// Tests for extended Object, Fixnum, String, Array, and Hash intrinsic methods.
namespace vm_builtins_ext_test;

import math;
import std;

import goosetest;
import vm;

fn test_to_s_and_to_i_conversions(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let num_s = vm::builtin_to_s(machine, vm::mrb_fixnum(-42));
    t.assert_eq("-42", vm::builtin_string_bytes(pool, scratch, num_s));

    let bool_s = vm::builtin_to_s(machine, vm::mrb_true());
    t.assert_eq("true", vm::builtin_string_bytes(pool, scratch, bool_s));

    let nil_s = vm::builtin_to_s(machine, vm::mrb_nil());
    t.assert_eq("", vm::builtin_string_bytes(pool, scratch, nil_s));

    let parsed = vm::builtin_to_i(machine, vm::scratch_alloc_string(scratch, "  -1000px"));
    t.assert_eq(-1000, vm::mrb_fixnum_value(parsed));
    t.assert_eq(0, vm::mrb_fixnum_value(vm::builtin_to_i(machine, vm::mrb_nil())));
}

fn test_fixnum_method_dispatch(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let args_one: vm::MrbValue[1] = [vm::mrb_fixnum(5)];
    let prod, prod_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(6), "*", args_one[..]);
    t.assert_true(prod_ok);
    t.assert_eq(30, vm::mrb_fixnum_value(prod));

    let quot, quot_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-7), "/", args_one[..]);
    t.assert_true(quot_ok);
    t.assert_eq(-2, vm::mrb_fixnum_value(quot));

    let rem, rem_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-7), "%", args_one[..]);
    t.assert_true(rem_ok);
    t.assert_eq(3, vm::mrb_fixnum_value(rem));

    let empty: vm::MrbValue[0] = [];
    let abs_v, abs_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-9), "abs", empty[..]);
    t.assert_true(abs_ok);
    t.assert_eq(9, vm::mrb_fixnum_value(abs_v));

    let even_v, even_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(4), "even?", empty[..]);
    t.assert_true(even_ok);
    t.assert_true(vm::mrb_is_true(even_v));

    let clamp_args: vm::MrbValue[2] = [vm::mrb_fixnum(0), vm::mrb_fixnum(10)];
    let clamped, clamp_ok = vm::builtin_number_method(
        machine, vm::mrb_fixnum(15), "clamp", clamp_args[..]
    );
    t.assert_true(clamp_ok);
    t.assert_eq(10, vm::mrb_fixnum_value(clamped));
}

fn test_numeric_rounding_dispatch(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let empty: vm::MrbValue[0] = [];
    let negative_precision: vm::MrbValue[1] = [vm::mrb_fixnum(-1)];
    let precision: vm::MrbValue[1] = [vm::mrb_fixnum(1)];

    let rounded, round_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-25), "round", negative_precision[..]);
    t.assert_true(round_ok);
    t.assert_eq(-30, vm::mrb_fixnum_value(rounded));
    let floored, floor_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-21), "floor", negative_precision[..]);
    t.assert_true(floor_ok);
    t.assert_eq(-30, vm::mrb_fixnum_value(floored));
    let ceiled, ceil_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(-21), "ceil", negative_precision[..]);
    t.assert_true(ceil_ok);
    t.assert_eq(-20, vm::mrb_fixnum_value(ceiled));

    let float = vm::num_from_f64(scratch, -1.25);
    let decimal, decimal_ok = vm::builtin_number_method(machine, float, "floor", precision[..]);
    t.assert_true(decimal_ok);
    t.assert_eq(vm::NumKind.Float, vm::num_kind(scratch, pool, decimal));
    let decimal_value, decimal_value_ok = vm::num_to_f64(scratch, pool, decimal);
    t.assert_true(decimal_value_ok);
    t.assert_eq(-1.3, decimal_value);
    let rounded_decimal, rounded_decimal_ok = vm::builtin_number_method(
        machine, float, "round", precision[..]
    );
    t.assert_true(rounded_decimal_ok);
    t.assert_eq(vm::NumKind.Float, vm::num_kind(scratch, pool, rounded_decimal));
    let rounded_decimal_value, rounded_decimal_value_ok = vm::num_to_f64(
        scratch, pool, rounded_decimal
    );
    t.assert_true(rounded_decimal_value_ok);
    t.assert_eq(-1.3, rounded_decimal_value);
    let float_ceil_input = vm::num_from_f64(scratch, 1.21);
    let float_ceil, float_ceil_ok = vm::builtin_number_method(
        machine, float_ceil_input, "ceil", precision[..]
    );
    t.assert_true(float_ceil_ok);
    t.assert_eq(vm::NumKind.Float, vm::num_kind(scratch, pool, float_ceil));
    let float_ceil_value, float_ceil_value_ok = vm::num_to_f64(scratch, pool, float_ceil);
    t.assert_true(float_ceil_value_ok);
    t.assert_eq(1.3, float_ceil_value);

    let negative_zero = vm::num_from_f64(scratch, -0.0);
    let rounded_zero, rounded_zero_ok = vm::builtin_number_method(
        machine, negative_zero, "round", precision[..]
    );
    t.assert_true(rounded_zero_ok);
    let rounded_zero_value, rounded_zero_value_ok = vm::num_float_value(scratch, pool, rounded_zero);
    t.assert_true(rounded_zero_value_ok);
    t.assert_eq(-1.0, copysign(1.0, rounded_zero_value));

    let decimal_input = vm::num_from_f64(scratch, 1.005);
    let two_digits: vm::MrbValue[1] = [vm::mrb_fixnum(2)];
    let decimal_half, decimal_half_ok = vm::builtin_number_method(machine, decimal_input, "round", two_digits[..]);
    t.assert_true(decimal_half_ok);
    let decimal_half_value, decimal_half_value_ok = vm::num_to_f64(scratch, pool, decimal_half);
    t.assert_true(decimal_half_value_ok);
    t.assert_eq(1.01, decimal_half_value);

    let halfway = vm::num_from_f64(scratch, 2.5);
    let rounded_half, half_ok = vm::builtin_number_method(machine, halfway, "round", empty[..]);
    t.assert_true(half_ok);
    t.assert_eq(3, vm::mrb_fixnum_value(rounded_half));

    let options = vm::builtin_hash_new(scratch);
    let half_key = vm::mrb_symbol(vm::intern_symbol("half"));
    let even_mode = vm::mrb_symbol(vm::intern_symbol("even"));
    t.assert_true(vm::builtin_hash_set(pool, scratch, options, half_key, even_mode));
    let keyword_args: vm::MrbValue[1] = [options];
    let even_half, even_ok = vm::builtin_number_method(machine, halfway, "round", keyword_args[..]);
    t.assert_true(even_ok);
    t.assert_eq(2, vm::mrb_fixnum_value(even_half));
    let three_half = vm::num_from_f64(scratch, 3.5);
    let even_three_half, even_three_ok = vm::builtin_number_method(
        machine, three_half, "round", keyword_args[..]
    );
    t.assert_true(even_three_ok);
    t.assert_eq(4, vm::mrb_fixnum_value(even_three_half));

    let down_mode = vm::mrb_symbol(vm::intern_symbol("down"));
    t.assert_true(vm::builtin_hash_set(pool, scratch, options, half_key, down_mode));
    let negative_half = vm::num_from_f64(scratch, -2.5);
    let down_half, down_ok = vm::builtin_number_method(machine, negative_half, "round", keyword_args[..]);
    t.assert_true(down_ok);
    t.assert_eq(-2, vm::mrb_fixnum_value(down_half));

    let integer_precision, integer_precision_ok = vm::builtin_number_method(machine, vm::mrb_fixnum(4), "round", precision[..]);
    t.assert_true(integer_precision_ok);
    t.assert_eq(vm::NumKind.Integer, vm::num_kind(scratch, pool, integer_precision));

    let tiny_negative = vm::num_from_f64(scratch, -1e-320);
    let coarse_precision: vm::MrbValue[1] = [vm::mrb_fixnum(-18)];
    let tiny_floor, tiny_floor_ok = vm::builtin_number_method(
        machine, tiny_negative, "floor", coarse_precision[..]
    );
    t.assert_true(tiny_floor_ok);
    let tiny_floor_value, tiny_floor_value_ok = vm::num_integer_value(scratch, pool, tiny_floor);
    t.assert_true(tiny_floor_value_ok);
    t.assert_eq(-1000000000000000000, tiny_floor_value);

    let small_tie = vm::num_from_f64(scratch, 5.0);
    let small_tie_rounded, small_tie_ok = vm::builtin_number_method(
        machine, small_tie, "round", negative_precision[..]
    );
    t.assert_true(small_tie_ok);
    t.assert_eq(10, vm::mrb_fixnum_value(small_tie_rounded));
    let small_below = vm::num_from_f64(scratch, 4.0);
    let small_rounded, small_ok = vm::builtin_number_method(
        machine, small_below, "round", negative_precision[..]
    );
    t.assert_true(small_ok);
    t.assert_eq(0, vm::mrb_fixnum_value(small_rounded));
}

fn test_numeric_rounding_rejects_unsupported_inputs(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let too_precise: vm::MrbValue[1] = [vm::mrb_fixnum(19)];
    let invalid, handled = vm::builtin_number_method(machine, vm::mrb_fixnum(1), "round", too_precise[..]);
    t.assert_true(handled);
    t.assert_true(vm::mrb_is_nil(invalid));
    t.assert_eq(vm::VmError.InvalidArgument, machine.error);

    machine.error = vm::VmError.Ok;
    let non_integer_precision: vm::MrbValue[1] = [vm::num_from_f64(scratch, 1.5)];
    let type_error, type_handled = vm::builtin_number_method(
        machine, vm::mrb_fixnum(1), "ceil", non_integer_precision[..]
    );
    t.assert_true(type_handled);
    t.assert_true(vm::mrb_is_nil(type_error));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);

    machine.error = vm::VmError.Ok;
    let extra_options = vm::builtin_hash_new(scratch);
    vm::builtin_hash_set(
        pool, scratch, extra_options,
        vm::mrb_symbol(vm::intern_symbol("unknown")), vm::mrb_true()
    );
    let extra_args: vm::MrbValue[1] = [extra_options];
    let extra, extra_handled = vm::builtin_number_method(
        machine, vm::mrb_fixnum(1), "round", extra_args[..]
    );
    t.assert_true(extra_handled);
    t.assert_true(vm::mrb_is_nil(extra));
    t.assert_eq(vm::VmError.InvalidArgument, machine.error);

    machine.error = vm::VmError.Ok;
    let invalid_mode_options = vm::builtin_hash_new(scratch);
    vm::builtin_hash_set(
        pool, scratch, invalid_mode_options,
        vm::mrb_symbol(vm::intern_symbol("half")),
        vm::mrb_symbol(vm::intern_symbol("sideways"))
    );
    let invalid_mode_args: vm::MrbValue[1] = [invalid_mode_options];
    let invalid_mode, invalid_mode_handled = vm::builtin_number_method(
        machine, vm::mrb_fixnum(2), "round", invalid_mode_args[..]
    );
    t.assert_true(invalid_mode_handled);
    t.assert_true(vm::mrb_is_nil(invalid_mode));
    t.assert_eq(vm::VmError.InvalidArgument, machine.error);

    machine.error = vm::VmError.Ok;
    let infinity = vm::num_from_f64(scratch, 1.0 / 0.0);
    let empty: vm::MrbValue[0] = [];
    let nonfinite, nonfinite_handled = vm::builtin_number_method(machine, infinity, "floor", empty[..]);
    t.assert_true(nonfinite_handled);
    t.assert_true(vm::mrb_is_nil(nonfinite));
    t.assert_eq(vm::VmError.FloatDomain, machine.error);

    machine.error = vm::VmError.Ok;
    let high_finite = vm::num_from_f64(scratch, 9223372036854775808.0);
    let overflow, overflow_handled = vm::builtin_number_method(machine, high_finite, "round", empty[..]);
    t.assert_true(overflow_handled);
    t.assert_true(vm::mrb_is_nil(overflow));
    t.assert_eq(vm::VmError.IntegerOverflow, machine.error);
}

fn test_string_ext_case_trim_and_predicates(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let empty: vm::MrbValue[0] = [];
    let raw = vm::scratch_alloc_string(scratch, "  Sencha Mochi  ");
    let stripped, strip_ok = vm::builtin_string_ext(machine, raw, "strip", empty[..]);
    t.assert_true(strip_ok);
    t.assert_eq("Sencha Mochi", vm::builtin_string_bytes(pool, scratch, stripped));

    let up, up_ok = vm::builtin_string_ext(machine, stripped, "upcase", empty[..]);
    t.assert_true(up_ok);
    t.assert_eq("SENCHA MOCHI", vm::builtin_string_bytes(pool, scratch, up));

    let down, down_ok = vm::builtin_string_ext(machine, stripped, "downcase", empty[..]);
    t.assert_true(down_ok);
    t.assert_eq("sencha mochi", vm::builtin_string_bytes(pool, scratch, down));

    let needle: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "Mochi")];
    let inc, inc_ok = vm::builtin_string_ext(machine, stripped, "include?", needle[..]);
    t.assert_true(inc_ok);
    t.assert_true(vm::mrb_is_true(inc));

    let ew, ew_ok = vm::builtin_string_ext(machine, stripped, "end_with?", needle[..]);
    t.assert_true(ew_ok);
    t.assert_true(vm::mrb_is_true(ew));
}

fn test_string_ext_split_and_gsub(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let csv = vm::scratch_alloc_string(scratch, "a,b,c");
    let sep: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, ",")];
    let parts, split_ok = vm::builtin_string_ext(machine, csv, "split", sep[..]);
    t.assert_true(split_ok);
    t.assert_eq(3, vm::builtin_array_length(pool, scratch, parts));
    t.assert_eq(
        "b", vm::builtin_string_bytes(pool, scratch, vm::builtin_array_get(pool, scratch, parts, 1))
    );

    let gsub_args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(scratch, ","),
        vm::scratch_alloc_string(scratch, "-"),
    ];
    let replaced, gsub_ok = vm::builtin_string_ext(machine, csv, "gsub", gsub_args[..]);
    t.assert_true(gsub_ok);
    t.assert_eq("a-b-c", vm::builtin_string_bytes(pool, scratch, replaced));
}

fn test_array_ext_operations(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let arr = vm::builtin_array_new(scratch);
    vm::builtin_array_push(pool, scratch, arr, vm::mrb_fixnum(3));
    vm::builtin_array_push(pool, scratch, arr, vm::mrb_nil());
    vm::builtin_array_push(pool, scratch, arr, vm::mrb_fixnum(1));
    vm::builtin_array_push(pool, scratch, arr, vm::mrb_fixnum(2));

    let empty: vm::MrbValue[0] = [];
    let compacted, comp_ok = vm::builtin_array_ext(machine, arr, "compact", empty[..]);
    t.assert_true(comp_ok);
    t.assert_eq(3, vm::builtin_array_length(pool, scratch, compacted));

    let sorted, sort_ok = vm::builtin_array_ext(machine, compacted, "sort", empty[..]);
    t.assert_true(sort_ok);
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, sorted, 0)));
    t.assert_eq(3, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, sorted, 2)));

    let rev, rev_ok = vm::builtin_array_ext(machine, sorted, "reverse", empty[..]);
    t.assert_true(rev_ok);
    t.assert_eq(3, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, rev, 0)));

    let target: vm::MrbValue[1] = [vm::mrb_fixnum(2)];
    let has_two, inc_ok = vm::builtin_array_ext(machine, sorted, "include?", target[..]);
    t.assert_true(inc_ok);
    t.assert_true(vm::mrb_is_true(has_two));
}

fn test_hash_ext_operations(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let h = vm::scratch_alloc_hash(scratch);
    let k1 = vm::mrb_symbol(1);
    let k2 = vm::mrb_symbol(2);
    vm::scratch_hash_set(scratch, h, k1, vm::mrb_fixnum(10));
    vm::scratch_hash_set(scratch, h, k2, vm::mrb_fixnum(20));

    let empty: vm::MrbValue[0] = [];
    let keys, keys_ok = vm::builtin_hash_ext(machine, h, "keys", empty[..]);
    t.assert_true(keys_ok);
    t.assert_eq(2, vm::builtin_array_length(pool, scratch, keys));

    let query: vm::MrbValue[1] = [k1];
    let has_k1, hk_ok = vm::builtin_hash_ext(machine, h, "has_key?", query[..]);
    t.assert_true(hk_ok);
    t.assert_true(vm::mrb_is_true(has_k1));

    let deleted, del_ok = vm::builtin_hash_ext(machine, h, "delete", query[..]);
    t.assert_true(del_ok);
    t.assert_eq(10, vm::mrb_fixnum_value(deleted));
    t.assert_eq(1, vm::scratch_hash_length(scratch, h));
}
