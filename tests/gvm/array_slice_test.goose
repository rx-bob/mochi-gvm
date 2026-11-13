// Ruby array indexing/slicing in both arenas, including bounded failure.
namespace vm_array_slice_test;

import std;

import goosetest;
import vm;

fn sequence(scratch: vm::ScratchArena&, count: i64) -> vm::MrbValue {
    let array = vm::scratch_alloc_array(scratch);
    for index in count {
        vm::scratch_array_push(scratch, array, vm::mrb_fixnum(index + 1));
    }
    return array;
}

fn test_slice_boundaries_match_ruby_in_both_zones(t: goosetest::Test&) {
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
    let original = sequence(scratch, 4);
    let persistent = vm::promote_to_state(pool, scratch, original);
    // start, length, result length (-1 means nil), first returned value.
    let cases: i64[4][11] = [
        [1, 2, 2, 2], [-2, 9, 2, 3], [-4, 2, 2, 1], [-5, 2, -1, 0],
        [0, -1, -1, 0], [1, 0, 0, 0], [4, 2, 0, 0], [4, 0, 0, 0],
        [5, 0, -1, 0], [0, 9223372036854775807, 4, 1],
        [-9223372036854775807 - 1, 2, -1, 0],
    ];
    for source in[original, persistent] {
        for name in["[]", "slice"] {
            for entry in cases {
                let args: vm::MrbValue[2] = [
                    vm::num_from_i64(scratch, entry[0]), vm::num_from_i64(scratch, entry[1]),
                ];
                let result, handled = vm::vm_call_array_builtin(machine, source, name, args[..]);
                t.assert_true(handled);
                t.assert_eq(vm::VmError.Ok, machine.error);
                if entry[2] < 0 {
                    t.assert_true(vm::mrb_is_nil(result));
                } else {
                    t.assert_true(vm::scratch_is_array(scratch, result));
                    t.assert_true(result != source);
                    t.assert_eq(entry[2], vm::scratch_array_length(scratch, result));
                    for index in entry[2] {
                        let value = vm::builtin_array_get(pool, scratch, result, index);
                        t.assert_eq(entry[3] + index, vm::mrb_fixnum_value(value));
                    }
                }
                t.assert_eq(4, vm::builtin_array_length(pool, scratch, source));
            }
            for index in[-5, -4, -1, 0, 3, 4, 9223372036854775807] {
                let args: vm::MrbValue[1] = [vm::num_from_i64(scratch, index)];
                let result, handled = vm::vm_call_array_builtin(machine, source, name, args[..]);
                t.assert_true(handled);
                if index < - 4 || index >= 4 {
                    t.assert_true(vm::mrb_is_nil(result));
                } else {
                    let expected = if index < 0 {
                        index + 5
                    } else {
                        index + 1
                    };
                    t.assert_eq(expected, vm::mrb_fixnum_value(result));
                }
            }
        }
    }
    let empty = sequence(scratch, 0);
    let empty_slice = vm::builtin_array_slice(pool, scratch, empty, 0, 4);
    t.assert_true(vm::scratch_is_array(scratch, empty_slice));
    t.assert_eq(0, vm::scratch_array_length(scratch, empty_slice));
    t.assert_true(vm::mrb_is_nil(vm::builtin_array_slice(pool, scratch, empty, 1, 0)));
}

fn test_fresh_shallow_slices_preserve_source(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let nested = vm::scratch_alloc_hash(scratch);
    let key = vm::mrb_symbol(1);
    vm::scratch_hash_set(scratch, nested, key, vm::mrb_fixnum(7));
    let original = vm::scratch_alloc_array(scratch);
    vm::scratch_array_push(scratch, original, nested);
    let persistent = vm::promote_to_state(pool, scratch, original);
    for source in[original, persistent] {
        let result = vm::builtin_array_slice(pool, scratch, source, 0, 1);
        let again = vm::builtin_array_slice(pool, scratch, source, 0, 1);
        t.assert_true(result != again);
        let source_child = vm::builtin_array_get(pool, scratch, source, 0);
        let result_child = vm::builtin_array_get(pool, scratch, result, 0);
        t.assert_eq(source_child, result_child);
        t.assert_true(vm::builtin_hash_set(pool, scratch, result_child, key, vm::mrb_fixnum(9)));
        t.assert_eq(9, vm::mrb_fixnum_value(vm::builtin_hash_get(pool, scratch, source_child, key)));
        t.assert_true(vm::builtin_array_set(pool, scratch, result, 0, vm::mrb_nil()));
        t.assert_eq(source_child, vm::builtin_array_get(pool, scratch, source, 0));
        t.assert_eq(1, vm::builtin_array_length(pool, scratch, source));
    }
}

fn test_slice_rejects_arity_and_argument_types(t: goosetest::Test&) {
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
    let source = sequence(scratch, 4);
    let empty: vm::MrbValue[0] = [];
    let extra: vm::MrbValue[3] = [vm::mrb_fixnum(0), vm::mrb_fixnum(1), vm::mrb_fixnum(2)];
    for name in["[]", "slice"] {
        machine.error = vm::VmError.Ok;
        let zero, zero_handled = vm::vm_call_array_builtin(machine, source, name, empty[..]);
        t.assert_true(zero_handled);
        t.assert_true(vm::mrb_is_nil(zero));
        t.assert_eq(vm::VmError.WrongArity, machine.error);
        machine.error = vm::VmError.Ok;
        let many, many_handled = vm::vm_call_array_builtin(machine, source, name, extra[..]);
        t.assert_true(many_handled);
        t.assert_true(vm::mrb_is_nil(many));
        t.assert_eq(vm::VmError.WrongArity, machine.error);
        for bad in[vm::mrb_nil(), vm::mrb_true(), vm::scratch_alloc_string(scratch, "1"),
            vm::num_from_f64(scratch, 1.5)] {
            for position in 2 {
                var args: vm::MrbValue[2] = [vm::mrb_fixnum(0), vm::mrb_fixnum(1)];
                args[position] = bad;
                machine.error = vm::VmError.Ok;
                let result, handled = vm::vm_call_array_builtin(machine, source, name, args[..]);
                t.assert_true(handled);
                t.assert_true(vm::mrb_is_nil(result));
                t.assert_eq(vm::VmError.TypeMismatch, machine.error);
            }
        }
    }
}

fn test_slice_allocates_only_returned_elements(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let original = sequence(scratch, 300);
    let persistent = vm::promote_to_state(pool, scratch, original);
    for source in[original, persistent] {
        let objects = vm::scratch_live_object_count(scratch);
        let slots = vm::scratch_live_slot_count(scratch);
        let result = vm::builtin_array_slice(pool, scratch, source, 290, 2);
        t.assert_eq(2, vm::builtin_array_length(pool, scratch, result));
        t.assert_eq(objects + 1, vm::scratch_live_object_count(scratch));
        t.assert_eq(slots + 2, vm::scratch_live_slot_count(scratch));
        t.assert_eq(291, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, result, 0)));
    }
}

fn test_slice_capacity_failure_and_recovery(t: goosetest::Test&) {
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
    let source = vm::promote_to_state(pool, scratch, sequence(scratch, 4));
    vm::scratch_reset(scratch);
    let filler = sequence(scratch, vm::SCRATCH_CAPACITY_SLOTS - 1);
    let args: vm::MrbValue[2] = [vm::mrb_fixnum(1), vm::mrb_fixnum(2)];
    let objects = vm::scratch_live_object_count(scratch);
    let result = vm::builtin_array_index(machine, source, args[..]);
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.ScratchFull, machine.error);
    t.assert_eq(vm::ScratchResource.Slots, scratch.failure.resource);
    t.assert_eq(vm::CapacityResource.ScratchSlots, machine.error_context.capacity_resource);
    t.assert_eq(2, machine.error_context.capacity_requested);
    t.assert_eq(2, scratch.failure.requested);
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS - 1, scratch.failure.used);
    t.assert_eq(objects, vm::scratch_live_object_count(scratch));
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS - 1, vm::scratch_array_length(scratch, filler));
    t.assert_eq(4, vm::state_array_length(pool, source));
    vm::scratch_reset(scratch);
    machine.error = vm::VmError.Ok;
    let recovered = vm::builtin_array_index(machine, source, args[..]);
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq(2, vm::scratch_array_length(scratch, recovered));
    vm::scratch_reset(scratch);
    for _ in vm::SCRATCH_CAPACITY_OBJECTS {
        vm::scratch_alloc_array(scratch);
    }
    let failed_empty = vm::builtin_array_slice(pool, scratch, source, 4, 0);
    t.assert_true(vm::mrb_is_nil(failed_empty));
    t.assert_eq(vm::ScratchResource.Objects, scratch.failure.resource);
    t.assert_eq(1, scratch.failure.requested);
    vm::scratch_reset(scratch);
    let fresh_empty = vm::builtin_array_slice(pool, scratch, source, 4, 0);
    t.assert_true(vm::scratch_is_array(scratch, fresh_empty));
}
