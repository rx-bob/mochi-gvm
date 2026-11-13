// Host capabilities for Mochi components: storage, routing, timers, and props.
namespace vm;

import.builtins;
import.json_args;
import.rite_types;
import.scratch_alloc;
import.signals;
import.state_pool;
import.value_arena;
import.vm_core;
import.vm_methods;

struct HostStorageEntry {
    key_symbol: u32,
    offset: i64,
    length: i64,
    active: bool,
}

var g_host_storage: HostStorageEntry[>..] = [];
var g_host_blob: u8[>..] = [];
var g_host_route: u8[..1024] = [];
var g_host_route_info: u8[..8192] = [];
var g_host_outbox: u8[>..] = [];
var g_host_next_timer_id: i64 = 1;

fn host_reset() {
    g_host_storage.clear();
    g_host_blob.clear();
    g_host_route.clear();
    g_host_route_info.clear();
    g_host_outbox.clear();
    g_host_next_timer_id = 1;
}

fn host_append_json_escaped(out: u8[>..]&, text: const u8[:]) {
    out.push(34);
    var i = 0;
    while i < text.len {
        let b = text[i];
        if b == 34 || b == 92 {
            out.push(92);
            out.push(b);
        } else if b == 10 {
            out.append("\\n");
        } else if b == 13 {
            out.append("\\r");
        } else if b == 9 {
            out.append("\\t");
        } else {
            out.push(b);
        }
        i += 1;
    }
    out.push(34);
}

fn host_storage_put_raw(key: const u8[:], value: const u8[:]) {
    if key.len == 0 {
        return;
    }
    let sym = intern_symbol(key);
    let offset = g_host_blob.len;
    g_host_blob.append(value);
    for idx in 0..g_host_storage.len {
        if g_host_storage[idx].key_symbol == sym {
            g_host_storage[idx].offset = offset;
            g_host_storage[idx].length = value.len;
            g_host_storage[idx].active = true;
            return;
        }
    }
    g_host_storage.push(HostStorageEntry {
            key_symbol: sym,
            offset: offset,
            length: value.len,
            active: true,
        });
}

fn host_storage_get_raw(key: const u8[:]) -> const u8[:], bool {
    if key.len == 0 {
        return "", false;
    }
    let sym = intern_symbol(key);
    for entry in g_host_storage {
        if entry.key_symbol == sym && entry.active {
            return g_host_blob[entry.offset..(entry.offset + entry.length)], true;
        }
    }
    return "", false;
}

fn host_storage_remove_raw(key: const u8[:]) {
    if key.len == 0 {
        return;
    }
    let sym = intern_symbol(key);
    for idx in 0..g_host_storage.len {
        if g_host_storage[idx].key_symbol == sym {
            g_host_storage[idx].active = false;
            return;
        }
    }
}

fn host_set_route_raw(path: const u8[:]) {
    g_host_route.clear();
    if path.len <= 1024 {
        g_host_route.append(path);
    }
}

fn host_set_route_info_raw(info: const u8[:]) {
    g_host_route_info.clear();
    if info.len <= 8192 {
        g_host_route_info.append(info);
    }
}

fn host_current_instance(machine: Vm&) -> MrbValue, bool {
    if machine.frames.len == 0 {
        return mrb_nil(), false;
    }
    return machine.frames[machine.frames.len - 1].self_value, true;
}

fn host_outbox_bytes() -> const u8[:] {
    return g_host_outbox[..];
}

fn host_clear_outbox() {
    g_host_outbox.clear();
}

fn host_arg_text(machine: Vm&, value: MrbValue, buf: u8[>..]&) -> const u8[:] {
    let key_text, ok = builtin_hash_key_text(machine.pool, machine.scratch, value);
    if ok {
        return key_text;
    }
    vm_append_value_text(machine, buf, value);
    return buf[..];
}

fn vm_call_mochi_storage(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if (name == "storage_get" || name == "get_storage") && args.len >= 1 {
        var kbuf: u8[>..] = [];
        let key = host_arg_text(machine, args[0], kbuf);
        let val, found = host_storage_get_raw(key);
        if found {
            return scratch_alloc_string(machine.scratch, val), true;
        }
        if args.len >= 2 {
            return args[1], true;
        }
        return mrb_nil(), true;
    }
    if (name == "storage_set" || name == "set_storage") && args.len >= 2 {
        var kbuf: u8[>..] = [];
        var vbuf: u8[>..] = [];
        let key = host_arg_text(machine, args[0], kbuf);
        let val = host_arg_text(machine, args[1], vbuf);
        host_storage_put_raw(key, val);
        g_host_outbox.append("{\"__host\":\"storage_set\",\"key\":");
        host_append_json_escaped(g_host_outbox, key);
        g_host_outbox.append(",\"value\":");
        host_append_json_escaped(g_host_outbox, val);
        g_host_outbox.append("}\n");
        return args[1], true;
    }
    if (name == "storage_remove" || name == "remove_storage") && args.len >= 1 {
        var kbuf: u8[>..] = [];
        let key = host_arg_text(machine, args[0], kbuf);
        host_storage_remove_raw(key);
        g_host_outbox.append("{\"__host\":\"storage_remove\",\"key\":");
        host_append_json_escaped(g_host_outbox, key);
        g_host_outbox.append("}\n");
        return mrb_true(), true;
    }
    if name == "storage_subscribe" && args.len >= 2 {
        let instance, has_instance = host_current_instance(machine);
        if !has_instance {
            return mrb_false(), true;
        }
        var kbuf: u8[>..] = [];
        var cbuf: u8[>..] = [];
        let key = host_arg_text(machine, args[0], kbuf);
        let callback = host_arg_text(machine, args[1], cbuf);
        if key.len == 0 || callback.len == 0 {
            return mrb_false(), true;
        }
        g_host_outbox.append("{\"__host\":\"storage_subscribe\",\"key\":");
        host_append_json_escaped(g_host_outbox, key);
        g_host_outbox.append(",\"instance\":\"");
        mrb_format_fixnum(g_host_outbox, instance as!i64);
        g_host_outbox.append("\",\"callback\":");
        host_append_json_escaped(g_host_outbox, callback);
        g_host_outbox.append("}\n");
        return mrb_true(), true;
    }
    return mrb_nil(), false;
}

fn vm_call_mochi_events(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name != "subscribe" && name != "unsubscribe" {
        return mrb_nil(), false;
    }
    if args.len < 2 {
        return mrb_false(), true;
    }
    let instance, has_instance = host_current_instance(machine);
    if !has_instance {
        return mrb_false(), true;
    }
    let event_name, event_ok = builtin_hash_key_text(machine.pool, machine.scratch, args[0]);
    let callback, callback_ok = builtin_hash_key_text(machine.pool, machine.scratch, args[1]);
    if !event_ok || !callback_ok || event_name.len == 0 || callback.len == 0 ||
    event_name.len > 128 || callback.len > 128 {
        return mrb_false(), true;
    }
    let command = if name == "subscribe" {
        "event_subscribe"
    } else {
        "event_unsubscribe"
    };
    g_host_outbox.append("{\"__host\":");
    host_append_json_escaped(g_host_outbox, command);
    g_host_outbox.append(",\"event\":");
    host_append_json_escaped(g_host_outbox, event_name);
    g_host_outbox.append(",\"callback\":");
    host_append_json_escaped(g_host_outbox, callback);
    g_host_outbox.append(",\"instance\":\"");
    mrb_format_fixnum(g_host_outbox, instance as!i64);
    g_host_outbox.append("\"}\n");
    return mrb_true(), true;
}

fn vm_call_mochi_timer(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if (name == "after" || name == "every") && args.len >= 2 && mrb_is_fixnum(args[0]) {
        var cbuf: u8[>..] = [];
        let cb = host_arg_text(machine, args[1], cbuf);
        if cb.len == 0 {
            return mrb_fixnum(-1), true;
        }
        let ms = mrb_fixnum_value(args[0]);
        let timer_id = g_host_next_timer_id;
        g_host_next_timer_id += 1;
        let self_val = if machine.frames.len > 0 {
            machine.frames[machine.frames.len - 1].self_value
        } else {
            mrb_nil()
        };
        g_host_outbox.append("{\"__host\":\"timer\",\"kind\":");
        host_append_json_escaped(g_host_outbox, name);
        g_host_outbox.append(",\"id\":");
        mrb_format_fixnum(g_host_outbox, timer_id);
        g_host_outbox.append(",\"ms\":");
        mrb_format_fixnum(g_host_outbox, ms);
        g_host_outbox.append(",\"instance\":\"");
        mrb_format_fixnum(g_host_outbox, self_val as!i64);
        g_host_outbox.append("\",\"callback\":");
        host_append_json_escaped(g_host_outbox, cb);
        g_host_outbox.append("}\n");
        return mrb_fixnum(timer_id), true;
    }
    if name == "cancel_timer" && args.len >= 1 && mrb_is_fixnum(args[0]) {
        let timer_id = mrb_fixnum_value(args[0]);
        g_host_outbox.append("{\"__host\":\"timer\",\"kind\":\"cancel\",\"id\":");
        mrb_format_fixnum(g_host_outbox, timer_id);
        g_host_outbox.append("}\n");
        return mrb_true(), true;
    }
    return mrb_nil(), false;
}

fn vm_call_mochi_focus(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let self_val = if machine.frames.len > 0 {
        machine.frames[machine.frames.len - 1].self_value
    } else {
        mrb_nil()
    };
    if name == "focus" && args.len >= 1 {
        var rbuf: u8[>..] = [];
        let ref = host_arg_text(machine, args[0], rbuf);
        if ref.len == 0 {
            return mrb_false(), true;
        }
        g_host_outbox.append("{\"__host\":\"focus\",\"name\":");
        host_append_json_escaped(g_host_outbox, ref);
        g_host_outbox.append(",\"instance\":\"");
        mrb_format_fixnum(g_host_outbox, self_val as!i64);
        g_host_outbox.append("\"}\n");
        return mrb_true(), true;
    }
    if name == "restore_focus" && args.len == 0 {
        g_host_outbox.append("{\"__host\":\"restore_focus\",\"instance\":\"");
        mrb_format_fixnum(g_host_outbox, self_val as!i64);
        g_host_outbox.append("\"}\n");
        return mrb_true(), true;
    }
    return mrb_nil(), false;
}

fn vm_call_mochi_route(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "route" {
        return scratch_alloc_string(machine.scratch, g_host_route[..]), true;
    }
    if name == "route_info" {
        if g_host_route_info.len == 0 {
            return builtin_hash_new(machine.scratch), true;
        }
        let info, parsed = json_parse_document(
            machine.pool, machine.scratch, g_host_route_info[..]);
        if parsed {
            return info, true;
        }
        return builtin_hash_new(machine.scratch), true;
    }
    if (name == "set_route" || name == "navigate") && args.len >= 1 {
        var pbuf: u8[>..] = [];
        let path = host_arg_text(machine, args[0], pbuf);
        host_set_route_raw(path);
        g_host_outbox.append("{\"__host\":\"set_route\",\"path\":");
        host_append_json_escaped(g_host_outbox, path);
        g_host_outbox.append("}\n");
        return args[0], true;
    }
    if name == "replace_route" && args.len >= 1 {
        var rbuf: u8[>..] = [];
        let replacement = host_arg_text(machine, args[0], rbuf);
        host_set_route_raw(replacement);
        g_host_outbox.append("{\"__host\":\"replace_route\",\"path\":");
        host_append_json_escaped(g_host_outbox, replacement);
        g_host_outbox.append("}\n");
        return args[0], true;
    }
    if name == "route_subscribe" {
        let instance, has_instance = host_current_instance(machine);
        if !has_instance {
            return mrb_false(), true;
        }
        g_host_outbox.append("{\"__host\":\"route_subscribe\",\"instance\":\"");
        mrb_format_fixnum(g_host_outbox, instance as!i64);
        g_host_outbox.append("\"}\n");
        return mrb_true(), true;
    }
    return mrb_nil(), false;
}

fn vm_call_mochi_attr(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    if name == "get_attr" && args.len >= 1 {
        var abuf: u8[>..] = [];
        let raw_name = host_arg_text(machine, args[0], abuf);
        if raw_name.len == 0 || machine.frames.len == 0 {
            return mrb_nil(), true;
        }
        var ivar_name: u8[>..] = [];
        if raw_name[0] != 64 {
            ivar_name.push(64);
        }
        ivar_name.append(raw_name);
        let self_val = machine.frames[machine.frames.len - 1].self_value;
        let val, found = state_get_ivar(machine.pool, self_val, intern_symbol(ivar_name[..]));
        if found && !mrb_is_nil(val) {
            return val, true;
        }
        if args.len >= 2 {
            return args[1], true;
        }
        return mrb_nil(), true;
    }
    return mrb_nil(), false;
}

fn vm_call_mochi_builtin(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let before = g_host_outbox.len;
    let value, handled = vm_call_mochi_operation(machine, name, args);
    if g_host_outbox.len >= HOST_OUTBOX_CAPACITY {
        state_fail_capacity(machine.pool, CapacityResource.HostCommands,
            g_host_outbox.len - before, before, HOST_OUTBOX_CAPACITY - 1);
        machine.error = VmError.StateCapacity;
    }
    return value, handled;
}

fn vm_call_mochi_operation(
    machine: Vm&, name: u8[:], args: MrbValue[:]
) -> MrbValue, bool {
    let event_val, event_ok = vm_call_mochi_events(machine, name, args);
    if event_ok {
        return event_val, true;
    }
    let storage_val, storage_ok = vm_call_mochi_storage(machine, name, args);
    if storage_ok {
        return storage_val, true;
    }
    let timer_val, timer_ok = vm_call_mochi_timer(machine, name, args);
    if timer_ok {
        return timer_val, true;
    }
    let focus_val, focus_ok = vm_call_mochi_focus(machine, name, args);
    if focus_ok {
        return focus_val, true;
    }
    let route_val, route_ok = vm_call_mochi_route(machine, name, args);
    if route_ok {
        return route_val, true;
    }
    return vm_call_mochi_attr(machine, name, args);
}

export fn goose_vm_seed_storage(key: const u8[:], value: const u8[:]) {
    host_storage_put_raw(key, value);
}

export fn goose_vm_remove_storage(key: const u8[:]) {
    host_storage_remove_raw(key);
}

export fn goose_vm_set_route_state(path: const u8[:]) {
    host_set_route_raw(path);
}

export fn goose_vm_set_route_info(info: const u8[:]) {
    host_set_route_info_raw(info);
}

export fn goose_vm_host_outbox() -> const u8[:] {
    return host_outbox_bytes();
}

export fn goose_vm_clear_host_outbox() {
    host_clear_outbox();
}
