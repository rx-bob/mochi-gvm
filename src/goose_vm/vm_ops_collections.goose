// Opcode handlers for inline Array and Hash access.
namespace vm;

import.builtins;
import.vm_core;

// GETIDX: R[a] = R[a][R[a+1]]
// SETIDX: R[a][R[a+1]] = R[a+2]
fn vm_op_index(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64, op: u8
) -> Step {
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
        let value = builtin_get_index(machine.pool, machine.scratch, container, key);
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

// HASH a,b: build a hash from b key-value pairs starting at R[a]. The first
// pair overwrites the destination register, so save it before writing.
fn vm_op_hash(
    machine: Vm&, frame: CallFrame, record: IrepRecord, iseq: u8[:], pc: i64
) -> Step {
    let ops = vm_read_operands(iseq, pc, 2);
    if !ops.valid {
        return vm_fail(machine, VmError.BadOperand, pc);
    }
    let hash = builtin_hash_new(machine.scratch);
    if ops.b > 0 {
        let first_key, first_key_ok = vm_read_register(machine, record, frame.base, ops.a);
        let first_value, first_value_ok = vm_read_register(machine, record, frame.base, ops.a + 1);
        if !first_key_ok || !first_value_ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        if !builtin_hash_set(machine.pool, machine.scratch, hash, first_key, first_value) {
            return vm_fail(machine, VmError.TypeMismatch, pc + 2);
        }
        var pair = 1;
        while pair < ops.b {
            let offset = ops.a + pair * 2;
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
    }
    if !vm_write_register(machine, record, frame.base, ops.a, hash) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}
