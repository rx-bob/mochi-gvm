// Tests for host entrypoints that invoke component methods with arguments.
namespace vm_entry_test;

import std;

import goosetest;
import vm;

let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
var g_counter_rite: u8[>..] = [];

fn counter_rite() -> u8[:] {
    if g_counter_rite.len == 0 {
        vm::vm_restore_rite_header(COUNTER_CHI, g_counter_rite);
    }
    return g_counter_rite[..];
}

fn test_call1_rejects_argument_for_zero_arity(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, counter_rite()));
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
    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    t.assert_true(vm::mrb_is_state(counter));
    vm::vm_call1(machine, counter, vm::intern_symbol("increment"), vm::mrb_fixnum(9));
    t.assert_eq(vm::VmError.WrongArity, machine.error);
    vm::vm_end_entry(machine);
}

fn test_required_args_reads_leading_enter(t: goosetest::Test&) {
    let one_arg: u8[4] = [vm::OP_ENTER, 4, 0, 0];
    let required, has_enter = vm::vm_required_args(one_arg[..]);
    t.assert_true(has_enter);
    t.assert_eq(1, required);
    let no_enter: u8[2] = [vm::OP_RETURN, 2];
    let no_required, no_has_enter = vm::vm_required_args(no_enter[..]);
    t.assert_false(no_has_enter);
    t.assert_eq(0, no_required);
}
