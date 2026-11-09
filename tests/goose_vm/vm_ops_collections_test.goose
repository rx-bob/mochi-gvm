// Tests for the HASH, GETIDX and SETIDX opcode handlers.
namespace vm_ops_collections_test;

import std;

import goosetest;
import vm;

fn fake_record(nregs: u16) -> vm::IrepRecord {
    return vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 0,
        nlocals: 1,
        nregs: nregs,
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
    };
}

fn test_hash_opcode_builds_scratch_hash(t: goosetest::Test&) {
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
    let record = fake_record(6);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    for _ in record.nregs {
        machine.regs.push(vm::mrb_nil());
    }
    let id = vm::mrb_symbol(7);
    let text = vm::mrb_symbol(8);
    machine.regs[1] = id;
    machine.regs[2] = vm::mrb_fixnum(1);
    machine.regs[3] = text;
    machine.regs[4] = vm::mrb_fixnum(2);

    let bytes: u8[2] = [1, 2];
    let step = vm::vm_op_hash(machine, frame, record, bytes[..], 0);
    t.assert_eq(vm::StepKind.Continue, step.kind);
    t.assert_eq(2, step.pc);
    t.assert_true(vm::scratch_is_hash(machine.scratch, machine.regs[1]));
    let id_value, id_ok = vm::scratch_hash_get(machine.scratch, machine.regs[1], id);
    let text_value, text_ok = vm::scratch_hash_get(machine.scratch, machine.regs[1], text);
    t.assert_true(id_ok);
    t.assert_true(text_ok);
    t.assert_eq(1, vm::mrb_fixnum_value(id_value));
    t.assert_eq(2, vm::mrb_fixnum_value(text_value));

    let empty_bytes: u8[2] = [1, 0];
    vm::vm_op_hash(machine, frame, record, empty_bytes[..], 0);
    t.assert_true(vm::scratch_is_hash(machine.scratch, machine.regs[1]));
    t.assert_eq(0, vm::scratch_hash_length(machine.scratch, machine.regs[1]));
}

fn test_getidx_and_setidx_on_hash_and_array(t: goosetest::Test&) {
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
    let record = fake_record(4);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    for _ in record.nregs {
        machine.regs.push(vm::mrb_nil());
    }

    let key = vm::mrb_symbol(10);
    let hash = vm::scratch_alloc_hash(machine.scratch);
    t.assert_true(vm::scratch_hash_set(machine.scratch, hash, key, vm::mrb_fixnum(10)));
    machine.regs[1] = hash;
    machine.regs[2] = key;
    let get_bytes: u8[1] = [1];
    let got = vm::vm_op_index(machine, frame, record, get_bytes[..], 0, vm::OP_GETIDX);
    t.assert_eq(vm::StepKind.Continue, got.kind);
    t.assert_eq(10, vm::mrb_fixnum_value(machine.regs[1]));

    machine.regs[1] = hash;
    machine.regs[2] = key;
    machine.regs[3] = vm::mrb_fixnum(11);
    let set_bytes: u8[1] = [1];
    let set = vm::vm_op_index(machine, frame, record, set_bytes[..], 0, vm::OP_SETIDX);
    t.assert_eq(vm::StepKind.Continue, set.kind);
    t.assert_eq(11, vm::mrb_fixnum_value(vm::builtin_hash_get(
        machine.pool, machine.scratch, hash, key)));

    let array = vm::scratch_alloc_array(machine.scratch);
    t.assert_true(vm::scratch_array_push(machine.scratch, array, vm::mrb_fixnum(4)));
    t.assert_true(vm::scratch_array_push(machine.scratch, array, vm::mrb_fixnum(5)));
    machine.regs[1] = array;
    machine.regs[2] = vm::mrb_fixnum(-1);
    vm::vm_op_index(machine, frame, record, get_bytes[..], 0, vm::OP_GETIDX);
    t.assert_eq(5, vm::mrb_fixnum_value(machine.regs[1]));

    machine.regs[1] = array;
    machine.regs[2] = vm::mrb_fixnum(0);
    machine.regs[3] = vm::mrb_fixnum(9);
    vm::vm_op_index(machine, frame, record, set_bytes[..], 0, vm::OP_SETIDX);
    let updated, updated_ok = vm::scratch_array_get(machine.scratch, array, 0);
    t.assert_true(updated_ok);
    t.assert_eq(9, vm::mrb_fixnum_value(updated));
}

fn test_setidx_rejects_non_container(t: goosetest::Test&) {
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
    let record = fake_record(4);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    for _ in record.nregs {
        machine.regs.push(vm::mrb_nil());
    }
    machine.regs[1] = vm::mrb_fixnum(1);
    machine.regs[2] = vm::mrb_symbol(1);
    machine.regs[3] = vm::mrb_nil();
    let bytes: u8[1] = [1];
    let step = vm::vm_op_index(machine, frame, record, bytes[..], 0, vm::OP_SETIDX);
    t.assert_eq(vm::StepKind.Stop, step.kind);
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}
