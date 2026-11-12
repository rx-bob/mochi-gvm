// Tests for extended Object, Fixnum, String, Array, and Hash intrinsic methods.
namespace vm_builtins_ext_test;

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
