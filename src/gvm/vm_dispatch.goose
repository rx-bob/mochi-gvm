// Branching, constants, array construction, and SEND-family opcode handlers.
namespace vm;

import.builtins;
import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_blocks;
import.vm_constants;
import.vm_core;
import.vm_methods;
import.vm_num;
import.vm_ops_collections;

// Handles the extended opcode set and reports whether `op` belongs here.
fn vm_dispatch_step(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step, bool {
    if op == OP_GETCONST || op == OP_SETCONST || op == OP_GETMCNST {
        return vm_op_const(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_JMP || op == OP_JMPUW {
        return vm_op_jump(machine, iseq, pc), true;
    }
    if op == OP_JMPIF || op == OP_JMPNOT || op == OP_JMPNIL {
        return vm_op_cond_jump(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV
        || op == OP_EQ || op == OP_LT || op == OP_LE || op == OP_GT || op == OP_GE {
        return vm_op_binary(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_ARRAY {
        return vm_op_array(machine, frame, record, iseq, pc), true;
    }
    if op == OP_ARRAY2 || op == OP_ARYPUSH || op == OP_ARYCAT {
        return vm_op_array_ext(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_BLOCK {
        return vm_op_block(machine, frame, record, iseq, pc), true;
    }
    if op == OP_SENDB || op == OP_SSENDB {
        return vm_op_send_block(machine, frame, record, iseq, pc, op), true;
    }
    if op == OP_SEND || op == OP_SEND0 || op == OP_SSEND || op == OP_SSEND0 {
        return vm_op_send(machine, frame, record, iseq, pc, op), true;
    }
    return vm_step_continue(pc), false;
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
    } else if op == OP_JMPNIL {
        take = mrb_is_nil(value);
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
    if num_is_number(machine.scratch, machine.pool, left)
        && num_is_number(machine.scratch, machine.pool, right) {
        return num_equal(machine.scratch, machine.pool, left, right);
    }
    if vm_is_string_value(machine, left) && vm_is_string_value(machine, right) {
        return builtin_string_bytes(machine.pool, machine.scratch, left)
            == builtin_string_bytes(machine.pool, machine.scratch, right);
    }
    return mrb_value_identical(left, right);
}

fn vm_num_error(fault: NumFault) -> VmError {
    return match fault {
        Overflow => VmError.IntegerOverflow,
        DivisionByZero => VmError.DivisionByZero,
        Scratch => VmError.ScratchFull,
        _ => VmError.TypeMismatch,
    };
}

fn vm_op_binary_non_fixnum(
    machine: Vm&, left: MrbValue, right: MrbValue, op: u8
) -> MrbValue, bool {
    if op == OP_ADD && vm_is_string_value(machine, left) && vm_is_string_value(machine, right) {
        return vm_concat_text(machine, left, right), true;
    }
    if op == OP_MUL && vm_is_string_value(machine, left) && mrb_is_fixnum(right) {
        let count = mrb_fixnum_value(right);
        let bytes = builtin_string_bytes(machine.pool, machine.scratch, left);
        var out: u8[>..] = [];
        var i = 0;
        while i < count {
            out.append(bytes);
            i += 1;
        }
        return scratch_alloc_string(machine.scratch, out[..]), true;
    }
    if op == OP_ADD && vm_is_array_value(machine, left) && vm_is_array_value(machine, right) {
        let joined = builtin_array_new(machine.scratch);
        let left_len = builtin_array_length(machine.pool, machine.scratch, left);
        let right_len = builtin_array_length(machine.pool, machine.scratch, right);
        var i = 0;
        while i < left_len {
            builtin_array_push(machine.pool, machine.scratch, joined,
                builtin_array_get(machine.pool, machine.scratch, left, i));
            i += 1;
        }
        i = 0;
        while i < right_len {
            builtin_array_push(machine.pool, machine.scratch, joined,
                builtin_array_get(machine.pool, machine.scratch, right, i));
            i += 1;
        }
        return joined, true;
    }
    return mrb_nil(), false;
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
    if !num_is_number(machine.scratch, machine.pool, left)
        || !num_is_number(machine.scratch, machine.pool, right) {
        if (op == OP_LT || op == OP_LE || op == OP_GT || op == OP_GE)
            && vm_is_string_value(machine, left) && vm_is_string_value(machine, right) {
            let pair: MrbValue[1] = [right];
            let order_value, handled = vm_call_string_builtin(
                machine, left, "<=>", pair[..]
            );
            if !handled || !mrb_is_fixnum(order_value) {
                return vm_fail(machine, VmError.TypeMismatch, pc + 1);
            }
            let order = mrb_fixnum_value(order_value);
            let comparison = if op == OP_LT {
                order < 0
            } else if op == OP_LE {
                order <= 0
            } else if op == OP_GT {
                order > 0
            } else {
                order >= 0
            };
            if !vm_write_register(machine, record, frame.base, ops.a, mrb_bool(comparison)) {
                return vm_fail(machine, VmError.BadOperand, pc + 1);
            }
            return vm_step_continue(pc + 1);
        }
        let non_fix, ok = vm_op_binary_non_fixnum(machine, left, right, op);
        if !ok {
            return vm_fail(machine, VmError.TypeMismatch, pc + 1);
        }
        if !vm_write_register(machine, record, frame.base, ops.a, non_fix) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_continue(pc + 1);
    }
    if op == OP_LT || op == OP_LE || op == OP_GT || op == OP_GE {
        let order, comparable = num_compare(machine.scratch, machine.pool, left, right);
        var comparison = false;
        if comparable {
            if op == OP_LT {
                comparison = order < 0;
            } else if op == OP_LE {
                comparison = order <= 0;
            } else if op == OP_GT {
                comparison = order > 0;
            } else {
                comparison = order >= 0;
            }
        }
        if !vm_write_register(machine, record, frame.base, ops.a, mrb_bool(comparison)) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_continue(pc + 1);
    }
    var result: MrbValue = mrb_nil();
    var fault: NumFault = NumFault.Ok;
    if op == OP_SUB {
        result, fault = num_sub(machine.scratch, machine.pool, left, right);
    } else if op == OP_MUL {
        result, fault = num_mul(machine.scratch, machine.pool, left, right);
    } else if op == OP_DIV {
        result, fault = num_div(machine.scratch, machine.pool, left, right);
    } else {
        result, fault = num_add(machine.scratch, machine.pool, left, right);
    }
    if fault != NumFault.Ok {
        return vm_fail(machine, vm_num_error(fault), pc + 1);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, result) {
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
    let env_frame = machine.frames.len - 1;
    if child < 0
        || !vm_write_register(machine, record, frame.base, ops.a,
        mrb_block_with_env(child, env_frame)) {
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
    var keyword_count = 0;
    if !no_args {
        arg_count = ops.c & 0x0F;
        keyword_count = (ops.c >> 4) & 0x0F;
        var packed_count = arg_count;
        if keyword_count > 0 {
            packed_count += 1;
        }
        if packed_count > MAX_VM_ARGS {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
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
    if keyword_count > 0 {
        let keywords = builtin_hash_new(machine.scratch);
        var key_index = 0;
        while key_index < keyword_count {
            let key, key_ok = vm_read_register(machine, record, frame.base,
                ops.a + 1 + arg_count + key_index * 2);
            let value, value_ok = vm_read_register(machine, record, frame.base,
                ops.a + 1 + arg_count + key_index * 2 + 1);
            if !key_ok || !value_ok {
                return vm_fail(machine, VmError.BadOperand, pc + count);
            }
            if !builtin_hash_set(machine.pool, machine.scratch, keywords, key, value) {
                return vm_fail(machine, VmError.BadOperand, pc + count);
            }
            key_index += 1;
        }
        args.push(keywords);
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
        // Explicit helper calls name their actual receiver. Implicit calls
        // retain the caller context, including asynchronous callback methods.
        let context_class = if mrb_is_class(receiver) && (op == OP_SEND || op == OP_SEND0) {
            mrb_class_id(receiver)
        } else {
            machine.error_context.class_id
        };
        if context_class != NULL_CLASS_ID {
            vm_set_error_context(machine, context_class, symbol, machine.error_context.binding_id);
        }
        machine.error_context.reference_symbol = symbol;
        return vm_fail(machine, VmError.NoMethod, pc + count);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, result) {
        return vm_fail(machine, VmError.BadOperand, pc + count);
    }
    return vm_step_continue(pc + count);
}

fn vm_op_send_block(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    if !ops.valid || ops.c >= 15 {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let symbol, symbol_ok = vm_record_symbol(machine.file, record, ops.b);
    let receiver_val, receiver_ok = vm_read_register(machine, record, frame.base, ops.a);
    let arg_count = ops.c & 0x0F;
    let closure, block_ok = vm_read_register(machine, record, frame.base, ops.a + arg_count + 1);
    if !symbol_ok || !receiver_ok || !block_ok || !mrb_is_block(closure) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    let receiver = if op == OP_SSENDB {
        frame.self_value
    } else {
        receiver_val
    };
    var args: MrbValue[..MAX_VM_ARGS] = [];
    var index = 0;
    while index < arg_count {
        let value, value_ok = vm_read_register(machine, record, frame.base, ops.a + 1 + index);
        if !value_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        args.push(value);
        index += 1;
    }
    let result = vm_dispatch_block_method(machine, receiver, symbol, closure, frame.self_value, args[..]);
    if machine.error != VmError.Ok {
        return vm_step_stop(pc + 3);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, result) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    return vm_step_continue(pc + 3);
}
