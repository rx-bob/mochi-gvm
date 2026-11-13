// Block invocation and Array/Hash/Integer iteration for SENDB and SSENDB.
namespace vm;

import.builtins;
import.capacity_config;
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

// Compares supported Array sort keys using Ruby's numeric and String order.
fn vm_sort_key_compare(machine: Vm&, left: MrbValue, right: MrbValue) -> i64, bool {
    if num_is_number(machine.scratch, machine.pool, left)
        && num_is_number(machine.scratch, machine.pool, right) {
        return num_compare(machine.scratch, machine.pool, left, right);
    }
    if vm_is_string_value(machine, left) && vm_is_string_value(machine, right) {
        let a = builtin_string_bytes(machine.pool, machine.scratch, left);
        let b = builtin_string_bytes(machine.pool, machine.scratch, right);
        var index = 0;
        while index < a.len && index < b.len {
            if a[index] < b[index] {
                return -1, true;
            }
            if a[index] > b[index] {
                return 1, true;
            }
            index += 1;
        }
        if a.len < b.len {
            return -1, true;
        }
        if a.len > b.len {
            return 1, true;
        }
        return 0, true;
    }
    return 0, false;
}

recursive fn vm_sort_compare(
    machine: Vm&, left: MrbValue, right: MrbValue, closure: MrbValue,
    self_value: MrbValue, comparator_block: bool
) -> i64, bool {
    if !comparator_block {
        let order, comparable = vm_sort_key_compare(machine, left, right);
        if !comparable {
            machine.error = VmError.TypeMismatch;
        }
        return order, comparable;
    }
    let pair: MrbValue[2] = [left, right];
    let result = vm_invoke_block_args(machine, closure, self_value, pair[..]);
    if machine.error != VmError.Ok {
        return 0, false;
    }
    let order, comparable = num_compare(machine.scratch, machine.pool, result, mrb_fixnum(0));
    if !comparable {
        machine.error = VmError.TypeMismatch;
        return 0, false;
    }
    return order, true;
}

// Bottom-up linked-list merge sort keeps workspace proportional to the
// returned array and avoids indexed access over Mochi's linked-list arrays.
recursive fn vm_sort_merge_runs(
    machine: Vm&, result: MrbValue, keys_array: MrbValue, by_key: bool,
    closure: MrbValue, self_value: MrbValue, comparator_block: bool, length: i64
) -> bool {
    let result_index = mrb_arena_index(result)as i64;
    let keys_index = if by_key {
        mrb_arena_index(keys_array)as i64
    } else {
        -1
    };
    var width = 1;
    while width < length {
        var current_value = machine.scratch.objects[result_index].items_first_index;
        var current_key = if by_key {
            machine.scratch.objects[keys_index].items_first_index
        } else {
            -1
        };
        var result_first = -1;
        var result_last = -1;
        var keys_first = -1;
        var keys_last = -1;
        var remaining = length;
        while remaining > 0 {
            let left_count = if remaining < width {
                remaining
            } else {
                width
            };
            let right_count = if remaining - left_count < width {
                remaining - left_count
            } else {
                width
            };
            var left_value = current_value;
            var left_key = current_key;
            var after_left_value = current_value;
            var after_left_key = current_key;
            var advance = 0;
            while advance < left_count {
                after_left_value = machine.scratch.slots[after_left_value].next_index;
                if by_key {
                    after_left_key = machine.scratch.slots[after_left_key].next_index;
                }
                advance += 1;
            }
            var right_value = after_left_value;
            var right_key = after_left_key;
            var next_run_value = right_value;
            var next_run_key = right_key;
            advance = 0;
            while advance < right_count {
                next_run_value = machine.scratch.slots[next_run_value].next_index;
                if by_key {
                    next_run_key = machine.scratch.slots[next_run_key].next_index;
                }
                advance += 1;
            }
            var left_remaining = left_count;
            var right_remaining = right_count;
            while left_remaining > 0 || right_remaining > 0 {
                var take_left = false;
                if right_remaining == 0 {
                    take_left = true;
                } else if left_remaining > 0 {
                    let left_value_key = if by_key {
                        machine.scratch.slots[left_key].value
                    } else {
                        machine.scratch.slots[left_value].value
                    };
                    let right_value_key = if by_key {
                        machine.scratch.slots[right_key].value
                    } else {
                        machine.scratch.slots[right_value].value
                    };
                    let order, comparable = vm_sort_compare(
                        machine, left_value_key, right_value_key, closure, self_value, comparator_block
                    );
                    if !comparable {
                        return false;
                    }
                    take_left = order <= 0;
                }
                var selected_value = -1;
                var selected_key = -1;
                if take_left {
                    selected_value = left_value;
                    left_value = machine.scratch.slots[left_value].next_index;
                    if by_key {
                        selected_key = left_key;
                        left_key = machine.scratch.slots[left_key].next_index;
                    }
                    left_remaining -= 1;
                } else {
                    selected_value = right_value;
                    right_value = machine.scratch.slots[right_value].next_index;
                    if by_key {
                        selected_key = right_key;
                        right_key = machine.scratch.slots[right_key].next_index;
                    }
                    right_remaining -= 1;
                }
                machine.scratch.slots[selected_value].previous_index = result_last;
                machine.scratch.slots[selected_value].next_index = -1;
                if result_last >= 0 {
                    machine.scratch.slots[result_last].next_index = selected_value;
                } else {
                    result_first = selected_value;
                }
                result_last = selected_value;
                if by_key {
                    machine.scratch.slots[selected_key].previous_index = keys_last;
                    machine.scratch.slots[selected_key].next_index = -1;
                    if keys_last >= 0 {
                        machine.scratch.slots[keys_last].next_index = selected_key;
                    } else {
                        keys_first = selected_key;
                    }
                    keys_last = selected_key;
                }
            }
            current_value = next_run_value;
            current_key = next_run_key;
            remaining -= left_count + right_count;
        }
        machine.scratch.objects[result_index].items_first_index = result_first;
        machine.scratch.objects[result_index].items_last_index = result_last;
        if by_key {
            machine.scratch.objects[keys_index].items_first_index = keys_first;
            machine.scratch.objects[keys_index].items_last_index = keys_last;
        }
        width *= 2;
    }
    return true;
}

recursive fn vm_array_sort_block(
    machine: Vm&, array: MrbValue, name: u8[:], closure: MrbValue,
    self_value: MrbValue, args: MrbValue[:]
) -> MrbValue {
    if args.len != 0 {
        machine.error = VmError.WrongArity;
        return mrb_nil();
    }
    if name != "sort" && name != "sort_by" {
        machine.error = VmError.NoMethod;
        return mrb_nil();
    }

    let root_mark = scratch_root_begin(machine);
    scratch_root(machine, array);
    scratch_root(machine, closure);
    scratch_root(machine, self_value);
    let length = builtin_array_length(machine.pool, machine.scratch, array);
    if length > SCRATCH_CAPACITY_SLOTS / 2 {
        machine.error = VmError.ScratchFull;
        scratch_root_end(machine, root_mark);
        return mrb_nil();
    }
    let by_key = name == "sort_by";
    let result = builtin_array_new(machine.scratch);
    if mrb_is_nil(result) {
        machine.error = VmError.ScratchFull;
        scratch_root_end(machine, root_mark);
        return mrb_nil();
    }
    scratch_root(machine, result);
    let source = if mrb_is_scratch(array) {
        let object, ok = scratch_object(machine.scratch, array);
        if !ok || object.kind != ArenaObjectKind.Array {
            machine.error = VmError.TypeMismatch;
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        var slot = object.items_first_index;
        while slot >= 0 {
            if !builtin_array_push(
                machine.pool, machine.scratch, result, machine.scratch.slots[slot].value
            ) {
                machine.error = VmError.ScratchFull;
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            slot = machine.scratch.slots[slot].next_index;
        }
        true
    } else {
        let object, ok = state_object(machine.pool, array);
        if !ok || object.kind != ArenaObjectKind.Array {
            machine.error = VmError.TypeMismatch;
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        var slot = object.items_first_index;
        while slot >= 0 {
            if !builtin_array_push(
                machine.pool, machine.scratch, result, machine.pool.slots[slot].value
            ) {
                machine.error = VmError.ScratchFull;
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            slot = machine.pool.slots[slot].next_index;
        }
        true
    };
    if !source || builtin_array_length(machine.pool, machine.scratch, result) != length {
        machine.error = VmError.TypeMismatch;
        scratch_root_end(machine, root_mark);
        return mrb_nil();
    }

    var keys = mrb_nil();
    if by_key {
        keys = builtin_array_new(machine.scratch);
        if mrb_is_nil(keys) {
            machine.error = VmError.ScratchFull;
            scratch_root_end(machine, root_mark);
            return mrb_nil();
        }
        scratch_root(machine, keys);
        let object_index = mrb_arena_index(result)as i64;
        var slot = machine.scratch.objects[object_index].items_first_index;
        while slot >= 0 {
            let key = vm_invoke_block(
                machine, closure, self_value, machine.scratch.slots[slot].value
            );
            if machine.error != VmError.Ok {
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            if !builtin_array_push(machine.pool, machine.scratch, keys, key) {
                machine.error = VmError.ScratchFull;
                scratch_root_end(machine, root_mark);
                return mrb_nil();
            }
            slot = machine.scratch.slots[slot].next_index;
        }
    }

    if length > 1 && !vm_sort_merge_runs(
        machine, result, keys, by_key, closure, self_value, name == "sort", length
    ) {
        scratch_root_end(machine, root_mark);
        return mrb_nil();
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
    if name == "sort" || name == "sort_by" {
        result = vm_array_sort_block(machine, array, name, closure, self_value, args);
    } else if name == "sum" || name == "min" || name == "max" {
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
