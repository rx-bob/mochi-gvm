#ifndef MOCHI_NATIVE_H
#define MOCHI_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MOCHI_NATIVE_ABI_VERSION 3

typedef uint64_t MochiNativeInstance;

typedef struct {
  const uint8_t *data;
  size_t length;
} MochiNativeBytes;

typedef struct {
  MochiNativeBytes bytes;
  size_t count;
} MochiNativePatches;

/*
 * One process-wide VM. Serialize calls on one thread. Open before loading
 * bytecode or mounting. Define MOCHI_NATIVE_STANDALONE when compiling the
 * bridge against standalone Goose C so open initializes the Goose runtime.
 * Inputs are borrowed through the call. Outputs are
 * initialized on failure where provided. Successful mounts own one handle
 * until unmount. Handles are VM values, never pointers.
 *
 * Status is 0 on success and -1 on failure. Read the error immediately.
 * Error and patch bytes are borrowed VM buffers, valid until the next
 * mutating ABI call. Copy anything that must survive that call. Text is
 * UTF-8. Capacity fingerprint storage is valid for the process lifetime.
 */
uint32_t mochi_native_abi_version(void);
const char *mochi_native_capacity_fingerprint(void);
int mochi_native_open(void);
int mochi_native_load(MochiNativeBytes irep);
int mochi_native_mount(MochiNativeBytes class_name, MochiNativeInstance *instance);
/* Props are an object in Mochi's typed JSON transport. */
int mochi_native_mount_props(MochiNativeBytes class_name, MochiNativeBytes json_props,
                            MochiNativeInstance *instance);
int mochi_native_set_props(MochiNativeInstance instance, MochiNativeBytes json_props);
/* Drain newline-delimited child events and enabled storage commands. Bytes
 * are borrowed through the next mutating call. Failed entries discard effects. */
MochiNativeBytes mochi_native_take_effects(void);
/* Opt in to the fetch outbox. Drain after each successful mounted entry.
 * The returned newline-delimited records are borrowed like other effects. */
void mochi_native_enable_fetch(void);
MochiNativeBytes mochi_native_take_fetch(void);
int mochi_native_deliver_fetch(MochiNativeInstance instance, MochiNativeBytes callback,
                               MochiNativeBytes response);
/* Enable storage and clear the optimistic VM mirror before reseeding the
 * durable snapshot. Empty value slices are valid. Reset/seed only between
 * Ruby entries. The host restores the mirror after a failed entry. */
int mochi_native_reset_storage(void);
int mochi_native_seed_storage(MochiNativeBytes key, MochiNativeBytes value);
int mochi_native_bind(MochiNativeInstance instance, uint16_t id, MochiNativeBytes getter);
/* On success, arity contains the required positional count, or -1 if absent. */
int mochi_native_method_arity(MochiNativeInstance instance, MochiNativeBytes method, int64_t *arity);
int mochi_native_dispatch(MochiNativeInstance instance, MochiNativeBytes method,
                          MochiNativeBytes json_args);
int mochi_native_flush(MochiNativeInstance instance, MochiNativePatches *patches);
int mochi_native_unmount(MochiNativeInstance instance);
MochiNativeBytes mochi_native_error(void);

/* Read one little-endian u16 binding ID, u32 byte count and UTF-8 payload.
 * Returns 1 for a record, 0 at end, -1 for a malformed buffer. Advances only
 * on success. The caller verifies UTF-8 and the declared record count. */
int mochi_native_patch_next(MochiNativeBytes *remaining, uint16_t *id,
                            MochiNativeBytes *value);

#ifdef __cplusplus
}
#endif

#endif
