// Diagnostic context for VM failures.
//
// A bare `VmError` name does not tell a host which component method failed.
// `ErrorContext` names the class, method and binding that were running, and the
// C ABI formats those fields into `lastError` as
// `CowboyToast#__mochi_bind_2 (binding 2): type mismatch`.
namespace vm;

import.vm_core;

struct ErrorContext {
    class_id: u32,
    method_symbol: u32,
    binding_id: i64,
}

// Records which component method and binding was running when `error` was set.
// A `binding_id` below zero means the failure happened outside a binding.
fn vm_set_error_context(machine: Vm&, class_id: u32, method_symbol: u32, binding_id: i64) {
    machine.error_context.class_id = class_id;
    machine.error_context.method_symbol = method_symbol;
    machine.error_context.binding_id = binding_id;
}
