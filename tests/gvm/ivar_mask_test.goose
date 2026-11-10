// Tests for 256-bit ivar masks, mask-backed tracking and capacity boundaries.
//
// The tests cover bit placement in all four words, tracking reads and dirty
// writes above bit 63, recovery when an instance reaches the 256-ivar limit,
// and a binding flush whose getter reads ivar bit 70.
namespace vm_ivar_mask_test;

import std;

import goosetest;
import vm;

// Builds a flat IREP record over caller-owned instruction bytes.
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

// Fills `file` with one single-ivar string getter over `code`.
fn build_getter_file(file: vm::RiteFile&, code: u8[>..]&, ivar_symbol: u32) {
    let getter: u8[7] = [
        vm::OP_GETIV, 1, 0,
        vm::OP_STRCAT, 1,
        vm::OP_RETURN, 1,
    ];
    code.append(getter[..]);
    file.data = code[..];
    file.syms.push(vm::SymbolId {
            index: ivar_symbol,
        });
    file.records.push(make_getter_record(0, 7, 0, 1, 3));
}

fn test_mask_helpers_cover_all_four_words(t: goosetest::Test&) {
    var mask = vm::mask_clear();
    t.assert_true(vm::mask_is_empty(mask));
    vm::mask_set_bit(mask, 0);
    vm::mask_set_bit(mask, 63);
    vm::mask_set_bit(mask, 64);
    vm::mask_set_bit(mask, 127);
    vm::mask_set_bit(mask, 128);
    vm::mask_set_bit(mask, 191);
    vm::mask_set_bit(mask, 192);
    vm::mask_set_bit(mask, 255);
    t.assert_eq(0x8000000000000001, mask.w0);
    t.assert_eq(0x8000000000000001, mask.w1);
    t.assert_eq(0x8000000000000001, mask.w2);
    t.assert_eq(0x8000000000000001, mask.w3);
    t.assert_true(vm::mask_intersects(mask, vm::state_ivar_bit(255)));
    t.assert_false(vm::mask_intersects(mask, vm::state_ivar_bit(254)));
    t.assert_true(vm::mask_equal(mask, vm::mask_or(mask, vm::state_ivar_bit(255))));

    let single = vm::state_ivar_bit(100);
    t.assert_eq(1, single.w1 >> 36);
    t.assert_eq(0, single.w0);
    t.assert_eq(0, single.w2);
    t.assert_eq(0, single.w3);
}

fn test_tracks_reads_across_all_four_mask_words(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("WideWidget"), vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    for index in 0..100 {
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
    }
    t.assert_eq(64, vm::state_ivar_bit_index(pool, instance, 64));
    t.assert_eq(99, vm::state_ivar_bit_index(pool, instance, 99));

    t.assert_true(vm::state_tracking_begin(pool, instance));
    let _, read_first = vm::state_get_ivar(pool, instance, 0);
    let _, read_63 = vm::state_get_ivar(pool, instance, 63);
    let _, read_64 = vm::state_get_ivar(pool, instance, 64);
    let _, read_99 = vm::state_get_ivar(pool, instance, 99);
    t.assert_true(read_first);
    t.assert_true(read_63);
    t.assert_true(read_64);
    t.assert_true(read_99);
    let mask = vm::state_tracking_end(pool);
    t.assert_eq(1, mask.w0 & 1);
    t.assert_eq(1, mask.w0 >> 63);
    t.assert_eq(1, mask.w1 & 1);
    t.assert_eq(1, mask.w1 >> 35);
    t.assert_eq(0, mask.w2);
    t.assert_eq(0, mask.w3);
}

fn test_tracks_bits_in_every_word(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("AllWordWidget"),
        vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    for index in 0..256 {
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
    }
    let keys: u32[8] = [0, 63, 64, 127, 128, 191, 192, 255];
    t.assert_true(vm::state_tracking_begin(pool, instance));
    for key in keys {
        let _, found = vm::state_get_ivar(pool, instance, key);
        t.assert_true(found);
    }
    let mask = vm::state_tracking_end(pool);
    t.assert_eq(0x8000000000000001, mask.w0);
    t.assert_eq(0x8000000000000001, mask.w1);
    t.assert_eq(0x8000000000000001, mask.w2);
    t.assert_eq(0x8000000000000001, mask.w3);
}

fn test_writes_above_bit_63_dirty_the_owning_word(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("DirtyWidget"), vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    for index in 0..100 {
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
    }
    t.assert_true(vm::state_clear_dirty_mask(pool, instance));
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, 70, vm::mrb_fixnum(700)));
    let dirty = vm::state_dirty_mask(pool, instance);
    t.assert_true(vm::mask_equal(vm::state_ivar_bit(70), dirty));
    t.assert_eq(1, dirty.w1 >> 6);
    t.assert_eq(0, dirty.w0);
}

fn test_ivar_capacity_is_a_recoverable_vm_error(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("FullWidget"), vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    for index in 0..256 {
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
    }
    t.assert_eq(256, vm::state_ivar_count(pool));
    t.assert_eq(vm::VmError.Ok, pool.error);

    t.assert_false(vm::state_set_ivar(pool, scratch, instance, 999, vm::mrb_fixnum(1)));
    t.assert_eq(vm::VmError.IvarCapacity, pool.error);
    t.assert_eq(256, vm::state_ivar_count(pool));

    let last, last_found = vm::state_get_ivar(pool, instance, 255);
    t.assert_true(last_found);
    t.assert_eq(255, vm::mrb_fixnum_value(last));

    let replacement = vm::state_alloc_instance(pool, class_id);
    t.assert_eq(vm::VmError.Ok, pool.error);
    t.assert_true(vm::state_set_ivar(pool, scratch, replacement, 7, vm::mrb_fixnum(7)));
}

fn test_tracked_read_at_capacity(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    let class_id = vm::state_define_class(pool, vm::intern_symbol("ReadFullWidget"), vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    for index in 0..256 {
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, index as u32,
            vm::mrb_fixnum(index)));
    }
    t.assert_true(vm::state_tracking_begin(pool, instance));
    let value, found = vm::state_get_ivar(pool, instance, 999);
    t.assert_false(found);
    t.assert_true(vm::mrb_is_nil(value));
    t.assert_eq(vm::VmError.IvarCapacity, pool.error);
    t.assert_eq(256, vm::state_ivar_count(pool));
    vm::state_tracking_end(pool);
}

fn test_flush_evaluates_a_binding_above_bit_63(t: goosetest::Test&) {
    let ivar_symbol = vm::intern_symbol("@wide");
    var code: u8[>..] = [];
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    build_getter_file(file, code, ivar_symbol);
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
    let class_id = vm::state_define_class(pool, vm::intern_symbol("WideBindingWidget"),
        vm::NULL_CLASS_ID);
    let instance = vm::state_alloc_instance(pool, class_id);
    t.assert_true(vm::state_register_component(pool, instance));
    vm::vm_define_method(machine, class_id, vm::intern_symbol("wide_text"), 0);
    for index in 0..100 {
        let key = if index == 70 {
            ivar_symbol
        } else {
            (index + 1000)as u32
        };
        t.assert_true(vm::state_set_ivar(pool, scratch, instance, key, vm::mrb_fixnum(index)));
    }
    t.assert_eq(0, vm::binding_register(pool, instance, 3, vm::intern_symbol("wide_text")));

    var patches: u8[>..] = [];
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(8, patches.len);
    t.assert_eq(3, patches[0]);
    t.assert_eq(0, patches[1]);
    t.assert_eq(2, patches[2]);
    t.assert_eq(0x37, patches[6]);
    t.assert_eq(0x30, patches[7]);
    t.assert_true(vm::mask_equal(vm::state_ivar_bit(70), pool.bindings[0].dep_mask));

    patches.clear();
    t.assert_true(vm::state_set_ivar(pool, scratch, instance, ivar_symbol, vm::mrb_fixnum(71)));
    t.assert_true(vm::mask_equal(vm::state_ivar_bit(70), vm::state_dirty_mask(pool, instance)));
    t.assert_eq(1, vm::vm_flush_dirty_bindings(machine, instance, patches));
    t.assert_eq(0x37, patches[6]);
    t.assert_eq(0x31, patches[7]);
}
