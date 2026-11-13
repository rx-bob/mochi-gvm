// Global event payloads must survive transport without lossy binding coercion.
namespace vm;

import math;

import.builtins;
import.capacity_config;
import.signals;
import.vm_methods;
import.vm_num;

recursive fn event_payload_value_ok(machine: Vm&, value: MrbValue, depth: i64, remaining: i64&) -> bool {
    if depth > MAX_JSON_DEPTH || remaining <= 0 {
        return false;
    }
    remaining -= 1;
    if binding_value_is_array(machine, value) {
        for index in 0..binding_array_length(machine, value) {
            let item, found = binding_array_get(machine, value, index);
            if !found || !event_payload_value_ok(machine, item, depth + 1, remaining) {
                return false;
            }
        }
        return true;
    }
    if binding_value_is_hash(machine, value) {
        for index in 0..binding_hash_length(machine, value) {
            let slot = binding_hash_slot_index(machine, value, index);
            if slot < 0 {
                return false;
            }
            let key = binding_hash_slot_key(machine, value, slot);
            let _, key_ok = builtin_hash_key_text(machine.pool, machine.scratch, key);
            if !key_ok || !event_payload_value_ok(
                machine, binding_hash_slot_value(machine, value, slot), depth + 1, remaining
            ) {
                return false;
            }
        }
        return true;
    }
    if mrb_is_int64(value) {
        let _, ok = num_integer_value(machine.scratch, machine.pool, value);
        return ok;
    }
    if mrb_is_float(value) {
        let number, ok = num_float_value(machine.scratch, machine.pool, value);
        return ok && number == number && number != INF && number != -INF;
    }
    return mrb_is_nil(value) || mrb_is_true(value) || mrb_is_false(value) ||
    mrb_is_fixnum(value) || mrb_is_symbol(value) || vm_is_string_value(machine, value);
}

fn event_payload_valid(machine: Vm&, value: MrbValue) -> bool {
    // Every transported node needs at least one byte. This bound also stops
    // repeated aliases/cycles from causing exponential validation work.
    var remaining: i64 = HOST_OUTBOX_CAPACITY;
    return event_payload_value_ok(machine, value, 0, remaining);
}
