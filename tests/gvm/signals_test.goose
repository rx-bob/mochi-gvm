// Tests for u64 bitmask signals on component instance variables.
//
// The tests cover the two directions of the mask: reads of the tracked
// instance OR slot bits into `active_read_mask`, stores OR changed bits into
// the instance's `dirty_ivars`, and equal values (including equal state string
// bytes) leave the dirty mask untouched. Collection tests prove that in-place
// array and hash mutations dirty the ivar that owns them, including through
// nested collections.
namespace vm_signals_test;

import std;

import goosetest;
import vm;

let COUNT_KEY: u32 = 1;
let LABEL_KEY: u32 = 2;
let ITEMS_KEY: u32 = 3;
let DONE_KEY: u32 = 4;
let MISSING_KEY: u32 = 5;

// Reads two ivars from a nested helper to prove tracking is not limited to the
// immediate caller of `state_get_ivar`.
fn read_count_and_label(pool: vm::StatePool&, instance: vm::MrbValue) -> i64 {
    let count, count_ok = vm::state_get_ivar(pool, instance, COUNT_KEY);
    let label, label_ok = vm::state_get_ivar(pool, instance, LABEL_KEY);
    if !count_ok || !label_ok {
        return -1;
    }
    return vm::mrb_fixnum_value(count) + vm::mrb_fixnum_value(label);
}

fn test_tracked_reads_set_active_bits(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    let other = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(2)));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, LABEL_KEY, vm::mrb_fixnum(3)));
    t.assert_true(vm::state_set_ivar(pool, scratch, other, COUNT_KEY, vm::mrb_fixnum(9)));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, COUNT_KEY));
    t.assert_eq(1, vm::state_ivar_bit_index(pool, instance, LABEL_KEY));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_tracking_begin(pool, instance));
    t.assert_eq(5, read_count_and_label(pool, instance));
    let mask = vm::state_tracking_end(pool);
    t.assert_eq(vm::state_ivar_bit(0), mask & vm::state_ivar_bit(0));
    t.assert_eq(vm::state_ivar_bit(1), mask & vm::state_ivar_bit(1));
    t.assert_eq(0, mask & vm::state_ivar_bit(2));
    t.assert_eq(3, mask);

    t.assert_true(vm::state_tracking_begin(pool, instance));
    let foreign, foreign_found = vm::state_get_ivar(pool, other, COUNT_KEY);
    t.assert_true(foreign_found);
    t.assert_eq(9, vm::mrb_fixnum_value(foreign));
    t.assert_eq(0, vm::state_tracking_end(pool));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_eq(0, vm::state_tracked_read_mask(pool));
    t.assert_false(vm::state_tracking_begin(pool, vm::mrb_nil()));
}

fn test_noop_assignment_keeps_dirty_mask_empty(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(0)));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    let current, found = vm::state_get_ivar(pool, instance, COUNT_KEY);
    t.assert_true(found);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, current));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance, COUNT_KEY, vm::mrb_fixnum(1)));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

fn test_string_assignments_compare_state_bytes(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "same")));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, LABEL_KEY));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "same")));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_set_ivar(pool, scratch, instance,
        LABEL_KEY, vm::state_alloc_string(pool, "different")));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

fn test_uninitialized_ivar_read_is_tracked(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_tracking_begin(pool, instance));

    let value, found = vm::state_get_ivar(pool, instance, MISSING_KEY);
    t.assert_false(found);
    t.assert_true(vm::mrb_is_nil(value));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_tracked_read_mask(pool));
    t.assert_eq(0, vm::state_ivar_bit_index(pool, instance, MISSING_KEY));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_eq(1, vm::state_ivar_count(pool));
    vm::state_tracking_end(pool);

    let _, second_found = vm::state_get_ivar(pool, instance, MISSING_KEY);
    t.assert_true(second_found);
    t.assert_eq(1, vm::state_ivar_count(pool));
}

fn test_nested_hash_mutation_dirties_owner(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let items = vm::state_alloc_array(pool);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, items));
    let items_bit = vm::state_ivar_bit_index(pool, instance, ITEMS_KEY)as u8;
    t.assert_eq(0, items_bit);
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::state_array_push(pool, items, vm::mrb_fixnum(1)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    let entry = vm::state_alloc_hash(pool);
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_push(pool, items, entry));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_false()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_false()));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_hash_set(pool, entry, DONE_KEY, vm::mrb_true()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_set(pool, items, 1, entry));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_set(pool, items, 0, vm::mrb_fixnum(2)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    let popped, pop_ok = vm::state_array_pop(pool, items);
    t.assert_true(pop_ok);
    t.assert_true(vm::mrb_value_identical(popped, entry));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
}

fn test_collection_mutation_outside_component(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    let owned = vm::state_alloc_array(pool);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, owned));
    t.assert_true(vm::state_register_component(pool, instance));
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    let orphan = vm::state_alloc_array(pool);
    t.assert_true(vm::state_array_push(pool, orphan, vm::mrb_fixnum(1)));
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_array_push(pool, owned, orphan));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_array_push(pool, orphan, vm::mrb_fixnum(2)));
    t.assert_eq(vm::state_ivar_bit(0), vm::state_dirty_mask(pool, instance));
}

// Exercises the builtin helpers that the OP_SETIDX and Array#<< handlers call.
fn test_builtin_set_index_dirties_owner(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, 1, vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    let items = vm::state_alloc_array(pool);
    let entry = vm::state_alloc_hash(pool);
    t.assert_true(vm::state_array_push(pool, items, entry));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ITEMS_KEY, items));
    let items_bit = vm::state_ivar_bit_index(pool, instance, ITEMS_KEY)as u8;
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));

    t.assert_true(vm::builtin_set_index(pool, scratch, entry, DONE_KEY, vm::mrb_true()));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));

    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::builtin_array_push(pool, scratch, items, vm::mrb_fixnum(7)));
    t.assert_eq(vm::state_ivar_bit(items_bit), vm::state_dirty_mask(pool, instance));
}

// Builds a flat IREP record over caller-owned instruction bytes. The test suite
// only needs method bodies, so every record is a leaf with no children.
fn make_getter_record(
    iseq_offset: i64, iseq_length: u32, syms_first: i64, syms_count: u16, nregs: u16
) -> vm::IrepRecord {
    return vm::IrepRecord {
        record_offset_bytes: 0,
        record_size_bytes: 0,
        nlocals: 2,
        nregs: nregs,
        child_count: 0,
        catch_count: 0,
        iseq_length_bytes: iseq_length,
        iseq_offset_bytes: iseq_offset,
        catch_offset_bytes: 0,
        pool_first_index: 0,
        pool_count: 0,
        syms_first_index: syms_first,
        syms_count: syms_count,
        parent_index: -1,
        first_child_index: -1,
        next_sibling_index: -1,
        depth: 0,
    };
}

// Fills `file` with two single-ivar text getters over `code`. The caller keeps
// `code` alive because `file.data` is only a view.
fn build_simple_getter_file(
    file: vm::RiteFile&, code: u8[>..]&, count_symbol: u32, label_symbol: u32
) {
    let getter: u8[7] = [vm::OP_GETIV, 1, 0, vm::OP_STRCAT, 1, vm::OP_RETURN, 1];
    code.append(getter[..]);
    code.append(getter[..]);
    file.data = code[..];
    file.syms.push(vm::SymbolId {
            index: count_symbol,
        });
    file.syms.push(vm::SymbolId {
            index: label_symbol,
        });
    file.records.push(make_getter_record(0, 7, 0, 1, 3));
    file.records.push(make_getter_record(7, 7, 1, 1, 3));
}

fn prepare_simple_widget(
    machine: vm::Vm&, pool: vm::StatePool&, scratch: vm::ScratchArena&,
    count_symbol: u32, label_symbol: u32
) -> vm::MrbValue {
    let class_id = vm::state_define_class(pool, vm::intern_symbol("BindingWidget"),
        vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    assert(vm::state_register_component(pool, instance));
    vm::vm_define_method(machine, class_id, vm::intern_symbol("count_text"), 0);
    vm::vm_define_method(machine, class_id, vm::intern_symbol("label_text"), 1);
    assert(vm::state_set_ivar(pool, scratch, instance, count_symbol, vm::mrb_fixnum(3)));
    assert(vm::state_set_ivar(pool, scratch, instance, label_symbol, vm::mrb_fixnum(4)));
    assert(vm::binding_register(pool, instance, 0, vm::intern_symbol("count_text")) == 0);
    assert(vm::binding_register(pool, instance, 1, vm::intern_symbol("label_text")) == 0);
    return instance;
}

fn build_conditional_file(
    file: vm::RiteFile&, code: u8[>..]&, show_symbol: u32, detail_symbol: u32
) {
    let conditional: u8[14] = [
        vm::OP_GETIV, 1, 0,
        vm::OP_JMPNOT, 1, 0, 5,
        vm::OP_GETIV, 2, 1,
        vm::OP_RETURN, 2,
        vm::OP_RETURN, 2,
    ];
    code.append(conditional[..]);
    file.data = code[..];
    file.syms.push(vm::SymbolId {
            index: show_symbol,
        });
    file.syms.push(vm::SymbolId {
            index: detail_symbol,
        });
    file.records.push(make_getter_record(0, 14, 0, 2, 3));
}

fn prepare_conditional_widget(
    machine: vm::Vm&, pool: vm::StatePool&, scratch: vm::ScratchArena&,
    show_symbol: u32, detail_symbol: u32
) -> vm::MrbValue {
    let class_id = vm::state_define_class(pool, vm::intern_symbol("ConditionalWidget"),
        vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    assert(vm::state_register_component(pool, instance));
    vm::vm_define_method(machine, class_id, vm::intern_symbol("detail_text"), 0);
    assert(vm::state_set_ivar(pool, scratch, instance, show_symbol, vm::mrb_false()));
    assert(vm::state_set_ivar(pool, scratch, instance, detail_symbol, vm::mrb_fixnum(7)));
    assert(vm::binding_register(pool, instance, 0, vm::intern_symbol("detail_text")) == 0);
    return instance;
}

fn test_flush_only_reevaluates_dirty_binding(t: goosetest::Test&) {
    let count_symbol = vm::intern_symbol("@count");
    let label_symbol = vm::intern_symbol("@label");
    var code: u8[>..] = [];
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    build_simple_getter_file(file, code, count_symbol, label_symbol);
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
    let instance = prepare_simple_widget(machine, pool, scratch, count_symbol, label_symbol);

    var patches: u8[>..] = [];
    t.assert_eq(2, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(14, patches.len);
    t.assert_eq(0, patches[0]);
    t.assert_eq(0, patches[1]);
    t.assert_eq(1, patches[2]);
    t.assert_eq(0, patches[3]);
    t.assert_eq(0x33, patches[6]);
    t.assert_eq(1, patches[7]);
    t.assert_eq(0, patches[8]);
    t.assert_eq(1, patches[9]);
    t.assert_eq(0x34, patches[13]);
    t.assert_eq(vm::state_ivar_bit(0), pool.bindings[0].dep_mask);
    t.assert_eq(vm::state_ivar_bit(1), pool.bindings[1].dep_mask);
    t.assert_eq(0, vm::state_dirty_mask(pool, instance));

    // A no-op flush emits nothing; incrementing @count re-evaluates binding 0
    // only and emits one framed record.
    patches.clear();
    t.assert_eq(0, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(0, patches.len);
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, count_symbol, vm::mrb_fixnum(5)));
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(7, patches.len);
    t.assert_eq(0, patches[0]);
    t.assert_eq(0, patches[1]);
    t.assert_eq(1, patches[2]);
    t.assert_eq(0, patches[3]);
    t.assert_eq(0, patches[4]);
    t.assert_eq(0, patches[5]);
    t.assert_eq(0x35, patches[6]);
    t.assert_eq(vm::state_ivar_bit(1), pool.bindings[1].dep_mask);
}

fn test_conditional_binding_resubscribes(t: goosetest::Test&) {
    let show_symbol = vm::intern_symbol("@show");
    let detail_symbol = vm::intern_symbol("@detail");
    var code: u8[>..] = [];
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    build_conditional_file(file, code, show_symbol, detail_symbol);
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
    let instance = prepare_conditional_widget(machine, pool, scratch,
        show_symbol, detail_symbol);
    let show_bit = vm::state_ivar_bit(0);
    let detail_bit = vm::state_ivar_bit(1);

    var patches: u8[>..] = [];
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(6, patches.len);
    t.assert_eq(show_bit, pool.bindings[0].dep_mask);
    t.assert_true(pool.bindings[0].initialized);

    // Hidden branch does not subscribe to @detail: mutating it emits nothing.
    patches.clear();
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, detail_symbol, vm::mrb_fixnum(8)));
    t.assert_eq(0, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(0, patches.len);
    t.assert_eq(show_bit, pool.bindings[0].dep_mask);

    // Showing the branch re-evaluates and now subscribes to both ivars.
    patches.clear();
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, show_symbol, vm::mrb_true()));
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(7, patches.len);
    t.assert_eq(0x38, patches[6]);
    t.assert_eq(show_bit | detail_bit, pool.bindings[0].dep_mask);

    patches.clear();
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, detail_symbol, vm::mrb_fixnum(9)));
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(7, patches.len);
    t.assert_eq(0x39, patches[6]);
}
