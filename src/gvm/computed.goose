// Explicit computed metadata and per-instance, GC-rooted lazy results.
namespace vm;

import.builtins;
import.capacity_config;
import.collection_arena;
import.ivar_mask;
import.signals;
import.slab;
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

// Accessors for computed definitions and their symbol roots. Registration,
// lookup and rollback all go through these helpers.

extern fn mochi_meta_computed_def_at(handle: i64, index: i64) -> ComputedDefinition;

extern fn mochi_meta_computed_def_push(
    handle: i64, definition: ComputedDefinition
) -> bool;

extern fn mochi_meta_computed_def_truncate(handle: i64, count: i64);

extern fn mochi_meta_computed_root_at(handle: i64, index: i64) -> u32;

extern fn mochi_meta_computed_root_push(handle: i64, root: u32) -> bool;

extern fn mochi_meta_computed_root_truncate(handle: i64, count: i64);

fn computed_def_count(machine: Vm&) -> i64 {
    return mochi_meta_count(vm_metadata(machine), 2);
}

fn computed_def_at(machine: Vm&, index: i64) -> ComputedDefinition {
    return mochi_meta_computed_def_at(vm_metadata(machine), index);
}

fn computed_def_push(machine: Vm&, definition: ComputedDefinition) -> bool {
    return mochi_meta_computed_def_push(vm_metadata(machine), definition);
}

fn computed_def_clear(machine: Vm&) {
    mochi_meta_computed_def_truncate(vm_metadata(machine), 0);
}

fn computed_def_truncate(machine: Vm&, count: i64) {
    mochi_meta_computed_def_truncate(vm_metadata(machine), count);
}

fn computed_root_count(machine: Vm&) -> i64 {
    return mochi_meta_count(vm_metadata(machine), 3);
}

fn computed_root_at(machine: Vm&, index: i64) -> u32 {
    return mochi_meta_computed_root_at(vm_metadata(machine), index);
}

fn computed_root_push(machine: Vm&, root: u32) -> bool {
    return mochi_meta_computed_root_push(vm_metadata(machine), root);
}

fn computed_root_clear(machine: Vm&) {
    mochi_meta_computed_root_truncate(vm_metadata(machine), 0);
}

fn computed_root_truncate(machine: Vm&, count: i64) {
    mochi_meta_computed_root_truncate(vm_metadata(machine), count);
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
    for index in 0..computed_def_count(machine) {
        let definition = computed_def_at(machine, index);
        if definition.class_id == class_id && definition.method_symbol == method_symbol {
            machine.error = VmError.InvalidArgument;
            return mrb_nil();
        }
    }
    let count = builtin_array_length(machine.pool, machine.scratch, args[1]);
    if count > MAX_TRACKED_IVARS {
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
    let root_start = computed_root_count(machine);
    if !computed_def_push(machine, ComputedDefinition {
            class_id: class_id,
            method_symbol: method_symbol,
            root_start: root_start,
            root_count: count,
        }) {
        state_fail_capacity(machine.pool, CapacityResource.Methods, 1,
            slab_used_bytes(), slab_limit_bytes());
        machine.error = VmError.StateCapacity;
        return mrb_nil();
    }
    for index in 0..count {
        let root = builtin_array_get(machine.pool, machine.scratch, args[1], index);
        if !computed_root_push(machine, mrb_symbol_id(root)) {
            computed_root_truncate(machine, root_start);
            computed_def_truncate(machine, computed_def_count(machine) - 1);
            state_fail_capacity(machine.pool, CapacityResource.Methods, 1,
                slab_used_bytes(), slab_limit_bytes());
            machine.error = VmError.StateCapacity;
            return mrb_nil();
        }
    }
    return mrb_nil();
}

fn computed_definition(machine: Vm&, class_id: u32, method_symbol: u32) -> i64 {
    if computed_def_count(machine) == 0 {
        return -1;
    }
    var owner = class_id;
    for _ in 0..state_class_count(machine.pool) + 1 {
        for index in 0..computed_def_count(machine) {
            let definition = computed_def_at(machine, index);
            if definition.class_id == owner && definition.method_symbol == method_symbol {
                return index;
            }
        }
        // An ordinary override replaces the ancestor's declaration too.
        for index in 0..method_count(machine) {
            let method = method_at(machine, index);
            if method.class_id == owner && method.name_symbol == method_symbol {
                return -1;
            }
        }
        if owner >= state_class_count(machine.pool) {
            return -1;
        }
        owner = state_class_superclass_id(machine.pool, owner);
    }
    return -1;
}

fn computed_entry(machine: Vm&, instance: MrbValue, definition_index: i64) -> i64 {
    let definition = computed_def_at(machine, definition_index);
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
        let key = computed_root_at(machine, root_index);
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
