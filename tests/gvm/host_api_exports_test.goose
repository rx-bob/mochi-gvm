// Host ABI export functions are exercised by host_api_test.goose.
namespace vm_host_api_exports_test;

import goosetest;
import vm;

fn test_host_api_exports_seed_and_clear_storage(t: goosetest::Test&) {
    vm::host_reset();
    vm::goose_vm_seed_storage("drag_test", "stored");
    t.assert_true(vm::goose_vm_host_outbox().len == 0);
    vm::goose_vm_remove_storage("drag_test");
    t.assert_true(vm::goose_vm_host_outbox().len == 0);
}
