// Computed tests exercise metadata, invalidation and lifetime through real VM calls.
namespace computed_test;

import goosetest;
import vm;

let COMPUTED: const u8[:] = embed_file("../fixtures/computed.mrb");

fn test_explicit_mask_invalidation(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let owner = vm::state_alloc_instance(pool, class_id);
    var dependencies = vm::mask_clear();
    vm::mask_set_bit(dependencies, 2);
    pool.computed.push(vm::ComputedEntry {
            instance: owner,
            method_symbol: 1,
            dependencies: dependencies,
            value: vm::mrb_fixnum(42),
            valid: true,
            ..
        });
    vm::computed_invalidate(pool, vm::mrb_arena_index(owner), 1);
    t.assert_true(pool.computed[0].valid);
    vm::computed_invalidate(pool, vm::mrb_arena_index(owner), 2);
    t.assert_false(pool.computed[0].valid);
    t.assert_true(vm::mrb_is_nil(pool.computed[0].value));
    vm::computed_unregister(pool, owner);
    t.assert_eq(0, pool.computed.len);
}

fn set_count(machine: vm::Vm&, owner: vm::MrbValue, count: i64) {
    let args: vm::MrbValue[1] = [vm::mrb_fixnum(count)];
    vm::vm_call_args(machine, owner, vm::intern_symbol("change"), args[..]);
}

fn test_gc_invalidation_instances_and_retry(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    let other = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    let rows_symbol = vm::intern_symbol("rows");
    let first = vm::vm_call0(machine, owner, rows_symbol);
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::mrb_is_state(first));
    vm::vm_end_entry(machine);
    vm::gc_collect(machine);
    let same = vm::vm_call0(machine, owner, rows_symbol);
    t.assert_true(vm::mrb_value_identical(first, same));
    let hash = vm::builtin_array_get(pool, scratch, same, 0);
    let value = vm::builtin_hash_get(pool, scratch, hash, vm::scratch_alloc_string(scratch, "value"));
    t.assert_eq(6, vm::mrb_fixnum_value(value));
    vm::vm_call0(machine, owner, vm::intern_symbol("unrelated"));
    t.assert_true(vm::mrb_value_identical(first, vm::vm_call0(machine, owner, rows_symbol)));
    let independent = vm::vm_call0(machine, other, rows_symbol);
    t.assert_false(vm::mrb_value_identical(first, independent));
    set_count(machine, owner, 3);
    let fresh = vm::vm_call0(machine, owner, rows_symbol);
    t.assert_false(vm::mrb_value_identical(first, fresh));
    set_count(machine, owner, 4);
    let fresher = vm::vm_call0(machine, owner, rows_symbol);
    t.assert_false(vm::mrb_value_identical(fresh, fresher));
    set_count(machine, owner, 0);
    vm::vm_call0(machine, owner, rows_symbol);
    t.assert_eq(vm::VmError.DivisionByZero, machine.error);
    t.assert_false(pool.computed[0].valid);
    t.assert_false(pool.computed[0].evaluating);
    t.assert_eq(0, pool.computed_depth);
    set_count(machine, owner, 6);
    let recovered = vm::vm_call0(machine, owner, vm::intern_symbol("summary"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::vm_string_equals(machine, recovered, "2"));
    vm::vm_end_entry(machine);
    vm::gc_collect(machine);
    t.assert_true(vm::mrb_value_identical(independent, vm::vm_call0(machine, other, rows_symbol)));
    vm::vm_end_entry(machine);
    t.assert_true(vm::vm_dispose_instance(machine, owner));
    t.assert_eq(1, pool.computed.len);
    t.assert_true(vm::vm_dispose_instance(machine, other));
    t.assert_eq(0, pool.computed.len);
    t.assert_eq(0, vm::state_allocated_object_count(pool));
}

fn test_binding_hits_keep_dependencies(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    vm::binding_register(pool, owner, 1, vm::intern_symbol("first_binding"));
    vm::binding_register(pool, owner, 2, vm::intern_symbol("second_binding"));
    var patches: u8[>..] = [];
    t.assert_eq(2, vm::vm_flush_dirty_bindings(machine, owner, patches));
    t.assert_eq(2, pool.computed.len);
    t.assert_true(vm::mask_equal(pool.bindings[0].dep_mask, pool.bindings[1].dep_mask));
    t.assert_false(vm::mask_is_empty(pool.bindings[1].dep_mask));
    set_count(machine, owner, 3);
    t.assert_eq(2, vm::vm_flush_dirty_bindings(machine, owner, patches));
    vm::vm_call0(machine, owner, vm::intern_symbol("unrelated"));
    t.assert_eq(0, vm::vm_flush_dirty_bindings(machine, owner, patches));
}

fn test_effects_and_reentry_guards(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    let class_id, _ = vm::vm_owner_class_id(machine, owner);
    vm::vm_define_native_method(machine, class_id, vm::intern_symbol("external"), 123);
    let names: const u8[:][4] = ["write", "mutate", "host", "native"];
    for name in names {
        vm::vm_call0(machine, owner, vm::intern_symbol(name));
        t.assert_eq(vm::VmError.ComputedEffect, machine.error);
        t.assert_eq(0, pool.computed_depth);
    }
    let count, _ = vm::state_get_ivar(pool, owner, vm::intern_symbol("@count"));
    t.assert_eq(2, vm::mrb_fixnum_value(count));
    let items, _ = vm::state_get_ivar(pool, owner, vm::intern_symbol("@items"));
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, items, 0)));
    vm::vm_call0(machine, owner, vm::intern_symbol("recursive"));
    t.assert_eq(vm::VmError.ComputedReentry, machine.error);
    t.assert_eq(0, pool.computed_depth);
    vm::vm_call0(machine, owner, vm::intern_symbol("rows"));
    t.assert_eq(vm::VmError.Ok, machine.error);
}

fn test_inheritance_local_work_and_gc(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedChild"));
    let rows = vm::vm_call0(machine, owner, vm::intern_symbol("rows"));
    let nested = vm::vm_call0(machine, owner, vm::intern_symbol("local_work"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::mrb_value_identical(rows, vm::builtin_array_get(pool, scratch, nested, 0)));
    vm::vm_end_entry(machine);
    vm::gc_collect(machine);
    t.assert_true(vm::mrb_value_identical(rows, vm::vm_call0(machine, owner, vm::intern_symbol("rows"))));
    vm::vm_call0(machine, owner, vm::intern_symbol("write"));
    t.assert_eq(vm::VmError.ComputedEffect, machine.error);
    let ordinary = vm::vm_instantiate(machine, vm::intern_symbol("ComputedOverride"));
    t.assert_eq(1, vm::mrb_fixnum_value(vm::vm_call0(machine, ordinary, vm::intern_symbol("rows"))));
    t.assert_eq(2, vm::mrb_fixnum_value(vm::vm_call0(machine, ordinary, vm::intern_symbol("rows"))));
    t.assert_eq(vm::VmError.Ok, machine.error);
}

fn test_promotion_failure_releases_and_retries(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    var bytes: u8[>..] = [];
    for _ in 0..vm::MAX_STATE_BYTES - pool.blob.len - 2 {
        bytes.push('x');
    }
    let retained = vm::state_alloc_string(pool, bytes[..]);
    let key = vm::intern_symbol("@pressure");
    vm::state_store_ivar_raw(pool, vm::mrb_arena_index(owner), key, retained);
    vm::vm_call0(machine, owner, vm::intern_symbol("text"));
    t.assert_eq(vm::VmError.StateCapacity, machine.error);
    t.assert_false(pool.computed[0].valid);
    t.assert_false(pool.computed[0].evaluating);
    vm::state_store_ivar_raw(pool, vm::mrb_arena_index(owner), key, vm::mrb_nil());
    vm::vm_end_entry(machine);
    vm::gc_collect(machine);
    let recovered = vm::vm_call0(machine, owner, vm::intern_symbol("text"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_true(vm::vm_string_equals(machine, recovered, "computed text"));
    t.assert_true(pool.computed[0].valid);
}

fn test_bad_metadata_and_cache_capacity(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::vm_load_irep(file, COMPUTED));
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
    let owner = vm::vm_instantiate(machine, vm::intern_symbol("ComputedProbe"));
    let class_id, _ = vm::vm_owner_class_id(machine, owner);
    let definitions = machine.computed_definitions.len;
    let roots = machine.computed_roots.len;
    let bad = vm::builtin_array_new(scratch);
    vm::builtin_array_push(pool, scratch, bad, vm::mrb_fixnum(7));
    let args: vm::MrbValue[2] = [vm::mrb_symbol(vm::intern_symbol("bad")), bad];
    vm::computed_register(machine, class_id, args[..]);
    t.assert_eq(vm::VmError.InvalidArgument, machine.error);
    t.assert_eq(definitions, machine.computed_definitions.len);
    t.assert_eq(roots, machine.computed_roots.len);
    // Fill only the bounded entry table; persistent graph capacity remains
    // available, so the diagnostic must identify entries rather than bytes.
    for _ in 0..vm::MAX_BINDINGS {
        pool.computed.push(vm::ComputedEntry {
                instance: owner,
                method_symbol: vm::NULL_SYMBOL,
                dependencies: vm::mask_clear(),
                value: vm::mrb_nil(),
                ..
            });
    }
    vm::vm_call0(machine, owner, vm::intern_symbol("rows"));
    t.assert_eq(vm::VmError.StateCapacity, machine.error);
    t.assert_eq(vm::CapacityResource.ComputedEntries, pool.failure.resource);
    t.assert_eq(vm::MAX_BINDINGS, pool.failure.capacity);
    vm::computed_unregister(pool, owner);
    vm::vm_call0(machine, owner, vm::intern_symbol("rows"));
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq(1, pool.computed.len);
}
