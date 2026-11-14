// Conventional, bounded JSON. Transport wrappers belong only to json_args.
namespace vm;

import.builtins;
import.json_args;
import.scratch_alloc;
import.signals;
import.value_arena;
import.vm_core;
import.vm_errors;
import.vm_methods;
import.vm_num;

let JSON_DOCUMENT_BYTES = 48000;

fn json_valid_utf8(text: u8[:]) -> bool {
    var at = 0;
    while at < text.len {
        let first = text[at];
        at += 1;
        if first < 128 {
            continue;
        }
        var count = 0;
        var code: u32 = 0;
        var minimum: u32 = 0;
        if first >= 194 && first <= 223 {
            count = 1;
            code = first & 31;
            minimum = 128;
        } else if first >= 224 && first <= 239 {
            count = 2;
            code = first & 15;
            minimum = 2048;
        } else if first >= 240 && first <= 244 {
            count = 3;
            code = first & 7;
            minimum = 65536;
        } else {
            return false;
        }
        if at + count > text.len {
            return false;
        }
        for index in 0..count {
            let byte = text[at + index];
            if byte < 128 || byte > 191 {
                return false;
            }
            code = (code << 6) | (byte & 63);
        }
        at += count;
        if code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
            return false;
        }
    }
    return true;
}

fn json_decode(machine: Vm&, text: u8[:]) -> MrbValue {
    if text.len > JSON_DOCUMENT_BYTES {
        machine.error = VmError.JsonLimit;
        return mrb_nil();
    }
    if !json_valid_utf8(text) {
        machine.error = VmError.JsonInvalid;
        return mrb_nil();
    }
    var cursor = JsonCursor {
        at: 0,
        failed: false,
        transport: false
    };
    let value = json_parse_value(machine.pool, machine.scratch, text, cursor, 0);
    json_skip_whitespace(text, cursor);
    if vm_capture_capacity_failure(machine) {
        return mrb_nil();
    }
    if cursor.failed || cursor.at != text.len {
        machine.error = if cursor.limit {
            VmError.JsonLimit
        } else {
            VmError.JsonInvalid
        };
        return mrb_nil();
    }
    return value;
}

fn json_append(machine: Vm&, out: u8[>..]&, text: u8[:]) {
    if machine.error != VmError.Ok {
        return;
    }
    if out.len + text.len > JSON_DOCUMENT_BYTES {
        machine.error = VmError.JsonLimit;
        return;
    }
    out.append(text);
}

fn json_encode_string(machine: Vm&, out: u8[>..]&, value: MrbValue) {
    if !vm_is_string_value(machine, value) {
        machine.error = VmError.JsonType;
        return;
    }
    let text = builtin_string_bytes(machine.pool, machine.scratch, value);
    if !json_valid_utf8(text) {
        machine.error = VmError.JsonInvalid;
        return;
    }
    // Count escapes before allocating or appending any expanded text.
    var size = 2;
    for byte in text {
        size += if byte == 8 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 34 || byte == 92 {
            2
        } else if byte < 32 {
            6
        } else {
            1
        };
    }
    if out.len + size > JSON_DOCUMENT_BYTES {
        machine.error = VmError.JsonLimit;
        return;
    }
    out.push(34);
    binding_json_escape(out, text);
    out.push(34);
}

recursive fn json_encode_value(machine: Vm&, out: u8[>..]&, value: MrbValue, ancestors: MrbValue[>..]&) {
    if machine.error != VmError.Ok {
        return;
    }
    let array = binding_value_is_array(machine, value);
    let hash = binding_value_is_hash(machine, value);
    if array || hash {
        for parent in ancestors {
            if parent == value {
                machine.error = VmError.JsonCycle;
                return;
            }
        }
        if ancestors.len >= JSON_MAX_DEPTH {
            machine.error = VmError.JsonLimit;
            return;
        }
        ancestors.push(value);
        json_append(machine, out, if array {
                "["
            } else {
                "{"
            });
        let length = if array {
            binding_array_length(machine, value)
        } else {
            binding_hash_length(machine, value)
        };
        for index in 0..length {
            if machine.error != VmError.Ok {
                break;
            }
            if index > 0 {
                json_append(machine, out, ",");
            }
            if array {
                let item, found = binding_array_get(machine, value, index);
                if !found {
                    machine.error = VmError.JsonType;
                    break;
                }
                json_encode_value(machine, out, item, ancestors);
            } else {
                let slot = binding_hash_slot_index(machine, value, index);
                if slot < 0 {
                    machine.error = VmError.JsonType;
                    break;
                }
                json_encode_string(machine, out, binding_hash_slot_key(machine, value, slot));
                json_append(machine, out, ":");
                json_encode_value(machine, out, binding_hash_slot_value(machine, value, slot), ancestors);
            }
        }
        ancestors.pop();
        json_append(machine, out, if array {
                "]"
            } else {
                "}"
            });
        return;
    }
    if mrb_is_nil(value) {
        json_append(machine, out, "null");
    } else if mrb_is_true(value) {
        json_append(machine, out, "true");
    } else if mrb_is_false(value) {
        json_append(machine, out, "false");
    } else if mrb_is_fixnum(value) || mrb_is_int64(value) {
        let number, ok = num_integer_value(machine.scratch, machine.pool, value);
        if !ok {
            machine.error = VmError.JsonType;
            return;
        }
        var text: u8[>..] = [];
        mrb_format_fixnum(text, number);
        json_append(machine, out, text[..]);
    } else if mrb_is_float(value) {
        let number, ok = num_float_value(machine.scratch, machine.pool, value);
        if !ok || number != number || number - number != 0.0 {
            machine.error = VmError.FloatDomain;
            return;
        }
        var text: u8[>..] = [];
        num_format_float(text, number);
        json_append(machine, out, text[..]);
    } else {
        json_encode_string(machine, out, value);
    }
}

fn json_encode(machine: Vm&, value: MrbValue) -> MrbValue {
    var out: u8[>..] = [];
    var ancestors: MrbValue[>..] = [];
    json_encode_value(machine, out, value, ancestors);
    if machine.error != VmError.Ok {
        return mrb_nil();
    }
    let result = scratch_alloc_string(machine.scratch, out[..]);
    vm_capture_capacity_failure(machine);
    return result;
}

fn vm_call_json(machine: Vm&, name: u8[:], args: MrbValue[:]) -> MrbValue, bool {
    if name != "json_parse" && name != "json_generate" {
        return mrb_nil(), false;
    }
    if args.len != 1 {
        machine.error = VmError.WrongArity;
        return mrb_nil(), true;
    }
    if name == "json_generate" {
        return json_encode(machine, args[0]), true;
    }
    if !vm_is_string_value(machine, args[0]) {
        machine.error = VmError.TypeMismatch;
        return mrb_nil(), true;
    }
    return json_decode(machine, builtin_string_bytes(machine.pool, machine.scratch, args[0])), true;
}
