// Tests for the Goose side of the opaque mruby C ABI.
namespace vm_abi_test;

import std;

import goosetest;
import vm;

let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
let TODO_CHI: const u8[:] = embed_file("../fixtures/todo.chi");
let COUNTER_HTML: const u8[:] = "<div class='counter'><h2>Click me</h2><span class='count'>1</span><div class='buttons'><button data-action='decrement'>-</button><button data-action='increment'>+</button><button data-action='reset'>Reset</button></div></div>";
let TODO_HTML_EMPTY: const u8[:] = "<div class='todo'><h2>Todo List (0 items)</h2><ul></ul><div class='buttons'><button data-action='add_item'>Add</button><button data-action='toggle_last'>Toggle Last</button><button data-action='remove_last'>Remove Last</button></div></div>";
var g_counter_rite: u8[>..] = [];
var g_todo_rite: u8[>..] = [];

fn counter_rite() -> u8[:] {
    if g_counter_rite.len == 0 {
        vm::vm_restore_rite_header(COUNTER_CHI, g_counter_rite);
    }
    return g_counter_rite[..];
}

fn todo_rite() -> u8[:] {
    if g_todo_rite.len == 0 {
        vm::vm_restore_rite_header(TODO_CHI, g_todo_rite);
    }
    return g_todo_rite[..];
}

fn test_abi_loads_and_calls_counter(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    t.assert_false(vm::abi_has_error());
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    t.assert_true(vm::abi_is_class(counter_class));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_true(vm::mrb_is_state(counter));
    t.assert_false(vm::abi_has_error());

    vm::abi_call(counter, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error());
    let html = vm::abi_call(counter, vm::intern_symbol("html"), 0);
    t.assert_false(vm::abi_has_error());
    t.assert_true(vm::abi_string_bytes(html) == COUNTER_HTML);
    vm::abi_close();
}

fn test_abi_appends_programs_and_keeps_methods(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    vm::abi_call(counter, vm::intern_symbol("increment"), 0);
    let first_html = vm::abi_call(counter, vm::intern_symbol("html"), 0);
    t.assert_eq(COUNTER_HTML, vm::abi_string_bytes(first_html), "first counter html");

    t.assert_eq(0, vm::abi_load_irep(todo_rite()));
    let kept_html = vm::abi_call(counter, vm::intern_symbol("html"), 0);
    t.assert_true(vm::abi_string_bytes(kept_html) == COUNTER_HTML);
    vm::abi_call(counter, vm::intern_symbol("increment"), 0);
    t.assert_false(vm::abi_has_error());

    let todo_class = vm::abi_const_get(vm::intern_symbol("TodoList"));
    t.assert_true(vm::abi_is_class(todo_class));
    let todo = vm::abi_obj_new(vm::mrb_class_id(todo_class));
    let todo_html = vm::abi_call(todo, vm::intern_symbol("html"), 0);
    t.assert_true(vm::abi_string_bytes(todo_html) == TODO_HTML_EMPTY);
    vm::abi_close();
}

fn test_abi_module_and_string_values(t: goosetest::Test&) {
    vm::abi_open();
    let before_load = vm::abi_const_get(vm::intern_symbol("Mochi"));
    t.assert_true(vm::abi_is_class(before_load));
    let mochi = vm::abi_define_module(vm::intern_symbol("Mochi"));
    t.assert_eq(vm::BUILTIN_MOCHI_CLASS_ID, mochi);
    t.assert_eq(0, vm::abi_define_native(mochi, vm::intern_symbol("fetch"), 0));
    t.assert_false(vm::abi_has_error());

    let text = vm::abi_make_string("hello");
    t.assert_true(vm::abi_is_string(text));
    t.assert_true(vm::abi_string_bytes(text) == "hello");
    t.assert_eq(5, vm::abi_string_bytes(text).len);
    vm::abi_close();
}

fn test_abi_reports_parse_errors(t: goosetest::Test&) {
    vm::abi_open();
    var bad: u8[>..] = [];
    bad.append("XXXXXXXXXXXXXXXXXXXX");
    let result = vm::abi_load_irep(bad[..]);
    t.assert_true(result != 0);
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "bad RITE magic");
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    t.assert_false(vm::abi_has_error());
    vm::abi_close();
}
