// C ABI adapter for an embedding host.
//
// The shim in `mrb_abi_shim.c` owns the opaque `mrb_state` and function
// pointers, while this module owns the single VM, its persistent state and the
// tick arena. Every exported function is a small, bounded operation: load one
// component, look up a class or method, or run one host call.
namespace vm;

import.rite_types;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_entry;
import.vm_methods;
import.vm_ops;

let ABI_OBJECT_CLASS_ID: u32 = 0xFFFFFF00;
let ABI_MAX_CALL_ARGS = 8;
let ABI_MAX_BYTECODE = 4194304;

var g_abi_file: RiteFile = RiteFile {
    ..
};
var g_abi_pool: StatePool = StatePool {
    ..
};
var g_abi_scratch: ScratchArena = ScratchArena {
    ..
};
var g_abi_machine: Vm = Vm {
    file: g_abi_file,
    pool: g_abi_pool,
    scratch: g_abi_scratch,
    ..
};
var g_abi_call_args: MrbValue[..ABI_MAX_CALL_ARGS] = [];
// `g_abi_file` keeps a view into this buffer, so loaded bytes are retained
// rather than cleared. The bridge's component set fits well under the cap.
var g_abi_bytecode: u8[>..] = [];
var g_abi_error: bool = false;
var g_abi_error_text: u8[>..] = [];

fn abi_clear_error() {
    g_abi_error = false;
    g_abi_error_text.clear();
}

fn abi_fail(text: u8[:]) {
    g_abi_error = true;
    g_abi_error_text.clear();
    g_abi_error_text.append(text);
}

fn abi_record_vm_error(machine: Vm&) {
    if machine.error != VmError.Ok {
        abi_fail(vm_error_name(machine.error));
    }
}

fn abi_reset() {
    g_abi_file.data = "";
    g_abi_file.records.clear();
    g_abi_file.pools.clear();
    g_abi_file.syms.clear();
    g_abi_file.error = ParseError.Ok;
    g_abi_file.binary_size_bytes = 0;
    g_abi_file.irep_section_offset_bytes = 0;
    g_abi_file.irep_section_size_bytes = 0;

    g_abi_pool.classes.clear();
    g_abi_pool.objects.clear();
    g_abi_pool.ivars.clear();
    g_abi_pool.slots.clear();
    g_abi_pool.components.clear();
    g_abi_pool.blob.clear();

    scratch_reset(g_abi_scratch);
    g_abi_scratch.allocated_objects_total = 0;
    g_abi_scratch.allocated_bytes_total = 0;
    g_abi_scratch.reset_count = 0;

    g_abi_machine.methods.clear();
    g_abi_machine.native_methods.clear();
    g_abi_machine.regs.clear();
    g_abi_machine.frames.clear();
    g_abi_machine.booted = false;
    g_abi_machine.error = VmError.Ok;

    g_abi_call_args.clear();
    abi_clear_error();
}

fn abi_builtin_class_id(name_symbol: u32) -> u32 {
    if name_symbol == intern_symbol("Array") {
        return BUILTIN_ARRAY_CLASS_ID;
    }
    if name_symbol == intern_symbol("Mochi") {
        return BUILTIN_MOCHI_CLASS_ID;
    }
    return NULL_CLASS_ID;
}

fn abi_define_class(name_symbol: u32, superclass_id: u32) -> u32 {
    let builtin = abi_builtin_class_id(name_symbol);
    if builtin != NULL_CLASS_ID {
        return builtin;
    }
    let existing, found = vm_find_class(g_abi_pool, name_symbol);
    if found {
        return existing;
    }
    if state_class_count(g_abi_pool) >= MAX_STATE_CLASSES {
        abi_fail("class capacity exceeded");
        return NULL_CLASS_ID;
    }
    return state_define_class(g_abi_pool, name_symbol, superclass_id);
}

fn abi_open() -> i64 {
    abi_reset();
    return 0;
}

fn abi_close() {
    abi_reset();
}

fn abi_load_irep(bytes: const u8[:]) -> i64 {
    abi_clear_error();
    g_abi_file.data = "";
    let offset = g_abi_bytecode.len;
    if offset + bytes.len > ABI_MAX_BYTECODE {
        abi_fail("bytecode capacity exceeded");
        return 1;
    }
    g_abi_bytecode.append(bytes);
    g_abi_file.data = g_abi_bytecode[offset..];
    let err = vm_load_irep(g_abi_file, g_abi_bytecode[offset..]);
    g_abi_machine.methods.clear();
    g_abi_machine.booted = false;
    g_abi_machine.error = VmError.Ok;
    if err != ParseError.Ok {
        abi_fail(parse_error_name(err));
        return 1;
    }
    return 0;
}

fn abi_last_error() -> const u8[:] {
    return g_abi_error_text[..];
}

fn abi_has_error() -> bool {
    return g_abi_error;
}

fn abi_intern(name: const u8[:]) -> u32 {
    return intern_symbol(name);
}

fn abi_define_module(name_symbol: u32) -> u32 {
    abi_clear_error();
    return abi_define_class(name_symbol, NULL_CLASS_ID);
}

fn abi_define_named_class(
    name_symbol: u32, superclass_id: u32
) -> u32 {
    abi_clear_error();
    var super_id = superclass_id;
    if super_id == ABI_OBJECT_CLASS_ID {
        super_id = NULL_CLASS_ID;
    }
    return abi_define_class(name_symbol, super_id);
}

fn abi_define_native(
    class_id: u32, name_symbol: u32, native_id: u32
) -> i64 {
    abi_clear_error();
    let builtin = class_id >= BUILTIN_ARRAY_CLASS_ID || class_id == ABI_OBJECT_CLASS_ID;
    if !builtin && class_id >= state_class_count(g_abi_pool)as u32 {
        abi_fail("unknown class");
        return -1;
    }
    vm_define_native_method(g_abi_machine, class_id, name_symbol, native_id);
    if g_abi_machine.error != VmError.Ok {
        abi_record_vm_error(g_abi_machine);
        return -1;
    }
    return 0;
}

fn abi_const_get(name_symbol: u32) -> u64 {
    abi_clear_error();
    let builtin = abi_builtin_class_id(name_symbol);
    if builtin != NULL_CLASS_ID {
        return mrb_class(builtin);
    }
    vm_begin_entry(g_abi_machine);
    vm_ensure_booted(g_abi_machine);
    let boot_error = g_abi_machine.error;
    vm_end_entry(g_abi_machine);
    if boot_error != VmError.Ok {
        g_abi_machine.error = boot_error;
        abi_record_vm_error(g_abi_machine);
        return mrb_nil();
    }
    let class_id, found = vm_find_class(g_abi_pool, name_symbol);
    if !found {
        abi_fail("unknown class");
        return mrb_nil();
    }
    return mrb_class(class_id);
}

fn abi_obj_new(class_id: u32) -> u64 {
    abi_clear_error();
    if class_id >= BUILTIN_ARRAY_CLASS_ID || class_id >= state_class_count(g_abi_pool)as u32 {
        abi_fail("unknown class");
        return mrb_nil();
    }
    let name_symbol = state_class_name_symbol(g_abi_pool, class_id);
    let value = vm_instantiate(g_abi_machine, name_symbol);
    abi_record_vm_error(g_abi_machine);
    return value;
}

fn abi_set_arg(index: i64, value: u64) {
    if index >= 0 && index < ABI_MAX_CALL_ARGS {
        while g_abi_call_args.len <= index {
            g_abi_call_args.push(mrb_nil());
        }
        g_abi_call_args[index] = value;
    }
}

fn abi_call(receiver: u64, method_symbol: u32, argc: i64) -> u64 {
    abi_clear_error();
    if argc < 0 || argc > ABI_MAX_CALL_ARGS {
        abi_fail("bad argument count");
        return mrb_nil();
    }
    let result = vm_call_args(g_abi_machine, receiver, method_symbol, g_abi_call_args[..argc]);
    abi_record_vm_error(g_abi_machine);
    return result;
}

fn abi_make_string(bytes: const u8[:]) -> u64 {
    abi_clear_error();
    if state_object_count(g_abi_pool) >= MAX_STATE_OBJECTS
        || state_bytes_used(g_abi_pool) + bytes.len > MAX_STATE_BYTES {
        abi_fail("state string capacity exceeded");
        return mrb_nil();
    }
    return state_alloc_string(g_abi_pool, bytes);
}

fn abi_string_bytes(value: u64) -> const u8[:] {
    if mrb_is_scratch(value) {
        return scratch_string_bytes(g_abi_scratch, value);
    }
    if mrb_is_state(value) {
        return state_string_bytes(g_abi_pool, value);
    }
    return "";
}

fn abi_is_string(value: u64) -> bool {
    return vm_is_string_value(g_abi_machine, value);
}

fn abi_is_class(value: u64) -> bool {
    return mrb_is_class(value);
}

export fn goose_vm_open() -> i64 {
    return abi_open();
}

export fn goose_vm_close() {
    abi_close();
}

export fn goose_vm_load_irep(bytes: const u8[:]) -> i64 {
    return abi_load_irep(bytes);
}

export fn goose_vm_last_error() -> const u8[:] {
    return abi_last_error();
}

export fn goose_vm_has_error() -> bool {
    return abi_has_error();
}

export fn goose_vm_intern(name: const u8[:]) -> u32 {
    return abi_intern(name);
}

export fn goose_vm_define_module(name_symbol: u32) -> u32 {
    return abi_define_module(name_symbol);
}

export fn goose_vm_define_class(name_symbol: u32, superclass_id: u32) -> u32 {
    return abi_define_named_class(name_symbol, superclass_id);
}

export fn goose_vm_define_native(class_id: u32, name_symbol: u32, native_id: u32) -> i64 {
    return abi_define_native(class_id, name_symbol, native_id);
}

export fn goose_vm_const_get(name_symbol: u32) -> u64 {
    return abi_const_get(name_symbol);
}

export fn goose_vm_obj_new(class_id: u32) -> u64 {
    return abi_obj_new(class_id);
}

export fn goose_vm_set_arg(index: i64, value: u64) {
    abi_set_arg(index, value);
}

export fn goose_vm_call(receiver: u64, method_symbol: u32, argc: i64) -> u64 {
    return abi_call(receiver, method_symbol, argc);
}

export fn goose_vm_make_string(bytes: const u8[:]) -> u64 {
    return abi_make_string(bytes);
}

export fn goose_vm_string_bytes(value: u64) -> const u8[:] {
    return abi_string_bytes(value);
}

export fn goose_vm_is_string(value: u64) -> bool {
    return abi_is_string(value);
}

export fn goose_vm_is_class(value: u64) -> bool {
    return abi_is_class(value);
}
