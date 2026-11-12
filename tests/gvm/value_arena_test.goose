// Tests for the 64-bit MrbValue layout and the fixed tick scratch arena.
//
// The tests prove three boundaries of the two-zone design: immediates never
// touch arena storage, arena handles round-trip their zone and 31-bit index,
// and ten thousand allocate/reset cycles keep the fixed arena at one tick's
// worth of live bytes.
namespace vm_value_arena_test;

import std;

import goosetest;
import vm;

fn test_value_tags_cover_every_immediate(t: goosetest::Test&) {
    t.assert_eq(vm::MRB_TAG_NIL, vm::mrb_value_tag(vm::mrb_nil()));
    t.assert_eq(vm::MRB_TAG_FALSE, vm::mrb_value_tag(vm::mrb_false()));
    t.assert_eq(vm::MRB_TAG_TRUE, vm::mrb_value_tag(vm::mrb_true()));
    t.assert_eq(vm::MRB_TAG_FIXNUM, vm::mrb_value_tag(vm::mrb_fixnum(7)));
    t.assert_eq(vm::MRB_TAG_SYMBOL, vm::mrb_value_tag(vm::mrb_symbol(7)));
    t.assert_eq(vm::MRB_TAG_CLASS, vm::mrb_value_tag(vm::mrb_class(7)));
    t.assert_eq(vm::MRB_TAG_ARENA, vm::mrb_value_tag(vm::mrb_arena_value(vm::MRB_ARENA_STATE, 7)));
    t.assert_true(vm::mrb_value_identical(vm::mrb_nil(), vm::mrb_nil()));
    t.assert_false(vm::mrb_value_identical(vm::mrb_nil(), vm::mrb_false()));
}

fn test_immediates_round_trip_without_arena_bytes(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let scratch_bytes = vm::scratch_bytes_used(scratch);
    let scratch_objects = vm::scratch_object_count(scratch);
    let state_bytes = vm::state_bytes_used(pool);
    let state_objects = vm::state_object_count(pool);

    t.assert_true(vm::mrb_is_nil(vm::mrb_nil()));
    t.assert_true(vm::mrb_is_false(vm::mrb_false()));
    t.assert_true(vm::mrb_is_true(vm::mrb_true()));
    t.assert_eq(vm::mrb_false(), vm::mrb_bool(false));
    t.assert_eq(vm::mrb_true(), vm::mrb_bool(true));

    let numbers: i64[6] = [-2147483648, -1, 0, 1, 42, 2147483647];
    for number in numbers {
        let value = vm::mrb_fixnum(number);
        t.assert_true(vm::mrb_is_fixnum(value));
        t.assert_eq(number, vm::mrb_fixnum_value(value));
        t.assert_eq(value, vm::mrb_fixnum(vm::mrb_fixnum_value(value)));
    }

    let symbols: u32[3] = [0, 42, vm::NULL_SYMBOL];
    for symbol in symbols {
        let value = vm::mrb_symbol(symbol);
        t.assert_true(vm::mrb_is_symbol(value));
        t.assert_eq(symbol, vm::mrb_symbol_id(value));
        t.assert_eq(value, vm::mrb_symbol(vm::mrb_symbol_id(value)));
    }

    let classes: u32[3] = [0, 7, 1024];
    for class_id in classes {
        let value = vm::mrb_class(class_id);
        t.assert_true(vm::mrb_is_class(value));
        t.assert_eq(class_id, vm::mrb_class_id(value));
        t.assert_eq(value, vm::mrb_class(vm::mrb_class_id(value)));
    }

    t.assert_eq(scratch_bytes, vm::scratch_bytes_used(scratch));
    t.assert_eq(scratch_objects, vm::scratch_object_count(scratch));
    t.assert_eq(state_bytes, vm::state_bytes_used(pool));
    t.assert_eq(state_objects, vm::state_object_count(pool));
}

fn test_truthiness_matches_mruby(t: goosetest::Test&) {
    t.assert_false(vm::mrb_truthy(vm::mrb_nil()));
    t.assert_false(vm::mrb_truthy(vm::mrb_false()));
    t.assert_true(vm::mrb_truthy(vm::mrb_true()));
    t.assert_true(vm::mrb_truthy(vm::mrb_fixnum(0)));
    t.assert_true(vm::mrb_truthy(vm::mrb_symbol(0)));
    t.assert_true(vm::mrb_truthy(vm::mrb_class(0)));
}

fn test_arena_handle_layout(t: goosetest::Test&) {
    let scratch_handle = vm::mrb_arena_value(vm::MRB_ARENA_SCRATCH, 123);
    t.assert_true(vm::mrb_is_scratch(scratch_handle));
    t.assert_false(vm::mrb_is_state(scratch_handle));
    t.assert_eq(vm::MRB_ARENA_SCRATCH, vm::mrb_arena_tag(scratch_handle));
    t.assert_eq(123, vm::mrb_arena_index(scratch_handle));

    let state_handle = vm::mrb_arena_value_versioned(vm::MRB_ARENA_STATE, 32767, 60000);
    t.assert_true(vm::mrb_is_state(state_handle));
    t.assert_false(vm::mrb_is_scratch(state_handle));
    t.assert_eq(vm::MRB_ARENA_STATE, vm::mrb_arena_tag(state_handle));
    t.assert_eq(32767, vm::mrb_arena_index(state_handle));
    t.assert_eq(60000, vm::mrb_arena_generation(state_handle));
}

fn test_boxed_numeric_handles_roundtrip(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let low = vm::scratch_alloc_int64(scratch, vm::NUM_I64_MIN);
    let high = vm::scratch_alloc_int64(scratch, vm::NUM_I64_MAX);
    let fraction = vm::scratch_alloc_float(scratch, -0.5);
    let negative_zero = vm::scratch_alloc_float(scratch, -0.0);

    t.assert_eq(vm::MRB_TAG_INT64, vm::mrb_value_tag(low));
    t.assert_eq(vm::MRB_TAG_FLOAT, vm::mrb_value_tag(fraction));
    t.assert_true(vm::mrb_is_arena(low));
    t.assert_true(vm::mrb_is_scratch(low));
    t.assert_false(vm::mrb_is_state(low));
    t.assert_true(vm::mrb_value_kind_name(high) == "int64");
    t.assert_true(vm::mrb_value_kind_name(fraction) == "float");

    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let minimum, minimum_ok = vm::num_integer_value(scratch, pool, low);
    let maximum, maximum_ok = vm::num_integer_value(scratch, pool, high);
    let decimal, decimal_ok = vm::num_float_value(scratch, pool, fraction);
    let zero, zero_ok = vm::num_float_value(scratch, pool, negative_zero);
    t.assert_true(minimum_ok);
    t.assert_true(maximum_ok);
    t.assert_true(decimal_ok);
    t.assert_true(zero_ok);
    t.assert_eq(vm::NUM_I64_MIN, minimum);
    t.assert_eq(vm::NUM_I64_MAX, maximum);
    t.assert_eq(-0.5, decimal);
    t.assert_true(zero == 0.0);
    t.assert_eq(4, vm::scratch_object_count(scratch));
    t.assert_eq(0, vm::scratch_bytes_used(scratch));

    vm::scratch_reset(scratch);
    t.assert_eq(0, vm::scratch_object_count(scratch));
}

fn test_scratch_string_round_trips_and_reset(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let value = vm::scratch_alloc_string(scratch, "hello");
    t.assert_true(vm::mrb_is_scratch(value));
    t.assert_true(vm::scratch_is_string(scratch, value));
    t.assert_true(vm::scratch_string_bytes(scratch, value) == "hello");
    t.assert_eq(5, vm::scratch_bytes_used(scratch));
    t.assert_eq(1, vm::scratch_object_count(scratch));

    vm::scratch_reset(scratch);
    t.assert_eq(0, vm::scratch_bytes_used(scratch));
    t.assert_eq(0, vm::scratch_object_count(scratch));
    t.assert_eq(1, scratch.reset_count);
    t.assert_eq(1, scratch.allocated_objects_total);
    t.assert_eq(5, scratch.allocated_bytes_total);
}

fn test_ten_thousand_scratch_resets(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var max_bytes = 0;
    var max_objects = 0;
    for _ in 10000 {
        let value = vm::scratch_alloc_string(scratch, "tick");
        assert(vm::scratch_string_bytes(scratch, value) == "tick");
        let used = vm::scratch_bytes_used(scratch);
        let objects = vm::scratch_object_count(scratch);
        if used > max_bytes {
            max_bytes = used;
        }
        if objects > max_objects {
            max_objects = objects;
        }
        vm::scratch_reset(scratch);
        assert(vm::scratch_bytes_used(scratch) == 0);
        assert(vm::scratch_object_count(scratch) == 0);
    }
    t.assert_eq(4, max_bytes);
    t.assert_eq(1, max_objects);
    t.assert_eq(10000, scratch.reset_count);
    t.assert_eq(10000, scratch.allocated_objects_total);
    t.assert_eq(40000, scratch.allocated_bytes_total);
    t.assert_eq(vm::SCRATCH_CAPACITY_BYTES, scratch.blob.cap);
    t.assert_eq(vm::SCRATCH_CAPACITY_OBJECTS, scratch.objects.cap);
    t.assert_eq(vm::SCRATCH_CAPACITY_IVARS, scratch.ivars.cap);
}

fn test_scratch_concat_allocates_a_new_string(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let left = vm::scratch_alloc_string(scratch, "<span>");
    let right = vm::scratch_alloc_string(scratch, "2</span>");
    let joined = vm::scratch_concat_string(scratch, left, right);
    t.assert_true(vm::scratch_string_bytes(scratch, joined) == "<span>2</span>");
    t.assert_true(vm::scratch_string_bytes(scratch, left) == "<span>");
    t.assert_eq(3, vm::scratch_object_count(scratch));
}

fn test_scratch_rejects_foreign_handles(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let _, nil_ok = vm::scratch_object(scratch, vm::mrb_nil());
    t.assert_false(nil_ok);

    let state_handle = vm::mrb_arena_value(vm::MRB_ARENA_STATE, 0);
    let _, state_ok = vm::scratch_object(scratch, state_handle);
    t.assert_false(state_ok);

    let missing = vm::mrb_arena_value(vm::MRB_ARENA_SCRATCH, 99);
    let _, missing_ok = vm::scratch_object(scratch, missing);
    t.assert_false(missing_ok);
    t.assert_true(vm::scratch_string_bytes(scratch, missing) == "");
    t.assert_false(vm::scratch_is_instance(scratch, missing));
}
