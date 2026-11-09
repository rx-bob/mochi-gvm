// Package-entry smoke test for the VM modules.
namespace vm_vm_test;

import goosetest;
import vm;

fn test_vm_package_links(t: goosetest::Test&) {
    t.assert_true(vm::parse_error_name(vm::ParseError.Ok) == "ok");
    t.assert_eq(vm::RITE_HEADER_BYTES, 20);
}
