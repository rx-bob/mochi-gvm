// Tests for tick-scratch allocation, byte reuse and capacity failures.
namespace vm_scratch_alloc_test;

import std;

import goosetest;
import vm;

fn test_scratch_alloc_reuses_freed_bytes(t: goosetest::Test&) {
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let first = vm::scratch_alloc_string(scratch, "first-value");
    t.assert_true(vm::mrb_is_scratch(first));
    var index = 0;
    while index < 64 {
        let value = vm::scratch_alloc_string(scratch, "garbage-value");
        t.assert_true(vm::mrb_is_scratch(value));
        index += 1;
    }
    let before = vm::scratch_bytes_used(scratch);
    vm::scratch_reset(scratch);
    let again = vm::scratch_alloc_string(scratch, "first-value");
    t.assert_true(vm::mrb_is_scratch(again));
    t.assert_true(vm::scratch_string_bytes(scratch, again) == "first-value");
    t.assert_eq(11, vm::scratch_bytes_used(scratch));
    t.assert_true(before > 11);
}
