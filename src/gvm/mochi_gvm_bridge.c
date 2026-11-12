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
#define MOCHI_EMIT_CAPACITY (16 * 1024)
#define MOCHI_EVENT_ARGS_CAPACITY 8192
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
extern uint64_t goose_vm_dispatch_event_args(uint64_t receiver, uint32_t method,
                                              goose_u8_slice json);
extern uint8_t goose_vm_has_method(uint64_t receiver, uint32_t method);
extern int64_t goose_vm_method_req_argc(uint64_t receiver, uint32_t method);
extern int64_t goose_vm_register_binding(uint64_t instance, uint32_t binding_id,
                                         uint32_t getter_symbol);
extern int64_t goose_vm_unregister_component(uint64_t instance);
extern int64_t goose_vm_binding_count(void);
extern int64_t goose_vm_component_count(void);
extern int64_t goose_vm_state_object_count(void);
extern int64_t goose_vm_state_allocated_count(void);
extern int64_t goose_vm_state_free_bytes(void);
extern int64_t goose_vm_flush_patches(uint64_t instance);
extern const uint8_t *goose_vm_patch_bytes(int64_t *out_len);
extern uint8_t goose_vm_is_class(uint64_t value);
extern uint8_t goose_vm_is_hash(uint64_t value);
extern uint64_t goose_vm_hash_get_symbol(uint64_t hash, uint32_t key_symbol);
extern const uint8_t *goose_vm_value_json(uint64_t value, int64_t *out_len);
extern uint64_t goose_vm_make_scratch_string(goose_u8_slice bytes);
extern uint64_t goose_vm_current_self(void);
extern const uint8_t *goose_vm_fetch_request_json(
    int64_t fetch_id, uint64_t instance, uint64_t url, uint64_t callback,
    uint64_t options, int64_t *out_len);
extern int64_t goose_vm_deliver_fetch(uint64_t instance, uint32_t callback_symbol,
                                      goose_u8_slice envelope);
extern void goose_vm_seed_storage(goose_u8_slice key, goose_u8_slice value);
extern void goose_vm_set_route_state(goose_u8_slice path);
extern const uint8_t *goose_vm_host_outbox(int64_t *out_len);
extern void goose_vm_clear_host_outbox(void);
extern int64_t goose_vm_set_ivar_string(uint64_t instance, goose_u8_slice name,
                                        goose_u8_slice value);
extern uint64_t goose_vm_obj_new_with_props(uint32_t class_id,
                                             goose_u8_slice props_json);
extern int64_t goose_vm_set_props_json(uint64_t instance, goose_u8_slice json);
extern const uint8_t *goose_vm_eval_each_expr(uint64_t receiver,
                                              uint32_t method_symbol,
                                              goose_u8_slice json,
                                              int64_t *out_len);

static mrb_state *g_mrb = NULL;
static uint8_t g_patch_buffer[MOCHI_PATCH_CAPACITY];
static int32_t g_patch_len = 0;
static uint8_t g_fetch_outbox[MOCHI_FETCH_CAPACITY];
static int32_t g_fetch_outbox_len = 0;
static uint8_t g_fetch_inbox[MOCHI_FETCH_CAPACITY];
static int32_t g_fetch_next_id = 1;
static uint8_t g_emit_outbox[MOCHI_EMIT_CAPACITY];
static int32_t g_emit_outbox_len = 0;
static uint8_t g_eval_buffer[MOCHI_EVENT_ARGS_CAPACITY];
static int32_t g_eval_len = 0;
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

/* Ruby-callable: Mochi.fetch(url, callback, options = {}).
 * Legacy form: Mochi.fetch(component_id, url, callback).
 * Appends one JSON request line to the outbox. New-form requests resolve the
 * component instance from the active VM frame, so user code never passes its
 * own component handle. */
static mrb_value mochi_fetch_native(mrb_state *mrb, mrb_value self) {
  mrb_value first = mrb_nil_value();
  mrb_value second = mrb_nil_value();
  mrb_value third = mrb_nil_value();
  mrb_value instance_value;
  mrb_value url_value;
  mrb_value callback_value;
  mrb_value options_value;
  mrb_int argc;
  uint64_t instance_handle;
  const uint8_t *line;
  int64_t line_len = 0;
  int instance_len;
  char instance_text[32];
  int fetch_id;
  (void)self;

  argc = mrb_get_args(mrb, "ooo", &first, &second, &third);
  if (argc < 2) return mrb_fixnum_value(-1);

  if (argc >= 3 && mrb_string_p(third)) {
    if (!mrb_string_p(first) || !mrb_string_p(second)) return mrb_fixnum_value(-1);
    instance_value = first;
    url_value = second;
    callback_value = third;
    options_value = mrb_nil_value();
  } else {
    if (!mrb_string_p(first)) return mrb_fixnum_value(-1);
    instance_handle = goose_vm_current_self();
    if (instance_handle == 0) return mrb_fixnum_value(-1);
    instance_len = snprintf(instance_text, sizeof(instance_text), "%llu",
                            (unsigned long long)instance_handle);
    if (instance_len <= 0 || instance_len >= (int)sizeof(instance_text)) {
      return mrb_fixnum_value(-1);
    }
    instance_value = goose_vm_make_scratch_string(
        slice_of(instance_text, (size_t)instance_len));
    if (instance_value == 0) return mrb_fixnum_value(-1);
    url_value = first;
    callback_value = second;
    options_value = argc >= 3 ? third : mrb_nil_value();
  }

  fetch_id = g_fetch_next_id;
  line = goose_vm_fetch_request_json(fetch_id, instance_value, url_value,
                                     callback_value, options_value, &line_len);
  if (!line || line_len <= 0) return mrb_fixnum_value(-1);
  if (g_fetch_outbox_len + (int32_t)line_len >= MOCHI_FETCH_CAPACITY) {
    return mrb_fixnum_value(-1);
  }
  memcpy(g_fetch_outbox + g_fetch_outbox_len, line, (size_t)line_len);
  g_fetch_outbox_len += (int32_t)line_len;
  g_fetch_outbox[g_fetch_outbox_len] = '\0';
  g_fetch_next_id += 1;
  return mrb_fixnum_value(fetch_id);
}

/* Ruby-callable: Mochi.emit("show_canvas").
 * Ruby-callable: Mochi.emit("select_trace", id: "tr_1", target: "cowboy-logs").
 * Appends one JSON object per emit:
 *   {"action":"...","target":...,"payload":...}\n
 * The loader filters by target tag and passes payload to one-argument action
 * handlers. A plain action line is still emitted with null target and payload. */
static int append_text_piece(
    char *buffer, size_t capacity, size_t *at, const void *data, size_t length
) {
  if (*at > capacity || length > capacity - *at) return 0;
  if (length > 0 && data) memcpy(buffer + *at, data, length);
  *at += length;
  return 1;
}

static mrb_value mochi_emit_native(mrb_state *mrb, mrb_value self) {
  static const char PREFIX[] = "{\"action\":";
  static const char TARGET_KEY[] = ",\"target\":";
  static const char PAYLOAD_KEY[] = ",\"payload\":";
  static const char SUFFIX[] = "}\n";
  static const char JSON_NULL[] = "null";
  mrb_value action_value = mrb_nil_value();
  mrb_value payload = mrb_nil_value();
  mrb_value target = mrb_nil_value();
  mrb_int argc;
  const uint8_t *action_json;
  const uint8_t *target_json;
  const uint8_t *payload_json;
  int64_t action_len = 0;
  int64_t target_len = 0;
  int64_t payload_len = 0;
  char line[MOCHI_EMIT_CAPACITY];
  size_t at = 0;
  (void)self;

  argc = mrb_get_args(mrb, "oo", &action_value, &payload);
  if (argc < 1 || !mrb_string_p(action_value) || mrb_string_len(action_value) <= 0) {
    return mrb_fixnum_value(-1);
  }
  if (argc >= 2 && !goose_vm_is_hash(payload)) {
    return mrb_fixnum_value(-1);
  }

  action_json = goose_vm_value_json(action_value, &action_len);
  if (!action_json || action_len <= 0) return mrb_fixnum_value(-1);
  if (!append_text_piece(line, sizeof(line), &at, PREFIX, sizeof(PREFIX) - 1)) {
    return mrb_fixnum_value(-1);
  }
  if (!append_text_piece(line, sizeof(line), &at, action_json, (size_t)action_len)) {
    return mrb_fixnum_value(-1);
  }
  if (!append_text_piece(line, sizeof(line), &at, TARGET_KEY,
                         sizeof(TARGET_KEY) - 1)) {
    return mrb_fixnum_value(-1);
  }

  if (argc >= 2) {
    mrb_sym target_symbol = mrb_intern_cstr(mrb, "target");
    target = goose_vm_hash_get_symbol(payload, target_symbol);
  }
  target_json = goose_vm_value_json(target, &target_len);
  if (!target_json || target_len <= 0) return mrb_fixnum_value(-1);
  if (!append_text_piece(line, sizeof(line), &at, target_json, (size_t)target_len)) {
    return mrb_fixnum_value(-1);
  }
  if (!append_text_piece(line, sizeof(line), &at, PAYLOAD_KEY,
                         sizeof(PAYLOAD_KEY) - 1)) {
    return mrb_fixnum_value(-1);
  }

  if (argc >= 2) {
    payload_json = goose_vm_value_json(payload, &payload_len);
    if (!payload_json || payload_len <= 0) return mrb_fixnum_value(-1);
    if (!append_text_piece(line, sizeof(line), &at, payload_json, (size_t)payload_len)) {
      return mrb_fixnum_value(-1);
    }
  } else if (!append_text_piece(line, sizeof(line), &at, JSON_NULL,
                                sizeof(JSON_NULL) - 1)) {
    return mrb_fixnum_value(-1);
  }

  if (!append_text_piece(line, sizeof(line), &at, SUFFIX, sizeof(SUFFIX) - 1)) {
    return mrb_fixnum_value(-1);
  }
  if (g_emit_outbox_len + (int32_t)at >= MOCHI_EMIT_CAPACITY) {
    return mrb_fixnum_value(-1);
  }

  memcpy(g_emit_outbox + g_emit_outbox_len, line, at);
  g_emit_outbox_len += (int32_t)at;
  g_emit_outbox[g_emit_outbox_len] = '\0';
  return mrb_fixnum_value(0);
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
                             MRB_ARGS_REQ(2) | MRB_ARGS_OPT(1));
  mrb_define_module_function(g_mrb, mochi, "emit", mochi_emit_native,
                             MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  if (g_mrb->exc) {
    set_error_text("Mochi module registration failed");
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
    capture_vm_error();
    if (g_error_len == 0) set_error_text("unknown component class");
    return 0;
  }
  klass = mrb_class_ptr(class_value);
  if (!klass) {
    set_error_text("unknown component class");
    return 0;
  }
  instance = mrb_obj_new(g_mrb, klass, 0, NULL);
  if (g_mrb->exc) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("component mount failed");
    return 0;
  }
  return (uint64_t)instance;
}

/* mount_component_props(class_name, props_json) -> opaque instance handle.
 * The props object is parsed and installed before `initialize`, then restored
 * after it so a child's initialization cannot overwrite a parent-supplied
 * input. A malformed payload fails the mount before any instance is returned. */
MOCHI_EXPORT
uint64_t mochi_mount_component_props(const uint8_t *name, int32_t length,
                                     const uint8_t *json, int32_t json_length) {
  uint32_t symbol;
  uint64_t class_value;
  struct RClass *klass;
  uint64_t instance;
  if (!g_mrb || !name || length <= 0) {
    set_error_text("runtime is not open");
    return 0;
  }
  if (!json || json_length < 0) {
    set_error_text("invalid props payload");
    return 0;
  }
  clear_error();
  symbol = goose_vm_intern(slice_of(name, (size_t)length));
  class_value = goose_vm_const_get(symbol);
  if (!goose_vm_is_class(class_value)) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("unknown component class");
    return 0;
  }
  klass = mrb_class_ptr(class_value);
  if (!klass) {
    set_error_text("unknown component class");
    return 0;
  }
  instance = goose_vm_obj_new_with_props(
      klass->class_id, slice_of(json, (size_t)json_length));
  if (goose_vm_has_error()) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("component mount failed");
    return 0;
  }
  return instance;
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
  if (result != 0) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("binding registration failed");
  }
  return result == 0 ? 0 : -1;
}

/* unmount_component(instance): drops every binding and the component root
 * registered for this instance. Safe to call twice; classes and IREPs stay
 * loaded for other instances. */
MOCHI_EXPORT
int32_t mochi_unmount_component(uint64_t instance) {
  int64_t result;
  clear_error();
  result = goose_vm_unregister_component(instance);
  if (result != 0) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("unmount failed");
  }
  return result == 0 ? 0 : -1;
}

/* Test/debug registration counts. The loader uses them to prove that ordinary
 * navigation returns to the active-screen baseline instead of growing. */
MOCHI_EXPORT
int32_t mochi_binding_count(void) {
  return (int32_t)goose_vm_binding_count();
}

MOCHI_EXPORT
int32_t mochi_component_count(void) {
  return (int32_t)goose_vm_component_count();
}

/* Test/debug reclamation counts. `state_objects` is the table high-water mark,
 * `state_allocated` includes headers not yet swept, and `state_free_bytes` is the
 * reclaimed string range still available for reuse. */
MOCHI_EXPORT
int32_t mochi_state_object_count(void) {
  return (int32_t)goose_vm_state_object_count();
}

MOCHI_EXPORT
int32_t mochi_state_allocated_count(void) {
  return (int32_t)goose_vm_state_allocated_count();
}

MOCHI_EXPORT
int32_t mochi_state_free_bytes(void) {
  return (int32_t)goose_vm_state_free_bytes();
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

/* dispatch_event_args(instance, method_symbol, json_ptr, json_len): decodes a
 * JSON array of strings, ints, booleans, nulls, arrays and objects into tick
 * values and invokes the handler with them. */
MOCHI_EXPORT
int32_t mochi_dispatch_event_args(uint64_t instance, uint32_t method_symbol,
                                  const uint8_t *json, int32_t length) {
  clear_error();
  if (!json || length <= 0 || length > MOCHI_EVENT_ARGS_CAPACITY) {
    set_error_text("invalid event arguments");
    return 0;
  }
  goose_vm_dispatch_event_args(instance, method_symbol,
                               slice_of(json, (size_t)length));
  if (goose_vm_has_error()) {
    capture_vm_error();
    return 0;
  }
  return 1;
}

/* has_method(instance, name_ptr, name_len): lets the loader decide whether a
 * document-level action belongs to this component before dispatching it. */
MOCHI_EXPORT
int32_t mochi_has_method(uint64_t instance, const uint8_t *name, int32_t length) {
  uint32_t symbol;
  if (!g_mrb || !name || length <= 0) return 0;
  symbol = goose_vm_intern(slice_of(name, (size_t)length));
  if (symbol == 0 || goose_vm_has_error()) return 0;
  return goose_vm_has_method(instance, symbol) == 1 ? 1 : 0;
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

static void sync_host_outbox(void) {
  int64_t host_len = 0;
  const uint8_t *host_bytes = goose_vm_host_outbox(&host_len);
  if (host_bytes && host_len > 0) {
    int32_t avail = MOCHI_EMIT_CAPACITY - 1 - g_emit_outbox_len;
    int32_t copy_len = clamp_length(host_len, avail);
    if (copy_len > 0) {
      memcpy(g_emit_outbox + g_emit_outbox_len, host_bytes, (size_t)copy_len);
      g_emit_outbox_len += copy_len;
      g_emit_outbox[g_emit_outbox_len] = '\0';
    }
    goose_vm_clear_host_outbox();
  }
}

MOCHI_EXPORT
int32_t mochi_emit_outbox_offset(void) {
  sync_host_outbox();
  return (int32_t)(intptr_t)g_emit_outbox;
}

MOCHI_EXPORT
int32_t mochi_emit_outbox_len(void) {
  sync_host_outbox();
  return g_emit_outbox_len;
}

MOCHI_EXPORT
int32_t mochi_emit_outbox_clear(void) {
  goose_vm_clear_host_outbox();
  g_emit_outbox_len = 0;
  g_emit_outbox[0] = '\0';
  return 0;
}

MOCHI_EXPORT
void mochi_seed_storage(const uint8_t *key, int32_t key_len,
                        const uint8_t *val, int32_t val_len) {
  if (!key || key_len <= 0 || val_len < 0) return;
  goose_vm_seed_storage(slice_of(key, (size_t)key_len),
                        slice_of(val ? val : (const uint8_t *)"", (size_t)val_len));
}

MOCHI_EXPORT
void mochi_set_route_state(const uint8_t *path, int32_t path_len) {
  if (!path || path_len < 0) return;
  goose_vm_set_route_state(slice_of(path, (size_t)path_len));
}

/* set_ivar_string(instance, name, value) -> 0 on success, -1 on failure.
 * The loader writes live child attributes through this entry; any value other
 * than 0 is a failure and the detail is read through mochi_last_error_*. An
 * identical value is still reported as success because the VM marks no dirty
 * ivar for it. */
MOCHI_EXPORT
int32_t mochi_set_ivar_string(uint64_t instance, const uint8_t *name,
                              int32_t name_len, const uint8_t *val,
                              int32_t val_len) {
  int64_t result;
  clear_error();
  if (!name || name_len <= 0 || val_len < 0) {
    set_error_text("invalid ivar assignment");
    return -1;
  }
  result = goose_vm_set_ivar_string(
      instance, slice_of(name, (size_t)name_len),
      slice_of(val ? val : (const uint8_t *)"", (size_t)val_len));
  if (result != 0) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("ivar assignment failed");
  }
  return result == 0 ? 0 : -1;
}

/* set_props_json(instance, json) -> 0 on success, -1 on failure.
 * The loader batches every changed declared prop into one JSON object so one
 * VM entry installs them together before the caller's single patch flush. */
MOCHI_EXPORT
int32_t mochi_set_props_json(uint64_t instance, const uint8_t *json,
                             int32_t json_len) {
  int64_t result;
  clear_error();
  if (!json || json_len <= 0) {
    set_error_text("empty props payload");
    return -1;
  }
  result = goose_vm_set_props_json(instance, slice_of(json, (size_t)json_len));
  if (result != 0) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("props update failed");
  }
  return result == 0 ? 0 : -1;
}

MOCHI_EXPORT
int32_t mochi_eval_each_expr(uint64_t instance, uint32_t method_symbol,
                             const uint8_t *json, int32_t json_len) {
  int64_t out_len = 0;
  const uint8_t *bytes;
  g_eval_len = 0;
  if (!json || json_len <= 0) return -1;
  bytes = goose_vm_eval_each_expr(instance, method_symbol,
                                  slice_of(json, (size_t)json_len), &out_len);
  if (goose_vm_has_error()) {
    capture_vm_error();
    return -1;
  }
  g_eval_len = clamp_length(out_len, MOCHI_EVENT_ARGS_CAPACITY - 1);
  if (bytes && g_eval_len > 0) {
    memcpy(g_eval_buffer, bytes, (size_t)g_eval_len);
  }
  g_eval_buffer[g_eval_len] = '\0';
  return g_eval_len;
}

MOCHI_EXPORT
int32_t mochi_eval_buffer_offset(void) {
  return (int32_t)(intptr_t)g_eval_buffer;
}

MOCHI_EXPORT
int32_t mochi_eval_buffer_len(void) { return g_eval_len; }

/* deliver_fetch(instance, callback_name, callback_len, response_len): the
 * loader has written the JSON response envelope to the inbox. Goose parses the
 * envelope into an indifferent Hash and invokes the callback with that Hash. */
MOCHI_EXPORT
int32_t mochi_deliver_fetch(uint64_t instance, const uint8_t *callback,
                            int32_t callback_len, int32_t response_len) {
  char name[MOCHI_CALLBACK_CAPACITY];
  mrb_sym symbol;
  int64_t result;
  if (!g_mrb || !callback || callback_len <= 0 || response_len <= 0 ||
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
  symbol = mrb_intern_cstr(g_mrb, name);
  if (symbol == 0) {
    set_error_text("fetch callback name invalid");
    return -1;
  }
  result = goose_vm_deliver_fetch(instance, symbol,
                                  slice_of(g_fetch_inbox, (size_t)response_len));
  if (result != 0 || goose_vm_has_error()) {
    capture_vm_error();
    if (g_error_len == 0) set_error_text("fetch callback failed");
    return -1;
  }
  return 0;
}

/* Emscripten wants a main for the module even with `--no-entry`. Only the
 * standalone wasm build defines the lifecycle macro. */
#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
int main(void) { return 0; }
#endif
