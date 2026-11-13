// Drag validation coverage lives in host_api_test.goose alongside VM payload tests.
namespace vm_drag_validation_test;

import goosetest;
import vm;

fn test_drag_value_accepts_supported_scalars(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    var items: i64 = 0;
    t.assert_true(vm::drag_value_valid(machine, vm::mrb_false(), 0, items));
    t.assert_eq(1, items);
}
