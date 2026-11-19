// Transactional execution of loaded program roots.
namespace vm;

import.capacity_config;
import.computed;
import.rite_types;
import.state_pool;
import.vm_core;
import.vm_errors;
import.vm_methods;
import.vm_ops;

extern fn mochi_shim_class_count() -> i64;

extern fn mochi_shim_class_truncate(count: i64);

fn vm_shim_class_truncate(count: i64) {
    mochi_shim_class_truncate(count);
}

// Runs one root IREP per loaded program. A failed root rolls its classes,
// constants, methods and computed definitions back to the pre-root watermark
// and leaves `booted_roots` unadvanced, so the same failure is reported again
// instead of booting on top of partial state.
fn vm_ensure_booted(machine: Vm&) {
    if record_count(machine.file) == 0 {
        machine.error = VmError.BadOpcode;
        return;
    }
    while machine.booted_roots < root_count(machine.file) {
        let root = root_at(machine.file, machine.booted_roots);
        let saved_classes = state_class_count(machine.pool);
        let saved_consts = const_count(machine.pool);
        let saved_methods = method_count(machine);
        let saved_native_methods = native_method_count(machine);
        let saved_definitions = computed_def_count(machine);
        let saved_roots = computed_root_count(machine);
        let saved_shim_classes = mochi_shim_class_count();

        machine.error = VmError.Ok;
        machine.pool.error = VmError.Ok;
        vm_exec(machine, root, mrb_nil(), -1);

        var boot_error = machine.error;
        if boot_error == VmError.Ok {
            boot_error = machine.pool.error;
        }
        if boot_error != VmError.Ok {
            machine.error = boot_error;
            if boot_error == VmError.StateCapacity || boot_error == VmError.IvarCapacity {
                vm_absorb_state_failure(machine, root);
            }
            state_class_truncate(machine.pool, saved_classes);
            const_truncate(machine.pool, saved_consts);
            method_truncate(machine, saved_methods);
            native_method_truncate(machine, saved_native_methods);
            computed_def_truncate(machine, saved_definitions);
            computed_root_truncate(machine, saved_roots);
            mochi_shim_class_truncate(saved_shim_classes);
            return;
        }
        machine.booted_roots += 1;
    }
}
