// u64 bitmask signals for component instance variables.
//
// Every component instance owns a 64-bit `dirty_ivars` mask, and every ivar
// slot owns a stable `bit_index` (0..63). While one binding getter is being
// evaluated, `StatePool.tracking_instance_index` names the instance under
// observation and each `state_get_ivar` of that instance ORs the slot bit into
// `StatePool.active_read_mask`. Writes run the other direction: an ivar store
// compares the old and new value and dirties the bit only when it changed.
//
// State collections mutate in place, so a push, pop or set on an array or hash
// reachable from a component ivar must dirty that ivar. Rather than mirroring
// reference counts, `state_mark_collection_mutated` walks each registered
// component's ivars with a bounded depth and marks every ivar whose value is or
// contains the mutated collection. The depth bound keeps cyclic collections
// terminating; aliased ivars all receive the bit.
//
// This module owns the ivar table and the reactive masks; `state_pool` owns
// allocation and collection storage. The two modules import each other, which
// Goose resolves because a program is compiled as one translation unit.
namespace vm;

import.state_pool;
import.value_arena;
import.vm_core;
import.vm_entry;

// A component tracks at most one bit per ivar, so 64 distinct ivars fit.
let MAX_TRACKED_IVARS: u8 = 64;
let MAX_SIGNAL_DEPTH = 32;
let MAX_BINDINGS = 256;

// One DOM binding: which instance owns it, which getter produces its text, and
// the ivar mask recorded the last time the getter ran. `initialized` is false
// until the binding has produced its first value, so mount evaluates it even
// when the instance has no dirty bits yet.
struct BindingEntry {
    instance: MrbValue,
    binding_id: u16,
    getter_symbol: u32,
    dep_mask: u64,
    initialized: bool,
}

// Registers one getter for an instance. Re-registering the same binding id
// replaces the getter and forces a fresh dependency scan.
fn binding_register(pool: StatePool&, instance: MrbValue, binding_id: u32, getter_symbol: u32) -> i64 {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance || binding_id > 0xFFFF {
        return -1;
    }
    for index in 0..pool.bindings.len {
        let entry = pool.bindings[index];
        if mrb_value_identical(entry.instance, instance) && entry.binding_id == binding_id {
            pool.bindings[index].getter_symbol = getter_symbol;
            pool.bindings[index].dep_mask = 0;
            pool.bindings[index].initialized = false;
            return 0;
        }
    }
    if pool.bindings.len >= MAX_BINDINGS {
        return -1;
    }
    pool.bindings.push(BindingEntry {
            instance: instance,
            binding_id: binding_id as u16,
            getter_symbol: getter_symbol,
            dep_mask: 0,
            initialized: false,
        });
    return 0;
}

// Appends one little-endian u16. The DOM loader decodes patch headers without
// depending on host endianness.
fn binding_append_u16_le(out: u8[>..]&, value: u16) {
    out.push((value & 0xFF)as u8);
    out.push((value >> 8)as u8);
}

fn binding_append_u32_le(out: u8[>..]&, value: u32) {
    out.push((value & 0xFF)as u8);
    out.push(((value >> 8) & 0xFF)as u8);
    out.push(((value >> 16) & 0xFF)as u8);
    out.push((value >> 24)as u8);
}

// Renders one binding result as text. Strings return their existing bytes;
// scalar values are formatted into the tick arena. The view stays valid until
// the next top-level entry resets the arena.
fn binding_text(machine: Vm&, value: MrbValue) -> const u8[:] {
    if mrb_is_nil(value) {
        return "";
    }
    if mrb_is_scratch(value) || mrb_is_state(value) {
        return vm_string_value(machine, value);
    }
    var text: u8[>..] = [];
    vm_append_value_text(machine, text, value);
    let handle = scratch_alloc_string(machine.scratch, text[..]);
    return scratch_string_bytes(machine.scratch, handle);
}

// Evaluates one binding getter inside a fresh dependency-tracking window.
// `entry.dep_mask` is replaced, not OR-ed, so conditional branches drop
// dependencies they no longer read on the next evaluation.
fn vm_eval_binding(machine: Vm&, entry: BindingEntry&) -> const u8[:] {
    if !state_tracking_begin(machine.pool, entry.instance) {
        entry.initialized = false;
        return "";
    }
    let no_args: MrbValue[1] = [mrb_nil()];
    let value = vm_call_args(machine, entry.instance, entry.getter_symbol, no_args[..0]);
    entry.dep_mask = state_tracking_end(machine.pool);
    if machine.error != VmError.Ok {
        entry.initialized = false;
        return "";
    }
    entry.initialized = true;
    return binding_text(machine, value);
}

// Re-evaluates the instance's uninitialized bindings plus every binding whose
// recorded dependencies intersect `dirty_ivars`. Each emitted record is
// `[binding_id u16 LE][byte_len u32 LE][utf8 bytes]`. The dirty mask is cleared
// once the pass finishes, and -1 reports a getter failure.
fn vm_flush_dirty_bindings(machine: Vm&, instance: MrbValue, out_patches: u8[>..]&) -> i64 {
    if !mrb_is_state(instance) {
        return 0;
    }
    let dirty = state_dirty_mask(machine.pool, instance);
    var emitted = 0;
    var first_error = VmError.Ok;
    for index in 0..machine.pool.bindings.len {
        let stored = machine.pool.bindings[index];
        if !mrb_value_identical(stored.instance, instance) {
            continue;
        }
        if stored.initialized && (stored.dep_mask & dirty) == 0 {
            continue;
        }
        var entry = stored;
        let text = vm_eval_binding(machine, entry);
        machine.pool.bindings[index] = entry;
        if machine.error != VmError.Ok {
            if first_error == VmError.Ok {
                first_error = machine.error;
            }
            continue;
        }
        binding_append_u16_le(out_patches, entry.binding_id);
        binding_append_u32_le(out_patches, text.len as u32);
        out_patches.append(text);
        emitted += 1;
    }
    state_clear_dirty_mask(machine.pool, instance);
    if first_error != VmError.Ok {
        machine.error = first_error;
        return -1;
    }
    return emitted;
}

// Returns the mask bit for one ivar slot.
fn state_ivar_bit(bit_index: u8) -> u64 {
    assert(bit_index < MAX_TRACKED_IVARS);
    return (1 as u64) << bit_index;
}

// Starts observing ivar reads on `instance` and returns false for non-instances.
// Any previous tracking window is replaced; callers must not nest windows.
fn state_tracking_begin(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    pool.tracking_instance_index = mrb_arena_index(instance);
    pool.active_read_mask = 0;
    return true;
}

// Ends the tracking window and returns the reads recorded during it.
fn state_tracking_end(pool: StatePool&) -> u64 {
    let mask = pool.active_read_mask;
    pool.active_read_mask = 0;
    pool.tracking_instance_index = -1;
    return mask;
}

fn state_tracked_read_mask(pool: StatePool&) -> u64 {
    return pool.active_read_mask;
}

fn state_dirty_mask(pool: StatePool&, instance: MrbValue) -> u64 {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return 0;
    }
    return pool.objects[mrb_arena_index(instance)as i64].dirty_ivars;
}

fn state_clear_dirty_mask(pool: StatePool&, instance: MrbValue) -> bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    pool.objects[mrb_arena_index(instance)as i64].dirty_ivars = 0;
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
// Returns the new slot index so the caller can inspect its assigned bit.
fn state_append_ivar_slot(pool: StatePool&, object_index: i64, key: u32, value: MrbValue) -> i64 {
    assert(object_index >= 0);
    assert(object_index < pool.objects.len);
    assert(pool.ivars.len < MAX_STATE_IVARS);
    let bit_index = pool.objects[object_index].ivar_count;
    assert(bit_index < MAX_TRACKED_IVARS);
    let slot_index = pool.ivars.len;
    pool.ivars.push(IvarSlot {
            key: key,
            bit_index: bit_index,
            value: value,
            next_index: pool.objects[object_index].ivar_head_index,
        });
    pool.objects[object_index].ivar_head_index = slot_index;
    pool.objects[object_index].ivar_count += 1;
    return slot_index;
}

fn state_mark_ivar_dirty(pool: StatePool&, object_index: i64, bit_index: u8) {
    assert(object_index >= 0);
    assert(object_index < pool.objects.len);
    pool.objects[object_index].dirty_ivars |= state_ivar_bit(bit_index);
}

// Value equality for dirtiness: identical handles, or equal state string bytes.
// Distinct containers stay distinct even when their contents match, matching
// Ruby's reference semantics for `@ivar` assignment.
fn state_value_equal(pool: StatePool&, left: MrbValue, right: MrbValue) -> bool {
    if mrb_value_identical(left, right) {
        return true;
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

// Reads an ivar, recording the slot bit whenever `instance` is the tracked one.
// Missed ivars are allocated as nil during tracking so that later conditional
// reads keep a stable bit instead of shifting other slots.
fn state_get_ivar(pool: StatePool&, instance: MrbValue, key: u32) -> MrbValue, bool {
    let object, ok = state_object(pool, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return mrb_nil(), false;
    }
    let instance_index = mrb_arena_index(instance)as i64;
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        let slot = pool.ivars[slot_index];
        if slot.key == key {
            if pool.tracking_instance_index == instance_index {
                pool.active_read_mask |= state_ivar_bit(slot.bit_index);
            }
            return slot.value, true;
        }
        slot_index = slot.next_index;
    }
    if pool.tracking_instance_index == instance_index {
        let created = state_append_ivar_slot(pool, instance_index, key, mrb_nil());
        pool.active_read_mask |= state_ivar_bit(pool.ivars[created].bit_index);
    }
    return mrb_nil(), false;
}

// Reports whether `target` is `root` or appears inside its collection contents.
recursive fn state_value_contains(pool: StatePool&, root: MrbValue, target: MrbValue, depth: i64) -> bool {
    if mrb_value_identical(root, target) {
        return true;
    }
    if depth >= MAX_SIGNAL_DEPTH {
        return false;
    }
    let object, ok = state_object(pool, root);
    if !ok {
        return false;
    }
    if object.kind != ArenaObjectKind.Array && object.kind != ArenaObjectKind.Hash {
        return false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if state_value_contains(pool, pool.slots[slot_index].value, target, depth + 1) {
            return true;
        }
        slot_index = pool.slots[slot_index].next_index;
    }
    return false;
}

// Dirties every component ivar that holds the mutated collection, directly or
// through nested arrays and hashes.
fn state_mark_collection_mutated(pool: StatePool&, collection: MrbValue) {
    if pool.components.len == 0 {
        return;
    }
    for component_index in pool.components {
        let instance_index = component_index as i64;
        var slot_index = pool.objects[instance_index].ivar_head_index;
        while slot_index >= 0 {
            if state_value_contains(pool, pool.ivars[slot_index].value, collection, 0) {
                state_mark_ivar_dirty(pool, instance_index, pool.ivars[slot_index].bit_index);
            }
            slot_index = pool.ivars[slot_index].next_index;
        }
    }
}
