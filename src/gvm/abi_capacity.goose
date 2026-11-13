// Preserve allocation failures from host input decoding on the normal error channel.
namespace vm;

import.abi;
import.vm_errors;

fn abi_input_failure(fallback: u8[:]) {
    if vm_capture_capacity_failure(g_abi_machine) {
        abi_record_vm_error(g_abi_machine);
    } else {
        abi_fail(fallback);
    }
}
