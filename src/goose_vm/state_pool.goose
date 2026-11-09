// Persistent state pool for classes, component instances and their ivars.
//
// The scratch arena is wiped at the end of every tick. Anything that must
// survive, such as a component's `@ivar` table, lives here instead: class
// definitions, instances and ivar slots all grow monotonically, and objects
// are addressed through the same 31-bit state handles used by `MrbValue`.
namespace vm;

import.value_arena;

// The state pool is long-lived, so its limits are larger but still enforced.
let MAX_STATE_CLASSES = 256;
let MAX_STATE_OBJECTS = 4096;
let MAX_STATE_IVARS = 8192;
let MAX_STATE_BYTES = 1048576;
let MAX_STATE_COMPONENTS = 256;
let MAX_PROMOTION_DEPTH = 32;

let NULL_CLASS_ID: u32 = 0xFFFFFFFF;

// A class definition. The class value itself is an immediate class ID.
struct ClassDef {
    name_symbol: u32,
    superclass_id: u32,
}

// Long-lived objects, classes and registered component roots. The VM owns one
// instance for its lifetime; unlike the scratch arena, this pool never resets.
root struct StatePool {
    classes: ClassDef[>..] = [],
    objects: ArenaObject[>..] = [],
    ivars: IvarSlot[>..] = [],
    components: u32[>..] = [],
    blob: u8[>..] = [],
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

fn state_class_count(pool: StatePool&) -> i64 {
    return pool.classes.len;
}

fn state_component_count(pool: StatePool&) -> i64 {
    return pool.components.len;
}

fn state_component_at(pool: StatePool&, at: i64) -> MrbValue {
    assert(at >= 0);
    assert(at < pool.components.len);
    return mrb_arena_value(MRB_ARENA_STATE, pool.components[at]);
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

// Copies `text` into the persistent state blob and returns a state string.
fn state_alloc_string(pool: StatePool&, text: u8[:]) -> MrbValue {
    assert(pool.objects.len < MAX_STATE_OBJECTS);
    assert(pool.blob.len + text.len <= MAX_STATE_BYTES);
    let offset = pool.blob.len;
    pool.blob.append(text);
    let index = pool.objects.len;
    pool.objects.push(ArenaObject {
            kind: ArenaObjectKind.String,
            text_offset_bytes: offset,
            text_length_bytes: text.len,
            class_index: 0,
            ivar_head_index: -1,
        });
    return mrb_arena_value(MRB_ARENA_STATE, index as u32);
}

fn state_alloc_instance(pool: StatePool&, class_id: u32) -> MrbValue {
    assert(class_id < pool.classes.len);
    assert(pool.objects.len < MAX_STATE_OBJECTS);
    let index = pool.objects.len;
    pool.objects.push(ArenaObject {
            kind: ArenaObjectKind.Instance,
            text_offset_bytes: 0,
            text_length_bytes: 0,
            class_index: class_id,
            ivar_head_index: -1,
        });
    return mrb_arena_value(MRB_ARENA_STATE, index as u32);
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
    return pool.objects[index], true;
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

// Stores an already-promoted value. Promotion happens in `promote_to_state`;
// this helper never copies, so recursive promotion cannot re-promote a value.
fn state_store_ivar_raw(pool: StatePool&, object_index: u32, key: u32, value: MrbValue) -> bool {
    assert(object_index < pool.objects.len);
    let index = object_index as i64;
    if pool.objects[index].kind != ArenaObjectKind.Instance {
        return false;
    }
    var slot_index = pool.objects[index].ivar_head_index;
    while slot_index >= 0 {
        if pool.ivars[slot_index].key == key {
            pool.ivars[slot_index].value = value;
            return true;
        }
        slot_index = pool.ivars[slot_index].next_index;
    }
    assert(pool.ivars.len < MAX_STATE_IVARS);
    let new_index = pool.ivars.len;
    pool.ivars.push(IvarSlot {
            key: key,
            value: value,
            next_index: pool.objects[index].ivar_head_index,
        });
    pool.objects[index].ivar_head_index = new_index;
    return true;
}

// Stores an ivar on a state instance, promoting scratch values first.
fn state_set_ivar(pool: StatePool&, scratch: ScratchArena&, instance: MrbValue, key: u32, value: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    let stored = promote_to_state(pool, scratch, value);
    return state_store_ivar_raw(pool, mrb_arena_index(instance), key, stored);
}

fn state_get_ivar(pool: StatePool&, instance: MrbValue, key: u32) -> MrbValue, bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return mrb_nil(), false;
    }
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        let slot = pool.ivars[slot_index];
        if slot.key == key {
            return slot.value, true;
        }
        slot_index = slot.next_index;
    }
    return mrb_nil(), false;
}

fn state_register_component(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    let index = mrb_arena_index(instance);
    for component in pool.components {
        if component == index {
            return true;
        }
    }
    assert(pool.components.len < MAX_STATE_COMPONENTS);
    pool.components.push(index);
    return true;
}

// Deep-promotes any scratch value into the state pool. Immediates and state
// handles are already durable and round-trip unchanged.
fn promote_to_state(pool: StatePool&, scratch: ScratchArena&, value: MrbValue) -> MrbValue {
    return promote_to_state_at(pool, scratch, value, 0);
}

// Recursive core of `promote_to_state`: strings copy their bytes, and
// instances copy their linked ivar list after promoting every value. Each
// scratch occurrence becomes its own state object, and a cyclic or overly deep
// graph trips the depth assert rather than recursing without a bound.
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
        Instance => {
            let promoted = state_alloc_instance(pool, object.class_index);
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
    }
}
