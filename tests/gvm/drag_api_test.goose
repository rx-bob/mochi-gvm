// Drag API coverage lives in host_api_test.goose alongside the VM host fixture.
namespace vm_drag_api_test;

import goosetest;
import vm;

fn test_drag_command_keeps_false_typed(t: goosetest::Test&) {
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
    var outbox: u8[>..] = [];
    let args: vm::MrbValue[1] = [vm::mrb_false()];
    let value = vm::drag_api_command(machine, "drag_set_data", args[..], outbox, vm::mrb_fixnum(9));
    t.assert_true(vm::mrb_is_true(value));
    t.assert_true(outbox.len >= 7);
    t.assert_true(outbox[outbox.len - 7..] == "false}\n");
}
