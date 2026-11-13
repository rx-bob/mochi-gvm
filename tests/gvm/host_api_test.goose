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

    vm::goose_vm_seed_storage("exported", "dark");
    vm::goose_vm_remove_storage("exported");
    let export_args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(scratch, "exported"),
        vm::scratch_alloc_string(scratch, "absent"),
    ];
    let absent, absent_ok = vm::vm_call_mochi_builtin(machine, "storage_get", export_args[..]);
    t.assert_true(absent_ok);
    t.assert_eq("absent", vm::builtin_string_bytes(pool, scratch, absent));
}

fn test_drag_payload_validation_and_typed_command(t: goosetest::Test&) {
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
    var count: i64 = 0;
    let array = vm::builtin_array_new(machine.scratch);
    t.assert_true(vm::builtin_array_push(machine.pool, machine.scratch, array, vm::mrb_false()));
    t.assert_true(vm::builtin_array_push(machine.pool, machine.scratch, array, vm::mrb_nil()));
    t.assert_true(vm::drag_value_valid(machine, array, 0, count));
    t.assert_eq(3, count);

    count = 0;
    t.assert_false(vm::drag_value_valid(machine, vm::mrb_symbol(vm::intern_symbol("unsafe")), 0, count));
    t.assert_false(vm::drag_value_valid(machine, vm::scratch_alloc_string(machine.scratch, "ok"), 33, count));

    vm::host_reset();
    var outbox: u8[>..] = [];
    let args: vm::MrbValue[1] = [vm::mrb_false()];
    let result = vm::drag_api_command(machine, "drag_set_data", args[..], outbox, vm::mrb_fixnum(7));
    t.assert_true(vm::mrb_is_true(result));
    t.assert_true(outbox.len >= 7);
    t.assert_true(outbox[outbox.len - 7..] == "false}\n");
}

fn test_host_storage_subscribe_requires_instance(t: goosetest::Test&) {
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

    let sub_args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(scratch, "cowboy_theme"),
        vm::scratch_alloc_string(scratch, "on_theme"),
    ];
    let sub_val, sub_ok = vm::vm_call_mochi_builtin(machine, "storage_subscribe", sub_args[..]);
    t.assert_true(sub_ok);
    t.assert_true(vm::mrb_is_false(sub_val));
    t.assert_eq(0, vm::goose_vm_host_outbox().len);
}

fn test_global_subscription_owner_and_escaping(t: goosetest::Test&) {
    vm::abi_open();
    vm::host_reset();
    let args: vm::MrbValue[2] = [
        vm::scratch_alloc_string(vm::g_abi_scratch, "notice\""),
        vm::mrb_symbol(vm::intern_symbol("receive")),
    ];
    let missing_owner, handled = vm::vm_call_mochi_builtin(vm::g_abi_machine, "subscribe", args[..]);
    t.assert_true(handled);
    t.assert_true(vm::mrb_is_false(missing_owner));
    t.assert_eq(0, vm::host_outbox_bytes().len);
    vm::g_abi_machine.frames.push(vm::CallFrame {
            self_value: 42,
            ..
        });
    let subscribed, sub_handled = vm::vm_call_mochi_builtin(vm::g_abi_machine, "subscribe", args[..]);
    t.assert_true(sub_handled && vm::mrb_is_true(subscribed));
    var expected: u8[>..] = [];
    expected.append("{\"__host\":\"event_subscribe\",\"event\":\"notice\\\"\",");
    expected.append("\"callback\":\"receive\",\"instance\":\"42\"}\n");
    t.assert_eq(expected[..], vm::host_outbox_bytes());
    vm::host_clear_outbox();
    let unsubscribed, unsub_handled = vm::vm_call_mochi_builtin(vm::g_abi_machine, "unsubscribe", args[..]);
    t.assert_true(unsub_handled && vm::mrb_is_true(unsubscribed));
    expected.clear();
    expected.append("{\"__host\":\"event_unsubscribe\",\"event\":\"notice\\\"\",");
    expected.append("\"callback\":\"receive\",\"instance\":\"42\"}\n");
    t.assert_eq(expected[..], vm::host_outbox_bytes());
    vm::g_abi_machine.frames.clear();
    vm::host_reset();
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

fn test_pointer_commands_component_owner(t: goosetest::Test&) {
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

    // MochiPointer is a static facade; the component frame is lower in the
    // call stack and remains the owner attached to the host command.
    let class_id = vm::state_define_class(machine.pool, vm::intern_symbol("PointerOwner"),
        vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(machine.pool, class_id);
    t.assert_true(vm::state_register_component(machine.pool, instance));
    machine.frames.push(vm::CallFrame {
            self_value: instance,
            ..
        });
    machine.frames.push(vm::CallFrame {
            self_value: vm::mrb_fixnum(900),
            ..
        });
    let capture_args: vm::MrbValue[2] = [
        vm::mrb_fixnum(17),
        vm::scratch_alloc_string(scratch, "drag_handle"),
    ];
    let captured, capture_ok = vm::vm_call_mochi_builtin(machine, "pointer_capture", capture_args[..]);
    t.assert_true(capture_ok);
    t.assert_true(vm::mrb_is_true(captured));
    var expected: u8[>..] = [];
    expected.append("{\"__host\":\"pointer_capture\",\"pointer_id\":17,");
    expected.append("\"reference\":\"drag_handle\",\"instance\":\"");
    vm::mrb_format_fixnum(expected, instance as!i64);
    expected.append("\"}\n");
    t.assert_eq(expected[..], vm::host_outbox_bytes());

    vm::host_clear_outbox();
    let release_args: vm::MrbValue[1] = [vm::mrb_fixnum(17)];
    let released, release_ok = vm::vm_call_mochi_builtin(machine, "pointer_release", release_args[..]);
    t.assert_true(release_ok);
    t.assert_true(vm::mrb_is_true(released));
    expected.clear();
    expected.append("{\"__host\":\"pointer_release\",\"pointer_id\":17,");
    expected.append("\"reference\":\"\",\"instance\":\"");
    vm::mrb_format_fixnum(expected, instance as!i64);
    expected.append("\"}\n");
    t.assert_eq(expected[..], vm::host_outbox_bytes());
    machine.frames.clear();
    vm::host_reset();
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
    vm::goose_vm_set_route_info(
        "{\"path\":\"/logs/a b\",\"segments\":[\"logs\",\"a b\"],\"query\":{\"level\":\"warn\"},\"search\":\"level=warn\",\"hash\":false,\"href\":\"http://localhost/logs/a%20b?level=warn\"}");
    let empty: vm::MrbValue[0] = [];
    let route_val, route_ok = vm::vm_call_mochi_builtin(machine, "route", empty[..]);
    t.assert_true(route_ok);
    t.assert_eq("/queues", vm::builtin_string_bytes(pool, scratch, route_val));

    let info_val, info_ok = vm::vm_call_mochi_builtin(machine, "route_info", empty[..]);
    t.assert_true(info_ok);
    let path_key = vm::scratch_alloc_string(scratch, "path");
    t.assert_eq("/logs/a b", vm::builtin_string_bytes(
        pool, scratch, vm::builtin_hash_get(pool, scratch, info_val, path_key)));
    let query_key = vm::scratch_alloc_string(scratch, "query");
    let query = vm::builtin_hash_get(pool, scratch, info_val, query_key);
    let level_key = vm::scratch_alloc_string(scratch, "level");
    t.assert_eq("warn", vm::builtin_string_bytes(
        pool, scratch, vm::builtin_hash_get(pool, scratch, query, level_key)));

    let nav_args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "/costs")];
    let nav_val, nav_ok = vm::vm_call_mochi_builtin(machine, "navigate", nav_args[..]);
    t.assert_true(nav_ok);
    t.assert_eq("/costs", vm::builtin_string_bytes(pool, scratch, nav_val));
    t.assert_true(vm::goose_vm_host_outbox().len > 0);
    vm::goose_vm_clear_host_outbox();

    let replace_val, replace_ok = vm::vm_call_mochi_builtin(machine, "replace_route", nav_args[..]);
    t.assert_true(replace_ok);
    t.assert_eq("/costs", vm::builtin_string_bytes(pool, scratch, replace_val));
    t.assert_true(vm::goose_vm_host_outbox().len > 0);
    vm::goose_vm_clear_host_outbox();

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
