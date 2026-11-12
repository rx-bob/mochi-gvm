// C ABI adapter for an embedding host.
//
// The shim in `mrb_abi_shim.c` owns the opaque `mrb_state` and function
// pointers, while this module owns the single VM, its persistent state and the
// tick arena. Every exported function is a small, bounded operation: load one
// component, look up a class or method, or run one host call.
namespace vm;

import.builtins;
import.host_api;
import.ivar_mask;
import.json_args;
import.rite_types;
import.scratch_alloc;
import.signals;
import.state_pool;
import.state_reclaim;
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
// Set by a native host adapter before it returns NATIVE_FAIL. It makes a
// native failure actionable instead of only reporting "native method failed".
var g_abi_host_error: u8[>..] = [];
var g_abi_patch_bytes: u8[>..] = [];
var g_abi_json: u8[>..] = [];
var g_abi_fetch_json: u8[>..] = [];

fn abi_clear_error() {
    g_abi_error = false;
    g_abi_error_text.clear();
    g_abi_host_error.clear();
}

fn abi_fail(text: u8[:]) {
    g_abi_error = true;
    g_abi_error_text.clear();
    g_abi_error_text.append(text);
}

// Appends the class, method and binding named by the VM's error context, when
// the context refers to a real component class.
fn abi_format_error_context() -> u8[>..] {
    var text: u8[>..] = [];
    let class_id = g_abi_machine.error_context.class_id;
    if class_id < state_class_count(g_abi_pool)as u32 {
        text.append(symbol_name(state_class_name_symbol(g_abi_pool, class_id)));
        if g_abi_machine.error_context.method_symbol != NULL_SYMBOL {
            text.append("#");
            text.append(symbol_name(g_abi_machine.error_context.method_symbol));
        }
        if g_abi_machine.error_context.binding_id >= 0 {
            text.append(" (binding ");
            mrb_format_fixnum(text, g_abi_machine.error_context.binding_id);
            text.append(")");
        }
        text.append(": ");
    }
    if g_abi_machine.error_context.scratch_resource != ScratchResource.None {
        text.append("scratch ");
        text.append(scratch_resource_name(g_abi_machine.error_context.scratch_resource));
        text.append(" exhausted (requested ");
        mrb_format_fixnum(text, g_abi_machine.error_context.scratch_requested);
        text.append(", used ");
        mrb_format_fixnum(text, g_abi_machine.error_context.scratch_used);
        text.append(" of ");
        mrb_format_fixnum(text, g_abi_machine.error_context.scratch_capacity);
        text.append(")");
        return text;
    }
    text.append(vm_error_name(g_abi_machine.error));
    if g_abi_machine.error == VmError.NativeError && g_abi_host_error.len > 0 {
        text.append(": ");
        text.append(g_abi_host_error[..]);
    }
    return text;
}

fn abi_record_vm_error(machine: Vm&) {
    if machine.error != VmError.Ok {
        abi_fail(abi_format_error_context());
    }
}

// The innermost executing method already claimed the context while unwinding.
// Only fall back to the ABI entry point when that did not happen, so an
// `initialize` failure is not relabelled as the `mounted` handler that called
// into it.
fn abi_record_call_context(receiver: u64, method_symbol: u32) {
    if g_abi_machine.error_context.class_id != NULL_CLASS_ID {
        return;
    }
    let class_id, is_instance = vm_owner_class_id(g_abi_machine, receiver);
    if is_instance {
        vm_set_error_context(g_abi_machine, class_id, method_symbol, -1);
    }
}

fn abi_reset() {
    g_abi_file.data = "";
    g_abi_file.records.clear();
    g_abi_file.pools.clear();
    g_abi_file.syms.clear();
    g_abi_file.roots.clear();
    g_abi_file.error = ParseError.Ok;
    g_abi_file.binary_size_bytes = 0;
    g_abi_file.irep_section_offset_bytes = 0;
    g_abi_file.irep_section_size_bytes = 0;

    g_abi_pool.classes.clear();
    g_abi_pool.consts.clear();
    g_abi_pool.objects.clear();
    g_abi_pool.ivars.clear();
    g_abi_pool.slots.clear();
    g_abi_pool.components.clear();
    g_abi_pool.bindings.clear();
    g_abi_pool.blob.clear();
    g_abi_pool.free_objects.clear();
    g_abi_pool.free_ivars.clear();
    g_abi_pool.free_slots.clear();
    g_abi_pool.free_bytes.clear();
    g_abi_pool.marks.clear();
    g_abi_pool.mark_epoch = 0;
    g_abi_pool.mark_stack.clear();
    g_abi_pool.allocations_since_collect = 0;
    g_abi_pool.active_read_mask = mask_clear();
    g_abi_pool.tracking_instance_index = -1;
    g_abi_pool.tracking_instance_generation = 0;
    g_abi_pool.error = VmError.Ok;

    scratch_reset(g_abi_scratch);
    g_abi_scratch.allocated_objects_total = 0;
    g_abi_scratch.allocated_bytes_total = 0;
    g_abi_scratch.reset_count = 0;

    g_abi_machine.methods.clear();
    g_abi_machine.native_methods.clear();
    g_abi_machine.regs.clear();
    g_abi_machine.frames.clear();
    g_abi_machine.entry_args.clear();
    g_abi_machine.scratch_roots.clear();
    g_abi_machine.booted_roots = 0;
    g_abi_machine.error = VmError.Ok;
    vm_set_error_context(g_abi_machine, NULL_CLASS_ID, NULL_SYMBOL, -1);

    g_abi_call_args.clear();
    g_abi_patch_bytes.clear();
    g_abi_json.clear();
    g_abi_fetch_json.clear();
    host_reset();
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
    g_abi_file.data = g_abi_bytecode[..];
    let err = vm_append_irep(g_abi_file, g_abi_bytecode[..], offset);
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
    // Interning allocates only in the symbol table. It must not inherit the
    // previous entry's error, or the bridge's `has_method` check would skip a
    // real `mounted` callback because of an unrelated earlier failure.
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
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

// Mounts a component after resolving its declared props. The JSON object is
// parsed and installed before `initialize`, then a fresh copy is restored
// after it so initialization cannot overwrite a parent-supplied input.
fn abi_obj_new_with_props(class_id: u32, props_json: const u8[:]) -> u64 {
    abi_clear_error();
    if class_id >= BUILTIN_ARRAY_CLASS_ID || class_id >= state_class_count(g_abi_pool)as u32 {
        abi_fail("unknown class");
        return mrb_nil();
    }
    let name_symbol = state_class_name_symbol(g_abi_pool, class_id);
    let value = vm_instantiate_with_props(g_abi_machine, name_symbol, props_json);
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
    g_abi_machine.error = VmError.Ok;
    if argc < 0 || argc > ABI_MAX_CALL_ARGS {
        abi_fail("bad argument count");
        return mrb_nil();
    }
    let result = vm_call_args(g_abi_machine, receiver, method_symbol, g_abi_call_args[..argc]);
    abi_record_call_context(receiver, method_symbol);
    abi_record_vm_error(g_abi_machine);
    return result;
}

// Returns the required positional arity declared by the target method's leading
// OP_ENTER. A missing method or a native method has no IREP, so both report -1.
fn abi_method_req_argc(receiver: u64, method_symbol: u32) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    let class_id, is_instance = vm_owner_class_id(g_abi_machine, receiver);
    if !is_instance {
        return -1;
    }
    let irep, found = vm_lookup_method(g_abi_machine, class_id, method_symbol);
    if !found || irep < 0 || irep >= g_abi_file.records.len {
        return -1;
    }
    let iseq = record_iseq(g_abi_file, g_abi_file.records[irep]);
    let required, has_enter = vm_required_args(iseq);
    if !has_enter {
        return 0;
    }
    return required;
}

// Decodes a JSON argument array into tick-arena values and invokes the method
// without resetting the arena between decoding and dispatch.
fn abi_call_json(receiver: u64, method_symbol: u32, json: const u8[:]) -> u64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    vm_begin_entry(g_abi_machine);
    var args: MrbValue[>..] = [];
    if !json_parse_args(g_abi_pool, g_abi_scratch, json, args) {
        abi_fail("bad JSON argument list");
        vm_end_entry(g_abi_machine);
        return mrb_nil();
    }
    let result = vm_call_args_prepared(g_abi_machine, receiver, method_symbol, args[..]);
    abi_record_call_context(receiver, method_symbol);
    abi_record_vm_error(g_abi_machine);
    return result;
}

// Checks whether a receiver implements a method without invoking it. The host
// uses this to route document-level actions to only the components that opt in.
fn abi_has_method(receiver: u64, method_symbol: u32) -> bool {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    if state_instance_disposed(g_abi_pool, receiver) {
        return false;
    }
    let class_id, is_instance = vm_owner_class_id(g_abi_machine, receiver);
    if !is_instance {
        return false;
    }
    let _, found = vm_lookup_method(g_abi_machine, class_id, method_symbol);
    if found {
        return true;
    }
    let _, native_found = vm_lookup_native_method(g_abi_machine, class_id, method_symbol);
    return native_found;
}

fn abi_register_binding(instance: u64, binding_id: u32, getter_symbol: u32) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    if state_instance_disposed(g_abi_pool, instance) {
        abi_fail("disposed instance");
        return -1;
    }
    let result = binding_register(g_abi_pool, instance, binding_id, getter_symbol);
    if result != 0 {
        let class_id, is_instance = vm_owner_class_id(g_abi_machine, instance);
        if is_instance {
            vm_set_error_context(g_abi_machine, class_id, NULL_SYMBOL, binding_id);
        }
        g_abi_machine.error = VmError.StateCapacity;
        abi_record_vm_error(g_abi_machine);
    }
    return result;
}

// Removes one instance's bindings and component root. Class and IREP records
// stay loaded because other instances and later mounts still use them.
fn abi_unregister_component(instance: u64) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    if !vm_dispose_instance(g_abi_machine, instance) {
        abi_fail("bad component instance");
        return 1;
    }
    return 0;
}

fn abi_binding_count() -> i64 {
    return g_abi_pool.bindings.len;
}

fn abi_component_count() -> i64 {
    return g_abi_pool.components.len;
}

// Test/debug inspection of reclamation. These counts are not telemetry: the
// loader reads them only from `debugStats` in lifetime tests.
fn abi_state_object_count() -> i64 {
    return state_object_count(g_abi_pool);
}

fn abi_state_allocated_count() -> i64 {
    return state_allocated_object_count(g_abi_pool);
}

fn abi_state_free_bytes() -> i64 {
    return state_free_byte_count(g_abi_pool);
}

// Flushes the instance's dirty bindings into the module patch buffer. The buffer
// is rebuilt for every call so the host always reads a complete patch frame.
fn abi_flush_patches(instance: u64) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    vm_set_error_context(g_abi_machine, NULL_CLASS_ID, NULL_SYMBOL, -1);
    g_abi_patch_bytes.clear();
    let count = vm_flush_dirty_bindings(g_abi_machine, instance, g_abi_patch_bytes);
    abi_record_vm_error(g_abi_machine);
    return count;
}

fn abi_patch_bytes() -> const u8[:] {
    return g_abi_patch_bytes[..];
}

// Creates a state string for the host. It is durable while reachable from a
// component, constant, active frame or binding registration. A host that keeps
// a raw handle across entries must store it in a component (the loader does this
// for props) rather than rely on the handle alone.
fn abi_make_string(bytes: const u8[:]) -> u64 {
    abi_clear_error();
    if !state_has_object_capacity(g_abi_pool)
        || !state_has_byte_capacity(g_abi_pool, bytes.len) {
        abi_fail("state string capacity exceeded");
        return mrb_nil();
    }
    return state_alloc_string(g_abi_pool, bytes);
}

// Temporary strings for native calls live in the tick arena. They survive only
// until the next entry, which is enough for one fetch request to be serialized.
fn abi_make_scratch_string(bytes: const u8[:]) -> u64 {
    return scratch_alloc_string(g_abi_scratch, bytes);
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

fn abi_is_hash(value: u64) -> bool {
    return vm_is_hash_value(g_abi_machine, value);
}

// Resolves a Hash key by symbol id. `builtin_hash_get` keeps Symbol and String
// keys indifferent, so `:target` and `"target"` hit the same payload entry.
fn abi_hash_get_symbol(hash: u64, key_symbol: u32) -> u64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    if !vm_is_hash_value(g_abi_machine, hash) {
        abi_fail("bad Hash payload");
        return mrb_nil();
    }
    return builtin_hash_get(g_abi_pool, g_abi_scratch, hash, mrb_symbol(key_symbol));
}

// Serializes one value for the host. The returned view points at a module-owned
// buffer and stays valid until the next `abi_value_json` call.
fn abi_value_json(value: u64) -> const u8[:] {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    g_abi_json.clear();
    binding_json_append_value(g_abi_machine, g_abi_json, value, 0);
    return g_abi_json[..];
}

// Returns the receiver of the current VM frame. Native module calls use this
// to resolve the component that invoked `Mochi.fetch`.
fn abi_current_self() -> u64 {
    if g_abi_machine.frames.len == 0 {
        return 0;
    }
    return g_abi_machine.frames[g_abi_machine.frames.len - 1].self_value;
}

fn abi_fetch_callback_ok(callback: u64) -> bool {
    return mrb_is_symbol(callback) || vm_is_string_value(g_abi_machine, callback);
}

// Builds one fetch request line. `instance` is a String for both the automatic
// component handle and the legacy component-id argument.
fn abi_fetch_request_json(
    fetch_id: i64, instance: u64, url: u64, callback: u64, options: u64
) -> const u8[:] {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    g_abi_fetch_json.clear();
    if !vm_is_string_value(g_abi_machine, instance)
        || !vm_is_string_value(g_abi_machine, url)
        || !abi_fetch_callback_ok(callback)
        || (!mrb_is_nil(options) && !vm_is_hash_value(g_abi_machine, options)) {
        abi_fail("bad fetch request");
        return "";
    }
    g_abi_fetch_json.append("{\"id\":");
    mrb_format_fixnum(g_abi_fetch_json, fetch_id);
    g_abi_fetch_json.append(",\"instance\":");
    binding_json_append_value(g_abi_machine, g_abi_fetch_json, instance, 0);
    g_abi_fetch_json.append(",\"url\":");
    binding_json_append_value(g_abi_machine, g_abi_fetch_json, url, 0);
    g_abi_fetch_json.append(",\"callback\":");
    binding_json_append_key(g_abi_machine, g_abi_fetch_json, callback);
    g_abi_fetch_json.append(",\"options\":");
    if mrb_is_nil(options) {
        g_abi_fetch_json.append("{}");
    } else {
        binding_json_append_value(g_abi_machine, g_abi_fetch_json, options, 0);
    }
    g_abi_fetch_json.append("}\n");
    return g_abi_fetch_json[..];
}

// Parses the loader's response envelope and fills in the stable response keys.
fn abi_fetch_response(envelope: const u8[:]) -> u64 {
    let value, parsed = json_parse_document(g_abi_pool, g_abi_scratch, envelope);
    if !parsed || !vm_is_hash_value(g_abi_machine, value) {
        abi_fail("bad fetch response");
        return mrb_nil();
    }
    let status_key = mrb_symbol(intern_symbol("status"));
    let ok_key = mrb_symbol(intern_symbol("ok"));
    let body_key = mrb_symbol(intern_symbol("body"));
    let data_key = mrb_symbol(intern_symbol("data"));
    let error_key = mrb_symbol(intern_symbol("error"));
    if mrb_is_nil(builtin_hash_get(g_abi_pool, g_abi_scratch, value, status_key)) {
        builtin_hash_set(g_abi_pool, g_abi_scratch, value, status_key, mrb_fixnum(0));
    }
    if mrb_is_nil(builtin_hash_get(g_abi_pool, g_abi_scratch, value, ok_key)) {
        builtin_hash_set(g_abi_pool, g_abi_scratch, value, ok_key, mrb_false());
    }
    if mrb_is_nil(builtin_hash_get(g_abi_pool, g_abi_scratch, value, body_key)) {
        builtin_hash_set(g_abi_pool, g_abi_scratch, value, body_key,
            scratch_alloc_string(g_abi_scratch, ""));
    }
    if mrb_is_nil(builtin_hash_get(g_abi_pool, g_abi_scratch, value, data_key)) {
        builtin_hash_set(g_abi_pool, g_abi_scratch, value, data_key, mrb_nil());
    }
    if mrb_is_nil(builtin_hash_get(g_abi_pool, g_abi_scratch, value, error_key)) {
        builtin_hash_set(g_abi_pool, g_abi_scratch, value, error_key, mrb_nil());
    }
    return value;
}

fn abi_deliver_fetch(instance: u64, callback_symbol: u32, envelope: const u8[:]) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    vm_begin_entry(g_abi_machine);
    let response = abi_fetch_response(envelope);
    if g_abi_machine.error != VmError.Ok || abi_has_error() {
        vm_end_entry(g_abi_machine);
        return -1;
    }
    let args: MrbValue[1] = [response];
    vm_call_args_prepared(g_abi_machine, instance, callback_symbol, args[..]);
    abi_record_call_context(instance, callback_symbol);
    abi_record_vm_error(g_abi_machine);
    if g_abi_machine.error != VmError.Ok {
        return -1;
    }
    return 0;
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

export fn goose_vm_set_host_error(text: const u8[:]) {
    g_abi_host_error.clear();
    g_abi_host_error.append(text);
}

export fn goose_vm_clear_host_error() {
    g_abi_host_error.clear();
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

export fn goose_vm_obj_new_with_props(class_id: u32, props_json: const u8[:]) -> u64 {
    return abi_obj_new_with_props(class_id, props_json);
}

export fn goose_vm_set_arg(index: i64, value: u64) {
    abi_set_arg(index, value);
}

export fn goose_vm_call(receiver: u64, method_symbol: u32, argc: i64) -> u64 {
    return abi_call(receiver, method_symbol, argc);
}

export fn goose_vm_has_method(receiver: u64, method_symbol: u32) -> bool {
    return abi_has_method(receiver, method_symbol);
}

export fn goose_vm_method_req_argc(receiver: u64, method_symbol: u32) -> i64 {
    return abi_method_req_argc(receiver, method_symbol);
}

export fn goose_vm_dispatch_event_args(receiver: u64, method_symbol: u32, json: const u8[:]) -> u64 {
    return abi_call_json(receiver, method_symbol, json);
}

export fn goose_vm_register_binding(instance: u64, binding_id: u32, getter_symbol: u32) -> i64 {
    return abi_register_binding(instance, binding_id, getter_symbol);
}

export fn goose_vm_unregister_component(instance: u64) -> i64 {
    return abi_unregister_component(instance);
}

export fn goose_vm_binding_count() -> i64 {
    return abi_binding_count();
}

export fn goose_vm_component_count() -> i64 {
    return abi_component_count();
}

export fn goose_vm_state_object_count() -> i64 {
    return abi_state_object_count();
}

export fn goose_vm_state_allocated_count() -> i64 {
    return abi_state_allocated_count();
}

export fn goose_vm_state_free_bytes() -> i64 {
    return abi_state_free_bytes();
}

export fn goose_vm_flush_patches(instance: u64) -> i64 {
    return abi_flush_patches(instance);
}

export fn goose_vm_patch_bytes() -> const u8[:] {
    return abi_patch_bytes();
}

export fn goose_vm_make_string(bytes: const u8[:]) -> u64 {
    return abi_make_string(bytes);
}

export fn goose_vm_make_scratch_string(bytes: const u8[:]) -> u64 {
    return abi_make_scratch_string(bytes);
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

export fn goose_vm_is_hash(value: u64) -> bool {
    return abi_is_hash(value);
}

export fn goose_vm_hash_get_symbol(hash: u64, key_symbol: u32) -> u64 {
    return abi_hash_get_symbol(hash, key_symbol);
}

export fn goose_vm_value_json(value: u64) -> const u8[:] {
    return abi_value_json(value);
}

export fn goose_vm_current_self() -> u64 {
    return abi_current_self();
}

export fn goose_vm_fetch_request_json(
    fetch_id: i64, instance: u64, url: u64, callback: u64, options: u64
) -> const u8[:] {
    return abi_fetch_request_json(fetch_id, instance, url, callback, options);
}

export fn goose_vm_deliver_fetch(
    instance: u64, callback_symbol: u32, envelope: const u8[:]
) -> i64 {
    return abi_deliver_fetch(instance, callback_symbol, envelope);
}

// Collects only when no VM frame or entry argument is live. Host mutations run
// quiescent in normal use; a reentrant native callback skips reclamation rather
// than collecting over an in-flight expression.
fn abi_reclaim_quiescent() {
    if g_abi_machine.frames.len == 0 && g_abi_machine.regs.len == 0
        && g_abi_machine.entry_args.len == 0 {
        gc_maybe_collect(g_abi_machine);
    }
}

// Host attribute -> component prop setter. `0` means success and `-1` means
// failure; the host reads the message through `goose_vm_last_error`. Writing a
// value identical to the stored one is still success and marks no dirty bit,
// so a host that echoes the current attribute cannot create an update loop.
export fn goose_vm_set_ivar_string(
    instance: u64, name: const u8[:], value: const u8[:]
) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    g_abi_pool.error = VmError.Ok;
    if state_instance_disposed(g_abi_pool, instance) {
        abi_fail("disposed instance");
        return -1;
    }
    if name.len == 0 {
        abi_fail("empty ivar name");
        return -1;
    }
    var ivar_name: u8[>..] = [];
    if name[0] != 64 {
        ivar_name.push(64);
    }
    ivar_name.append(name);
    let sym = intern_symbol(ivar_name[..]);
    let str_val = abi_make_string(value);
    if abi_has_error() {
        return -1;
    }
    if !state_set_ivar(g_abi_pool, g_abi_scratch, instance, sym, str_val) {
        if g_abi_pool.error == VmError.IvarCapacity {
            abi_fail("ivar capacity exceeded");
        } else if g_abi_pool.error == VmError.StateCapacity {
            abi_fail("state capacity exceeded");
        } else {
            abi_fail("unknown component instance");
        }
        return -1;
    }
    // String replacement is a host mutation; the stored value is rooted by the
    // component, and quiescent reclamation can return the previous bytes.
    abi_reclaim_quiescent();
    return 0;
}

// Host typed-prop update. The JSON object may contain any subset of the
// component's declared props. All values are installed by one call to the
// generated `__mochi_apply_props` before the host flushes patches, which keeps
// related inputs consistent for observers.
export fn goose_vm_set_props_json(instance: u64, json: const u8[:]) -> i64 {
    abi_clear_error();
    g_abi_machine.error = VmError.Ok;
    g_abi_pool.error = VmError.Ok;
    if state_instance_disposed(g_abi_pool, instance) {
        abi_fail("disposed instance");
        return -1;
    }
    vm_begin_entry(g_abi_machine);
    let props, parsed = json_parse_document(g_abi_pool, g_abi_scratch, json);
    if !parsed || !vm_is_hash_value(g_abi_machine, props) {
        abi_fail("bad props payload");
        vm_end_entry(g_abi_machine);
        return -1;
    }
    if !vm_apply_component_props(g_abi_machine, instance, props, false) {
        abi_record_vm_error(g_abi_machine);
        vm_end_entry(g_abi_machine);
        return -1;
    }
    vm_end_entry(g_abi_machine);
    // Replacing a prop snapshot is a host mutation. Running reclaim here lets
    // repeated parent updates return the previous array/hash before the next
    // allocation needs the space.
    abi_reclaim_quiescent();
    return 0;
}

export fn goose_vm_eval_each_expr(
    receiver: u64, method_symbol: u32, json: const u8[:]
) -> const u8[:] {
    let result = abi_call_json(receiver, method_symbol, json);
    g_abi_json.clear();
    if !abi_has_error() && g_abi_machine.error == VmError.Ok {
        vm_append_value_text(g_abi_machine, g_abi_json, result);
    }
    vm_end_entry(g_abi_machine);
    return g_abi_json[..];
}
