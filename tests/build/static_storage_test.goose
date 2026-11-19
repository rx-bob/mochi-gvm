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

let SCRATCH_INIT = "static void gs_init_globals(void) {\n    vm_ScratchArena_g2 *t33 = (vm_ScratchArena_g2 *)GS(0 + 0)->top;\n    GS(0 + 0)->top += sizeof(vm_ScratchArena_g2);\n    GS_MEMZERO(&(*t33), sizeof((*t33)));\n    l8_u8 *t34 = (l8_u8 *)GS(0 + 1)->top;\n    GS(0 + 1)->top += sizeof(l8_u8);\n    GS_MEMZERO(&(*t34), sizeof((*t34)));\n    (*t34).len = 0;\n    (*t33).blob_g = (*t34);\n    (*t33).mark_epoch_g = 0;\n    t47.tag = 0;\n    t46.resource_g = t47;\n    (*t33).failure_g = t46;\n    (*t33).overflow_g = 0;\n    GS_GL->vm_g_abi_scratch_g2 = (*t33);\n    GS(0 + 1)->top = (uint8_t *)t34;\n    GS(0 + 0)->top = (uint8_t *)t33;\n    GS_GL->after = 1;\n}\n";

fn test_scratch_arena_initialization_is_static(t: goosetest::Test&) {
    var output: u8[>..] = [];
    t.assert_eq(1, static_storage::lower(SCRATCH_INIT, output));
    t.assert_true(output[..] == "static void gs_init_globals(void) {\n    uint8_t *t33 = GS(0 + 0)->top;\n    GS_MEMZERO(&GS_GL->vm_g_abi_scratch_g2, sizeof(GS_GL->vm_g_abi_scratch_g2));\n    GS_GL->after = 1;\n}\n");
}

fn test_changed_scratch_initialization_rejected(t: goosetest::Test&) {
    var changed: u8[>..] = [];
    changed.append(SCRATCH_INIT);
    let at = find(changed, "GS_GL->vm_g_abi_scratch_g2 = (*t33);");
    changed[at + 33] = '4';
    var output: u8[>..] = [];
    t.assert_eq(-1, static_storage::lower(changed, output));
}

fn test_lower_wasm_runtime(t: goosetest::Test&) {
    let sample = "#define GS_IDX(i, n, f, l) \\\n    ((uint64_t)(i) < (uint64_t)(n) ? (i) \\\n                                   : (gs_idxfail((int64_t)(i), (n), (f), (l)), (int64_t)0))\nstatic const char gs_file0[] = \"src/gvm/vm_num.goose\";\n#ifndef GS_STACK_GAP\n#define GS_STACK_GAP (1ull << 20)   /* Unmapped tail so runaway growth aborts. */\n#endif\nstatic GS_NORETURN void gs_fail(const void *msg, int64_t len, const char *file, int line) {\n    fprintf(stderr, \"fail\\n\");\n}\nstatic GS_NORETURN void gs_park(void) {\n    for (;;) pause();\n}\nstatic void gs_regions_init(void) {\n    sigaction(SIGSEGV, &sa, &gs_prev_segv);\n}\n";
    var output: u8[>..] = [];
    t.assert_true(static_storage::lower_wasm_runtime(sample, output));
    t.assert_true(find(output[..], "__builtin_trap()") >= 0);
    t.assert_true(find(output[..], "gs_idxfail") < 0);
    t.assert_true(find(output[..], "src/gvm/vm_num.goose") < 0);
    t.assert_true(find(output[..], "fprintf") < 0);
    t.assert_true(find(output[..], "pause()") < 0);
    t.assert_true(find(output[..], "sigaction") < 0);
    t.assert_true(find(output[..], "#define GS_STACK_GAP 0ull") >= 0);
    t.assert_true(find(output[..], "(1ull << 20)") < 0);
}

fn test_lower_wasm_requires_gap_anchor(t: goosetest::Test&) {
    var output: u8[>..] = [];
    t.assert_false(static_storage::lower_wasm_runtime("int gs_probe;\n", output));
}
