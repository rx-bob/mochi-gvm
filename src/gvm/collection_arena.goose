// Tick-scoped Array and Hash storage.
//
// Collections are arena objects whose payload is a doubly linked list of
// `ArenaSlot` nodes in the zone slot table. `push` appends in O(1), `pop`
// unlinks the tail, and hashes retain insertion order while doing linear scans
// for small symbol-keyed records.
namespace vm;

import.ivar_mask;
import.scratch_alloc;
import.value_arena;

fn scratch_slot_count(arena: ScratchArena&) -> i64 {
    return arena.slots.len;
}

fn scratch_alloc_array(arena: ScratchArena&) -> MrbValue {
    return scratch_alloc_collection(arena, ArenaObjectKind.Array);
}

fn scratch_alloc_hash(arena: ScratchArena&) -> MrbValue {
    return scratch_alloc_collection(arena, ArenaObjectKind.Hash);
}

fn scratch_alloc_collection(arena: ScratchArena&, kind: ArenaObjectKind) -> MrbValue {
    let index = scratch_take_object(arena, kind);
    if index < 0 {
        return mrb_nil();
    }
    return mrb_arena_value(MRB_ARENA_SCRATCH, index as u32);
}

fn scratch_is_array(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.Array;
}

fn scratch_is_hash(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.Hash;
}

// Appends one slot to `object_index`'s linked list and returns its index.
fn scratch_append_slot(arena: ScratchArena&, object_index: i64, key: MrbValue, value: MrbValue) -> bool {
    if object_index < 0 || object_index >= arena.objects.len {
        arena.overflow = true;
        return false;
    }
    var slot_index = -1;
    if arena.free_slots.len > 0 {
        slot_index = arena.free_slots.pop();
    } else {
        if arena.slots.len >= SCRATCH_CAPACITY_SLOTS {
            scratch_fail(arena, ScratchResource.Slots, 1, arena.slots.len,
                SCRATCH_CAPACITY_SLOTS);
            return false;
        }
        slot_index = arena.slots.len;
        arena.slots.push(ArenaSlot {
                key: key,
                value: value,
                previous_index: -1,
                next_index: -1,
                allocated: true,
            });
    }
    let previous = arena.objects[object_index].items_last_index;
    arena.slots[slot_index] = ArenaSlot {
        key: key,
        value: value,
        previous_index: previous,
        next_index: -1,
        allocated: true,
    };
    if previous >= 0 {
        arena.slots[previous].next_index = slot_index;
    } else {
        arena.objects[object_index].items_first_index = slot_index;
    }
    arena.objects[object_index].items_last_index = slot_index;
    arena.objects[object_index].item_count += 1;
    return true;
}

// Walks to the slot at `position` inside a collection. Returns -1 when the
// position is outside the list.
fn scratch_slot_index_at(arena: ScratchArena&, object_index: i64, position: i64) -> i64 {
    if position < 0 {
        return -1;
    }
    var slot_index = arena.objects[object_index].items_first_index;
    var remaining = position;
    while slot_index >= 0 && remaining > 0 {
        slot_index = arena.slots[slot_index].next_index;
        remaining -= 1;
    }
    return slot_index;
}

fn scratch_array_push(arena: ScratchArena&, array: MrbValue, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return false;
    }
    return scratch_append_slot(arena, mrb_arena_index(array), mrb_nil(), value);
}

fn scratch_array_pop(arena: ScratchArena&, array: MrbValue) -> MrbValue, bool {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array || object.item_count == 0 {
        return mrb_nil(), false;
    }
    let object_index = mrb_arena_index(array)as i64;
    let tail = object.items_last_index;
    let value = arena.slots[tail].value;
    let previous = arena.slots[tail].previous_index;
    if previous >= 0 {
        arena.slots[previous].next_index = -1;
    } else {
        arena.objects[object_index].items_first_index = -1;
    }
    arena.objects[object_index].items_last_index = previous;
    arena.objects[object_index].item_count -= 1;
    if tail == arena.slots.len - 1 {
        arena.slots.pop();
    }
    return value, true;
}

fn scratch_array_get(arena: ScratchArena&, array: MrbValue, position: i64) -> MrbValue, bool {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return mrb_nil(), false;
    }
    if position < 0 || position >= object.item_count {
        return mrb_nil(), false;
    }
    let slot_index = scratch_slot_index_at(arena, mrb_arena_index(array), position);
    if slot_index < 0 {
        return mrb_nil(), false;
    }
    return arena.slots[slot_index].value, true;
}

fn scratch_array_set(arena: ScratchArena&, array: MrbValue, position: i64, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return false;
    }
    if position < 0 || position >= object.item_count {
        return false;
    }
    let slot_index = scratch_slot_index_at(arena, mrb_arena_index(array), position);
    if slot_index < 0 {
        return false;
    }
    arena.slots[slot_index].value = value;
    return true;
}

fn scratch_array_last(arena: ScratchArena&, array: MrbValue) -> MrbValue, bool {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array || object.item_count == 0 {
        return mrb_nil(), false;
    }
    return arena.slots[object.items_last_index].value, true;
}

fn scratch_array_length(arena: ScratchArena&, array: MrbValue) -> i64 {
    let object, ok = scratch_object(arena, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return 0;
    }
    return object.item_count;
}

fn scratch_hash_set(arena: ScratchArena&, hash: MrbValue, key: MrbValue, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if mrb_value_identical(arena.slots[slot_index].key, key) {
            arena.slots[slot_index].value = value;
            return true;
        }
        slot_index = arena.slots[slot_index].next_index;
    }
    return scratch_append_slot(arena, mrb_arena_index(hash), key, value);
}

fn scratch_hash_get(arena: ScratchArena&, hash: MrbValue, key: MrbValue) -> MrbValue, bool {
    let object, ok = scratch_object(arena, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return mrb_nil(), false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if mrb_value_identical(arena.slots[slot_index].key, key) {
            return arena.slots[slot_index].value, true;
        }
        slot_index = arena.slots[slot_index].next_index;
    }
    return mrb_nil(), false;
}

fn scratch_hash_length(arena: ScratchArena&, hash: MrbValue) -> i64 {
    let object, ok = scratch_object(arena, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return 0;
    }
    return object.item_count;
}
