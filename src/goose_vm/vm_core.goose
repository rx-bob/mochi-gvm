// Shared state and helpers for the scalar RITE register VM.
//
// The VM keeps its public surface here: the bounded `Vm` owner, the frame and
// step records used by the dispatch loop, the RITE loader, the tick boundary,
// and the register, symbol, class and string helpers. The instruction handlers
// and the interpreter loop live in `vm_ops.goose` so both files stay within the
// style guide's file and function length limits.
namespace vm;

import.rite_parser;
import.rite_types;
import.state_pool;
import.value_arena;

let MAX_VM_REGS = 512;
let MAX_VM_CALL_DEPTH = 32;
let MAX_VM_METHODS = 256;

// Opcode bytes from mruby 4.0 `include/mruby/ops.h`. Only the subset emitted by
// the scalar component slice is decoded; anything else stops the VM with
// `VmError.BadOpcode` instead of guessing at an instruction width.
let OP_NOP: u8 = 0;
let OP_MOVE: u8 = 1;
let OP_LOADI8: u8 = 3;
let OP_LOADINEG: u8 = 4;
let OP_LOADI_NEG1: u8 = 5;
let OP_LOADI_0: u8 = 6;
let OP_LOADI_7: u8 = 13;
let OP_LOADSYM: u8 = 16;
let OP_LOADNIL: u8 = 17;
let OP_LOADSELF: u8 = 18;
let OP_LOADTRUE: u8 = 19;
let OP_LOADFALSE: u8 = 20;
let OP_GETIV: u8 = 25;
let OP_SETIV: u8 = 26;
let OP_GETIDX: u8 = 35;
let OP_SETIDX: u8 = 37;
let OP_ENTER: u8 = 57;
let OP_RETURN: u8 = 61;
let OP_RETNIL: u8 = 64;
let OP_ADDI: u8 = 70;
let OP_SUBI: u8 = 72;
let OP_STRING: u8 = 92;
let OP_STRCAT: u8 = 93;
let OP_HASH: u8 = 94;
let OP_CLASS: u8 = 103;
let OP_EXEC: u8 = 105;
let OP_TDEF: u8 = 107;
let OP_STOP: u8 = 118;

// A VM rejection reason. Bytecode from an untrusted component must never abort
// the process, so dispatch records the first problem here and stops the frame.
enum VmError {
    Ok,
    BadOpcode,
    BadOperand,
    BadReceiver,
    NoClass,
    NoMethod,
    TypeMismatch,
    Registers,
    CallDepth,
}

// What the interpreter loop should do after one decoded instruction.
enum StepKind {
    Continue,
    Return,
    Stop,
    Execute,
}

// One method definition binding a class ID to a child IREP.
struct MethodEntry {
    class_id: u32,
    name_symbol: u32,
    irep_index: i64,
}

// One active call frame. `base` is the first register of the window, and `pc`
// is the byte offset of the next instruction inside the frame's IREP.
struct CallFrame {
    record_index: i64,
    base: i64,
    self_value: MrbValue,
    pc: i64,
}

// The result of one instruction. `Execute` asks the loop to recurse into a child
// IREP with `value` as self and `dst_register` as the caller's result slot.
struct Step {
    pc: i64,
    kind: StepKind,
    value: MrbValue,
    child_index: i64,
    dst_register: i64,
}

// Operands decoded as unsigned bytes. `valid` is false when the instruction
// stream ended before all requested bytes, which is a malformed frame.
struct Operands {
    a: i64,
    b: i64,
    c: i64,
    valid: bool,
}

// The VM owns the mutable dispatch state while the caller owns the three
// storage roots. The register window and frame stack are inline and bounded.
root struct Vm {
    file: RiteFile&,
    pool: StatePool&,
    scratch: ScratchArena&,
    methods: MethodEntry[>..] = [],
    regs: MrbValue[..MAX_VM_REGS] = [],
    frames: CallFrame[..MAX_VM_CALL_DEPTH] = [],
    booted: bool = false,
    error: VmError = VmError.Ok,
}

fn vm_error_name(err: VmError) -> u8[:] {
    return match err {
        Ok => "ok",
        BadOpcode => "bad opcode",
        BadOperand => "bad operand",
        BadReceiver => "bad receiver",
        NoClass => "unknown class",
        NoMethod => "unknown method",
        TypeMismatch => "type mismatch",
        Registers => "register overflow",
        CallDepth => "call depth exceeded",
    };
}

fn vm_step_continue(pc: i64) -> Step {
    return Step {
        pc: pc,
        kind: StepKind.Continue,
        value: mrb_nil(),
        child_index: -1,
        dst_register: -1,
    };
}

fn vm_step_return(pc: i64, value: MrbValue) -> Step {
    return Step {
        pc: pc,
        kind: StepKind.Return,
        value: value,
        child_index: -1,
        dst_register: -1,
    };
}

fn vm_step_stop(pc: i64) -> Step {
    return Step {
        pc: pc,
        kind: StepKind.Stop,
        value: mrb_nil(),
        child_index: -1,
        dst_register: -1,
    };
}

fn vm_step_execute(pc: i64, child_index: i64, target: MrbValue, dst_register: i64) -> Step {
    return Step {
        pc: pc,
        kind: StepKind.Execute,
        value: target,
        child_index: child_index,
        dst_register: dst_register,
    };
}

// Records `err` and stops the current frame without aborting the process.
fn vm_fail(machine: Vm&, err: VmError, pc: i64) -> Step {
    machine.error = err;
    return vm_step_stop(pc);
}

// Restores the 10-byte prefix that `poc_yiseq/build.sh` strips from `mrbc`
// output: `RITE0400` plus the two leading zero bytes of the u32 binary size.
fn vm_restore_rite_header(stripped: u8[:], out: u8[>..]&) {
    out.append("RITE0400");
    out.push(0);
    out.push(0);
    out.append(stripped);
}

// Parses a complete RITE buffer into `file`. The bytes must outlive the file
// because `RiteFile.data` views them. Call this before constructing a `Vm`:
// the VM borrows the file, and loading shrinks its record and pool arrays.
fn vm_load_irep(file: RiteFile&, bytes: u8[:]) -> ParseError {
    return parse_rite(bytes, file);
}

// Starts a top-level entry from a clean tick arena. A previous entry's scratch
// result is dead once the host has read it, so the arena rewinds here.
fn vm_begin_entry(machine: Vm&) {
    machine.error = VmError.Ok;
    machine.regs.clear();
    machine.frames.clear();
    scratch_reset(machine.scratch);
}

// Ends a top-level entry and returns the tick arena to zero bytes.
fn vm_end_entry(machine: Vm&) {
    machine.regs.clear();
    machine.frames.clear();
    scratch_reset(machine.scratch);
}

// Returns the bytes of a string value, or an empty view for any other kind.
fn vm_string_value(machine: Vm&, value: MrbValue) -> const u8[:] {
    if mrb_is_scratch(value) {
        return scratch_string_bytes(machine.scratch, value);
    }
    if mrb_is_state(value) {
        return state_string_bytes(machine.pool, value);
    }
    return "";
}

fn vm_string_equals(machine: Vm&, value: MrbValue, expected: u8[:]) -> bool {
    return vm_string_value(machine, value) == expected;
}

// Appends the text form of `value`, matching Ruby's `to_s` for the scalar kinds
// this slice can produce. Integers render without arena allocation.
fn vm_append_value_text(machine: Vm&, out: u8[>..]&, value: MrbValue) {
    if mrb_is_scratch(value) {
        out.append(scratch_string_bytes(machine.scratch, value));
        return;
    }
    if mrb_is_state(value) {
        out.append(state_string_bytes(machine.pool, value));
        return;
    }
    if mrb_is_fixnum(value) {
        mrb_format_fixnum(out, mrb_fixnum_value(value));
        return;
    }
    if mrb_is_true(value) {
        out.append("true");
        return;
    }
    if mrb_is_false(value) {
        out.append("false");
    }
}

// Concatenates a string with a string or integer, allocating the result in the
// tick arena. This is the `OP_STRCAT` operation behind `#{@count}`.
fn vm_concat_text(machine: Vm&, left: MrbValue, right: MrbValue) -> MrbValue {
    var joined: u8[>..] = [];
    vm_append_value_text(machine, joined, left);
    vm_append_value_text(machine, joined, right);
    return scratch_alloc_string(machine.scratch, joined[..]);
}

// Finds a class definition by its interned name symbol.
fn vm_find_class(pool: StatePool&, name_symbol: u32) -> u32, bool {
    for index in 0..pool.classes.len {
        if pool.classes[index].name_symbol == name_symbol {
            return index as u32, true;
        }
    }
    return NULL_CLASS_ID, false;
}

// Binds `name_symbol` to `irep_index` on `class_id`, replacing a redefinition.
fn vm_define_method(machine: Vm&, class_id: u32, name_symbol: u32, irep_index: i64) {
    for index in 0..machine.methods.len {
        if machine.methods[index].class_id == class_id
            && machine.methods[index].name_symbol == name_symbol {
            machine.methods[index].irep_index = irep_index;
            return;
        }
    }
    if machine.methods.len >= MAX_VM_METHODS {
        machine.error = VmError.NoMethod;
        return;
    }
    machine.methods.push(MethodEntry {
            class_id: class_id,
            name_symbol: name_symbol,
            irep_index: irep_index,
        });
}

// Resolves a method through the class and its superclass chain.
fn vm_lookup_method(machine: Vm&, class_id: u32, name_symbol: u32) -> i64, bool {
    var current = class_id;
    var steps = 0;
    while current != NULL_CLASS_ID && steps < MAX_STATE_CLASSES {
        for index in 0..machine.methods.len {
            let entry = machine.methods[index];
            if entry.class_id == current && entry.name_symbol == name_symbol {
                return entry.irep_index, true;
            }
        }
        current = state_class_superclass_id(machine.pool, current);
        steps += 1;
    }
    return -1, false;
}

fn vm_receiver_class_id(machine: Vm&, receiver: MrbValue) -> u32, bool {
    let object, ok = state_object(machine.pool, receiver);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return NULL_CLASS_ID, false;
    }
    return object.class_index, true;
}

// Returns the child IREP at `ordinal` in the operand-local child list.
fn vm_child_record(file: RiteFile&, parent_index: i64, ordinal: i64) -> i64 {
    if parent_index < 0 || parent_index >= file.records.len || ordinal < 0 {
        return -1;
    }
    var index = file.records[parent_index].first_child_index;
    var at = 0;
    while index >= 0 && index < file.records.len {
        if at == ordinal {
            return index;
        }
        index = file.records[index].next_sibling_index;
        at += 1;
    }
    return -1;
}

fn vm_record_symbol(file: RiteFile&, record: IrepRecord, local_index: i64) -> u32, bool {
    if local_index < 0 || local_index >= record.syms_count {
        return NULL_SYMBOL, false;
    }
    let index = record.syms_first_index + local_index;
    if index < 0 || index >= file.syms.len {
        return NULL_SYMBOL, false;
    }
    return file.syms[index].index, true;
}

fn vm_record_pool_text(file: RiteFile&, record: IrepRecord, local_index: i64) -> const u8[:], bool {
    if local_index < 0 || local_index >= record.pool_count {
        return "", false;
    }
    let index = record.pool_first_index + local_index;
    if index < 0 || index >= file.pools.len {
        return "", false;
    }
    return pool_text(file, file.pools[index]), true;
}

fn vm_read_register(machine: Vm&, record: IrepRecord, base: i64, a: i64) -> MrbValue, bool {
    if a < 0 || a >= record.nregs {
        return mrb_nil(), false;
    }
    return machine.regs[base + a], true;
}

fn vm_write_register(machine: Vm&, record: IrepRecord, base: i64, a: i64, value: MrbValue) -> bool {
    if a < 0 || a >= record.nregs {
        return false;
    }
    machine.regs[base + a] = value;
    return true;
}

fn vm_operands_available(iseq: u8[:], pc: i64, count: i64) -> bool {
    return count >= 0 && pc >= 0 && pc + count <= iseq.len;
}

// Decodes up to three unsigned operand bytes, reporting a short instruction.
fn vm_read_operands(iseq: u8[:], pc: i64, count: i64) -> Operands {
    var operands = Operands {
        a: 0,
        b: 0,
        c: 0,
        valid: false,
    };
    if !vm_operands_available(iseq, pc, count) {
        return operands;
    }
    operands.valid = true;
    if count > 0 {
        operands.a = iseq[pc];
    }
    if count > 1 {
        operands.b = iseq[pc + 1];
    }
    if count > 2 {
        operands.c = iseq[pc + 2];
    }
    return operands;
}
