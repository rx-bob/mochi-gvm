// Block invocation and Array/Hash/Integer iteration for SENDB and SSENDB.
namespace vm;

import.builtins;
import.collection_arena;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_methods;
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
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    let mapped = builtin_array_new(machine.scratch);
    var index = 0;
    while index < length {
        let element = builtin_array_get(machine.pool, machine.scratch, array, index);
        let result = vm_invoke_block(machine, closure, self_value, element);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        if collect {
            if !builtin_array_push(machine.pool, machine.scratch, mapped, result) {
                machine.error = VmError.TypeMismatch;
                return mrb_nil();
            }
        }
        index += 1;
    }
    if collect {
        return mapped;
    }
    return array;
}

recursive fn vm_filter_array(
    machine: Vm&, array: MrbValue, closure: MrbValue, self_value: MrbValue, keep_truthy: bool
) -> MrbValue {
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    let out = builtin_array_new(machine.scratch);
    var index = 0;
    while index < length {
        let element = builtin_array_get(machine.pool, machine.scratch, array, index);
        let result = vm_invoke_block(machine, closure, self_value, element);
        if machine.error != VmError.Ok {
            return mrb_nil();
        }
        if mrb_truthy(result) == keep_truthy {
            builtin_array_push(machine.pool, machine.scratch, out, element);
        }
        index += 1;
    }
    return out;
}

recursive fn vm_array_block_ext(
    machine: Vm&, array: MrbValue, name: u8[:], closure: MrbValue, self_value: MrbValue
) -> MrbValue, bool {
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    if name == "each_with_index" {
        var i = 0;
        while i < length {
            let el = builtin_array_get(machine.pool, machine.scratch, array, i);
            let pair: MrbValue[2] = [el, mrb_fixnum(i)];
            vm_invoke_block_args(machine, closure, self_value, pair[..]);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            i += 1;
        }
        return array, true;
    }
    if name == "find" || name == "detect" {
        var i = 0;
        while i < length {
            let el = builtin_array_get(machine.pool, machine.scratch, array, i);
            let res = vm_invoke_block(machine, closure, self_value, el);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            if mrb_truthy(res) {
                return el, true;
            }
            i += 1;
        }
        return mrb_nil(), true;
    }
    if name == "any?" || name == "all?" || name == "count" {
        var matched = 0;
        var i = 0;
        while i < length {
            let el = builtin_array_get(machine.pool, machine.scratch, array, i);
            let res = vm_invoke_block(machine, closure, self_value, el);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            if mrb_truthy(res) {
                matched += 1;
                if name == "any?" {
                    return mrb_true(), true;
                }
            } else if name == "all?" {
                return mrb_false(), true;
            }
            i += 1;
        }
        if name == "any?" {
            return mrb_false(), true;
        }
        if name == "all?" {
            return mrb_true(), true;
        }
        return mrb_fixnum(matched), true;
    }
    return mrb_nil(), false;
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

recursive fn vm_dispatch_hash_block(
    machine: Vm&, hash: MrbValue, name: u8[:], closure: MrbValue, self_value: MrbValue
) -> MrbValue, bool {
    let keys, vals = vm_collect_hash_pairs(machine, hash);
    let len = builtin_array_length(machine.pool, machine.scratch, keys);
    if name == "each" {
        var i = 0;
        while i < len {
            let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
            let v = builtin_array_get(machine.pool, machine.scratch, vals, i);
            let pair: MrbValue[2] = [k, v];
            vm_invoke_block_args(machine, closure, self_value, pair[..]);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            i += 1;
        }
        return hash, true;
    }
    if name == "select" || name == "filter" || name == "reject" {
        let keep_truthy = name != "reject";
        let out = builtin_hash_new(machine.scratch);
        var i = 0;
        while i < len {
            let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
            let v = builtin_array_get(machine.pool, machine.scratch, vals, i);
            let pair: MrbValue[2] = [k, v];
            let res = vm_invoke_block_args(machine, closure, self_value, pair[..]);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            if mrb_truthy(res) == keep_truthy {
                builtin_hash_set(machine.pool, machine.scratch, out, k, v);
            }
            i += 1;
        }
        return out, true;
    }
    if name == "map" || name == "collect" {
        let out = builtin_array_new(machine.scratch);
        var i = 0;
        while i < len {
            let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
            let v = builtin_array_get(machine.pool, machine.scratch, vals, i);
            let pair: MrbValue[2] = [k, v];
            let res = vm_invoke_block_args(machine, closure, self_value, pair[..]);
            if machine.error != VmError.Ok {
                return mrb_nil(), true;
            }
            builtin_array_push(machine.pool, machine.scratch, out, res);
            i += 1;
        }
        return out, true;
    }
    return mrb_nil(), false;
}

recursive fn vm_dispatch_block_method(
    machine: Vm&, receiver: MrbValue, symbol: u32, closure: MrbValue, self_value: MrbValue
) -> MrbValue {
    let name = symbol_name(symbol);
    if vm_is_array_value(machine, receiver) {
        if name == "map" || name == "collect" || name == "each" {
            return vm_iterate_array(machine, receiver, closure, self_value, name != "each");
        }
        if name == "select" || name == "filter" || name == "find_all" || name == "reject" {
            return vm_filter_array(machine, receiver, closure, self_value, name != "reject");
        }
        let ext, ok = vm_array_block_ext(machine, receiver, name, closure, self_value);
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
