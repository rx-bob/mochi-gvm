// Bounded JSON decoding for host event arguments.
//
// The loader passes event argument lists as JSON arrays. This module decodes
// strings, integers, booleans, nulls, arrays and objects into tick-arena
// `MrbValue`s. Objects become Hashes with string keys, and the Hash key
// comparison in `builtins.goose` makes those keys indistinguishable from the
// matching Ruby symbols.
namespace vm;

import.builtins;
import.collection_arena;
import.scratch_alloc;
import.state_pool;
import.value_arena;

let JSON_MAX_ARGS = 8;
let JSON_MAX_DEPTH = 16;
let JSON_QUOTE: u8 = 34;
let JSON_BACKSLASH: u8 = 92;
let JSON_COMMA: u8 = 44;
let JSON_COLON: u8 = 58;
let JSON_OPEN_ARRAY: u8 = 91;
let JSON_CLOSE_ARRAY: u8 = 93;
let JSON_OPEN_OBJECT: u8 = 123;
let JSON_CLOSE_OBJECT: u8 = 125;

struct JsonCursor {
    at: i64,
    failed: bool,
}

fn json_skip_whitespace(data: const u8[:], cursor: JsonCursor&) {
    while cursor.at < data.len {
        let byte = data[cursor.at];
        if byte != 32 && byte != 9 && byte != 10 && byte != 13 {
            return;
        }
        cursor.at += 1;
    }
}

fn json_take(data: const u8[:], cursor: JsonCursor&, expected: u8) -> bool {
    if cursor.at >= data.len || data[cursor.at] != expected {
        return false;
    }
    cursor.at += 1;
    return true;
}

fn json_match(data: const u8[:], cursor: JsonCursor&, text: const u8[:]) -> bool {
    if cursor.at + text.len > data.len {
        return false;
    }
    var index = 0;
    while index < text.len {
        if data[cursor.at + index] != text[index] {
            return false;
        }
        index += 1;
    }
    cursor.at += text.len;
    return true;
}

fn json_digit(byte: u8) -> bool {
    return byte >= 48 && byte <= 57;
}

fn json_hex_value(byte: u8) -> u8, bool {
    if byte >= 48 && byte <= 57 {
        return byte - 48, true;
    }
    if byte >= 65 && byte <= 70 {
        return byte - 65 + 10, true;
    }
    if byte >= 97 && byte <= 102 {
        return byte - 97 + 10, true;
    }
    return 0, false;
}

fn json_read_hex4(data: const u8[:], cursor: JsonCursor&) -> u32, bool {
    if cursor.at + 4 > data.len {
        return 0, false;
    }
    var value: u32 = 0;
    var index = 0;
    while index < 4 {
        let digit, ok = json_hex_value(data[cursor.at + index]);
        if !ok {
            return 0, false;
        }
        value = (value << 4) | digit;
        index += 1;
    }
    cursor.at += 4;
    return value, true;
}

fn json_append_utf8(out: u8[>..]&, code: u32) {
    if code <= 0x7F {
        out.push(code as u8);
    } else if code <= 0x7FF {
        out.push((0xC0 | (code >> 6))as u8);
        out.push((0x80 | (code & 0x3F))as u8);
    } else if code <= 0xFFFF {
        out.push((0xE0 | (code >> 12))as u8);
        out.push((0x80 | ((code >> 6) & 0x3F))as u8);
        out.push((0x80 | (code & 0x3F))as u8);
    } else {
        out.push((0xF0 | (code >> 18))as u8);
        out.push((0x80 | ((code >> 12) & 0x3F))as u8);
        out.push((0x80 | ((code >> 6) & 0x3F))as u8);
        out.push((0x80 | (code & 0x3F))as u8);
    }
}

fn json_parse_string(scratch: ScratchArena&, data: const u8[:], cursor: JsonCursor&) -> MrbValue {
    if !json_take(data, cursor, JSON_QUOTE) {
        cursor.failed = true;
        return mrb_nil();
    }
    var out: u8[>..] = [];
    while cursor.at < data.len {
        let byte = data[cursor.at];
        cursor.at += 1;
        if byte == JSON_QUOTE {
            return scratch_alloc_string(scratch, out[..]);
        }
        if byte == JSON_BACKSLASH {
            if cursor.at >= data.len {
                cursor.failed = true;
                return mrb_nil();
            }
            let escape = data[cursor.at];
            cursor.at += 1;
            if escape == JSON_QUOTE || escape == JSON_BACKSLASH || escape == 47 {
                out.push(escape);
            } else if escape == 98 {
                out.push(8);
            } else if escape == 102 {
                out.push(12);
            } else if escape == 110 {
                out.push(10);
            } else if escape == 114 {
                out.push(13);
            } else if escape == 116 {
                out.push(9);
            } else if escape == 117 {
                var code, code_ok = json_read_hex4(data, cursor);
                if !code_ok {
                    cursor.failed = true;
                    return mrb_nil();
                }
                if code >= 0xD800 && code <= 0xDBFF {
                    if cursor.at + 2 > data.len
                        || data[cursor.at] != JSON_BACKSLASH
                        || data[cursor.at + 1] != 117 {
                        cursor.failed = true;
                        return mrb_nil();
                    }
                    cursor.at += 2;
                    let low, low_ok = json_read_hex4(data, cursor);
                    if !low_ok || low < 0xDC00 || low > 0xDFFF {
                        cursor.failed = true;
                        return mrb_nil();
                    }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                } else if code >= 0xDC00 && code <= 0xDFFF {
                    cursor.failed = true;
                    return mrb_nil();
                }
                json_append_utf8(out, code);
            } else {
                cursor.failed = true;
                return mrb_nil();
            }
        } else {
            if byte < 32 {
                cursor.failed = true;
                return mrb_nil();
            }
            out.push(byte);
        }
    }
    cursor.failed = true;
    return mrb_nil();
}

fn json_parse_number(data: const u8[:], cursor: JsonCursor&) -> MrbValue {
    var negative = false;
    if cursor.at < data.len && data[cursor.at] == 45 {
        negative = true;
        cursor.at += 1;
    }
    if cursor.at >= data.len || !json_digit(data[cursor.at]) {
        cursor.failed = true;
        return mrb_nil();
    }
    var magnitude: i64 = 0;
    if data[cursor.at] == 48 {
        cursor.at += 1;
        if cursor.at < data.len && json_digit(data[cursor.at]) {
            cursor.failed = true;
            return mrb_nil();
        }
    } else {
        while cursor.at < data.len && json_digit(data[cursor.at]) {
            let digit = (data[cursor.at] - 48)as i64;
            if magnitude > 214748364 {
                cursor.failed = true;
                return mrb_nil();
            }
            magnitude = magnitude * 10 + digit;
            if magnitude > 2147483648 {
                cursor.failed = true;
                return mrb_nil();
            }
            cursor.at += 1;
        }
    }
    if cursor.at < data.len {
        let suffix = data[cursor.at];
        if suffix == 46 || suffix == 101 || suffix == 69 {
            cursor.failed = true;
            return mrb_nil();
        }
    }
    if negative {
        return mrb_fixnum(-magnitude);
    }
    if magnitude > 2147483647 {
        cursor.failed = true;
        return mrb_nil();
    }
    return mrb_fixnum(magnitude);
}

recursive fn json_parse_value(
    pool: StatePool&, scratch: ScratchArena&, data: const u8[:], cursor: JsonCursor&, depth: i64
) -> MrbValue {
    json_skip_whitespace(data, cursor);
    if cursor.at >= data.len || depth > JSON_MAX_DEPTH {
        cursor.failed = true;
        return mrb_nil();
    }
    let byte = data[cursor.at];
    if byte == JSON_QUOTE {
        return json_parse_string(scratch, data, cursor);
    }
    if byte == JSON_OPEN_OBJECT {
        cursor.at += 1;
        return json_parse_object(pool, scratch, data, cursor, depth + 1);
    }
    if byte == JSON_OPEN_ARRAY {
        cursor.at += 1;
        return json_parse_array(pool, scratch, data, cursor, depth + 1);
    }
    if byte == 116 && json_match(data, cursor, "true") {
        return mrb_true();
    }
    if byte == 102 && json_match(data, cursor, "false") {
        return mrb_false();
    }
    if byte == 110 && json_match(data, cursor, "null") {
        return mrb_nil();
    }
    if byte == 45 || json_digit(byte) {
        return json_parse_number(data, cursor);
    }
    cursor.failed = true;
    return mrb_nil();
}

recursive fn json_parse_object(
    pool: StatePool&, scratch: ScratchArena&, data: const u8[:], cursor: JsonCursor&, depth: i64
) -> MrbValue {
    let hash = scratch_alloc_hash(scratch);
    json_skip_whitespace(data, cursor);
    if json_take(data, cursor, JSON_CLOSE_OBJECT) {
        return hash;
    }
    while !cursor.failed {
        json_skip_whitespace(data, cursor);
        let key = json_parse_string(scratch, data, cursor);
        if cursor.failed {
            return mrb_nil();
        }
        json_skip_whitespace(data, cursor);
        if !json_take(data, cursor, JSON_COLON) {
            cursor.failed = true;
            return mrb_nil();
        }
        let value = json_parse_value(pool, scratch, data, cursor, depth);
        if cursor.failed {
            return mrb_nil();
        }
        if !builtin_hash_set(pool, scratch, hash, key, value) {
            cursor.failed = true;
            return mrb_nil();
        }
        json_skip_whitespace(data, cursor);
        if json_take(data, cursor, JSON_CLOSE_OBJECT) {
            return hash;
        }
        if !json_take(data, cursor, JSON_COMMA) {
            cursor.failed = true;
            return mrb_nil();
        }
    }
    return mrb_nil();
}

recursive fn json_parse_array(
    pool: StatePool&, scratch: ScratchArena&, data: const u8[:], cursor: JsonCursor&, depth: i64
) -> MrbValue {
    let array = scratch_alloc_array(scratch);
    json_skip_whitespace(data, cursor);
    if json_take(data, cursor, JSON_CLOSE_ARRAY) {
        return array;
    }
    while !cursor.failed {
        let value = json_parse_value(pool, scratch, data, cursor, depth);
        if cursor.failed {
            return mrb_nil();
        }
        if !builtin_array_push(pool, scratch, array, value) {
            cursor.failed = true;
            return mrb_nil();
        }
        json_skip_whitespace(data, cursor);
        if json_take(data, cursor, JSON_CLOSE_ARRAY) {
            return array;
        }
        if !json_take(data, cursor, JSON_COMMA) {
            cursor.failed = true;
            return mrb_nil();
        }
    }
    return mrb_nil();
}

// Decodes one complete JSON document. Response envelopes use this entry so a
// top-level Hash or Array is accepted, not only the event argument list shape.
fn json_parse_document(
    pool: StatePool&, scratch: ScratchArena&, data: const u8[:]
) -> MrbValue, bool {
    var cursor = JsonCursor {
        at: 0,
        failed: false,
    };
    let value = json_parse_value(pool, scratch, data, cursor, 0);
    json_skip_whitespace(data, cursor);
    return value, !cursor.failed && cursor.at == data.len;
}

// Decodes a top-level JSON array into `args`. The caller owns `args` and must
// provide enough room for the ABI's fixed call window.
fn json_parse_args(
    pool: StatePool&, scratch: ScratchArena&, data: const u8[:], args: MrbValue[>..]&
) -> bool {
    var cursor = JsonCursor {
        at: 0,
        failed: false,
    };
    json_skip_whitespace(data, cursor);
    if !json_take(data, cursor, JSON_OPEN_ARRAY) {
        return false;
    }
    json_skip_whitespace(data, cursor);
    if json_take(data, cursor, JSON_CLOSE_ARRAY) {
        json_skip_whitespace(data, cursor);
        return cursor.at == data.len;
    }
    while !cursor.failed {
        if args.len >= JSON_MAX_ARGS {
            return false;
        }
        let value = json_parse_value(pool, scratch, data, cursor, 0);
        if cursor.failed {
            return false;
        }
        args.push(value);
        json_skip_whitespace(data, cursor);
        if json_take(data, cursor, JSON_CLOSE_ARRAY) {
            json_skip_whitespace(data, cursor);
            return cursor.at == data.len;
        }
        if !json_take(data, cursor, JSON_COMMA) {
            return false;
        }
    }
    return false;
}
