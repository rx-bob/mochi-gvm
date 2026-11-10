// Builds the standalone browser artifact: dist/mochi-gvm.wasm and
// dist/mochi-gvm.js. The Goose ABI compiles alone via `--standalone`; the C
// bridge supplies the small integer surface the JS loader calls.

import os;

let OUT_DIR: const u8[:] = "dist";
let ENTRY: const u8[:] = "src/gvm/vm.goose";
let GOOSE_C: const u8[:] = "dist/goose_vm.c";
let GOOSE_H: const u8[:] = "dist/goose_vm.h";
let WASM_JS: const u8[:] = "dist/mochi-gvm.js";
let WASM_BIN: const u8[:] = "dist/mochi-gvm.wasm";
let WASM_OPT_BIN: const u8[:] = "dist/mochi-gvm.opt.wasm";

// Provided by scripts/toolchain.c: the script's sidecar.
extern fn mochi_prepare_toolchain() -> i64;

extern fn mochi_run(command: const u8[:]) -> i64;

fn run(command: const u8[:]) {
    let status = mochi_run(command);
    if status != 0 {
        print("build_wasm failed (", status, "): ", command);
        exit(1);
    }
}

fn generate_goose_c() {
    var command: u8[>..] = [];
    command.append("goose -o ");
    command.append(GOOSE_C);
    command.append(" --standalone --header ");
    command.append(GOOSE_H);
    command.append(" --stack-reserve 512K -O2 ");
    command.append(ENTRY);
    run(command[..]);
}

fn compile_bridge() {
    var command: u8[>..] = [];
    command.append("emcc -Oz -fwasm-exceptions -sSUPPORT_LONGJMP=wasm ");
    command.append("-DMOCHI_ABI_OWNS_GOOSE_LIFECYCLE ");
    command.append("-sEXPORTED_FUNCTIONS='[\"_main\",");
    command.append("\"_mochi_init_runtime\",\"_mochi_load_irep\",");
    command.append("\"_mochi_mount_component\",\"_mochi_intern\",");
    command.append("\"_mochi_register_binding\",\"_mochi_dispatch_event\",");
    command.append("\"_mochi_dispatch_event_args\",");
    command.append("\"_mochi_has_method\",\"_goose_vm_has_method\",");
    command.append("\"_goose_vm_method_req_argc\",");
    command.append("\"_mochi_flush_patches\",");
    command.append("\"_mochi_patch_buffer_offset\",");
    command.append("\"_mochi_patch_buffer_len\",\"_mochi_last_error_offset\",");
    command.append("\"_mochi_last_error_len\",");
    command.append("\"_mochi_fetch_outbox_offset\",");
    command.append("\"_mochi_fetch_outbox_len\",\"_mochi_fetch_outbox_clear\",");
    command.append("\"_mochi_emit_outbox_offset\",");
    command.append("\"_mochi_emit_outbox_len\",\"_mochi_emit_outbox_clear\",");
    command.append("\"_mochi_fetch_inbox_offset\",");
    command.append("\"_mochi_fetch_inbox_capacity\",");
    command.append("\"_mochi_deliver_fetch\",\"_malloc\",\"_free\"]' ");
    command.append(
        "-sEXPORTED_RUNTIME_METHODS='[\"HEAPU8\",\"UTF8ToString\","
    );
    command.append(
        "\"stringToUTF8\",\"lengthBytesUTF8\",\"setValue\",\"getValue\"]' "
    );
    command.append("-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=4194304 ");
    command.append("-sSTACK_SIZE=1048576 -sMODULARIZE=1 ");
    command.append("-sEXPORT_NAME=MochiModule -sNO_EXIT_RUNTIME=1 ");
    command.append("--no-entry -I src/gvm/include ");
    command.append("src/gvm/mochi_gvm_bridge.c ");
    command.append("src/gvm/mrb_abi_shim.c src/gvm/mrbgem_loader.c ");
    command.append(GOOSE_C);
    command.append(" -o ");
    command.append(WASM_JS);
    run(command[..]);
}

fn optimize_wasm() {
    var command: u8[>..] = [];
    command.append("wasm-opt -Oz --strip-debug --strip-producers ");
    command.append("--enable-bulk-memory --enable-exception-handling ");
    command.append("--enable-nontrapping-float-to-int ");
    command.append(WASM_BIN);
    command.append(" -o ");
    command.append(WASM_OPT_BIN);
    run(command[..]);
    if !rename_file(WASM_OPT_BIN, WASM_BIN) {
        print("build_wasm failed: cannot replace ", WASM_BIN);
        exit(1);
    }
}

fn main() {
    if !make_dir(OUT_DIR) {
        print("build_wasm failed: cannot create ", OUT_DIR);
        exit(1);
    }
    if mochi_prepare_toolchain() != 0 {
        print("build_wasm failed: toolchain is incomplete");
        exit(1);
    }
    generate_goose_c();
    compile_bridge();
    optimize_wasm();
    if !file_exists(WASM_JS) || !file_exists(WASM_BIN) {
        print("build_wasm failed: artifact is missing");
        exit(1);
    }
    print("built ", WASM_JS, " and ", WASM_BIN);
}
