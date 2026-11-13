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
