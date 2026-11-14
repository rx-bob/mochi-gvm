// Return, stop, and method-entry opcodes.
namespace vm;

import.rite_types;
import.vm_core;

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
