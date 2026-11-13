namespace vm_files_api_test;

import goosetest;
import vm;

fn test_file_release_command_owner_and_escape(t: goosetest::Test&) {
    var outbox: u8[>..] = [];
    let value = vm::files_api_command("file_release", "mochi-file-\"1", outbox, vm::mrb_fixnum(9));
    t.assert_true(vm::mrb_is_true(value));
    t.assert_eq("{\"__host\":\"file_release\",\"instance\":\"12884901897\",\"handle\":\"mochi-file-\\\"1\"}\n", outbox[..]);
}

fn test_file_reader_open_and_close_commands(t: goosetest::Test&) {
    var outbox: u8[>..] = [];
    vm::files_api_command("file_reader_open", "file-1", outbox, vm::mrb_fixnum(3));
    t.assert_eq("{\"__host\":\"file_reader_open\",\"instance\":\"12884901891\",\"handle\":\"file-1\"}\n", outbox[..]);
    outbox.clear();
    vm::files_api_command("file_reader_close", "file-1", outbox, vm::mrb_fixnum(3));
    t.assert_eq("{\"__host\":\"file_reader_close\",\"instance\":\"12884901891\",\"handle\":\"file-1\"}\n", outbox[..]);
}

fn test_file_release_requires_a_string_handle(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    var scratch: vm::ScratchArena = vm::ScratchArena {
        ..
    };
    var pool: vm::StatePool = vm::StatePool {
        ..
    };
    var machine: vm::Vm = vm::Vm {
        file: file,
        pool: pool,
        scratch: scratch,
        ..
    };
    var outbox: u8[>..] = [];
    let args: vm::MrbValue[1] = [vm::mrb_fixnum(1)];
    let value, handled = vm::files_api_dispatch(machine, "file_release", args[..], outbox);
    t.assert_true(handled);
    t.assert_true(vm::mrb_is_nil(value));
    t.assert_eq(vm::VmError.TypeMismatch, machine.error);
    t.assert_eq(0, outbox.len);
}
