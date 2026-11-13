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
    IntegerOverflow,
    DivisionByZero,
    FloatDomain,
    InvalidArgument,
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
    capacity_resource: CapacityResource = CapacityResource.None,
    capacity_requested: i64 = 0,
    capacity_used: i64 = 0,
    capacity_limit: i64 = 0,
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
        IntegerOverflow => "integer overflow",
        DivisionByZero => "division by zero",
        FloatDomain => "non-finite float",
        InvalidArgument => "invalid argument",
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

fn vm_clear_entry_capacity_failure(machine: Vm&) {
    machine.error_context.scratch_resource = ScratchResource.None;
    machine.error_context.scratch_requested = 0;
    machine.error_context.scratch_used = 0;
    machine.error_context.scratch_capacity = 0;
    machine.error_context.capacity_resource = CapacityResource.None;
    machine.error_context.capacity_requested = 0;
    machine.error_context.capacity_used = 0;
    machine.error_context.capacity_limit = 0;
    machine.scratch.failure.resource = ScratchResource.None;
    machine.scratch.failure.requested = 0;
    machine.scratch.failure.used = 0;
    machine.scratch.failure.capacity = 0;
    machine.scratch.failure.active = false;
    machine.pool.failure.resource = CapacityResource.None;
    machine.pool.failure.requested = 0;
    machine.pool.failure.used = 0;
    machine.pool.failure.capacity = 0;
    machine.pool.failure.active = false;
}

// Parsing and promotion can reject an allocation before bytecode executes.
// Preserve that rejection before entry teardown resets the scratch arena.
fn vm_capture_capacity_failure(machine: Vm&) -> bool {
    if machine.scratch.failure.active {
        machine.error = VmError.ScratchFull;
        vm_absorb_scratch_failure(machine, -1);
        return true;
    }
    if machine.pool.failure.active {
        machine.error = machine.pool.error;
        if machine.error == VmError.Ok {
            machine.error = VmError.StateCapacity;
        }
        vm_absorb_state_failure(machine, -1);
        return true;
    }
    return false;
}

fn capacity_resource_name(resource: CapacityResource) -> u8[:] {
    return match resource {
        None => "",
        ScratchObjects => "scratch objects",
        ScratchBytes => "scratch bytes",
        ScratchIvars => "scratch ivars",
        ScratchSlots => "scratch slots",
        StateBytes => "state bytes",
        StateObjects => "state objects",
        StateIvars => "state ivars",
        StateSlots => "state slots",
        IvarsPerObject => "ivars per object",
        Components => "component registrations",
        Bindings => "bindings",
        Classes => "classes",
        AbiBytecode => "ABI bytecode bytes",
        HostCommands => "host command bytes",
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
        machine.error_context.capacity_resource = match failure.resource {
            Objects => CapacityResource.ScratchObjects,
            Bytes => CapacityResource.ScratchBytes,
            Ivars => CapacityResource.ScratchIvars,
            Slots => CapacityResource.ScratchSlots,
            None => CapacityResource.None,
        };
        machine.error_context.capacity_requested = failure.requested;
        machine.error_context.capacity_used = failure.used;
        machine.error_context.capacity_limit = failure.capacity;
        machine.error_context.scratch_resource = failure.resource;
        machine.error_context.scratch_requested = failure.requested;
        machine.error_context.scratch_used = failure.used;
        machine.error_context.scratch_capacity = failure.capacity;
    }
    vm_absorb_method_context(machine, record_index);
}

fn vm_absorb_state_failure(machine: Vm&, record_index: i64) {
    let failure = machine.pool.failure;
    if failure.active {
        machine.error_context.capacity_resource = failure.resource;
        machine.error_context.capacity_requested = failure.requested;
        machine.error_context.capacity_used = failure.used;
        machine.error_context.capacity_limit = failure.capacity;
    }
    vm_absorb_method_context(machine, record_index);
}
