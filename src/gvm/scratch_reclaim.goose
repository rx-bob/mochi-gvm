// Reclaims unreachable tick-scratch storage between instructions.
//
// Scratch is still rewound in O(1) at every host entry, but nested helpers used
// to accumulate every temporary string and hash until the entry ended. A build
// that constructs 180 rows through `date_short`, `money` and a hash literal can
// allocate thousands of short-lived objects even though only the promoted rows
// escape. This collector marks from the active register windows and the
// helper-owned root stack, then returns unmarked headers, slots, ivars and
// string bytes to free lists. It only runs at an instruction boundary, so no
// in-flight expression can be invalidated.
namespace vm;

import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;

let SCRATCH_ALLOCATION_INTERVAL: i64 = 64;

fn scratch_root_begin(machine: Vm&) -> i64 {
    return machine.scratch_roots.len;
}

fn scratch_root(machine: Vm&, value: MrbValue) {
    machine.scratch_roots.push(value);
}

fn scratch_root_end(machine: Vm&, mark: i64) {
    machine.scratch_roots.resize(mark);
}

fn scratch_should_collect(arena: ScratchArena&) -> bool {
    if arena.overflow || arena.failure.active {
        return false;
    }
    if arena.allocations_since_collect >= SCRATCH_ALLOCATION_INTERVAL {
        return true;
    }
    let live_objects = scratch_live_object_count(arena);
    if live_objects * 4 >= SCRATCH_CAPACITY_OBJECTS * 3 {
        return true;
    }
    let live_slots = scratch_live_slot_count(arena);
    if live_slots * 4 >= SCRATCH_CAPACITY_SLOTS * 3 {
        return true;
    }
    return arena.blob.len * 4 >= SCRATCH_CAPACITY_BYTES * 3;
}

fn scratch_mark_push(machine: Vm&, value: MrbValue) {
    if !mrb_is_scratch(value) {
        return;
    }
    let index = mrb_arena_index(value)as i64;
    if index < 0 || index >= machine.scratch.objects.len {
        return;
    }
    if !machine.scratch.objects[index].allocated
        || machine.scratch.marks[index] == machine.scratch.mark_epoch {
        return;
    }
    machine.scratch.marks[index] = machine.scratch.mark_epoch;
    machine.scratch.mark_stack.push(value);
}

// Walks every value reachable from one marked collection or instance.
fn scratch_mark_payload(machine: Vm&, object: ArenaObject) {
    if object.kind == ArenaObjectKind.Instance {
        var ivar_index = object.ivar_head_index;
        while ivar_index >= 0 {
            machine.scratch.ivar_marks[ivar_index] = machine.scratch.mark_epoch;
            scratch_mark_push(machine, machine.scratch.ivars[ivar_index].value);
            ivar_index = machine.scratch.ivars[ivar_index].next_index;
        }
        return;
    }
    if object.kind == ArenaObjectKind.String {
        return;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        machine.scratch.slot_marks[slot_index] = machine.scratch.mark_epoch;
        scratch_mark_push(machine, machine.scratch.slots[slot_index].key);
        scratch_mark_push(machine, machine.scratch.slots[slot_index].value);
        slot_index = machine.scratch.slots[slot_index].next_index;
    }
}

fn scratch_mark_drain(machine: Vm&) {
    while machine.scratch.mark_stack.len > 0 {
        let value = machine.scratch.mark_stack.pop();
        let index = mrb_arena_index(value)as i64;
        if index >= 0 && index < machine.scratch.objects.len {
            scratch_mark_payload(machine, machine.scratch.objects[index]);
        }
    }
}

// A parent frame's register window holds every captured upvar the current
// frame can read, so scanning the active windows covers closures. Registers of
// popped frames are not roots.
fn scratch_mark_roots(machine: Vm&) {
    for frame in machine.frames {
        scratch_mark_push(machine, frame.self_value);
        if frame.record_index < 0 || frame.record_index >= machine.file.records.len {
            continue;
        }
        let record = machine.file.records[frame.record_index];
        var offset = 0;
        while offset < record.nregs && frame.base + offset < machine.regs.len {
            scratch_mark_push(machine, machine.regs[frame.base + offset]);
            offset += 1;
        }
    }
    for value in machine.entry_args {
        scratch_mark_push(machine, value);
    }
    for value in machine.scratch_roots {
        scratch_mark_push(machine, value);
    }
    scratch_mark_drain(machine);
}

fn scratch_release_ivars(arena: ScratchArena&, head: i64) {
    var slot_index = head;
    while slot_index >= 0 {
        let next_index = arena.ivars[slot_index].next_index;
        arena.ivars[slot_index] = IvarSlot {
            key: 0,
            bit_index: 0,
            value: mrb_nil(),
            next_index: -1,
            allocated: false,
        };
        arena.free_ivars.push(slot_index);
        slot_index = next_index;
    }
}

fn scratch_release_slots(arena: ScratchArena&, head: i64) {
    var slot_index = head;
    while slot_index >= 0 {
        let next_index = arena.slots[slot_index].next_index;
        arena.slots[slot_index] = ArenaSlot {
            key: mrb_nil(),
            value: mrb_nil(),
            previous_index: -1,
            next_index: -1,
            allocated: false,
        };
        arena.free_slots.push(slot_index);
        slot_index = next_index;
    }
}

fn scratch_reclaim_object(arena: ScratchArena&, index: i64) -> bool {
    let object = arena.objects[index];
    if !object.allocated {
        return false;
    }
    if object.kind == ArenaObjectKind.String {
        scratch_release_bytes(arena, object.text_offset_bytes, object.text_length_bytes);
    } else if object.kind == ArenaObjectKind.Instance {
        scratch_release_ivars(arena, object.ivar_head_index);
    } else {
        scratch_release_slots(arena, object.items_first_index);
    }
    arena.objects[index] = empty_arena_object(ArenaObjectKind.String);
    arena.objects[index].allocated = false;
    arena.free_objects.push(index);
    return true;
}

fn scratch_sweep(arena: ScratchArena&) -> i64 {
    var freed = 0;
    for index in 0..arena.objects.len {
        if arena.objects[index].allocated && arena.marks[index] != arena.mark_epoch {
            if scratch_reclaim_object(arena, index) {
                freed += 1;
            }
        }
    }
    return freed;
}

// Runs one collection at an instruction boundary. Values that escape to state
// have already been copied by `promote_to_state`, so they are never roots here.
fn scratch_collect(machine: Vm&) -> i64 {
    if machine.scratch.marks.len < machine.scratch.objects.len {
        machine.scratch.marks.resize(machine.scratch.objects.len, 0);
    }
    if machine.scratch.ivar_marks.len < machine.scratch.ivars.len {
        machine.scratch.ivar_marks.resize(machine.scratch.ivars.len, 0);
    }
    if machine.scratch.slot_marks.len < machine.scratch.slots.len {
        machine.scratch.slot_marks.resize(machine.scratch.slots.len, 0);
    }
    machine.scratch.mark_epoch += 1;
    if machine.scratch.mark_epoch == 0 {
        for index in 0..machine.scratch.marks.len {
            machine.scratch.marks[index] = 0;
        }
        for index in 0..machine.scratch.ivar_marks.len {
            machine.scratch.ivar_marks[index] = 0;
        }
        for index in 0..machine.scratch.slot_marks.len {
            machine.scratch.slot_marks[index] = 0;
        }
        machine.scratch.mark_epoch = 1;
    }
    machine.scratch.mark_stack.clear();
    scratch_mark_roots(machine);
    let freed = scratch_sweep(machine.scratch);
    machine.scratch.allocations_since_collect = 0;
    return freed;
}

fn scratch_maybe_collect(machine: Vm&) -> bool {
    if !scratch_should_collect(machine.scratch) {
        return false;
    }
    scratch_collect(machine);
    return true;
}
