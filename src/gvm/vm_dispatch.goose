// Branching, constants, array construction, and SEND-family opcode handlers.
namespace vm;

import.builtins;
import.value_arena;
import.vm_blocks;
import.vm_core;
import.vm_methods;

// Handles the extended opcode set and reports whether `op` belongs here.
fn vm_dispatch_step(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step, bool {
    if op == OP_GETCONST {
        return vm_op_getconst(machine, frame, record, iseq, pc), true;
    }
    if op == OP_JMP || op == OP_JMPUW {
        return vm_op_jump(machine, iseq, pc), true;
    }
    if op == OP_JMPIF || op == OP_JMPNOT {
        return vm_op_cond_jump(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_ADD || op == OP_SUB || op == OP_EQ || op == OP_LT
        || op == OP_LE || op == OP_GT || op == OP_GE {
        return vm_op_binary(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_ARRAY {
        return vm_op_array(machine, frame, record, iseq, pc), true;
    }
    if op == OP_BLOCK {
        return vm_op_block(machine, frame, record, iseq, pc), true;
    }
    if op == OP_SENDB {
        return vm_op_send_block(machine, frame, record, iseq, pc), true;
    }
    if op == OP_SEND || op == OP_SEND0 || op == OP_SSEND || op == OP_SSEND0 {
        return vm_op_send(machine, frame, record, iseq, pc, op), true;
    }
    return vm_step_continue(pc), false;
}

fn vm_op_getconst(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    if !symbol_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    let name = symbol_name(symbol);
    var value = mrb_nil();
    if name == "Array" {
        value = mrb_class(BUILTIN_ARRAY_CLASS_ID);
    } else if name == "Mochi" {
        value = mrb_class(BUILTIN_MOCHI_CLASS_ID);
    } else {
        let class_id, found = vm_find_class(machine.pool, symbol);
        if !found {
            return vm_fail(machine, VmError.NoClass, pc + 2);
        }
        value = mrb_class(class_id);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, value) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_jump(machine: Vm&, iseq: u8[:], pc: i64) -> Step {
    let offset, offset_ok = vm_read_signed16(iseq, pc);
    if !offset_ok {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let target = pc + 2 + offset;
    if target < 0 || target > iseq.len {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(target);
}

fn vm_op_cond_jump(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    let offset, offset_ok = vm_read_signed16(iseq, pc + 1);
    if !ops.valid || !offset_ok {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !value_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    let next = pc + 3;
    var take = mrb_truthy(value);
    if op == OP_JMPNOT {
        take = !take;
    }
    if !take {
        return vm_step_continue(next);
    }
    let target = next + offset;
    if target < 0 || target > iseq.len {
        return vm_fail(machine, VmError.BadOperand, next);
    }
    return vm_step_continue(target);
}

fn vm_values_equal(machine: Vm&, left: MrbValue, right: MrbValue) -> bool {
    if vm_is_string_value(machine, left) && vm_is_string_value(machine, right) {
        return builtin_string_bytes(machine.pool, machine.scratch, left)
            == builtin_string_bytes(machine.pool, machine.scratch, right);
    }
    return mrb_value_identical(left, right);
}

fn vm_op_binary(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let left, left_ok = vm_read_register(machine, record, frame.base, ops.a);
    let right, right_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !left_ok || !right_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    if op == OP_EQ {
        if !vm_write_register(machine, record, frame.base, ops.a,
            mrb_bool(vm_values_equal(machine, left, right))) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_continue(pc + 1);
    }
    if !mrb_is_fixnum(left) || !mrb_is_fixnum(right) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 1);
    }
    let left_number = mrb_fixnum_value(left);
    let right_number = mrb_fixnum_value(right);
    if op == OP_LT || op == OP_LE || op == OP_GT || op == OP_GE {
        var comparison = false;
        if op == OP_LT {
            comparison = left_number < right_number;
        } else if op == OP_LE {
            comparison = left_number <= right_number;
        } else if op == OP_GT {
            comparison = left_number > right_number;
        } else {
            comparison = left_number >= right_number;
        }
        if !vm_write_register(machine, record, frame.base, ops.a, mrb_bool(comparison)) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_continue(pc + 1);
    }
    var result = left_number + right_number;
    if op == OP_SUB {
        result = left_number - right_number;
    }
    if result < MRB_FIXNUM_MIN || result > MRB_FIXNUM_MAX {
        return vm_fail(machine, VmError.TypeMismatch, pc + 1);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, mrb_fixnum(result)) {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    return vm_step_continue(pc + 1);
}

fn vm_op_array(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let array = builtin_array_new(machine.scratch);
    var index = 0;
    while index < ops.b {
        let value, value_ok = vm_read_register(machine, record, frame.base, ops.a + index);
        if !value_ok || !builtin_array_push(machine.pool, machine.scratch, array, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        index += 1;
    }
    if !vm_write_register(machine, record, frame.base, ops.a, array) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_block(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let child = vm_child_record(machine.file, frame.record_index, ops.b);
    if child < 0 || !vm_write_register(machine, record, frame.base, ops.a, mrb_block(child)) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_send(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let no_args = op == OP_SEND0 || op == OP_SSEND0;
    let count = if no_args {
        2
    } else {
        3
    };
    let ops = vm_read_operands(iseq, pc, count);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    if !symbol_ok {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    var arg_count = 0;
    if !no_args {
        if ops.c >= 15 || ops.c > MAX_VM_ARGS {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        arg_count = ops.c;
    }
    let receiver_value, receiver_ok = vm_read_register(machine, record, frame.base, ops.a);
    if !receiver_ok {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    var receiver = receiver_value;
    if op == OP_SSEND || op == OP_SSEND0 {
        receiver = frame.self_value;
    }
    var args: MrbValue[..MAX_VM_ARGS] = [];
    var index = 0;
    while index < arg_count {
        let value, value_ok = vm_read_register(machine, record, frame.base, ops.a + 1 + index);
        if !value_ok {
            return vm_fail(machine, VmError.BadOperand, pc + count);
        }
        args.push(value);
        index += 1;
    }
    let found, ok = vm_call_user_method(machine, frame, receiver, symbol, args[..], ops.a);
    if found {
        if !ok {
            return vm_step_stop(pc + count);
        }
        return vm_step_continue(pc + count);
    }
    let result, handled = vm_call_builtin(machine, receiver, symbol, args[..]);
    if !handled {
        return vm_fail(machine, VmError.NoMethod, pc + count);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, result) {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    return vm_step_continue(pc + count);
}

fn vm_op_send_block(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    if !ops.valid || ops.c >= 15 {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    let receiver, receiver_ok = vm_read_register(machine, record, frame.base, ops.a);
    let closure, block_ok = vm_read_register(machine, record, frame.base, ops.a + ops.c + 1);
    if !symbol_ok || !receiver_ok || !block_ok || !mrb_is_block(closure) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    let name = symbol_name(symbol);
    if (name != "map" && name != "each") || !vm_is_array_value(machine, receiver) {
        return vm_fail(machine, VmError.NoMethod, pc + 3);
    }
    let result = vm_iterate_array(machine, receiver, closure, frame.self_value, name == "map");
    if machine.error != VmError.Ok {
        return vm_step_stop(pc + 3);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, result) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    return vm_step_continue(pc + 3);
}
