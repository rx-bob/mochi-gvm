// Tests for the shared RITE types, symbol interning and zero-copy accessors.
namespace vm_rite_types_test;

import std;

import goosetest;
import vm;

fn test_symbol_interning_deduplicates(t: goosetest::Test&) {
    let first = vm::intern_symbol("mochi_symbol_probe");
    let second = vm::intern_symbol("mochi_symbol_probe");
    t.assert_eq(first, second);
    t.assert_true(vm::symbol_name(first) == "mochi_symbol_probe");
    t.assert_true(vm::symbol_count() > 0);
}

fn test_symbol_blob_spans_multiple_16kb_blocks(t: goosetest::Test&) {
    let before = vm::symbol_blob_length();
    var ids: u32[>..] = [];
    for i in 0..2100 {
        let id = vm::intern_symbol(str("symbol_block_probe_", i));
        if id == vm::NULL_SYMBOL {
            t.assert_true(false, "symbol interning failed");
            return;
        }
        ids.push(id);
    }
    t.assert_true(vm::symbol_blob_length() - before > 32768);
    for i in 0..ids.len {
        let expected = str("symbol_block_probe_", i);
        if vm::symbol_name(ids[i]) != expected {
            t.assert_true(false, "symbol name view crossed a block boundary");
            return;
        }
    }
}

fn test_null_symbol_has_no_name(t: goosetest::Test&) {
    t.assert_true(vm::symbol_name(vm::NULL_SYMBOL) == "");
}

fn test_record_links_name_children(t: goosetest::Test&) {
    let record = vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 20,
        nlocals: 1,
        nregs: 2,
        child_count: 2,
        catch_count: 0,
        iseq_length_bytes: 3,
        iseq_offset_bytes: 20,
        catch_offset_bytes: 23,
        pool_first_index: 0,
        pool_count: 0,
        syms_first_index: 0,
        syms_count: 0,
        parent_index: -1,
        first_child_index: 3,
        next_sibling_index: 5,
        depth: 0,
    };
    t.assert_eq(3, vm::first_child(record));
    t.assert_eq(5, vm::next_sibling(record));
}

fn test_iseq_and_pool_views_alias_input(t: goosetest::Test&) {
    var data: u8[>..] = [];
    data.append("abcdef");
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    file.data = data[..];

    let record = vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 20,
        nlocals: 1,
        nregs: 2,
        child_count: 0,
        catch_count: 0,
        iseq_length_bytes: 3,
        iseq_offset_bytes: 1,
        catch_offset_bytes: 4,
        pool_first_index: 0,
        pool_count: 1,
        syms_first_index: 0,
        syms_count: 0,
        parent_index: -1,
        first_child_index: -1,
        next_sibling_index: -1,
        depth: 0,
    };
    t.assert_true(vm::record_iseq(file, record) == "bcd");

    let text = vm::PoolEntry {
        tag: 0,
        text_offset_bytes: 4,
        text_length_bytes: 2,
        int_value: 0,
        float_value: 0.0,
    };
    t.assert_true(vm::pool_text(file, text) == "ef");

    let number = vm::PoolEntry {
        tag: 1,
        text_offset_bytes: 0,
        text_length_bytes: 0,
        int_value: 7,
        float_value: 0.0,
    };
    t.assert_true(vm::pool_text(file, number) == "");
}

fn test_parse_error_names_are_distinct(t: goosetest::Test&) {
    t.assert_true(vm::parse_error_name(vm::ParseError.Ok) == "ok");
    t.assert_true(vm::parse_error_name(vm::ParseError.TooDeep) == "IREP nesting too deep");
    t.assert_true(vm::parse_error_name(vm::ParseError.BadPoolTag) == "bad literal pool tag");
}

fn make_record(depth: u16) -> vm::IrepRecord {
    return vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 20,
        nlocals: 1,
        nregs: 2,
        child_count: 0,
        catch_count: 0,
        iseq_length_bytes: 0,
        iseq_offset_bytes: 20,
        catch_offset_bytes: 20,
        pool_first_index: 0,
        pool_count: 0,
        syms_first_index: 0,
        syms_count: 0,
        parent_index: -1,
        first_child_index: -1,
        next_sibling_index: -1,
        depth: depth,
    };
}

// @DisplayName("test_symbol_intern_hash_scales_to_10000_symbols_and_rolls_back")
fn test_symbol_hash_rollback(t: goosetest::Test&) {
    let saved_count = vm::symbol_count();
    let saved_blob = vm::symbol_blob_length();
    var ids: u32[>..] = [];
    var mid_count = saved_count;
    var mid_blob = saved_blob;
    for i in 0..10000 {
        let name = str("hash_symbol_probe_", i);
        let id = vm::intern_symbol(name);
        if id == vm::NULL_SYMBOL {
            t.assert_true(false, "hash symbol interning failed");
            return;
        }
        t.assert_eq(id, vm::intern_symbol(name));
        if i == 4999 {
            mid_count = vm::symbol_count();
            mid_blob = vm::symbol_blob_length();
        }
        ids.push(id);
    }
    t.assert_eq(saved_count + 10000, vm::symbol_count());
    for i in 0..ids.len {
        if vm::symbol_name(ids[i]) != str("hash_symbol_probe_", i) {
            t.assert_true(false, "hash symbol lookup returned the wrong name");
            return;
        }
    }
    vm::symbol_table_truncate(mid_count, mid_blob);
    t.assert_eq(mid_count, vm::symbol_count());
    let reused = vm::intern_symbol(str("hash_symbol_probe_", 7000));
    t.assert_true(reused >= mid_count as u32);
    t.assert_eq(reused, vm::intern_symbol(str("hash_symbol_probe_", 7000)));
    t.assert_true(vm::symbol_name(reused) == str("hash_symbol_probe_", 7000));
    for i in 0..5000 {
        if vm::symbol_name(ids[i]) != str("hash_symbol_probe_", i) {
            t.assert_true(false, "rollback corrupted a retained symbol");
            return;
        }
    }
    vm::symbol_table_truncate(saved_count, saved_blob);
}

fn test_table_accessors_track_links(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    vm::record_push(file, make_record(0));
    vm::record_push(file, make_record(1));
    vm::record_push(file, make_record(2));
    vm::record_set_first_child(file, 0, 1);
    vm::record_set_next_sibling(file, 1, 2);
    t.assert_eq(3, vm::record_count(file));
    t.assert_eq(1, vm::record_at(file, 0).first_child_index);
    t.assert_eq(2, vm::record_at(file, 1).next_sibling_index);
    t.assert_eq(2, vm::record_at(file, 2).depth);

    vm::pool_push(file, vm::PoolEntry {
            tag: 1,
            text_offset_bytes: 0,
            text_length_bytes: 0,
            int_value: 7,
            float_value: 0.0,
        });
    t.assert_eq(1, vm::pool_count(file));
    t.assert_eq(7, vm::pool_at(file, 0).int_value);

    vm::symbol_ref_push(file, vm::SymbolId {
            index: 42
        });
    t.assert_eq(1, vm::symbol_ref_count(file));
    t.assert_eq(42, vm::symbol_ref_at(file, 0).index);

    vm::root_push(file, 1);
    t.assert_eq(1, vm::root_count(file));
    t.assert_eq(1, vm::root_at(file, 0));
}
