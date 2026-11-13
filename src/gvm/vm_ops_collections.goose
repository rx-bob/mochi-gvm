// Opcode handlers for literals, strings, upvars, and Array/Hash operations.
namespace vm;

import.array_slice;
import.builtins;
import.collection_arena;
import.rite_types;
import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_num;

fn vm_bigint_literal(file: RiteFile&, entry: PoolEntry) -> i64, bool {
    let start = entry.text_offset_bytes;
    let stop = start + entry.text_length_bytes;
    if start < 0 || stop > file.data.len || stop - start < 3 {
        return 0, false;
    }
    let blob = file.data[start..stop];
    let digits = blob[0]as i64;
    if blob.len != digits + 2 {
        return 0, false;
    }
    let signed_base = blob[1]as!i8;
    var base = signed_base as i64;
    let negative = base < 0;
    if negative {
        base = -base;
    }
    return num_parse_i64_bytes(blob[2..2 + digits], base, negative);
}

fn vm_op_load_literal(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_LOADI16 {
        let ops = vm_read_operands(iseq, pc, 1);
        let value, ok = vm_read_signed16(iseq, pc + 1);
        if !ops.valid || !ok {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        if !vm_write_register(machine, record, frame.base, ops.a, mrb_fixnum(value)) {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        return vm_step_continue(pc + 3);
    }
    if op == OP_LOADI32 {
        if !vm_operands_available(iseq, pc, 5) {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let a = iseq[pc]as i64;
        let b0 = iseq[pc + 1]as u32;
        let b1 = iseq[pc + 2]as u32;
        let b2 = iseq[pc + 3]as u32;
        let b3 = iseq[pc + 4]as u32;
        let raw_u32: u32 = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
        var value = raw_u32 as i64;
        if value >= 2147483648 {
            value -= 4294967296;
        }
        if !vm_write_register(machine, record, frame.base, a, mrb_fixnum(value)) {
            return vm_fail(machine, VmError.BadOperand, pc + 5);
        }
        return vm_step_continue(pc + 5);
    }
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let entry, entry_ok = vm_record_pool_entry(machine.file, record, ops.b);
    if !entry_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    var value = mrb_nil();
    if entry.tag == 1 || entry.tag == 3 {
        value = num_from_i64(machine.scratch, entry.int_value);
    } else if entry.tag == 5 {
        value = num_from_f64(machine.scratch, entry.float_value);
    } else if entry.tag == 7 {
        let number, number_ok = vm_bigint_literal(machine.file, entry);
        if !number_ok {
            return vm_fail(machine, VmError.IntegerOverflow, pc + 2);
        }
        value = num_from_i64(machine.scratch, number);
    } else {
        return vm_fail(machine, VmError.TypeMismatch, pc + 2);
    }
    if mrb_is_nil(value) {
        return vm_fail(machine, VmError.ScratchFull, pc + 2);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, value) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}

fn vm_op_string(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_STRING || op == OP_SYMBOL {
        let ops = vm_read_operands(iseq, pc, 2);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let text, text_ok = vm_record_pool_text(machine.file, record, ops.b);
        if !text_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        let result = if op == OP_SYMBOL {
            mrb_symbol(intern_symbol(text))
        } else {
            scratch_alloc_string(machine.scratch, text)
        };
        if !vm_write_register(machine, record, frame.base, ops.a, result) {
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

fn vm_op_upvar(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    let ops = vm_read_operands(iseq, pc, 3);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    var target_frame = frame.env_frame;
    var depth = ops.c;
    while depth > 0 && target_frame >= 0 && target_frame < machine.frames.len {
        target_frame = machine.frames[target_frame].env_frame;
        depth -= 1;
    }
    if target_frame < 0 || target_frame >= machine.frames.len {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    let env = machine.frames[target_frame];
    if env.record_index < 0 || env.record_index >= machine.file.records.len {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    let env_record = machine.file.records[env.record_index];
    if op == OP_GETUPVAR {
        let value, ok = vm_read_register(machine, env_record, env.base, ops.b);
        if !ok || !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        return vm_step_continue(pc + 3);
    }
    let value, ok = vm_read_register(machine, record, frame.base, ops.a);
    if !ok || !vm_write_register(machine, env_record, env.base, ops.b, value) {
        return vm_fail(machine, VmError.BadOperand, pc + 3);
    }
    return vm_step_continue(pc + 3);
}

// GETIDX, GETIDX0, SETIDX, AREF
fn vm_op_index(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_GETIDX0 {
        let ops = vm_read_operands(iseq, pc, 2);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let container, ok = vm_read_register(machine, record, frame.base, ops.b);
        if !ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        let value = builtin_get_index(machine.pool, machine.scratch, container, mrb_fixnum(0));
        if !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    if op == OP_AREF {
        let ops = vm_read_operands(iseq, pc, 3);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let src, ok = vm_read_register(machine, record, frame.base, ops.b);
        if !ok {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        var value = mrb_nil();
        if scratch_is_array(machine.scratch, src) || state_is_array(machine.pool, src) {
            value = builtin_array_get(machine.pool, machine.scratch, src, ops.c);
        } else if ops.c == 0 {
            value = src;
        }
        if !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        return vm_step_continue(pc + 3);
    }
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let container, container_ok = vm_read_register(machine, record, frame.base, ops.a);
    let key, key_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !container_ok || !key_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    if op == OP_GETIDX {
        var value = mrb_nil();
        if scratch_is_array(machine.scratch, container) || state_is_array(machine.pool, container) {
            let args: MrbValue[1] = [key];
            value = builtin_array_index(machine, container, args[..]);
            if machine.error != VmError.Ok {
                return vm_fail(machine, machine.error, pc + 1);
            }
        } else {
            value = builtin_get_index(machine.pool, machine.scratch, container, key);
        }
        if !vm_write_register(machine, record, frame.base, ops.a, value) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
        return vm_step_continue(pc + 1);
    }
    let value, value_ok = vm_read_register(machine, record, frame.base, ops.a + 2);
    if !value_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    if !builtin_set_index(machine.pool, machine.scratch, container, key, value) {
        return vm_fail(machine, VmError.TypeMismatch, pc + 1);
    }
    return vm_step_continue(pc + 1);
}

fn vm_op_array_ext(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_ARRAY2 {
        let ops = vm_read_operands(iseq, pc, 3);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let array = builtin_array_new(machine.scratch);
        var index = 0;
        while index < ops.c {
            let value, ok = vm_read_register(machine, record, frame.base, ops.b + index);
            if !ok || !builtin_array_push(machine.pool, machine.scratch, array, value) {
                return vm_fail(machine, VmError.BadOperand, pc + 3);
            }
            index += 1;
        }
        if !vm_write_register(machine, record, frame.base, ops.a, array) {
            return vm_fail(machine, VmError.BadOperand, pc + 3);
        }
        return vm_step_continue(pc + 3);
    }
    if op == OP_ARYPUSH {
        let ops = vm_read_operands(iseq, pc, 2);
        if !ops.valid {
            return vm_fail(machine, VmError.BadOperand, pc);
        }
        let array, ok = vm_read_register(machine, record, frame.base, ops.a);
        if !ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        var index = 0;
        while index < ops.b {
            let item, item_ok = vm_read_register(machine, record, frame.base, ops.a + 1 + index);
            if !item_ok || !builtin_array_push(machine.pool, machine.scratch, array, item) {
                return vm_fail(machine, VmError.BadOperand, pc + 2);
            }
            index += 1;
        }
        return vm_step_continue(pc + 2);
    }
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    var dst, dst_ok = vm_read_register(machine, record, frame.base, ops.a);
    let src, src_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !dst_ok || !src_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    if mrb_is_nil(dst) {
        dst = builtin_array_new(machine.scratch);
        if !vm_write_register(machine, record, frame.base, ops.a, dst) {
            return vm_fail(machine, VmError.BadOperand, pc + 1);
        }
    }
    let len = builtin_array_length(machine.pool, machine.scratch, src);
    var idx = 0;
    while idx < len {
        let item = builtin_array_get(machine.pool, machine.scratch, src, idx);
        if !builtin_array_push(machine.pool, machine.scratch, dst, item) {
            return vm_fail(machine, VmError.TypeMismatch, pc + 1);
        }
        idx += 1;
    }
    return vm_step_continue(pc + 1);
}

fn vm_op_hashcat(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 1);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let dst, dst_ok = vm_read_register(machine, record, frame.base, ops.a);
    let src, src_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
    if !dst_ok || !src_ok {
        return vm_fail(machine, VmError.BadOperand, pc + 1);
    }
    if mrb_is_scratch(src) {
        let obj, ok = scratch_object(machine.scratch, src);
        if ok && obj.kind == ArenaObjectKind.Hash {
            var slot = obj.items_first_index;
            while slot >= 0 {
                let s = machine.scratch.slots[slot];
                builtin_hash_set(machine.pool, machine.scratch, dst, s.key, s.value);
                slot = s.next_index;
            }
        }
    } else if mrb_is_state(src) {
        let obj, ok = state_object(machine.pool, src);
        if ok && obj.kind == ArenaObjectKind.Hash {
            var slot = obj.items_first_index;
            while slot >= 0 {
                let s = machine.pool.slots[slot];
                builtin_hash_set(machine.pool, machine.scratch, dst, s.key, s.value);
                slot = s.next_index;
            }
        }
    }
    return vm_step_continue(pc + 1);
}

// HASH, HASHADD, HASHCAT
fn vm_op_hash(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
    if op == OP_HASHCAT {
        return vm_op_hashcat(machine, frame, record, iseq, pc);
    }
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    var hash = mrb_nil();
    var start_offset = ops.a;
    if op == OP_HASHADD {
        let existing, ok = vm_read_register(machine, record, frame.base, ops.a);
        if !ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        hash = existing;
        start_offset = ops.a + 1;
    } else {
        hash = builtin_hash_new(machine.scratch);
    }
    var pair = 0;
    while pair < ops.b {
        let offset = start_offset + pair * 2;
        let key, key_ok = vm_read_register(machine, record, frame.base, offset);
        let value, value_ok = vm_read_register(machine, record, frame.base, offset + 1);
        if !key_ok || !value_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        if !builtin_hash_set(machine.pool, machine.scratch, hash, key, value) {
            return vm_fail(machine, VmError.TypeMismatch, pc + 2);
        }
        pair += 1;
    }
    if op == OP_HASH && !vm_write_register(machine, record, frame.base, ops.a, hash) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}
