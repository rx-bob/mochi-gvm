namespace vm;

import.drag_validation;
import.json_args;
import.signals;
import.vm_methods;

fn drag_current_component_instance(machine: Vm&) -> MrbValue, bool {
    var frame_index = machine.frames.len - 1;
    while frame_index >= 0 {
        let candidate = machine.frames[frame_index].self_value;
        for component in machine.pool.components {
            if mrb_value_identical(candidate, component) {
                return candidate, true;
            }
        }
        frame_index -= 1;
    }
    return mrb_nil(), false;
}

fn drag_append_quoted(out: u8[>..]&, text: const u8[:]) {
    out.push(34);
    binding_json_escape(out, text);
    out.push(34);
}

fn drag_append_value(machine: Vm&, out: u8[>..]&, value: MrbValue) -> bool {
    var items: i64 = 0;
    if !drag_value_valid(machine, value, 0, items) {
        machine.error = VmError.TypeMismatch;
        return false;
    }
    var json: u8[>..] = [];
    binding_json_append_value(machine, json, value, 0);
    if json.len > 8192 {
        machine.error = VmError.StateCapacity;
        return false;
    }
    out.append(",\"value\":");
    out.append(json[..]);
    return true;
}

fn drag_append_effect(machine: Vm&, out: u8[>..]&, effect: MrbValue) -> bool {
    if !vm_is_string_value(machine, effect) {
        machine.error = VmError.TypeMismatch;
        return false;
    }
    let text = vm_string_value(machine, effect);
    if text != "copy" && text != "move" && text != "link" {
        machine.error = VmError.TypeMismatch;
        return false;
    }
    out.append(",\"effect\":");
    drag_append_quoted(out, text);
    return true;
}

fn drag_api_command(
    machine: Vm&, name: u8[:], args: MrbValue[:], out: u8[>..]&, instance: MrbValue
) -> MrbValue {
    let expected = if name == "drag_accept" {
        2
    } else {
        1
    };
    if args.len != expected {
        machine.error = VmError.WrongArity;
        return mrb_nil();
    }
    out.append("{\"__host\":");
    drag_append_quoted(out, name);
    out.append(",\"instance\":\"");
    mrb_format_fixnum(out, instance as!i64);
    out.append("\",\"type\":");
    if name == "drag_accept" {
        if !vm_is_string_value(machine, args[0]) {
            machine.error = VmError.TypeMismatch;
            return mrb_nil();
        }
        let accepted_type = vm_string_value(machine, args[0]);
        if accepted_type.len == 0 || accepted_type.len > 128 {
            machine.error = VmError.TypeMismatch;
            return mrb_nil();
        }
        drag_append_quoted(out, accepted_type);
    } else if name == "drag_set_text" {
        drag_append_quoted(out, "text/plain");
    } else {
        drag_append_quoted(out, "application/vnd.mochi.value+json");
    }
    if name == "drag_set_data" {
        if !drag_append_value(machine, out, args[0]) {
            return mrb_nil();
        }
    } else if name == "drag_set_text" {
        if !vm_is_string_value(machine, args[0]) {
            machine.error = VmError.TypeMismatch;
            return mrb_nil();
        }
        if !drag_append_value(machine, out, args[0]) {
            return mrb_nil();
        }
    } else if !drag_append_effect(machine, out, args[1]) {
        return mrb_nil();
    }
    out.append("}\n");
    return mrb_true();
}

fn drag_api_dispatch(
    machine: Vm&, name: u8[:], args: MrbValue[:], out: u8[>..]&
) -> MrbValue, bool {
    if name != "drag_set_data" && name != "drag_set_text" && name != "drag_accept" {
        return mrb_nil(), false;
    }
    let instance, found = drag_current_component_instance(machine);
    if !found {
        machine.error = VmError.TypeMismatch;
        return mrb_nil(), true;
    }
    return drag_api_command(machine, name, args, out, instance), true;
}
