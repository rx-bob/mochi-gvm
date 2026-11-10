// Tests for the Goose side of the opaque mruby C ABI.
namespace vm_abi_test;

import std;

import goosetest;
import vm;

let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
let TODO_CHI: const u8[:] = embed_file("../fixtures/todo.chi");
let USERS_CHI: const u8[:] = embed_file("../fixtures/users.chi");
let FETCH_PROBE_CHI: const u8[:] = embed_file("../fixtures/fetch_probe.chi");
let COUNTER_HTML: const u8[:] = "<div class='counter'><h2>Click me</h2><span class='count'>1</span><div class='buttons'><button data-action='decrement'>-</button><button data-action='increment'>+</button><button data-action='reset'>Reset</button></div></div>";
let TODO_HTML_EMPTY: const u8[:] = "<div class='todo'><h2>Todo List (0 items)</h2><ul></ul><div class='buttons'><button data-action='add_item'>Add</button><button data-action='toggle_last'>Toggle Last</button><button data-action='remove_last'>Remove Last</button></div></div>";
var g_counter_rite: u8[>..] = [];
var g_todo_rite: u8[>..] = [];
var g_users_rite: u8[>..] = [];
var g_fetch_probe_rite: u8[>..] = [];

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
