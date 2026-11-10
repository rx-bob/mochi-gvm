// Tests for method lookup and intrinsic dispatch.
namespace vm_methods_test;

import std;

import goosetest;
import vm;

fn test_array_builtin_dispatch(t: goosetest::Test&) {
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
    let array = vm::builtin_array_new(scratch);
    var args: vm::MrbValue[>..] = [];
    args.push(vm::mrb_fixnum(7));
    let pushed, push_handled = vm::vm_call_builtin(machine, array,
        vm::intern_symbol("push"), args[..]);
    t.assert_true(push_handled);
    t.assert_eq(array, pushed);
    t.assert_eq(1, vm::builtin_array_length(pool, scratch, array));

    let last, last_handled = vm::vm_call_builtin(machine, array,
        vm::intern_symbol("last"), args[..1]);
    t.assert_true(last_handled);
    t.assert_eq(7, vm::mrb_fixnum_value(last));

    let joined, join_handled = vm::vm_call_builtin(machine, array,
        vm::intern_symbol("join"), args[..1]);
    t.assert_true(join_handled);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, joined) == "7");
}

fn test_string_and_hash_builtin_dispatch(t: goosetest::Test&) {
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
    let text = vm::scratch_alloc_string(scratch, "hello world");
    var args: vm::MrbValue[>..] = [];
    args.push(vm::scratch_alloc_string(scratch, "world"));
    args.push(vm::mrb_fixnum(0));
    let index, index_handled = vm::vm_call_builtin(machine, text,
        vm::intern_symbol("index"), args[..]);
    t.assert_true(index_handled);
    t.assert_eq(6, vm::mrb_fixnum_value(index));

    var slice_args: vm::MrbValue[>..] = [];
    slice_args.push(vm::mrb_fixnum(0));
    slice_args.push(vm::mrb_fixnum(5));
    let slice, slice_handled = vm::vm_call_builtin(machine, text,
        vm::intern_symbol("[]"), slice_args[..]);
    t.assert_true(slice_handled);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, slice) == "hello");

    let hash = vm::builtin_hash_new(scratch);
    let key = vm::mrb_symbol(99);
    var set_args: vm::MrbValue[>..] = [];
    set_args.push(key);
    set_args.push(vm::mrb_fixnum(4));
    let set, set_handled = vm::vm_call_builtin(machine, hash,
        vm::intern_symbol("[]="), set_args[..]);
    t.assert_true(set_handled);
    t.assert_eq(4, vm::mrb_fixnum_value(set));
    let got, get_handled = vm::vm_call_builtin(machine, hash,
        vm::intern_symbol("[]"), set_args[..1]);
    t.assert_true(get_handled);
    t.assert_eq(4, vm::mrb_fixnum_value(got));
}

fn test_boolean_not_and_array_new(t: goosetest::Test&) {
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
    var no_args: vm::MrbValue[>..] = [];
    let negated, negated_handled = vm::vm_call_builtin(machine, vm::mrb_true(),
        vm::intern_symbol("!"), no_args[..]);
    t.assert_true(negated_handled);
    t.assert_true(vm::mrb_is_false(negated));
    let array, new_handled = vm::vm_call_builtin(machine,
        vm::mrb_class(vm::BUILTIN_ARRAY_CLASS_ID), vm::intern_symbol("new"), no_args[..]);
    t.assert_true(new_handled);
    t.assert_true(vm::scratch_is_array(scratch, array));
}
