// Builds the standalone browser artifact: dist/mochi-gvm.wasm and
// dist/mochi-gvm.js. The Goose ABI compiles alone via `--standalone`; the C
// bridge supplies the small integer surface the JS loader calls.

import static_storage from "../src/build";

import json;
import os;
import std;

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

// Read the same profile header as emcc at build time. Compiling this metadata
// into the toolchain sidecar could reuse a cached C object from another profile.
fn write_capacity_profile() -> bool {
    var header: u8[>..] = [];
    if !read_file("src/gvm/include/mochi_capacity_profile.h", header) {
        return false;
    }
    let prefix = "#define MOCHI_CAPACITY_PROFILE_JSON ";
    for line in split(header, '\n') {
        if starts_with(line, prefix) {
            var nodes: json::Node[>..] = [];
            var decoded: u8[>..] = [];
            let node, error = json::parse(line[prefix.len..], nodes, decoded);
            let text, valid = json::as_string(node);
            return error.len == 0 && valid && write_file("dist/mochi-gvm.capacity.json", text);
        }
    }
    return false;
}

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
    command.append(" --stack-reserve 64K -O2 ");
    command.append(ENTRY);
    run(command[..]);
    var generated: u8[>..] = [];
    var lowered: u8[>..] = [];
    var wasm_lowered: u8[>..] = [];
    if !read_file(GOOSE_C, generated)
        || static_storage::lower(generated, lowered) != 10
        || !static_storage::lower_wasm_runtime(lowered, wasm_lowered)
        || !write_file(GOOSE_C, wasm_lowered) {
        print("build_wasm failed: persistent storage initialization layout changed");
        exit(1);
    }
}

fn compile_bridge() {
    var command: u8[>..] = [];
    command.append("emcc -Oz -flto -sFILESYSTEM=0 -sMALLOC=emmalloc --closure 1 ");
    command.append("-DMOCHI_ABI_OWNS_GOOSE_LIFECYCLE ");
    command.append("-sEXPORTED_FUNCTIONS='[\"_main\",\"_mochi_capacity_fingerprint\",\"_mochi_capacity_profile\",");
    command.append("\"_mochi_init_runtime\",\"_mochi_load_irep\",");
    command.append("\"_mochi_mount_component\",\"_mochi_mount_component_props\",");
    command.append("\"_mochi_set_props_json\",\"_mochi_intern\",");
    command.append("\"_mochi_register_binding\",\"_mochi_unmount_component\",");
    command.append("\"_mochi_binding_count\",\"_mochi_component_count\",");
    command.append("\"_mochi_state_object_count\",\"_mochi_state_allocated_count\",");
    command.append("\"_mochi_state_free_bytes\",");
    command.append("\"_mochi_dispatch_event\",");
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
    command.append("\"_mochi_host_inbox_offset\",");
    command.append("\"_mochi_host_inbox_capacity\",");
    command.append("\"_mochi_deliver_fetch\",\"_mochi_deliver_host_result\",");
    command.append("\"_mochi_seed_storage\",\"_mochi_remove_storage\",");
    command.append("\"_mochi_set_route_state\",");
    command.append("\"_mochi_set_route_info\",");
    command.append("\"_mochi_set_ivar_string\",\"_mochi_eval_each_expr\",");
    command.append("\"_mochi_eval_buffer_offset\",\"_mochi_eval_buffer_len\",");
    command.append("\"_malloc\",\"_free\"]' ");
    command.append(
        "-sEXPORTED_RUNTIME_METHODS='[\"HEAPU8\",\"UTF8ToString\","
    );
    command.append(
        "\"stringToUTF8\",\"lengthBytesUTF8\",\"setValue\",\"getValue\"]' "
    );
    command.append("-sALLOW_MEMORY_GROWTH=1 -sINITIAL_HEAP=4194304 ");
    command.append("-sMAXIMUM_MEMORY=100663296 ");
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
    command.append("wasm-opt -Oz --converge --strip-debug --strip-producers ");
    command.append("--enable-bulk-memory --enable-nontrapping-float-to-int ");
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
    if !write_capacity_profile() {
        print("build_wasm failed: cannot write capacity profile identity");
        exit(1);
    }
    print("built ", WASM_JS, " and ", WASM_BIN);
}
