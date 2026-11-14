namespace vm_json_codec_test;

import goosetest;
import vm;

fn test_json_float_roundtrip_and_state(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let documents: const u8[:][..8] = ["-0.0", "1.7976931348623157e308", "5e-324", "2.2250738585072014e-308", "1e-999", "0.1"];
    for document in documents {
        vm::scratch_reset(scratch);
        let first = vm::json_decode(machine, document);
        let encoded = vm::json_encode(machine, first);
        let second = vm::json_decode(machine, vm::builtin_string_bytes(pool, scratch, encoded));
        let before, before_ok = vm::num_float_value(scratch, pool, first);
        let after, after_ok = vm::num_float_value(scratch, pool, second);
        t.assert_eq(vm::VmError.Ok, machine.error);
        t.assert_true(before_ok && after_ok);
        t.assert_eq(before, after);
        if document == "-0.0" {
            t.assert_eq("-0.0", vm::builtin_string_bytes(pool, scratch, encoded));
        }
    }
    let nested = vm::json_decode(machine, "{\"values\":[9223372036854775807,\"é\",null,true]}");
    let retained = vm::promote_to_state(pool, scratch, nested);
    vm::scratch_reset(scratch);
    let encoded = vm::json_encode(machine, retained);
    t.assert_eq("{\"values\":[9223372036854775807,\"é\",null,true]}", vm::builtin_string_bytes(pool, scratch, encoded));
}

fn test_json_allocation_failure_and_recovery(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    var document: u8[>..] = [];
    document.append("[0");
    for index in 0..vm::SCRATCH_CAPACITY_SLOTS {
        document.append(",0");
    }
    document.append("]");
    let failed = vm::json_decode(machine, document[..]);
    t.assert_true(vm::mrb_is_nil(failed));
    t.assert_eq(vm::VmError.ScratchFull, machine.error);
    t.assert_eq(vm::ScratchResource.Slots, machine.error_context.scratch_resource);
    vm::scratch_reset(scratch);
    machine.error = vm::VmError.Ok;
    let valid = vm::json_decode(machine, "[42]");
    let encoded = vm::json_encode(machine, valid);
    t.assert_eq(vm::VmError.Ok, machine.error);
    t.assert_eq("[42]", vm::builtin_string_bytes(pool, scratch, encoded));
}

fn test_json_scalars_precision_wrappers(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let documents: const u8[:][..16] = [
        "null", "true", "false", "9007199254740993", "9223372036854775807", "-9223372036854775808",
        "[1,2.5,\"hello\",null,false]", "{\"__mochi_number\":\"i64\",\"value\":\"9007199254740993\"}",
        "{\"__mochi_bytes\":\"ff\"}", "\"é😀\\n\\t\\u0000\"", "{}", "[]"
    ];
    for document in documents {
        vm::scratch_reset(scratch);
        let value = vm::json_decode(machine, document);
        t.assert_eq(vm::VmError.Ok, machine.error);
        let encoded = vm::json_encode(machine, value);
        t.assert_eq(vm::VmError.Ok, machine.error);
        t.assert_eq(document, vm::builtin_string_bytes(pool, scratch, encoded));
    }
    let duplicate = vm::json_decode(machine, "{\"x\":1,\"x\":2}");
    let encoded = vm::json_encode(machine, duplicate);
    t.assert_eq("{\"x\":2}", vm::builtin_string_bytes(pool, scratch, encoded));
}

fn test_json_malformed_and_number_range(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let documents: const u8[:][..32] = [
        "", " ", "01", "+1", "1.", "1e", "NaN", "Infinity", "1e9999", "9223372036854775808",
        "-9223372036854775809", "[1,]", "{\"x\":}", "null true", "\"\\uD800\"", "\"\\uDC00\"",
        "\"\\uD800\\u0000\"", "\"\\q\"", "{1:2}"
    ];
    for document in documents {
        vm::scratch_reset(scratch);
        machine.error = vm::VmError.Ok;
        vm::json_decode(machine, document);
        t.assert_eq(vm::VmError.JsonInvalid, machine.error);
    }
}

fn test_json_utf8_and_surrogates(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let bad: u8[..16] = [34, 0xED, 0xA0, 0x80, 34];
    vm::json_decode(machine, bad[..]);
    t.assert_eq(vm::VmError.JsonInvalid, machine.error);
    let overlong: u8[..4] = [0xC0, 0x80];
    let high: u8[..4] = [0xF4, 0x90, 0x80, 0x80];
    let truncated: u8[..4] = [0xE2, 0x82];
    let continuation: u8[..4] = [0x80];
    t.assert_false(vm::json_valid_utf8(overlong[..]));
    t.assert_false(vm::json_valid_utf8(high[..]));
    t.assert_false(vm::json_valid_utf8(truncated[..]));
    t.assert_false(vm::json_valid_utf8(continuation[..]));
    machine.error = vm::VmError.Ok;
    let decoded = vm::json_decode(machine, "\"\\uD83D\\uDE00\"");
    t.assert_eq("😀", vm::builtin_string_bytes(pool, scratch, decoded));
    let invalid_string = vm::scratch_alloc_string(scratch, overlong[..]);
    vm::json_encode(machine, invalid_string);
    t.assert_eq(vm::VmError.JsonInvalid, machine.error);
}

fn test_json_container_depth_and_cycles(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    let at_limit = "[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]";
    let value = vm::json_decode(machine, at_limit);
    t.assert_eq(vm::VmError.Ok, machine.error);
    let encoded = vm::json_encode(machine, value);
    t.assert_eq(at_limit, vm::builtin_string_bytes(pool, scratch, encoded));
    vm::json_decode(machine, "[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]");
    t.assert_eq(vm::VmError.JsonLimit, machine.error);
    machine.error = vm::VmError.Ok;
    let array = vm::scratch_alloc_array(scratch);
    vm::builtin_array_push(pool, scratch, array, array);
    vm::json_encode(machine, array);
    t.assert_eq(vm::VmError.JsonCycle, machine.error);
    machine.error = vm::VmError.Ok;
    let parent = vm::scratch_alloc_array(scratch);
    let child = vm::scratch_alloc_array(scratch);
    vm::builtin_array_push(pool, scratch, parent, child);
    vm::builtin_array_push(pool, scratch, parent, child);
    let shared = vm::json_encode(machine, parent);
    t.assert_eq("[[],[]]", vm::builtin_string_bytes(pool, scratch, shared));
    vm::builtin_array_push(pool, scratch, parent, value);
    vm::json_encode(machine, parent);
    t.assert_eq(vm::VmError.JsonLimit, machine.error);
}

fn test_json_bytes_and_escaping(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    var document: u8[>..] = [];
    document.append("null");
    while document.len < vm::JSON_DOCUMENT_BYTES {
        document.push(32);
    }
    t.assert_true(vm::mrb_is_nil(vm::json_decode(machine, document[..])));
    t.assert_eq(vm::VmError.Ok, machine.error);
    document.push(32);
    vm::json_decode(machine, document[..]);
    t.assert_eq(vm::VmError.JsonLimit, machine.error);
    machine.error = vm::VmError.Ok;
    document.clear();
    while document.len < vm::JSON_DOCUMENT_BYTES / 2 - 1 {
        document.push(10);
    }
    let string = vm::scratch_alloc_string(scratch, document[..]);
    let encoded = vm::json_encode(machine, string);
    t.assert_eq(vm::JSON_DOCUMENT_BYTES, vm::builtin_string_bytes(pool, scratch, encoded).len);
    t.assert_eq(vm::VmError.Ok, machine.error);
    document.push(10);
    let excess = vm::scratch_alloc_string(scratch, document[..]);
    vm::json_encode(machine, excess);
    t.assert_eq(vm::VmError.JsonLimit, machine.error);
}

fn test_json_pure_dispatch_and_types(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var machine = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    pool.computed_depth = 1;
    let args: vm::MrbValue[1] = [vm::scratch_alloc_string(scratch, "123")];
    let value, handled = vm::vm_call_mochi_builtin(machine, "json_parse", args[..]);
    t.assert_true(handled);
    t.assert_eq(123, vm::mrb_fixnum_value(value));
    t.assert_eq(vm::VmError.Ok, machine.error);
    let symbol = vm::mrb_symbol(vm::intern_symbol("key"));
    vm::json_encode(machine, symbol);
    t.assert_eq(vm::VmError.JsonType, machine.error);
    machine.error = vm::VmError.Ok;
    let hash = vm::scratch_alloc_hash(scratch);
    vm::builtin_hash_set(pool, scratch, hash, symbol, vm::mrb_true());
    vm::json_encode(machine, hash);
    t.assert_eq(vm::VmError.JsonType, machine.error);
    machine.error = vm::VmError.Ok;
    let infinite, ok = vm::json_parse_float_text(scratch, "Infinity");
    t.assert_true(ok);
    vm::json_encode(machine, infinite);
    t.assert_eq(vm::VmError.FloatDomain, machine.error);
}
