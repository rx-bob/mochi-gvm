// Block invocation and Array#map/#each iteration for SENDB.
namespace vm;

import.builtins;
import.value_arena;
import.vm_core;
import.vm_ops;

recursive fn vm_invoke_block(
    machine: Vm&, closure: MrbValue, self_value: MrbValue, argument: MrbValue
) -> MrbValue {
    if !mrb_is_block(closure) {
        machine.error = VmError.TypeMismatch;
        return mrb_nil();
    }
    let record_index = mrb_block_record_index(closure);
    let args: MrbValue[1] = [argument];
    return vm_exec_with_args(machine, record_index, self_value, -1, args[..]);
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
