// Bounded Ruby numbers: checked signed 64-bit integers and binary64 floats.
//
// Integers keep the 32-bit immediate fast path. Values outside that range are
// boxed in either arena, and every arithmetic operation pre-checks the signed
// 64-bit result because Goose aborts on debug overflow and wraps in release.
// Float arithmetic follows Ruby's IEEE behavior, including Infinity and NaN.
namespace vm;

import math;

import.scratch_alloc;
import.state_pool;
import.value_arena;

let NUM_I64_MIN: i64 = -9223372036854775808;
let NUM_I64_MAX: i64 = 9223372036854775807;
let NUM_I64_MAGNITUDE: u64 = 0x8000000000000000;
let NUM_I64_POSITIVE_LIMIT: u64 = 0x7FFFFFFFFFFFFFFF;
// 2^63 as a binary64. Values at or beyond this bound cannot be converted to a
// signed 64-bit integer.
let NUM_TWO_POW_63: f64 = 9223372036854775808.0;

enum NumKind {
    Invalid,
    Integer,
    Float,
}

enum NumFault {
    Ok,
    Type,
    Overflow,
    DivisionByZero,
    Scratch,
}

fn num_kind(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> NumKind {
    if mrb_is_fixnum(value) || mrb_is_int64(value) {
        return NumKind.Integer;
    }
    if mrb_is_float(value) {
        return NumKind.Float;
    }
    if mrb_is_scratch(value) {
        let object, ok = scratch_object(scratch, value);
        if !ok {
            return NumKind.Invalid;
        }
        if object.kind == ArenaObjectKind.Int64 {
            return NumKind.Integer;
        }
        if object.kind == ArenaObjectKind.Float {
            return NumKind.Float;
        }
        return NumKind.Invalid;
    }
    let object, ok = state_object(pool, value);
    if !ok {
        return NumKind.Invalid;
    }
    if object.kind == ArenaObjectKind.Int64 {
        return NumKind.Integer;
    }
    if object.kind == ArenaObjectKind.Float {
        return NumKind.Float;
    }
    return NumKind.Invalid;
}

fn num_is_number(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> bool {
    return num_kind(scratch, pool, value) != NumKind.Invalid;
}

fn num_is_integer(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> bool {
    return num_kind(scratch, pool, value) == NumKind.Integer;
}

fn num_integer_value(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> i64, bool {
    if mrb_is_fixnum(value) {
        return mrb_fixnum_value(value), true;
    }
    var object = empty_arena_object(ArenaObjectKind.Int64);
    var ok = false;
    if mrb_is_scratch(value) {
        object, ok = scratch_object(scratch, value);
    } else {
        object, ok = state_object(pool, value);
    }
    if !ok || object.kind != ArenaObjectKind.Int64 {
        return 0, false;
    }
    return object.integer_value, true;
}

fn num_float_value(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> f64, bool {
    var object = empty_arena_object(ArenaObjectKind.Float);
    var ok = false;
    if mrb_is_scratch(value) {
        object, ok = scratch_object(scratch, value);
    } else {
        object, ok = state_object(pool, value);
    }
    if !ok || object.kind != ArenaObjectKind.Float {
        return 0.0, false;
    }
    return object.float_value, true;
}

fn num_to_f64(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> f64, bool {
    let kind = num_kind(scratch, pool, value);
    if kind == NumKind.Integer {
        let integer, ok = num_integer_value(scratch, pool, value);
        if !ok {
            return 0.0, false;
        }
        return integer, true;
    }
    if kind == NumKind.Float {
        return num_float_value(scratch, pool, value);
    }
    return 0.0, false;
}

// Converts an integral numeric value to i64. Floats truncate toward zero, as
// Ruby's `Float#to_i`; non-finite and out-of-range floats fail instead of
// producing a wrapped value.
fn num_to_i64(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> i64, bool {
    let kind = num_kind(scratch, pool, value);
    if kind == NumKind.Integer {
        return num_integer_value(scratch, pool, value);
    }
    if kind != NumKind.Float {
        return 0, false;
    }
    let float, ok = num_float_value(scratch, pool, value);
    if !ok || float != float || float >= NUM_TWO_POW_63 || float < - NUM_TWO_POW_63 {
        return 0, false;
    }
    return float as i64, true;
}

fn num_from_i64(scratch: ScratchArena&, value: i64) -> MrbValue {
    if value >= MRB_FIXNUM_MIN && value <= MRB_FIXNUM_MAX {
        return mrb_fixnum(value);
    }
    return scratch_alloc_int64(scratch, value);
}

fn num_from_f64(scratch: ScratchArena&, value: f64) -> MrbValue {
    return scratch_alloc_float(scratch, value);
}

fn num_finish(value: MrbValue) -> MrbValue, NumFault {
    if mrb_is_nil(value) {
        return mrb_nil(), NumFault.Scratch;
    }
    return value, NumFault.Ok;
}

fn num_zero(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> bool {
    let kind = num_kind(scratch, pool, value);
    if kind == NumKind.Integer {
        let integer, ok = num_integer_value(scratch, pool, value);
        return ok && integer == 0;
    }
    if kind == NumKind.Float {
        let float, ok = num_float_value(scratch, pool, value);
        return ok && float == 0.0;
    }
    return false;
}

fn num_add_i64(left: i64, right: i64) -> i64, bool {
    if right > 0 && left > NUM_I64_MAX - right {
        return 0, false;
    }
    if right < 0 && left < NUM_I64_MIN - right {
        return 0, false;
    }
    return left + right, true;
}

fn num_sub_i64(left: i64, right: i64) -> i64, bool {
    if right > 0 && left < NUM_I64_MIN + right {
        return 0, false;
    }
    if right < 0 && left > NUM_I64_MAX + right {
        return 0, false;
    }
    return left - right, true;
}

fn num_mul_i64(left: i64, right: i64) -> i64, bool {
    let negative = (left < 0) != (right < 0);
    var left_magnitude = left as!u64;
    if left < 0 {
        left_magnitude = 0 - left_magnitude;
    }
    var right_magnitude = right as!u64;
    if right < 0 {
        right_magnitude = 0 - right_magnitude;
    }
    let limit = if negative {
        NUM_I64_MAGNITUDE
    } else {
        NUM_I64_POSITIVE_LIMIT
    };
    if left_magnitude != 0 && right_magnitude > limit / left_magnitude {
        return 0, false;
    }
    let magnitude = left_magnitude * right_magnitude;
    if negative {
        if magnitude == NUM_I64_MAGNITUDE {
            return NUM_I64_MIN, true;
        }
        return -(magnitude as!i64), true;
    }
    return magnitude as!i64, true;
}

fn num_div_i64(left: i64, right: i64) -> i64, bool {
    if right == 0 {
        return 0, false;
    }
    if left == NUM_I64_MIN && right == -1 {
        return 0, false;
    }
    var quotient = left / right;
    let remainder = left - quotient * right;
    if remainder != 0 && ((remainder < 0) != (right < 0)) {
        quotient -= 1;
    }
    return quotient, true;
}

fn num_mod_i64(left: i64, right: i64) -> i64, bool {
    if right == 0 {
        return 0, false;
    }
    if left == NUM_I64_MIN && right == -1 {
        return 0, true;
    }
    var remainder = left % right;
    if remainder != 0 && ((remainder < 0) != (right < 0)) {
        remainder += right;
    }
    return remainder, true;
}

fn num_float_div(left: f64, right: f64) -> f64 {
    if right == 0.0 {
        if left == 0.0 || left != left {
            return NAN;
        }
        return copysign(INF, left) * copysign(1.0, right);
    }
    return left / right;
}

fn num_float_mod(left: f64, right: f64) -> f64 {
    if right == 0.0 || left != left || right != right {
        return NAN;
    }
    return left - right * floor(left / right);
}

fn num_add(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> MrbValue, NumFault {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if left_kind == NumKind.Float || right_kind == NumKind.Float {
        let left_float, left_ok = num_to_f64(scratch, pool, left);
        let right_float, right_ok = num_to_f64(scratch, pool, right);
        if !left_ok || !right_ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, left_float + right_float);
        return num_finish(result);
    }
    let left_integer, left_ok = num_integer_value(scratch, pool, left);
    let right_integer, right_ok = num_integer_value(scratch, pool, right);
    if !left_ok || !right_ok {
        return mrb_nil(), NumFault.Type;
    }
    let sum, ok = num_add_i64(left_integer, right_integer);
    if !ok {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, sum);
    return num_finish(result);
}

fn num_sub(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> MrbValue, NumFault {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if left_kind == NumKind.Float || right_kind == NumKind.Float {
        let left_float, left_ok = num_to_f64(scratch, pool, left);
        let right_float, right_ok = num_to_f64(scratch, pool, right);
        if !left_ok || !right_ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, left_float - right_float);
        return num_finish(result);
    }
    let left_integer, left_ok = num_integer_value(scratch, pool, left);
    let right_integer, right_ok = num_integer_value(scratch, pool, right);
    if !left_ok || !right_ok {
        return mrb_nil(), NumFault.Type;
    }
    let difference, ok = num_sub_i64(left_integer, right_integer);
    if !ok {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, difference);
    return num_finish(result);
}

fn num_mul(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> MrbValue, NumFault {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if left_kind == NumKind.Float || right_kind == NumKind.Float {
        let left_float, left_ok = num_to_f64(scratch, pool, left);
        let right_float, right_ok = num_to_f64(scratch, pool, right);
        if !left_ok || !right_ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, left_float * right_float);
        return num_finish(result);
    }
    let left_integer, left_ok = num_integer_value(scratch, pool, left);
    let right_integer, right_ok = num_integer_value(scratch, pool, right);
    if !left_ok || !right_ok {
        return mrb_nil(), NumFault.Type;
    }
    let product, ok = num_mul_i64(left_integer, right_integer);
    if !ok {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, product);
    return num_finish(result);
}

fn num_div(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> MrbValue, NumFault {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if left_kind == NumKind.Float || right_kind == NumKind.Float {
        let left_float, left_ok = num_to_f64(scratch, pool, left);
        let right_float, right_ok = num_to_f64(scratch, pool, right);
        if !left_ok || !right_ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, num_float_div(left_float, right_float));
        return num_finish(result);
    }
    let left_integer, left_ok = num_integer_value(scratch, pool, left);
    let right_integer, right_ok = num_integer_value(scratch, pool, right);
    if !left_ok || !right_ok {
        return mrb_nil(), NumFault.Type;
    }
    if right_integer == 0 {
        return mrb_nil(), NumFault.DivisionByZero;
    }
    let quotient, ok = num_div_i64(left_integer, right_integer);
    if !ok {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, quotient);
    return num_finish(result);
}

fn num_mod(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> MrbValue, NumFault {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if left_kind == NumKind.Float || right_kind == NumKind.Float {
        let left_float, left_ok = num_to_f64(scratch, pool, left);
        let right_float, right_ok = num_to_f64(scratch, pool, right);
        if !left_ok || !right_ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, num_float_mod(left_float, right_float));
        return num_finish(result);
    }
    let left_integer, left_ok = num_integer_value(scratch, pool, left);
    let right_integer, right_ok = num_integer_value(scratch, pool, right);
    if !left_ok || !right_ok {
        return mrb_nil(), NumFault.Type;
    }
    if right_integer == 0 {
        return mrb_nil(), NumFault.DivisionByZero;
    }
    let remainder, ok = num_mod_i64(left_integer, right_integer);
    if !ok {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, remainder);
    return num_finish(result);
}

fn num_neg(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> MrbValue, NumFault {
    let kind = num_kind(scratch, pool, value);
    if kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if kind == NumKind.Float {
        let float, ok = num_float_value(scratch, pool, value);
        if !ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, -float);
        return num_finish(result);
    }
    let integer, ok = num_integer_value(scratch, pool, value);
    if !ok {
        return mrb_nil(), NumFault.Type;
    }
    if integer == NUM_I64_MIN {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, -integer);
    return num_finish(result);
}

fn num_abs(scratch: ScratchArena&, pool: StatePool&, value: MrbValue) -> MrbValue, NumFault {
    let kind = num_kind(scratch, pool, value);
    if kind == NumKind.Invalid {
        return mrb_nil(), NumFault.Type;
    }
    if kind == NumKind.Float {
        let float, ok = num_float_value(scratch, pool, value);
        if !ok {
            return mrb_nil(), NumFault.Type;
        }
        let result = num_from_f64(scratch, if float < 0.0 {
                -float
            } else {
                float
            });
        return num_finish(result);
    }
    let integer, ok = num_integer_value(scratch, pool, value);
    if !ok {
        return mrb_nil(), NumFault.Type;
    }
    if integer == NUM_I64_MIN {
        return mrb_nil(), NumFault.Overflow;
    }
    let result = num_from_i64(scratch, if integer < 0 {
            -integer
        } else {
            integer
        });
    return num_finish(result);
}

fn num_compare_int_float(integer: i64, float: f64) -> i64, bool {
    if float != float {
        return 0, false;
    }
    if float >= NUM_TWO_POW_63 {
        return -1, true;
    }
    if float < - NUM_TWO_POW_63 {
        return 1, true;
    }
    let truncated = float as i64;
    if integer < truncated {
        return -1, true;
    }
    if integer > truncated {
        return 1, true;
    }
    let truncated_float = truncated as f64;
    if float > truncated_float {
        return -1, true;
    }
    if float < truncated_float {
        return 1, true;
    }
    return 0, true;
}

// Returns -1, 0 or 1. `ok` is false for NaN, which is unordered.
fn num_compare(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> i64, bool {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || right_kind == NumKind.Invalid {
        return 0, false;
    }
    if left_kind == NumKind.Integer && right_kind == NumKind.Integer {
        let left_integer, left_ok = num_integer_value(scratch, pool, left);
        let right_integer, right_ok = num_integer_value(scratch, pool, right);
        if !left_ok || !right_ok {
            return 0, false;
        }
        if left_integer < right_integer {
            return -1, true;
        }
        if left_integer > right_integer {
            return 1, true;
        }
        return 0, true;
    }
    if left_kind == NumKind.Integer {
        let left_integer, left_ok = num_integer_value(scratch, pool, left);
        let right_float, right_ok = num_float_value(scratch, pool, right);
        if !left_ok || !right_ok {
            return 0, false;
        }
        return num_compare_int_float(left_integer, right_float);
    }
    if right_kind == NumKind.Integer {
        let left_float, left_ok = num_float_value(scratch, pool, left);
        let right_integer, right_ok = num_integer_value(scratch, pool, right);
        if !left_ok || !right_ok {
            return 0, false;
        }
        let order, ok = num_compare_int_float(right_integer, left_float);
        return -order, ok;
    }
    let left_float, left_ok = num_float_value(scratch, pool, left);
    let right_float, right_ok = num_float_value(scratch, pool, right);
    if !left_ok || !right_ok || left_float != left_float || right_float != right_float {
        return 0, false;
    }
    if left_float < right_float {
        return -1, true;
    }
    if left_float > right_float {
        return 1, true;
    }
    return 0, true;
}

// Ruby `==`: integer and float values compare across the numeric boundary.
fn num_equal(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> bool {
    let order, ok = num_compare(scratch, pool, left, right);
    return ok && order == 0;
}

// Ruby Hash key equality (`eql?`): both operands must be the same numeric kind,
// so `1` and `1.0` remain distinct keys.
fn num_eql(scratch: ScratchArena&, pool: StatePool&, left: MrbValue, right: MrbValue) -> bool {
    let left_kind = num_kind(scratch, pool, left);
    let right_kind = num_kind(scratch, pool, right);
    if left_kind == NumKind.Invalid || left_kind != right_kind {
        return false;
    }
    if left_kind == NumKind.Integer {
        let left_integer, left_ok = num_integer_value(scratch, pool, left);
        let right_integer, right_ok = num_integer_value(scratch, pool, right);
        return left_ok && right_ok && left_integer == right_integer;
    }
    let left_float, left_ok = num_float_value(scratch, pool, left);
    let right_float, right_ok = num_float_value(scratch, pool, right);
    return left_ok && right_ok && left_float == right_float;
}

// Appends Ruby's `Float#to_s` form. The shortest round-trip digits come from
// the compiler's `format` builtin; this layer adds the `.0` mantissa and the
// Infinity/NaN spelling Ruby uses.
fn num_format_float(out: u8[>..]&, value: f64) {
    if value != value {
        out.append("NaN");
        return;
    }
    if value - value != 0.0 {
        if value < 0.0 {
            out.append("-Infinity");
        } else {
            out.append("Infinity");
        }
        return;
    }
    var raw: u8[>..] = [];
    format(raw, value);
    var exponent_at = -1;
    var index = 0;
    while index < raw.len {
        if raw[index] == 101 || raw[index] == 69 {
            exponent_at = index;
            break;
        }
        index += 1;
    }
    if exponent_at < 0 {
        out.append(raw[..]);
        return;
    }
    var has_point = false;
    index = 0;
    while index < exponent_at {
        if raw[index] == 46 {
            has_point = true;
            break;
        }
        index += 1;
    }
    out.append(raw[..exponent_at]);
    if !has_point {
        out.append(".0");
    }
    out.push(raw[exponent_at]);
    index = exponent_at + 1;
    if index < raw.len && (raw[index] == 43 || raw[index] == 45) {
        out.push(raw[index]);
        index += 1;
    }
    let digits_start = index;
    while index < raw.len {
        index += 1;
    }
    if index - digits_start < 2 {
        out.push(48);
    }
    out.append(raw[digits_start..index]);
}

// Parses unsigned digits in `base` and applies `negative`. Magnitudes are
// accumulated in u64 so i64.min can be represented before the final sign.
fn num_parse_i64_bytes(bytes: u8[:], base: i64, negative: bool) -> i64, bool {
    if base < 2 || base > 36 || bytes.len == 0 {
        return 0, false;
    }
    let unsigned_base = base as u64;
    let limit = if negative {
        NUM_I64_MAGNITUDE
    } else {
        NUM_I64_POSITIVE_LIMIT
    };
    var magnitude: u64 = 0;
    for byte in bytes {
        var digit: u64 = 0;
        if byte >= 48 && byte <= 57 {
            digit = (byte - 48);
        } else if byte >= 65 && byte <= 90 {
            digit = (byte - 65 + 10);
        } else if byte >= 97 && byte <= 122 {
            digit = (byte - 97 + 10);
        } else {
            return 0, false;
        }
        if digit >= unsigned_base || magnitude > (limit - digit) / unsigned_base {
            return 0, false;
        }
        magnitude = magnitude * unsigned_base + digit;
    }
    if !negative {
        return magnitude as!i64, true;
    }
    if magnitude == NUM_I64_MAGNITUDE {
        return NUM_I64_MIN, true;
    }
    return -(magnitude as!i64), true;
}
