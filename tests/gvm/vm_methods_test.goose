// Tests for method lookup and intrinsic dispatch.
namespace vm_methods_test;

import std;

import goosetest;
import vm;

let HELPER_CALLS_CHI: const u8[:] = embed_file("../fixtures/helper_calls.chi");

var g_helper_calls_rite: u8[>..] = [];

fn helper_calls_rite() -> u8[:] {
    if g_helper_calls_rite.len == 0 {
        vm::vm_restore_rite_header(HELPER_CALLS_CHI, g_helper_calls_rite);
    }
    return g_helper_calls_rite[..];
}

fn test_compiled_helpers_pass_args_and_late_defs(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, helper_calls_rite()));
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

    let probe = vm::vm_instantiate(machine, vm::intern_symbol("HelperCalls"));
    t.assert_true(vm::mrb_is_state(probe));
    t.assert_eq(vm::VmError.Ok, machine.error);

    let direct = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_0"));
    t.assert_true(vm::vm_string_equals(machine, direct, "1234"));
    let later = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_1"));
    t.assert_true(vm::vm_string_equals(machine, later, "1234 total"));
    let later_direct = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_2"));
    t.assert_true(vm::vm_string_equals(machine, later_direct, "1234 total"));
    let nested = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_3"));
    t.assert_true(vm::vm_string_equals(machine, nested, "1234 nested"));
    let initial = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_4"));
    t.assert_true(vm::vm_string_equals(machine, initial, "1234 init"));

    t.assert_eq(0, vm::binding_register(pool, probe, 0, vm::intern_symbol("__mochi_bind_0")));
    t.assert_eq(0, vm::binding_register(pool, probe, 1, vm::intern_symbol("__mochi_bind_1")));
    t.assert_eq(0, vm::binding_register(pool, probe, 2, vm::intern_symbol("__mochi_bind_2")));
    t.assert_eq(0, vm::binding_register(pool, probe, 3, vm::intern_symbol("__mochi_bind_3")));

    vm::vm_call0(machine, probe, vm::intern_symbol("bump"));
    var patches: u8[>..] = [];
    t.assert_eq(4, vm::vm_flush_dirty_bindings(machine, probe, patches));
    t.assert_eq(vm::VmError.Ok, machine.error);

    let status = vm::vm_call1(machine, probe, vm::intern_symbol("apply"), vm::mrb_fixnum(5));
    t.assert_true(vm::vm_string_equals(machine, status,
        "count=5 label=1235 total direct=1235"));
    let updated = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_bind_1"));
    t.assert_true(vm::vm_string_equals(machine, updated, "1235 total"));

    var arity_args: vm::MrbValue[2] = [vm::mrb_fixnum(1), vm::mrb_fixnum(2)];
    vm::vm_call_args(machine, probe, vm::intern_symbol("number"), arity_args[..]);
    t.assert_eq(vm::VmError.WrongArity, machine.error);

    vm::vm_call0(machine, probe, vm::intern_symbol("missing_helper"));
    t.assert_eq(vm::VmError.NoMethod, machine.error);
    vm::vm_end_entry(machine);
}

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

let EACH_ROWS_CHI: const u8[:] = embed_file("../fixtures/each_rows.chi");

var g_each_rows_rite: u8[>..] = [];

fn each_rows_rite() -> u8[:] {
    if g_each_rows_rite.len == 0 {
        vm::vm_restore_rite_header(EACH_ROWS_CHI, g_each_rows_rite);
    }
    return g_each_rows_rite[..];
}

fn rows_value(
    machine: vm::Vm&, rows: vm::MrbValue, row: i64, index: i64
) -> vm::MrbValue {
    let row_value = vm::builtin_array_get(machine.pool, machine.scratch, rows, row);
    let values = vm::builtin_array_get(machine.pool, machine.scratch, row_value, 1);
    return vm::builtin_array_get(machine.pool, machine.scratch, values, index);
}

fn test_row_getters_evaluate_nested_scopes(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, each_rows_rite()));
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

    let probe = vm::vm_instantiate(machine, vm::intern_symbol("EachRows"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::mrb_is_state(probe));

    let rows = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_each_0_rows"));
    t.assert_eq(vm::VmError.Ok, machine.error, "rows getter");
    t.assert_eq(2, vm::builtin_array_length(machine.pool, machine.scratch, rows));
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, rows, 0, 0), "a"), "row0 id");
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, rows, 0, 1), "Alpha!:0"), "row0 label");
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, rows, 1, 0), "b"), "row1 id");
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, rows, 1, 1), "Beta!:1"), "row1 label");

    let row = vm::builtin_array_get(machine.pool, machine.scratch, rows, 0);
    let children = vm::builtin_array_get(machine.pool, machine.scratch, row, 2);
    t.assert_eq(1, vm::builtin_array_length(machine.pool, machine.scratch, children));
    let child_rows = vm::builtin_array_get(machine.pool, machine.scratch, children, 0);
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, child_rows, 1, 0),
        "a2#0"), "child value");
    let row_one = vm::builtin_array_get(machine.pool, machine.scratch, rows, 1);
    let children_one = vm::builtin_array_get(machine.pool, machine.scratch, row_one, 2);
    let child_rows_one = vm::builtin_array_get(machine.pool, machine.scratch, children_one, 0);
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, child_rows_one, 0, 0),
        "a1#1"), "child outer index");

    let status = vm::vm_call0(machine, probe, vm::intern_symbol("status"));
    t.assert_true(vm::vm_string_equals(machine, status, "idle"), "initial status");

    let item = vm::builtin_array_get(machine.pool, machine.scratch, row, 0);
    var event_args: vm::MrbValue[3] = [item, vm::mrb_fixnum(1), vm::mrb_nil()];
    vm::vm_call_args(machine, probe, vm::intern_symbol("__mochi_each_0_ev_1"),
        event_args[..]);
    t.assert_eq(vm::VmError.Ok, machine.error, "row event");
    let opened = vm::vm_call0(machine, probe, vm::intern_symbol("status"));
    t.assert_true(vm::vm_string_equals(machine, opened, "1"), "opened status");

    t.assert_eq(0, vm::binding_register(pool, probe, 0,
        vm::intern_symbol("__mochi_each_0_rows")));
    t.assert_eq(0, vm::binding_register(pool, probe, 1, vm::intern_symbol("status")));
    var patches: u8[>..] = [];
    t.assert_eq(2, vm::vm_flush_dirty_bindings(machine, probe, patches));

    vm::vm_call0(machine, probe, vm::intern_symbol("bump"));
    let bumped = vm::vm_call0(machine, probe, vm::intern_symbol("__mochi_each_0_rows"));
    t.assert_true(vm::vm_string_equals(machine, rows_value(machine, bumped, 0, 1), "Alpha?:0"));
    var refreshed: u8[>..] = [];
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, probe, refreshed));
    vm::vm_end_entry(machine);
}

fn test_row_helper_failure_reports_row_binding(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, each_rows_rite()));
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

    vm::vm_begin_entry(machine);
    let probe = vm::vm_instantiate(machine, vm::intern_symbol("EachRows"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::mrb_is_state(probe));
    t.assert_eq(0, vm::binding_register(pool, probe, 5,
        vm::intern_symbol("__mochi_each_1_rows")));
    var patches: u8[>..] = [];
    t.assert_eq(-1, vm::vm_flush_dirty_bindings(machine, probe, patches));
    t.assert_eq(vm::VmError.NoMethod, machine.error);
    t.assert_eq(5, machine.error_context.binding_id);
    t.assert_eq("EachRows", vm::symbol_name(
        vm::state_class_name_symbol(pool, machine.error_context.class_id)));
    t.assert_true(vm::symbol_name(machine.error_context.method_symbol) ==
        "__mochi_each_1_rows");
    vm::vm_end_entry(machine);
}
