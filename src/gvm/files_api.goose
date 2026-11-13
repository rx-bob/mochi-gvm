namespace vm;

import.json_args;
import.signals;
import.vm_methods;

fn files_current_component_instance(machine: Vm&) -> MrbValue, bool {
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

fn files_api_command(command: u8[:], handle: u8[:], out: u8[>..]&, instance: MrbValue) -> MrbValue {
    out.append("{\"__host\":\"");
    out.append(command);
    out.append("\",\"instance\":\"");
    mrb_format_fixnum(out, instance as!i64);
    out.append("\",\"handle\":");
    out.push(34);
    binding_json_escape(out, handle);
    out.append("\"}\n");
    return mrb_true();
}

fn files_api_dispatch(
    machine: Vm&, name: u8[:], args: MrbValue[:], out: u8[>..]&
) -> MrbValue, bool {
    if name != "file_release" && name != "file_reader_open" && name != "file_reader_close" {
        return mrb_nil(), false;
    }
    if args.len != 1 {
        machine.error = VmError.WrongArity;
        return mrb_nil(), true;
    }
    if !vm_is_string_value(machine, args[0]) {
        machine.error = VmError.TypeMismatch;
        return mrb_nil(), true;
    }
    let handle = vm_string_value(machine, args[0]);
    if handle.len == 0 || handle.len > 256 {
        machine.error = VmError.TypeMismatch;
        return mrb_nil(), true;
    }
    let instance, found = files_current_component_instance(machine);
    if !found {
        machine.error = VmError.TypeMismatch;
        return mrb_nil(), true;
    }
    let command = if name == "file_reader_open" {
        "file_reader_open"
    } else if name == "file_reader_close" {
        "file_reader_close"
    } else {
        "file_release"
    };
    return files_api_command(command, handle, out, instance), true;
}
