// Tests for the scalar VM internals that are not exposed through a component
// lifecycle: error naming, operand decoding bounds, and the step protocol that
// the interpreter loop uses to return, stop, or recurse into a child IREP.
namespace vm_ops_test;

import std;

import goosetest;
import vm;

fn test_error_names_cover_vm_failures(t: goosetest::Test&) {
    t.assert_true(vm::vm_error_name(vm::VmError.Ok) == "ok");
    t.assert_true(vm::vm_error_name(vm::VmError.BadOpcode) == "bad opcode");
    t.assert_true(vm::vm_error_name(vm::VmError.BadOperand) == "bad operand");
    t.assert_true(vm::vm_error_name(vm::VmError.NoClass) == "unknown class");
    t.assert_true(vm::vm_error_name(vm::VmError.NoMethod) == "unknown method");
    t.assert_true(vm::vm_error_name(vm::VmError.TypeMismatch) == "type mismatch");
    t.assert_true(vm::vm_error_name(vm::VmError.WrongArity) == "wrong number of arguments");
    t.assert_true(vm::vm_error_name(vm::VmError.CallDepth) == "call depth exceeded");
}

fn test_operand_reader_rejects_short_stream(t: goosetest::Test&) {
    let bytes: u8[4] = [1, 2, 3, 4];
    let ops = vm::vm_read_operands(bytes[..], 1, 2);
    t.assert_true(ops.valid);
    t.assert_eq(2, ops.a);
    t.assert_eq(3, ops.b);
    let short = vm::vm_read_operands(bytes[..], 3, 2);
    t.assert_false(short.valid);
    let empty = vm::vm_read_operands(bytes[..], 0, 0);
    t.assert_true(empty.valid);
    t.assert_eq(0, empty.a);
}

fn test_step_constructors_carry_payload(t: goosetest::Test&) {
    let continuing = vm::vm_step_continue(4);
    t.assert_eq(vm::StepKind.Continue, continuing.kind);
    t.assert_eq(4, continuing.pc);
    t.assert_eq(-1, continuing.dst_register);

    let returning = vm::vm_step_return(9, vm::mrb_fixnum(3));
    t.assert_eq(vm::StepKind.Return, returning.kind);
    t.assert_eq(3, vm::mrb_fixnum_value(returning.value));

    let executing = vm::vm_step_execute(12, 5, vm::mrb_fixnum(7), 8);
    t.assert_eq(vm::StepKind.Execute, executing.kind);
    t.assert_eq(5, executing.child_index);
    t.assert_eq(8, executing.dst_register);
    t.assert_eq(7, vm::mrb_fixnum_value(executing.value));

    let stopped = vm::vm_step_stop(2);
    t.assert_eq(vm::StepKind.Stop, stopped.kind);
    t.assert_eq(2, stopped.pc);
}

// Builds the minimal record header that operand handlers read: they only use
// `nregs` and the symbol range.
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

fn test_move_and_integer_loads(t: goosetest::Test&) {
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
    let record = fake_record(3);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    for _ in record.nregs {
        machine.regs.push(vm::mrb_nil());
    }
    machine.regs[0] = vm::mrb_fixnum(7);

    let move_bytes: u8[2] = [1, 0];
    let moved = vm::vm_op_move(machine, frame, record, move_bytes[..], 0);
    t.assert_eq(vm::StepKind.Continue, moved.kind);
    t.assert_eq(2, moved.pc);
    t.assert_eq(7, vm::mrb_fixnum_value(machine.regs[1]));

    let load_bytes: u8[2] = [1, 200];
    let loaded = vm::vm_op_loadi(machine, frame, record, load_bytes[..], 0, vm::OP_LOADI8);
    t.assert_eq(vm::StepKind.Continue, loaded.kind);
    t.assert_eq(200, vm::mrb_fixnum_value(machine.regs[1]));
    let negative = vm::vm_op_loadi(machine, frame, record, load_bytes[..], 0, vm::OP_LOADINEG);
    t.assert_eq(-200, vm::mrb_fixnum_value(machine.regs[1]));

    let one_byte: u8[1] = [2];
    let zero = vm::vm_op_loadi(machine, frame, record, one_byte[..], 0, vm::OP_LOADI_0);
    t.assert_eq(0, vm::mrb_fixnum_value(machine.regs[2]));
    t.assert_eq(1, zero.pc);
    vm::vm_op_loadi(machine, frame, record, one_byte[..], 0, vm::OP_LOADI_7);
    t.assert_eq(7, vm::mrb_fixnum_value(machine.regs[2]));
    vm::vm_op_loadi(machine, frame, record, one_byte[..], 0, vm::OP_LOADI_NEG1);
    t.assert_eq(-1, vm::mrb_fixnum_value(machine.regs[2]));
}

fn test_boolean_nil_self_and_symbol_loads(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    file.syms.push(vm::SymbolId {
            index: 42,
        });
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
    var record = fake_record(2);
    record.syms_count = 1;
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_fixnum(99),
        pc: 0,
    };
    machine.regs.push(vm::mrb_fixnum(99));
    machine.regs.push(vm::mrb_nil());

    let one_byte: u8[1] = [1];
    vm::vm_op_loadvalue(machine, frame, record, one_byte[..], 0, vm::OP_LOADTRUE);
    t.assert_true(vm::mrb_is_true(machine.regs[1]));
    vm::vm_op_loadvalue(machine, frame, record, one_byte[..], 0, vm::OP_LOADFALSE);
    t.assert_true(vm::mrb_is_false(machine.regs[1]));
    vm::vm_op_loadvalue(machine, frame, record, one_byte[..], 0, vm::OP_LOADNIL);
    t.assert_true(vm::mrb_is_nil(machine.regs[1]));
    vm::vm_op_loadvalue(machine, frame, record, one_byte[..], 0, vm::OP_LOADSELF);
    t.assert_eq(99, vm::mrb_fixnum_value(machine.regs[1]));

    let symbol_bytes: u8[2] = [1, 0];
    let symbol_step = vm::vm_op_loadvalue(machine, frame, record, symbol_bytes[..], 0, vm::OP_LOADSYM);
    t.assert_eq(2, symbol_step.pc);
    t.assert_eq(42, vm::mrb_symbol_id(machine.regs[1]));
}

fn test_control_flow_steps(t: goosetest::Test&) {
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
    let record = fake_record(2);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    machine.regs.push(vm::mrb_nil());
    machine.regs.push(vm::mrb_fixnum(5));

    let enter_bytes: u8[3] = [0, 0, 0];
    let entered = vm::vm_op_control(machine, frame, record, enter_bytes[..], 0, vm::OP_ENTER);
    t.assert_eq(vm::StepKind.Continue, entered.kind);
    t.assert_eq(3, entered.pc);

    let return_bytes: u8[1] = [1];
    let returned = vm::vm_op_control(machine, frame, record, return_bytes[..], 0, vm::OP_RETURN);
    t.assert_eq(vm::StepKind.Return, returned.kind);
    t.assert_eq(5, vm::mrb_fixnum_value(returned.value));
    let nil_return = vm::vm_op_control(machine, frame, record, return_bytes[..], 0, vm::OP_RETNIL);
    t.assert_eq(vm::StepKind.Return, nil_return.kind);
    t.assert_true(vm::mrb_is_nil(nil_return.value));
    let stopped = vm::vm_op_control(machine, frame, record, return_bytes[..], 0, vm::OP_STOP);
    t.assert_eq(vm::StepKind.Stop, stopped.kind);
}

fn test_arith_overflow_reports_type_mismatch(t: goosetest::Test&) {
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
    let record = fake_record(2);
    let frame = vm::CallFrame {
        record_index: 0,
        base: 0,
        self_value: vm::mrb_nil(),
        pc: 0,
    };
    machine.regs.push(vm::mrb_fixnum(2147483647));
    machine.regs.push(vm::mrb_nil());
    let bytes: u8[2] = [0, 1];
    let step = vm::vm_op_arith(machine, frame, record, bytes[..], 0, vm::OP_ADDI);
    t.assert_eq(vm::StepKind.Stop, step.kind);
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}
