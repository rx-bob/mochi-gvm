// Tests for the persistent state pool and deep scratch-to-state promotion.
//
// The tests build class and instance graphs in the state pool, assign scratch
// strings and nested scratch instances through `state_set_ivar`, reset the
// tick arena, and then verify that every promoted value still reads back.
namespace vm_state_pool_test;

import std;

import goosetest;
import vm;

// Promotion copies a fresh graph without publishing mutations. Once assigned,
// writes through a retained nested alias must still dirty the owning root.
fn test_promoted_graph_publication_and_alias(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("PromotionProbe"), vm::NULL_CLASS_ID);
    let owner = vm::state_alloc_instance(pool, class_id);
    vm::state_register_component(pool, owner);
    let root_key = vm::intern_symbol("@records");
    let initial = vm::state_alloc_array(pool);
    vm::state_set_ivar(pool, scratch, owner, root_key, initial);
    vm::state_clear_dirty_mask(pool, owner);
    let hash = vm::scratch_alloc_hash(scratch);
    let first_key = vm::mrb_symbol(vm::intern_symbol("first"));
    let second_key = vm::mrb_symbol(vm::intern_symbol("second"));
    vm::scratch_hash_set(scratch, hash, first_key, vm::mrb_fixnum(1));
    vm::scratch_hash_set(scratch, hash, second_key, vm::mrb_fixnum(2));
    vm::scratch_hash_set(scratch, hash, first_key, vm::mrb_fixnum(3));
    let array = vm::scratch_alloc_array(scratch);
    vm::scratch_array_push(scratch, array, hash);
    vm::scratch_array_push(scratch, array, initial);
    let promoted = vm::promote_to_state(pool, scratch, array);
    t.assert_eq(vm::VmError.Ok, pool.error);
    t.assert_true(vm::mask_is_empty(vm::state_dirty_mask(pool, owner)));
    vm::scratch_reset(scratch);
    let nested, _ = vm::state_array_get(pool, promoted, 0);
    let alias, _ = vm::state_array_get(pool, promoted, 1);
    t.assert_true(vm::mrb_value_identical(initial, alias));
    let value, _ = vm::state_hash_get(pool, nested, first_key);
    t.assert_eq(3, vm::mrb_fixnum_value(value));
    let object, _ = vm::state_object(pool, nested);
    t.assert_eq(2, object.item_count);
    t.assert_true(vm::mrb_value_identical(first_key, pool.slots[object.items_first_index].key));
    t.assert_true(vm::mrb_value_identical(second_key, pool.slots[object.items_last_index].key));
    vm::state_set_ivar(pool, scratch, owner, root_key, promoted);
    t.assert_false(vm::mask_is_empty(vm::state_dirty_mask(pool, owner)));
    vm::state_clear_dirty_mask(pool, owner);
    vm::state_hash_set(pool, nested, first_key, vm::mrb_fixnum(4));
    t.assert_false(vm::mask_is_empty(vm::state_dirty_mask(pool, owner)));
}

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

fn test_state_unregister_component_is_safe(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let class_id = vm::state_define_class(pool, 30, vm::NULL_CLASS_ID);
    let first = vm::state_alloc_instance(pool, class_id);
    let second = vm::state_alloc_instance(pool, class_id);
    let third = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, first));
    t.assert_true(vm::state_register_component(pool, second));
    t.assert_true(vm::state_register_component(pool, third));

    t.assert_true(vm::state_unregister_component(pool, second));
    t.assert_eq(2, vm::state_component_count(pool));
    t.assert_eq(first, vm::state_component_at(pool, 0));
    t.assert_eq(third, vm::state_component_at(pool, 1));

    t.assert_false(vm::state_unregister_component(pool, second));
    t.assert_true(vm::state_mark_instance_disposed(pool, second));
    t.assert_true(vm::state_instance_disposed(pool, second));
    t.assert_false(vm::state_instance_disposed(pool, first));
    t.assert_true(vm::state_mark_instance_disposed(pool, second));
    t.assert_false(vm::state_mark_instance_disposed(pool, vm::mrb_nil()));
}

fn test_state_hash_updates_existing_symbol_key(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let hash = vm::state_alloc_hash(pool);
    let id_key = vm::mrb_symbol(8);
    let text_key = vm::mrb_symbol(9);
    let done_key = vm::mrb_symbol(10);
    t.assert_true(vm::state_hash_set(pool, hash, id_key, vm::mrb_fixnum(1)));
    t.assert_true(vm::state_hash_set(pool, hash, text_key, vm::mrb_fixnum(2)));
    t.assert_true(vm::state_hash_set(pool, hash, done_key, vm::mrb_false()));
    t.assert_eq(3, vm::state_hash_length(pool, hash));
    t.assert_true(vm::state_hash_set(pool, hash, done_key, vm::mrb_true()));
    t.assert_eq(3, vm::state_hash_length(pool, hash));
    let value, found = vm::state_hash_get(pool, hash, done_key);
    t.assert_true(found);
    t.assert_true(vm::mrb_is_true(value));
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

fn test_promotion_copies_boxed_numbers(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let wide = vm::scratch_alloc_int64(scratch, 9007199254740993);
    let fraction = vm::scratch_alloc_float(scratch, 0.25);
    let array = vm::scratch_alloc_array(scratch);
    t.assert_true(vm::scratch_array_push(scratch, array, wide));
    t.assert_true(vm::scratch_array_push(scratch, array, fraction));

    let durable = vm::promote_to_state(pool, scratch, array);
    t.assert_true(vm::mrb_is_state(durable));
    let stored_wide = vm::state_array_get(pool, durable, 0);
    let stored_fraction = vm::state_array_get(pool, durable, 1);
    t.assert_eq(vm::MRB_TAG_INT64, vm::mrb_value_tag(stored_wide));
    t.assert_eq(vm::MRB_TAG_FLOAT, vm::mrb_value_tag(stored_fraction));
    vm::scratch_reset(scratch);

    let integer, integer_ok = vm::num_integer_value(scratch, pool, stored_wide);
    let float, float_ok = vm::num_float_value(scratch, pool, stored_fraction);
    t.assert_true(integer_ok);
    t.assert_true(float_ok);
    t.assert_eq(9007199254740993, integer);
    t.assert_eq(0.25, float);
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

fn test_logs_ring_1000_bounded_updates(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let retained = vm::state_alloc_array(pool);
    var sequence = 1;
    var initialized = true;
    while sequence <= 2000 {
        initialized = vm::state_array_push(pool, retained, vm::mrb_fixnum(sequence)) && initialized;
        sequence += 1;
    }
    t.assert_true(initialized);
    let object_count = vm::state_object_count(pool);

    var cursor = 0;
    var step = 0;
    var updated = true;
    while step < 1000 {
        updated = vm::state_array_set(
            pool, retained, cursor, vm::mrb_fixnum(2001 + step)) && updated;
        cursor = (cursor + 1) % 2000;
        step += 1;
    }

    t.assert_true(updated);
    t.assert_eq(2000, vm::state_array_length(pool, retained));
    t.assert_eq(object_count, vm::state_object_count(pool));
    let oldest, oldest_found = vm::state_array_get(pool, retained, cursor);
    let newest, newest_found = vm::state_array_get(pool, retained, cursor - 1);
    t.assert_true(oldest_found);
    t.assert_true(newest_found);
    t.assert_eq(1001, vm::mrb_fixnum_value(oldest));
    t.assert_eq(3000, vm::mrb_fixnum_value(newest));
}
