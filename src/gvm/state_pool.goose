// Persistent state pool for classes, component instances and their ivars.
//
// The scratch arena is wiped at the end of every tick. Anything that must
// survive, such as a component's `@ivar` table, lives here instead: class
// definitions, instances and ivar slots all grow monotonically, and objects
// are addressed through the same 31-bit state handles used by `MrbValue`.
namespace vm;

import.capacity_config;
import.ivar_mask;
import.scratch_alloc;
import.signals;
import.value_arena;
import.vm_core;
import.vm_errors;

// The state pool is long-lived, so its limits are larger but still enforced.
let NULL_CLASS_ID: u32 = 0xFFFFFFFF;

// A class definition. The class value itself is an immediate class ID.
struct ClassDef {
    name_symbol: u32,
    superclass_id: u32,
}

struct ConstEntry {
    name_symbol: u32,
    value: MrbValue,
}

// One reclaimed string byte range. Adjacent ranges are coalesced on free so a
// pool with `n` live strings keeps at most `n + 1` ranges.
struct ByteRange {
    offset: i64,
    length: i64,
}

// Long-lived objects, classes and registered component roots. The VM owns one
// instance for its lifetime. Storage is reused rather than grown forever:
// `state_reclaim.goose` frees unreachable headers, ivars, slots and string
// ranges into the free lists below at safe VM boundaries.
root struct StatePool {
    classes: ClassDef[>..] = [],
    consts: ConstEntry[>..] = [],
    objects: ArenaObject[>..] = [],
    ivars: IvarSlot[>..] = [],
    slots: ArenaSlot[>..] = [],
    components: MrbValue[>..] = [],
    bindings: BindingEntry[>..] = [],
    blob: u8[>..] = [],
    free_objects: i64[>..] = [],
    free_ivars: i64[>..] = [],
    free_slots: i64[>..] = [],
    // String bytes use first-fit reuse without compaction. Adjacent ranges are
    // coalesced on free, so the list is bounded by the live string count. The
    // collector runs at most one allocation interval (64 objects) after a value
    // becomes garbage; that interval plus the live graph is the retention bound.
    free_bytes: ByteRange[>..] = [],
    // One mark word per object header. `mark_epoch` advances per collection so
    // marking never has to clear the whole table.
    marks: u32[>..] = [],
    mark_epoch: u32 = 0,
    mark_stack: MrbValue[>..] = [],
    allocations_since_collect: i64 = 0,
    // Signal tracking is global because at most one binding getter runs at a
    // time: reads of the tracked instance set their bits in `active_read_mask`
    // and writes set changed bits in the instance's `dirty_ivars`.
    active_read_mask: IvarMask = IvarMask {
        w0: 0,
        w1: 0,
        w2: 0,
        w3: 0,
    },
    tracking_instance_index: i64 = -1,
    tracking_instance_generation: u16 = 0,
    // Capacity failures are reported here because the state layer has no `Vm`
    // handle. `vm_begin_entry` clears it before every host call.
    error: VmError = VmError.Ok,
}

fn state_object_count(pool: StatePool&) -> i64 {
    return pool.objects.len;
}

fn state_bytes_used(pool: StatePool&) -> i64 {
    return pool.blob.len;
}

fn state_ivar_count(pool: StatePool&) -> i64 {
    return pool.ivars.len;
}

fn state_slot_count(pool: StatePool&) -> i64 {
    return pool.slots.len;
}

fn state_class_count(pool: StatePool&) -> i64 {
    return pool.classes.len;
}

fn state_component_count(pool: StatePool&) -> i64 {
    return pool.components.len;
}

// Number of headers currently holding a live object. `state_object_count`
// remains the table high-water mark used to prove bounded reuse.
fn state_allocated_object_count(pool: StatePool&) -> i64 {
    return pool.objects.len - pool.free_objects.len;
}

fn state_free_object_count(pool: StatePool&) -> i64 {
    return pool.free_objects.len;
}

fn state_free_byte_count(pool: StatePool&) -> i64 {
    var total = 0;
    for range in pool.free_bytes {
        total += range.length;
    }
    return total;
}

fn state_component_at(pool: StatePool&, at: i64) -> MrbValue {
    assert(at >= 0);
    assert(at < pool.components.len);
    return pool.components[at];
}

// True when one more object can be allocated without growing the table.
fn state_has_object_capacity(pool: StatePool&) -> bool {
    return pool.free_objects.len > 0 || pool.objects.len < MAX_STATE_OBJECTS;
}

fn state_has_byte_capacity(pool: StatePool&, length: i64) -> bool {
    if length <= 0 {
        return true;
    }
    for range in pool.free_bytes {
        if range.length >= length {
            return true;
        }
    }
    return pool.blob.len + length <= MAX_STATE_BYTES;
}

// Appends a class definition and returns its immediate class ID.
fn state_define_class(pool: StatePool&, name_symbol: u32, superclass_id: u32) -> u32 {
    assert(pool.classes.len < MAX_STATE_CLASSES);
    let class_id = pool.classes.len as u32;
    pool.classes.push(ClassDef {
            name_symbol: name_symbol,
            superclass_id: superclass_id,
        });
    return class_id;
}

fn state_class_name_symbol(pool: StatePool&, class_id: u32) -> u32 {
    assert(class_id < pool.classes.len);
    return pool.classes[class_id].name_symbol;
}

fn state_class_superclass_id(pool: StatePool&, class_id: u32) -> u32 {
    assert(class_id < pool.classes.len);
    return pool.classes[class_id].superclass_id;
}

fn state_set_const(pool: StatePool&, scratch: ScratchArena&, name_symbol: u32, value: MrbValue) {
    let promoted = promote_to_state(pool, scratch, value);
    for index in 0..pool.consts.len {
        if pool.consts[index].name_symbol == name_symbol {
            pool.consts[index].value = promoted;
            return;
        }
    }
    pool.consts.push(ConstEntry {
            name_symbol: name_symbol,
            value: promoted,
        });
}

fn state_get_const(pool: StatePool&, name_symbol: u32) -> MrbValue, bool {
    for entry in pool.consts {
        if entry.name_symbol == name_symbol {
            return entry.value, true;
        }
    }
    return mrb_nil(), false;
}

// Removes one byte range from the free list, preserving order so coalescing
// stays simple and deterministic.
fn state_remove_free_byte(pool: StatePool&, at: i64) {
    var cursor = at;
    while cursor + 1 < pool.free_bytes.len {
        pool.free_bytes[cursor] = pool.free_bytes[cursor + 1];
        cursor += 1;
    }
    pool.free_bytes.pop();
}

// Allocates `length` bytes from a freed range or the blob high-water mark.
// Returns -1 when the pool cannot satisfy the request without exceeding its
// documented ceiling.
fn state_blob_allocate(pool: StatePool&, length: i64) -> i64 {
    if length <= 0 {
        return 0;
    }
    var found = -1;
    for index in 0..pool.free_bytes.len {
        if pool.free_bytes[index].length >= length {
            found = index;
            break;
        }
    }
    if found >= 0 {
        let offset = pool.free_bytes[found].offset;
        if pool.free_bytes[found].length == length {
            state_remove_free_byte(pool, found);
        } else {
            pool.free_bytes[found].offset = offset + length;
            pool.free_bytes[found].length -= length;
        }
        return offset;
    }
    if pool.blob.len + length > MAX_STATE_BYTES {
        pool.error = VmError.StateCapacity;
        return -1;
    }
    let offset = pool.blob.len;
    var appended = 0;
    while appended < length {
        pool.blob.push(0);
        appended += 1;
    }
    return offset;
}

// Returns a string's byte range to the free list and merges touching ranges.
fn state_blob_free(pool: StatePool&, offset: i64, length: i64) {
    if length <= 0 || offset < 0 {
        return;
    }
    var at = 0;
    while at < pool.free_bytes.len && pool.free_bytes[at].offset < offset {
        at += 1;
    }
    pool.free_bytes.push(ByteRange {
            offset: offset,
            length: length,
        });
    var cursor = pool.free_bytes.len - 1;
    while cursor > at {
        pool.free_bytes[cursor] = pool.free_bytes[cursor - 1];
        cursor -= 1;
    }
    pool.free_bytes[at] = ByteRange {
        offset: offset,
        length: length,
    };
    if at + 1 < pool.free_bytes.len
        && pool.free_bytes[at].offset + pool.free_bytes[at].length == pool.free_bytes[at + 1].offset {
        pool.free_bytes[at].length += pool.free_bytes[at + 1].length;
        state_remove_free_byte(pool, at + 1);
    }
    if at > 0
        && pool.free_bytes[at - 1].offset + pool.free_bytes[at - 1].length == pool.free_bytes[at].offset {
        pool.free_bytes[at - 1].length += pool.free_bytes[at].length;
        state_remove_free_byte(pool, at);
    }
}

// Takes a header from the free list or grows the table. A reused header keeps
// its generation, which the handle carries so stale references miss.
fn state_take_object(pool: StatePool&, kind: ArenaObjectKind) -> i64 {
    pool.allocations_since_collect += 1;
    if pool.free_objects.len > 0 {
        let index = pool.free_objects[pool.free_objects.len - 1];
        pool.free_objects.pop();
        let generation = pool.objects[index].generation;
        var object = empty_arena_object(kind);
        object.generation = generation;
        pool.objects[index] = object;
        return index;
    }
    if pool.objects.len >= MAX_STATE_OBJECTS {
        pool.error = VmError.StateCapacity;
        return -1;
    }
    let index = pool.objects.len;
    pool.objects.push(empty_arena_object(kind));
    pool.marks.push(0);
    return index;
}

fn state_object_handle(pool: StatePool&, index: i64) -> MrbValue {
    assert(index >= 0);
    assert(index < pool.objects.len);
    return mrb_arena_value_versioned(MRB_ARENA_STATE, index as u32, pool.objects[index].generation);
}

// Copies `text` into the persistent state blob and returns a state string.
fn state_alloc_string(pool: StatePool&, text: u8[:]) -> MrbValue {
    let offset = state_blob_allocate(pool, text.len);
    if offset < 0 {
        return mrb_nil();
    }
    let index = state_take_object(pool, ArenaObjectKind.String);
    if index < 0 {
        state_blob_free(pool, offset, text.len);
        return mrb_nil();
    }
    for at in 0..text.len {
        pool.blob[offset + at] = text[at];
    }
    pool.objects[index].text_offset_bytes = offset;
    pool.objects[index].text_length_bytes = text.len;
    return state_object_handle(pool, index);
}

// Instances receive a header from the free list when one exists. Disposal
// clears registration state; reclamation only frees the header once no root or
// reachable collection refers to it.
fn state_alloc_instance(pool: StatePool&, class_id: u32) -> MrbValue {
    assert(class_id < pool.classes.len);
    pool.error = VmError.Ok;
    let index = state_take_object(pool, ArenaObjectKind.Instance);
    if index < 0 {
        return mrb_nil();
    }
    pool.objects[index].class_index = class_id;
    return state_object_handle(pool, index);
}

fn state_alloc_int64(pool: StatePool&, value: i64) -> MrbValue {
    let index = state_take_object(pool, ArenaObjectKind.Int64);
    if index < 0 {
        return mrb_nil();
    }
    pool.objects[index].integer_value = value;
    return mrb_typed_arena_value(
        MRB_TAG_INT64, MRB_ARENA_STATE, index as u32, pool.objects[index].generation);
}

fn state_alloc_float(pool: StatePool&, value: f64) -> MrbValue {
    let index = state_take_object(pool, ArenaObjectKind.Float);
    if index < 0 {
        return mrb_nil();
    }
    pool.objects[index].float_value = value;
    return mrb_typed_arena_value(
        MRB_TAG_FLOAT, MRB_ARENA_STATE, index as u32, pool.objects[index].generation);
}

fn state_alloc_array(pool: StatePool&) -> MrbValue {
    return state_alloc_collection(pool, ArenaObjectKind.Array);
}

fn state_alloc_hash(pool: StatePool&) -> MrbValue {
    return state_alloc_collection(pool, ArenaObjectKind.Hash);
}

fn state_alloc_collection(pool: StatePool&, kind: ArenaObjectKind) -> MrbValue {
    let index = state_take_object(pool, kind);
    if index < 0 {
        return mrb_nil();
    }
    return state_object_handle(pool, index);
}

fn state_is_array(pool: StatePool&, value: MrbValue) -> bool {
    let object, ok = state_object(pool, value);
    return ok && object.kind == ArenaObjectKind.Array;
}

fn state_is_hash(pool: StatePool&, value: MrbValue) -> bool {
    let object, ok = state_object(pool, value);
    return ok && object.kind == ArenaObjectKind.Hash;
}

// Takes one array/hash slot node from the free list or grows the table.
fn state_take_slot(pool: StatePool&) -> i64 {
    if pool.free_slots.len > 0 {
        let index = pool.free_slots[pool.free_slots.len - 1];
        pool.free_slots.pop();
        pool.slots[index].allocated = true;
        return index;
    }
    if pool.slots.len >= MAX_STATE_SLOTS {
        pool.error = VmError.StateCapacity;
        return -1;
    }
    let index = pool.slots.len;
    pool.slots.push(ArenaSlot {
            key: mrb_nil(),
            value: mrb_nil(),
            previous_index: -1,
            next_index: -1,
            allocated: true,
        });
    return index;
}

fn state_release_slot(pool: StatePool&, slot_index: i64) {
    if slot_index < 0 || slot_index >= pool.slots.len {
        return;
    }
    pool.slots[slot_index].key = mrb_nil();
    pool.slots[slot_index].value = mrb_nil();
    pool.slots[slot_index].previous_index = -1;
    pool.slots[slot_index].next_index = -1;
    pool.slots[slot_index].allocated = false;
    pool.free_slots.push(slot_index);
}

// Appends one slot to `object_index`'s linked list. Values must already be
// promoted; callers that accept scratch values use `state_set_ivar` or the
// high-level builtins, which promote before reaching this helper.
fn state_append_slot(pool: StatePool&, object_index: i64, key: MrbValue, value: MrbValue) -> bool {
    assert(object_index >= 0);
    assert(object_index < pool.objects.len);
    let slot_index = state_take_slot(pool);
    if slot_index < 0 {
        return false;
    }
    let previous = pool.objects[object_index].items_last_index;
    pool.slots[slot_index] = ArenaSlot {
        key: key,
        value: value,
        previous_index: previous,
        next_index: -1,
        allocated: true,
    };
    if previous >= 0 {
        pool.slots[previous].next_index = slot_index;
    } else {
        pool.objects[object_index].items_first_index = slot_index;
    }
    pool.objects[object_index].items_last_index = slot_index;
    pool.objects[object_index].item_count += 1;
    return true;
}

fn state_slot_index_at(pool: StatePool&, object_index: i64, position: i64) -> i64 {
    if position < 0 {
        return -1;
    }
    var slot_index = pool.objects[object_index].items_first_index;
    var remaining = position;
    while slot_index >= 0 && remaining > 0 {
        slot_index = pool.slots[slot_index].next_index;
        remaining -= 1;
    }
    return slot_index;
}

fn state_array_push(pool: StatePool&, array: MrbValue, value: MrbValue) -> bool {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return false;
    }
    let pushed = state_append_slot(pool, mrb_arena_index(array), mrb_nil(), value);
    if pushed {
        state_mark_collection_mutated(pool, array);
    }
    return pushed;
}

fn state_array_pop(pool: StatePool&, array: MrbValue) -> MrbValue, bool {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array || object.item_count == 0 {
        return mrb_nil(), false;
    }
    let object_index = mrb_arena_index(array)as i64;
    let tail = object.items_last_index;
    let value = pool.slots[tail].value;
    let previous = pool.slots[tail].previous_index;
    if previous >= 0 {
        pool.slots[previous].next_index = -1;
    } else {
        pool.objects[object_index].items_first_index = -1;
    }
    pool.objects[object_index].items_last_index = previous;
    pool.objects[object_index].item_count -= 1;
    state_release_slot(pool, tail);
    state_mark_collection_mutated(pool, array);
    return value, true;
}

fn state_array_get(pool: StatePool&, array: MrbValue, position: i64) -> MrbValue, bool {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return mrb_nil(), false;
    }
    if position < 0 || position >= object.item_count {
        return mrb_nil(), false;
    }
    let slot_index = state_slot_index_at(pool, mrb_arena_index(array), position);
    if slot_index < 0 {
        return mrb_nil(), false;
    }
    return pool.slots[slot_index].value, true;
}

fn state_array_set(pool: StatePool&, array: MrbValue, position: i64, value: MrbValue) -> bool {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return false;
    }
    if position < 0 || position >= object.item_count {
        return false;
    }
    let slot_index = state_slot_index_at(pool, mrb_arena_index(array), position);
    if slot_index < 0 {
        return false;
    }
    let previous = pool.slots[slot_index].value;
    if state_value_equal(pool, previous, value) {
        return true;
    }
    pool.slots[slot_index].value = value;
    state_mark_collection_mutated(pool, array);
    return true;
}

fn state_array_last(pool: StatePool&, array: MrbValue) -> MrbValue, bool {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array || object.item_count == 0 {
        return mrb_nil(), false;
    }
    return pool.slots[object.items_last_index].value, true;
}

fn state_array_length(pool: StatePool&, array: MrbValue) -> i64 {
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return 0;
    }
    return object.item_count;
}

fn state_hash_set(pool: StatePool&, hash: MrbValue, key: MrbValue, value: MrbValue) -> bool {
    let object, ok = state_object(pool, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if mrb_value_identical(pool.slots[slot_index].key, key) {
            let previous = pool.slots[slot_index].value;
            if state_value_equal(pool, previous, value) {
                return true;
            }
            pool.slots[slot_index].value = value;
            state_mark_collection_mutated(pool, hash);
            return true;
        }
        slot_index = pool.slots[slot_index].next_index;
    }
    let inserted = state_append_slot(pool, mrb_arena_index(hash), key, value);
    if inserted {
        state_mark_collection_mutated(pool, hash);
    }
    return inserted;
}

fn state_hash_get(pool: StatePool&, hash: MrbValue, key: MrbValue) -> MrbValue, bool {
    let object, ok = state_object(pool, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return mrb_nil(), false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if mrb_value_identical(pool.slots[slot_index].key, key) {
            return pool.slots[slot_index].value, true;
        }
        slot_index = pool.slots[slot_index].next_index;
    }
    return mrb_nil(), false;
}

fn state_hash_length(pool: StatePool&, hash: MrbValue) -> i64 {
    let object, ok = state_object(pool, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return 0;
    }
    return object.item_count;
}

fn state_object(pool: StatePool&, value: MrbValue) -> ArenaObject, bool {
    if !mrb_is_arena(value) {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    if mrb_arena_tag(value) != MRB_ARENA_STATE {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    let index = mrb_arena_index(value)as i64;
    if index < 0 || index >= pool.objects.len {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    let object = pool.objects[index];
    if !object.allocated || object.generation != mrb_arena_generation(value) {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    return object, true;
}

fn state_string_bytes(pool: StatePool&, value: MrbValue) -> const u8[:] {
    let object, ok = state_object(pool, value);
    if !ok || object.kind != ArenaObjectKind.String {
        return "";
    }
    let start = object.text_offset_bytes;
    let stop = start + object.text_length_bytes;
    if start < 0 || stop > pool.blob.len {
        return "";
    }
    return pool.blob[start..stop];
}

// Registers an instance as a component root exactly once.
fn state_register_component(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    for component in pool.components {
        if mrb_value_identical(component, instance) {
            return true;
        }
    }
    assert(pool.components.len < MAX_STATE_COMPONENTS);
    pool.components.push(instance);
    return true;
}

// Removes an instance from the component root registry. Order is preserved so
// `state_component_at` stays stable for observers, and repeated calls are
// harmless.
fn state_unregister_component(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    var at = 0;
    while at < pool.components.len {
        if mrb_value_identical(pool.components[at], instance) {
            var cursor = at;
            while cursor + 1 < pool.components.len {
                pool.components[cursor] = pool.components[cursor + 1];
                cursor += 1;
            }
            pool.components.pop();
            return true;
        }
        at += 1;
    }
    return false;
}

// Marks the instance header as disposed. Reclamation frees the header and ivar
// storage once no root or reachable collection refers to it, but no host entry
// may use the disposed handle in the meantime.
fn state_mark_instance_disposed(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    let index = mrb_arena_index(instance)as i64;
    pool.objects[index].disposed = true;
    pool.objects[index].dirty_ivars = mask_clear();
    return true;
}

fn state_instance_disposed(pool: StatePool&, value: MrbValue) -> bool {
    if !mrb_is_state(value) {
        return false;
    }
    let index = mrb_arena_index(value)as i64;
    if index < 0 || index >= pool.objects.len {
        return false;
    }
    if !pool.objects[index].allocated
        || pool.objects[index].generation != mrb_arena_generation(value) {
        // A reclaimed header is indistinguishable from a disposed instance to a
        // host that kept the old handle. Treat it as disposed so stale unmounts
        // and callbacks fail with the same diagnostic instead of aliasing.
        return true;
    }
    let object = pool.objects[index];
    return object.kind == ArenaObjectKind.Instance && object.disposed;
}

// Deep-promotes any scratch value into the state pool. Immediates and state
// handles are already durable and round-trip unchanged.
fn promote_to_state(pool: StatePool&, scratch: ScratchArena&, value: MrbValue) -> MrbValue {
    return promote_to_state_at(pool, scratch, value, 0);
}

// Recursive core of `promote_to_state`: strings copy their bytes, instances
// copy their ivar list, and arrays/hashes copy every element while promoting
// nested values. Each scratch occurrence becomes its own state object, and a
// cyclic or overly deep graph trips the depth assert rather than recursing
// without a bound.
recursive fn promote_to_state_at(pool: StatePool&, scratch: ScratchArena&, value: MrbValue, depth: i64) -> MrbValue {
    if !mrb_is_arena(value) {
        return value;
    }
    if mrb_arena_tag(value) == MRB_ARENA_STATE {
        return value;
    }
    assert(depth < MAX_PROMOTION_DEPTH);
    let object, ok = scratch_object(scratch, value);
    if !ok {
        return mrb_nil();
    }
    match object.kind {
        String => {
            return state_alloc_string(pool, scratch_string_bytes(scratch, value));
        },
        Int64 => {
            return state_alloc_int64(pool, object.integer_value);
        },
        Float => {
            return state_alloc_float(pool, object.float_value);
        },
        Instance => {
            let promoted = state_alloc_instance(pool, object.class_index);
            if !mrb_is_state(promoted) {
                return mrb_nil();
            }
            let index = mrb_arena_index(promoted);
            var slot_index = object.ivar_head_index;
            while slot_index >= 0 {
                let slot = scratch.ivars[slot_index];
                let stored = promote_to_state_at(pool, scratch, slot.value, depth + 1);
                state_store_ivar_raw(pool, index, slot.key, stored);
                slot_index = slot.next_index;
            }
            return promoted;
        },
        Array => {
            let promoted = state_alloc_array(pool);
            if !mrb_is_state(promoted) {
                return mrb_nil();
            }
            var slot_index = object.items_first_index;
            while slot_index >= 0 {
                let slot = scratch.slots[slot_index];
                let stored = promote_to_state_at(pool, scratch, slot.value, depth + 1);
                state_array_push(pool, promoted, stored);
                slot_index = slot.next_index;
            }
            return promoted;
        },
        Hash => {
            let promoted = state_alloc_hash(pool);
            if !mrb_is_state(promoted) {
                return mrb_nil();
            }
            var slot_index = object.items_first_index;
            while slot_index >= 0 {
                let slot = scratch.slots[slot_index];
                let stored_key = promote_to_state_at(pool, scratch, slot.key, depth + 1);
                let stored_value = promote_to_state_at(pool, scratch, slot.value, depth + 1);
                state_hash_set(pool, promoted, stored_key, stored_value);
                slot_index = slot.next_index;
            }
            return promoted;
        },
    }
}
