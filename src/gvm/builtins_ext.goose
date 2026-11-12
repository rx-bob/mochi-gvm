// Extended scalar, String, Array, and Hash intrinsics for the Goose VM.
namespace vm;

import.builtins;
import.collection_arena;
import.rite_types;
import.scratch_alloc;
import.signals;
import.state_pool;
import.value_arena;
import.vm_blocks;
import.vm_core;
import.vm_dispatch;
import.vm_methods;
import.vm_num;

fn builtin_to_s(machine: Vm&, value: MrbValue) -> MrbValue {
    if vm_is_string_value(machine, value) {
        return value;
    }
    var out: u8[>..] = [];
    vm_append_value_text(machine, out, value);
    return scratch_alloc_string(machine.scratch, out[..]);
}

fn builtin_to_i(machine: Vm&, value: MrbValue) -> MrbValue {
    let kind = num_kind(machine.scratch, machine.pool, value);
    if kind == NumKind.Integer {
        return value;
    }
    if kind == NumKind.Float {
        let integer, ok = num_to_i64(machine.scratch, machine.pool, value);
        if !ok {
            machine.error = VmError.FloatDomain;
            return mrb_nil();
        }
        let converted = num_from_i64(machine.scratch, integer);
        if mrb_is_nil(converted) {
            machine.error = VmError.ScratchFull;
        }
        return converted;
    }
    if !vm_is_string_value(machine, value) {
        return mrb_fixnum(0);
    }
    let bytes = builtin_string_bytes(machine.pool, machine.scratch, value);
    var at = 0;
    while at < bytes.len && bytes[at] <= 32 {
        at += 1;
    }
    var negative = false;
    if at < bytes.len && (bytes[at] == 45 || bytes[at] == 43) {
        negative = bytes[at] == 45;
        at += 1;
    }
    let digits_start = at;
    while at < bytes.len && bytes[at] >= 48 && bytes[at] <= 57 {
        at += 1;
    }
    if at == digits_start {
        return mrb_fixnum(0);
    }
    let integer, ok = num_parse_i64_bytes(bytes[digits_start..at], 10, negative);
    if !ok {
        machine.error = VmError.IntegerOverflow;
        return mrb_nil();
    }
    let converted = num_from_i64(machine.scratch, integer);
    if mrb_is_nil(converted) {
        machine.error = VmError.ScratchFull;
    }
    return converted;
}

fn numeric_method_fault(fault: NumFault) -> VmError {
    return match fault {
        Overflow => VmError.IntegerOverflow,
        DivisionByZero => VmError.DivisionByZero,
        Scratch => VmError.ScratchFull,
        _ => VmError.TypeMismatch,
    };
}

fn builtin_number_method(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "zero?" {
        return mrb_bool(num_zero(machine.scratch, machine.pool, receiver)), true;
    }
    if name == "abs" {
        let value, fault = num_abs(machine.scratch, machine.pool, receiver);
        if fault != NumFault.Ok {
            machine.error = numeric_method_fault(fault);
        }
        return value, true;
    }
    if name == "to_f" {
        let float, ok = num_to_f64(machine.scratch, machine.pool, receiver);
        if !ok {
            machine.error = VmError.TypeMismatch;
            return mrb_nil(), true;
        }
        let value = num_from_f64(machine.scratch, float);
        if mrb_is_nil(value) {
            machine.error = VmError.ScratchFull;
        }
        return value, true;
    }
    if name == "even?" || name == "odd?" {
        let integer, ok = num_integer_value(machine.scratch, machine.pool, receiver);
        if !ok {
            return mrb_nil(), false;
        }
        let even = integer % 2 == 0;
        return mrb_bool(if name == "even?" {
                even
            } else {
                !even
            }), true;
    }
    if name == "clamp" && args.len >= 2
        && num_is_number(machine.scratch, machine.pool, args[0])
        && num_is_number(machine.scratch, machine.pool, args[1]) {
        let below, below_ok = num_compare(machine.scratch, machine.pool, receiver, args[0]);
        let above, above_ok = num_compare(machine.scratch, machine.pool, receiver, args[1]);
        if !below_ok || !above_ok {
            machine.error = VmError.TypeMismatch;
            return mrb_nil(), true;
        }
        if below < 0 {
            return args[0], true;
        }
        if above > 0 {
            return args[1], true;
        }
        return receiver, true;
    }
    if name == "-@" {
        let value, fault = num_neg(machine.scratch, machine.pool, receiver);
        if fault != NumFault.Ok {
            machine.error = numeric_method_fault(fault);
        }
        return value, true;
    }
    if args.len < 1 || !num_is_number(machine.scratch, machine.pool, args[0]) {
        return mrb_nil(), false;
    }
    let right = args[0];
    if name == "+" || name == "-" || name == "*" || name == "/" || name == "%" {
        var result: MrbValue = mrb_nil();
        var fault: NumFault = NumFault.Ok;
        if name == "+" {
            result, fault = num_add(machine.scratch, machine.pool, receiver, right);
        } else if name == "-" {
            result, fault = num_sub(machine.scratch, machine.pool, receiver, right);
        } else if name == "*" {
            result, fault = num_mul(machine.scratch, machine.pool, receiver, right);
        } else if name == "/" {
            result, fault = num_div(machine.scratch, machine.pool, receiver, right);
        } else {
            result, fault = num_mod(machine.scratch, machine.pool, receiver, right);
        }
        if fault != NumFault.Ok {
            machine.error = numeric_method_fault(fault);
        }
        return result, true;
    }
    if name == "<" || name == "<=" || name == ">" || name == ">=" {
        let order, comparable = num_compare(machine.scratch, machine.pool, receiver, right);
        var comparison = false;
        if comparable {
            if name == "<" {
                comparison = order < 0;
            } else if name == "<=" {
                comparison = order <= 0;
            } else if name == ">" {
                comparison = order > 0;
            } else {
                comparison = order >= 0;
            }
        }
        return mrb_bool(comparison), true;
    }
    return mrb_nil(), false;
}

fn builtin_string_case_trim(
    machine: Vm&, receiver: MrbValue, name: u8[:]
) -> MrbValue, bool {
    let bytes = builtin_string_bytes(machine.pool, machine.scratch, receiver);
    if name == "upcase" || name == "downcase" {
        var out: u8[>..] = [];
        let up = name == "upcase";
        var i = 0;
        while i < bytes.len {
            var b = bytes[i];
            if up && b >= 97 && b <= 122 {
                b -= 32;
            } else if !up && b >= 65 && b <= 90 {
                b += 32;
            }
            out.push(b);
            i += 1;
        }
        return scratch_alloc_string(machine.scratch, out[..]), true;
    }
    if name == "strip" || name == "lstrip" || name == "rstrip" {
        var start = 0;
        var stop = bytes.len;
        if name != "rstrip" {
            while start < stop && bytes[start] <= 32 {
                start += 1;
            }
        }
        if name != "lstrip" {
            while stop > start && bytes[stop - 1] <= 32 {
                stop -= 1;
            }
        }
        return scratch_alloc_string(machine.scratch, bytes[start..stop]), true;
    }
    if name == "chars" {
        let arr = builtin_array_new(machine.scratch);
        var i = 0;
        while i < bytes.len {
            var char_len = 1;
            let lead = bytes[i];
            if (lead & 0xE0) == 0xC0 {
                char_len = 2;
            } else if (lead & 0xF0) == 0xE0 {
                char_len = 3;
            } else if (lead & 0xF8) == 0xF0 {
                char_len = 4;
            }
            if i + char_len > bytes.len {
                char_len = bytes.len - i;
            }
            let ch = scratch_alloc_string(machine.scratch, bytes[i..(i + char_len)]);
            builtin_array_push(machine.pool, machine.scratch, arr, ch);
            i += char_len;
        }
        return arr, true;
    }
    return mrb_nil(), false;
}

fn builtin_string_split_replace(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let bytes = builtin_string_bytes(machine.pool, machine.scratch, receiver);
    if name == "split" {
        let arr = builtin_array_new(machine.scratch);
        let sep = if args.len > 0 && vm_is_string_value(machine, args[0]) {
            builtin_string_bytes(machine.pool, machine.scratch, args[0])
        } else {
            " "
        };
        if sep.len == 0 {
            return builtin_string_case_trim(machine, receiver, "chars");
        }
        var cursor = 0;
        while cursor <= bytes.len {
            let idx, found = builtin_string_index(machine.pool, machine.scratch,
                receiver, scratch_alloc_string(machine.scratch, sep), cursor);
            if !found {
                let tail = scratch_alloc_string(machine.scratch, bytes[cursor..bytes.len]);
                builtin_array_push(machine.pool, machine.scratch, arr, tail);
                return arr, true;
            }
            let part = scratch_alloc_string(machine.scratch, bytes[cursor..idx]);
            builtin_array_push(machine.pool, machine.scratch, arr, part);
            cursor = idx + sep.len;
        }
        return arr, true;
    }
    if (name == "sub" || name == "gsub") && args.len >= 2 {
        let pat = builtin_string_bytes(machine.pool, machine.scratch, args[0]);
        let rep = builtin_string_bytes(machine.pool, machine.scratch, args[1]);
        if pat.len == 0 {
            return receiver, true;
        }
        var out: u8[>..] = [];
        var cursor = 0;
        let all = name == "gsub";
        while cursor <= bytes.len {
            let idx, found = builtin_string_index(machine.pool, machine.scratch,
                receiver, args[0], cursor);
            if !found {
                out.append(bytes[cursor..bytes.len]);
                return scratch_alloc_string(machine.scratch, out[..]), true;
            }
            out.append(bytes[cursor..idx]);
            out.append(rep);
            cursor = idx + pat.len;
            if !all {
                out.append(bytes[cursor..bytes.len]);
                return scratch_alloc_string(machine.scratch, out[..]), true;
            }
        }
        return scratch_alloc_string(machine.scratch, out[..]), true;
    }
    return mrb_nil(), false;
}

fn builtin_string_ext(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "size" {
        return mrb_fixnum(builtin_string_length(machine.pool, machine.scratch, receiver)), true;
    }
    if name == "+" && args.len >= 1 && vm_is_string_value(machine, args[0]) {
        return vm_concat_text(machine, receiver, args[0]), true;
    }
    if name == "*" && args.len >= 1 && mrb_is_fixnum(args[0]) {
        let res, ok = vm_op_binary_non_fixnum(machine, receiver, args[0], OP_MUL);
        return res, ok;
    }
    if (name == "[]" || name == "slice") && args.len >= 1 && mrb_is_fixnum(args[0]) {
        let start = mrb_fixnum_value(args[0]);
        if args.len >= 2 && mrb_is_fixnum(args[1]) {
            return builtin_string_slice(machine.pool, machine.scratch, receiver,
                start, mrb_fixnum_value(args[1])), true;
        }
        return builtin_get_index(machine.pool, machine.scratch, receiver, args[0]), true;
    }
    if name == "include?" && args.len >= 1 {
        let _, found = builtin_string_index(machine.pool, machine.scratch, receiver, args[0], 0);
        return mrb_bool(found), true;
    }
    if (name == "start_with?" || name == "end_with?") && args.len >= 1 {
        let hay = builtin_string_bytes(machine.pool, machine.scratch, receiver);
        let needle = builtin_string_bytes(machine.pool, machine.scratch, args[0]);
        if needle.len > hay.len {
            return mrb_false(), true;
        }
        if name == "start_with?" {
            return mrb_bool(hay[0..needle.len] == needle), true;
        }
        return mrb_bool(hay[(hay.len - needle.len)..hay.len] == needle), true;
    }
    let trimmed, trim_ok = builtin_string_case_trim(machine, receiver, name);
    if trim_ok {
        return trimmed, true;
    }
    return builtin_string_split_replace(machine, receiver, name, args);
}

fn builtin_array_order_less(machine: Vm&, a: MrbValue, b: MrbValue) -> bool {
    if num_is_number(machine.scratch, machine.pool, a)
        && num_is_number(machine.scratch, machine.pool, b) {
        let order, comparable = num_compare(machine.scratch, machine.pool, a, b);
        return comparable && order < 0;
    }
    let sa = builtin_string_bytes(machine.pool, machine.scratch, a);
    let sb = builtin_string_bytes(machine.pool, machine.scratch, b);
    let min_len = if sa.len < sb.len {
        sa.len
    } else {
        sb.len
    };
    var i = 0;
    while i < min_len {
        if sa[i] != sb[i] {
            return sa[i] < sb[i];
        }
        i += 1;
    }
    return sa.len < sb.len;
}

fn builtin_array_sort_delete(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let len = builtin_array_length(machine.pool, machine.scratch, receiver);
    if name == "sort" {
        let out = builtin_array_new(machine.scratch);
        var i = 0;
        while i < len {
            let item = builtin_array_get(machine.pool, machine.scratch, receiver, i);
            builtin_array_push(machine.pool, machine.scratch, out, item);
            i += 1;
        }
        var a = 0;
        while a < len {
            var b = a + 1;
            while b < len {
                let va = builtin_array_get(machine.pool, machine.scratch, out, a);
                let vb = builtin_array_get(machine.pool, machine.scratch, out, b);
                if builtin_array_order_less(machine, vb, va) {
                    builtin_array_set(machine.pool, machine.scratch, out, a, vb);
                    builtin_array_set(machine.pool, machine.scratch, out, b, va);
                }
                b += 1;
            }
            a += 1;
        }
        return out, true;
    }
    if name == "delete" && args.len >= 1 {
        let target = args[0];
        var kept: MrbValue[>..] = [];
        var removed = mrb_nil();
        var i = 0;
        while i < len {
            let el = builtin_array_get(machine.pool, machine.scratch, receiver, i);
            if vm_values_equal(machine, el, target) {
                removed = el;
            } else {
                kept.push(el);
            }
            i += 1;
        }
        while builtin_array_length(machine.pool, machine.scratch, receiver) > 0 {
            builtin_array_pop(machine.pool, machine.scratch, receiver);
        }
        for item in kept {
            builtin_array_push(machine.pool, machine.scratch, receiver, item);
        }
        return removed, true;
    }
    return mrb_nil(), false;
}

fn builtin_array_ext(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let len = builtin_array_length(machine.pool, machine.scratch, receiver);
    if name == "size" || (name == "count" && args.len == 0) {
        return mrb_fixnum(len), true;
    }
    if name == "count" && args.len >= 1 {
        var matched = 0;
        var i = 0;
        while i < len {
            if vm_values_equal(machine,
                builtin_array_get(machine.pool, machine.scratch, receiver, i), args[0]) {
                matched += 1;
            }
            i += 1;
        }
        return mrb_fixnum(matched), true;
    }
    if name == "first" {
        return builtin_array_get(machine.pool, machine.scratch, receiver, 0), true;
    }
    if name == "include?" && args.len >= 1 {
        var i = 0;
        while i < len {
            if vm_values_equal(machine,
                builtin_array_get(machine.pool, machine.scratch, receiver, i), args[0]) {
                return mrb_true(), true;
            }
            i += 1;
        }
        return mrb_false(), true;
    }
    if name == "reverse" || name == "compact" {
        let out = builtin_array_new(machine.scratch);
        var i = 0;
        while i < len {
            let idx = if name == "reverse" {
                len - 1 - i
            } else {
                i
            };
            let el = builtin_array_get(machine.pool, machine.scratch, receiver, idx);
            if name != "compact" || !mrb_is_nil(el) {
                builtin_array_push(machine.pool, machine.scratch, out, el);
            }
            i += 1;
        }
        return out, true;
    }
    if name == "clear" {
        while builtin_array_length(machine.pool, machine.scratch, receiver) > 0 {
            builtin_array_pop(machine.pool, machine.scratch, receiver);
        }
        return receiver, true;
    }
    if (name == "concat" || name == "+") && args.len >= 1 && vm_is_array_value(machine, args[0]) {
        if name == "+" {
            return vm_op_binary_non_fixnum(machine, receiver, args[0], OP_ADD);
        }
        let other_len = builtin_array_length(machine.pool, machine.scratch, args[0]);
        var i = 0;
        while i < other_len {
            builtin_array_push(machine.pool, machine.scratch, receiver,
                builtin_array_get(machine.pool, machine.scratch, args[0], i));
            i += 1;
        }
        return receiver, true;
    }
    return builtin_array_sort_delete(machine, receiver, name, args);
}

fn builtin_hash_ext(
    machine: Vm&, receiver: MrbValue, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "size" {
        return mrb_fixnum(builtin_hash_length(machine.pool, machine.scratch, receiver)), true;
    }
    let keys, vals = vm_collect_hash_pairs(machine, receiver);
    let len = builtin_array_length(machine.pool, machine.scratch, keys);
    if name == "keys" {
        return keys, true;
    }
    if name == "values" {
        return vals, true;
    }
    if (name == "has_key?" || name == "key?" || name == "include?") && args.len >= 1 {
        var i = 0;
        while i < len {
            let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
            if builtin_hash_key_equal(machine.pool, machine.scratch, k, args[0]) {
                return mrb_true(), true;
            }
            i += 1;
        }
        return mrb_false(), true;
    }
    if name == "fetch" && args.len >= 1 {
        let got = builtin_hash_get(machine.pool, machine.scratch, receiver, args[0]);
        if !mrb_is_nil(got) {
            return got, true;
        }
        if args.len >= 2 {
            return args[1], true;
        }
        return mrb_nil(), true;
    }
    if name == "merge" && args.len >= 1 && vm_is_hash_value(machine, args[0]) {
        let out = builtin_hash_new(machine.scratch);
        var i = 0;
        while i < len {
            builtin_hash_set(machine.pool, machine.scratch, out,
                builtin_array_get(machine.pool, machine.scratch, keys, i),
                builtin_array_get(machine.pool, machine.scratch, vals, i));
            i += 1;
        }
        let okeys, ovals = vm_collect_hash_pairs(machine, args[0]);
        let olen = builtin_array_length(machine.pool, machine.scratch, okeys);
        i = 0;
        while i < olen {
            builtin_hash_set(machine.pool, machine.scratch, out,
                builtin_array_get(machine.pool, machine.scratch, okeys, i),
                builtin_array_get(machine.pool, machine.scratch, ovals, i));
            i += 1;
        }
        return out, true;
    }
    if name == "delete" && args.len >= 1 {
        let removed = builtin_hash_get(machine.pool, machine.scratch, receiver, args[0]);
        builtin_hash_delete(machine, receiver, args[0]);
        return removed, true;
    }
    return mrb_nil(), false;
}

fn builtin_hash_delete(machine: Vm&, hash: MrbValue, key: MrbValue) {
    let keys, vals = vm_collect_hash_pairs(machine, hash);
    let len = builtin_array_length(machine.pool, machine.scratch, keys);
    if mrb_is_scratch(hash) {
        let idx = mrb_arena_index(hash)as i64;
        machine.scratch.objects[idx].items_first_index = -1;
        machine.scratch.objects[idx].items_last_index = -1;
        machine.scratch.objects[idx].item_count = 0;
    } else if mrb_is_state(hash) {
        let idx = mrb_arena_index(hash)as i64;
        machine.pool.objects[idx].items_first_index = -1;
        machine.pool.objects[idx].items_last_index = -1;
        machine.pool.objects[idx].item_count = 0;
        state_mark_collection_mutated(machine.pool, hash);
    }
    var i = 0;
    while i < len {
        let k = builtin_array_get(machine.pool, machine.scratch, keys, i);
        if !builtin_hash_key_equal(machine.pool, machine.scratch, k, key) {
            builtin_hash_set(machine.pool, machine.scratch, hash, k,
                builtin_array_get(machine.pool, machine.scratch, vals, i));
        }
        i += 1;
    }
}
