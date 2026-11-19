// Transactional root boot: empty programs fail before executing any root.
namespace vm_boot_test;

import goosetest;
import vm;

fn test_boot_without_records_reports_bad_opcode(t: goosetest::Test&) {
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
    vm::vm_ensure_booted(machine);
    t.assert_eq(vm::VmError.BadOpcode, machine.error);
    t.assert_eq(0, machine.booted_roots);
}
