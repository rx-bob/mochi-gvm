// Method lookup and intrinsic dispatch for SEND-family opcodes.
namespace vm;

import.builtins;
import.collection_arena;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_ops;

// Reserved class IDs for constants that have no state-pool class definition.
let BUILTIN_ARRAY_CLASS_ID: u32 = 0xFFFFFF01;
let BUILTIN_MOCHI_CLASS_ID: u32 = 0xFFFFFF02;

fn vm_is_array_value(machine: Vm&, value: MrbValue) -> bool {
    if mrb_is_scratch(value) {
        return scratch_is_array(machine.scratch, value);
    }
    return state_is_array(machine.pool, value);
}

fn vm_is_hash_value(machine: Vm&, value: MrbValue) -> bool {
    if mrb_is_scratch(value) {
        return scratch_is_hash(machine.scratch, value);
    }
    return state_is_hash(machine.pool, value);
}

fn vm_is_string_value(machine: Vm&, value: MrbValue) -> bool {
    if mrb_is_scratch(value) {
        return scratch_is_string(machine.scratch, value);
    }
    let object, ok = state_object(machine.pool, value);
    return ok && object.kind == ArenaObjectKind.String;
}

// Calls a user-defined IREP method. Returns `found` separately so the caller
// can fall back to an intrinsic or report a missing method.
fn vm_call_user_method(
    machine: Vm&, frame: CallFrame, receiver: MrbValue, method_symbol: u32, args: MrbValue[:], dst: i64
) -> bool, bool {
    let class_id, is_instance = vm_receiver_class_id(machine, receiver);
    if !is_instance {
        return false, true;
    }
    let irep, found = vm_lookup_method(machine, class_id, method_symbol);
    if !found {
        return false, true;
    }
    vm_exec_with_args(machine, irep, receiver, frame.base + dst, args);
    return true, machine.error == VmError.Ok;
}

fn vm_call_array_builtin(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "<<" || name == "push" {
        if args.len < 1 {
            return mrb_nil(), true;
        }
        if !builtin_array_push(machine.pool, machine.scratch, receiver, args[0]) {
            return mrb_nil(), true;
        }
        return receiver, true;
    }
    if name == "pop" {
        return builtin_array_pop(machine.pool, machine.scratch, receiver), true;
    }
    if name == "last" {
        return builtin_array_last(machine.pool, machine.scratch, receiver), true;
    }
    if name == "empty?" {
        return mrb_bool(builtin_array_empty(machine.pool, machine.scratch, receiver)), true;
    }
    if name == "length" {
        return mrb_fixnum(builtin_array_length(machine.pool, machine.scratch, receiver)), true;
    }
    if name == "join" {
        var separator = mrb_nil();
        if args.len > 0 {
            separator = args[0];
        }
        return builtin_array_join(machine.pool, machine.scratch, receiver, separator), true;
    }
    if name == "[]" {
        if args.len < 1 || !mrb_is_fixnum(args[0]) {
            return mrb_nil(), true;
        }
        return builtin_array_get(machine.pool, machine.scratch, receiver,
            mrb_fixnum_value(args[0])), true;
    }
    if name == "[]=" {
        if args.len < 2 || !mrb_is_fixnum(args[0]) {
            return mrb_nil(), true;
        }
        if !builtin_array_set(machine.pool, machine.scratch, receiver,
            mrb_fixnum_value(args[0]), args[1]) {
            return mrb_nil(), true;
        }
        return args[1], true;
    }
    return mrb_nil(), false;
}

fn vm_call_hash_builtin(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "[]" {
        if args.len < 1 {
            return mrb_nil(), true;
        }
        return builtin_hash_get(machine.pool, machine.scratch, receiver, args[0]), true;
    }
    if name == "[]=" {
        if args.len < 2 {
            return mrb_nil(), true;
        }
        if !builtin_hash_set(machine.pool, machine.scratch, receiver, args[0], args[1]) {
            return mrb_nil(), true;
        }
        return args[1], true;
    }
    if name == "length" {
        return mrb_fixnum(builtin_hash_length(machine.pool, machine.scratch, receiver)), true;
    }
    if name == "empty?" {
        return mrb_bool(builtin_hash_length(machine.pool, machine.scratch, receiver) == 0), true;
    }
    return mrb_nil(), false;
}

fn vm_call_string_builtin(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "length" {
        return mrb_fixnum(builtin_string_length(machine.pool, machine.scratch, receiver)), true;
    }
    if name == "index" {
        if args.len < 1 {
            return mrb_nil(), true;
        }
        var offset = 0;
        if args.len > 1 && mrb_is_fixnum(args[1]) {
            offset = mrb_fixnum_value(args[1]);
        }
        let index, found = builtin_string_index(machine.pool, machine.scratch,
            receiver, args[0], offset);
        if !found {
            return mrb_nil(), true;
        }
        return mrb_fixnum(index), true;
    }
    if name == "[]" {
        if args.len < 2 || !mrb_is_fixnum(args[0]) || !mrb_is_fixnum(args[1]) {
            return mrb_nil(), true;
        }
        return builtin_string_slice(machine.pool, machine.scratch, receiver,
            mrb_fixnum_value(args[0]), mrb_fixnum_value(args[1])), true;
    }
    if name == "empty?" {
        return mrb_bool(builtin_string_length(machine.pool, machine.scratch, receiver) == 0), true;
    }
    return mrb_nil(), false;
}

// Dispatches an intrinsic method. Returns `handled` so the caller can report a
// missing method instead of silently producing nil.
fn vm_call_builtin(
    machine: Vm&, receiver: MrbValue, method_symbol: u32, args: MrbValue[:]
) -> MrbValue, bool {
    let name = symbol_name(method_symbol);
    if name == "!" {
        return builtin_not(receiver), true;
    }
    if mrb_is_class(receiver) {
        let class_id = mrb_class_id(receiver);
        if class_id == BUILTIN_ARRAY_CLASS_ID && name == "new" {
            return builtin_array_new(machine.scratch), true;
        }
        return mrb_nil(), false;
    }
    if vm_is_array_value(machine, receiver) {
        return vm_call_array_builtin(machine, receiver, name, args);
    }
    if vm_is_hash_value(machine, receiver) {
        return vm_call_hash_builtin(machine, receiver, name, args);
    }
    if vm_is_string_value(machine, receiver) {
        return vm_call_string_builtin(machine, receiver, name, args);
    }
    return mrb_nil(), false;
}
