// Explicit computed metadata and per-instance, GC-rooted lazy results.
namespace vm;

import.builtins;
import.capacity_config;
import.collection_arena;
import.ivar_mask;
import.signals;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_ops;

// Definitions contain interned symbols only; no scratch or state handles.
struct ComputedDefinition {
    class_id: u32,
    method_symbol: u32,
    root_start: i64,
    root_count: i64,
}

// Invalidating drops the retained graph immediately. Entries are bounded by
// the profile's binding limit and removed when their component is disposed.
struct ComputedEntry {
    instance: MrbValue,
    method_symbol: u32,
    dependencies: IvarMask,
    value: MrbValue,
    valid: bool = false,
    evaluating: bool = false,
}

fn computed_register(machine: Vm&, class_id: u32, args: MrbValue[:]) -> MrbValue {
    if machine.pool.computed_depth > 0 {
        machine.error = VmError.ComputedEffect;
        return mrb_nil();
    }
    if args.len != 2 || !mrb_is_symbol(args[0]) {
        machine.error = VmError.InvalidArgument;
        return mrb_nil();
    }
    if !scratch_is_array(machine.scratch, args[1]) && !state_is_array(machine.pool, args[1]) {
        machine.error = VmError.InvalidArgument;
        return mrb_nil();
    }
    let method_symbol = mrb_symbol_id(args[0]);
    for definition in machine.computed_definitions {
        if definition.class_id == class_id && definition.method_symbol == method_symbol {
            machine.error = VmError.InvalidArgument;
            return mrb_nil();
        }
    }
    let count = builtin_array_length(machine.pool, machine.scratch, args[1]);
    if count > MAX_TRACKED_IVARS || machine.computed_definitions.len >= MAX_VM_METHODS {
        machine.error = VmError.InvalidArgument;
        return mrb_nil();
    }
    // Validate the entire slice before publishing a descriptor: a rejected
    // declaration must never leave a root range beyond the metadata table.
    for index in 0..count {
        let root = builtin_array_get(machine.pool, machine.scratch, args[1], index);
        if !mrb_is_symbol(root) {
            machine.error = VmError.InvalidArgument;
            return mrb_nil();
        }
    }
    machine.computed_definitions.push(ComputedDefinition {
            class_id: class_id,
            method_symbol: method_symbol,
            root_start: machine.computed_roots.len,
            root_count: count,
        });
    for index in 0..count {
        let root = builtin_array_get(machine.pool, machine.scratch, args[1], index);
        machine.computed_roots.push(mrb_symbol_id(root));
    }
    return mrb_nil();
}

fn computed_definition(machine: Vm&, class_id: u32, method_symbol: u32) -> i64 {
    if machine.computed_definitions.len == 0 {
        return -1;
    }
    var owner = class_id;
    for _ in 0..machine.pool.classes.len + 1 {
        for index in 0..machine.computed_definitions.len {
            let definition = machine.computed_definitions[index];
            if definition.class_id == owner && definition.method_symbol == method_symbol {
                return index;
            }
        }
        // An ordinary override replaces the ancestor's declaration too.
        for method in machine.methods {
            if method.class_id == owner && method.name_symbol == method_symbol {
                return -1;
            }
        }
        if owner >= machine.pool.classes.len {
            return -1;
        }
        owner = state_class_superclass_id(machine.pool, owner);
    }
    return -1;
}

fn computed_entry(machine: Vm&, instance: MrbValue, definition_index: i64) -> i64 {
    let definition .= machine.computed_definitions[definition_index];
    for index in 0..machine.pool.computed.len {
        let entry = machine.pool.computed[index];
        if mrb_value_identical(entry.instance, instance) && entry.method_symbol == definition.method_symbol {
            return index;
        }
    }
    if machine.pool.computed.len >= MAX_BINDINGS {
        state_fail_capacity(machine.pool, CapacityResource.ComputedEntries, 1,
            machine.pool.computed.len, MAX_BINDINGS);
        return -1;
    }
    var dependencies = mask_clear();
    for root_index in definition.root_start..definition.root_start + definition.root_count {
        let key = machine.computed_roots[root_index];
        var bit_index = state_ivar_bit_index(machine.pool, instance, key);
        if bit_index < 0 {
            let slot = state_append_ivar_slot(machine.pool, mrb_arena_index(instance), key, mrb_nil());
            if slot < 0 {
                return -1;
            }
            bit_index = machine.pool.ivars[slot].bit_index;
        }
        mask_set_bit(dependencies, bit_index as u16);
    }
    let index = machine.pool.computed.len;
    machine.pool.computed.push(ComputedEntry {
            instance: instance,
            method_symbol: definition.method_symbol,
            dependencies: dependencies,
            value: mrb_nil(),
            ..
        });
    return index;
}

// Called at the ordinary method dispatch seam; nested evaluation keeps the
// caller's register window and the binding's active read mask intact.
fn vm_exec_method(machine: Vm&, class_id: u32, method_symbol: u32, irep: i64,
    receiver: MrbValue, dst: i64, args: MrbValue[:]) -> MrbValue {
    let definition = computed_definition(machine, class_id, method_symbol);
    if definition < 0 {
        return vm_exec_with_args(machine, irep, receiver, dst, args);
    }
    if args.len != 0 {
        machine.error = VmError.WrongArity;
        return mrb_nil();
    }
    let object, is_instance = state_object(machine.pool, receiver);
    if !is_instance || object.kind != ArenaObjectKind.Instance {
        machine.error = VmError.BadReceiver;
        return mrb_nil();
    }
    let index = computed_entry(machine, receiver, definition);
    if index < 0 {
        machine.error = machine.pool.error;
        // Entry allocation can fail before the method gets a frame. Keep the
        // rejected computed method, rather than attributing it to its caller.
        vm_set_error_context(machine, class_id, method_symbol, machine.error_context.binding_id);
        machine.error_context.computed = true;
        vm_absorb_state_failure(machine, irep);
        return mrb_nil();
    }
    let entry = machine.pool.computed[index];
    if state_is_tracked(machine.pool, receiver) {
        machine.pool.active_read_mask = mask_or(machine.pool.active_read_mask, entry.dependencies);
    }
    if entry.evaluating {
        machine.error = VmError.ComputedReentry;
        vm_set_error_context(machine, class_id, method_symbol, -1);
        return mrb_nil();
    }
    var value = entry.value;
    if !entry.valid {
        machine.pool.computed[index].evaluating = true;
        machine.pool.computed_depth += 1;
        value = vm_exec_with_args(machine, irep, receiver, dst, args);
        machine.pool.computed_depth -= 1;
        machine.pool.computed[index].evaluating = false;
        if machine.error == VmError.Ok && machine.pool.error == VmError.Ok && !machine.scratch.overflow {
            // Promotion is internal bookkeeping; it may run inside an outer
            // computed evaluation and uses raw allocation, not Ruby mutation.
            value = promote_to_state(machine.pool, machine.scratch, value);
            if machine.pool.error == VmError.Ok {
                machine.pool.computed[index].value = value;
                machine.pool.computed[index].valid = true;
            }
        }
        if machine.pool.error != VmError.Ok && machine.error == VmError.Ok {
            machine.error = machine.pool.error;
        }
        if machine.error != VmError.Ok {
            if !machine.error_context.computed
                && (machine.error == VmError.ComputedEffect || machine.error == VmError.ComputedReentry) {
                vm_set_error_context(machine, class_id, method_symbol, -1);
            }
            machine.error_context.computed = true;
            vm_absorb_method_context(machine, irep);
            return mrb_nil();
        }
    }
    if dst >= 0 {
        machine.regs[dst] = value;
    }
    return value;
}

fn computed_invalidate(pool: StatePool&, object_index: i64, bit_index: u8) {
    let changed = state_ivar_bit(bit_index);
    for index in 0..pool.computed.len {
        let entry = pool.computed[index];
        if mrb_arena_index(entry.instance) == object_index && mask_intersects(entry.dependencies, changed) {
            pool.computed[index].valid = false;
            pool.computed[index].value = mrb_nil();
        }
    }
}

fn computed_unregister(pool: StatePool&, instance: MrbValue) {
    var keep = 0;
    for index in 0..pool.computed.len {
        if !mrb_value_identical(pool.computed[index].instance, instance) {
            pool.computed[keep] = pool.computed[index];
            keep += 1;
        }
    }
    while pool.computed.len > keep {
        pool.computed.pop();
    }
}
