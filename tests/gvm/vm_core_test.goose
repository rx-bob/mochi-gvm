// Tests for the scalar register VM that executes `counter.chi`.
//
// Every test first parses the shared, restored RITE fixture into its own
// `RiteFile`, then builds `StatePool`/`ScratchArena` roots and a `Vm` that
// borrows all three. Loading must happen before the VM exists because the
// loader shrinks the file's record and pool arrays. The lifecycle test covers
// the plan's exact acceptance strings; the negative tests prove that bad
// bytecode, classes, methods and receivers report a structured `VmError`
// instead of aborting.
namespace vm_core_test;

import std;

import goosetest;
import vm;

let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
let COUNTER_HTML_2: const u8[:] = "<div class='counter'><h2>Click me</h2><span class='count'>2</span><div class='buttons'><button data-action='decrement'>-</button><button data-action='increment'>+</button><button data-action='reset'>Reset</button></div></div>";
let COUNTER_HTML_0: const u8[:] = "<div class='counter'><h2>Click me</h2><span class='count'>0</span><div class='buttons'><button data-action='decrement'>-</button><button data-action='increment'>+</button><button data-action='reset'>Reset</button></div></div>";

// The complete RITE buffer is a process-lifetime fixture because `RiteFile`
// views the bytes and every test reuses the same stable storage.
var g_counter_rite: u8[>..] = [];

fn counter_rite() -> u8[:] {
    if g_counter_rite.len == 0 {
        vm::vm_restore_rite_header(COUNTER_CHI, g_counter_rite);
    }
    return g_counter_rite[..];
}

fn load_counter(file: vm::RiteFile&) -> vm::ParseError {
    return vm::vm_load_irep(file, counter_rite());
}

fn test_restore_header_rebuilds_rite(t: goosetest::Test&) {
    let full = counter_rite();
    t.assert_eq(751, full.len);
    t.assert_true(full[0..8] == "RITE0400");
    let binary_size, size_ok = vm::read_u32(full, 8);
    t.assert_true(size_ok);
    t.assert_eq(751, binary_size);
    let end_at = full.len - 8;
    t.assert_true(full[end_at..end_at + 4] == "END\0");
}

fn test_load_counter_irep(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq(7, machine.file.records.len);
    t.assert_eq(1, machine.file.records[0].child_count);
    t.assert_eq(3, machine.file.records[0].nregs);
    t.assert_eq(0, machine.methods.len);
}

fn test_initialize_sets_default_ivars(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);

    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    t.assert_true(vm::mrb_is_state(counter));
    t.assert_eq(vm::VmError.Ok, machine.error);

    let count, count_ok = vm::state_get_ivar(pool, counter, vm::intern_symbol("@count"));
    t.assert_true(count_ok);
    t.assert_eq(0, vm::mrb_fixnum_value(count));
    let label, label_ok = vm::state_get_ivar(pool, counter, vm::intern_symbol("@label"));
    t.assert_true(label_ok);
    t.assert_true(vm::state_string_bytes(pool, label) == "Click me");

    let incremented = vm::vm_call0(machine, counter, vm::intern_symbol("increment"));
    t.assert_eq(1, vm::mrb_fixnum_value(incremented));
    vm::vm_end_entry(machine);

    let reinitialized = vm::vm_call0(machine, counter, vm::intern_symbol("initialize"));
    t.assert_true(vm::vm_string_equals(machine, reinitialized, "Click me"));
    vm::vm_end_entry(machine);
    let reset_count, reset_ok = vm::state_get_ivar(pool, counter, vm::intern_symbol("@count"));
    t.assert_true(reset_ok);
    t.assert_eq(0, vm::mrb_fixnum_value(reset_count));
}

fn test_counter_lifecycle_renders_exact_html(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);

    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    let increment = vm::intern_symbol("increment");
    let first = vm::vm_call0(machine, counter, increment);
    t.assert_eq(1, vm::mrb_fixnum_value(first));
    vm::vm_end_entry(machine);
    let second = vm::vm_call0(machine, counter, increment);
    t.assert_eq(2, vm::mrb_fixnum_value(second));
    vm::vm_end_entry(machine);
    let third = vm::vm_call0(machine, counter, increment);
    t.assert_eq(3, vm::mrb_fixnum_value(third));
    vm::vm_end_entry(machine);
    let decremented = vm::vm_call0(machine, counter, vm::intern_symbol("decrement"));
    t.assert_eq(2, vm::mrb_fixnum_value(decremented));
    vm::vm_end_entry(machine);

    let html = vm::vm_call0(machine, counter, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, html, COUNTER_HTML_2));
    vm::vm_end_entry(machine);

    vm::vm_call0(machine, counter, vm::intern_symbol("reset"));
    vm::vm_end_entry(machine);
    let html_zero = vm::vm_call0(machine, counter, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, html_zero, COUNTER_HTML_0));
    vm::vm_end_entry(machine);
    t.assert_eq(0, vm::scratch_bytes_used(scratch));
    t.assert_eq(0, vm::scratch_object_count(scratch));
    t.assert_eq(1, vm::state_component_count(pool));
}

fn test_load_rejects_truncated_bytes(t: goosetest::Test&) {
    var broken: u8[>..] = [];
    broken.append("RITE");
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = vm::vm_load_irep(file, broken[..]);
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
    t.assert_eq(vm::ParseError.Truncated, load_error);
    t.assert_eq(0, machine.file.records.len);
    t.assert_eq(0, machine.methods.len);
}

fn test_instantiate_unknown_class_fails(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    let instance = vm::vm_instantiate(machine, vm::intern_symbol("Missing"));
    t.assert_true(vm::mrb_is_nil(instance));
    t.assert_eq(vm::VmError.NoClass, machine.error);
    t.assert_eq(0, vm::state_component_count(pool));
}

fn test_call_unknown_method_fails(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    let result = vm::vm_call0(machine, counter, vm::intern_symbol("missing"));
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.NoMethod, machine.error);
    vm::vm_end_entry(machine);
}

fn test_call_requires_instance_receiver(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    let result = vm::vm_call0(machine, vm::mrb_nil(), vm::intern_symbol("increment"));
    t.assert_true(vm::mrb_is_nil(result));
    t.assert_eq(vm::VmError.BadReceiver, machine.error);
    vm::vm_end_entry(machine);
}

fn test_tick_reset_reclaims_scratch(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    t.assert_eq(0, vm::scratch_bytes_used(scratch));

    let html = vm::vm_call0(machine, counter, vm::intern_symbol("html"));
    t.assert_true(vm::vm_string_equals(machine, html, COUNTER_HTML_0));
    t.assert_true(vm::scratch_bytes_used(scratch) > 0);
    t.assert_true(vm::scratch_object_count(scratch) > 0);
    vm::vm_end_entry(machine);
    t.assert_eq(0, vm::scratch_bytes_used(scratch));
    t.assert_eq(0, vm::scratch_object_count(scratch));
    t.assert_eq(0, machine.regs.len);
    t.assert_eq(0, machine.frames.len);

    let count, count_ok = vm::state_get_ivar(pool, counter, vm::intern_symbol("@count"));
    t.assert_true(count_ok);
    t.assert_eq(0, vm::mrb_fixnum_value(count));
}

fn test_repeated_renders_keep_state_flat(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let load_error = load_counter(file);
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
    t.assert_eq(vm::ParseError.Ok, load_error);
    let counter = vm::vm_instantiate(machine, vm::intern_symbol("Counter"));
    let html_sym = vm::intern_symbol("html");
    let base_objects = vm::state_object_count(pool);
    let base_bytes = vm::state_bytes_used(pool);

    for _ in 100 {
        let html = vm::vm_call0(machine, counter, html_sym);
        assert(vm::vm_string_equals(machine, html, COUNTER_HTML_0));
        vm::vm_end_entry(machine);
    }

    t.assert_eq(base_objects, vm::state_object_count(pool));
    t.assert_eq(base_bytes, vm::state_bytes_used(pool));
    t.assert_eq(0, vm::scratch_bytes_used(scratch));
    t.assert_eq(0, vm::scratch_object_count(scratch));
}
