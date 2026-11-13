// Tests for block invocation guards.
namespace vm_blocks_test;

import std;

import goosetest;
import vm;

fn test_iterate_requires_block(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let array = vm::builtin_array_new(scratch);
    t.assert_true(vm::builtin_array_push(pool, scratch, array, vm::mrb_nil()));
    let result = vm::vm_iterate_array(machine, array, vm::mrb_nil(), vm::mrb_nil(), true);
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}

fn test_invoke_block_requires_block(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let result = vm::vm_invoke_block(machine, vm::mrb_nil(), vm::mrb_nil(), vm::mrb_nil());
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
}

fn test_empty_array_aggregates(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let array = vm::builtin_array_new(scratch);
    let no_args: vm::MrbValue[0] = [];
    let sum = vm::vm_dispatch_block_method(
        machine, array, vm::intern_symbol("sum"), vm::mrb_nil(), vm::mrb_nil(), no_args[..]
    );
    t.assert_eq(0, vm::mrb_fixnum_value(sum));
    let initial: vm::MrbValue[1] = [vm::mrb_fixnum(12)];
    let initialized_sum = vm::vm_dispatch_block_method(
        machine, array, vm::intern_symbol("sum"), vm::mrb_nil(), vm::mrb_nil(), initial[..]
    );
    t.assert_eq(12, vm::mrb_fixnum_value(initialized_sum));
    let minimum = vm::vm_dispatch_block_method(
        machine, array, vm::intern_symbol("min"), vm::mrb_nil(), vm::mrb_nil(), no_args[..]
    );
    t.assert_true(vm::mrb_is_nil(minimum));
    let maximum = vm::vm_dispatch_block_method(
        machine, array, vm::intern_symbol("max"), vm::mrb_nil(), vm::mrb_nil(), no_args[..]
    );
    t.assert_true(vm::mrb_is_nil(maximum));
}

fn test_linked_merge_sort_preserves_original(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let original = vm::builtin_array_new(scratch);
    for value in[4, -2, 9, 0, -7, 4] {
        t.assert_true(vm::builtin_array_push(pool, scratch, original, vm::mrb_fixnum(value)));
    }
    let sorted = vm::builtin_array_new(scratch);
    for value in[4, -2, 9, 0, -7, 4] {
        t.assert_true(vm::builtin_array_push(pool, scratch, sorted, vm::mrb_fixnum(value)));
    }
    t.assert_true(vm::vm_sort_merge_runs(
        machine, sorted, vm::mrb_nil(), false, vm::mrb_nil(), vm::mrb_nil(), false, 6
        ));
    let expected: i64[6] = [-7, -2, 0, 4, 4, 9];
    var index = 0;
    while index < expected.len {
        t.assert_eq(expected[index], vm::mrb_fixnum_value(
            vm::builtin_array_get(pool, scratch, sorted, index as i64)
            ));
        t.assert_eq([4, -2, 9, 0, -7, 4][index], vm::mrb_fixnum_value(
            vm::builtin_array_get(pool, scratch, original, index as i64)
            ));
        index += 1;
    }

    let words = vm::builtin_array_new(scratch);
    for word in["pear", "apple", "plum"] {
        t.assert_true(vm::builtin_array_push(pool, scratch, words, vm::scratch_alloc_string(scratch, word)));
    }
    t.assert_true(vm::vm_sort_merge_runs(
        machine, words, vm::mrb_nil(), false, vm::mrb_nil(), vm::mrb_nil(), false, 3
        ));
    t.assert_true(vm::vm_string_equals(
        machine, vm::builtin_array_get(pool, scratch, words, 0), "apple"
        ));
    t.assert_true(vm::vm_string_equals(
        machine, vm::builtin_array_get(pool, scratch, words, 1), "pear"
        ));
    t.assert_true(vm::vm_string_equals(
        machine, vm::builtin_array_get(pool, scratch, words, 2), "plum"
        ));
}

fn test_linked_merge_sort_by_keys_and_invalid_key(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let sorted = vm::builtin_array_new(scratch);
    let keys = vm::builtin_array_new(scratch);
    for value in[30, 10, 20, 40] {
        t.assert_true(vm::builtin_array_push(pool, scratch, sorted, vm::mrb_fixnum(value)));
    }
    for key in[3, -1, 2, 4] {
        t.assert_true(vm::builtin_array_push(pool, scratch, keys, vm::mrb_fixnum(key)));
    }
    t.assert_true(vm::vm_sort_merge_runs(
        machine, sorted, keys, true, vm::mrb_nil(), vm::mrb_nil(), false, 4
        ));
    let expected: i64[4] = [10, 20, 30, 40];
    var index = 0;
    while index < expected.len {
        t.assert_eq(expected[index], vm::mrb_fixnum_value(
            vm::builtin_array_get(pool, scratch, sorted, index as i64)
            ));
        index += 1;
    }

    let invalid_source = vm::builtin_array_new(scratch);
    let invalid = vm::builtin_array_new(scratch);
    let invalid_keys = vm::builtin_array_new(scratch);
    for value in[1, 2] {
        t.assert_true(vm::builtin_array_push(pool, scratch, invalid_source, vm::mrb_fixnum(value)));
        t.assert_true(vm::builtin_array_push(pool, scratch, invalid, vm::mrb_fixnum(value)));
    }
    t.assert_true(vm::builtin_array_push(pool, scratch, invalid_keys, vm::mrb_fixnum(1)));
    let text = vm::scratch_alloc_string(scratch, "bad");
    t.assert_true(vm::builtin_array_push(pool, scratch, invalid_keys, text));
    t.assert_false(vm::vm_sort_merge_runs(
        machine, invalid, invalid_keys, true, vm::mrb_nil(), vm::mrb_nil(), false, 2
        ));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, invalid_source, 0)));
    t.assert_eq(2, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, invalid_source, 1)));
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, invalid, 0)));
    t.assert_eq(2, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, invalid, 1)));
}

fn test_sort_comparator_block_reverses_order(t: goosetest::Test&) {
    let iseq: u8[15] = [
        vm::OP_MOVE, 3, 2,
        vm::OP_MOVE, 4, 1,
        vm::OP_SEND, 3, 0, 1,
        vm::OP_RETURN, 3,
        vm::OP_RETURN, 1,
        vm::OP_RETNIL,
    ];
    var file: vm::RiteFile = vm::RiteFile {
        data: iseq[..],
        ..
    };
    file.records.push(vm::IrepRecord {
            record_offset_bytes: 0,
            record_size_bytes: 0,
            nlocals: 3,
            nregs: 5,
            child_count: 0,
            catch_count: 0,
            iseq_length_bytes: 12,
            iseq_offset_bytes: 0,
            catch_offset_bytes: 0,
            pool_first_index: 0,
            pool_count: 0,
            syms_first_index: 0,
            syms_count: 1,
            parent_index: -1,
            first_child_index: -1,
            next_sibling_index: -1,
            depth: 0,
        });
    file.records.push(vm::IrepRecord {
            record_offset_bytes: 0,
            record_size_bytes: 0,
            nlocals: 1,
            nregs: 1,
            child_count: 0,
            catch_count: 0,
            iseq_length_bytes: 1,
            iseq_offset_bytes: 14,
            catch_offset_bytes: 0,
            pool_first_index: 0,
            pool_count: 0,
            syms_first_index: 0,
            syms_count: 0,
            parent_index: -1,
            first_child_index: -1,
            next_sibling_index: -1,
            depth: 0,
        });
    file.records.push(vm::IrepRecord {
            record_offset_bytes: 0,
            record_size_bytes: 0,
            nlocals: 2,
            nregs: 2,
            child_count: 0,
            catch_count: 0,
            iseq_length_bytes: 2,
            iseq_offset_bytes: 12,
            catch_offset_bytes: 0,
            pool_first_index: 0,
            pool_count: 0,
            syms_first_index: 0,
            syms_count: 0,
            parent_index: -1,
            first_child_index: -1,
            next_sibling_index: -1,
            depth: 0,
        });
    file.syms.push(vm::SymbolId {
            index: vm::intern_symbol("<=>")
        });
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    machine.frames.push(vm::CallFrame {
            record_index: 0,
            base: 0,
            self_value: vm::mrb_nil(),
            pc: 0,
            env_frame: -1,
            argc: 0,
        });
    let input = vm::builtin_array_new(machine.scratch);
    for value in[1, -3, 2, 0] {
        t.assert_true(vm::builtin_array_push(machine.pool, machine.scratch, input, vm::mrb_fixnum(value)));
    }
    let no_args: vm::MrbValue[0] = [];
    let sorted = vm::vm_dispatch_block_method(
        machine, input, vm::intern_symbol("sort"), vm::mrb_block_with_env(0, 0),
        vm::mrb_nil(), no_args[..]
    );
    t.assert_eq(vm::VmError.Ok, machine.error);
    let expected: i64[4] = [2, 1, 0, -3];
    var index = 0;
    while index < expected.len {
        t.assert_eq(expected[index], vm::mrb_fixnum_value(
            vm::builtin_array_get(machine.pool, machine.scratch, sorted, index as i64)
            ));
        t.assert_eq([1, -3, 2, 0][index], vm::mrb_fixnum_value(
            vm::builtin_array_get(machine.pool, machine.scratch, input, index as i64)
            ));
        index += 1;
    }

    let key_input = vm::builtin_array_new(machine.scratch);
    for value in[3, -1, 2, 0] {
        t.assert_true(vm::builtin_array_push(machine.pool, machine.scratch, key_input, vm::mrb_fixnum(value)));
    }
    let keyed = vm::vm_dispatch_block_method(
        machine, key_input, vm::intern_symbol("sort_by"), vm::mrb_block_with_env(2, 0),
        vm::mrb_nil(), no_args[..]
    );
    t.assert_eq(vm::VmError.Ok, machine.error);
    let expected_keys: i64[4] = [-1, 0, 2, 3];
    index = 0;
    while index < expected_keys.len {
        t.assert_eq(expected_keys[index], vm::mrb_fixnum_value(
            vm::builtin_array_get(machine.pool, machine.scratch, keyed, index as i64)
            ));
        t.assert_eq([3, -1, 2, 0][index], vm::mrb_fixnum_value(
            vm::builtin_array_get(machine.pool, machine.scratch, key_input, index as i64)
            ));
        index += 1;
    }

    let invalid_comparison = vm::vm_dispatch_block_method(
        machine, key_input, vm::intern_symbol("sort"), vm::mrb_block_with_env(1, 0),
        vm::mrb_nil(), no_args[..]
    );
    t.assert_true(vm::mrb_is_nil(invalid_comparison));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
    t.assert_eq(3, vm::mrb_fixnum_value(
        vm::builtin_array_get(machine.pool, machine.scratch, key_input, 0)
        ));
    t.assert_eq(-1, vm::mrb_fixnum_value(
        vm::builtin_array_get(machine.pool, machine.scratch, key_input, 1)
        ));
}

fn test_sort_workspace_limit_preserves_input(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let input = vm::builtin_array_new(machine.scratch);
    var index = 0;
    while index <= vm::SCRATCH_CAPACITY_SLOTS / 2 {
        t.assert_true(vm::builtin_array_push(
            machine.pool, machine.scratch, input, vm::mrb_fixnum(index)
            ));
        index += 1;
    }
    let no_args: vm::MrbValue[0] = [];
    let result = vm::vm_array_sort_block(
        machine, input, "sort_by", vm::mrb_nil(), vm::mrb_nil(), no_args[..]
    );
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.ScratchFull, machine.error);
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS / 2 + 1,
        vm::builtin_array_length(machine.pool, machine.scratch, input));
    t.assert_eq(0, vm::mrb_fixnum_value(
        vm::builtin_array_get(machine.pool, machine.scratch, input, 0)
        ));
    t.assert_eq(vm::SCRATCH_CAPACITY_SLOTS / 2,
        vm::mrb_fixnum_value(vm::builtin_array_get(
        machine.pool, machine.scratch, input, vm::SCRATCH_CAPACITY_SLOTS / 2
        )));
}

fn test_next_preserves_flow_and_lexical_locals(t: goosetest::Test&) {
    let bytes = embed_file("../fixtures/helper_contracts.mrb");
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, bytes));
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let root = vm::vm_instantiate(machine, vm::intern_symbol("HelperRoot"));
    let result = vm::vm_call0(machine, root, vm::intern_symbol("blocks"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::vm_string_equals(machine, result, "1,3:11,7,13:4:after"));
    let nested = vm::vm_call0(machine, root, vm::intern_symbol("nested"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq(12, vm::mrb_fixnum_value(nested));
}
