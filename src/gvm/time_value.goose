// Construction only: the optional Ruby Time package owns its public methods.
namespace vm;

import.ivar_mask;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_errors;
import.vm_num;

let TIME_MAX_SECONDS: f64 = 8640000000000.0;

fn time_at(machine: Vm&, args: MrbValue[:]) -> MrbValue {
    if args.len != 1 {
        machine.error = VmError.WrongArity;
        return mrb_nil();
    }
    let seconds, numeric = num_to_f64(machine.scratch, machine.pool, args[0]);
    if !numeric {
        machine.error = VmError.TimeType;
        return mrb_nil();
    }
    if seconds != seconds || seconds - seconds != 0.0 {
        machine.error = VmError.FloatDomain;
        return mrb_nil();
    }
    if seconds < - TIME_MAX_SECONDS || seconds > TIME_MAX_SECONDS {
        machine.error = VmError.TimeRange;
        return mrb_nil();
    }
    let class_id, found = vm_find_class(machine.pool, intern_symbol("Time"));
    if !found {
        machine.error = VmError.NoClass;
        return mrb_nil();
    }
    // A fresh value object, not a mounted component. It is rooted by ordinary
    // registers/ivars and reclaimed by the existing state collector.
    let instant = state_alloc_instance(machine.pool, class_id);
    if vm_capture_capacity_failure(machine) {
        return mrb_nil();
    }
    let stored = state_set_ivar(machine.pool, machine.scratch, instant, intern_symbol("@seconds"), args[0]);
    if vm_capture_capacity_failure(machine) {
        return mrb_nil();
    }
    if !stored {
        machine.error = VmError.StateCapacity;
        return mrb_nil();
    }
    return instant;
}
