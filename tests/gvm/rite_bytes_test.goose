// Tests for the bounds-checked big-endian byte readers.
namespace vm_rite_bytes_test;

import goosetest;
import vm;

fn test_read_u16_decodes_big_endian(t: goosetest::Test&) {
    let data: const u8[:] = "\x12\x34";
    let value, ok = vm::read_u16(data, 0);
    t.assert_true(ok);
    t.assert_eq(0x1234, value);
}

fn test_read_u16_rejects_out_of_bounds(t: goosetest::Test&) {
    let data: const u8[:] = "\x12\x34";
    let value, ok = vm::read_u16(data, 1);
    t.assert_false(ok);
    t.assert_eq(0, value);

    let empty: const u8[:] = "";
    let _, empty_ok = vm::read_u16(empty, 0);
    t.assert_false(empty_ok);
}

fn test_read_u32_decodes_big_endian(t: goosetest::Test&) {
    let data: const u8[:] = "\xDE\xAD\xBE\xEF";
    let value, ok = vm::read_u32(data, 0);
    t.assert_true(ok);
    t.assert_eq(0xDEADBEEF, value);
}

fn test_read_u32_rejects_short_reads(t: goosetest::Test&) {
    let data: const u8[:] = "\xDE\xAD\xBE\xEF";
    let value, ok = vm::read_u32(data, 1);
    t.assert_false(ok);
    t.assert_eq(0, value);

    let short: const u8[:] = "\xDE\xAD\xBE";
    let _, short_ok = vm::read_u32(short, 0);
    t.assert_false(short_ok);
}

fn test_bytes_equal_compares_only_in_bounds(t: goosetest::Test&) {
    let data: const u8[:] = "IREP0400";
    t.assert_true(vm::bytes_equal(data, 0, "IREP"));
    t.assert_true(vm::bytes_equal(data, 4, "0400"));
    t.assert_false(vm::bytes_equal(data, 1, "IREP"));
    t.assert_false(vm::bytes_equal(data, 5, "0400"));
    t.assert_true(vm::bytes_equal(data, 8, ""));
    t.assert_false(vm::bytes_equal(data, -1, "IREP"));
    t.assert_true(vm::bytes_equal("", 0, ""));
}
