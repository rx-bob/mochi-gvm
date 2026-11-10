// End-to-end tests for branching, method dispatch and Array#map blocks.
namespace vm_dispatch_test;

import std;

import goosetest;
import vm;

let TODO_CHI: const u8[:] = embed_file("../fixtures/todo.chi");
let USERS_CHI: const u8[:] = embed_file("../fixtures/users.chi");
let TODO_HTML_ONE: const u8[:] = "<div class='todo'><h2>Todo List (1 items)</h2><ul><li class='done'>Task 1 ✓</li></ul><div class='buttons'><button data-action='add_item'>Add</button><button data-action='toggle_last'>Toggle Last</button><button data-action='remove_last'>Remove Last</button></div></div>";
let TODO_HTML_EMPTY: const u8[:] = "<div class='todo'><h2>Todo List (0 items)</h2><ul></ul><div class='buttons'><button data-action='add_item'>Add</button><button data-action='toggle_last'>Toggle Last</button><button data-action='remove_last'>Remove Last</button></div></div>";
let USERS_HTML: const u8[:] = "<div class='users'><h2>Users from API</h2><p class='fetch-status'>Status: done</p><ul><li>Alice</li><li>Bob</li><li>Charlie</li></ul><div class='buttons'><button data-action='load_users'>Fetch Users</button></div></div>";
let USERS_JSON: const u8[:] = "[{\"name\":\"Alice\"},{\"name\":\"Bob\"},{\"name\":\"Charlie\"}]";

var g_todo_rite: u8[>..] = [];
var g_users_rite: u8[>..] = [];

fn todo_rite() -> u8[:] {
    if g_todo_rite.len == 0 {
        vm::vm_restore_rite_header(TODO_CHI, g_todo_rite);
    }
    return g_todo_rite[..];
}

fn users_rite() -> u8[:] {
    if g_users_rite.len == 0 {
        vm::vm_restore_rite_header(USERS_CHI, g_users_rite);
    }
    return g_users_rite[..];
}

fn test_todo_lifecycle_renders_exact_html(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, todo_rite()));
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
    let todo = vm::vm_instantiate(machine, vm::intern_symbol("TodoList"));
    t.assert_true(vm::mrb_is_state(todo));
    t.assert_eq(vm::VmError.Ok, machine.error);

    vm::vm_call0(machine, todo, vm::intern_symbol("add_item"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    vm::vm_call0(machine, todo, vm::intern_symbol("toggle_last"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    let html = vm::vm_call0(machine, todo, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, html, TODO_HTML_ONE));

    let items, items_ok = vm::state_get_ivar(pool, todo, vm::intern_symbol("@items"));
    t.assert_true(items_ok);
    t.assert_true(vm::state_is_array(pool, items));
    t.assert_eq(1, vm::builtin_array_length(pool, scratch, items));
    let item = vm::builtin_array_get(pool, scratch, items, 0);
    let done_key = vm::mrb_symbol(vm::intern_symbol("done"));
    let done = vm::builtin_hash_get(pool, scratch, item, done_key);
    t.assert_true(vm::mrb_is_true(done));

    vm::vm_call0(machine, todo, vm::intern_symbol("remove_last"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    let empty_html = vm::vm_call0(machine, todo, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, empty_html, TODO_HTML_EMPTY));
    vm::vm_end_entry(machine);
}

fn test_users_on_loaded_renders_exact_html(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, users_rite()));
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
    let user_list = vm::vm_instantiate(machine, vm::intern_symbol("UserList"));
    t.assert_true(vm::mrb_is_state(user_list));
    t.assert_eq(vm::VmError.Ok, machine.error);

    let json = vm::state_alloc_string(pool, USERS_JSON);
    vm::vm_call1(machine, user_list, vm::intern_symbol("on_users_loaded"), json);
    t.assert_eq(vm::VmError.Ok, machine.error);

    let users, users_ok = vm::state_get_ivar(pool, user_list, vm::intern_symbol("@users"));
    t.assert_true(users_ok);
    t.assert_true(vm::state_is_array(pool, users));
    t.assert_eq(3, vm::builtin_array_length(pool, scratch, users));
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_array_get(pool, scratch, users, 0)) == "Alice");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_array_get(pool, scratch, users, 1)) == "Bob");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_array_get(pool, scratch, users, 2)) == "Charlie");

    let html = vm::vm_call0(machine, user_list, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, html, USERS_HTML));
    vm::vm_end_entry(machine);
}

fn test_jump_and_conditional_offsets(t: goosetest::Test&) {
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
    let record = fake_record(2);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    machine.regs.push(vm::mrb_true());
    machine.regs.push(vm::mrb_nil());

    let bytes: u8[10] = [0, 6, 0, 0, 3, 0, 0, 0, 0, 0];
    let jump = vm::vm_op_jump(machine, bytes[..], 0);
    t.assert_eq(vm::StepKind.Continue, jump.kind);
    t.assert_eq(8, jump.pc);

    let if_step = vm::vm_op_cond_jump(machine, frame, record, bytes[..], 2, vm::OP_JMPIF);
    t.assert_eq(8, if_step.pc);
    let not_step = vm::vm_op_cond_jump(machine, frame, record, bytes[..], 2, vm::OP_JMPNOT);
    t.assert_eq(5, not_step.pc);
}

fn test_binary_and_array_ops(t: goosetest::Test&) {
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
    let record = fake_record(4);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    for _ in record.nregs {
        machine.regs.push(vm::mrb_nil());
    }
    machine.regs[0] = vm::mrb_fixnum(3);
    machine.regs[1] = vm::mrb_fixnum(4);
    let one: u8[1] = [0];
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_ADD);
    t.assert_eq(7, vm::mrb_fixnum_value(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(7);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_SUB);
    t.assert_eq(3, vm::mrb_fixnum_value(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(3);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_LT);
    t.assert_true(vm::mrb_is_true(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(3);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_LE);
    t.assert_true(vm::mrb_is_true(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(3);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_GT);
    t.assert_true(vm::mrb_is_false(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(3);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_GE);
    t.assert_true(vm::mrb_is_false(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(5);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_GT);
    t.assert_true(vm::mrb_is_true(machine.regs[0]));
    machine.regs[0] = vm::mrb_fixnum(5);
    vm::vm_op_binary(machine, frame, record, one[..], 0, vm::OP_GE);
    t.assert_true(vm::mrb_is_true(machine.regs[0]));

    machine.regs[0] = vm::mrb_fixnum(5);
    machine.regs[1] = vm::mrb_fixnum(6);
    let array_bytes: u8[2] = [0, 2];
    vm::vm_op_array(machine, frame, record, array_bytes[..], 0);
    let array = machine.regs[0];
    t.assert_true(vm::scratch_is_array(machine.scratch, array));
    t.assert_eq(2, vm::builtin_array_length(pool, scratch, array));
}

fn fake_record(nregs: u16) -> vm::IrepRecord {
    return vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 0,
        nlocals: 1,
        nregs: nregs,
        child_count: 0,
        catch_count: 0,
        iseq_length_bytes: 0,
        iseq_offset_bytes: 0,
        catch_offset_bytes: 0,
        pool_first_index: 0,
        pool_count: 0,
        syms_first_index: 0,
        syms_count: 0,
        parent_index: -1,
        first_child_index: -1,
        next_sibling_index: -1,
        depth: 0,
    };
}
