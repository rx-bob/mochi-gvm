// Block invocation and Array/Hash/Integer iteration for SENDB and SSENDB.
namespace vm;

import.builtins;
import.collection_arena;
import.scratch_reclaim;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_methods;
import.vm_num;
import.vm_ops;

recursive fn vm_invoke_block(
    machine: Vm&, closure: MrbValue, self_value: MrbValue, argument: MrbValue
) -> MrbValue {
    let args: MrbValue[1] = [argument];
    return vm_invoke_block_args(machine, closure, self_value, args[..]);
}

recursive fn vm_invoke_block_args(
    machine: Vm&, closure: MrbValue, self_value: MrbValue, args: MrbValue[:]
) -> MrbValue {
    if !mrb_is_block(closure) {
        machine.error = VmError.TypeMismatch;
        return mrb_nil();
    }
    let record_index = mrb_block_record_index(closure);
    var env_frame = mrb_block_env_frame(closure);
    if env_frame < 0 && machine.frames.len > 0 {
        env_frame = machine.frames.len - 1;
    }
    return vm_exec_frame(machine, record_index, self_value, -1, args, env_frame);
}

// Runs `closure` for every element. With `collect`, returns a new scratch array
// of block results; otherwise returns the original array.
recursive fn vm_iterate_array(
    machine: Vm&, array: MrbValue, closure: MrbValue, self_value: MrbValue, collect: bool
) -> MrbValue {
    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, array);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    var mapped = mrb_nil();
    if collect {
        mapped = builtin_array_new(machine.scratch);
        scratch_root(machine, mapped);
    }
    var index = 0;
    while index < length {
        let element = builtin_array_get(machine.pool, machine.scratch, array, index);
        let result = vm_invoke_block(machine, closure, self_value, element);
        if machine.error != VmError.Ok {
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        if collect {
            if !builtin_array_push(machine.pool, machine.scratch, mapped, result) {
                machine.error = VmError.TypeMismatch;
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
        }
        index += 1;
    }
    scratch_root_end(machine, root_mark);
    if collect {
        return mapped;
    }
    return array;
}

recursive fn vm_filter_array(
    machine: Vm&, array: MrbValue, closure: MrbValue, self_value: MrbValue, keep_truthy: bool
) -> MrbValue {
    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, array);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    let out = builtin_array_new(machine.scratch);
    scratch_root(machine, out);
    var index = 0;
    while index < length {
        let element = builtin_array_get(machine.pool, machine.scratch, array, index);
        let result = vm_invoke_block(machine, closure, self_value, element);
        if machine.error != VmError.Ok {
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        if mrb_truthy(result) == keep_truthy {
            builtin_array_push(machine.pool, machine.scratch, out, element);
        }
        index += 1;
    }
    scratch_root_end(machine, root_mark);
    return out;
}

recursive fn vm_array_each_with_index(
    machine: Vm&, array: MrbValue, closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    var i = 0;
    while i < length {
        let el = builtin_array_get(machine.pool, machine.scratch, array, i);
        let pair: MrbValue[2] = [el, mrb_fixnum(i)];
        vm_invoke_block_args(machine, closure, self_value, pair[..]);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        i += 1;
    }
    return array;
}

recursive fn vm_array_find_block(
    machine: Vm&, array: MrbValue, closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    var i = 0;
    while i < length {
        let el = builtin_array_get(machine.pool, machine.scratch, array, i);
        let res = vm_invoke_block(machine, closure, self_value, el);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        if mrb_truthy(res) {
            return el;
        }
        i += 1;
    }
    return mrb_nil();
}

recursive fn vm_array_match_block(
    machine: Vm&, array: MrbValue, name: u8[:], closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    var matched = 0;
    var i = 0;
    while i < length {
        let el = builtin_array_get(machine.pool, machine.scratch, array, i);
        let res = vm_invoke_block(machine, closure, self_value, el);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        if mrb_truthy(res) {
            matched += 1;
            if name == "any?" {
                return mrb_true();
            }
        } else if name == "all?" {
            return mrb_false();
        }
        i += 1;
    }
    if name == "any?" {
        return mrb_false();
    }
    if name == "all?" {
        return mrb_true();
    }
    return mrb_fixnum(matched);
}

recursive fn vm_array_aggregate_block(
    machine: Vm&, array: MrbValue, name: u8[:], closure: MrbValue,
    self_value: MrbValue, args: MrbValue[:]
) -> MrbValue {
    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, array);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    for value in args {
        scratch_root(machine, value);
    }
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    if name == "sum" {
        if args.len > 1 {
            machine.error = VmError.WrongArity;
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        var total = if args.len == 1 {
            args[0]
        } else {
            mrb_fixnum(0)
        };
        scratch_root(machine, total);
        let total_root_index = machine.scratch_roots.len - 1;
        var index = 0;
        while index < length {
            let item = builtin_array_get(machine.pool, machine.scratch, array, index);
            let mapped = vm_invoke_block(machine, closure, self_value, item);
            if machine.error != VmError.Ok {
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            let updated, fault = num_add(machine.scratch, machine.pool, total, mapped);
            if fault != NumFault.Ok {
                machine.error = match fault {
                    Overflow => VmError.IntegerOverflow,
                    Scratch => VmError.ScratchFull,
                    _ => VmError.TypeMismatch,
                };
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            total = updated;
            machine.scratch_roots[total_root_index] = total;
            index += 1;
        }
        scratch_root_end(machine, root_mark);
        return total;
    }
    if args.len != 0 {
        machine.error = VmError.WrongArity;
        scratch_root_end(machine, root_mark);
        return mrb_nil();
    }
    if length == 0 {
        scratch_root_end(machine, root_mark);
        return mrb_nil();
    }
    var result = builtin_array_get(machine.pool, machine.scratch, array, 0);
    scratch_root(machine, result);
    let result_root_index = machine.scratch_roots.len - 1;
    var index = 1;
    while index < length {
        let candidate = builtin_array_get(machine.pool, machine.scratch, array, index);
        let pair: MrbValue[2] = [candidate, result];
        let order_value = vm_invoke_block_args(machine, closure, self_value, pair[..]);
        if machine.error != VmError.Ok {
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        let order, comparable = num_compare(
            machine.scratch, machine.pool, order_value, mrb_fixnum(0)
        );
        if !comparable {
            machine.error = VmError.TypeMismatch;
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        if (name == "min" && order < 0) || (name == "max" && order > 0) {
            result = candidate;
            machine.scratch_roots[result_root_index] = result;
        }
        index += 1;
    }
    scratch_root_end(machine, root_mark);
    return result;
}

recursive fn vm_array_block_ext(
    machine: Vm&, array: MrbValue, name: u8[:], closure: MrbValue,
    self_value: MrbValue, args: MrbValue[:]
) -> MrbValue, bool {
    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, array);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    for value in args {
        scratch_root(machine, value);
    }
    var result = mrb_nil();
    var handled = true;
    if name == "sum" || name == "min" || name == "max" {
        result = vm_array_aggregate_block(machine, array, name, closure, self_value, args);
    } else if name == "each_with_index" {
        result = vm_array_each_with_index(machine, array, closure, self_value);
    } else if name == "find" || name == "detect" {
        result = vm_array_find_block(machine, array, closure, self_value);
    } else if name == "any?" || name == "all?" || name == "count" {
        result = vm_array_match_block(machine, array, name, closure, self_value);
    } else {
        handled = false;
    }
    scratch_root_end(machine, root_mark);
    return result, handled;
}

fn vm_collect_hash_pairs(
    machine: Vm&, hash: MrbValue
) -> MrbValue, MrbValue {
    let keys = builtin_array_new(machine.scratch);
    let vals = builtin_array_new(machine.scratch);
    if mrb_is_scratch(hash) {
        let obj, ok = scratch_object(machine.scratch, hash);
        if ok && obj.kind == ArenaObjectKind.Hash {
            var slot = obj.items_first_index;
            while slot >= 0 {
                let k = machine.scratch.slots[slot].key;
                let v = machine.scratch.slots[slot].value;
                slot = machine.scratch.slots[slot].next_index;
                builtin_array_push(machine.pool, machine.scratch, keys, k);
                builtin_array_push(machine.pool, machine.scratch, vals, v);
            }
        }
    } else if mrb_is_state(hash) {
        let obj, ok = state_object(machine.pool, hash);
        if ok && obj.kind == ArenaObjectKind.Hash {
            var slot = obj.items_first_index;
            while slot >= 0 {
                let k = machine.pool.slots[slot].key;
                let v = machine.pool.slots[slot].value;
                slot = machine.pool.slots[slot].next_index;
                builtin_array_push(machine.pool, machine.scratch, keys, k);
                builtin_array_push(machine.pool, machine.scratch, vals, v);
            }
        }
    }
    return keys, vals;
}

recursive fn vm_hash_each_block(
    machine: Vm&, hash: MrbValue, closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    var slot_index = -1;
    if mrb_is_scratch(hash) {
        let obj, ok = scratch_object(machine.scratch, hash);
        if ok && obj.kind == ArenaObjectKind.Hash {
            slot_index = obj.items_first_index;
        }
    } else if mrb_is_state(hash) {
        let obj, ok = state_object(machine.pool, hash);
        if ok && obj.kind == ArenaObjectKind.Hash {
            slot_index = obj.items_first_index;
        }
    }
    while slot_index >= 0 {
        var key = mrb_nil();
        var value = mrb_nil();
        var next_index = -1;
        if mrb_is_scratch(hash) {
            key = machine.scratch.slots[slot_index].key;
            value = machine.scratch.slots[slot_index].value;
            next_index = machine.scratch.slots[slot_index].next_index;
        } else {
            key = machine.pool.slots[slot_index].key;
            value = machine.pool.slots[slot_index].value;
            next_index = machine.pool.slots[slot_index].next_index;
        }
        let pair: MrbValue[2] = [key, value];
        vm_invoke_block_args(machine, closure, self_value, pair[..]);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        slot_index = next_index;
    }
    return hash;
}

recursive fn vm_hash_select_block(
    machine: Vm&, hash: MrbValue, closure: MrbValue, self_value: MrbValue, keep_truthy: bool
) -> MrbValue {
    let root_mark = scratch_root_begin(machine);
    let keys, vals = vm_collect_hash_pairs(machine, hash);
    scratch_root(machine, keys);
    scratch_root(machine, vals);
    let out = builtin_hash_new(machine.scratch);
    scratch_root(machine, out);
    let len = builtin_array_length(machine.pool, machine.scratch, keys);
    var i = 0;
    while i < len {
        let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
        let v = builtin_array_get(machine.pool, machine.scratch, vals, i);
        let pair: MrbValue[2] = [k, v];
        let res = vm_invoke_block_args(machine, closure, self_value, pair[..]);
        if machine.error != VmError.Ok {
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        if mrb_truthy(res) == keep_truthy {
            builtin_hash_set(machine.pool, machine.scratch, out, k, v);
        }
        i += 1;
    }
    scratch_root_end(machine, root_mark);
    return out;
}

recursive fn vm_hash_map_block(
    machine: Vm&, hash: MrbValue, closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    let root_mark = scratch_root_begin(machine);
    let keys, vals = vm_collect_hash_pairs(machine, hash);
    scratch_root(machine, keys);
    scratch_root(machine, vals);
    let out = builtin_array_new(machine.scratch);
    scratch_root(machine, out);
    let len = builtin_array_length(machine.pool, machine.scratch, keys);
    var i = 0;
    while i < len {
        let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
        let v = builtin_array_get(machine.pool, machine.scratch, vals, i);
        let pair: MrbValue[2] = [k, v];
        let res = vm_invoke_block_args(machine, closure, self_value, pair[..]);
        if machine.error != VmError.Ok {
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        builtin_array_push(machine.pool, machine.scratch, out, res);
        i += 1;
    }
    scratch_root_end(machine, root_mark);
    return out;
}

recursive fn vm_dispatch_hash_block(
    machine: Vm&, hash: MrbValue, name: u8[:], closure: MrbValue, self_value: MrbValue
) -> MrbValue, bool {
    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, hash);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    var result = mrb_nil();
    var handled = true;
    if name == "each" {
        result = vm_hash_each_block(machine, hash, closure, self_value);
    } else if name == "select" || name == "filter" || name == "reject" {
        result = vm_hash_select_block(machine, hash, closure, self_value, name != "reject");
    } else if name == "map" || name == "collect" {
        result = vm_hash_map_block(machine, hash, closure, self_value);
    } else {
        handled = false;
    }
    scratch_root_end(machine, root_mark);
    return result, handled;
}

recursive fn vm_dispatch_block_method(
    machine: Vm&, receiver: MrbValue, symbol: u32, closure: MrbValue,
    self_value: MrbValue, args: MrbValue[:]
) -> MrbValue {
    let name = symbol_name(symbol);
    if vm_is_array_value(machine, receiver) {
        if name == "map" || name == "collect" || name == "each" {
            return vm_iterate_array(machine, receiver, closure, self_value, name != "each");
        }
        if name == "select" || name == "filter" || name == "find_all" || name == "reject" {
            return vm_filter_array(machine, receiver, closure, self_value, name != "reject");
        }
        let ext, ok = vm_array_block_ext(machine, receiver, name, closure, self_value, args);
        if ok {
            return ext;
        }
    }
    if vm_is_hash_value(machine, receiver) {
        let res, ok = vm_dispatch_hash_block(machine, receiver, name, closure, self_value);
        if ok {
            return res;
        }
    }
    if mrb_is_fixnum(receiver) && name == "times" {
        let count = mrb_fixnum_value(receiver);
        var i = 0;
        while i < count {
            vm_invoke_block(machine, closure, self_value, mrb_fixnum(i));
            if machine.error != VmError.Ok {
                return mrb_nil();
            }
            i += 1;
        }
        return receiver;
    }
    machine.error = VmError.NoMethod;
    return mrb_nil();
}
