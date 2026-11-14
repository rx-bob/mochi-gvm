// Decoder checks for the mruby fallback method-definition sequence.
namespace vm_method_definitions_test;

import std;

import goosetest;
import vm;

let METHOD_OPERANDS: const u8[2] = [2, 1];
let SHORT_METHOD_OPERANDS: const u8[1] = [2];

fn test_method_operands_decode(t: goosetest::Test&) {
    let decoded, valid = vm::vm_definition_operands(vm::DefinitionInstruction {
            frame_index: 0,
            record: vm::IrepRecord {
                ..
            },
            iseq: METHOD_OPERANDS,
            pc: 0,
            op: vm::OP_METHOD,
        });
    t.assert_true(valid);
    t.assert_eq(2, decoded.a);
    t.assert_eq(1, decoded.b);
    t.assert_eq(2, decoded.next_pc);
}

fn test_short_method_operands_rejected(t: goosetest::Test&) {
    let _, valid = vm::vm_definition_operands(vm::DefinitionInstruction {
            frame_index: 0,
            record: vm::IrepRecord {
                ..
            },
            iseq: SHORT_METHOD_OPERANDS,
            pc: 0,
            op: vm::OP_DEF,
        });
    t.assert_false(valid);
    t.assert_eq(256, vm::vm_read_extended_byte([1, 0], 0, true));
}
