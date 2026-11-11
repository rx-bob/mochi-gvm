// Bitmask signals for component instance variables.
//
// Every component instance owns a 256-bit `dirty_ivars` mask, and every ivar
// slot owns a stable `bit_index` (0..255). While one binding getter is being
// evaluated, `StatePool.tracking_instance_index` names the instance under
// observation and each `state_get_ivar` of that instance sets the slot bit in
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

import.collection_arena;
import.ivar_mask;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_entry;

let MAX_SIGNAL_DEPTH = 32;
let MAX_BINDINGS = 2048;
let MAX_JSON_DEPTH = 16;

// One DOM binding: which instance owns it, which getter produces its text, and
// the ivar mask recorded the last time the getter ran. `initialized` is false
// until the binding has produced its first value, so mount evaluates it even
// when the instance has no dirty bits yet.
struct BindingEntry {
    instance: MrbValue,
    binding_id: u16,
    getter_symbol: u32,
    dep_mask: IvarMask,
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
            pool.bindings[index].dep_mask = mask_clear();
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
            dep_mask: mask_clear(),
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

// Returns true when a value is an Array or Hash in either arena. The loader's
// `each` binding receives a JSON array, so collections are serialized instead
// of being treated as strings with an empty byte view.
fn binding_value_is_array(machine: Vm&, value: MrbValue) -> bool {
    if mrb_is_scratch(value) {
        return scratch_is_array(machine.scratch, value);
    }
    if mrb_is_state(value) {
        return state_is_array(machine.pool, value);
    }
    return false;
}

fn binding_value_is_hash(machine: Vm&, value: MrbValue) -> bool {
    if mrb_is_scratch(value) {
        return scratch_is_hash(machine.scratch, value);
    }
    if mrb_is_state(value) {
        return state_is_hash(machine.pool, value);
    }
    return false;
}

fn binding_json_hex_digit(value: u8) -> u8 {
    if value < 10 {
        return 48 + value;
    }
    return 87 + value;
}

// Escapes one UTF-8 byte string for a JSON string literal. Non-ASCII bytes pass
// through unchanged, which is valid JSON and preserves Ruby symbol names.
fn binding_json_escape(out: u8[>..]&, bytes: u8[:]) {
    for index in 0..bytes.len {
        let byte = bytes[index];
        if byte == 34 {
            out.push(92);
            out.push(34);
        } else if byte == 92 {
            out.push(92);
            out.push(92);
        } else if byte == 8 {
            out.push(92);
            out.push(98);
        } else if byte == 9 {
            out.push(92);
            out.push(116);
        } else if byte == 10 {
            out.push(92);
            out.push(110);
        } else if byte == 12 {
            out.push(92);
            out.push(102);
        } else if byte == 13 {
            out.push(92);
            out.push(114);
        } else if byte < 32 {
            out.push(92);
            out.push(117);
            out.push(48);
            out.push(48);
            out.push(binding_json_hex_digit(byte >> 4));
            out.push(binding_json_hex_digit(byte & 0x0F));
        } else {
            out.push(byte);
        }
    }
}

fn binding_json_append_key(machine: Vm&, out: u8[>..]&, key: MrbValue) {
    out.push(34);
    if mrb_is_symbol(key) {
        binding_json_escape(out, symbol_name(mrb_symbol_id(key)));
    } else {
        var text: u8[>..] = [];
        vm_append_value_text(machine, text, key);
        binding_json_escape(out, text[..]);
    }
    out.push(34);
}

fn binding_array_length(machine: Vm&, value: MrbValue) -> i64 {
    if mrb_is_scratch(value) {
        return scratch_array_length(machine.scratch, value);
    }
    return state_array_length(machine.pool, value);
}

fn binding_array_get(machine: Vm&, value: MrbValue, index: i64) -> MrbValue, bool {
    if mrb_is_scratch(value) {
        return scratch_array_get(machine.scratch, value, index);
    }
    return state_array_get(machine.pool, value, index);
}

fn binding_hash_length(machine: Vm&, value: MrbValue) -> i64 {
    if mrb_is_scratch(value) {
        return scratch_hash_length(machine.scratch, value);
    }
    return state_hash_length(machine.pool, value);
}

fn binding_hash_slot_index(machine: Vm&, value: MrbValue, position: i64) -> i64 {
    let object_index = mrb_arena_index(value)as i64;
    if mrb_is_scratch(value) {
        return scratch_slot_index_at(machine.scratch, object_index, position);
    }
    return state_slot_index_at(machine.pool, object_index, position);
}

fn binding_hash_slot_key(machine: Vm&, value: MrbValue, slot_index: i64) -> MrbValue {
    if mrb_is_scratch(value) {
        return machine.scratch.slots[slot_index].key;
    }
    return machine.pool.slots[slot_index].key;
}

fn binding_hash_slot_value(machine: Vm&, value: MrbValue, slot_index: i64) -> MrbValue {
    if mrb_is_scratch(value) {
        return machine.scratch.slots[slot_index].value;
    }
    return machine.pool.slots[slot_index].value;
}

recursive fn binding_json_append_array(machine: Vm&, out: u8[>..]&, value: MrbValue, depth: i64) {
    let length = binding_array_length(machine, value);
    out.push(91);
    for index in 0..length {
        if index > 0 {
            out.push(44);
        }
        let item, found = binding_array_get(machine, value, index);
        if found {
            binding_json_append_value(machine, out, item, depth + 1);
        } else {
            out.append("null");
        }
    }
    out.push(93);
}

recursive fn binding_json_append_hash(machine: Vm&, out: u8[>..]&, value: MrbValue, depth: i64) {
    let length = binding_hash_length(machine, value);
    out.push(123);
    for position in 0..length {
        if position > 0 {
            out.push(44);
        }
        let slot_index = binding_hash_slot_index(machine, value, position);
        if slot_index < 0 {
            continue;
        }
        binding_json_append_key(machine, out, binding_hash_slot_key(machine, value, slot_index));
        out.push(58);
        binding_json_append_value(
            machine, out, binding_hash_slot_value(machine, value, slot_index), depth + 1);
    }
    out.push(125);
}

// Appends one JSON value. Scalars mirror `binding_text`; collections recurse
// with a depth bound so cyclic or very deep state cannot exhaust the stack.
recursive fn binding_json_append_value(machine: Vm&, out: u8[>..]&, value: MrbValue, depth: i64) {
    if depth > MAX_JSON_DEPTH {
        out.append("null");
        return;
    }
    if binding_value_is_array(machine, value) {
        binding_json_append_array(machine, out, value, depth);
        return;
    }
    if binding_value_is_hash(machine, value) {
        binding_json_append_hash(machine, out, value, depth);
        return;
    }
    if mrb_is_nil(value) {
        out.append("null");
        return;
    }
    if mrb_is_true(value) {
        out.append("true");
        return;
    }
    if mrb_is_false(value) {
        out.append("false");
        return;
    }
    if mrb_is_fixnum(value) {
        mrb_format_fixnum(out, mrb_fixnum_value(value));
        return;
    }
    if mrb_is_symbol(value) {
        out.push(34);
        binding_json_escape(out, symbol_name(mrb_symbol_id(value)));
        out.push(34);
        return;
    }
    if mrb_is_scratch(value) || mrb_is_state(value) {
        out.push(34);
        binding_json_escape(out, vm_string_value(machine, value));
        out.push(34);
        return;
    }
    out.append("null");
}

// Renders one binding result as text. Strings return their existing bytes and
// Arrays/Hashes become JSON, which is how `each` bindings transport keyed
// rows. The view stays valid until the next top-level entry resets the arena.
fn binding_text(machine: Vm&, value: MrbValue) -> const u8[:] {
    if mrb_is_nil(value) {
        return "";
    }
    if binding_value_is_array(machine, value) || binding_value_is_hash(machine, value) {
        var json: u8[>..] = [];
        binding_json_append_value(machine, json, value, 0);
        let handle = scratch_alloc_string(machine.scratch, json[..]);
        return scratch_string_bytes(machine.scratch, handle);
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
        if stored.initialized && !mask_intersects(stored.dep_mask, dirty) {
            continue;
        }
        var entry = stored;
        let text = vm_eval_binding(machine, entry);
        machine.pool.bindings[index] = entry;
        if machine.error != VmError.Ok {
            if first_error == VmError.Ok {
                first_error = machine.error;
                let class_id, _ = vm_receiver_class_id(machine, instance);
                vm_set_error_context(machine, class_id, entry.getter_symbol, entry.binding_id);
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
                var mask = pool.active_read_mask;
                mask_set_bit(mask, slot.bit_index);
                pool.active_read_mask = mask;
            }
            return slot.value, true;
        }
        slot_index = slot.next_index;
    }
    if pool.tracking_instance_index == instance_index {
        let created = state_append_ivar_slot(pool, instance_index, key, mrb_nil());
        if created >= 0 {
            var mask = pool.active_read_mask;
            mask_set_bit(mask, pool.ivars[created].bit_index);
            pool.active_read_mask = mask;
        }
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
