// Tests for bounded JSON decoding of host event arguments.
namespace vm_json_args_test;

import std;

import goosetest;
import vm;

fn test_parse_scalar_event_arguments(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var args: vm::MrbValue[>..] = [];
    let json = "[\"action\",42,-7,true,false,null]";
    t.assert_true(vm::json_parse_args(pool, scratch, json, args));
    t.assert_eq(6, args.len);
    t.assert_true(vm::builtin_string_bytes(pool, scratch, args[0]) == "action");
    t.assert_eq(42, vm::mrb_fixnum_value(args[1]));
    t.assert_eq(-7, vm::mrb_fixnum_value(args[2]));
    t.assert_true(vm::mrb_is_true(args[3]));
    t.assert_true(vm::mrb_is_false(args[4]));
    t.assert_true(vm::mrb_is_nil(args[5]));
}

fn test_parse_nested_event_object(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var args: vm::MrbValue[>..] = [];
    let json = "[{\"id\":7,\"rows\":[1,2],\"meta\":{\"ok\":true}}]";
    t.assert_true(vm::json_parse_args(pool, scratch, json, args));
    t.assert_eq(1, args.len);
    let event = args[0];
    t.assert_true(vm::scratch_is_hash(scratch, event));

    let id_key = vm::mrb_symbol(vm::intern_symbol("id"));
    let id = vm::builtin_hash_get(pool, scratch, event, id_key);
    t.assert_eq(7, vm::mrb_fixnum_value(id));

    let rows_key = vm::mrb_symbol(vm::intern_symbol("rows"));
    let rows = vm::builtin_hash_get(pool, scratch, event, rows_key);
    t.assert_true(vm::scratch_is_array(scratch, rows));
    t.assert_eq(1, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, rows, 0)));
    t.assert_eq(2, vm::mrb_fixnum_value(vm::builtin_array_get(pool, scratch, rows, 1)));

    let meta_key = vm::mrb_symbol(vm::intern_symbol("meta"));
    let meta = vm::builtin_hash_get(pool, scratch, event, meta_key);
    let ok_key = vm::mrb_symbol(vm::intern_symbol("ok"));
    t.assert_true(vm::mrb_is_true(vm::builtin_hash_get(pool, scratch, meta, ok_key)));
}

fn test_parse_string_escapes_and_unicode(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var args: vm::MrbValue[>..] = [];
    let json = "[\"a\\nb\",\"\\u263A\",\"\\uD83D\\uDE00\"]";
    t.assert_true(vm::json_parse_args(pool, scratch, json, args));
    t.assert_eq(3, args.len);

    let newline = vm::builtin_string_bytes(pool, scratch, args[0]);
    t.assert_eq(3, newline.len);
    t.assert_true(newline[0] == 97);
    t.assert_true(newline[1] == 10);
    t.assert_true(newline[2] == 98);

    let smile = vm::builtin_string_bytes(pool, scratch, args[1]);
    t.assert_eq(3, smile.len);
    t.assert_true(smile[0] == 226);
    t.assert_true(smile[1] == 152);
    t.assert_true(smile[2] == 186);

    let emoji = vm::builtin_string_bytes(pool, scratch, args[2]);
    t.assert_eq(4, emoji.len);
    t.assert_true(emoji[0] == 240);
    t.assert_true(emoji[1] == 159);
    t.assert_true(emoji[2] == 152);
    t.assert_true(emoji[3] == 128);
}

fn test_parse_wide_numbers_and_wrappers(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var args: vm::MrbValue[>..] = [];
    let json = "[9007199254740993,1.5,1e-7,{\"__mochi_number\":\"i64\",\"value\":\"9223372036854775807\"},{\"__mochi_number\":\"f64\",\"value\":\"0.5\"}]";
    t.assert_true(vm::json_parse_args(pool, scratch, json, args));
    t.assert_eq(5, args.len);
    let wide, wide_ok = vm::num_integer_value(scratch, pool, args[0]);
    t.assert_true(wide_ok);
    t.assert_eq(9007199254740993, wide);
    let fraction, fraction_ok = vm::num_float_value(scratch, pool, args[1]);
    t.assert_true(fraction_ok);
    t.assert_eq(1.5, fraction);
    let exponent, exponent_ok = vm::num_float_value(scratch, pool, args[2]);
    t.assert_true(exponent_ok);
    t.assert_eq(0.0000001, exponent);
    let maximum, maximum_ok = vm::num_integer_value(scratch, pool, args[3]);
    t.assert_true(maximum_ok);
    t.assert_eq(vm::NUM_I64_MAX, maximum);
    let wrapper_float, wrapper_float_ok = vm::num_float_value(scratch, pool, args[4]);
    t.assert_true(wrapper_float_ok);
    t.assert_eq(0.5, wrapper_float);
}

fn test_rejects_malformed_json(t: goosetest::Test&) {
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var args: vm::MrbValue[>..] = [];
    t.assert_false(vm::json_parse_args(pool, scratch, "", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[1,]", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[\"unterminated]", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[01]", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[1e]", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[9223372036854775808]", args));
    t.assert_false(vm::json_parse_args(pool, scratch, "[true] trailing", args));
    t.assert_false(vm::json_parse_args(pool, scratch,
        "[1,2,3,4,5,6,7,8,9]", args));
}
