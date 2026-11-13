namespace vm;

import.signals;
import.vm_methods;
import.vm_num;

recursive fn drag_array_valid(machine: Vm&, value: MrbValue, depth: i64, items: i64&) -> bool {
    for index in 0..binding_array_length(machine, value) {
        let item, found = binding_array_get(machine, value, index);
        if !found || !drag_value_valid(machine, item, depth + 1, items) {
            return false;
        }
    }
    return true;
}

recursive fn drag_hash_valid(machine: Vm&, value: MrbValue, depth: i64, items: i64&) -> bool {
    for position in 0..binding_hash_length(machine, value) {
        let slot = binding_hash_slot_index(machine, value, position);
        if slot < 0 {
            continue;
        }
        let key = binding_hash_slot_key(machine, value, slot);
        if !mrb_is_symbol(key) && !vm_is_string_value(machine, key) {
            return false;
        }
        if !drag_value_valid(machine, binding_hash_slot_value(machine, value, slot), depth + 1, items) {
            return false;
        }
    }
    return true;
}

recursive fn drag_value_valid(machine: Vm&, value: MrbValue, depth: i64, items: i64&) -> bool {
    if depth > 32 {
        return false;
    }
    items += 1;
    if items > 4096 {
        return false;
    }
    if binding_value_is_array(machine, value) {
        return drag_array_valid(machine, value, depth, items);
    }
    if binding_value_is_hash(machine, value) {
        return drag_hash_valid(machine, value, depth, items);
    }
    if mrb_is_nil(value) || mrb_is_true(value) || mrb_is_false(value) ||
    mrb_is_fixnum(value) || mrb_is_int64(value) || vm_is_string_value(machine, value) {
        return true;
    }
    if mrb_is_float(value) {
        let _, ok = num_float_value(machine.scratch, machine.pool, value);
        return ok;
    }
    return false;
}
