namespace static_storage_test;

import static_storage from "../../src/build";

import std;

import goosetest;

let ZERO_INIT = "static void gs_init_globals(void) {\n    l32768_Object *t21 = (l32768_Object *)GS(0 + 0)->top;\n    GS(0 + 0)->top += sizeof(l32768_Object);\n    GS_MEMZERO(&(*t21), sizeof((*t21)));\n    (*t21).len = 0;\n    GS_GL->gs_component_vm_g_abi_pool_g2_2 = (*t21);\n    GS_GL->pool.objects = &GS_GL->gs_component_vm_g_abi_pool_g2_2;\n    GS(0 + 0)->top = (uint8_t *)t21;\n}\n";

fn test_static_zero_storage(t: goosetest::Test&) {
    var output: u8[>..] = [];
    t.assert_eq(1, static_storage::lower(ZERO_INIT, output));
    t.assert_true(output[..] == "static void gs_init_globals(void) {\n    uint8_t *t21 = GS(0 + 0)->top;\n    GS_MEMZERO(&GS_GL->gs_component_vm_g_abi_pool_g2_2, sizeof(GS_GL->gs_component_vm_g_abi_pool_g2_2));\n    GS_GL->pool.objects = &GS_GL->gs_component_vm_g_abi_pool_g2_2;\n    GS(0 + 0)->top = (uint8_t *)t21;\n}\n");
    var unchanged: u8[>..] = [];
    t.assert_eq(0, static_storage::lower(output, unchanged));
    t.assert_true(output[..] == unchanged[..]);
}

fn test_changed_initialization_rejected(t: goosetest::Test&) {
    var changed: u8[>..] = [];
    changed.append(ZERO_INIT);
    let at = find(changed, "(*t21).len = 0;");
    changed[at + 12] = '1';
    var output: u8[>..] = [];
    t.assert_eq(-1, static_storage::lower(changed, output));
}

fn test_lower_wasm_runtime(t: goosetest::Test&) {
    let sample = "#define GS_IDX(i, n, f, l) \\\n    ((uint64_t)(i) < (uint64_t)(n) ? (i) \\\n                                   : (gs_idxfail((int64_t)(i), (n), (f), (l)), (int64_t)0))\nstatic const char gs_file0[] = \"src/gvm/vm_num.goose\";\nstatic GS_NORETURN void gs_fail(const void *msg, int64_t len, const char *file, int line) {\n    fprintf(stderr, \"fail\\n\");\n}\nstatic GS_NORETURN void gs_park(void) {\n    for (;;) pause();\n}\nstatic void gs_regions_init(void) {\n    sigaction(SIGSEGV, &sa, &gs_prev_segv);\n}\n";
    var output: u8[>..] = [];
    t.assert_true(static_storage::lower_wasm_runtime(sample, output));
    t.assert_true(find(output[..], "__builtin_trap()") >= 0);
    t.assert_true(find(output[..], "gs_idxfail") < 0);
    t.assert_true(find(output[..], "src/gvm/vm_num.goose") < 0);
    t.assert_true(find(output[..], "fprintf") < 0);
    t.assert_true(find(output[..], "pause()") < 0);
    t.assert_true(find(output[..], "sigaction") < 0);
}
