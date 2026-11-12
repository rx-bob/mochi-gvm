// Diagnostic context and error codes for VM failures.
namespace vm;

import.scratch_alloc;
import.value_arena;
import.vm_core;

enum VmError {
    Ok,
    BadOpcode,
    BadOperand,
    BadReceiver,
    NoClass,
    NoMethod,
    TypeMismatch,
    WrongArity,
    NativeError,
    Registers,
    CallDepth,
    IvarCapacity,
    ScratchFull,
    StateCapacity,
    Disposed,
}

struct ErrorContext {
    class_id: u32,
    method_symbol: u32,
    binding_id: i64,
    scratch_resource: ScratchResource = ScratchResource.None,
    scratch_requested: i64 = 0,
    scratch_used: i64 = 0,
    scratch_capacity: i64 = 0,
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
        WrongArity => "wrong number of arguments",
        NativeError => "native method failed",
        Registers => "register overflow",
        CallDepth => "call depth exceeded",
        IvarCapacity => "ivar capacity exceeded",
        ScratchFull => "scratch arena capacity exceeded",
        StateCapacity => "state pool capacity exceeded",
        Disposed => "disposed instance",
    };
}

// Records which component method and binding was running when `error` was set.
// A `binding_id` below zero means the failure happened outside a binding.
fn vm_set_error_context(machine: Vm&, class_id: u32, method_symbol: u32, binding_id: i64) {
    machine.error_context.class_id = class_id;
    machine.error_context.method_symbol = method_symbol;
    machine.error_context.binding_id = binding_id;
}

fn vm_clear_scratch_failure(machine: Vm&) {
    machine.error_context.scratch_resource = ScratchResource.None;
    machine.error_context.scratch_requested = 0;
    machine.error_context.scratch_used = 0;
    machine.error_context.scratch_capacity = 0;
    machine.scratch.failure.resource = ScratchResource.None;
    machine.scratch.failure.requested = 0;
    machine.scratch.failure.used = 0;
    machine.scratch.failure.capacity = 0;
    machine.scratch.failure.active = false;
}

fn scratch_resource_name(resource: ScratchResource) -> u8[:] {
    return match resource {
        None => "",
        Objects => "objects",
        Bytes => "bytes",
        Ivars => "ivars",
        Slots => "slots",
    };
}

// Names the innermost method whose IREP was executing. The class-body root has
// no method entry, so its existing context is kept. Called as an error
// unwinds, the first frame to see it wins and outer frames cannot overwrite
// the original component method with their own.
fn vm_absorb_method_context(machine: Vm&, record_index: i64) {
    if machine.error_context.class_id != NULL_CLASS_ID {
        return;
    }
    for method in machine.methods {
        if method.irep_index == record_index {
            vm_set_error_context(machine, method.class_id, method.name_symbol,
                machine.error_context.binding_id);
            return;
        }
    }
}

// Copies the first scratch rejection into the error record and names the
// innermost method whose IREP was executing.
fn vm_absorb_scratch_failure(machine: Vm&, record_index: i64) {
    let failure = machine.scratch.failure;
    if failure.active {
        machine.error_context.scratch_resource = failure.resource;
        machine.error_context.scratch_requested = failure.requested;
        machine.error_context.scratch_used = failure.used;
        machine.error_context.scratch_capacity = failure.capacity;
    }
    vm_absorb_method_context(machine, record_index);
}
