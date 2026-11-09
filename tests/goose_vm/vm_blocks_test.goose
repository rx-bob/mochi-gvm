// Tests for block invocation guards.
namespace vm_blocks_test;

import std;

import goosetest;
import vm;

fn test_iterate_requires_block(t: goosetest::Test&) {
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
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_nil()));
    let result = vm::vm_iterate_array(machine, array, vm::mrb_nil(), vm::mrb_nil(), true);
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}

fn test_invoke_block_requires_block(t: goosetest::Test&) {
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
    let result = vm::vm_invoke_block(machine, vm::mrb_nil(), vm::mrb_nil(), vm::mrb_nil());
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}
