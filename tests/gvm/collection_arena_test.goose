// Tests for tick-scoped Array and Hash storage.
namespace vm_collection_arena_test;

import std;

import goosetest;
import vm;

fn test_scratch_array_push_get_last_pop(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::scratch_alloc_array(scratch);
    t.assert_true(vm::scratch_is_array(scratch, array));
    t.assert_false(vm::scratch_is_hash(scratch, array));
    t.assert_eq(0, vm::scratch_array_length(scratch, array));

    t.assert_true(vm::scratch_array_push(scratch, array, vm::mrb_fixnum(10)));
    t.assert_true(vm::scratch_array_push(scratch, array, vm::mrb_fixnum(20)));
    t.assert_true(vm::scratch_array_push(scratch, array, vm::mrb_fixnum(30)));
    t.assert_eq(3, vm::scratch_array_length(scratch, array));
    t.assert_eq(3, vm::scratch_slot_count(scratch));

    let first, first_ok = vm::scratch_array_get(scratch, array, 0);
    let second, second_ok = vm::scratch_array_get(scratch, array, 1);
    let third, third_ok = vm::scratch_array_get(scratch, array, 2);
    t.assert_true(first_ok);
    t.assert_true(second_ok);
    t.assert_true(third_ok);
    t.assert_eq(10, vm::mrb_fixnum_value(first));
    t.assert_eq(20, vm::mrb_fixnum_value(second));
    t.assert_eq(30, vm::mrb_fixnum_value(third));
    let _, missing_ok = vm::scratch_array_get(scratch, array, 3);
    t.assert_false(missing_ok);
    let _, negative_ok = vm::scratch_array_get(scratch, array, -1);
    t.assert_false(negative_ok);

    t.assert_true(vm::scratch_array_set(scratch, array, 1, vm::mrb_fixnum(25)));
    let updated, updated_ok = vm::scratch_array_get(scratch, array, 1);
    t.assert_true(updated_ok);
    t.assert_eq(25, vm::mrb_fixnum_value(updated));
    t.assert_false(vm::scratch_array_set(scratch, array, 3, vm::mrb_fixnum(0)));

    let last, last_ok = vm::scratch_array_last(scratch, array);
    t.assert_true(last_ok);
    t.assert_eq(30, vm::mrb_fixnum_value(last));

    let popped, popped_ok = vm::scratch_array_pop(scratch, array);
    t.assert_true(popped_ok);
    t.assert_eq(30, vm::mrb_fixnum_value(popped));
    t.assert_eq(2, vm::scratch_array_length(scratch, array));
    let now_last, now_last_ok = vm::scratch_array_last(scratch, array);
    t.assert_true(now_last_ok);
    t.assert_eq(25, vm::mrb_fixnum_value(now_last));

    let first_pop, first_pop_ok = vm::scratch_array_pop(scratch, array);
    let second_pop, second_pop_ok = vm::scratch_array_pop(scratch, array);
    t.assert_true(first_pop_ok);
    t.assert_true(second_pop_ok);
    t.assert_eq(25, vm::mrb_fixnum_value(first_pop));
    t.assert_eq(10, vm::mrb_fixnum_value(second_pop));
    let _, empty_ok = vm::scratch_array_pop(scratch, array);
    t.assert_false(empty_ok);
    t.assert_eq(0, vm::scratch_array_length(scratch, array));
}

fn test_scratch_hash_keeps_insertion_order(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let hash = vm::scratch_alloc_hash(scratch);
    t.assert_true(vm::scratch_is_hash(scratch, hash));
    t.assert_false(vm::scratch_is_array(scratch, hash));

    let id = vm::mrb_symbol(7);
    let text = vm::mrb_symbol(8);
    t.assert_true(vm::scratch_hash_set(scratch, hash, id, vm::mrb_fixnum(1)));
    t.assert_true(vm::scratch_hash_set(scratch, hash, text, vm::mrb_fixnum(2)));
    t.assert_eq(2, vm::scratch_hash_length(scratch, hash));

    let found, found_ok = vm::scratch_hash_get(scratch, hash, id);
    t.assert_true(found_ok);
    t.assert_eq(1, vm::mrb_fixnum_value(found));
    let _, missing_ok = vm::scratch_hash_get(scratch, hash, vm::mrb_symbol(9));
    t.assert_false(missing_ok);

    t.assert_true(vm::scratch_hash_set(scratch, hash, id, vm::mrb_fixnum(11)));
    t.assert_eq(2, vm::scratch_hash_length(scratch, hash));
    t.assert_eq(2, vm::scratch_slot_count(scratch));
    let updated, updated_ok = vm::scratch_hash_get(scratch, hash, id);
    t.assert_true(updated_ok);
    t.assert_eq(11, vm::mrb_fixnum_value(updated));
}

fn test_scratch_reset_reclaims_collection_slots(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::scratch_alloc_array(scratch);
    t.assert_true(vm::scratch_array_push(scratch, array, vm::mrb_nil()));
    let hash = vm::scratch_alloc_hash(scratch);
    t.assert_true(vm::scratch_hash_set(scratch, hash, vm::mrb_symbol(1), vm::mrb_nil()));
    t.assert_eq(2, vm::scratch_slot_count(scratch));

    vm::scratch_reset(scratch);
    t.assert_eq(0, vm::scratch_slot_count(scratch));
    t.assert_false(vm::scratch_is_array(scratch, array));
    t.assert_false(vm::scratch_is_hash(scratch, hash));
}
