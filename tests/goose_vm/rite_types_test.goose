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
