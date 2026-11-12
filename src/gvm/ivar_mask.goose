// 256-bit dependency masks and the mask-backed ivar tracking helpers.
//
// A component can track up to 256 ivars. Each mask packs those bits into four
// little-endian words: word 0 holds bits 0..63, word 1 bits 64..127, word 2
// bits 128..191, and word 3 bits 192..255. Dependency tracking and dirty signal
// propagation use the same layout, so intersecting two masks is a word-wise
// test and setting a bit only touches the owning word.
namespace vm;

import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;

let MAX_TRACKED_IVARS: u16 = 256;

// A 256-bit set of tracked instance variables.
struct IvarMask {
    w0: u64,
    w1: u64,
    w2: u64,
    w3: u64,
}

// Returns an empty mask.
fn mask_clear() -> IvarMask {
    return IvarMask {
        w0: 0,
        w1: 0,
        w2: 0,
        w3: 0,
    };
}

// Sets one bit in `mask`. Out-of-range indices are ignored because every
// caller already enforces `MAX_TRACKED_IVARS` when it assigns a slot.
fn mask_set_bit(mask: IvarMask&, bit_index: u16) {
    if bit_index < 64 {
        mask.w0 |= (1 as u64) << (bit_index as u8);
    } else if bit_index < 128 {
        mask.w1 |= (1 as u64) << ((bit_index - 64)as u8);
    } else if bit_index < 192 {
        mask.w2 |= (1 as u64) << ((bit_index - 128)as u8);
    } else if bit_index < MAX_TRACKED_IVARS {
        mask.w3 |= (1 as u64) << ((bit_index - 192)as u8);
    }
}

// Returns the union of two masks.
fn mask_or(left: IvarMask, right: IvarMask) -> IvarMask {
    return IvarMask {
        w0: left.w0 | right.w0,
        w1: left.w1 | right.w1,
        w2: left.w2 | right.w2,
        w3: left.w3 | right.w3,
    };
}

// Reports whether two masks share at least one bit.
fn mask_intersects(left: IvarMask, right: IvarMask) -> bool {
    return (left.w0 & right.w0) != 0
        || (left.w1 & right.w1) != 0
        || (left.w2 & right.w2) != 0
        || (left.w3 & right.w3) != 0;
}

// Reports whether two masks contain exactly the same bits.
fn mask_equal(left: IvarMask, right: IvarMask) -> bool {
    return left.w0 == right.w0
        && left.w1 == right.w1
        && left.w2 == right.w2
        && left.w3 == right.w3;
}

// Reports whether the mask has no bits set.
fn mask_is_empty(mask: IvarMask) -> bool {
    return mask.w0 == 0 && mask.w1 == 0 && mask.w2 == 0 && mask.w3 == 0;
}

// Returns a mask containing only `bit_index`. Out-of-range indices return an
// empty mask; slot allocation is the single place that enforces capacity.
fn state_ivar_bit(bit_index: u16) -> IvarMask {
    var mask = mask_clear();
    if bit_index < MAX_TRACKED_IVARS {
        mask_set_bit(mask, bit_index);
    }
    return mask;
}

// Starts observing ivar reads on `instance` and returns false for non-instances.
// Any previous tracking window is replaced; callers must not nest windows.
fn state_tracking_begin(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    pool.tracking_instance_index = mrb_arena_index(instance);
    pool.tracking_instance_generation = mrb_arena_generation(instance);
    pool.active_read_mask = mask_clear();
    return true;
}

// Ends the tracking window and returns the reads recorded during it.
fn state_tracking_end(pool: StatePool&) -> IvarMask {
    let mask = pool.active_read_mask;
    pool.active_read_mask = mask_clear();
    pool.tracking_instance_index = -1;
    pool.tracking_instance_generation = 0;
    return mask;
}

fn state_tracked_read_mask(pool: StatePool&) -> IvarMask {
    return pool.active_read_mask;
}

fn state_dirty_mask(pool: StatePool&, instance: MrbValue) -> IvarMask {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return mask_clear();
    }
    return pool.objects[mrb_arena_index(instance)as i64].dirty_ivars;
}

fn state_clear_dirty_mask(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    pool.objects[mrb_arena_index(instance)as i64].dirty_ivars = mask_clear();
    return true;
}

// Returns the slot bit for `key`, or -1 when the instance has no such ivar.
fn state_ivar_bit_index(pool: StatePool&, instance: MrbValue, key: u32) -> i64 {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return -1;
    }
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        let slot = pool.ivars[slot_index];
        if slot.key == key {
            return slot.bit_index;
        }
        slot_index = slot.next_index;
    }
    return -1;
}

// Appends a slot even when the value is unchanged; callers decide dirtiness.
// Returns the new slot index, or -1 when the instance already tracks the
// maximum number of ivars. The capacity failure is recoverable: it records
// `VmError.IvarCapacity` instead of trapping the WASM process.
fn state_append_ivar_slot(pool: StatePool&, object_index: i64, key: u32, value: MrbValue) -> i64 {
    assert(object_index >= 0);
    assert(object_index < pool.objects.len);
    let bit_index = pool.objects[object_index].ivar_count;
    if bit_index >= MAX_TRACKED_IVARS {
        pool.error = VmError.IvarCapacity;
        if !pool.failure.active {
            pool.failure = CapacityFailure {
                resource: CapacityResource.IvarsPerObject,
                requested: 1,
                used: bit_index,
                capacity: MAX_TRACKED_IVARS,
                active: true,
            };
        }
        return -1;
    }
    var slot_index = -1;
    if pool.free_ivars.len > 0 {
        slot_index = pool.free_ivars[pool.free_ivars.len - 1];
        pool.free_ivars.pop();
    } else {
        if pool.ivars.len >= MAX_STATE_IVARS {
            state_fail_capacity(pool, CapacityResource.StateIvars, 1, pool.ivars.len,
                MAX_STATE_IVARS);
            return -1;
        }
        slot_index = pool.ivars.len;
        pool.ivars.push(IvarSlot {
                key: key,
                bit_index: 0,
                value: mrb_nil(),
                next_index: -1,
                allocated: true,
            });
    }
    pool.ivars[slot_index] = IvarSlot {
        key: key,
        bit_index: bit_index as u8,
        value: value,
        next_index: pool.objects[object_index].ivar_head_index,
        allocated: true,
    };
    pool.objects[object_index].ivar_head_index = slot_index;
    pool.objects[object_index].ivar_count += 1;
    return slot_index;
}

fn state_mark_ivar_dirty(pool: StatePool&, object_index: i64, bit_index: u8) {
    assert(object_index >= 0);
    assert(object_index < pool.objects.len);
    var mask = pool.objects[object_index].dirty_ivars;
    mask_set_bit(mask, bit_index);
    pool.objects[object_index].dirty_ivars = mask;
}

// Classifies a live numeric value for dirtiness checks without importing the
// arithmetic core, which would create another state-pool dependency cycle.
fn state_number_kind(pool: StatePool&, value: MrbValue) -> u8 {
    if mrb_is_fixnum(value) || mrb_is_int64(value) {
        return 1;
    }
    if mrb_is_float(value) {
        return 2;
    }
    if !mrb_is_state(value) {
        return 0;
    }
    let object, ok = state_object(pool, value);
    if !ok {
        return 0;
    }
    if object.kind == ArenaObjectKind.Int64 {
        return 1;
    }
    if object.kind == ArenaObjectKind.Float {
        return 2;
    }
    return 0;
}

// Compares same-kind numbers by value. Cross-kind equality is deliberately not
// folded in: a type change is still an observable assignment and must dirty.
fn state_number_equal(pool: StatePool&, left: MrbValue, right: MrbValue) -> bool {
    if mrb_is_fixnum(left) && mrb_is_fixnum(right) {
        return mrb_fixnum_value(left) == mrb_fixnum_value(right);
    }
    if mrb_is_float(left) || mrb_is_float(right) {
        if !mrb_is_float(left) || !mrb_is_float(right) {
            return false;
        }
        let left_object, left_ok = state_object(pool, left);
        let right_object, right_ok = state_object(pool, right);
        if !left_ok || !right_ok {
            return false;
        }
        let left_value = left_object.float_value;
        let right_value = right_object.float_value;
        if left_value != left_value || right_value != right_value {
            return left_value != left_value && right_value != right_value;
        }
        return left_value == right_value;
    }
    if mrb_is_fixnum(left) {
        let right_object, right_ok = state_object(pool, right);
        return right_ok && right_object.kind == ArenaObjectKind.Int64
            && mrb_fixnum_value(left) == right_object.integer_value;
    }
    if mrb_is_fixnum(right) {
        let left_object, left_ok = state_object(pool, left);
        return left_ok && left_object.kind == ArenaObjectKind.Int64
            && left_object.integer_value == mrb_fixnum_value(right);
    }
    let left_object, left_ok = state_object(pool, left);
    let right_object, right_ok = state_object(pool, right);
    return left_ok && right_ok
        && left_object.kind == ArenaObjectKind.Int64
        && right_object.kind == ArenaObjectKind.Int64
        && left_object.integer_value == right_object.integer_value;
}

// Value equality for dirtiness: identical handles, same-kind numeric values, or
// equal state string bytes. Distinct containers stay distinct even when their
// contents match, matching Ruby's reference semantics for `@ivar` assignment.
fn state_value_equal(pool: StatePool&, left: MrbValue, right: MrbValue) -> bool {
    if mrb_value_identical(left, right) {
        return true;
    }
    let left_number = state_number_kind(pool, left);
    let right_number = state_number_kind(pool, right);
    if left_number != 0 || right_number != 0 {
        if left_number != right_number {
            return false;
        }
        return state_number_equal(pool, left, right);
    }
    if !mrb_is_state(left) || !mrb_is_state(right) {
        return false;
    }
    let left_object, left_ok = state_object(pool, left);
    let right_object, right_ok = state_object(pool, right);
    if !left_ok || !right_ok {
        return false;
    }
    if left_object.kind != ArenaObjectKind.String || right_object.kind != ArenaObjectKind.String {
        return false;
    }
    return state_string_bytes(pool, left) == state_string_bytes(pool, right);
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
            let previous = pool.ivars[slot_index].value;
            if state_value_equal(pool, previous, value) {
                return true;
            }
            pool.ivars[slot_index].value = value;
            state_mark_ivar_dirty(pool, index, pool.ivars[slot_index].bit_index);
            return true;
        }
        slot_index = pool.ivars[slot_index].next_index;
    }
    let created = state_append_ivar_slot(pool, index, key, value);
    if created < 0 {
        return false;
    }
    if !mrb_is_nil(value) {
        state_mark_ivar_dirty(pool, index, pool.ivars[created].bit_index);
    }
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
