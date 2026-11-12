// Tests for the Goose side of the opaque mruby C ABI.
namespace vm_abi_test;

import std;

import goosetest;
import vm;

let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
let TODO_CHI: const u8[:] = embed_file("../fixtures/todo.chi");
let USERS_CHI: const u8[:] = embed_file("../fixtures/users.chi");
let FETCH_PROBE_CHI: const u8[:] = embed_file("../fixtures/fetch_probe.chi");
let FAILING_INIT_CHI: const u8[:] = embed_file("../fixtures/failing_init.chi");
let WIDE_COMPONENT_CHI: const u8[:] = embed_file("../fixtures/wide_component.chi");
let PROPS_COMPONENT_CHI: const u8[:] = embed_file("../fixtures/props_component.chi");
let COUNTER_HTML: const u8[:] = "<div class='counter'><h2>Click me</h2><span class='count'>1</span><div class='buttons'><button data-action='decrement'>-</button><button data-action='increment'>+</button><button data-action='reset'>Reset</button></div></div>";
let TODO_HTML_EMPTY: const u8[:] = "<div class='todo'><h2>Todo List (0 items)</h2><ul></ul><div class='buttons'><button data-action='add_item'>Add</button><button data-action='toggle_last'>Toggle Last</button><button data-action='remove_last'>Remove Last</button></div></div>";
var g_counter_rite: u8[>..] = [];
var g_todo_rite: u8[>..] = [];
var g_users_rite: u8[>..] = [];
var g_fetch_probe_rite: u8[>..] = [];
var g_failing_init_rite: u8[>..] = [];
var g_wide_component_rite: u8[>..] = [];
var g_props_component_rite: u8[>..] = [];

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

fn users_rite() -> u8[:] {
    if g_users_rite.len == 0 {
        vm::vm_restore_rite_header(USERS_CHI, g_users_rite);
    }
    return g_users_rite[..];
}

fn fetch_probe_rite() -> u8[:] {
    if g_fetch_probe_rite.len == 0 {
        vm::vm_restore_rite_header(FETCH_PROBE_CHI, g_fetch_probe_rite);
    }
    return g_fetch_probe_rite[..];
}

fn failing_init_rite() -> u8[:] {
    if g_failing_init_rite.len == 0 {
        vm::vm_restore_rite_header(FAILING_INIT_CHI, g_failing_init_rite);
    }
    return g_failing_init_rite[..];
}

fn wide_component_rite() -> u8[:] {
    if g_wide_component_rite.len == 0 {
        vm::vm_restore_rite_header(WIDE_COMPONENT_CHI, g_wide_component_rite);
    }
    return g_wide_component_rite[..];
}

fn props_component_rite() -> u8[:] {
    if g_props_component_rite.len == 0 {
        vm::vm_restore_rite_header(PROPS_COMPONENT_CHI, g_props_component_rite);
    }
    return g_props_component_rite[..];
}

fn call_string(instance: u64, name: u8[:]) -> const u8[:] {
    let value = vm::abi_call(instance, vm::intern_symbol(name), 0);
    return vm::abi_string_bytes(value);
}

fn call_fixnum(instance: u64, name: u8[:]) -> i64 {
    let value = vm::abi_call(instance, vm::intern_symbol(name), 0);
    return vm::mrb_fixnum_value(value);
}

fn call_json(instance: u64, name: u8[:]) -> const u8[:] {
    let value = vm::abi_call(instance, vm::intern_symbol(name), 0);
    return vm::abi_value_json(value);
}

fn test_abi_mounts_typed_props_with_defaults(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(props_component_rite()));
    let klass = vm::abi_const_get(vm::intern_symbol("PropsComponent"));
    let instance = vm::abi_obj_new_with_props(vm::mrb_class_id(klass), "{}");
    t.assert_true(vm::mrb_is_state(instance));
    t.assert_false(vm::abi_has_error());

    t.assert_eq("default", call_string(instance, "label"));
    t.assert_eq(3, call_fixnum(instance, "count"));
    t.assert_eq("false", call_json(instance, "flag"));
    t.assert_eq("null", call_json(instance, "note"));
    t.assert_eq("[]", call_json(instance, "rows"));
    t.assert_eq("{}", call_json(instance, "meta"));
    // initialize runs after the defaults are installed.
    t.assert_eq("default", call_string(instance, "init_label"));
    t.assert_eq(3, call_fixnum(instance, "init_count"));
    t.assert_eq("null", call_json(instance, "init_note"));
    vm::abi_close();
}

fn test_abi_mounts_typed_props_before_initialize(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(props_component_rite()));
    let klass = vm::abi_const_get(vm::intern_symbol("PropsComponent"));
    let payload: const u8[:] = "{\"label\":\"from-parent\",\"count\":7,\"flag\":true,\"note\":\"\",\"rows\":[{\"id\":1}],\"meta\":{\"currency\":\"USD\"}}";
    let instance = vm::abi_obj_new_with_props(vm::mrb_class_id(klass), payload);
    t.assert_true(vm::mrb_is_state(instance));
    t.assert_false(vm::abi_has_error());

    t.assert_eq("from-parent", call_string(instance, "label"));
    t.assert_eq(7, call_fixnum(instance, "count"));
    t.assert_eq("true", call_json(instance, "flag"));
    t.assert_eq("\"\"", call_json(instance, "note"));
    t.assert_eq("[{\"id\":1}]", call_json(instance, "rows"));
    t.assert_eq("{\"currency\":\"USD\"}", call_json(instance, "meta"));
    // initialize observed the resolved inputs, and its later clobbering
    // assignments were restored from the independent second snapshot.
    t.assert_eq("from-parent", call_string(instance, "init_label"));
    t.assert_eq(7, call_fixnum(instance, "init_count"));
    t.assert_eq("\"\"", call_json(instance, "init_note"));
    t.assert_eq("[{\"id\":1}]", call_json(instance, "rows"));
    vm::abi_close();
}

fn test_abi_updates_typed_props_together(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(props_component_rite()));
    let klass = vm::abi_const_get(vm::intern_symbol("PropsComponent"));
    let instance = vm::abi_obj_new_with_props(vm::mrb_class_id(klass), "{}");

    t.assert_eq(0, vm::goose_vm_set_props_json(instance, "{\"label\":\"next\",\"count\":8}"));
    t.assert_false(vm::abi_has_error());
    t.assert_eq("next", call_string(instance, "label"));
    t.assert_eq(8, call_fixnum(instance, "count"));
    // Omitted props keep their last value.
    t.assert_eq("false", call_json(instance, "flag"));
    t.assert_eq("[]", call_json(instance, "rows"));

    t.assert_eq(-1, vm::goose_vm_set_props_json(instance, "[1,2]"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("next", call_string(instance, "label"));

    t.assert_eq(0, vm::abi_unregister_component(instance));
    t.assert_eq(-1, vm::goose_vm_set_props_json(instance, "{\"label\":\"gone\"}"));
    vm::abi_close();
}

fn test_abi_reclaims_replaced_prop_snapshots(t: goosetest::Test&) {
    let payload: const u8[:] = "{\"rows\":[1,2,3],\"meta\":{\"key\":\"value\"}}";
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(props_component_rite()));
    let klass = vm::abi_const_get(vm::intern_symbol("PropsComponent"));
    let instance = vm::abi_obj_new_with_props(vm::mrb_class_id(klass), "{}");

    var update = 0;
    while update < 300 {
        t.assert_eq(0, vm::goose_vm_set_props_json(instance, payload));
        update += 1;
    }
    vm::gc_collect(vm::g_abi_machine);
    t.assert_true(vm::abi_state_allocated_count() < 30, "old prop snapshots reclaimed");
    t.assert_eq("[1,2,3]", call_json(instance, "rows"));
    vm::abi_close();
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

fn test_abi_failed_call_does_not_stick(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_eq(0, vm::abi_register_binding(counter, 5, vm::intern_symbol("html")));

    vm::abi_call(counter, vm::intern_symbol("missing_handler"), 0);
    t.assert_true(vm::abi_has_error());
    t.assert_eq("Counter#missing_handler: unknown method", vm::abi_last_error());
    // Interning a method name starts a fresh entry: a previous call failure
    // must not make the host skip a real `mounted` callback.
    let html_symbol = vm::abi_intern("html");
    t.assert_false(vm::abi_has_error());
    t.assert_true(vm::abi_has_method(counter, html_symbol));

    t.assert_eq(1, vm::abi_flush_patches(counter));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(0, vm::abi_flush_patches(counter));
    t.assert_false(vm::abi_has_error());
    vm::abi_close();
}

fn test_abi_formats_ivar_capacity_error(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    vm::g_abi_machine.error = vm::VmError.IvarCapacity;
    vm::vm_set_error_context(vm::g_abi_machine, vm::mrb_class_id(counter_class),
        vm::intern_symbol("html"), -1);
    vm::abi_record_vm_error(vm::g_abi_machine);
    t.assert_true(vm::abi_has_error());
    t.assert_eq("Counter#html: ivar capacity exceeded", vm::abi_last_error());
    vm::abi_close();
}

fn test_abi_binding_errors_include_context(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_eq(0, vm::abi_register_binding(counter, 7, vm::intern_symbol("missing_getter")));

    t.assert_eq(-1, vm::abi_flush_patches(counter));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("Counter#missing_getter (binding 7): unknown method", vm::abi_last_error());
    vm::abi_close();
}

fn test_abi_method_req_argc_reads_target_enter(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    t.assert_eq(0, vm::abi_load_irep(users_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_eq(0, vm::abi_method_req_argc(counter, vm::intern_symbol("increment")));
    t.assert_eq(-1, vm::abi_method_req_argc(counter, vm::intern_symbol("missing")));

    let users_class = vm::abi_const_get(vm::intern_symbol("UserList"));
    let user_list = vm::abi_obj_new(vm::mrb_class_id(users_class));
    t.assert_eq(1, vm::abi_method_req_argc(user_list, vm::intern_symbol("on_users_loaded")));
    t.assert_false(vm::abi_has_error());
    vm::abi_close();
}

fn test_abi_dispatches_json_event_arguments(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(users_rite()));
    let users_class = vm::abi_const_get(vm::intern_symbol("UserList"));
    let user_list = vm::abi_obj_new(vm::mrb_class_id(users_class));
    let json_args = "[\"[{\\\"name\\\":\\\"Alice\\\"}]\"]";
    vm::abi_call_json(user_list, vm::intern_symbol("on_users_loaded"), json_args);
    t.assert_false(vm::abi_has_error());

    let users, users_ok = vm::state_get_ivar(vm::g_abi_pool, user_list,
        vm::intern_symbol("@users"));
    t.assert_true(users_ok);
    t.assert_true(vm::state_is_array(vm::g_abi_pool, users));
    t.assert_eq(1, vm::builtin_array_length(vm::g_abi_pool, vm::g_abi_scratch, users));
    t.assert_true(vm::builtin_string_bytes(vm::g_abi_pool, vm::g_abi_scratch,
        vm::builtin_array_get(vm::g_abi_pool, vm::g_abi_scratch, users, 0)) == "Alice");

    vm::abi_call_json(user_list, vm::intern_symbol("on_users_loaded"), "[");
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "bad JSON argument list");
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

fn test_abi_serializes_and_reads_hash_payloads(t: goosetest::Test&) {
    vm::abi_open();
    let payload = vm::builtin_hash_new(vm::g_abi_scratch);
    let target_key = vm::intern_symbol("target");
    let target = vm::abi_make_string("cowboy-logs");
    t.assert_true(vm::builtin_hash_set(vm::g_abi_pool, vm::g_abi_scratch, payload,
        vm::mrb_symbol(target_key), target));
    t.assert_true(vm::abi_is_hash(payload));
    t.assert_eq("{\"target\":\"cowboy-logs\"}", vm::abi_value_json(payload));

    let by_symbol = vm::abi_hash_get_symbol(payload, target_key);
    t.assert_true(vm::abi_string_bytes(by_symbol) == "cowboy-logs");
    let string_key = vm::abi_make_string("target");
    let by_string = vm::builtin_hash_get(vm::g_abi_pool, vm::g_abi_scratch, payload, string_key);
    t.assert_true(vm::abi_string_bytes(by_string) == "cowboy-logs");

    let nested = vm::builtin_hash_new(vm::g_abi_scratch);
    let id_key = vm::scratch_alloc_string(vm::g_abi_scratch, "id");
    let id = vm::scratch_alloc_string(vm::g_abi_scratch, "tr_9f2a");
    t.assert_true(vm::builtin_hash_set(vm::g_abi_pool, vm::g_abi_scratch, nested,
        id_key, id));
    t.assert_eq("{\"id\":\"tr_9f2a\"}", vm::abi_value_json(nested));
    t.assert_eq("null", vm::abi_value_json(vm::mrb_nil()));
    t.assert_eq("\"line\\n\\\"quoted\\\"\"",
        vm::abi_value_json(vm::abi_make_string("line\n\"quoted\"")));
    vm::abi_close();
}

fn test_abi_builds_fetch_requests_and_response_hash(t: goosetest::Test&) {
    vm::abi_open();
    vm::vm_begin_entry(vm::g_abi_machine);
    let instance = vm::abi_make_string("42");
    let url = vm::abi_make_string("/api/logs");
    let callback = vm::mrb_symbol(vm::intern_symbol("on_logs"));
    let options = vm::builtin_hash_new(vm::g_abi_scratch);
    let method_key = vm::mrb_symbol(vm::intern_symbol("method"));
    let method = vm::abi_make_string("POST");
    t.assert_true(vm::builtin_hash_set(vm::g_abi_pool, vm::g_abi_scratch, options,
        method_key, method));
    t.assert_eq(
        "{\"id\":7,\"instance\":\"42\",\"url\":\"/api/logs\",\"callback\":\"on_logs\",\"options\":{\"method\":\"POST\"}}\n",
        vm::abi_fetch_request_json(7, instance, url, callback, options));
    t.assert_eq(
        "{\"id\":8,\"instance\":\"42\",\"url\":\"/api/logs\",\"callback\":\"on_logs\",\"options\":{}}\n",
        vm::abi_fetch_request_json(8, instance, url, callback, vm::mrb_nil()));

    let response = vm::abi_fetch_response(
        "{\"status\":200,\"ok\":true,\"body\":\"payload\",\"data\":{\"rows\":[1,2]},\"error\":null}");
    let status_key = vm::mrb_symbol(vm::intern_symbol("status"));
    let ok_key = vm::mrb_symbol(vm::intern_symbol("ok"));
    let body_key = vm::mrb_symbol(vm::intern_symbol("body"));
    let data_key = vm::mrb_symbol(vm::intern_symbol("data"));
    let error_key = vm::mrb_symbol(vm::intern_symbol("error"));
    t.assert_eq(200, vm::mrb_fixnum_value(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, response, status_key)));
    t.assert_true(vm::mrb_is_true(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, response, ok_key)));
    t.assert_true(vm::builtin_string_bytes(vm::g_abi_pool, vm::g_abi_scratch,
        vm::builtin_hash_get(vm::g_abi_pool, vm::g_abi_scratch, response, body_key)) == "payload");
    let data = vm::builtin_hash_get(vm::g_abi_pool, vm::g_abi_scratch, response, data_key);
    let rows = vm::builtin_hash_get(vm::g_abi_pool, vm::g_abi_scratch, data,
        vm::mrb_symbol(vm::intern_symbol("rows")));
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(
        vm::g_abi_pool, vm::g_abi_scratch, rows, 0)));
    t.assert_true(vm::mrb_is_nil(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, response, error_key)));

    let defaults = vm::abi_fetch_response("{}");
    t.assert_eq(0, vm::mrb_fixnum_value(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, defaults, status_key)));
    t.assert_true(vm::mrb_is_false(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, defaults, ok_key)));
    t.assert_true(vm::vm_string_equals(vm::g_abi_machine,
        vm::builtin_hash_get(vm::g_abi_pool, vm::g_abi_scratch, defaults, body_key), ""));
    t.assert_true(vm::mrb_is_nil(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, defaults, data_key)));
    t.assert_true(vm::mrb_is_nil(vm::builtin_hash_get(
        vm::g_abi_pool, vm::g_abi_scratch, defaults, error_key)));

    vm::abi_fetch_response("[]");
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "bad fetch response");
    vm::vm_end_entry(vm::g_abi_machine);
    vm::abi_close();
}

fn test_abi_mounts_component_with_100_ivars(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(wide_component_rite()));
    t.assert_false(vm::abi_has_error());
    let wide_class = vm::abi_const_get(vm::intern_symbol("WideComponent"));
    let wide = vm::abi_obj_new(vm::mrb_class_id(wide_class));
    t.assert_true(vm::mrb_is_state(wide));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(100, vm::state_ivar_count(vm::g_abi_pool));

    t.assert_eq(0, vm::abi_register_binding(wide, 0, vm::intern_symbol("late")));
    vm::abi_call(wide, vm::intern_symbol("set_late"), 0);
    t.assert_false(vm::abi_has_error());

    t.assert_eq(1, vm::abi_flush_patches(wide));
    t.assert_false(vm::abi_has_error());
    let patches = vm::abi_patch_bytes();
    t.assert_eq(8, patches.len);
    t.assert_eq(0, patches[0]);
    t.assert_eq(0, patches[1]);
    t.assert_eq(2, patches[2]);
    t.assert_eq(0, patches[3]);
    t.assert_eq(0, patches[4]);
    t.assert_eq(0, patches[5]);
    t.assert_eq(0x37, patches[6]);
    t.assert_eq(0x31, patches[7]);
    vm::abi_close();
}

fn test_abi_failed_initialize_rolls_back_mount(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(failing_init_rite()));
    t.assert_false(vm::abi_has_error());
    let failing_class = vm::abi_const_get(vm::intern_symbol("FailingInit"));
    t.assert_true(vm::abi_is_class(failing_class));

    let failed = vm::abi_obj_new(vm::mrb_class_id(failing_class));
    t.assert_true(vm::mrb_is_nil(failed));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("FailingInit#initialize: unknown method", vm::abi_last_error());
    t.assert_eq(0, vm::abi_binding_count());
    t.assert_eq(0, vm::abi_component_count());

    // The class and its bytecode survive the rollback, so a later valid mount
    // in the same runtime still works.
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_true(vm::mrb_is_state(counter));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(1, vm::abi_component_count());
    vm::abi_close();
}

fn test_abi_unregister_releases_stale_handle(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let first = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_eq(0, vm::abi_register_binding(first, 0, vm::intern_symbol("html")));
    t.assert_eq(0, vm::abi_register_binding(first, 1, vm::intern_symbol("increment")));
    t.assert_eq(2, vm::abi_binding_count());
    t.assert_eq(1, vm::abi_component_count());

    t.assert_eq(0, vm::abi_unregister_component(first));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(0, vm::abi_binding_count());
    t.assert_eq(0, vm::abi_component_count());
    // Repeated disposal is safe and does not report an error.
    t.assert_eq(0, vm::abi_unregister_component(first));
    t.assert_false(vm::abi_has_error());

    t.assert_eq(-1, vm::abi_register_binding(first, 2, vm::intern_symbol("html")));
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "disposed instance");
    t.assert_eq(-1, vm::abi_flush_patches(first));
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "disposed instance");
    vm::abi_call(first, vm::intern_symbol("increment"), 0);
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "disposed instance");
    t.assert_eq(-1, vm::abi_deliver_fetch(first, vm::intern_symbol("html"),
        "{\"status\":200,\"ok\":true}"));
    t.assert_true(vm::abi_has_error());

    // A fresh mount gets new registrations and the shared class still runs.
    let second = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_true(vm::mrb_is_state(second));
    t.assert_false(vm::mrb_value_identical(first, second));
    t.assert_eq(0, vm::abi_register_binding(second, 0, vm::intern_symbol("html")));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(1, vm::abi_binding_count());
    t.assert_eq(1, vm::abi_component_count());
    vm::abi_close();
}

fn test_abi_fetch_callback_hash(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(fetch_probe_rite()));
    let probe_class = vm::abi_const_get(vm::intern_symbol("FetchProbe"));
    let probe = vm::abi_obj_new(vm::mrb_class_id(probe_class));
    let callback = vm::intern_symbol("on_logs");

    t.assert_eq(0, vm::abi_deliver_fetch(probe, callback,
        "{\"status\":200,\"ok\":true,\"body\":\"payload\",\"data\":{\"rows\":[10,20]},\"error\":null}"));
    t.assert_false(vm::abi_has_error());
    let status, status_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@status"));
    t.assert_true(status_ok);
    t.assert_eq(200, vm::mrb_fixnum_value(status));
    let ok, ok_ok = vm::state_get_ivar(vm::g_abi_pool, probe, vm::intern_symbol("@ok"));
    t.assert_true(ok_ok);
    t.assert_true(vm::mrb_is_true(ok));
    let row, row_ok = vm::state_get_ivar(vm::g_abi_pool, probe, vm::intern_symbol("@row"));
    t.assert_true(row_ok);
    t.assert_eq(10, vm::mrb_fixnum_value(row));
    let error, error_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@error"));
    t.assert_true(error_ok);
    t.assert_true(vm::abi_string_bytes(error) == "none");

    t.assert_eq(0, vm::abi_deliver_fetch(probe, callback,
        "{\"status\":500,\"ok\":false,\"body\":\"boom\",\"data\":null,\"error\":\"HTTP 500 Server Error\"}"));
    t.assert_false(vm::abi_has_error());
    let failed_status, failed_status_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@status"));
    t.assert_true(failed_status_ok);
    t.assert_eq(500, vm::mrb_fixnum_value(failed_status));
    let failed_ok, failed_ok_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@ok"));
    t.assert_true(failed_ok_ok);
    t.assert_true(vm::mrb_is_false(failed_ok));
    let failed_error, failed_error_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@error"));
    t.assert_true(failed_error_ok);
    t.assert_true(vm::abi_string_bytes(failed_error) == "HTTP 500 Server Error");

    t.assert_eq(-1, vm::abi_deliver_fetch(probe, callback, "[]"));
    t.assert_true(vm::abi_has_error());
    t.assert_true(vm::abi_last_error() == "bad fetch response");
    let unchanged_status, unchanged_status_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@status"));
    t.assert_true(unchanged_status_ok);
    t.assert_eq(500, vm::mrb_fixnum_value(unchanged_status));

    t.assert_eq(-1, vm::abi_deliver_fetch(probe, vm::intern_symbol("missing_callback"),
        "{\"status\":500,\"ok\":false}"));
    t.assert_true(vm::abi_has_error());
    vm::abi_close();
}

fn test_abi_thousand_ivar_writes_stay_bounded(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(counter_rite()));
    let counter_class = vm::abi_const_get(vm::intern_symbol("Counter"));
    let counter = vm::abi_obj_new(vm::mrb_class_id(counter_class));
    t.assert_false(vm::abi_has_error());
    var update = 0;
    while update < 1000 {
        t.assert_eq(0, vm::goose_vm_set_ivar_string(counter, "label", "replacement"));
        update += 1;
    }
    t.assert_false(vm::abi_has_error());
    t.assert_true(vm::state_object_count(vm::g_abi_pool)
        <= 2 + vm::GC_ALLOCATION_INTERVAL);
    vm::gc_collect(vm::g_abi_machine);
    t.assert_eq(2, vm::state_allocated_object_count(vm::g_abi_pool));
    let stored, found = vm::state_get_ivar(vm::g_abi_pool, counter, vm::intern_symbol("@label"));
    t.assert_true(found);
    t.assert_true(vm::abi_string_bytes(stored) == "replacement");
    vm::abi_close();
}

// Pins the setter convention used by the loader: 0 is success, -1 is failure,
// and an identical replacement is still success without emitting a patch.
fn test_abi_set_ivar_string_return_codes(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(wide_component_rite()));
    let wide_class = vm::abi_const_get(vm::intern_symbol("WideComponent"));
    let wide = vm::abi_obj_new(vm::mrb_class_id(wide_class));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(0, vm::abi_register_binding(wide, 0, vm::intern_symbol("late")));

    t.assert_eq(0, vm::goose_vm_set_ivar_string(wide, "v70", "alpha"));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(1, vm::abi_flush_patches(wide));
    t.assert_false(vm::abi_has_error());
    let patches = vm::abi_patch_bytes();
    t.assert_eq(11, patches.len);
    t.assert_eq(0, patches[0]);
    t.assert_eq(0, patches[1]);
    t.assert_eq(5, patches[2]);
    t.assert_eq(0x61, patches[6]);

    // Identical replacement: success, no dirty bit, no patch.
    t.assert_eq(0, vm::goose_vm_set_ivar_string(wide, "v70", "alpha"));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(0, vm::abi_flush_patches(wide));
    t.assert_false(vm::abi_has_error());

    t.assert_eq(0, vm::goose_vm_set_ivar_string(wide, "v70", "beta"));
    t.assert_false(vm::abi_has_error());
    t.assert_eq(1, vm::abi_flush_patches(wide));
    let changed = vm::abi_patch_bytes();
    t.assert_eq(0x62, changed[6]);

    t.assert_eq(-1, vm::goose_vm_set_ivar_string(wide, "", "beta"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("empty ivar name", vm::abi_last_error());

    let not_instance = vm::abi_make_string("not an instance");
    t.assert_false(vm::abi_has_error());
    t.assert_eq(-1, vm::goose_vm_set_ivar_string(not_instance, "v70", "beta"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("unknown component instance", vm::abi_last_error());

    t.assert_eq(0, vm::abi_unregister_component(wide));
    t.assert_eq(-1, vm::goose_vm_set_ivar_string(wide, "v70", "gone"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("disposed instance", vm::abi_last_error());
    vm::abi_close();
}

fn test_abi_host_result_keeps_typing_and_errors(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq("42", vm::abi_value_json(
        vm::abi_host_result("{\"ok\":true,\"value\":42}")));
    t.assert_false(vm::abi_has_error());
    t.assert_eq("\"ready\"", vm::abi_value_json(
        vm::abi_host_result("{\"ok\":true,\"value\":\"ready\"}")));
    t.assert_eq("[1,2]", vm::abi_value_json(
        vm::abi_host_result("{\"ok\":true,\"value\":[1,2]}")));
    t.assert_eq("{\"ok\":false,\"value\":null,\"error\":null}", vm::abi_value_json(
        vm::abi_host_result_hash("{}")));

    t.assert_true(vm::mrb_is_nil(vm::abi_host_result(
        "{\"ok\":false,\"value\":null,\"error\":\"no locale\"}")));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("no locale", vm::abi_last_error());

    t.assert_true(vm::mrb_is_nil(vm::abi_host_result("[]")));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("bad host capability result", vm::abi_last_error());
    vm::abi_close();
}

fn test_abi_builds_host_capability_requests(t: goosetest::Test&) {
    vm::abi_open();
    let instance = vm::abi_make_string("42");
    let capability = vm::abi_make_string("probe");
    let operation = vm::abi_make_string("ping");
    let args, parsed = vm::json_parse_document(
        vm::g_abi_pool, vm::g_abi_scratch, "[41,\"x\"]");
    t.assert_true(parsed);
    let callback = vm::mrb_symbol(vm::intern_symbol("on_ping"));

    t.assert_eq(
        "{\"__host\":\"capability_async\",\"id\":3,\"instance\":\"42\",\"capability\":\"probe\",\"operation\":\"ping\",\"args\":[41,\"x\"],\"callback\":\"on_ping\"}\n",
        vm::abi_capability_request_json(
        3, instance, capability, operation, args, callback));
    t.assert_false(vm::abi_has_error());

    t.assert_eq("", vm::abi_capability_request_json(
        4, instance, capability, operation, vm::abi_make_string("not an array"),
        callback));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("bad host capability request", vm::abi_last_error());
    vm::abi_close();
}

fn test_abi_delivers_host_capability_results(t: goosetest::Test&) {
    vm::abi_open();
    t.assert_eq(0, vm::abi_load_irep(fetch_probe_rite()));
    let probe_class = vm::abi_const_get(vm::intern_symbol("FetchProbe"));
    let probe = vm::abi_obj_new(vm::mrb_class_id(probe_class));
    let callback = vm::intern_symbol("on_logs");

    t.assert_eq(0, vm::abi_deliver_host_result(probe, callback,
        "{\"ok\":true,\"value\":null,\"error\":null,\"status\":201,\"data\":{\"rows\":[77]}}"));
    t.assert_false(vm::abi_has_error());
    let status, status_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@status"));
    t.assert_true(status_ok);
    t.assert_eq(201, vm::mrb_fixnum_value(status));
    let row, row_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@row"));
    t.assert_true(row_ok);
    t.assert_eq(77, vm::mrb_fixnum_value(row));
    let error, error_ok = vm::state_get_ivar(vm::g_abi_pool, probe,
        vm::intern_symbol("@error"));
    t.assert_true(error_ok);
    t.assert_true(vm::abi_string_bytes(error) == "none");

    t.assert_eq(-1, vm::abi_deliver_host_result(probe, callback, "[]"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("bad host capability result", vm::abi_last_error());

    t.assert_eq(0, vm::abi_unregister_component(probe));
    t.assert_eq(-1, vm::abi_deliver_host_result(probe, callback,
        "{\"ok\":true,\"value\":null}"));
    t.assert_true(vm::abi_has_error());
    t.assert_eq("disposed instance", vm::abi_last_error());
    vm::abi_close();
}
