/*
 * Browser-facing bridge for the standalone mochi-gvm wasm artifact.
 *
 * The Goose ABI (`abi.goose`) exposes scalar entry points and slices. This
 * file turns them into the small integer surface a JS loader can call: load a
 * component's `.chi`, mount an instance, register getter symbols, dispatch an
 * event, and read the binary patch buffer. It also owns the `Mochi.fetch`
 * outbox/inbox pair so Ruby components never need a network API of their own.
 *
 * Buffers are copied out of Goose-owned memory on every call: the VM rebuilds
 * its patch slice per flush, and the host may read the copy at leisure.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#define MOCHI_EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define MOCHI_EXPORT __attribute__((used))
#endif

/* Offset accessors return wasm32 addresses, matching the loader's memory
 * model; a native host test for these must run in a 32-bit process. */
#define MOCHI_PATCH_CAPACITY (64 * 1024)
#define MOCHI_FETCH_CAPACITY (64 * 1024)
#define MOCHI_FETCH_LINE_CAPACITY 2048
#define MOCHI_ERROR_CAPACITY 256
#define MOCHI_CALLBACK_CAPACITY 128

/* Goose emits core C types under `#pragma pack(push, 1)`, so a u8 slice is
 * { pointer, i64 } with the length at offset 4 on wasm32. */
typedef struct __attribute__((packed)) {
  uint8_t *data;
  int64_t len;
} goose_u8_slice;

_Static_assert(offsetof(goose_u8_slice, len) == sizeof(void *),
               "Goose u8 slice length must follow the packed pointer");
_Static_assert(sizeof(goose_u8_slice) == sizeof(void *) + sizeof(int64_t),
               "Goose u8 slice must have no padding");

/* Symbols emitted by `abi.goose`; `mrb_abi_shim.c` declares most of them for
 * its own use, while the patch trio is only needed here. */
extern int64_t goose_vm_load_irep(goose_u8_slice bytes);
extern const uint8_t *goose_vm_last_error(int64_t *out_len);
extern uint8_t goose_vm_has_error(void);
extern uint32_t goose_vm_intern(goose_u8_slice name);
extern uint64_t goose_vm_const_get(uint32_t name);
extern uint64_t goose_vm_call(uint64_t receiver, uint32_t method, int64_t argc);
extern int64_t goose_vm_register_binding(uint64_t instance, uint32_t binding_id,
                                         uint32_t getter_symbol);
extern int64_t goose_vm_flush_patches(uint64_t instance);
extern const uint8_t *goose_vm_patch_bytes(int64_t *out_len);
extern uint8_t goose_vm_is_class(uint64_t value);

static mrb_state *g_mrb = NULL;
static uint8_t g_patch_buffer[MOCHI_PATCH_CAPACITY];
static int32_t g_patch_len = 0;
static uint8_t g_fetch_outbox[MOCHI_FETCH_CAPACITY];
static int32_t g_fetch_outbox_len = 0;
static uint8_t g_fetch_inbox[MOCHI_FETCH_CAPACITY];
static int32_t g_fetch_next_id = 1;
static char g_error_text[MOCHI_ERROR_CAPACITY];
static int32_t g_error_len = 0;

static goose_u8_slice slice_of(const void *data, size_t length) {
  goose_u8_slice slice;
  slice.data = (uint8_t *)data;
  slice.len = (int64_t)length;
  return slice;
}

static int32_t clamp_length(int64_t length, int32_t capacity) {
  if (length <= 0) return 0;
  if (length > capacity) return capacity;
  return (int32_t)length;
}

static void clear_error(void) {
  g_error_text[0] = '\0';
  g_error_len = 0;
}

static void set_error_text(const char *text) {
  size_t length;
  if (!text) {
    clear_error();
    return;
  }
  length = strlen(text);
  if (length >= MOCHI_ERROR_CAPACITY) length = MOCHI_ERROR_CAPACITY - 1;
  memcpy(g_error_text, text, length);
  g_error_text[length] = '\0';
  g_error_len = (int32_t)length;
}

/* Copies the VM's error text out of Goose memory before the next entry can
 * rewind it. */
static void capture_vm_error(void) {
  int64_t length = 0;
  const uint8_t *bytes;
  if (!goose_vm_has_error()) {
    clear_error();
    return;
  }
  bytes = goose_vm_last_error(&length);
  if (!bytes || length <= 0) {
    set_error_text("vm error");
    return;
  }
  if (length >= MOCHI_ERROR_CAPACITY) length = MOCHI_ERROR_CAPACITY - 1;
  memcpy(g_error_text, bytes, (size_t)length);
  g_error_text[length] = '\0';
  g_error_len = (int32_t)length;
}

/* Ruby-callable: Mochi.fetch(component_id, url, callback).
 * Appends "fetch_id|component_id|url|callback\n" to the outbox. The loader
 * performs the request and hands the body back through the inbox. */
static mrb_value mochi_fetch_native(mrb_state *mrb, mrb_value self) {
  const char *component = "";
  const char *url = "";
  const char *callback = "";
  char line[MOCHI_FETCH_LINE_CAPACITY];
  int written;
  int fetch_id;
  (void)self;
  mrb_get_args(mrb, "zzz", &component, &url, &callback);
  fetch_id = g_fetch_next_id;
  written = snprintf(line, sizeof(line), "%d|%s|%s|%s\n", fetch_id, component,
                     url, callback);
  if (written <= 0 || written >= (int)sizeof(line)) return mrb_fixnum_value(-1);
  if (g_fetch_outbox_len + written > MOCHI_FETCH_CAPACITY) {
    return mrb_fixnum_value(-1);
  }
  memcpy(g_fetch_outbox + g_fetch_outbox_len, line, (size_t)written);
  g_fetch_outbox_len += written;
  g_fetch_next_id += 1;
  return mrb_fixnum_value(fetch_id);
}

MOCHI_EXPORT
int32_t mochi_init_runtime(void) {
  struct RClass *mochi;
  if (g_mrb) return 0;
  clear_error();
  g_mrb = mrb_open();
  if (!g_mrb) {
    set_error_text("mrb_open failed");
    return -1;
  }
  mochi = mrb_define_module(g_mrb, "Mochi");
  mrb_define_module_function(g_mrb, mochi, "fetch", mochi_fetch_native,
                             MRB_ARGS_REQ(3));
  if (g_mrb->exc) {
    set_error_text("Mochi.fetch registration failed");
    return -1;
  }
  return 0;
}

/* load_irep(bytes_ptr, byte_len): the loader owns the bytes and they may be
 * released as soon as this returns; the ABI keeps its own copy. */
MOCHI_EXPORT
int32_t mochi_load_irep(const uint8_t *bytes, int32_t length) {
  int64_t result;
  if (!bytes || length <= 0) {
    set_error_text("empty irep");
    return -1;
  }
  clear_error();
  result = goose_vm_load_irep(slice_of(bytes, (size_t)length));
  capture_vm_error();
  return result == 0 ? 0 : -1;
}

/* mount_component(class_name_ptr, class_name_len) -> opaque instance handle. */
MOCHI_EXPORT
uint64_t mochi_mount_component(const uint8_t *name, int32_t length) {
  uint32_t symbol;
  uint64_t class_value;
  struct RClass *klass;
  mrb_value instance;
  if (!g_mrb || !name || length <= 0) {
    set_error_text("runtime is not open");
    return 0;
  }
  clear_error();
  symbol = goose_vm_intern(slice_of(name, (size_t)length));
  class_value = goose_vm_const_get(symbol);
  if (!goose_vm_is_class(class_value)) {
    set_error_text("unknown component class");
    return 0;
  }
  klass = mrb_class_ptr(class_value);
  if (!klass) {
    set_error_text("unknown component class");
    return 0;
  }
  instance = mrb_obj_new(g_mrb, klass, 0, NULL);
  if (g_mrb->exc) {
    set_error_text("component mount failed");
    return 0;
  }
  return (uint64_t)instance;
}

MOCHI_EXPORT
uint32_t mochi_intern(const uint8_t *name, int32_t length) {
  if (!name || length <= 0) return 0;
  return goose_vm_intern(slice_of(name, (size_t)length));
}

MOCHI_EXPORT
int32_t mochi_register_binding(uint64_t instance, uint32_t binding_id,
                               uint32_t getter_symbol) {
  int64_t result;
  clear_error();
  result = goose_vm_register_binding(instance, binding_id, getter_symbol);
  if (result != 0) set_error_text("binding registration failed");
  return result == 0 ? 0 : -1;
}

/* dispatch_event(instance, method_symbol): runs the handler with no args.
 * Returns 1 on success and 0 on failure, leaving the error for the host. */
MOCHI_EXPORT
int32_t mochi_dispatch_event(uint64_t instance, uint32_t method_symbol) {
  clear_error();
  goose_vm_call(instance, method_symbol, 0);
  if (goose_vm_has_error()) {
    capture_vm_error();
    return 0;
  }
  return 1;
}

/* flush_patches(instance) -> patch count, or -1 on failure. The bytes land in
 * the module-owned buffer read through the offset/length pair below. */
MOCHI_EXPORT
int32_t mochi_flush_patches(uint64_t instance) {
  int64_t count;
  int64_t length = 0;
  const uint8_t *bytes;
  clear_error();
  g_patch_len = 0;
  count = goose_vm_flush_patches(instance);
  bytes = goose_vm_patch_bytes(&length);
  g_patch_len = clamp_length(length, MOCHI_PATCH_CAPACITY);
  if (bytes && g_patch_len > 0) {
    memcpy(g_patch_buffer, bytes, (size_t)g_patch_len);
  }
  if (goose_vm_has_error() || count < 0) {
    capture_vm_error();
    return -1;
  }
  return (int32_t)count;
}

MOCHI_EXPORT
int32_t mochi_patch_buffer_offset(void) {
  return (int32_t)(intptr_t)g_patch_buffer;
}

MOCHI_EXPORT
int32_t mochi_patch_buffer_len(void) { return g_patch_len; }

MOCHI_EXPORT
int32_t mochi_last_error_offset(void) {
  return (int32_t)(intptr_t)g_error_text;
}

MOCHI_EXPORT
int32_t mochi_last_error_len(void) { return g_error_len; }

MOCHI_EXPORT
int32_t mochi_fetch_outbox_offset(void) {
  return (int32_t)(intptr_t)g_fetch_outbox;
}

MOCHI_EXPORT
int32_t mochi_fetch_outbox_len(void) { return g_fetch_outbox_len; }

MOCHI_EXPORT
int32_t mochi_fetch_outbox_clear(void) {
  g_fetch_outbox_len = 0;
  g_fetch_outbox[0] = '\0';
  return 0;
}

MOCHI_EXPORT
int32_t mochi_fetch_inbox_offset(void) {
  return (int32_t)(intptr_t)g_fetch_inbox;
}

MOCHI_EXPORT
int32_t mochi_fetch_inbox_capacity(void) { return MOCHI_FETCH_CAPACITY; }

/* deliver_fetch(instance, callback_name, callback_len, response_len): the
 * loader has written the response body to the inbox and calls the component's
 * callback with it. */
MOCHI_EXPORT
int32_t mochi_deliver_fetch(uint64_t instance, const uint8_t *callback,
                            int32_t callback_len, int32_t response_len) {
  char name[MOCHI_CALLBACK_CAPACITY];
  mrb_sym symbol;
  mrb_value response;
  mrb_value ignored;
  if (!g_mrb || !callback || callback_len <= 0 || response_len < 0 ||
      response_len > MOCHI_FETCH_CAPACITY) {
    set_error_text("bad fetch delivery");
    return -1;
  }
  if (callback_len >= MOCHI_CALLBACK_CAPACITY) {
    set_error_text("fetch callback name too long");
    return -1;
  }
  memcpy(name, callback, (size_t)callback_len);
  name[callback_len] = '\0';
  clear_error();
  response = mrb_str_new(g_mrb, (const char *)g_fetch_inbox, response_len);
  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    set_error_text("fetch response allocation failed");
    return -1;
  }
  symbol = mrb_intern_cstr(g_mrb, name);
  ignored = mrb_funcall_argv(g_mrb, instance, symbol, 1, &response);
  (void)ignored;
  if (g_mrb->exc) {
    g_mrb->exc = NULL;
    capture_vm_error();
    return -1;
  }
  return 0;
}

/* Emscripten wants a main for the module even with `--no-entry`. Only the
 * standalone wasm build defines the lifecycle macro. */
#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
int main(void) { return 0; }
#endif
