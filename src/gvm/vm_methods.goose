// Method lookup and intrinsic dispatch for SEND-family opcodes.
namespace vm;

import.builtins;
import.builtins_ext;
import.collection_arena;
import.host_api;
import.scratch_alloc;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_dispatch;
import.vm_num;
import.vm_ops;

// Reserved class IDs for constants that have no state-pool class definition.
let BUILTIN_MOCHI_CLASS_ID: u32 = 0xFFFFFF02;
let NATIVE_FAIL: u64 = 0xFFFFFFFFFFFFFFFF;

extern fn goose_abi_native_set_arg(index: i64, value: u64);

extern fn goose_abi_native_call(native_id: u32, self_value: u64, argc: i64) -> u64;

fn vm_define_native_method(machine: Vm&, class_id: u32, name_symbol: u32, native_id: u32) {
    for index in 0..machine.native_methods.len {
        if machine.native_methods[index].class_id == class_id
            && machine.native_methods[index].name_symbol == name_symbol {
            machine.native_methods[index].native_id = native_id;
            return;
        }
    }
    if machine.native_methods.len >= MAX_VM_METHODS {
        machine.error = VmError.NoMethod;
        return;
    }
    machine.native_methods.push(NativeMethod {
            class_id: class_id,
            name_symbol: name_symbol,
            native_id: native_id,
        });
}

fn vm_lookup_native_method(machine: Vm&, class_id: u32, name_symbol: u32) -> u32, bool {
    for entry in machine.native_methods {
        if entry.class_id == class_id && entry.name_symbol == name_symbol {
            return entry.native_id, true;
        }
    }
    return 0, false;
}

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
    let class_id, is_instance = vm_owner_class_id(machine, receiver);
    if !is_instance {
        return false, true;
    }
    let irep, found = vm_lookup_method(machine, class_id, method_symbol);
    if found {
        vm_exec_with_args(machine, irep, receiver, frame.base + dst, args);
        return true, machine.error == VmError.Ok;
    }
    let native_id, native_found = vm_lookup_native_method(machine, class_id, method_symbol);
    if !native_found {
        return false, true;
    }
    for index in 0..args.len {
        goose_abi_native_set_arg(index, args[index]);
    }
    let result = goose_abi_native_call(native_id, receiver, args.len);
    if result == NATIVE_FAIL {
        machine.error = VmError.NativeError;
        return true, false;
    }
    let record = machine.file.records[frame.record_index];
    if !vm_write_register(machine, record, frame.base, dst, result) {
        machine.error = VmError.Registers;
        return true, false;
    }
    return true, true;
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
    return builtin_array_ext(machine, receiver, name, args);
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
    return builtin_hash_ext(machine, receiver, name, args);
}

fn vm_call_string_builtin(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "<=>" || name == "<" || name == "<=" || name == ">" || name == ">=" {
        if args.len != 1 || !vm_is_string_value(machine, args[0]) {
            machine.error = VmError.TypeMismatch;
            return mrb_nil(), true;
        }
        let left = builtin_string_bytes(machine.pool, machine.scratch, receiver);
        let right = builtin_string_bytes(machine.pool, machine.scratch, args[0]);
        var order = 0;
        var index = 0;
        while index < left.len && index < right.len {
            if left[index] < right[index] {
                order = -1;
                break;
            }
            if left[index] > right[index] {
                order = 1;
                break;
            }
            index += 1;
        }
        if order == 0 {
            if left.len < right.len {
                order = -1;
            } else if left.len > right.len {
                order = 1;
            }
        }
        if name == "<=>" {
            return mrb_fixnum(order), true;
        }
        let comparison = if name == "<" {
            order < 0
        } else if name == "<=" {
            order <= 0
        } else if name == ">" {
            order > 0
        } else {
            order >= 0
        };
        return mrb_bool(comparison), true;
    }
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
    return builtin_string_ext(machine, receiver, name, args);
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
    if name == "==" && args.len >= 1 {
        return mrb_bool(vm_values_equal(machine, receiver, args[0])), true;
    }
    if name == "!=" && args.len >= 1 {
        return mrb_bool(!vm_values_equal(machine, receiver, args[0])), true;
    }
    if name == "nil?" {
        return mrb_bool(mrb_is_nil(receiver)), true;
    }
    if name == "to_s" {
        return builtin_to_s(machine, receiver), true;
    }
    if name == "to_i" {
        return builtin_to_i(machine, receiver), true;
    }
    if num_is_number(machine.scratch, machine.pool, receiver) {
        return builtin_number_method(machine, receiver, name, args);
    }
    if mrb_is_class(receiver) {
        let class_id = mrb_class_id(receiver);
        if class_id == BUILTIN_ARRAY_CLASS_ID && name == "new" {
            return builtin_array_new(machine.scratch), true;
        }
        if class_id == BUILTIN_MOCHI_CLASS_ID {
            return vm_call_mochi_builtin(machine, name, args);
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
