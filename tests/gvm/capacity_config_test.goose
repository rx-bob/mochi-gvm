// Tests that the default build profile stays aligned with existing hard VM bounds.
namespace vm_capacity_config_test;

import std;

import goosetest;
import vm;

fn test_default_capacity_values(t: goosetest::Test&) {
    t.assert_eq(131072, vm::SCRATCH_CAPACITY_BYTES);
    t.assert_eq(2048, vm::SCRATCH_CAPACITY_OBJECTS);
    t.assert_eq(2048, vm::SCRATCH_CAPACITY_IVARS);
    t.assert_eq(4096, vm::SCRATCH_CAPACITY_SLOTS);
    t.assert_eq(512, vm::MAX_STATE_CLASSES);
    t.assert_eq(32768, vm::MAX_STATE_OBJECTS);
    t.assert_eq(65536, vm::MAX_STATE_IVARS);
    t.assert_eq(131072, vm::MAX_STATE_SLOTS);
    t.assert_eq(8388608, vm::MAX_STATE_BYTES);
    t.assert_eq(1024, vm::MAX_STATE_COMPONENTS);
    t.assert_eq(2048, vm::MAX_BINDINGS);
    t.assert_eq(8, vm::ABI_MAX_CALL_ARGS);
    t.assert_eq(4194304, vm::ABI_MAX_BYTECODE);
}
