// Qualified constants keep their owner; lexical reads use the defining method.
namespace vm;

import.state_pool;
import.value_arena;
import.vm_core;

fn vm_lexical_owner(machine: Vm&, record_index: i64, self_value: MrbValue, env_frame: i64) -> u32 {
    if env_frame >= 0 && env_frame < machine.frames.len {
        return machine.frames[env_frame].lexical_owner;
    }
    for method in machine.methods {
        if method.irep_index == record_index {
            return method.lexical_owner;
        }
    }
    if mrb_is_class(self_value) {
        return mrb_class_id(self_value);
    }
    return NULL_CLASS_ID;
}

fn vm_qualified_symbol(pool: StatePool&, owner: u32, symbol: u32) -> u32 {
    if owner >= pool.classes.len {
        return symbol;
    }
    var name: u8[>..] = [];
    name.append(symbol_name(pool.classes[owner].name_symbol));
    name.append("::");
    name.append(symbol_name(symbol));
    return intern_symbol(name[..]);
}

fn vm_op_const(
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
    var owner = frame.lexical_owner;
    if op == OP_GETMCNST {
        let target, ok = vm_read_register(machine, record, frame.base, ops.a);
        if !ok || !mrb_is_class(target) {
            return vm_fail(machine, VmError.TypeMismatch, pc + 2);
        }
        owner = mrb_class_id(target);
    }
    if op == OP_SETCONST {
        let value, ok = vm_read_register(machine, record, frame.base, ops.a);
        if !ok {
            return vm_fail(machine, VmError.BadOperand, pc + 2);
        }
        state_set_const(machine.pool, machine.scratch, symbol, value, owner);
        if machine.pool.error != VmError.Ok {
            return vm_fail(machine, machine.pool.error, pc + 2);
        }
        return vm_step_continue(pc + 2);
    }
    var value, found = state_get_const(machine.pool, symbol, owner);
    if !found && op == OP_GETCONST {
        value, found = state_get_const(machine.pool, symbol);
        if !found {
            let name = symbol_name(symbol);
            let class_id, class_found = vm_find_class(machine.pool, symbol);
            if name == "Mochi" {
                value = mrb_class(BUILTIN_MOCHI_CLASS_ID);
                found = true;
            } else if class_found {
                value = mrb_class(class_id);
                found = true;
            }
        }
    }
    if !found {
        machine.error_context.reference_symbol = vm_qualified_symbol(machine.pool, owner, symbol);
        let error = if op == OP_GETMCNST {
            VmError.NoConstant
        } else {
            VmError.NoClass
        };
        return vm_fail(machine, error, pc + 2);
    }
    if !vm_write_register(machine, record, frame.base, ops.a, value) {
        return vm_fail(machine, VmError.BadOperand, pc + 2);
    }
    return vm_step_continue(pc + 2);
}
