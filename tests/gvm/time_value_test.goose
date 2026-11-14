namespace time_value_test;

import goosetest;
import vm;

fn test_time_values_follow_existing_gc_roots(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    vm::state_define_class(pool, vm::intern_symbol("Time"), vm::NULL_CLASS_ID);
    for index in 0..100 {
        let args: vm::MrbValue[1] = [vm::scratch_alloc_float(scratch, -1.25)];
        let instant = vm::time_at(machine, args[..]);
        machine.entry_args.push(instant);
        vm::scratch_reset(scratch);
        vm::gc_collect(machine);
        t.assert_eq(2, vm::state_allocated_object_count(pool));
        let stored = vm::state_get_ivar(pool, instant, vm::intern_symbol("@seconds"));
        let value, found = vm::num_float_value(scratch, pool, stored);
        t.assert_true(found);
        t.assert_eq(-1.25, value);
        machine.entry_args.clear();
        vm::gc_collect(machine);
        t.assert_eq(0, vm::state_allocated_object_count(pool));
    }
    t.assert_eq(0, vm::state_component_count(pool));
}

fn test_time_preserves_seconds_without_mounting(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("Time"), vm::NULL_CLASS_ID);
    let values: f64[..6] = [0.0, -1.25, 1794571200.123, -0.0001, -8640000000000.0, 8640000000000.0];
    for seconds in values {
        let args: vm::MrbValue[1] = [vm::scratch_alloc_float(scratch, seconds)];
        let instant = vm::time_at(machine, args[..]);
        t.assert_eq(vm::VmError.Ok, machine.error);
        let object, found = vm::state_object(pool, instant);
        t.assert_true(found);
        t.assert_eq(class_id, object.class_index);
        let stored = vm::state_get_ivar(pool, instant, vm::intern_symbol("@seconds"));
        vm::scratch_reset(scratch);
        let actual, numeric = vm::num_float_value(scratch, pool, stored);
        t.assert_true(numeric);
        t.assert_eq(seconds, actual);
    }
    t.assert_eq(0, vm::state_component_count(pool));
    pool.computed_depth = 1;
    let args: vm::MrbValue[1] = [vm::num_from_i64(scratch, -8640000000000)];
    let instant, handled = vm::vm_call_mochi_builtin(machine, "time_at", args[..]);
    t.assert_true(handled);
    t.assert_eq(vm::VmError.Ok, machine.error);
    let stored = vm::state_get_ivar(pool, instant, vm::intern_symbol("@seconds"));
    let actual, numeric = vm::num_integer_value(scratch, pool, stored);
    t.assert_true(numeric);
    t.assert_eq(-8640000000000, actual);
}

fn test_time_rejects_arguments_before_allocating(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    vm::state_define_class(pool, vm::intern_symbol("Time"), vm::NULL_CLASS_ID);
    var args: vm::MrbValue[..2] = [];
    vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.WrongArity, machine.error);
    args.push(vm::mrb_nil());
    machine.error = vm::VmError.Ok;
    vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.TimeType, machine.error);
    args[0] = vm::scratch_alloc_string(scratch, "1");
    machine.error = vm::VmError.Ok;
    vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.TimeType, machine.error);
    args[0] = vm::num_from_i64(scratch, 8640000000001);
    machine.error = vm::VmError.Ok;
    vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.TimeRange, machine.error);
    let infinite, ok = vm::json_parse_float_text(scratch, "Infinity");
    t.assert_true(ok);
    args[0] = infinite;
    machine.error = vm::VmError.Ok;
    vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.FloatDomain, machine.error);
    t.assert_eq(0, pool.objects.len);
    args[0] = vm::mrb_fixnum(-1);
    machine.error = vm::VmError.Ok;
    let valid = vm::time_at(machine, args[..]);
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::mrb_is_state(valid));
}
