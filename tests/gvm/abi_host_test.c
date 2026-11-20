/* Build with the standalone Goose C, mrb_abi_shim.c, mrbgem_loader.c and
 * mochi_gvm_bridge.c. Pass tests/fixtures/native_probe.rb compiled by mrbc
 * (including its RITE header) as argv[1]. This test runs at native width. */
#include "mochi_native.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int32_t mochi_component_count(void);
extern int32_t mochi_binding_count(void);

#define BYTES(s) ((MochiNativeBytes){(const uint8_t *)(s), sizeof(s) - 1})

static void check(int ok, const char *what) {
  if (ok) return;
  MochiNativeBytes error = mochi_native_error();
  fprintf(stderr, "FAIL %s: %.*s\n", what, (int)error.length, (const char *)error.data);
  exit(1);
}

static void load_fixture(const char *path) {
  FILE *file = fopen(path, "rb");
  check(file != NULL, "open native probe");
  check(fseek(file, 0, SEEK_END) == 0, "seek native probe");
  long length = ftell(file);
  check(length > 0 && fseek(file, 0, SEEK_SET) == 0, "size native probe");
  uint8_t *data = malloc((size_t)length);
  check(data != NULL, "allocate native probe");
  check(fread(data, 1, (size_t)length, file) == (size_t)length, "read native probe");
  fclose(file);
  check(mochi_native_load((MochiNativeBytes){data, (size_t)length}) == 0, "load native probe");
  free(data);
}

static MochiNativeInstance mount_probe(void) {
  MochiNativeInstance instance = 0;
  check(mochi_native_mount(BYTES("NativeProbe"), &instance) == 0 && instance != 0, "mount probe");
  check(mochi_native_bind(instance, 0x0201, BYTES("label")) == 0, "bind label");
  return instance;
}

static void expect_patch(MochiNativeInstance instance, MochiNativeBytes expected) {
  MochiNativePatches patches;
  check(mochi_native_flush(instance, &patches) == 0 && patches.count == 1, "flush one patch");
  uint16_t id = 0;
  MochiNativeBytes value;
  check(mochi_native_patch_next(&patches.bytes, &id, &value) == 1 && id == 0x0201,
        "decode little-endian binding");
  check(value.length == expected.length && memcmp(value.data, expected.data, expected.length) == 0,
        "patch bytes");
  check(mochi_native_patch_next(&patches.bytes, &id, &value) == 0, "end of patch batch");
}

static void malformed_patches(void) {
  static const uint8_t bad[] = {1, 2, 0xff, 0xff, 0xff, 0xff, 'x'};
  uint16_t id = 0;
  MochiNativeBytes value = {0};
  for (size_t size = 1; size <= sizeof(bad); ++size) {
    MochiNativeBytes remaining = {bad, size};
    check(mochi_native_patch_next(&remaining, &id, &value) == -1, "reject truncated patch");
    check(remaining.data == bad && remaining.length == size && id == 0 && value.data == NULL,
          "failed decode leaves the cursor and record alone");
  }
  MochiNativeBytes missing = {NULL, 6};
  check(mochi_native_patch_next(&missing, &id, &value) == -1, "reject missing patch pointer");
}

int main(int argc, char **argv) {
  check(argc == 2, "expected path to compiled native_probe.rb");
  check(sizeof(void *) > 4, "test requires a native-width pointer");
  check(mochi_native_abi_version() == MOCHI_NATIVE_ABI_VERSION, "ABI version");
  check(strlen(mochi_native_capacity_fingerprint()) == 64, "capacity fingerprint");
  check(mochi_native_open() == 0 && mochi_native_open() == 0, "open native VM");
  MochiNativeBytes nil_data = {NULL, 16};
  MochiNativeBytes oversized = {(const uint8_t *)"", SIZE_MAX};
  check(mochi_native_load(nil_data) == -1 && mochi_native_load(oversized) == -1,
        "validate bytecode pointer and native length");
  check(mochi_native_error().length > 0, "failed load has a borrowed error");
  check(mochi_native_load(BYTES("not bytecode")) == -1, "reject invalid bytecode");
  load_fixture(argv[1]);

  MochiNativeInstance failed = 1;
  check(mochi_native_mount(BYTES("BrokenNativeProbe"), &failed) == -1 && !failed &&
        mochi_component_count() == 0, "rollback failed initialize");
  check(mochi_native_mount(BYTES("HostEffectNativeProbe"), &failed) == -1 && !failed &&
        mochi_component_count() == 0, "rollback unsupported mount effect");
  MochiNativeInstance a = mount_probe();
  MochiNativeInstance b = mount_probe();
  check(a != b && mochi_component_count() == 2 && mochi_binding_count() == 2, "two distinct instances");

  expect_patch(a, BYTES("ready"));
  expect_patch(b, BYTES("ready"));
  int64_t arity;
  check(mochi_native_method_arity(a, BYTES("change"), &arity) == 0 && arity == 1, "required arity");
  check(mochi_native_method_arity(a, BYTES("mounted"), &arity) == 0 && arity == -1, "absent lifecycle");
  check(mochi_native_dispatch(a, BYTES("change"), oversized) == -1 &&
        mochi_native_dispatch(a, BYTES("change"), BYTES("{}")) == -1, "reject invalid event arguments");
  check(mochi_native_dispatch(a, BYTES("unsupported"), BYTES("[]")) == -1, "reject unsupported host effect");
  check(mochi_native_dispatch(a, BYTES("change"), BYTES("[\"Café\"]")) == 0, "dispatch after errors");
  expect_patch(a, BYTES("Café"));
  MochiNativePatches unchanged;
  check(mochi_native_flush(b, &unchanged) == 0 && unchanged.count == 0 && unchanged.bytes.length == 0,
        "second instance remains unchanged");

  check(mochi_native_unmount(a) == 0 && mochi_component_count() == 1 && mochi_binding_count() == 1,
        "unmount releases one instance");
  MochiNativeInstance replacement = mount_probe();
  check(mochi_native_dispatch(a, BYTES("change"), BYTES("[\"stale\"]")) == -1,
        "closed handle cannot target a remounted instance");
  expect_patch(replacement, BYTES("ready"));
  check(mochi_native_dispatch(b, BYTES("change"), BYTES("[\"still active\"]")) == 0, "dispatch to surviving instance");
  expect_patch(b, BYTES("still active"));
  check(mochi_native_unmount(b) == 0 && mochi_native_unmount(replacement) == 0 &&
        mochi_component_count() == 0 && mochi_binding_count() == 0, "release remaining instances");
  malformed_patches();
  puts("PASS native GVM ABI");
  return 0;
}
