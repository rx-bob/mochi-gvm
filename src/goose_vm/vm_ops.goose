// Interpreter loop, host entrypoints and opcode handlers for the scalar VM.
//
// `vm_exec` owns the register-window and frame-stack discipline, while each
// `vm_op_*` helper decodes one family of instructions and returns a `Step` that
// tells the loop whether to continue, return, stop, or recurse into a child
// IREP. Keeping the handlers out of `vm_core.goose` holds both files under the
// style guide's 500-line limit and keeps every function below 70 lines.
namespace vm;

import.rite_types;
import.state_pool;
import.value_arena;
import.vm_core;

// Runs the root IREP once per loaded program. The root defines classes and
// methods, so every host entry calls this before looking anything up.
fn vm_ensure_booted(machine: Vm&) {
    if machine.booted {
        return;
    }
    if machine.file.records.len == 0 {
        machine.error = VmError.BadOpcode;
        return;
    }
    vm_exec(machine, 0, mrb_nil(), -1);
    if machine.error == VmError.Ok {
        machine.booted = true;
    }
}

// Creates a state instance of `class_sym` and runs its `initialize` method with
// no arguments. The returned instance is durable state, so the tick arena is
// released before returning.
fn vm_instantiate(machine: Vm&, class_sym: u32) -> MrbValue {
    vm_begin_entry(machine);
    vm_ensure_booted(machine);
    if machine.error != VmError.Ok {
        vm_end_entry(machine);
        return mrb_nil();
    }
    let class_id, found = vm_find_class(machine.pool, class_sym);
    if !found {
        machine.error = VmError.NoClass;
        vm_end_entry(machine);
        return mrb_nil();
    }
    let instance = state_alloc_instance(machine.pool, class_id);
    assert(state_register_component(machine.pool, instance));
    let irep, has_initialize = vm_lookup_method(machine, class_id, intern_symbol("initialize"));
    if has_initialize {
        vm_exec(machine, irep, instance, -1);
    }
    vm_end_entry(machine);
    if machine.error != VmError.Ok {
        return mrb_nil();
    }
    return instance;
}

// Calls a no-argument method on a state instance. The result may be a scratch
// string, so it stays valid until the host calls `vm_end_entry` after copying
// the bytes out; the next top-level entry clears the arena before it starts.
fn vm_call0(machine: Vm&, receiver: MrbValue, method_sym: u32) -> MrbValue {
    vm_begin_entry(machine);
    vm_ensure_booted(machine);
    if machine.error != VmError.Ok {
        vm_end_entry(machine);
        return mrb_nil();
    }
    let class_id, is_instance = vm_receiver_class_id(machine, receiver);
    if !is_instance {
        machine.error = VmError.BadReceiver;
        vm_end_entry(machine);
        return mrb_nil();
    }
    let irep, found = vm_lookup_method(machine, class_id, method_sym);
    if !found {
        machine.error = VmError.NoMethod;
        vm_end_entry(machine);
        return mrb_nil();
    }
    return vm_exec(machine, irep, receiver, -1);
}

// Executes one IREP frame. `dst_register` is an absolute register index in the
// caller's window, or -1 for a host entry call. Recursion is bounded by the
// frame-stack capacity and by `MAX_VM_CALL_DEPTH`.
recursive fn vm_exec(
    machine: Vm&, record_index: i64, self_value: MrbValue, dst_register: i64
) -> MrbValue {
    if machine.frames.len >= MAX_VM_CALL_DEPTH {
        machine.error = VmError.CallDepth;
        return mrb_nil();
    }
    assert(record_index >= 0);
    assert(record_index < machine.file.records.len);
    let record = machine.file.records[record_index];
    let base = machine.regs.len;
    if base + record.nregs > MAX_VM_REGS {
        machine.error = VmError.Registers;
        return mrb_nil();
    }
    for _ in record.nregs {
        machine.regs.push(mrb_nil());
    }
    machine.regs[base] = self_value;
    let frame = CallFrame {
        record_index: record_index,
        base: base,
        self_value: self_value,
        pc: 0,
    };
    machine.frames.push(frame);
    let frame_index = machine.frames.len - 1;
    let iseq = record_iseq(machine.file, record);
    var pc = 0;
    var running = true;
    var result = mrb_nil();

    while running && pc < iseq.len {
        let op = iseq[pc];
        let step = vm_exec_step(machine, frame, record, iseq, pc + 1, op);
        pc = step.pc;
        machine.frames[frame_index].pc = pc;
        if step.kind == StepKind.Execute {
            vm_exec(machine, step.child_index, step.value, step.dst_register);
        } else if step.kind == StepKind.Return {
            result = step.value;
            running = false;
        } else if step.kind != StepKind.Continue {
            running = false;
        }
    }

    machine.frames.pop();
    while machine.regs.len > base {
        machine.regs.pop();
    }
    if dst_register >= 0 {
        if dst_register >= machine.regs.len {
            machine.error = VmError.Registers;
        } else {
            machine.regs[dst_register] = result;
        }
    }
    return result;
}

// Routes one opcode byte to its handler family.
fn vm_exec_step(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_NOP {
        return vm_step_continue(pc);
    }
    if op == OP_MOVE {
        return vm_op_move(machine, frame, record, iseq, pc);
    }
    if (op >= OP_LOADI_0 && op <= OP_LOADI_7) || op == OP_LOADI8
        || op == OP_LOADINEG || op == OP_LOADI_NEG1 {
        return vm_op_loadi(machine, frame, record, iseq, pc, op);
    }
    if op == OP_LOADNIL || op == OP_LOADSELF || op == OP_LOADTRUE
        || op == OP_LOADFALSE || op == OP_LOADSYM {
        return vm_op_loadvalue(machine, frame, record, iseq, pc, op);
    }
    if op == OP_GETIV || op == OP_SETIV {
        return vm_op_ivar(machine, frame, record, iseq, pc, op);
    }
    if op == OP_ADDI || op == OP_SUBI {
        return vm_op_arith(machine, frame, record, iseq, pc, op);
    }
    if op == OP_STRING || op == OP_STRCAT {
        return vm_op_string(machine, frame, record, iseq, pc, op);
    }
    if op == OP_CLASS {
        return vm_op_class(machine, frame, record, iseq, pc);
    }
    if op == OP_EXEC {
        return vm_op_exec(machine, frame, record, iseq, pc);
    }
    if op == OP_TDEF {
        return vm_op_tdef(machine, frame, record, iseq, pc);
    }
    if op == OP_ENTER || op == OP_RETURN || op == OP_RETNIL || op == OP_STOP {
        return vm_op_control(machine, frame, record, iseq, pc, op);
    }
    machine.error = VmError.BadOpcode;
    return vm_step_stop(pc);
}

fn vm_op_move(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.b);
    if !value_ok || !vm_write_register(machine, record, frame.base, ops.a, value) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_loadi(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_LOADI8 || op == OP_LOADINEG {
        let ops = vm_read_operands(iseq, pc, 2);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        var value = ops.b;
        if op == OP_LOADINEG {
            value = -value;
        }
        if !vm_write_register(machine, record, frame.base, ops.a, mrb_fixnum(value)) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    var value = 0;
    if op == OP_LOADI_NEG1 {
        value = -1;
    } else if op >= OP_LOADI_0 && op <= OP_LOADI_7 {
        value = op - OP_LOADI_0;
    } else {
        return vm_fail(machine, VmError.BadOpcode, pc + 1);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, mrb_fixnum(value)) {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    return vm_step_continue(pc + 1);
}

fn vm_op_loadvalue(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let count = if op == OP_LOADSYM {
        2
    } else {
        1
    };
    let ops = vm_read_operands(iseq, pc, count);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    var value = mrb_nil();
    if op == OP_LOADSELF {
        value = machine.regs[frame.base];
    } else if op == OP_LOADTRUE {
        value = mrb_true();
    } else if op == OP_LOADFALSE {
        value = mrb_false();
    } else if op == OP_LOADSYM {
        let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
        if !symbol_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        value = mrb_symbol(symbol);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, value) {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    return vm_step_continue(pc + count);
}

fn vm_op_ivar(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    if !symbol_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    if op == OP_GETIV {
        let value, _ = state_get_ivar(machine.pool, machine.regs[frame.base], symbol);
        if !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !value_ok || !state_set_ivar(machine.pool, machine.scratch,
        machine.regs[frame.base], symbol, value) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_arith(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !value_ok || !mrb_is_fixnum(value) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 2);
    }
    var delta = ops.b;
    if op == OP_SUBI {
        delta = -delta;
    }
    let updated = mrb_fixnum_value(value) + delta;
    if updated < MRB_FIXNUM_MIN || updated > MRB_FIXNUM_MAX {
        return vm_fail(machine, VmError.TypeMismatch, pc + 2);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, mrb_fixnum(updated)) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_string(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_STRING {
        let ops = vm_read_operands(iseq, pc, 2);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let text, text_ok = vm_record_pool_text(machine.file, record, ops.b);
        if !text_ok
            || !vm_write_register(machine, record, frame.base, ops.a,
            scratch_alloc_string(machine.scratch, text)) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let left, left_ok = vm_read_register(machine, record, frame.base, ops.a);
    let right, right_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !left_ok || !right_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    let joined = vm_concat_text(machine, left, right);
    if !vm_write_register(machine, record, frame.base, ops.a, joined) {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    return vm_step_continue(pc + 1);
}

fn vm_op_class(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    let superclass, superclass_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !symbol_ok || !superclass_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    var superclass_id = NULL_CLASS_ID;
    if !mrb_is_nil(superclass) {
        if !mrb_is_class(superclass) {
            return vm_fail(machine, VmError.TypeMismatch, pc + 2);
        }
        superclass_id = mrb_class_id(superclass);
    }
    let class_id, found = vm_find_class(machine.pool, symbol);
    let defined = if found {
        class_id
    } else {
        state_define_class(machine.pool, symbol, superclass_id)
    };
    if !vm_write_register(machine, record, frame.base, ops.a, mrb_class(defined)) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_exec(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let child = vm_child_record(machine.file, frame.record_index, ops.b);
    let target, target_ok = vm_read_register(machine, record, frame.base, ops.a);
    if child < 0 || !target_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_execute(pc + 2, child, target, frame.base + ops.a);
}

fn vm_op_tdef(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    let child = vm_child_record(machine.file, frame.record_index, ops.c);
    let target = machine.regs[frame.base];
    if !symbol_ok || child < 0 || !mrb_is_class(target) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 3);
    }
    vm_define_method(machine, mrb_class_id(target), symbol, child);
    if !vm_write_register(machine, record, frame.base, ops.a, mrb_symbol(symbol)) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    return vm_step_continue(pc + 3);
}

fn vm_op_control(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_ENTER {
        let ops = vm_read_operands(iseq, pc, 3);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let flags = (ops.a << 16) | (ops.b << 8) | ops.c;
        if flags != 0 {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        return vm_step_continue(pc + 3);
    }
    if op == OP_RETURN {
        let ops = vm_read_operands(iseq, pc, 1);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
        if !value_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_return(pc + 1, value);
    }
    if op == OP_RETNIL {
        return vm_step_return(pc, mrb_nil());
    }
    if op == OP_STOP {
        return vm_step_stop(pc);
    }
    return vm_fail(machine, VmError.BadOpcode, pc);
}
