// Real mrbc dispatch must preserve helper namespaces and lexical owners.
namespace vm_constants_test;

import std;

import goosetest;
import vm;

let HELPERS: const u8[:] = embed_file("../fixtures/helper_contracts.mrb");

fn test_qualified_and_lexical_constants(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, HELPERS));
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
    let root = vm::vm_instantiate(machine, vm::intern_symbol("HelperRoot"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    let result = vm::vm_call0(machine, root, vm::intern_symbol("constants"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::vm_string_equals(machine, result, "7,7,99,99"));
    let helper, found = vm::vm_find_class(pool, vm::intern_symbol("RecordData"));
    t.assert_true(found);
    let direct = vm::vm_call0(machine, vm::mrb_class(helper), vm::intern_symbol("base"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq(7, vm::mrb_fixnum_value(direct));
    vm::vm_call0(machine, root, vm::intern_symbol("missing_constant"));
    t.assert_eq(vm::VmError.NoConstant, machine.error);
    t.assert_true(vm::symbol_name(machine.error_context.reference_symbol) == "RecordData::MISSING");
    vm::vm_call0(machine, root, vm::intern_symbol("missing_method"));
    t.assert_eq(vm::VmError.NoMethod, machine.error);
    t.assert_eq(helper, machine.error_context.class_id);
    t.assert_true(vm::symbol_name(machine.error_context.method_symbol) == "missing");
    let recovered = vm::vm_call0(machine, root, vm::intern_symbol("constants"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::vm_string_equals(machine, recovered, "7,7,99,99"));
    t.assert_eq(vm::NULL_SYMBOL, machine.error_context.reference_symbol);
}
