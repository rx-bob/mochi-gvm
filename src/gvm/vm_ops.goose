// Interpreter loop, host entrypoints and opcode handlers for the scalar VM.
//
// `vm_exec` owns the register-window and frame-stack discipline, while each
// `vm_op_*` helper decodes one family of instructions and returns a `Step` that
// tells the loop whether to continue, return, stop, or recurse into a child
// IREP. Keeping the handlers out of `vm_core.goose` keeps every function small.
namespace vm;

import.rite_types;
import.scratch_alloc;
import.scratch_reclaim;
import.state_pool;
import.state_reclaim;
import.value_arena;
import.vm_constants;
import.vm_core;
import.vm_dispatch;
import.vm_num;
import.vm_ops_collections;

// Runs the root IREP once per loaded program. Each root advances `booted_roots`
// before executing so a runtime failure in one class body does not leave later
// components unbooted.
fn vm_ensure_booted(machine: Vm&) {
    if machine.file.records.len == 0 {
        machine.error = VmError.BadOpcode;
        return;
    }
    var first_error = VmError.Ok;
    while machine.booted_roots < machine.file.roots.len {
        let root = machine.file.roots[machine.booted_roots];
        machine.booted_roots += 1;
        vm_exec(machine, root, mrb_nil(), -1);
        if machine.error != VmError.Ok {
            if first_error == VmError.Ok {
                first_error = machine.error;
            }
            machine.error = VmError.Ok;
        }
    }
    if first_error != VmError.Ok {
        machine.error = first_error;
    }
}

recursive fn vm_exec(
    machine: Vm&, record_index: i64, self_value: MrbValue, dst_register: i64
) -> MrbValue {
    let no_args: MrbValue[1] = [mrb_nil()];
    return vm_exec_frame(machine, record_index, self_value, dst_register, no_args[..0], -1);
}

recursive fn vm_exec_with_args(
    machine: Vm&, record_index: i64, self_value: MrbValue, dst_register: i64, args: MrbValue[:]
) -> MrbValue {
    return vm_exec_frame(machine, record_index, self_value, dst_register, args, -1);
}

fn vm_finish_frame(machine: Vm&, base: i64, dst_register: i64, result: MrbValue) -> MrbValue {
    machine.frames.pop();
    while machine.regs.len > base {
        machine.regs.pop();
    }
    if dst_register >= 0 && dst_register >= machine.regs.len {
        machine.error = VmError.Registers;
        return result;
    }
    if dst_register >= 0 {
        machine.regs[dst_register] = result;
    }
    return result;
}

// Executes one IREP frame with arguments and an optional lexical parent.
recursive fn vm_exec_frame(
    machine: Vm&, record_index: i64, self_value: MrbValue,
    dst_register: i64, args: MrbValue[:], env_frame: i64
) -> MrbValue {
    if machine.frames.len >= MAX_VM_CALL_DEPTH {
        machine.error = VmError.CallDepth;
        vm_absorb_method_context(machine, record_index);
        return mrb_nil();
    }
    assert(record_index >= 0);
    assert(record_index < machine.file.records.len);
    let record = machine.file.records[record_index];
    let iseq = record_iseq(machine.file, record);
    if env_frame < 0 && !vm_entry_arity_ok(machine, iseq, args) {
        vm_absorb_method_context(machine, record_index);
        return mrb_nil();
    }
    let base = machine.regs.len;
    if base + record.nregs > MAX_VM_REGS {
        machine.error = VmError.Registers;
        vm_absorb_method_context(machine, record_index);
        return mrb_nil();
    }
    vm_initialize_registers(machine, record.nregs, self_value, args);
    let frame = CallFrame {
        record_index: record_index,
        base: base,
        self_value: self_value,
        pc: 0,
        env_frame: env_frame,
        argc: args.len,
        lexical_owner: vm_lexical_owner(machine, record_index, self_value, env_frame),
    };
    machine.frames.push(frame);
    let frame_index = machine.frames.len - 1;
    var pc = 0;
    var running = true;
    var result = mrb_nil();

    while running && pc < iseq.len {
        let op = iseq[pc];
        let step = vm_exec_step(machine, frame, record, iseq, pc + 1, op);
        pc = step.pc;
        machine.frames[frame_index].pc = pc;
        if machine.pool.error != VmError.Ok && machine.error == VmError.Ok {
            machine.error = machine.pool.error;
        }
        if machine.scratch.overflow && machine.error == VmError.Ok {
            machine.error = VmError.ScratchFull;
            vm_absorb_scratch_failure(machine, record_index);
            running = false;
        } else if step.kind == StepKind.Execute {
            vm_exec(machine, step.child_index, step.value, step.dst_register);
            if machine.error != VmError.Ok {
                running = false;
            }
        } else if step.kind == StepKind.Return {
            result = step.value;
            running = false;
        } else if step.kind != StepKind.Continue {
            running = false;
        }
        if machine.error != VmError.Ok {
            vm_absorb_method_context(machine, record_index);
            running = false;
        }
    }

    return vm_finish_frame(machine, base, dst_register, result);
}

// Initializes one checked register window before publishing its call frame.
fn vm_initialize_registers(machine: Vm&, count: i64, self_value: MrbValue, args: MrbValue[:]) {
    let base = machine.regs.len;
    for _ in count {
        machine.regs.push(mrb_nil());
    }
    machine.regs[base] = self_value;
    var argument = 0;
    while argument < args.len && argument + 1 < count {
        machine.regs[base + 1 + argument] = args[argument];
        argument += 1;
    }
}

// Routes one opcode byte to its handler family.
fn vm_exec_step(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    // Between instructions every live value is in a register window, so a
    // collection here cannot invalidate an in-flight expression.
    gc_maybe_collect(machine);
    scratch_maybe_collect(machine);
    if machine.pool.computed_depth > 0 && (op == OP_SETIV || op == OP_SETCONST) {
        return vm_fail(machine, VmError.ComputedEffect, pc);
    }
    let dispatched, handled = vm_dispatch_step(machine, frame, record, iseq, pc, op);
    if handled {
        return dispatched;
    }
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
    if op == OP_LOADL || op == OP_LOADI16 || op == OP_LOADI32 {
        return vm_op_load_literal(machine, frame, record, iseq, pc, op);
    }
    if op == OP_LOADNIL || op == OP_LOADSELF || op == OP_LOADTRUE
        || op == OP_LOADFALSE || op == OP_LOADSYM {
        return vm_op_loadvalue(machine, frame, record, iseq, pc, op);
    }
    if op == OP_GETIV || op == OP_SETIV {
        return vm_op_ivar(machine, frame, record, iseq, pc, op);
    }
    if op == OP_GETUPVAR || op == OP_SETUPVAR {
        return vm_op_upvar(machine, frame, record, iseq, pc, op);
    }
    if op == OP_GETIDX || op == OP_GETIDX0 || op == OP_SETIDX || op == OP_AREF {
        return vm_op_index(machine, frame, record, iseq, pc, op);
    }
    if op == OP_HASH || op == OP_HASHADD || op == OP_HASHCAT {
        return vm_op_hash(machine, frame, record, iseq, pc, op);
    }
    if op == OP_ADDI || op == OP_SUBI || op == OP_ADDILV || op == OP_SUBILV {
        return vm_op_arith(machine, frame, record, iseq, pc, op);
    }
    if op == OP_STRING || op == OP_STRCAT || op == OP_SYMBOL {
        return vm_op_string(machine, frame, record, iseq, pc, op);
    }
    if op == OP_CLASS || op == OP_MODULE {
        return vm_op_class(machine, frame, record, iseq, pc, op);
    }
    if op == OP_EXEC {
        return vm_op_exec(machine, frame, record, iseq, pc);
    }
    if op == OP_TDEF || op == OP_SDEF {
        return vm_op_tdef(machine, frame, record, iseq, pc, op);
    }
    if op == OP_ENTER || op == OP_RETURN
        || op == OP_RETSELF || op == OP_RETNIL || op == OP_RETTRUE
        || op == OP_RETFALSE || op == OP_STOP {
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
        if machine.pool.error != VmError.Ok {
            return vm_fail(machine, machine.pool.error, pc + 2);
        }
        if !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !value_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    if !state_set_ivar(machine.pool, machine.scratch, machine.regs[frame.base], symbol, value) {
        if machine.pool.error != VmError.Ok {
            return vm_fail(machine, machine.pool.error, pc + 2);
        }
        return vm_fail(machine, VmError.TypeMismatch, pc + 2);
    }
    if machine.pool.error != VmError.Ok {
        return vm_fail(machine, machine.pool.error, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_arith(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let is_ilv = op == OP_ADDILV || op == OP_SUBILV;
    let count = if is_ilv {
        3
    } else {
        2
    };
    let ops = vm_read_operands(iseq, pc, count);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !value_ok || !num_is_number(machine.scratch, machine.pool, value) {
        return vm_fail(machine, VmError.TypeMismatch, pc + count);
    }
    let delta = if is_ilv {
        ops.c
    } else {
        ops.b
    };
    var updated: MrbValue = mrb_nil();
    var fault: NumFault = NumFault.Ok;
    if op == OP_SUBI || op == OP_SUBILV {
        updated, fault = num_sub(machine.scratch, machine.pool, value, mrb_fixnum(delta));
    } else {
        updated, fault = num_add(machine.scratch, machine.pool, value, mrb_fixnum(delta));
    }
    if fault != NumFault.Ok {
        let error = if fault == NumFault.Overflow {
            VmError.IntegerOverflow
        } else if fault == NumFault.Scratch {
            VmError.ScratchFull
        } else {
            VmError.TypeMismatch
        };
        return vm_fail(machine, error, pc + count);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, updated) {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    return vm_step_continue(pc + count);
}

fn vm_op_class(
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
    var superclass_id = NULL_CLASS_ID;
    if op == OP_CLASS {
        let superclass, superclass_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
        if !superclass_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        if !mrb_is_nil(superclass) {
            if !mrb_is_class(superclass) {
                return vm_fail(machine, VmError.TypeMismatch, pc + 2);
            }
            superclass_id = mrb_class_id(superclass);
        }
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
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    let child = vm_child_record(machine.file, frame.record_index, ops.c);
    var target = machine.regs[frame.base];
    if op == OP_SDEF {
        let explicit, explicit_ok = vm_read_register(machine, record, frame.base, ops.a);
        if !explicit_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        target = explicit;
    }
    if !symbol_ok || child < 0 || !mrb_is_class(target) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 3);
    }
    vm_define_method(machine, mrb_class_id(target), symbol, child, frame.lexical_owner);
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
        let aspec = (ops.a << 16) | (ops.b << 8) | ops.c;
        let required = (aspec >> 18) & 0x1f;
        let optional = (aspec >> 13) & 0x1f;
        let rest = (aspec >> 12) & 1;
        let post = (aspec >> 7) & 0x1f;
        let key = (aspec >> 2) & 0x1f;
        let kdict = (aspec >> 1) & 1;
        if rest != 0 || post != 0 || key != 0 || kdict != 0 {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        if optional > 0 {
            var provided = frame.argc - required;
            if provided < 0 {
                provided = 0;
            }
            if provided > optional {
                provided = optional;
            }
            return vm_step_continue(pc + 3 + provided * 3);
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
    if op == OP_RETSELF {
        return vm_step_return(pc, machine.regs[frame.base]);
    }
    if op == OP_RETNIL {
        return vm_step_return(pc, mrb_nil());
    }
    if op == OP_RETTRUE {
        return vm_step_return(pc, mrb_true());
    }
    if op == OP_RETFALSE {
        return vm_step_return(pc, mrb_false());
    }
    if op == OP_STOP {
        return vm_step_stop(pc);
    }
    return vm_fail(machine, VmError.BadOpcode, pc);
}
