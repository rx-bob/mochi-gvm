// Non-moving mark/sweep reclamation for the persistent state pool.
//
// Roots are the registered component handles, constants, live register windows,
// frame receivers, binding registrations and the instance being tracked for a
// binding getter. Marking is iterative: each object is pushed at most once, so
// self-referential and mutually referential collections terminate without a
// depth limit. Sweeping returns unreachable headers, ivar slots, collection
// slots and string byte ranges to their free lists. Live objects never move.
namespace vm;

import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;

// Headroom kept for one promotion between collection points. A single tick can
// copy at most one scratch arena, so these reserves exceed the scratch limits.
let GC_RESERVE_OBJECTS = 4096;
let GC_RESERVE_IVARS = 4096;
let GC_RESERVE_SLOTS = 8192;
let GC_RESERVE_BYTES = 262144;
let GC_ALLOCATION_INTERVAL = 64;

// True when reclamation should run before the next instruction. Allocation
// pressure triggers early enough that a whole scratch arena can still promote.
fn gc_should_collect(pool: StatePool&) -> bool {
    if pool.allocations_since_collect >= GC_ALLOCATION_INTERVAL {
        return true;
    }
    if pool.free_objects.len == 0 && pool.objects.len + GC_RESERVE_OBJECTS >= MAX_STATE_OBJECTS {
        return true;
    }
    if pool.free_ivars.len == 0 && pool.ivars.len + GC_RESERVE_IVARS >= MAX_STATE_IVARS {
        return true;
    }
    if pool.free_slots.len == 0 && pool.slots.len + GC_RESERVE_SLOTS >= MAX_STATE_SLOTS {
        return true;
    }
    return pool.blob.len + GC_RESERVE_BYTES >= MAX_STATE_BYTES;
}

// Marks one reachable state value. Non-state handles and stale generations are
// ignored, matching the normal lookup rules.
fn gc_mark_push(pool: StatePool&, value: MrbValue) {
    if !mrb_is_state(value) {
        return;
    }
    let object, ok = state_object(pool, value);
    if !ok || !object.allocated {
        return;
    }
    let index = mrb_arena_index(value)as i64;
    if pool.marks[index] == pool.mark_epoch {
        return;
    }
    pool.marks[index] = pool.mark_epoch;
    pool.mark_stack.push(value);
}

// Drains the worklist, adding each object's children exactly once.
fn gc_drain(pool: StatePool&) {
    while pool.mark_stack.len > 0 {
        let value = pool.mark_stack[pool.mark_stack.len - 1];
        pool.mark_stack.pop();
        let object, ok = state_object(pool, value);
        if !ok {
            continue;
        }
        if object.kind == ArenaObjectKind.Instance {
            var slot_index = object.ivar_head_index;
            while slot_index >= 0 {
                gc_mark_push(pool, pool.ivars[slot_index].value);
                slot_index = pool.ivars[slot_index].next_index;
            }
        } else if object.kind == ArenaObjectKind.Array {
            var slot_index = object.items_first_index;
            while slot_index >= 0 {
                gc_mark_push(pool, pool.slots[slot_index].value);
                slot_index = pool.slots[slot_index].next_index;
            }
        } else if object.kind == ArenaObjectKind.Hash {
            var slot_index = object.items_first_index;
            while slot_index >= 0 {
                gc_mark_push(pool, pool.slots[slot_index].key);
                gc_mark_push(pool, pool.slots[slot_index].value);
                slot_index = pool.slots[slot_index].next_index;
            }
        }
    }
}

// Marks every root surface. Captured upvars live in the parent frame's register
// window, so scanning all live registers also covers closures. Fetch, timer and
// subscription payloads are byte buffers and hold no state handles.
fn gc_mark_roots(machine: Vm&) {
    let pool = machine.pool;
    for component in pool.components {
        gc_mark_push(pool, component);
    }
    for entry in pool.consts {
        gc_mark_push(pool, entry.value);
    }
    for entry in pool.bindings {
        gc_mark_push(pool, entry.instance);
    }
    for value in machine.regs {
        gc_mark_push(pool, value);
    }
    for frame in machine.frames {
        gc_mark_push(pool, frame.self_value);
    }
    for value in machine.entry_args {
        gc_mark_push(pool, value);
    }
    let tracked = pool.tracking_instance_index;
    if tracked >= 0 && tracked < pool.objects.len {
        gc_mark_push(pool, mrb_arena_value_versioned(
            MRB_ARENA_STATE, tracked as u32, pool.tracking_instance_generation));
    }
    gc_drain(pool);
}

// Returns every ivar slot in one chain to the free list.
fn gc_release_ivars(pool: StatePool&, head: i64) {
    var slot_index = head;
    while slot_index >= 0 {
        let next_index = pool.ivars[slot_index].next_index;
        pool.ivars[slot_index] = IvarSlot {
            key: 0,
            bit_index: 0,
            value: mrb_nil(),
            next_index: -1,
            allocated: false,
        };
        pool.free_ivars.push(slot_index);
        slot_index = next_index;
    }
}

// Returns every collection slot in one chain to the free list.
fn gc_release_slots(pool: StatePool&, head: i64) {
    var slot_index = head;
    while slot_index >= 0 {
        let next_index = pool.slots[slot_index].next_index;
        state_release_slot(pool, slot_index);
        slot_index = next_index;
    }
}

// Frees one unmarked header and detaches all of its storage.
fn gc_reclaim_object(pool: StatePool&, index: i64) -> bool {
    let object = pool.objects[index];
    if !object.allocated {
        return false;
    }
    if object.kind == ArenaObjectKind.String {
        state_blob_free(pool, object.text_offset_bytes, object.text_length_bytes);
    } else if object.kind == ArenaObjectKind.Instance {
        gc_release_ivars(pool, object.ivar_head_index);
    } else {
        gc_release_slots(pool, object.items_first_index);
    }
    let generation = ((object.generation as u32 + 1) & 0xFFFF)as u16;
    var empty = empty_arena_object(ArenaObjectKind.String);
    empty.allocated = false;
    empty.generation = generation;
    pool.objects[index] = empty;
    pool.free_objects.push(index);
    return true;
}

// Sweeps every unmarked header. Object indices stay stable; only their
// generations advance and their storage joins the free lists.
fn gc_sweep(pool: StatePool&) -> i64 {
    var freed = 0;
    for index in 0..pool.objects.len {
        if pool.objects[index].allocated && pool.marks[index] != pool.mark_epoch {
            if gc_reclaim_object(pool, index) {
                freed += 1;
            }
        }
    }
    return freed;
}

// Runs one full collection. Callers must be at a boundary where every live
// value is in a root surface (a frame dispatch boundary or a host entry with no
// active frames).
fn gc_collect(machine: Vm&) -> i64 {
    let pool = machine.pool;
    if pool.mark_epoch == 0xFFFFFFFF {
        for index in 0..pool.marks.len {
            pool.marks[index] = 0;
        }
        pool.mark_epoch = 1;
    } else {
        pool.mark_epoch += 1;
    }
    pool.mark_stack.clear();
    gc_mark_roots(machine);
    let freed = gc_sweep(pool);
    pool.allocations_since_collect = 0;
    return freed;
}

// Collects only when the allocation interval or a capacity reserve is reached.
fn gc_maybe_collect(machine: Vm&) -> bool {
    if !gc_should_collect(machine.pool) {
        return false;
    }
    gc_collect(machine);
    return true;
}
