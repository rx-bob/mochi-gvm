// Tests for non-moving mark/sweep reclamation in the persistent state pool.
//
// Each test builds a small machine, registers components and values through the
// public state helpers, then drives `gc_collect` or `gc_maybe_collect` at the
// same boundaries the interpreter uses.
namespace vm_state_reclaim_test;

import std;

import goosetest;
import vm;

fn reclaim_machine(machine: vm::Vm&) -> i64 {
    return vm::gc_collect(machine);
}

fn test_gc_reclaims_stale_string_and_reuses_bytes(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let first = vm::state_alloc_string(pool, "hello");
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(instance), 1, first));

    let _, live_ok = vm::state_object(pool, first);
    t.assert_true(live_ok);
    let freed = reclaim_machine(machine);
    t.assert_eq(0, freed);
    t.assert_true(vm::state_string_bytes(pool, first) == "hello");

    let second = vm::state_alloc_string(pool, "world");
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(instance), 1, second));
    let high_water = vm::state_object_count(pool);
    t.assert_eq(1, reclaim_machine(machine));
    let _, old_ok = vm::state_object(pool, first);
    t.assert_false(old_ok);
    t.assert_eq(2, vm::state_allocated_object_count(pool));
    t.assert_eq(5, vm::state_free_byte_count(pool));

    let third = vm::state_alloc_string(pool, "again");
    t.assert_eq(high_water, vm::state_object_count(pool));
    t.assert_eq(0, vm::state_free_byte_count(pool));
    t.assert_true(vm::state_string_bytes(pool, third) == "again");
    let _, third_ok = vm::state_object(pool, third);
    t.assert_true(third_ok);
}

fn test_gc_shared_collection_survives_one_disposal(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let first = vm::state_alloc_instance(pool, class_id);
    let second = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, first));
    t.assert_true(vm::state_register_component(pool, second));
    let shared = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, shared, vm::mrb_fixnum(7)));
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(first), 1, shared));
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(second), 1, shared));

    t.assert_true(vm::vm_dispose_instance(machine, first));
    let _, shared_ok = vm::state_object(pool, shared);
    t.assert_true(shared_ok);
    t.assert_eq(1, vm::state_component_count(pool));
    let value, found = vm::state_array_get(pool, shared, 0);
    t.assert_true(found);
    t.assert_eq(7, vm::mrb_fixnum_value(value));

    t.assert_true(vm::vm_dispose_instance(machine, second));
    let _, gone = vm::state_object(pool, shared);
    t.assert_false(gone);
    t.assert_eq(0, vm::state_component_count(pool));
    t.assert_eq(0, vm::state_allocated_object_count(pool));
}

fn test_gc_self_reference_terminates_and_reclaims(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let array = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, array, array));
    machine.regs.push(array);
    t.assert_eq(0, reclaim_machine(machine));
    let _, live_ok = vm::state_object(pool, array);
    t.assert_true(live_ok);
    machine.regs.clear();
    t.assert_eq(1, reclaim_machine(machine));
    let _, gone = vm::state_object(pool, array);
    t.assert_false(gone);
}

fn test_gc_mutual_cycle_reclaims_after_root_removed(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let left = vm::state_alloc_array(pool);
    let right = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, left, right));
    t.assert_true(vm::state_array_push(pool, right, left));
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(instance), 1, left));

    t.assert_eq(0, reclaim_machine(machine));
    t.assert_eq(3, vm::state_allocated_object_count(pool));
    t.assert_true(vm::vm_dispose_instance(machine, instance));
    t.assert_eq(0, vm::state_allocated_object_count(pool));
    let _, left_ok = vm::state_object(pool, left);
    t.assert_false(left_ok);
}

fn test_gc_marks_constant_and_argument_roots(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let constant = vm::state_alloc_string(pool, "const");
    vm::state_set_const(pool, scratch, 2, constant);
    let registered = vm::state_alloc_string(pool, "reg");
    machine.regs.push(registered);
    let temporary = vm::state_alloc_string(pool, "arg");
    machine.entry_args.push(temporary);

    t.assert_eq(0, reclaim_machine(machine));
    let _, constant_ok = vm::state_object(pool, constant);
    let _, register_ok = vm::state_object(pool, registered);
    let _, argument_ok = vm::state_object(pool, temporary);
    t.assert_true(constant_ok);
    t.assert_true(register_ok);
    t.assert_true(argument_ok);

    machine.regs.clear();
    machine.entry_args.clear();
    pool.consts.clear();
    t.assert_eq(3, reclaim_machine(machine));
}

fn test_gc_reused_collection_accepts_mutation(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let old = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, old, vm::mrb_fixnum(1)));
    t.assert_true(vm::state_store_ivar_raw(pool, vm::mrb_arena_index(instance), 1, old));
    t.assert_true(vm::vm_dispose_instance(machine, instance));
    let _, old_ok = vm::state_object(pool, old);
    t.assert_false(old_ok);

    let fresh = vm::state_alloc_array(pool);
    t.assert_false(vm::mrb_value_identical(old, fresh));
    t.assert_eq(vm::mrb_arena_index(old), vm::mrb_arena_index(fresh));
    t.assert_true(vm::state_array_push(pool, fresh, vm::mrb_fixnum(2)));
    t.assert_true(vm::state_array_push(pool, fresh, vm::mrb_fixnum(3)));
    t.assert_eq(2, vm::state_array_length(pool, fresh));
    let value, found = vm::state_array_get(pool, fresh, 1);
    t.assert_true(found);
    t.assert_eq(3, vm::mrb_fixnum_value(value));
}

fn test_gc_thousand_replacements_stay_bounded(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let index = vm::mrb_arena_index(instance);
    var update = 0;
    while update < 1000 {
        let value = vm::state_alloc_string(pool, "replacement");
        t.assert_true(vm::state_store_ivar_raw(pool, index, 1, value));
        vm::gc_maybe_collect(machine);
        update += 1;
    }
    let final_freed = reclaim_machine(machine);
    t.assert_true(final_freed >= 0);
    // High-water stays within the live graph plus one collection interval; the
    // free list, not unbounded growth, serves the remaining updates.
    t.assert_true(vm::state_object_count(pool) <= 2 + vm::GC_ALLOCATION_INTERVAL);
    t.assert_eq(2, vm::state_allocated_object_count(pool));
    t.assert_true(vm::state_ivar_count(pool) <= 1);
    let stored, found = vm::state_get_ivar(pool, instance, 1);
    t.assert_true(found);
    t.assert_true(vm::state_string_bytes(pool, stored) == "replacement");
}

fn test_gc_reuses_ivar_and_slot_storage(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let first = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, first));
    var index = 0;
    while index < 100 {
        t.assert_true(vm::state_set_ivar(pool, scratch, first, index as u32,
            vm::mrb_fixnum(index)));
        index += 1;
    }
    let array = vm::state_alloc_array(pool);
    index = 0;
    while index < 10 {
        t.assert_true(vm::state_array_push(pool, array, vm::mrb_fixnum(index)));
        index += 1;
    }
    t.assert_eq(100, vm::state_ivar_count(pool));
    t.assert_eq(10, vm::state_slot_count(pool));
    t.assert_true(vm::vm_dispose_instance(machine, first));
    t.assert_eq(0, vm::state_allocated_object_count(pool));

    let second = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, second));
    index = 0;
    while index < 100 {
        t.assert_true(vm::state_set_ivar(pool, scratch, second, index as u32,
            vm::mrb_fixnum(index + 1)));
        index += 1;
    }
    let fresh = vm::state_alloc_array(pool);
    index = 0;
    while index < 10 {
        t.assert_true(vm::state_array_push(pool, fresh, vm::mrb_fixnum(index)));
        index += 1;
    }
    t.assert_eq(100, vm::state_ivar_count(pool));
    t.assert_eq(10, vm::state_slot_count(pool));
    let last, found = vm::state_get_ivar(pool, second, 99);
    t.assert_true(found);
    t.assert_eq(100, vm::mrb_fixnum_value(last));
}
