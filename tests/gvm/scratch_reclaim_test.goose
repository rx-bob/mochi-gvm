// Tests for instruction-boundary scratch reclamation.
//
// Tick scratch still resets at every host entry. These tests cover the
// additional boundary used by long row builds: unreachable headers, slots,
// ivars and string bytes are returned to free lists while active register
// windows and helper roots keep live temporaries intact.
namespace vm_scratch_reclaim_test;

import std;

import goosetest;
import vm;

fn test_scratch_collect_reclaims_strings(t: goosetest::Test&) {
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
    let first = vm::scratch_alloc_string(machine.scratch, "row-1");
    t.assert_true(vm::mrb_is_scratch(first));
    let second = vm::scratch_alloc_string(machine.scratch, "row-2");
    t.assert_true(vm::mrb_is_scratch(second));
    machine.regs.push(second);
    machine.frames.push(vm::CallFrame {
            record_index: 0,
            base: 0,
            self_value: vm::mrb_nil(),
            pc: 0,
            env_frame: -1,
            argc: 0,
        });
    machine.file.records.push(vm::IrepRecord {
            record_offset_bytes: 0,
            record_size_bytes: 0,
            nlocals: 1,
            nregs: 1,
            child_count: 0,
            catch_count: 0,
            iseq_length_bytes: 0,
            iseq_offset_bytes: 0,
            catch_offset_bytes: 0,
            pool_first_index: 0,
            pool_count: 0,
            syms_first_index: 0,
            syms_count: 0,
            parent_index: -1,
            first_child_index: -1,
            next_sibling_index: -1,
            depth: 0,
        });
    vm::scratch_collect(machine);
    t.assert_eq(1, vm::scratch_live_object_count(machine.scratch));
    t.assert_eq(2, vm::scratch_object_count(machine.scratch));
    let _, dead_ok = vm::scratch_object(machine.scratch, first);
    t.assert_false(dead_ok);
    let live, live_ok = vm::scratch_object(machine.scratch, second);
    t.assert_true(live_ok);
    t.assert_eq(vm::ArenaObjectKind.String, live.kind);
}

fn test_scratch_collect_keeps_helper_roots(t: goosetest::Test&) {
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
    let mapped = vm::scratch_alloc_array(machine.scratch);
    let result = vm::scratch_alloc_string(machine.scratch, "mapped-result");
    t.assert_true(vm::builtin_array_push(machine.pool, machine.scratch, mapped, result));
    let root = vm::scratch_root_begin(machine);
    vm::scratch_root(machine, mapped);
    vm::scratch_collect(machine);
    t.assert_eq(2, vm::scratch_live_object_count(machine.scratch));
    let array, array_ok = vm::scratch_object(machine.scratch, mapped);
    t.assert_true(array_ok);
    t.assert_eq(vm::ArenaObjectKind.Array, array.kind);
    t.assert_eq(1, vm::scratch_array_length(machine.scratch, mapped));
    vm::scratch_root_end(machine, root);
    vm::scratch_collect(machine);
    t.assert_eq(0, vm::scratch_live_object_count(machine.scratch));
}

fn test_scratch_reuses_before_capacity(t: goosetest::Test&) {
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
    var index = 0;
    while index < vm::SCRATCH_CAPACITY_OBJECTS * 2 {
        let text = vm::scratch_alloc_string(machine.scratch, "temporary-row-value");
        t.assert_true(vm::mrb_is_scratch(text));
        if vm::scratch_should_collect(machine.scratch) {
            vm::scratch_collect(machine);
        }
        index += 1;
    }
    t.assert_false(machine.scratch.overflow);
    t.assert_true(vm::scratch_live_object_count(machine.scratch) < 80);
}

fn test_scratch_failure_names_byte_resource(t: goosetest::Test&) {
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
    var chunk: u8[>..] = [];
    chunk.resize(4096, 120);
    var index = 0;
    while index < 32 {
        let value = vm::scratch_alloc_string(machine.scratch, chunk[..]);
        t.assert_true(vm::mrb_is_scratch(value));
        index += 1;
    }
    let rejected = vm::scratch_alloc_string(machine.scratch, chunk[..]);
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(machine.scratch.failure.active);
    t.assert_eq(vm::ScratchResource.Bytes, machine.scratch.failure.resource);
    t.assert_eq(4096, machine.scratch.failure.requested);
    t.assert_eq(vm::SCRATCH_CAPACITY_BYTES, machine.scratch.failure.used);
    t.assert_eq(vm::SCRATCH_CAPACITY_BYTES, machine.scratch.failure.capacity);
}

fn test_scratch_failure_names_slot_resource(t: goosetest::Test&) {
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
    let array = vm::scratch_alloc_array(machine.scratch);
    var index = 0;
    while index < vm::SCRATCH_CAPACITY_SLOTS {
        t.assert_true(vm::scratch_array_push(machine.scratch, array, vm::mrb_fixnum(index)));
        index += 1;
    }
    t.assert_false(vm::scratch_array_push(machine.scratch, array, vm::mrb_fixnum(0)));
    t.assert_true(machine.scratch.failure.active);
    t.assert_eq(vm::ScratchResource.Slots, machine.scratch.failure.resource);
    t.assert_eq(1, machine.scratch.failure.requested);
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS, machine.scratch.failure.used);
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS, machine.scratch.failure.capacity);
}

fn test_scratch_failure_names_ivar_resource(t: goosetest::Test&) {
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
    let instance = vm::scratch_alloc_instance(machine.scratch, 1);
    var index = 0;
    while index < vm::SCRATCH_CAPACITY_IVARS {
        t.assert_true(vm::scratch_set_ivar(machine.scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
        index += 1;
    }
    t.assert_false(vm::scratch_set_ivar(machine.scratch, instance,
        vm::SCRATCH_CAPACITY_IVARS as u32, vm::mrb_nil()));
    t.assert_true(machine.scratch.failure.active);
    t.assert_eq(vm::ScratchResource.Ivars, machine.scratch.failure.resource);
    t.assert_eq(1, machine.scratch.failure.requested);
    t.assert_eq(vm::SCRATCH_CAPACITY_IVARS, machine.scratch.failure.used);
    t.assert_eq(vm::SCRATCH_CAPACITY_IVARS, machine.scratch.failure.capacity);
}

fn test_scratch_failure_names_object_resource(t: goosetest::Test&) {
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
    let text = "x";
    var index = 0;
    while index < vm::SCRATCH_CAPACITY_OBJECTS {
        let value = vm::scratch_alloc_string(machine.scratch, text);
        t.assert_true(vm::mrb_is_scratch(value));
        index += 1;
    }
    let rejected = vm::scratch_alloc_string(machine.scratch, text);
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(machine.scratch.overflow);
    t.assert_true(machine.scratch.failure.active);
    t.assert_eq(vm::ScratchResource.Objects, machine.scratch.failure.resource);
    t.assert_eq(1, machine.scratch.failure.requested);
    t.assert_eq(vm::SCRATCH_CAPACITY_OBJECTS, machine.scratch.failure.used);
    t.assert_eq(vm::SCRATCH_CAPACITY_OBJECTS, machine.scratch.failure.capacity);
}
