// Tests for checked signed 64-bit and binary64 numeric operations.
namespace vm_vm_num_test;

import std;

import goosetest;
import vm;

fn test_checked_integer_bounds(t: goosetest::Test&) {
    let max = vm::NUM_I64_MAX;
    let min = vm::NUM_I64_MIN;
    let sum, sum_ok = vm::num_add_i64(max, 1);
    t.assert_false(sum_ok);
    t.assert_eq(0, sum);
    let low, low_ok = vm::num_add_i64(min, -1);
    t.assert_false(low_ok);
    t.assert_eq(0, low);
    let edge, edge_ok = vm::num_add_i64(max, -1);
    t.assert_true(edge_ok);
    t.assert_eq(max - 1, edge);
    let difference, difference_ok = vm::num_sub_i64(min, 1);
    t.assert_false(difference_ok);
    t.assert_eq(0, difference);
    let product, product_ok = vm::num_mul_i64(min, 1);
    t.assert_true(product_ok);
    t.assert_eq(min, product);
    let negative_product, negative_ok = vm::num_mul_i64(min, -1);
    t.assert_false(negative_ok);
    t.assert_eq(0, negative_product);
    let small_product, small_ok = vm::num_mul_i64(-3, 7);
    t.assert_true(small_ok);
    t.assert_eq(-21, small_product);
}

fn test_integer_floor_division(t: goosetest::Test&) {
    let quotient, quotient_ok = vm::num_div_i64(7, 2);
    t.assert_true(quotient_ok);
    t.assert_eq(3, quotient);
    let negative_quotient, negative_ok = vm::num_div_i64(-7, 2);
    t.assert_true(negative_ok);
    t.assert_eq(-4, negative_quotient);
    let remainder, remainder_ok = vm::num_mod_i64(-7, 2);
    t.assert_true(remainder_ok);
    t.assert_eq(1, remainder);
    let min_remainder, min_ok = vm::num_mod_i64(vm::NUM_I64_MIN, -1);
    t.assert_true(min_ok);
    t.assert_eq(0, min_remainder);
    let zero, zero_ok = vm::num_div_i64(1, 0);
    t.assert_false(zero_ok);
    t.assert_eq(0, zero);
}

fn test_exact_mixed_comparison(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let large = vm::num_from_i64(scratch, 9007199254740993);
    let rounded = vm::num_from_f64(scratch, 9007199254740992.0);
    let order, ok = vm::num_compare(scratch, pool, large, rounded);
    t.assert_true(ok);
    t.assert_eq(1, order);
    t.assert_false(vm::num_equal(scratch, pool, large, rounded));
    let equal = vm::num_from_i64(scratch, 1);
    let float_equal = vm::num_from_f64(scratch, 1.0);
    t.assert_true(vm::num_equal(scratch, pool, equal, float_equal));
}

fn test_mixed_arithmetic(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let one = vm::mrb_fixnum(1);
    let two = vm::mrb_fixnum(2);
    let integer_quotient, integer_ok = vm::num_div(scratch, pool, one, two);
    t.assert_eq(vm::NumFault.Ok, integer_ok);
    t.assert_eq(0, vm::mrb_fixnum_value(integer_quotient));
    let one_float = vm::num_from_f64(scratch, 1.0);
    let float_quotient, float_ok = vm::num_div(scratch, pool, one_float, two);
    t.assert_eq(vm::NumFault.Ok, float_ok);
    let quotient, quotient_ok = vm::num_float_value(scratch, pool, float_quotient);
    t.assert_true(quotient_ok);
    t.assert_eq(0.5, quotient);
    let mixed, mixed_ok = vm::num_add(scratch, pool, one, vm::num_from_f64(scratch, 0.5));
    t.assert_eq(vm::NumFault.Ok, mixed_ok);
    let mixed_value, mixed_value_ok = vm::num_float_value(scratch, pool, mixed);
    t.assert_true(mixed_value_ok);
    t.assert_eq(1.5, mixed_value);
}

fn test_typed_numeric_errors(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let max = vm::num_from_i64(scratch, vm::NUM_I64_MAX);
    let one = vm::mrb_fixnum(1);
    let overflow, overflow_fault = vm::num_add(scratch, pool, max, one);
    t.assert_eq(vm::NumFault.Overflow, overflow_fault);
    t.assert_true(vm::mrb_is_nil(overflow));
    let divide, divide_fault = vm::num_div(scratch, pool, one, vm::mrb_fixnum(0));
    t.assert_eq(vm::NumFault.DivisionByZero, divide_fault);
    t.assert_true(vm::mrb_is_nil(divide));
}

fn test_float_format(t: goosetest::Test&) {
    var half: u8[>..] = [];
    vm::num_format_float(half, 0.5);
    t.assert_true(half[..] == "0.5");
    var whole: u8[>..] = [];
    vm::num_format_float(whole, 1.0);
    t.assert_true(whole[..] == "1.0");
    var exponent: u8[>..] = [];
    vm::num_format_float(exponent, 1e20);
    t.assert_true(exponent[..] == "1.0e+20");
    var infinity: u8[>..] = [];
    vm::num_format_float(infinity, INF);
    t.assert_true(infinity[..] == "Infinity");
    var nan: u8[>..] = [];
    vm::num_format_float(nan, NAN);
    t.assert_true(nan[..] == "NaN");
}

fn test_parse_integer_min(t: goosetest::Test&) {
    let maximum, maximum_ok = vm::num_parse_i64_bytes("9223372036854775807", 10, false);
    t.assert_true(maximum_ok);
    t.assert_eq(vm::NUM_I64_MAX, maximum);
    let minimum, minimum_ok = vm::num_parse_i64_bytes("9223372036854775808", 10, true);
    t.assert_true(minimum_ok);
    t.assert_eq(vm::NUM_I64_MIN, minimum);
    let too_large, too_large_ok = vm::num_parse_i64_bytes("9223372036854775808", 10, false);
    t.assert_false(too_large_ok);
    t.assert_eq(0, too_large);
}
