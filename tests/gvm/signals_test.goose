// Tests for u64 bitmask signals on component instance variables.
//
// The tests cover the two directions of the mask: reads of the tracked
// instance OR slot bits into `active_read_mask`, stores OR changed bits into
// the instance's `dirty_ivars`, and equal values (including equal state string
// bytes) leave the dirty mask untouched. Collection tests prove that in-place
// array and hash mutations dirty the ivar that owns them, including through
// nested collections.
namespace vm_signals_test;

import std;

import goosetest;
import vm;

let COUNT_KEY: u32 = 1;
let LABEL_KEY: u32 = 2;
let ITEMS_KEY: u32 = 3;
let DONE_KEY: u32 = 4;
let MISSING_KEY: u32 = 5;

// Reads two ivars from a nested helper to prove tracking is not limited to the
// immediate caller of `state_get_ivar`.
fn read_count_and_label(pool: vm::StatePool&, instance: vm::MrbValue) -> i64 {
    let count, count_ok = vm::state_get_ivar(pool, instance, COUNT_KEY);
    let label, label_ok = vm::state_get_ivar(pool, instance, LABEL_KEY);
    if !count_ok || !label_ok {
        return -1;
    }
    return vm::mrb_fixnum_value(count) + vm::mrb_fixnum_value(label);
}

fn test_tracked_reads_set_active_bits(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    let other = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(2)));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, LABEL_KEY, vm::mrb_fixnum(3)));
    t.assert_true(vm::state_set_ivar(pool, scratch, other, COUNT_KEY, vm::mrb_fixnum(9)));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, COUNT_KEY));
    t.assert_eq(1, vm::state_ivar_bit_index(pool, instance, LABEL_KEY));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_tracking_begin(pool, instance));
    t.assert_eq(5, read_count_and_label(pool, instance));
    let mask = vm::state_tracking_end(pool);
    t.assert_eq(vm::state_ivar_bit(0), mask & vm::state_ivar_bit(0));
    t.assert_eq(vm::state_ivar_bit(1), mask & vm::state_ivar_bit(1));
    t.assert_eq(0, mask & vm::state_ivar_bit(2));
    t.assert_eq(3, mask);

    t.assert_true(vm::state_tracking_begin(pool, instance));
    let foreign, foreign_found = vm::state_get_ivar(pool, other, COUNT_KEY);
    t.assert_true(foreign_found);
    t.assert_eq(9, vm::mrb_fixnum_value(foreign));
    t.assert_eq(0, vm::state_tracking_end(pool));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_eq(0, vm::state_tracked_read_mask(pool));
    t.assert_false(vm::state_tracking_begin(pool, vm::mrb_nil()));
}

fn test_noop_assignment_keeps_dirty_mask_empty(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(0)));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    let current, found = vm::state_get_ivar(pool, instance, COUNT_KEY);
    t.assert_true(found);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, current));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(1)));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

fn test_string_assignments_compare_state_bytes(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "same")));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, LABEL_KEY));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "same")));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "different")));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

fn test_uninitialized_ivar_read_is_tracked(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_tracking_begin(pool, instance));

    let value, found = vm::state_get_ivar(pool, instance, MISSING_KEY);
    t.assert_false(found);
    t.assert_true(vm::mrb_is_nil(value));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_tracked_read_mask(pool));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, MISSING_KEY));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_eq(1, vm::state_ivar_count(pool));
    vm::state_tracking_end(pool);

    let _, second_found = vm::state_get_ivar(pool, instance, MISSING_KEY);
    t.assert_true(second_found);
    t.assert_eq(1, vm::state_ivar_count(pool));
}

fn test_nested_hash_mutation_dirties_owner(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let items = vm::state_alloc_array(pool);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, items));
    let items_bit = vm::state_ivar_bit_index(pool, instance, ITEMS_KEY)as u8;
    t.assert_eq(0, items_bit);
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_array_push(pool, items, vm::mrb_fixnum(1)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    let entry = vm::state_alloc_hash(pool);
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_push(pool, items, entry));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_false()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_false()));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_true()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_set(pool, items, 1, entry));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_set(pool, items, 0, vm::mrb_fixnum(2)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    let popped, pop_ok = vm::state_array_pop(pool, items);
    t.assert_true(pop_ok);
    t.assert_true(vm::mrb_value_identical(popped, entry));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
}

fn test_collection_mutation_outside_component(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    let owned = vm::state_alloc_array(pool);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, owned));
    t.assert_true(vm::state_register_component(pool, instance));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    let orphan = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, orphan, vm::mrb_fixnum(1)));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_array_push(pool, owned, orphan));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_push(pool, orphan, vm::mrb_fixnum(2)));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

// Exercises the builtin helpers that the OP_SETIDX and Array#<< handlers call.
fn test_builtin_set_index_dirties_owner(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let items = vm::state_alloc_array(pool);
    let entry = vm::state_alloc_hash(pool);
    t.assert_true(vm::state_array_push(pool, items, entry));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, items));
    let items_bit = vm::state_ivar_bit_index(pool, instance, ITEMS_KEY)as u8;
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::builtin_set_index(pool, scratch, entry, DONE_KEY, vm::mrb_true()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::builtin_array_push(pool, scratch, items, vm::mrb_fixnum(7)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
}
