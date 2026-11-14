// Tests for the VM's control-flow instruction handlers.
namespace vm_ops_control_test;

import std;

import goosetest;
import vm;

fn test_stop_opcode_stops_frame(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let step = vm::vm_op_control(machine, vm::CallFrame {
            ..
        }, vm::IrepRecord {
            ..
        }, "", 0,
        vm::OP_STOP);
    t.assert_eq(vm::StepKind.Stop, step.kind);
}
