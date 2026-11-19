// Tests for the C-owned metadata slab used by package bytecode and symbols.
namespace vm_slab_test;

import std;

import goosetest;
import vm;

fn test_package_round_trip(t: goosetest::Test&) {
    vm::slab_use_default_limit();
    vm::slab_truncate_packages(0);
    let id = vm::slab_push_package("abc");
    t.assert_eq(id, 0);
    t.assert_eq(vm::slab_package_count(), 1);
    t.assert_eq(vm::slab_package_bytes_used(), 3);
    t.assert_true(vm::slab_package_bytes(id as u32, 0, 3) == "abc");
    let second = vm::slab_push_package("def");
    t.assert_eq(second, 1);
    t.assert_true(vm::slab_package_bytes(second as u32, 0, 3) == "def");
    vm::slab_truncate_packages(1);
    t.assert_eq(vm::slab_package_count(), 1);
    t.assert_eq(vm::slab_package_bytes_used(), 3);
    t.assert_true(vm::slab_package_bytes(id as u32, 0, 3) == "abc");
    vm::slab_truncate_packages(0);
    t.assert_eq(vm::slab_package_count(), 0);
    t.assert_eq(vm::slab_package_bytes_used(), 0);
}

fn test_package_rejects_over_budget(t: goosetest::Test&) {
    vm::slab_truncate_packages(0);
    vm::slab_set_limit(2);
    let id = vm::slab_push_package("abc");
    t.assert_eq(id, -1);
    t.assert_eq(vm::slab_package_count(), 0);
    t.assert_eq(vm::slab_package_bytes_used(), 0);
    vm::slab_use_default_limit();
}

fn test_symbol_bytes_survive_package_truncation(t: goosetest::Test&) {
    vm::slab_use_default_limit();
    let id = vm::slab_push_package("x");
    t.assert_eq(id, 0);
    let offset = vm::slab_intern_bytes("slab_symbol_probe");
    t.assert_true(offset >= 0);
    t.assert_true(vm::slab_symbol_bytes(offset, 17) == "slab_symbol_probe");
    let before = vm::slab_symbol_blob_length();
    vm::slab_truncate_packages(0);
    t.assert_eq(vm::slab_package_count(), 0);
    t.assert_true(vm::slab_symbol_bytes(offset, 17) == "slab_symbol_probe");
    vm::slab_truncate_symbol_bytes(before);
    t.assert_eq(vm::slab_symbol_blob_length(), before);
}
