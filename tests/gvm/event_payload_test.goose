// Publication validates nested values before any receiver sees the payload.
namespace event_payload_test;

import math;

import goosetest;
import vm;

fn test_event_payload_preserves_supported_types(t: goosetest::Test&) {
    vm::abi_open();
    let payload = vm::builtin_hash_new(vm::g_abi_scratch);
    let values: vm::MrbValue[7] = [
        vm::mrb_nil(), vm::mrb_false(), vm::mrb_true(), vm::mrb_fixnum(-3),
        vm::num_from_i64(vm::g_abi_scratch, 9007199254740993),
        vm::num_from_f64(vm::g_abi_scratch, 1.25),
        vm::scratch_alloc_string(vm::g_abi_scratch, "hello"),
    ];
    let array = vm::builtin_array_new(vm::g_abi_scratch);
    for value in values {
        t.assert_true(vm::builtin_array_push(vm::g_abi_pool, vm::g_abi_scratch, array, value));
    }
    let key = vm::mrb_symbol(vm::intern_symbol("values"));
    t.assert_true(vm::builtin_hash_set(vm::g_abi_pool, vm::g_abi_scratch, payload, key, array));
    t.assert_true(vm::event_payload_valid(vm::g_abi_machine, payload));
}

fn test_event_payload_rejects_loss_and_cycles(t: goosetest::Test&) {
    vm::abi_open();
    let object = vm::scratch_alloc_instance(vm::g_abi_scratch, 0);
    t.assert_false(vm::event_payload_valid(vm::g_abi_machine, object));
    let infinity = vm::num_from_f64(vm::g_abi_scratch, INF);
    t.assert_false(vm::event_payload_valid(vm::g_abi_machine, infinity));
    let array = vm::builtin_array_new(vm::g_abi_scratch);
    t.assert_true(vm::builtin_array_push(vm::g_abi_pool, vm::g_abi_scratch, array, array));
    t.assert_false(vm::event_payload_valid(vm::g_abi_machine, array));
    var remaining: i64 = 0;
    t.assert_false(vm::event_payload_value_ok(vm::g_abi_machine, vm::mrb_nil(), 0, remaining));
}
