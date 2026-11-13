// Capacity rejection must preserve loaded programs and release failed entry roots.
namespace abi_capacity_test;

import std;

import goosetest;
import tests.gvm.abi_test;
import vm;

fn counter(t: goosetest::Test&) -> u64 {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(vm_abi_test::counter_rite()));
    let class = vm::abi_const_get(vm::intern_symbol("Counter"));
    return vm::abi_obj_new(vm::mrb_class_id(class));
}

fn assert_recovered(t: goosetest::Test&, instance: u64) {
    t.assert_eq(0, vm::g_abi_machine.frames.len);
    t.assert_eq(0, vm::g_abi_machine.regs.len);
    t.assert_eq(0, vm::g_abi_machine.entry_args.len);
    t.assert_eq(0, vm::g_abi_machine.scratch_roots.len);
    t.assert_eq(0, vm::g_abi_scratch.objects.len);
    vm::abi_call(instance, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error(), "loaded class and unrelated component survive");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn oversized_array() -> u8[>..] {
    var json = str("[");
    for i in vm::SCRATCH_CAPACITY_OBJECTS {
        if i > 0 {
            json.push(',');
        }
        json.append("\"x\"");
    }
    json.push(']');
    return json;
}

fn test_json_capacity_recovery(t: goosetest::Test&) {
    let instance = counter(t);
    let json = str("[", oversized_array(), "]");
    vm::abi_call_json(instance, vm::intern_symbol("increment"), json);
    t.assert_true(vm::abi_has_error());
    t.assert_true(starts_with(vm::abi_last_error(), "Counter#increment: scratch objects exhausted"));
    t.assert_eq(vm::SCRATCH_CAPACITY_OBJECTS, vm::g_abi_machine.error_context.capacity_limit);
    assert_recovered(t, instance);
}

fn test_props_rejection_disposes_mount(t: goosetest::Test&) {
    let instance = counter(t);
    let class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let props = str("{\"rows\":", oversized_array(), "}");
    let rejected = vm::abi_obj_new_with_props(vm::mrb_class_id(class), props);
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(starts_with(vm::abi_last_error(), "Counter: scratch objects exhausted"));
    t.assert_eq(1, vm::abi_component_count(), "failed mount removed only its registration");
    assert_recovered(t, instance);
}

fn test_bytecode_rejection_preserves_program(t: goosetest::Test&) {
    let instance = counter(t);
    let previous = vm::g_abi_file.data.len;
    var bytes: u8[>..] = [];
    bytes.resize(vm::ABI_MAX_BYTECODE + 1, 0);
    t.assert_eq(1, vm::abi_load_irep(bytes));
    t.assert_true(starts_with(vm::abi_last_error(), "ABI bytecode bytes exhausted"));
    t.assert_eq(previous, vm::g_abi_file.data.len);
    assert_recovered(t, instance);
}

fn test_failed_flush_discards_prior_patches(t: goosetest::Test&) {
    let instance = counter(t);
    t.assert_eq(0, vm::abi_register_binding(instance, 1, vm::intern_symbol("html")));
    t.assert_eq(0, vm::abi_register_binding(instance, 2, vm::intern_symbol("missing_getter")));
    t.assert_eq(0, vm::abi_register_binding(instance, 3, vm::intern_symbol("html")));
    t.assert_eq(-1, vm::abi_flush_patches(instance));
    t.assert_eq(0, vm::abi_patch_bytes().len, "earlier successful getters must not leak a partial batch");
    t.assert_true(starts_with(vm::abi_last_error(), "Counter#missing_getter (binding 2)"));
    vm::binding_unregister_all(vm::g_abi_pool, instance);
    t.assert_eq(0, vm::abi_register_binding(instance, 1, vm::intern_symbol("html")));
    t.assert_eq(1, vm::abi_flush_patches(instance));
    t.assert_true(vm::abi_patch_bytes().len > 0);
    vm::vm_end_entry(vm::g_abi_machine);
    assert_recovered(t, instance);
}
