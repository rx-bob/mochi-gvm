// Tests for Mochi.* host capabilities: storage, routing, timers, and attribute access.
namespace vm_host_api_test;

import std;

import goosetest;
import vm;

fn test_host_storage_roundtrip_and_outbox(t: goosetest::Test&) {
    vm::host_reset();
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

    vm::goose_vm_seed_storage("theme", "dark");
    let get_args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "theme")];
    let got, got_ok = vm::vm_call_mochi_builtin(machine, "storage_get", get_args[..]);
    t.assert_true(got_ok);
    t.assert_eq("dark", vm::builtin_string_bytes(pool, scratch, got));

    let set_args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(scratch, "theme"),
        vm::scratch_alloc_string(scratch, "light"),
    ];
    let set_v, set_ok = vm::vm_call_mochi_builtin(machine, "storage_set", set_args[..]);
    t.assert_true(set_ok);
    t.assert_eq("light", vm::builtin_string_bytes(pool, scratch, set_v));
    t.assert_true(vm::goose_vm_host_outbox().len > 0);
    vm::goose_vm_clear_host_outbox();
    t.assert_eq(0, vm::goose_vm_host_outbox().len);

    let rm_ok_val, rm_ok = vm::vm_call_mochi_builtin(machine, "storage_remove", get_args[..]);
    t.assert_true(rm_ok);
    t.assert_true(vm::mrb_is_true(rm_ok_val));

    let def_args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(scratch, "theme"),
        vm::scratch_alloc_string(scratch, "fallback"),
    ];
    let fallback, fb_ok = vm::vm_call_mochi_builtin(machine, "storage_get", def_args[..]);
    t.assert_true(fb_ok);
    t.assert_eq("fallback", vm::builtin_string_bytes(pool, scratch, fallback));
}

fn test_host_focus_commands(t: goosetest::Test&) {
    vm::host_reset();
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

    let focus_args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "modal_close")];
    let focus_val, focus_ok = vm::vm_call_mochi_builtin(machine, "focus", focus_args[..]);
    t.assert_true(focus_ok);
    t.assert_true(vm::mrb_is_true(focus_val));
    t.assert_true(vm::goose_vm_host_outbox().len > 0);
    vm::goose_vm_clear_host_outbox();

    let empty: vm::MrbValue[0] = [];
    let restore_val, restore_ok = vm::vm_call_mochi_builtin(machine, "restore_focus", empty[..]);
    t.assert_true(restore_ok);
    t.assert_true(vm::mrb_is_true(restore_val));
    t.assert_true(vm::goose_vm_host_outbox().len > 0);
    vm::goose_vm_clear_host_outbox();

    let empty_ref_args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "")];
    let empty_val, empty_ok = vm::vm_call_mochi_builtin(machine, "focus", empty_ref_args[..]);
    t.assert_true(empty_ok);
    t.assert_true(vm::mrb_is_false(empty_val));
}

fn test_host_route_timer_and_get_attr(t: goosetest::Test&) {
    vm::host_reset();
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

    vm::goose_vm_set_route_state("/queues");
    let empty: vm::MrbValue[0] = [];
    let route_val, route_ok = vm::vm_call_mochi_builtin(machine, "route", empty[..]);
    t.assert_true(route_ok);
    t.assert_eq("/queues", vm::builtin_string_bytes(pool, scratch, route_val));

    let nav_args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "/costs")];
    let nav_val, nav_ok = vm::vm_call_mochi_builtin(machine, "set_route", nav_args[..]);
    t.assert_true(nav_ok);
    t.assert_eq("/costs", vm::builtin_string_bytes(pool, scratch, nav_val));

    let timer_args: vm::MrbValue[2] = [
        vm::mrb_fixnum(250),
        vm::scratch_alloc_string(scratch, "tick"),
    ];
    let tid, t_ok = vm::vm_call_mochi_builtin(machine, "after", timer_args[..]);
    t.assert_true(t_ok);
    t.assert_eq(1, vm::mrb_fixnum_value(tid));

    let cancel_args: vm::MrbValue[1] = [tid];
    let c_val, c_ok = vm::vm_call_mochi_builtin(machine, "cancel_timer", cancel_args[..]);
    t.assert_true(c_ok);
    t.assert_true(vm::mrb_is_true(c_val));
}
