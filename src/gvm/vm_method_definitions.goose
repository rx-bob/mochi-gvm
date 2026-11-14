// Decoding and execution of mruby's fused and fallback method definitions.
namespace vm;

import.rite_types;
import.state_pool;
import.value_arena;
import.vm_core;

struct DefinitionInstruction {
    frame_index: i64,
    record: IrepRecord,
    iseq: const u8[:],
    pc: i64,
    op: u8,
}

struct DefinitionOperands {
    a: i64,
    b: i64,
    next_pc: i64,
}

fn vm_definition_step(machine: Vm&, instruction: DefinitionInstruction) -> Step, bool {
    let is_extended = instruction.op == OP_EXT1 || instruction.op == OP_EXT2 || instruction.op == OP_EXT3;
    let is_direct = instruction.op == OP_TCLASS || instruction.op == OP_METHOD || instruction.op == OP_DEF;
    if !is_extended && !is_direct {
        return vm_step_continue(instruction.pc), false;
    }
    let frame = machine.frames[instruction.frame_index];
    if is_extended {
        return vm_extended_definition(machine, instruction, frame), true;
    }
    let operands, valid = vm_definition_operands(instruction);
    if !valid {
        return vm_fail(machine, VmError.BadOperand, instruction.pc), true;
    }
    return vm_execute_definition(machine, instruction, frame, operands), true;
}

fn vm_definition_operands(instruction: DefinitionInstruction) -> DefinitionOperands, bool {
    let count = if instruction.op == OP_TCLASS {
        1
    } else {
        2
    };
    if instruction.op != OP_TCLASS && instruction.op != OP_METHOD && instruction.op != OP_DEF {
        return DefinitionOperands {
            ..
        }, false;
    }
    if !vm_operands_available(instruction.iseq, instruction.pc, count) {
        return DefinitionOperands {
            ..
        }, false;
    }
    let a = instruction.iseq[instruction.pc]as i64;
    let b = if count == 2 {
        instruction.iseq[instruction.pc + 1]as i64
    } else {
        0
    };
    return DefinitionOperands {
        a: a,
        b: b,
        next_pc: instruction.pc + count
    }, true;
}

fn vm_execute_definition(
    machine: Vm&, instruction: DefinitionInstruction, frame: CallFrame, operands: DefinitionOperands
) -> Step {
    if instruction.op == OP_TCLASS {
        return vm_tclass_register(machine, instruction, frame, operands);
    }
    if instruction.op == OP_METHOD {
        return vm_method_register(machine, instruction, frame, operands);
    }
    return vm_def_register(machine, instruction, frame, operands);
}

fn vm_extended_definition(machine: Vm&, instruction: DefinitionInstruction, frame: CallFrame) -> Step {
    if instruction.pc >= instruction.iseq.len {
        return vm_fail(machine, VmError.BadOperand, instruction.pc);
    }
    let op = instruction.iseq[instruction.pc];
    if op != OP_TCLASS && op != OP_METHOD && op != OP_DEF {
        return vm_fail(machine, VmError.BadOpcode, instruction.pc + 1);
    }
    let extension = instruction.op;
    let width_a = extension == OP_EXT1 || extension == OP_EXT3;
    let width_b = extension == OP_EXT2 || extension == OP_EXT3;
    let a_bytes = if width_a {
        2
    } else {
        1
    };
    let count = if op == OP_TCLASS {
        1
    } else {
        2
    };
    let b_bytes = if count == 2 && width_b {
        2
    } else if count == 2 {
        1
    } else {
        0
    };
    let args_at = instruction.pc + 1;
    if args_at + a_bytes + b_bytes > instruction.iseq.len {
        return vm_fail(machine, VmError.BadOperand, args_at);
    }
    let a = vm_read_extended_byte(instruction.iseq, args_at, width_a);
    let b_at = args_at + a_bytes;
    let b = if count == 2 {
        vm_read_extended_byte(instruction.iseq, b_at, width_b)
    } else {
        0
    };
    let operands = DefinitionOperands {
        a: a,
        b: b,
        next_pc: args_at + a_bytes + b_bytes
    };
    let decoded = DefinitionInstruction {
        frame_index: instruction.frame_index,
        record: instruction.record,
        iseq: instruction.iseq,
        pc: instruction.pc,
        op: op,
    };
    return vm_execute_definition(machine, decoded, frame, operands);
}

fn vm_read_extended_byte(iseq: u8[:], at: i64, wide: bool) -> i64 {
    if wide {
        let high: i64 = iseq[at];
        return high * 256 + iseq[at + 1];
    }
    return iseq[at];
}

fn vm_tclass_register(
    machine: Vm&, instruction: DefinitionInstruction, frame: CallFrame, operands: DefinitionOperands
) -> Step {
    if !mrb_is_class(frame.self_value) {
        return vm_fail(machine, VmError.TypeMismatch, operands.next_pc);
    }
    if !vm_write_register(machine, instruction.record, frame.base, operands.a, frame.self_value) {
        return vm_fail(machine, VmError.BadOperand, operands.next_pc);
    }
    return vm_step_continue(operands.next_pc);
}

fn vm_method_register(
    machine: Vm&, instruction: DefinitionInstruction, frame: CallFrame, operands: DefinitionOperands
) -> Step {
    let target_register = operands.a - 1;
    let target, target_ok = vm_read_register(machine, instruction.record, frame.base, target_register);
    let child = vm_child_record(machine.file, frame.record_index, operands.b);
    if !target_ok || !mrb_is_class(target) || child < 0 || operands.a >= instruction.record.nregs {
        return vm_fail(machine, VmError.BadOperand, operands.next_pc);
    }
    machine.frames[instruction.frame_index].pending_method_irep = child;
    machine.frames[instruction.frame_index].pending_method_register = operands.a;
    return vm_step_continue(operands.next_pc);
}

fn vm_def_register(
    machine: Vm&, instruction: DefinitionInstruction, frame: CallFrame, operands: DefinitionOperands
) -> Step {
    let symbol, symbol_ok = vm_record_symbol(machine.file, instruction.record, operands.b);
    let target, target_ok = vm_read_register(machine, instruction.record, frame.base, operands.a);
    if !symbol_ok || !target_ok || !mrb_is_class(target)
        || frame.pending_method_irep < 0
        || frame.pending_method_register != operands.a + 1 {
        return vm_fail(machine, VmError.BadOperand, operands.next_pc);
    }
    vm_define_method(machine, mrb_class_id(target), symbol,
        frame.pending_method_irep, frame.lexical_owner);
    if machine.error != VmError.Ok {
        return vm_fail(machine, machine.error, operands.next_pc);
    }
    if !vm_write_register(machine, instruction.record, frame.base, operands.a, mrb_symbol(symbol)) {
        return vm_fail(machine, VmError.BadOperand, operands.next_pc);
    }
    machine.frames[instruction.frame_index].pending_method_irep = -1;
    machine.frames[instruction.frame_index].pending_method_register = -1;
    return vm_step_continue(operands.next_pc);
}
