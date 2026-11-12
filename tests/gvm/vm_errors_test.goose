// Tests for VM error context and descriptive error names.
namespace vm_errors_test;

import std;

import goosetest;
import vm;

fn test_error_context_records_fields(t: goosetest::Test&) {
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
    vm::vm_set_error_context(machine, 3, 7, 2);
    t.assert_eq(3, machine.error_context.class_id);
    t.assert_eq(7, machine.error_context.method_symbol);
    t.assert_eq(2, machine.error_context.binding_id);
}

fn test_ivar_capacity_error_name(t: goosetest::Test&) {
    t.assert_eq("ivar capacity exceeded", vm::vm_error_name(vm::VmError.IvarCapacity));
}

fn test_innermost_method_claims_error_context_once(t: goosetest::Test&) {
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
    machine.methods.push(vm::MethodEntry {
            class_id: 3,
            name_symbol: 7,
            irep_index: 9,
        });
    machine.methods.push(vm::MethodEntry {
            class_id: 4,
            name_symbol: 8,
            irep_index: 10,
        });
    vm::vm_set_error_context(machine, 0xFFFFFFFF, 0xFFFFFFFF, -1);
    vm::vm_absorb_method_context(machine, 9);
    t.assert_eq(3, machine.error_context.class_id);
    t.assert_eq(7, machine.error_context.method_symbol);
    vm::vm_absorb_method_context(machine, 10);
    t.assert_eq(3, machine.error_context.class_id);
    t.assert_eq(7, machine.error_context.method_symbol);
}
