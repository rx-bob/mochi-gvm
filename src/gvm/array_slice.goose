// Array indexing and shallow slices share one checked argument contract.
// Collections use linked slots: seek once, then copy only the requested page.
namespace vm;

import.builtins;
import.collection_arena;
import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_errors;
import.vm_num;

fn builtin_array_index(machine: Vm&, receiver: MrbValue, args: MrbValue[:]) -> MrbValue {
    if args.len < 1 || args.len > 2 {
        machine.error = VmError.WrongArity;
        return mrb_nil();
    }
    let start, start_ok = num_integer_value(machine.scratch, machine.pool, args[0]);
    if !start_ok {
        machine.error = VmError.TypeMismatch;
        return mrb_nil();
    }
    if args.len == 1 {
        return builtin_array_get(machine.pool, machine.scratch, receiver, start);
    }
    let length, length_ok = num_integer_value(machine.scratch, machine.pool, args[1]);
    if !length_ok {
        machine.error = VmError.TypeMismatch;
        return mrb_nil();
    }
    let result = builtin_array_slice(machine.pool, machine.scratch, receiver, start, length);
    if machine.scratch.overflow {
        machine.error = VmError.ScratchFull;
        vm_absorb_scratch_failure(machine, -1);
    }
    return result;
}

fn builtin_array_slice(
    pool: StatePool&, scratch: ScratchArena&, receiver: MrbValue, start: i64, length: i64
) -> MrbValue {
    if length < 0 {
        return mrb_nil();
    }
    let size = builtin_array_length(pool, scratch, receiver);
    var begin = start;
    if begin < 0 {
        begin += size;
    }
    if begin < 0 || begin > size {
        return mrb_nil();
    }
    // Subtract before clamping, avoiding overflow for an i64-sized request.
    let count = if length < size - begin {
        length
    } else {
        size - begin
    };
    let objects = scratch_live_object_count(scratch);
    if objects >= SCRATCH_CAPACITY_OBJECTS {
        scratch_fail(scratch, ScratchResource.Objects, 1, objects, SCRATCH_CAPACITY_OBJECTS);
        return mrb_nil();
    }
    let slots = scratch_live_slot_count(scratch);
    if count > SCRATCH_CAPACITY_SLOTS - slots {
        scratch_fail(scratch, ScratchResource.Slots, count, slots, SCRATCH_CAPACITY_SLOTS);
        return mrb_nil();
    }
    // Reserve nothing until both bounds are known. Failure never publishes a
    // partial array or mutates the source. Nested values keep their identity.
    let result = scratch_alloc_array(scratch);
    if mrb_is_nil(result) || count == 0 {
        return result;
    }
    let source_index = mrb_arena_index(receiver);
    if mrb_is_scratch(receiver) {
        var slot = scratch_slot_index_at(scratch, source_index, begin);
        for _ in count {
            let item = scratch.slots[slot];
            if !scratch_array_push(scratch, result, item.value) {
                return mrb_nil();
            }
            slot = item.next_index;
        }
    } else {
        var slot = state_slot_index_at(pool, source_index, begin);
        for _ in count {
            let item = pool.slots[slot];
            if !scratch_array_push(scratch, result, item.value) {
                return mrb_nil();
            }
            slot = item.next_index;
        }
    }
    return result;
}
