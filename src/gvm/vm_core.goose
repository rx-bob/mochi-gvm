// Shared state and helpers for the scalar RITE register VM.
namespace vm;

import.rite_parser;
import.rite_pool;
import.rite_types;
import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_errors;
import.vm_num;

let MAX_VM_REGS = 1024;
let MAX_VM_CALL_DEPTH = 64;
let MAX_VM_METHODS = 4096;
let MAX_VM_ARGS = 8;

// Opcode bytes from mruby 4.0 `include/mruby/ops.h`.
let OP_NOP: u8 = 0;
let OP_MOVE: u8 = 1;
let OP_LOADL: u8 = 2;
let OP_LOADI8: u8 = 3;
let OP_LOADINEG: u8 = 4;
let OP_LOADI_NEG1: u8 = 5;
let OP_LOADI_0: u8 = 6;
let OP_LOADI_7: u8 = 13;
let OP_LOADI16: u8 = 14;
let OP_LOADI32: u8 = 15;
let OP_LOADSYM: u8 = 16;
let OP_LOADNIL: u8 = 17;
let OP_LOADSELF: u8 = 18;
let OP_LOADTRUE: u8 = 19;
let OP_LOADFALSE: u8 = 20;
let OP_GETIV: u8 = 25;
let OP_SETIV: u8 = 26;
let OP_GETCONST: u8 = 29;
let OP_SETCONST: u8 = 30;
let OP_GETUPVAR: u8 = 33;
let OP_SETUPVAR: u8 = 34;
let OP_GETIDX: u8 = 35;
let OP_GETIDX0: u8 = 36;
let OP_SETIDX: u8 = 37;
let OP_JMP: u8 = 38;
let OP_JMPIF: u8 = 39;
let OP_JMPNOT: u8 = 40;
let OP_JMPNIL: u8 = 41;
let OP_JMPUW: u8 = 42;
let OP_SSEND: u8 = 47;
let OP_SSEND0: u8 = 48;
let OP_SSENDB: u8 = 49;
let OP_SEND: u8 = 50;
let OP_SEND0: u8 = 51;
let OP_SENDB: u8 = 52;
let OP_ENTER: u8 = 57;
let OP_RETURN: u8 = 61;
let OP_RETURN_BLK: u8 = 62;
let OP_RETSELF: u8 = 63;
let OP_RETNIL: u8 = 64;
let OP_RETTRUE: u8 = 65;
let OP_RETFALSE: u8 = 66;
let OP_BREAK: u8 = 67;
let OP_ADD: u8 = 69;
let OP_ADDI: u8 = 70;
let OP_SUB: u8 = 71;
let OP_SUBI: u8 = 72;
let OP_ADDILV: u8 = 73;
let OP_SUBILV: u8 = 74;
let OP_MUL: u8 = 75;
let OP_DIV: u8 = 76;
let OP_EQ: u8 = 77;
let OP_LT: u8 = 78;
let OP_LE: u8 = 79;
let OP_GT: u8 = 80;
let OP_GE: u8 = 81;
let OP_ARRAY: u8 = 82;
let OP_ARRAY2: u8 = 83;
let OP_ARYCAT: u8 = 84;
let OP_ARYPUSH: u8 = 85;
let OP_AREF: u8 = 87;
let OP_SYMBOL: u8 = 91;
let OP_STRING: u8 = 92;
let OP_STRCAT: u8 = 93;
let OP_HASH: u8 = 94;
let OP_HASHADD: u8 = 95;
let OP_HASHCAT: u8 = 96;
let OP_BLOCK: u8 = 98;
let OP_CLASS: u8 = 103;
let OP_MODULE: u8 = 104;
let OP_EXEC: u8 = 105;
let OP_TDEF: u8 = 107;
let OP_SDEF: u8 = 108;
let OP_STOP: u8 = 118;

enum StepKind {
    Continue,
    Return,
    Stop,
    Execute,
}

struct MethodEntry {
    class_id: u32,
    name_symbol: u32,
    irep_index: i64,
}

struct NativeMethod {
    class_id: u32,
    name_symbol: u32,
    native_id: u32,
}

struct CallFrame {
    record_index: i64,
    base: i64,
    self_value: MrbValue,
    pc: i64,
    env_frame: i64 = -1,
    argc: i64 = 0,
}

struct Step {
    pc: i64,
    kind: StepKind,
    value: MrbValue,
    child_index: i64,
    dst_register: i64,
}

struct Operands {
    a: i64,
    b: i64,
    c: i64,
    valid: bool,
}

root struct Vm {
    file: RiteFile&,
    pool: StatePool&,
    scratch: ScratchArena&,
    methods: MethodEntry[>..] = [],
    native_methods: NativeMethod[>..] = [],
    regs: MrbValue[..MAX_VM_REGS] = [],
    frames: CallFrame[..MAX_VM_CALL_DEPTH] = [],
    // Arguments are durable roots while the VM boots class bodies, before they
    // are copied into a callee's register window.
    entry_args: MrbValue[>..] = [],
    // Helper-owned tick values held outside a register window (block
    // accumulators such as `map` results) are roots for scratch reclamation.
    scratch_roots: MrbValue[>..] = [],
    booted_roots: i64 = 0,
    error: VmError = VmError.Ok,
    error_context: ErrorContext = ErrorContext {
        class_id: NULL_CLASS_ID,
        method_symbol: NULL_SYMBOL,
        binding_id: -1,
    },
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
    if err == VmError.StateCapacity || err == VmError.IvarCapacity {
        vm_absorb_state_failure(machine, -1);
    }
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

// Appends one complete RITE buffer to an already loaded file. Record, pool and
// symbol indices stay absolute, so earlier programs remain executable.
fn vm_append_irep(file: RiteFile&, bytes: u8[:], byte_offset: i64) -> ParseError {
    return parse_rite_append(bytes, file, byte_offset);
}

// Starts a top-level entry from a clean tick arena. A previous entry's scratch
// result is dead once the host has read it, so the arena rewinds here.
fn vm_begin_entry(machine: Vm&) {
    machine.error = VmError.Ok;
    vm_set_error_context(machine, NULL_CLASS_ID, NULL_SYMBOL, -1);
    vm_clear_entry_capacity_failure(machine);
    machine.pool.error = VmError.Ok;
    machine.regs.clear();
    machine.frames.clear();
    machine.entry_args.clear();
    machine.scratch_roots.clear();
    scratch_reset(machine.scratch);
}

// Ends a top-level entry and returns the tick arena to zero bytes.
fn vm_end_entry(machine: Vm&) {
    machine.regs.clear();
    machine.frames.clear();
    machine.entry_args.clear();
    machine.scratch_roots.clear();
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
    if mrb_is_fixnum(value) {
        mrb_format_fixnum(out, mrb_fixnum_value(value));
        return;
    }
    if mrb_is_int64(value) {
        let number, ok = num_integer_value(machine.scratch, machine.pool, value);
        if ok {
            mrb_format_fixnum(out, number);
        }
        return;
    }
    if mrb_is_float(value) {
        let number, ok = num_float_value(machine.scratch, machine.pool, value);
        if ok {
            num_format_float(out, number);
        }
        return;
    }
    if mrb_is_scratch(value) {
        out.append(scratch_string_bytes(machine.scratch, value));
        return;
    }
    if mrb_is_state(value) {
        out.append(state_string_bytes(machine.pool, value));
        return;
    }
    if mrb_is_symbol(value) {
        out.append(symbol_name(mrb_symbol_id(value)));
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
    while current != NULL_CLASS_ID
        && current < state_class_count(machine.pool)as u32
        && steps < MAX_STATE_CLASSES {
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

// A native module function such as `Mochi.fetch` is sent to a class value,
// while component methods are sent to state instances.
fn vm_owner_class_id(machine: Vm&, receiver: MrbValue) -> u32, bool {
    if mrb_is_class(receiver) {
        return mrb_class_id(receiver), true;
    }
    return vm_receiver_class_id(machine, receiver);
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

fn vm_record_pool_entry(file: RiteFile&, record: IrepRecord, local_index: i64) -> PoolEntry, bool {
    if local_index < 0 || local_index >= record.pool_count {
        return empty_pool_entry(), false;
    }
    let index = record.pool_first_index + local_index;
    if index < 0 || index >= file.pools.len {
        return empty_pool_entry(), false;
    }
    return file.pools[index], true;
}

fn vm_record_pool_text(file: RiteFile&, record: IrepRecord, local_index: i64) -> const u8[:], bool {
    let entry, ok = vm_record_pool_entry(file, record, local_index);
    if !ok {
        return "", false;
    }
    return pool_text(file, entry), true;
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

// Returns the required positional arity declared by a leading ENTER instruction.
// `has_enter` is false for root and class-body IREPs, which take no arguments.
fn vm_required_args(iseq: u8[:]) -> i64, bool {
    if iseq.len == 0 || iseq[0] != OP_ENTER {
        return 0, false;
    }
    let ops = vm_read_operands(iseq, 1, 3);
    if !ops.valid {
        return 0, false;
    }
    let aspec = (ops.a << 16) | (ops.b << 8) | ops.c;
    return (aspec >> 18) & 0x1f, true;
}

// Rejects a call whose positional argument count disagrees with a leading ENTER.
fn vm_entry_arity_ok(machine: Vm&, iseq: u8[:], args: MrbValue[:]) -> bool {
    if iseq.len == 0 || iseq[0] != OP_ENTER {
        return true;
    }
    let ops = vm_read_operands(iseq, 1, 3);
    if !ops.valid {
        return false;
    }
    let aspec = (ops.a << 16) | (ops.b << 8) | ops.c;
    let required = (aspec >> 18) & 0x1f;
    let optional = (aspec >> 13) & 0x1f;
    if args.len < required || args.len > required + optional {
        machine.error = VmError.WrongArity;
        return false;
    }
    return true;
}

// Decodes the signed big-endian 16-bit jump displacement at `pc`.
fn vm_read_signed16(iseq: u8[:], pc: i64) -> i64, bool {
    if !vm_operands_available(iseq, pc, 2) {
        return 0, false;
    }
    let raw = ((iseq[pc]as u16) << 8) | iseq[pc + 1];
    let value: i64 = raw;
    if value >= 32768 {
        return value - 65536, true;
    }
    return value, true;
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
