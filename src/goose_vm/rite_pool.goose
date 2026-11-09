// Literal pool entry decoder for the RITE0400 reader.
//
// Each entry starts with a one-byte type tag. String and bigint entries view
// the caller's buffer; integer and float entries hold scalar values.
namespace vm;

import binary;

import.rite_bytes;
import.rite_types;

// Parses one tagged pool entry at `at`, returning the entry and the offset
// just past it.
fn parse_pool_entry(data: u8[:], at: i64, limit: i64) -> PoolEntry, i64, ParseError {
    if at + 1 > limit {
        return empty_pool_entry(), at, ParseError.Truncated;
    }
    let tag = data[at];
    var entry = empty_pool_entry();
    entry.tag = tag;
    var cursor = at + 1;

    if tag == 0 {
        let next, err = parse_pool_string(data, cursor, limit, entry);
        if err != ParseError.Ok {
            return entry, cursor, err;
        }
        cursor = next;
    } else if tag == 1 {
        let next, err = parse_pool_int32(data, cursor, limit, entry);
        if err != ParseError.Ok {
            return entry, cursor, err;
        }
        cursor = next;
    } else if tag == 3 {
        let next, err = parse_pool_int64(data, cursor, limit, entry);
        if err != ParseError.Ok {
            return entry, cursor, err;
        }
        cursor = next;
    } else if tag == 5 {
        let next, err = parse_pool_float(data, cursor, limit, entry);
        if err != ParseError.Ok {
            return entry, cursor, err;
        }
        cursor = next;
    } else if tag == 7 {
        let next, err = parse_pool_bigint(data, cursor, limit, entry);
        if err != ParseError.Ok {
            return entry, cursor, err;
        }
        cursor = next;
    } else {
        return entry, cursor, ParseError.BadPoolTag;
    }
    return entry, cursor, ParseError.Ok;
}

// IREP_TT_STR: u16 byte length, the bytes, then a NUL terminator.
fn parse_pool_string(
    data: u8[:], at: i64, limit: i64, entry: PoolEntry&
) -> i64, ParseError {
    if at + 2 > limit {
        return at, ParseError.Truncated;
    }
    let length, length_ok = read_u16(data, at);
    if !length_ok {
        return at, ParseError.Truncated;
    }
    let text_length: i64 = length;
    let text_start = at + 2;
    let text_end = text_start + text_length;
    if text_end + 1 > limit {
        return at, ParseError.Truncated;
    }
    if data[text_end] != 0 {
        return at, ParseError.MissingTerminator;
    }
    entry.text_offset_bytes = text_start;
    entry.text_length_bytes = text_length;
    return text_end + 1, ParseError.Ok;
}

// IREP_TT_INT32: a signed big-endian 32-bit integer.
fn parse_pool_int32(
    data: u8[:], at: i64, limit: i64, entry: PoolEntry&
) -> i64, ParseError {
    if at + 4 > limit {
        return at, ParseError.Truncated;
    }
    let bits, bits_ok = read_u32(data, at);
    if !bits_ok {
        return at, ParseError.Truncated;
    }
    entry.int_value = bits as!i32;
    return at + 4, ParseError.Ok;
}

// IREP_TT_INT64: high and low big-endian 32-bit halves.
fn parse_pool_int64(
    data: u8[:], at: i64, limit: i64, entry: PoolEntry&
) -> i64, ParseError {
    if at + 8 > limit {
        return at, ParseError.Truncated;
    }
    let high, high_ok = read_u32(data, at);
    let low, low_ok = read_u32(data, at + 4);
    if !high_ok || !low_ok {
        return at, ParseError.Truncated;
    }
    entry.int_value = ((high as u64 << 32) | low)as!i64;
    return at + 8, ParseError.Ok;
}

// IREP_TT_FLOAT: the only little-endian payload in the format.
fn parse_pool_float(
    data: u8[:], at: i64, limit: i64, entry: PoolEntry&
) -> i64, ParseError {
    if at + 8 > limit {
        return at, ParseError.Truncated;
    }
    let value, value_ok = binary::read_f64le(data, at);
    if !value_ok {
        return at, ParseError.Truncated;
    }
    entry.float_value = value;
    return at + 8, ParseError.Ok;
}

// IREP_TT_BIGINT: one length byte and length + 2 opaque bytes. mruby keeps the
// length byte as the first byte of the blob, so the view starts there.
fn parse_pool_bigint(
    data: u8[:], at: i64, limit: i64, entry: PoolEntry&
) -> i64, ParseError {
    if at + 1 > limit {
        return at, ParseError.Truncated;
    }
    let digits = data[at]as i64;
    let blob_length = digits + 2;
    if at + blob_length > limit {
        return at, ParseError.Truncated;
    }
    entry.text_offset_bytes = at;
    entry.text_length_bytes = blob_length;
    return at + blob_length, ParseError.Ok;
}

// A default pool entry used on the error path.
fn empty_pool_entry() -> PoolEntry {
    return PoolEntry {
        tag: 0,
        text_offset_bytes: 0,
        text_length_bytes: 0,
        int_value: 0,
        float_value: 0.0,
    };
}
