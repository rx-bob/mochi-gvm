// Host entrypoints for instantiating components and invoking their methods.
namespace vm;

import.computed;
import.signals;
import.state_pool;
import.state_reclaim;
import.value_arena;
import.vm_core;
import.vm_methods;
import.vm_ops;

// Starts a top-level entry from a clean tick arena. A previous entry's scratch
// result is dead once the host has read it, so the arena rewinds here.
fn vm_begin_entry(machine: Vm&) {
    machine.error = VmError.Ok;
    vm_set_error_context(machine, NULL_CLASS_ID, NULL_SYMBOL, -1);
    vm_clear_entry_capacity_failure(machine);
    machine.pool.error = VmError.Ok;
    machine.regs.clear();
    machine.frames.clear();
    machine.entry_args.clear();
    machine.scratch_roots.clear();
    scratch_reset(machine.scratch);
}

// Preserve rejected allocations before releasing transient roots and scratch.
fn vm_end_entry(machine: Vm&) {
    if machine.error != VmError.Ok {
        vm_capture_capacity_failure(machine);
    }
    machine.regs.clear();
    machine.frames.clear();
    machine.entry_args.clear();
    machine.scratch_roots.clear();
    scratch_reset(machine.scratch);
}

// Releases the registrations created for one instance. Classes and IREP stay
// resident; the instance header itself is reclaimed by the collector once no
// root or reachable collection refers to it. Repeated disposal is safe.
fn vm_dispose_instance(machine: Vm&, instance: MrbValue) -> bool {
    let object, ok = state_object(machine.pool, instance);
    if !ok {
        // A second unmount of an already reclaimed handle is still a successful
        // no-op; the handle cannot name a live object any more.
        return state_instance_disposed(machine.pool, instance);
    }
    if object.kind != ArenaObjectKind.Instance {
        return false;
    }
    binding_unregister_all(machine.pool, instance);
    computed_unregister(machine.pool, instance);
    state_unregister_component(machine.pool, instance);
    state_mark_instance_disposed(machine.pool, instance);
    // Reclaim immediately when this host entry owns no frames. A collection
    // shared with another component stays reachable from that component's root.
    if machine.frames.len == 0 && machine.regs.len == 0
        && machine.entry_args.len == 0 && machine.pool.tracking_instance_index < 0 {
        gc_collect(machine);
    }
    return true;
}

// Installs declared props through the component's generated
// `__mochi_apply_props` method. A component without declarations has no such
// method and ignores the payload. A missing or failed generated method leaves
// `machine.error` set so the mount transaction can roll back.
fn vm_apply_component_props(
    machine: Vm&, instance: MrbValue, props: MrbValue, initial: bool
) -> bool {
    let class_id, is_instance = vm_owner_class_id(machine, instance);
    if !is_instance {
        machine.error = VmError.BadReceiver;
        return false;
    }
    let apply_symbol = intern_symbol("__mochi_apply_props");
    let irep, found = vm_lookup_method(machine, class_id, apply_symbol);
    if !found {
        return true;
    }
    vm_set_error_context(machine, class_id, apply_symbol, -1);
    let args: MrbValue[2] = [props, mrb_bool(initial)];
    vm_exec_with_args(machine, irep, instance, -1, args[..]);
    if machine.error != VmError.Ok {
        return false;
    }
    if machine.pool.error != VmError.Ok {
        machine.error = machine.pool.error;
        return false;
    }
    return true;
}

fn vm_component_registration_failed(machine: Vm&, instance: MrbValue) -> MrbValue {
    machine.error = machine.pool.error;
    if machine.error == VmError.Ok {
        machine.error = VmError.StateCapacity;
    }
    return vm_rollback_mount(machine, instance);
}

fn vm_rollback_mount(machine: Vm&, instance: MrbValue) -> MrbValue {
    vm_end_entry(machine);
    vm_dispose_instance(machine, instance);
    return mrb_nil();
}

fn vm_prepare_mount_props(
    machine: Vm&, props_json: const u8[:], props: MrbValue&, restore_props: MrbValue&
) -> bool {
    props = builtin_hash_new(machine.scratch);
    restore_props = props;
    if props_json.len == 0 {
        return true;
    }
    let parsed, parsed_ok = json_parse_document(machine.pool, machine.scratch, props_json);
    if !parsed_ok || !vm_is_hash_value(machine, parsed) {
        machine.error = VmError.TypeMismatch;
        return false;
    }
    props = promote_to_state(machine.pool, machine.scratch, parsed);
    if !mrb_is_state(props) || machine.pool.error != VmError.Ok {
        machine.error = VmError.StateCapacity;
        if machine.pool.error != VmError.Ok {
            machine.error = machine.pool.error;
        }
        return false;
    }
    // Keep an independent input snapshot because initialize can mutate nested
    // collections in the first promoted copy.
    restore_props = promote_to_state(machine.pool, machine.scratch, parsed);
    if !mrb_is_state(restore_props) || machine.pool.error != VmError.Ok {
        machine.error = VmError.StateCapacity;
        if machine.pool.error != VmError.Ok {
            machine.error = machine.pool.error;
        }
        return false;
    }
    return true;
}

// Creates a state instance of `class_sym` and runs its `initialize` method with
// no arguments. The returned instance is durable state, so the tick arena is
// released before returning.
fn vm_instantiate(machine: Vm&, class_sym: u32) -> MrbValue {
    return vm_instantiate_with_props(machine, class_sym, "");
}

// Mounts one component with a JSON object of declared props. Props are
// installed before `initialize` so declared defaults and supplied values are
// readable there. A second copy of the payload is installed afterwards so an
// `initialize` assignment or in-place collection mutation cannot clobber the
// parent's input.
fn vm_instantiate_with_props(
    machine: Vm&, class_sym: u32, props_json: const u8[:]
) -> MrbValue {
    vm_begin_entry(machine);
    vm_ensure_booted(machine);
    if machine.error != VmError.Ok {
        vm_end_entry(machine);
        return mrb_nil();
    }
    let class_id, found = vm_find_class(machine.pool, class_sym);
    if !found {
        machine.error = VmError.NoClass;
        vm_end_entry(machine);
        return mrb_nil();
    }
    // Even an allocation failure before `initialize` runs belongs to this
    // component, so the host never reports a bare "component mount failed".
    vm_set_error_context(machine, class_id, NULL_SYMBOL, -1);
    let instance = state_alloc_instance(machine.pool, class_id);
    if !mrb_is_state(instance) {
        machine.error = VmError.StateCapacity;
        if machine.pool.error != VmError.Ok {
            machine.error = machine.pool.error;
        }
        vm_end_entry(machine);
        return mrb_nil();
    }
    if !state_register_component(machine.pool, instance) {
        return vm_component_registration_failed(machine, instance);
    }

    var props = mrb_nil();
    var restore_props = mrb_nil();
    if !vm_prepare_mount_props(machine, props_json, props, restore_props) {
        return vm_rollback_mount(machine, instance);
    }

    // Both promoted snapshots are ordinary locals, so the collector cannot
    // see them while initialize executes between the two generated prop calls.
    // Keep them in the host-entry root set until vm_end_entry clears it.
    machine.entry_args.push(props);
    machine.entry_args.push(restore_props);

    if !vm_apply_component_props(machine, instance, props, true) {
        return vm_rollback_mount(machine, instance);
    }

    let initialize_symbol = intern_symbol("initialize");
    let irep, has_initialize = vm_lookup_method(machine, class_id, initialize_symbol);
    if has_initialize {
        vm_set_error_context(machine, class_id, initialize_symbol, -1);
        vm_exec(machine, irep, instance, -1);
    }
    // Declared props are read-only inputs. Reinstalling defaults and supplied
    // values discards any `initialize` assignment or in-place collection
    // mutation, so a mount always starts from the resolved snapshot.
    if machine.error == VmError.Ok {
        if !vm_apply_component_props(machine, instance, restore_props, true) {
            return vm_rollback_mount(machine, instance);
        }
    }
    vm_end_entry(machine);
    if machine.error != VmError.Ok {
        // A failed initialize is a failed mount: its bindings and component
        // root must not survive as a half-live instance.
        vm_dispose_instance(machine, instance);
        return mrb_nil();
    }
    return instance;
}

// Calls a no-argument method on a state instance or class value. The result
// may be a scratch string, so it stays valid until the host copies the bytes
// out; the next top-level entry clears the arena before it starts.
fn vm_call0(machine: Vm&, receiver: MrbValue, method_sym: u32) -> MrbValue {
    let no_args: MrbValue[1] = [mrb_nil()];
    return vm_call_args(machine, receiver, method_sym, no_args[..0]);
}

// Calls a one-argument method on a state instance or class value. The argument
// must already be durable (a state value or an immediate) because the tick
// arena resets before the callee starts.
fn vm_call1(machine: Vm&, receiver: MrbValue, method_sym: u32, argument: MrbValue) -> MrbValue {
    let args: MrbValue[1] = [argument];
    return vm_call_args(machine, receiver, method_sym, args[..]);
}

// Calls a state instance or class method with positional arguments. The C ABI
// uses this entry point for zero-argument renders and one-argument callbacks.
fn vm_call_args(
    machine: Vm&, receiver: MrbValue, method_sym: u32, args: MrbValue[:]
) -> MrbValue {
    vm_begin_entry(machine);
    return vm_call_args_prepared(machine, receiver, method_sym, args);
}

// Calls a method after the caller has begun the entry. JSON event arguments are
// parsed into the tick arena, so the entry must not reset it between parsing
// and this call.
fn vm_call_args_prepared(
    machine: Vm&, receiver: MrbValue, method_sym: u32, args: MrbValue[:]
) -> MrbValue {
    if state_instance_disposed(machine.pool, receiver) {
        machine.error = VmError.Disposed;
        vm_end_entry(machine);
        return mrb_nil();
    }
    let class_id, is_instance = vm_owner_class_id(machine, receiver);
    if !is_instance {
        machine.error = VmError.BadReceiver;
        vm_end_entry(machine);
        return mrb_nil();
    }
    let native_id, native_found = vm_lookup_native_method(machine, class_id, method_sym);
    if native_found {
        if machine.pool.computed_depth > 0 || computed_definition(machine, class_id, method_sym) >= 0 {
            machine.error = VmError.ComputedEffect;
            vm_set_error_context(machine, class_id, method_sym, -1);
            return mrb_nil();
        }
        for index in 0..args.len {
            goose_abi_native_set_arg(index, args[index]);
        }
        let native_result = goose_abi_native_call(native_id, receiver, args.len);
        if native_result == NATIVE_FAIL {
            machine.error = VmError.NativeError;
            vm_end_entry(machine);
            return mrb_nil();
        }
        return native_result;
    }
    for value in args {
        machine.entry_args.push(value);
    }
    vm_ensure_booted(machine);
    machine.entry_args.clear();
    if machine.error != VmError.Ok {
        vm_end_entry(machine);
        return mrb_nil();
    }
    let irep, found = vm_lookup_method(machine, class_id, method_sym);
    if !found {
        machine.error = VmError.NoMethod;
        vm_end_entry(machine);
        return mrb_nil();
    }
    return vm_exec_method(machine, class_id, method_sym, irep, receiver, -1, args);
}
