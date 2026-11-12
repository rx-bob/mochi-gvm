// Tick-scratch allocation, string bytes, ivars and reset.
//
// Scratch headers and their payloads live in the value arena types. Keeping the
// allocation and free-list helpers here holds `value_arena.goose` below the
// style guide limit without changing the two-zone value layout.
namespace vm;

import.value_arena;

fn scratch_bytes_used(arena: ScratchArena&) -> i64 {
    return arena.blob.len;
}

// Records the first rejected allocation so capacity errors can name the
// exhausted resource and the size that did not fit.
fn scratch_fail(
    arena: ScratchArena&, resource: ScratchResource, requested: i64, used: i64, capacity: i64
) {
    if !arena.failure.active {
        arena.failure = ScratchFailure {
            resource: resource,
            requested: requested,
            used: used,
            capacity: capacity,
            active: true,
        };
    }
    arena.overflow = true;
}

fn scratch_live_object_count(arena: ScratchArena&) -> i64 {
    return arena.objects.len - arena.free_objects.len;
}

fn scratch_live_slot_count(arena: ScratchArena&) -> i64 {
    return arena.slots.len - arena.free_slots.len;
}

// Returns one object header for `kind`, reusing a freed header when possible.
fn scratch_take_object(arena: ScratchArena&, kind: ArenaObjectKind) -> i64 {
    var index = -1;
    if arena.free_objects.len > 0 {
        index = arena.free_objects.pop();
    } else {
        if arena.objects.len >= SCRATCH_CAPACITY_OBJECTS {
            scratch_fail(arena, ScratchResource.Objects, 1, arena.objects.len,
                SCRATCH_CAPACITY_OBJECTS);
            return -1;
        }
        index = arena.objects.len;
        arena.objects.push(empty_arena_object(kind));
    }
    arena.objects[index] = empty_arena_object(kind);
    arena.allocations_since_collect += 1;
    return index;
}

// Adds one freed byte range to the ordered free list and coalesces both sides.
fn scratch_release_bytes(arena: ScratchArena&, offset: i64, length: i64) {
    if length <= 0 || offset < 0 || offset + length > arena.blob.len {
        return;
    }
    if arena.free_bytes.len >= SCRATCH_CAPACITY_OBJECTS {
        return;
    }
    var insert_at = 0;
    while insert_at < arena.free_bytes.len && arena.free_bytes[insert_at].offset < offset {
        insert_at += 1;
    }
    arena.free_bytes.push(ScratchByteRange {
            offset: offset,
            length: length,
        });
    var move_index = arena.free_bytes.len - 1;
    while move_index > insert_at {
        arena.free_bytes[move_index] = arena.free_bytes[move_index - 1];
        move_index -= 1;
    }
    arena.free_bytes[insert_at] = ScratchByteRange {
        offset: offset,
        length: length,
    };
    if insert_at + 1 < arena.free_bytes.len {
        let next = arena.free_bytes[insert_at + 1];
        if arena.free_bytes[insert_at].offset + arena.free_bytes[insert_at].length == next.offset {
            arena.free_bytes[insert_at].length += next.length;
            var shift_index = insert_at + 1;
            while shift_index + 1 < arena.free_bytes.len {
                arena.free_bytes[shift_index] = arena.free_bytes[shift_index + 1];
                shift_index += 1;
            }
            arena.free_bytes.pop();
        }
    }
    if insert_at > 0 {
        let previous = arena.free_bytes[insert_at - 1];
        if previous.offset + previous.length == arena.free_bytes[insert_at].offset {
            arena.free_bytes[insert_at - 1].length += arena.free_bytes[insert_at].length;
            var shift_index = insert_at;
            while shift_index + 1 < arena.free_bytes.len {
                arena.free_bytes[shift_index] = arena.free_bytes[shift_index + 1];
                shift_index += 1;
            }
            arena.free_bytes.pop();
        }
    }
    while arena.free_bytes.len > 0 {
        let last_index = arena.free_bytes.len - 1;
        let last = arena.free_bytes[last_index];
        if last.offset + last.length < arena.blob.len {
            break;
        }
        arena.blob.resize(last.offset);
        arena.free_bytes.pop();
    }
}

// Reserves `length` bytes from the free ranges or the bump cursor.
fn scratch_take_bytes(arena: ScratchArena&, length: i64) -> i64 {
    if length < 0 {
        return -1;
    }
    var index = 0;
    while index < arena.free_bytes.len {
        let range = arena.free_bytes[index];
        if range.length >= length {
            let offset = range.offset;
            if range.length == length {
                var shift_index = index;
                while shift_index + 1 < arena.free_bytes.len {
                    arena.free_bytes[shift_index] = arena.free_bytes[shift_index + 1];
                    shift_index += 1;
                }
                arena.free_bytes.pop();
            } else {
                arena.free_bytes[index].offset += length;
                arena.free_bytes[index].length -= length;
            }
            return offset;
        }
        index += 1;
    }
    if arena.blob.len + length > SCRATCH_CAPACITY_BYTES {
        scratch_fail(arena, ScratchResource.Bytes, length, arena.blob.len,
            SCRATCH_CAPACITY_BYTES);
        return -1;
    }
    let offset = arena.blob.len;
    arena.blob.resize(offset + length, 0);
    return offset;
}

fn scratch_write_bytes(arena: ScratchArena&, offset: i64, text: u8[:]) {
    var index = 0;
    while index < text.len {
        arena.blob[offset + index] = text[index];
        index += 1;
    }
}

fn scratch_object_count(arena: ScratchArena&) -> i64 {
    return arena.objects.len;
}

fn scratch_ivar_count(arena: ScratchArena&) -> i64 {
    return arena.ivars.len;
}

// Rewinds both bump cursors. Total allocation counters deliberately survive so
// tests and telemetry can prove that many ticks reused the same fixed arena.
fn scratch_reset(arena: ScratchArena&) {
    arena.blob.clear();
    arena.objects.clear();
    arena.ivars.clear();
    arena.slots.clear();
    arena.free_objects.clear();
    arena.free_ivars.clear();
    arena.free_slots.clear();
    arena.free_bytes.clear();
    arena.mark_stack.clear();
    arena.mark_epoch += 1;
    if arena.mark_epoch == 0 {
        for index in 0..arena.marks.len {
            arena.marks[index] = 0;
        }
        for index in 0..arena.ivar_marks.len {
            arena.ivar_marks[index] = 0;
        }
        for index in 0..arena.slot_marks.len {
            arena.slot_marks[index] = 0;
        }
        arena.mark_epoch = 1;
    }
    arena.allocations_since_collect = 0;
    arena.failure.resource = ScratchResource.None;
    arena.failure.requested = 0;
    arena.failure.used = 0;
    arena.failure.capacity = 0;
    arena.failure.active = false;
    arena.overflow = false;
    arena.reset_count += 1;
}

fn scratch_object(arena: ScratchArena&, value: MrbValue) -> ArenaObject, bool {
    if !mrb_is_arena(value) {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    if mrb_arena_tag(value) != MRB_ARENA_SCRATCH {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    let index = mrb_arena_index(value)as i64;
    if index < 0 || index >= arena.objects.len || !arena.objects[index].allocated {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    return arena.objects[index], true;
}

// Copies `text` into the tick arena and returns a scratch string handle.
fn scratch_alloc_string(arena: ScratchArena&, text: u8[:]) -> MrbValue {
    let index = scratch_take_object(arena, ArenaObjectKind.String);
    if index < 0 {
        return mrb_nil();
    }
    let offset = scratch_take_bytes(arena, text.len);
    if offset < 0 {
        arena.objects[index].allocated = false;
        arena.free_objects.push(index);
        return mrb_nil();
    }
    scratch_write_bytes(arena, offset, text);
    var object = empty_arena_object(ArenaObjectKind.String);
    object.text_offset_bytes = offset;
    object.text_length_bytes = text.len;
    arena.objects[index] = object;
    arena.allocated_objects_total += 1;
    arena.allocated_bytes_total += text.len;
    return mrb_arena_value(MRB_ARENA_SCRATCH, index as u32);
}

// Allocates a scratch instance bound to a state-pool class ID.
fn scratch_alloc_instance(arena: ScratchArena&, class_id: u32) -> MrbValue {
    let index = scratch_take_object(arena, ArenaObjectKind.Instance);
    if index < 0 {
        return mrb_nil();
    }
    var object = empty_arena_object(ArenaObjectKind.Instance);
    object.class_index = class_id;
    arena.objects[index] = object;
    arena.allocated_objects_total += 1;
    return mrb_arena_value(MRB_ARENA_SCRATCH, index as u32);
}

fn scratch_is_string(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.String;
}

fn scratch_is_instance(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.Instance;
}

// Returns a view of the string bytes, or an empty view for a non-string.
fn scratch_string_bytes(arena: ScratchArena&, value: MrbValue) -> const u8[:] {
    let object, ok = scratch_object(arena, value);
    if !ok || object.kind != ArenaObjectKind.String {
        return "";
    }
    let start = object.text_offset_bytes;
    let stop = start + object.text_length_bytes;
    if start < 0 || stop > arena.blob.len {
        return "";
    }
    return arena.blob[start..stop];
}

// Allocates a fresh scratch string holding `left` followed by `right`.
fn scratch_concat_string(arena: ScratchArena&, left: MrbValue, right: MrbValue) -> MrbValue {
    if !scratch_is_string(arena, left) || !scratch_is_string(arena, right) {
        return mrb_nil();
    }
    var joined: u8[>..] = [];
    joined.append(scratch_string_bytes(arena, left));
    joined.append(scratch_string_bytes(arena, right));
    return scratch_alloc_string(arena, joined[..]);
}

fn scratch_set_ivar(arena: ScratchArena&, instance: MrbValue, key: u32, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    let index = mrb_arena_index(instance)as i64;
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        if arena.ivars[slot_index].key == key {
            arena.ivars[slot_index].value = value;
            return true;
        }
        slot_index = arena.ivars[slot_index].next_index;
    }
    var new_index = -1;
    if arena.free_ivars.len > 0 {
        new_index = arena.free_ivars.pop();
    } else {
        if arena.ivars.len >= SCRATCH_CAPACITY_IVARS {
            scratch_fail(arena, ScratchResource.Ivars, 1, arena.ivars.len,
                SCRATCH_CAPACITY_IVARS);
            return false;
        }
        new_index = arena.ivars.len;
        arena.ivars.push(IvarSlot {
                key: key,
                bit_index: 0,
                value: value,
                next_index: -1,
                allocated: true,
            });
    }
    arena.ivars[new_index] = IvarSlot {
        key: key,
        bit_index: 0,
        value: value,
        next_index: object.ivar_head_index,
        allocated: true,
    };
    arena.objects[index].ivar_head_index = new_index;
    return true;
}

fn scratch_get_ivar(arena: ScratchArena&, instance: MrbValue, key: u32) -> MrbValue, bool {
    let object, ok = scratch_object(arena, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return mrb_nil(), false;
    }
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        let slot = arena.ivars[slot_index];
        if slot.key == key {
            return slot.value, true;
        }
        slot_index = slot.next_index;
    }
    return mrb_nil(), false;
}
