// Diagnostic context and error codes for VM failures.
namespace vm;

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
}

struct ErrorContext {
    class_id: u32,
    method_symbol: u32,
    binding_id: i64,
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
    };
}

// Records which component method and binding was running when `error` was set.
// A `binding_id` below zero means the failure happened outside a binding.
fn vm_set_error_context(machine: Vm&, class_id: u32, method_symbol: u32, binding_id: i64) {
    machine.error_context.class_id = class_id;
    machine.error_context.method_symbol = method_symbol;
    machine.error_context.binding_id = binding_id;
}
