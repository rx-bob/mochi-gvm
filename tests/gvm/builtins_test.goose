// Tests for inline Array, Hash, String and Boolean intrinsic methods.
namespace vm_builtins_test;

import std;

import goosetest;
import vm;

// Mirrors `UserList#parse_names` without method dispatch: scan the JSON for the
// `"name":"` key, then slice up to the closing quote.
fn parse_names_like(
    pool: vm::StatePool&, scratch: vm::ScratchArena&, json: vm::MrbValue
) -> vm::MrbValue {
    let names = vm::builtin_array_new(scratch);
    let key = vm::scratch_alloc_string(scratch, "\"name\":\"");
    let quote = vm::scratch_alloc_string(scratch, "\"");
    let key_length = vm::builtin_string_length(pool, scratch, key);
    let length = vm::builtin_string_length(pool, scratch, json);
    var position = 0;
    while position < length {
        let key_index, key_found = vm::builtin_string_index(pool, scratch, json, key, position);
        if !key_found {
            break;
        }
        let start = key_index + key_length;
        let end_index, end_found = vm::builtin_string_index(pool, scratch, json, quote, start);
        if !end_found {
            break;
        }
        let name = vm::builtin_string_slice(pool, scratch, json, start, end_index - start);
        if vm::mrb_is_nil(name) {
            break;
        }
        if !vm::builtin_array_push(pool, scratch, names, name) {
            break;
        }
        position = end_index + 1;
    }
    return names;
}

fn test_boolean_not_negates_truthiness(t: goosetest::Test&) {
    t.assert_true(vm::mrb_is_false(vm::builtin_not(vm::mrb_true())));
    t.assert_true(vm::mrb_is_true(vm::builtin_not(vm::mrb_false())));
    t.assert_true(vm::mrb_is_true(vm::builtin_not(vm::mrb_nil())));
    t.assert_true(vm::mrb_is_false(vm::builtin_not(vm::mrb_fixnum(0))));
}

fn test_scratch_array_push_last_pop_join(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::builtin_array_new(scratch);
    t.assert_true(vm::builtin_array_empty(pool, scratch, array));
    t.assert_eq(0, vm::builtin_array_length(pool, scratch, array));

    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_fixnum(1)));
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_true()));
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_false()));
    t.assert_false(vm::builtin_array_empty(pool, scratch, array));
    t.assert_eq(3, vm::builtin_array_length(pool, scratch, array));

    let last = vm::builtin_array_last(pool, scratch, array);
    t.assert_true(vm::mrb_is_false(last));
    let first = vm::builtin_array_get(pool, scratch, array, 0);
    t.assert_eq(1, vm::mrb_fixnum_value(first));
    let final = vm::builtin_array_get(pool, scratch, array, -1);
    t.assert_true(vm::mrb_is_false(final));
    t.assert_true(vm::mrb_is_nil(vm::builtin_array_get(pool, scratch, array, 3)));

    let separator = vm::scratch_alloc_string(scratch, ",");
    let joined = vm::builtin_array_join(pool, scratch, array, separator);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, joined) == "1,true,false");

    let popped = vm::builtin_array_pop(pool, scratch, array);
    t.assert_true(vm::mrb_is_false(popped));
    t.assert_eq(2, vm::builtin_array_length(pool, scratch, array));
    t.assert_true(vm::builtin_array_set(pool, scratch, array, -1, vm::mrb_fixnum(9)));
    t.assert_eq(9, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, array, 1)));
}

fn test_state_array_promotes_and_mutates(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::builtin_array_new(scratch);
    let alice = vm::scratch_alloc_string(scratch, "Alice");
    t.assert_true(vm::builtin_array_push(pool, scratch, array, alice));
    let durable = vm::promote_to_state(pool, scratch, array);
    t.assert_true(vm::mrb_is_state(durable));
    t.assert_true(vm::state_is_array(pool, durable));

    vm::scratch_reset(scratch);
    t.assert_eq(1, vm::builtin_array_length(pool, scratch, durable));
    let stored = vm::builtin_array_get(pool, scratch, durable, 0);
    t.assert_true(vm::mrb_is_state(stored));
    t.assert_true(vm::builtin_string_bytes(pool, scratch, stored) == "Alice");

    let bob = vm::scratch_alloc_string(scratch, "Bob");
    t.assert_true(vm::builtin_array_push(pool, scratch, durable, bob));
    t.assert_eq(2, vm::builtin_array_length(pool, scratch, durable));
    let popped = vm::builtin_array_pop(pool, scratch, durable);
    t.assert_true(vm::mrb_is_state(popped));
    t.assert_true(vm::builtin_string_bytes(pool, scratch, popped) == "Bob");

    vm::scratch_reset(scratch);
    t.assert_eq(1, vm::builtin_array_length(pool, scratch, durable));
    let alice_again = vm::builtin_array_get(pool, scratch, durable, 0);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, alice_again) == "Alice");

    let carol = vm::scratch_alloc_string(scratch, "Carol");
    t.assert_true(vm::builtin_array_set(pool, scratch, durable, 0, carol));
    vm::scratch_reset(scratch);
    let changed = vm::builtin_array_get(pool, scratch, durable, 0);
    t.assert_true(vm::mrb_is_state(changed));
    t.assert_true(vm::builtin_string_bytes(pool, scratch, changed) == "Carol");
    let joined = vm::builtin_array_join(pool, scratch, durable, vm::mrb_nil());
    t.assert_true(vm::builtin_string_bytes(pool, scratch, joined) == "Carol");

    let slots_before = vm::state_slot_count(pool);
    for _ in 100 {
        t.assert_true(vm::builtin_array_push(pool, scratch, durable, vm::mrb_fixnum(1)));
        let popped = vm::builtin_array_pop(pool, scratch, durable);
        t.assert_eq(1, vm::mrb_fixnum_value(popped));
    }
    t.assert_eq(slots_before, vm::state_slot_count(pool));
    t.assert_eq(1, vm::builtin_array_length(pool, scratch, durable));
}

fn test_scratch_hash_get_set_and_update(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let hash = vm::builtin_hash_new(scratch);
    let done = vm::mrb_symbol(20);
    let text = vm::mrb_symbol(21);
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, done, vm::mrb_false()));
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, text, vm::mrb_fixnum(7)));
    t.assert_eq(2, vm::builtin_hash_length(pool, scratch, hash));
    t.assert_true(vm::mrb_is_false(vm::builtin_hash_get(pool, scratch, hash, done)));
    t.assert_eq(7, vm::mrb_fixnum_value(vm::builtin_hash_get(pool, scratch, hash, text)));

    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, done, vm::mrb_true()));
    t.assert_eq(2, vm::builtin_hash_length(pool, scratch, hash));
    t.assert_true(vm::mrb_is_true(vm::builtin_hash_get(pool, scratch, hash, done)));
    t.assert_true(vm::mrb_is_nil(vm::builtin_hash_get(pool, scratch, hash, vm::mrb_symbol(22))));
}

fn test_hash_keys_are_indifferent(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let key_symbol = vm::mrb_symbol(vm::intern_symbol("indifferent_id"));
    let key_text = vm::scratch_alloc_string(scratch, "indifferent_id");
    let hash = vm::builtin_hash_new(scratch);
    let first = vm::scratch_alloc_string(scratch, "tr_1");
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, key_symbol, first));
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, hash, key_text)) == "tr_1");

    let second = vm::scratch_alloc_string(scratch, "tr_2");
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, key_text, second));
    t.assert_eq(1, vm::builtin_hash_length(pool, scratch, hash));
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, hash, key_symbol)) == "tr_2");

    let durable = vm::promote_to_state(pool, scratch, hash);
    vm::scratch_reset(scratch);
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, durable, key_symbol)) == "tr_2");
    let durable_key = vm::scratch_alloc_string(scratch, "indifferent_id");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, durable, durable_key)) == "tr_2");

    let string_hash = vm::builtin_hash_new(scratch);
    let row = vm::scratch_alloc_string(scratch, "tr_9f2a");
    let row_key = vm::scratch_alloc_string(scratch, "row");
    t.assert_true(vm::builtin_hash_set(pool, scratch, string_hash, row_key, row));
    let stored_hash = vm::promote_to_state(pool, scratch, string_hash);
    let row_symbol = vm::mrb_symbol(vm::intern_symbol("row"));
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, stored_hash, row_symbol)) == "tr_9f2a");
    let fresh_row_key = vm::scratch_alloc_string(scratch, "row");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, stored_hash, fresh_row_key)) == "tr_9f2a");
    let updated = vm::scratch_alloc_string(scratch, "tr_1");
    t.assert_true(vm::builtin_hash_set(pool, scratch, stored_hash, row_symbol, updated));
    t.assert_eq(1, vm::builtin_hash_length(pool, scratch, stored_hash));
    let updated_key = vm::scratch_alloc_string(scratch, "row");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, stored_hash, updated_key)) == "tr_1");
}

fn test_state_hash_promotes_keys_and_values(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let hash = vm::builtin_hash_new(scratch);
    let done = vm::mrb_symbol(30);
    let text = vm::mrb_symbol(31);
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, done, vm::mrb_false()));
    let value = vm::scratch_alloc_string(scratch, "write");
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, text, value));
    let durable = vm::promote_to_state(pool, scratch, hash);
    t.assert_true(vm::state_is_hash(pool, durable));

    vm::scratch_reset(scratch);
    t.assert_true(vm::mrb_is_false(vm::builtin_hash_get(pool, scratch, durable, done)));
    let stored = vm::builtin_hash_get(pool, scratch, durable, text);
    t.assert_true(vm::mrb_is_state(stored));
    t.assert_true(vm::builtin_string_bytes(pool, scratch, stored) == "write");

    t.assert_true(vm::builtin_hash_set(pool, scratch, durable, done, vm::mrb_true()));
    t.assert_true(vm::mrb_is_true(vm::builtin_hash_get(pool, scratch, durable, done)));
    let changed = vm::scratch_alloc_string(scratch, "done");
    t.assert_true(vm::builtin_hash_set(pool, scratch, durable, text, changed));
    t.assert_eq(2, vm::builtin_hash_length(pool, scratch, durable));
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_hash_get(pool, scratch, durable, text)) == "done");
}

fn test_promotion_walks_nested_array_hash(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::builtin_array_new(scratch);
    let hash = vm::builtin_hash_new(scratch);
    let text = vm::mrb_symbol(40);
    let nested = vm::scratch_alloc_string(scratch, "nested");
    t.assert_true(vm::builtin_hash_set(pool, scratch, hash, text, nested));
    t.assert_true(vm::builtin_array_push(pool, scratch, array, hash));
    let durable = vm::promote_to_state(pool, scratch, array);

    vm::scratch_reset(scratch);
    let stored_hash = vm::builtin_array_get(pool, scratch, durable, 0);
    t.assert_true(vm::mrb_is_state(stored_hash));
    t.assert_true(vm::state_is_hash(pool, stored_hash));
    let stored_text = vm::builtin_hash_get(pool, scratch, stored_hash, text);
    t.assert_true(vm::mrb_is_state(stored_text));
    t.assert_true(vm::builtin_string_bytes(pool, scratch, stored_text) == "nested");
}

fn test_string_length_index_and_slice(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let text = vm::scratch_alloc_string(scratch, "hello world");
    let world = vm::scratch_alloc_string(scratch, "world");
    let missing = vm::scratch_alloc_string(scratch, "zebra");
    let empty = vm::scratch_alloc_string(scratch, "");
    t.assert_eq(11, vm::builtin_string_length(pool, scratch, text));

    let found, found_ok = vm::builtin_string_index(pool, scratch, text, world, 0);
    t.assert_true(found_ok);
    t.assert_eq(6, found);
    let after, after_ok = vm::builtin_string_index(pool, scratch, text, world, 7);
    t.assert_false(after_ok);
    t.assert_eq(-1, after);
    let _, missing_ok = vm::builtin_string_index(pool, scratch, text, missing, 0);
    t.assert_false(missing_ok);
    let at_end, at_end_ok = vm::builtin_string_index(pool, scratch, text, empty, 11);
    t.assert_true(at_end_ok);
    t.assert_eq(11, at_end);
    let beyond, beyond_ok = vm::builtin_string_index(pool, scratch, text, empty, 12);
    t.assert_false(beyond_ok);
    t.assert_eq(-1, beyond);

    let hello = vm::builtin_string_slice(pool, scratch, text, 0, 5);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, hello) == "hello");
    let tail = vm::builtin_string_slice(pool, scratch, text, -5, 5);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, tail) == "world");
    let whole = vm::builtin_string_slice(pool, scratch, text, 0, 99);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, whole) == "hello world");
    let empty_tail = vm::builtin_string_slice(pool, scratch, text, 11, 0);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, empty_tail) == "");
    t.assert_true(vm::mrb_is_nil(vm::builtin_string_slice(pool, scratch, text, 20, 1)));
    t.assert_true(vm::mrb_is_nil(vm::builtin_string_slice(pool, scratch, text, 0, -1)));

    let durable = vm::state_alloc_string(pool, "persist");
    t.assert_eq(7, vm::builtin_string_length(pool, scratch, durable));
    let prefix = vm::builtin_string_slice(pool, scratch, durable, 0, 3);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, prefix) == "per");
    let state_hay = vm::state_alloc_string(pool, "hello world");
    let state_found, state_found_ok = vm::builtin_string_index(pool, scratch, state_hay, world, 0);
    t.assert_true(state_found_ok);
    t.assert_eq(6, state_found);
    t.assert_eq(0, vm::builtin_string_length(pool, scratch, vm::mrb_nil()));
}

fn test_index_dispatch_covers_arrays_and_hashes(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let array = vm::builtin_array_new(scratch);
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_fixnum(4)));
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_fixnum(5)));
    let last = vm::builtin_get_index(pool, scratch, array, vm::mrb_fixnum(-1));
    t.assert_eq(5, vm::mrb_fixnum_value(last));
    t.assert_true(vm::builtin_set_index(pool, scratch, array, vm::mrb_fixnum(-1), vm::mrb_fixnum(6)));
    let changed = vm::builtin_get_index(pool, scratch, array, vm::mrb_fixnum(1));
    t.assert_eq(6, vm::mrb_fixnum_value(changed));

    let hash = vm::builtin_hash_new(scratch);
    let key = vm::mrb_symbol(50);
    t.assert_true(vm::builtin_set_index(pool, scratch, hash, key, vm::mrb_fixnum(8)));
    t.assert_eq(8, vm::mrb_fixnum_value(vm::builtin_get_index(pool, scratch, hash, key)));
    t.assert_false(vm::builtin_set_index(pool, scratch, vm::mrb_nil(), key, vm::mrb_fixnum(1)));
}

fn test_parse_names_uses_index_and_slice(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let json = vm::scratch_alloc_string(scratch, "[{\"name\":\"Alice\"},{\"name\":\"Bob\"},{\"name\":\"Charlie\"}]");
    let names = parse_names_like(pool, scratch, json);
    t.assert_eq(3, vm::builtin_array_length(pool, scratch, names));
    let comma = vm::scratch_alloc_string(scratch, ",");
    let joined = vm::builtin_array_join(pool, scratch, names, comma);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, joined) == "Alice,Bob,Charlie");
    t.assert_true(vm::builtin_string_bytes(pool, scratch,
        vm::builtin_array_get(pool, scratch, names, 1)) == "Bob");
}
