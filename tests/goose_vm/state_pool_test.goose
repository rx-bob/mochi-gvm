// Tests for the persistent state pool and deep scratch-to-state promotion.
//
// The tests build class and instance graphs in the state pool, assign scratch
// strings and nested scratch instances through `state_set_ivar`, reset the
// tick arena, and then verify that every promoted value still reads back.
namespace vm_state_pool_test;

import std;

import goosetest;
import vm;

fn test_state_classes_and_component_registration(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let base = vm::state_define_class(pool, 10, vm::NULL_CLASS_ID);
    let child = vm::state_define_class(pool, 20, base);
    t.assert_eq(0, base);
    t.assert_eq(1, child);
    t.assert_eq(10, vm::state_class_name_symbol(pool, base));
    t.assert_eq(vm::NULL_CLASS_ID, vm::state_class_superclass_id(pool, base));
    t.assert_eq(base, vm::state_class_superclass_id(pool, child));

    let instance = vm::state_alloc_instance(pool, child);
    t.assert_true(vm::mrb_is_state(instance));
    let object, object_ok = vm::state_object(pool, instance);
    t.assert_true(object_ok);
    t.assert_eq(child, object.class_index);

    t.assert_true(vm::state_register_component(pool, instance));
    t.assert_true(vm::state_register_component(pool, instance));
    t.assert_eq(1, vm::state_component_count(pool));
    t.assert_eq(instance, vm::state_component_at(pool, 0));
}

fn test_state_ivar_assignment_updates_existing_key(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);

    t.assert_true(vm::state_set_ivar(pool, scratch, instance, 5, vm::mrb_fixnum(1)));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, 5, vm::mrb_fixnum(2)));
    t.assert_eq(1, vm::state_ivar_count(pool));

    let value, found = vm::state_get_ivar(pool, instance, 5);
    t.assert_true(found);
    t.assert_eq(2, vm::mrb_fixnum_value(value));
}

fn test_promoted_ivar_string_survives_scratch_reset(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    let open = vm::scratch_alloc_string(scratch, "<span>");
    let close = vm::scratch_alloc_string(scratch, "</span>");
    let temporary = vm::scratch_concat_string(scratch, open, close);

    t.assert_true(vm::state_set_ivar(pool, scratch, instance, 11, temporary));
    let stored, found = vm::state_get_ivar(pool, instance, 11);
    t.assert_true(found);
    t.assert_true(vm::mrb_is_state(stored));
    t.assert_true(vm::state_string_bytes(pool, stored) == "<span></span>");

    vm::scratch_reset(scratch);
    t.assert_eq(0, vm::scratch_bytes_used(scratch));
    t.assert_eq(0, vm::scratch_object_count(scratch));
    let after, after_found = vm::state_get_ivar(pool, instance, 11);
    t.assert_true(after_found);
    t.assert_true(vm::state_string_bytes(pool, after) == "<span></span>");
}

fn test_promotion_is_deep_for_nested_instances(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 7, vm::NULL_CLASS_ID);
    let outer = vm::scratch_alloc_instance(scratch, class_id);
    let inner = vm::scratch_alloc_instance(scratch, class_id);
    let leaf = vm::scratch_alloc_string(scratch, "leaf");
    t.assert_true(vm::scratch_set_ivar(scratch, inner, 1, leaf));
    t.assert_true(vm::scratch_set_ivar(scratch, outer, 2, inner));

    let promoted = vm::promote_to_state(pool, scratch, outer);
    t.assert_true(vm::mrb_is_state(promoted));
    vm::scratch_reset(scratch);

    let inner_value, inner_ok = vm::state_get_ivar(pool, promoted, 2);
    t.assert_true(inner_ok);
    t.assert_true(vm::mrb_is_state(inner_value));
    let leaf_value, leaf_ok = vm::state_get_ivar(pool, inner_value, 1);
    t.assert_true(leaf_ok);
    t.assert_true(vm::state_string_bytes(pool, leaf_value) == "leaf");
}

fn test_promotion_keeps_state_and_immediates(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let state_string = vm::state_alloc_string(pool, "durable");
    let state_objects = vm::state_object_count(pool);
    let state_bytes = vm::state_bytes_used(pool);

    t.assert_eq(state_string, vm::promote_to_state(pool, scratch, state_string));
    let fixnum = vm::mrb_fixnum(9);
    t.assert_eq(fixnum, vm::promote_to_state(pool, scratch, fixnum));
    t.assert_eq(state_objects, vm::state_object_count(pool));
    t.assert_eq(state_bytes, vm::state_bytes_used(pool));
}

fn test_state_rejects_non_instance_receivers(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);

    t.assert_false(vm::state_set_ivar(pool, scratch, vm::mrb_nil(), 1, vm::mrb_nil()));
    t.assert_false(vm::state_register_component(pool, vm::mrb_nil()));
    let _, found = vm::state_get_ivar(pool, vm::mrb_nil(), 1);
    t.assert_false(found);
    t.assert_true(vm::state_string_bytes(pool, vm::mrb_nil()) == "");
    t.assert_eq(0, vm::state_ivar_count(pool));
    t.assert_true(vm::mrb_is_state(instance));
}
