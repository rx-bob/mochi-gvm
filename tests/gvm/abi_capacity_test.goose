// Capacity rejection must preserve loaded programs and release failed entry roots.
namespace abi_capacity_test;

import std;

import goosetest;
import tests.gvm.abi_test;
import vm;

fn counter(t: goosetest::Test&) -> u64 {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(vm_abi_test::counter_rite()));
    let class = vm::abi_const_get(vm::intern_symbol("Counter"));
    return vm::abi_obj_new(vm::mrb_class_id(class));
}

fn assert_recovered(t: goosetest::Test&, instance: u64) {
    t.assert_eq(0, vm::g_abi_machine.frames.len);
    t.assert_eq(0, vm::g_abi_machine.regs.len);
    t.assert_eq(0, vm::g_abi_machine.entry_args.len);
    t.assert_eq(0, vm::g_abi_machine.scratch_roots.len);
    t.assert_eq(0, vm::g_abi_scratch.objects.len);
    vm::abi_call(instance, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error(), "loaded class and unrelated component survive");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn oversized_array() -> u8[>..] {
    var json = str("[");
    for i in vm::SCRATCH_CAPACITY_OBJECTS {
        if i > 0 {
            json.push(',');
        }
        json.append("\"x\"");
    }
    json.push(']');
    return json;
}

fn test_json_capacity_recovery(t: goosetest::Test&) {
    let instance = counter(t);
    let json = str("[", oversized_array(), "]");
    vm::abi_call_json(instance, vm::intern_symbol("increment"), json);
    t.assert_true(vm::abi_has_error());
    t.assert_true(starts_with(vm::abi_last_error(), "Counter#increment: scratch objects exhausted"));
    t.assert_eq(vm::SCRATCH_CAPACITY_OBJECTS, vm::g_abi_machine.error_context.capacity_limit);
    assert_recovered(t, instance);
}

fn test_props_rejection_disposes_mount(t: goosetest::Test&) {
    let instance = counter(t);
    let class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let props = str("{\"rows\":", oversized_array(), "}");
    let rejected = vm::abi_obj_new_with_props(vm::mrb_class_id(class), props);
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(starts_with(vm::abi_last_error(), "Counter: scratch objects exhausted"));
    t.assert_eq(1, vm::abi_component_count(), "failed mount removed only its registration");
    assert_recovered(t, instance);
}

fn test_bytecode_rejection_preserves_program(t: goosetest::Test&) {
    let instance = counter(t);
    let packages = vm::slab_package_count();
    let package_bytes = vm::slab_package_bytes_used();
    let used = vm::slab_used_bytes();
    vm::slab_set_limit(used);
    var bytes: u8[>..] = [];
    bytes.resize(16, 0);
    t.assert_eq(1, vm::abi_load_irep(bytes));
    t.assert_true(starts_with(vm::abi_last_error(), "metadata bytes exhausted"));
    t.assert_eq(packages, vm::slab_package_count());
    t.assert_eq(package_bytes, vm::slab_package_bytes_used());
    t.assert_eq(used, vm::slab_used_bytes());
    t.assert_eq(0, vm::g_abi_file.data.len);
    vm::slab_use_default_limit();
    assert_recovered(t, instance);
}

fn test_failed_flush_discards_prior_patches(t: goosetest::Test&) {
    let instance = counter(t);
    t.assert_eq(0, vm::abi_register_binding(instance, 1, vm::intern_symbol("html")));
    t.assert_eq(0, vm::abi_register_binding(instance, 2, vm::intern_symbol("missing_getter")));
    t.assert_eq(0, vm::abi_register_binding(instance, 3, vm::intern_symbol("html")));
    t.assert_eq(-1, vm::abi_flush_patches(instance));
    t.assert_eq(0, vm::abi_patch_bytes().len, "earlier successful getters must not leak a partial batch");
    t.assert_true(starts_with(vm::abi_last_error(), "Counter#missing_getter (binding 2)"));
    vm::binding_unregister_all(vm::g_abi_pool, instance);
    t.assert_eq(0, vm::abi_register_binding(instance, 1, vm::intern_symbol("html")));
    t.assert_eq(1, vm::abi_flush_patches(instance));
    t.assert_true(vm::abi_patch_bytes().len > 0);
    vm::vm_end_entry(vm::g_abi_machine);
    assert_recovered(t, instance);
}

fn push_u16_be(out: u8[>..]&, value: u16) {
    out.push((value >> 8)as!u8);
    out.push(value as!u8);
}

fn push_u32_be(out: u8[>..]&, value: u32) {
    out.push((value >> 24)as!u8);
    out.push((value >> 16)as!u8);
    out.push((value >> 8)as!u8);
    out.push(value as!u8);
}

fn put_u32_be(out: u8[>..]&, at: i64, value: u32) {
    out[at] = (value >> 24)as!u8;
    out[at + 1] = (value >> 16)as!u8;
    out[at + 2] = (value >> 8)as!u8;
    out[at + 3] = value as!u8;
}

fn make_record(
    pool: u8[:], pool_count: u16, syms: u8[:], sym_count: u16, child_count: u16
) -> u8[>..] {
    var out: u8[>..] = [];
    let own_size = 16 + 2 + pool.len + 2 + syms.len;
    push_u32_be(out, own_size as u32);
    push_u16_be(out, 1);
    push_u16_be(out, 3);
    push_u16_be(out, child_count);
    push_u16_be(out, 0);
    push_u32_be(out, 0);
    push_u16_be(out, pool_count);
    out.append(pool);
    push_u16_be(out, sym_count);
    out.append(syms);
    return out;
}

// A valid root record with one literal and one interned symbol, followed by a
// child whose 16-byte header is cut in half. Parsing appends the root, pool and
// symbol before the child rejects the package.
fn truncated_package() -> u8[>..] {
    var pool: u8[>..] = [];
    pool.push(0);
    push_u16_be(pool, 2);
    pool.append("ok");
    pool.push(0);

    var syms: u8[>..] = [];
    push_u16_be(syms, 7);
    syms.append("Partial");
    syms.push(0);

    var irep = make_record(pool[..], 1, syms[..], 1, 1);
    push_u32_be(irep, 20);
    push_u16_be(irep, 1);
    push_u16_be(irep, 3);

    var out: u8[>..] = [];
    out.append("RITE0400");
    push_u32_be(out, 0);
    out.append("MATZ");
    out.append("0000");
    out.append("IREP");
    push_u32_be(out, (vm::IREP_SECTION_HEADER_BYTES + irep.len)as u32);
    out.append("0400");
    out.append(irep[..]);
    put_u32_be(out, 8, out.len as u32);
    return out;
}

// A second truncated package whose root interns two new symbols. Loading it
// after the symbol table is one entry below a bucket boundary forces a hash
// directory resize before the child record rejects the package.
fn truncated_symbol_package() -> u8[>..] {
    var syms: u8[>..] = [];
    push_u16_be(syms, 19);
    syms.append("HashBucketRollbackA");
    syms.push(0);
    push_u16_be(syms, 19);
    syms.append("HashBucketRollbackB");
    syms.push(0);

    var pool: u8[>..] = [];
    var irep = make_record(pool[..], 0, syms[..], 2, 1);
    push_u32_be(irep, 20);
    push_u16_be(irep, 1);
    push_u16_be(irep, 3);

    var out: u8[>..] = [];
    out.append("RITE0400");
    push_u32_be(out, 0);
    out.append("MATZ");
    out.append("0000");
    out.append("IREP");
    push_u32_be(out, (vm::IREP_SECTION_HEADER_BYTES + irep.len)as u32);
    out.append("0400");
    out.append(irep[..]);
    put_u32_be(out, 8, out.len as u32);
    return out;
}

fn test_failed_irep_parse_rolls_back_partial(t: goosetest::Test&) {
    let instance = counter(t);
    let records = vm::record_count(vm::g_abi_file);
    let pools = vm::pool_count(vm::g_abi_file);
    let syms = vm::symbol_ref_count(vm::g_abi_file);
    let symbols = vm::symbol_count();
    let symbol_bytes = vm::symbol_blob_length();
    let packages = vm::slab_package_count();
    let package_bytes = vm::slab_package_bytes_used();
    let used = vm::slab_used_bytes();

    var bad = truncated_package();
    t.assert_eq(1, vm::abi_load_irep(bad[..]));
    t.assert_true(starts_with(vm::abi_last_error(), "truncated"));
    t.assert_eq(records, vm::record_count(vm::g_abi_file));
    t.assert_eq(pools, vm::pool_count(vm::g_abi_file));
    t.assert_eq(syms, vm::symbol_ref_count(vm::g_abi_file));
    t.assert_eq(symbols, vm::symbol_count());
    t.assert_eq(symbol_bytes, vm::symbol_blob_length());
    t.assert_eq(packages, vm::slab_package_count());
    t.assert_eq(package_bytes, vm::slab_package_bytes_used());
    t.assert_eq(used, vm::slab_used_bytes());
    t.assert_eq(0, vm::g_abi_file.data.len);

    vm::abi_call(instance, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error(), "existing component survives a rejected package");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn test_symbol_hash_bucket_rollback_restores_budget(t: goosetest::Test&) {
    let instance = counter(t);
    let start = vm::symbol_count();
    var boundary: i64 = 256;
    while boundary <= start {
        boundary *= 2;
    }
    var filler = start;
    while vm::symbol_count() < boundary - 1 {
        vm::intern_symbol(str("hash_bucket_filler_", filler));
        filler += 1;
    }
    let symbols = vm::symbol_count();
    let symbol_bytes = vm::symbol_blob_length();
    let used = vm::slab_used_bytes();
    var bad = truncated_symbol_package();

    t.assert_eq(1, vm::abi_load_irep(bad[..]));
    t.assert_true(starts_with(vm::abi_last_error(), "truncated"));
    t.assert_eq(symbols, vm::symbol_count());
    t.assert_eq(symbol_bytes, vm::symbol_blob_length());
    t.assert_eq(used, vm::slab_used_bytes(),
        "a failed load must shrink hash buckets to their pre-load size");

    let first = vm::intern_symbol("HashBucketRollbackA");
    let second = vm::intern_symbol("HashBucketRollbackB");
    t.assert_eq(symbols as u32, first);
    t.assert_eq((symbols + 1)as u32, second);
    t.assert_true(vm::symbol_name(first) == "HashBucketRollbackA");
    t.assert_true(vm::symbol_name(second) == "HashBucketRollbackB");

    vm::abi_call(instance, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error(), "mounted component still runs");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn fill_classes(limit: i64) {
    while vm::state_class_count(vm::g_abi_pool) < limit {
        vm::state_define_class(vm::g_abi_pool, vm::intern_symbol("Filler"), vm::NULL_CLASS_ID);
    }
}

fn fill_methods(limit: i64) {
    while vm::method_count(vm::g_abi_machine) < limit {
        if !vm::method_push(vm::g_abi_machine, vm::MethodEntry {
                class_id: vm::NULL_CLASS_ID,
                name_symbol: vm::intern_symbol("FillerMethod"),
                irep_index: 0,
            }) {
            return;
        }
    }
}

fn next_chunk_boundary(count: i64) -> i64 {
    return (count / 256 + 1) * 256;
}

fn fill_records(limit: i64) {
    while vm::record_count(vm::g_abi_file) < limit {
        vm::record_push(vm::g_abi_file, vm::IrepRecord {
                record_offset_bytes: 0,
                record_size_bytes: 0,
                nlocals: 1,
                nregs: 1,
                child_count: 0,
                catch_count: 0,
                iseq_length_bytes: 0,
                iseq_offset_bytes: 0,
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
    }
}

fn test_failed_parse_after_reset_frees_package(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::g_abi_file.data.len);
    t.assert_eq(0, vm::slab_package_count());
    let used = vm::slab_used_bytes();

    var bad = truncated_package();
    t.assert_eq(1, vm::abi_load_irep(bad[..]));
    t.assert_true(starts_with(vm::abi_last_error(), "truncated"));
    t.assert_eq(0, vm::slab_package_count());
    t.assert_eq(used, vm::slab_used_bytes());
    t.assert_eq(0, vm::g_abi_file.data.len,
        "rolled-back load leaves the package slab empty");
    vm::abi_close();
}

fn test_failed_root_boot_reports_class_capacity(t: goosetest::Test&) {
    let instance = counter(t);
    t.assert_eq(0, vm::abi_load_irep(vm_abi_test::todo_rite()));

    fill_classes(next_chunk_boundary(vm::state_class_count(vm::g_abi_pool)));
    let classes = vm::state_class_count(vm::g_abi_pool);
    let consts = vm::const_count(vm::g_abi_pool);
    let methods = vm::method_count(vm::g_abi_machine);
    let native_methods = vm::native_method_count(vm::g_abi_machine);
    let definitions = vm::computed_def_count(vm::g_abi_machine);
    let roots = vm::computed_root_count(vm::g_abi_machine);
    let booted = vm::g_abi_machine.booted_roots;
    vm::slab_set_limit(vm::slab_used_bytes());

    let rejected = vm::abi_const_get(vm::intern_symbol("TodoList"));
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(starts_with(vm::abi_last_error(), "classes exhausted"));
    t.assert_eq(booted, vm::g_abi_machine.booted_roots);
    t.assert_eq(classes, vm::state_class_count(vm::g_abi_pool));
    t.assert_eq(consts, vm::const_count(vm::g_abi_pool));
    t.assert_eq(methods, vm::method_count(vm::g_abi_machine));
    t.assert_eq(native_methods, vm::native_method_count(vm::g_abi_machine));
    t.assert_eq(definitions, vm::computed_def_count(vm::g_abi_machine));
    t.assert_eq(roots, vm::computed_root_count(vm::g_abi_machine));

    t.assert_true(vm::abi_has_method(instance, vm::intern_symbol("increment")),
        "existing component methods survive a failed root boot");
    t.assert_false(vm::abi_has_error());
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

// @DisplayName("test_metadata_budget_exhaustion_rolls_back_chunks")
fn test_metadata_budget_rolls_back_chunks(t: goosetest::Test&) {
    let instance = counter(t);
    fill_records(next_chunk_boundary(vm::record_count(vm::g_abi_file)) - 1);
    let records = vm::record_count(vm::g_abi_file);
    let pools = vm::pool_count(vm::g_abi_file);
    let syms = vm::symbol_ref_count(vm::g_abi_file);
    let symbols = vm::symbol_count();
    let packages = vm::slab_package_count();
    let used = vm::slab_used_bytes();
    var bad = truncated_package();
    vm::slab_set_limit(used + bad.len + 30000);

    t.assert_eq(1, vm::abi_load_irep(bad[..]));
    t.assert_true(starts_with(vm::abi_last_error(), "truncated"));
    t.assert_eq(records, vm::record_count(vm::g_abi_file),
        "new record chunk released on rollback");
    t.assert_eq(pools, vm::pool_count(vm::g_abi_file));
    t.assert_eq(syms, vm::symbol_ref_count(vm::g_abi_file));
    t.assert_eq(symbols, vm::symbol_count());
    t.assert_eq(packages, vm::slab_package_count());
    t.assert_eq(used, vm::slab_used_bytes(),
        "metadata budget restored exactly after chunk rollback");

    vm::slab_use_default_limit();
    vm::abi_call(instance, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error(), "mounted component still runs");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn test_failed_root_boot_rolls_back_class_methods(t: goosetest::Test&) {
    let instance = counter(t);
    t.assert_eq(0, vm::abi_load_irep(vm_abi_test::todo_rite()));

    let class_target = next_chunk_boundary(vm::state_class_count(vm::g_abi_pool)) - 4;
    fill_classes(class_target);
    fill_methods(next_chunk_boundary(vm::method_count(vm::g_abi_machine)));
    let classes = vm::state_class_count(vm::g_abi_pool);
    let consts = vm::const_count(vm::g_abi_pool);
    let methods = vm::method_count(vm::g_abi_machine);
    let native_methods = vm::native_method_count(vm::g_abi_machine);
    let definitions = vm::computed_def_count(vm::g_abi_machine);
    let roots = vm::computed_root_count(vm::g_abi_machine);
    let booted = vm::g_abi_machine.booted_roots;
    let todo_symbol = vm::intern_symbol("TodoList");
    let used = vm::slab_used_bytes();
    vm::slab_set_limit(used + 2048);

    let rejected = vm::abi_const_get(todo_symbol);
    t.assert_true(vm::mrb_is_nil(rejected));
    t.assert_true(starts_with(vm::abi_last_error(),
        "VM methods exhausted"));
    t.assert_eq(booted, vm::g_abi_machine.booted_roots);
    t.assert_eq(classes, vm::state_class_count(vm::g_abi_pool),
        "partial class definition rolled back");
    t.assert_eq(consts, vm::const_count(vm::g_abi_pool));
    t.assert_eq(methods, vm::method_count(vm::g_abi_machine),
        "methods defined by the failed root rolled back");
    t.assert_eq(native_methods, vm::native_method_count(vm::g_abi_machine));
    t.assert_eq(definitions, vm::computed_def_count(vm::g_abi_machine));
    t.assert_eq(roots, vm::computed_root_count(vm::g_abi_machine));
    t.assert_eq(used, vm::slab_used_bytes(),
        "failed root boot restores hash buckets and table chunks");
    let _, todo_found = vm::vm_find_class(vm::g_abi_pool, vm::intern_symbol("TodoList"));
    t.assert_false(todo_found, "partial class definition rolled back");

    t.assert_true(vm::abi_has_method(instance, vm::intern_symbol("increment")),
        "existing component methods survive a failed root boot");
    t.assert_false(vm::abi_has_error());
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}
