// Inline intrinsic methods for the scalar VM.
//
// These helpers implement the Array, Hash, String and Boolean operations that
// the first real components use. They are zone-aware: values may live in the
// tick scratch arena or the persistent state pool, and writes into state
// promote scratch arguments first.
namespace vm;

import.collection_arena;
import.rite_types;
import.state_pool;
import.value_arena;

fn builtin_not(value: MrbValue) -> MrbValue {
    if mrb_truthy(value) {
        return mrb_false();
    }
    return mrb_true();
}

// Returns the bytes of a string in either zone, or an empty slice for any
// other value.
fn builtin_string_bytes(pool: StatePool&, scratch: ScratchArena&, value: MrbValue) -> const u8[:] {
    if mrb_is_scratch(value) {
        return scratch_string_bytes(scratch, value);
    }
    if mrb_is_state(value) {
        return state_string_bytes(pool, value);
    }
    return "";
}

fn builtin_string_length(pool: StatePool&, scratch: ScratchArena&, value: MrbValue) -> i64 {
    return builtin_string_bytes(pool, scratch, value).len;
}

// Finds `needle` at or after `offset`. Returns the byte index and whether it
// was found; callers map a miss to Ruby's nil.
fn builtin_string_index(
    pool: StatePool&, scratch: ScratchArena&, haystack: MrbValue, needle: MrbValue, offset: i64
) -> i64, bool {
    let hay = builtin_string_bytes(pool, scratch, haystack);
    let pattern = builtin_string_bytes(pool, scratch, needle);
    var start = offset;
    if start < 0 {
        start = 0;
    }
    if start > hay.len {
        return -1, false;
    }
    if pattern.len == 0 {
        return start, true;
    }
    while start + pattern.len <= hay.len {
        var matched = true;
        var index = 0;
        while index < pattern.len {
            if hay[start + index] != pattern[index] {
                matched = false;
                break;
            }
            index += 1;
        }
        if matched {
            return start, true;
        }
        start += 1;
    }
    return -1, false;
}

// Ruby's `String#[start, length]`, including negative start offsets. The
// result is always a new scratch string.
fn builtin_string_slice(
    pool: StatePool&, scratch: ScratchArena&, value: MrbValue, start: i64, length: i64
) -> MrbValue {
    let text = builtin_string_bytes(pool, scratch, value);
    if length < 0 {
        return mrb_nil();
    }
    var begin = start;
    if begin < 0 {
        begin += text.len;
    }
    if begin < 0 || begin > text.len {
        return mrb_nil();
    }
    var stop = begin + length;
    if stop > text.len {
        stop = text.len;
    }
    if stop < begin {
        stop = begin;
    }
    return scratch_alloc_string(scratch, text[begin..stop]);
}

fn builtin_array_new(scratch: ScratchArena&) -> MrbValue {
    return scratch_alloc_array(scratch);
}

fn builtin_array_push(pool: StatePool&, scratch: ScratchArena&, array: MrbValue, value: MrbValue) -> bool {
    if mrb_is_scratch(array) {
        return scratch_array_push(scratch, array, value);
    }
    if mrb_is_state(array) {
        if !state_is_array(pool, array) {
            return false;
        }
        let stored = promote_to_state(pool, scratch, value);
        return state_array_push(pool, array, stored);
    }
    return false;
}

fn builtin_array_pop(pool: StatePool&, scratch: ScratchArena&, array: MrbValue) -> MrbValue {
    if mrb_is_scratch(array) {
        let value, ok = scratch_array_pop(scratch, array);
        if !ok {
            return mrb_nil();
        }
        return value;
    }
    let value, ok = state_array_pop(pool, array);
    if !ok {
        return mrb_nil();
    }
    return value;
}

fn builtin_array_last(pool: StatePool&, scratch: ScratchArena&, array: MrbValue) -> MrbValue {
    if mrb_is_scratch(array) {
        let value, ok = scratch_array_last(scratch, array);
        if !ok {
            return mrb_nil();
        }
        return value;
    }
    let value, ok = state_array_last(pool, array);
    if !ok {
        return mrb_nil();
    }
    return value;
}

fn builtin_array_length(pool: StatePool&, scratch: ScratchArena&, array: MrbValue) -> i64 {
    if mrb_is_scratch(array) {
        return scratch_array_length(scratch, array);
    }
    return state_array_length(pool, array);
}

fn builtin_array_empty(pool: StatePool&, scratch: ScratchArena&, array: MrbValue) -> bool {
    if mrb_is_scratch(array) {
        if !scratch_is_array(scratch, array) {
            return false;
        }
        return scratch_array_length(scratch, array) == 0;
    }
    if !state_is_array(pool, array) {
        return false;
    }
    return state_array_length(pool, array) == 0;
}

fn builtin_array_get(pool: StatePool&, scratch: ScratchArena&, array: MrbValue, position: i64) -> MrbValue {
    let length = builtin_array_length(pool, scratch, array);
    var index = position;
    if index < 0 {
        index += length;
    }
    if index < 0 || index >= length {
        return mrb_nil();
    }
    if mrb_is_scratch(array) {
        let value, ok = scratch_array_get(scratch, array, index);
        if !ok {
            return mrb_nil();
        }
        return value;
    }
    let value, ok = state_array_get(pool, array, index);
    if !ok {
        return mrb_nil();
    }
    return value;
}

fn builtin_array_set(
    pool: StatePool&, scratch: ScratchArena&, array: MrbValue, position: i64, value: MrbValue
) -> bool {
    let length = builtin_array_length(pool, scratch, array);
    var index = position;
    if index < 0 {
        index += length;
    }
    if index < 0 || index >= length {
        return false;
    }
    if mrb_is_scratch(array) {
        return scratch_array_set(scratch, array, index, value);
    }
    if !state_is_array(pool, array) {
        return false;
    }
    let stored = promote_to_state(pool, scratch, value);
    return state_array_set(pool, array, index, stored);
}

fn builtin_append_text(pool: StatePool&, scratch: ScratchArena&, out: u8[>..]&, value: MrbValue) {
    if mrb_is_scratch(value) || mrb_is_state(value) {
        out.append(builtin_string_bytes(pool, scratch, value));
        return;
    }
    if mrb_is_fixnum(value) {
        mrb_format_fixnum(out, mrb_fixnum_value(value));
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
    if mrb_is_symbol(value) {
        out.append(symbol_name(mrb_symbol_id(value)));
    }
}

fn builtin_array_join(pool: StatePool&, scratch: ScratchArena&, array: MrbValue, separator: MrbValue) -> MrbValue {
    let glue = builtin_string_bytes(pool, scratch, separator);
    var joined: u8[>..] = [];
    if mrb_is_scratch(array) {
        let object, ok = scratch_object(scratch, array);
        if !ok || object.kind != ArenaObjectKind.Array {
            return mrb_nil();
        }
        var slot_index = object.items_first_index;
        var first = true;
        while slot_index >= 0 {
            if !first {
                joined.append(glue);
            }
            builtin_append_text(pool, scratch, joined, scratch.slots[slot_index].value);
            first = false;
            slot_index = scratch.slots[slot_index].next_index;
        }
        return scratch_alloc_string(scratch, joined[..]);
    }
    let object, ok = state_object(pool, array);
    if !ok || object.kind != ArenaObjectKind.Array {
        return mrb_nil();
    }
    var slot_index = object.items_first_index;
    var first = true;
    while slot_index >= 0 {
        if !first {
            joined.append(glue);
        }
        builtin_append_text(pool, scratch, joined, pool.slots[slot_index].value);
        first = false;
        slot_index = pool.slots[slot_index].next_index;
    }
    return scratch_alloc_string(scratch, joined[..]);
}

fn builtin_hash_new(scratch: ScratchArena&) -> MrbValue {
    return scratch_alloc_hash(scratch);
}

// Returns the lookup text for a Hash key. Symbols and strings participate in
// indifferent lookup; every other value only matches itself.
fn builtin_hash_key_text(
    pool: StatePool&, scratch: ScratchArena&, value: MrbValue
) -> const u8[:], bool {
    if mrb_is_symbol(value) {
        let symbol_id = mrb_symbol_id(value);
        if symbol_id >= symbol_count() {
            return "", false;
        }
        return symbol_name(symbol_id), true;
    }
    if mrb_is_scratch(value) {
        if !scratch_is_string(scratch, value) {
            return "", false;
        }
        return scratch_string_bytes(scratch, value), true;
    }
    if mrb_is_state(value) {
        let object, ok = state_object(pool, value);
        if !ok || object.kind != ArenaObjectKind.String {
            return "", false;
        }
        return state_string_bytes(pool, value), true;
    }
    return "", false;
}

// Compares two Hash keys. Symbol and String keys match when their UTF-8 bytes
// match, so `hash[:id]` and `hash["id"]` address the same slot.
fn builtin_hash_key_equal(
    pool: StatePool&, scratch: ScratchArena&, left: MrbValue, right: MrbValue
) -> bool {
    if mrb_value_identical(left, right) {
        return true;
    }
    let left_text, left_ok = builtin_hash_key_text(pool, scratch, left);
    if !left_ok {
        return false;
    }
    let right_text, right_ok = builtin_hash_key_text(pool, scratch, right);
    if !right_ok {
        return false;
    }
    return left_text == right_text;
}

fn builtin_hash_set(pool: StatePool&, scratch: ScratchArena&, hash: MrbValue, key: MrbValue, value: MrbValue) -> bool {
    if mrb_is_scratch(hash) {
        let object, ok = scratch_object(scratch, hash);
        if !ok || object.kind != ArenaObjectKind.Hash {
            return false;
        }
        var slot_index = object.items_first_index;
        while slot_index >= 0 {
            if builtin_hash_key_equal(pool, scratch, scratch.slots[slot_index].key, key) {
                return scratch_hash_set(scratch, hash, scratch.slots[slot_index].key, value);
            }
            slot_index = scratch.slots[slot_index].next_index;
        }
        return scratch_hash_set(scratch, hash, key, value);
    }
    let object, ok = state_object(pool, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return false;
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if builtin_hash_key_equal(pool, scratch, pool.slots[slot_index].key, key) {
            let stored = promote_to_state(pool, scratch, value);
            return state_hash_set(pool, hash, pool.slots[slot_index].key, stored);
        }
        slot_index = pool.slots[slot_index].next_index;
    }
    let stored_key = promote_to_state(pool, scratch, key);
    let stored_value = promote_to_state(pool, scratch, value);
    return state_hash_set(pool, hash, stored_key, stored_value);
}

fn builtin_hash_get(pool: StatePool&, scratch: ScratchArena&, hash: MrbValue, key: MrbValue) -> MrbValue {
    if mrb_is_scratch(hash) {
        let object, ok = scratch_object(scratch, hash);
        if !ok || object.kind != ArenaObjectKind.Hash {
            return mrb_nil();
        }
        var slot_index = object.items_first_index;
        while slot_index >= 0 {
            if builtin_hash_key_equal(pool, scratch, scratch.slots[slot_index].key, key) {
                return scratch.slots[slot_index].value;
            }
            slot_index = scratch.slots[slot_index].next_index;
        }
        return mrb_nil();
    }
    let object, ok = state_object(pool, hash);
    if !ok || object.kind != ArenaObjectKind.Hash {
        return mrb_nil();
    }
    var slot_index = object.items_first_index;
    while slot_index >= 0 {
        if builtin_hash_key_equal(pool, scratch, pool.slots[slot_index].key, key) {
            return pool.slots[slot_index].value;
        }
        slot_index = pool.slots[slot_index].next_index;
    }
    return mrb_nil();
}

fn builtin_hash_length(pool: StatePool&, scratch: ScratchArena&, hash: MrbValue) -> i64 {
    if mrb_is_scratch(hash) {
        return scratch_hash_length(scratch, hash);
    }
    return state_hash_length(pool, hash);
}

// Dispatches Ruby `obj[key]` for arrays and hashes.
fn builtin_get_index(pool: StatePool&, scratch: ScratchArena&, container: MrbValue, key: MrbValue) -> MrbValue {
    if mrb_is_fixnum(key) && (mrb_is_scratch(container) || mrb_is_state(container)) {
        if mrb_is_scratch(container) {
            if scratch_is_array(scratch, container) {
                return builtin_array_get(pool, scratch, container, mrb_fixnum_value(key));
            }
        } else if state_is_array(pool, container) {
            return builtin_array_get(pool, scratch, container, mrb_fixnum_value(key));
        }
    }
    return builtin_hash_get(pool, scratch, container, key);
}

// Dispatches Ruby `obj[key] = value` for arrays and hashes.
fn builtin_set_index(
    pool: StatePool&, scratch: ScratchArena&, container: MrbValue, key: MrbValue, value: MrbValue
) -> bool {
    if mrb_is_fixnum(key) && (mrb_is_scratch(container) || mrb_is_state(container)) {
        if mrb_is_scratch(container) {
            if scratch_is_array(scratch, container) {
                return builtin_array_set(pool, scratch, container, mrb_fixnum_value(key), value);
            }
        } else if state_is_array(pool, container) {
            return builtin_array_set(pool, scratch, container, mrb_fixnum_value(key), value);
        }
    }
    return builtin_hash_set(pool, scratch, container, key, value);
}
