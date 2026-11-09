// Tests for the literal pool entry decoder.
namespace vm_rite_pool_test;

import goosetest;
import vm;

fn test_string_and_bigint_views(t: goosetest::Test&) {
    let text: const u8[:] = "\x00\x00\x05hello\x00";
    let entry, next, err = vm::parse_pool_entry(text, 0, text.len);
    t.assert_eq(vm::ParseError.Ok, err);
    t.assert_eq(0, entry.tag);
    t.assert_eq(9, next);
    t.assert_eq(3, entry.text_offset_bytes);
    t.assert_eq(5, entry.text_length_bytes);
    t.assert_true(text[3..8] == "hello");

    let big: const u8[:] = "\x07\x02\x01\x02\x03";
    let big_entry, big_next, big_err = vm::parse_pool_entry(big, 0, big.len);
    t.assert_eq(vm::ParseError.Ok, big_err);
    t.assert_eq(7, big_entry.tag);
    t.assert_eq(5, big_next);
    t.assert_eq(1, big_entry.text_offset_bytes);
    t.assert_eq(4, big_entry.text_length_bytes);
}

fn test_integer_and_float_values(t: goosetest::Test&) {
    let int32: const u8[:] = "\x01\xFF\xFF\xFF\xFE";
    let int32_entry, int32_next, int32_err = vm::parse_pool_entry(int32, 0, int32.len);
    t.assert_eq(vm::ParseError.Ok, int32_err);
    t.assert_eq(5, int32_next);
    t.assert_eq(-2, int32_entry.int_value);

    let int64: const u8[:] = "\x03\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFE";
    let int64_entry, int64_next, int64_err = vm::parse_pool_entry(int64, 0, int64.len);
    t.assert_eq(vm::ParseError.Ok, int64_err);
    t.assert_eq(9, int64_next);
    t.assert_eq(-2, int64_entry.int_value);

    let float: const u8[:] = "\x05\x00\x00\x00\x00\x00\x00\xF8\x3F";
    let float_entry, float_next, float_err = vm::parse_pool_entry(float, 0, float.len);
    t.assert_eq(vm::ParseError.Ok, float_err);
    t.assert_eq(9, float_next);
    t.assert_true(float_entry.float_value == 1.5, "float value");
}

fn test_bad_entries_are_rejected(t: goosetest::Test&) {
    let bad_tag: const u8[:] = "\x09";
    let _, _, bad_tag_err = vm::parse_pool_entry(bad_tag, 0, bad_tag.len);
    t.assert_eq(vm::ParseError.BadPoolTag, bad_tag_err);

    let no_nul: const u8[:] = "\x00\x00\x05helloX";
    let _, _, no_nul_err = vm::parse_pool_entry(no_nul, 0, no_nul.len);
    t.assert_eq(vm::ParseError.MissingTerminator, no_nul_err);

    let short_text: const u8[:] = "\x00\x00\x05he";
    let _, _, short_text_err = vm::parse_pool_entry(short_text, 0, short_text.len);
    t.assert_eq(vm::ParseError.Truncated, short_text_err);

    let short_float: const u8[:] = "\x05\x00\x00";
    let _, _, short_float_err = vm::parse_pool_entry(short_float, 0, short_float.len);
    t.assert_eq(vm::ParseError.Truncated, short_float_err);

    let short_bigint: const u8[:] = "\x07\x02\x01";
    let _, _, short_bigint_err = vm::parse_pool_entry(short_bigint, 0, short_bigint.len);
    t.assert_eq(vm::ParseError.Truncated, short_bigint_err);
}
