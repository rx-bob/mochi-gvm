/*
 * C-to-Goose bridge for the opaque mruby ABI.
 *
 * The shim owns C function pointers, class tokens and the current native-call
 * argument window. All Ruby values and storage stay inside the Goose VM; the
 * exported goose_vm_* functions are the only boundary.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/compile.h>
#include <mruby/error.h>
#include <mruby/irep.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <stdlib.h>
#include <string.h>

#define SHIM_MAX_CLASSES 256
#define SHIM_MAX_NATIVES 128
#define SHIM_MAX_ARGS 8
#define SHIM_ZARG_SIZE 512
#define SHIM_CSTR_SIZE 4096
#define SHIM_ERROR_SIZE 256
#define SHIM_OBJECT_CLASS_ID 0xFFFFFF00u
#define SHIM_NULL_CLASS_ID 0xFFFFFFFFu
#define SHIM_NATIVE_FAIL 0xFFFFFFFFFFFFFFFFull

/* Goose emits core C types under `#pragma pack(push, 1)`, so a u8 slice is
 * { pointer, i64 } with the length at offset 4 on wasm32, not offset 8. Keep
 * the host-side layout identical or the exported-call ABI reads shifted data. */
typedef struct __attribute__((packed)) {
  uint8_t *data;
  int64_t len;
} goose_u8_slice;

_Static_assert(offsetof(goose_u8_slice, len) == sizeof(void *),
               "Goose u8 slice length must follow the packed pointer");
_Static_assert(sizeof(goose_u8_slice) == sizeof(void *) + sizeof(int64_t),
               "Goose u8 slice must have no padding");

typedef struct {
  mrb_func_t func;
  mrb_aspec aspec;
} shim_native;

typedef struct {
  struct RClass classes[SHIM_MAX_CLASSES];
  int class_count;
  struct RObject exc_object;
  char error_text[SHIM_ERROR_SIZE];
  char cstr[SHIM_CSTR_SIZE];
  int call_argc;
  mrb_value call_args[SHIM_MAX_ARGS];
  mrb_value native_args[SHIM_MAX_ARGS];
  char zargs[SHIM_MAX_ARGS][SHIM_ZARG_SIZE];
  uint8_t *load_buf;
  size_t load_len;
  shim_native natives[SHIM_MAX_NATIVES];
  uint32_t native_count;
} mrb_shim;

/* A `--header` host build owns Goose startup. A `goose build` program
 * initializes the runtime in its own main, so it must not reference this. */
#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
extern void goose_init(int argc, char **argv);
#endif

/* These are the symbols emitted by the Goose ABI module. */
extern int64_t goose_vm_open(void);
extern void goose_vm_close(void);
extern int64_t goose_vm_load_irep(goose_u8_slice bytes);
extern const uint8_t *goose_vm_last_error(int64_t *out_len);
extern uint8_t goose_vm_has_error(void);
extern uint32_t goose_vm_intern(goose_u8_slice name);
extern uint32_t goose_vm_define_module(uint32_t name);
extern uint32_t goose_vm_define_class(uint32_t name, uint32_t superclass);
extern int64_t goose_vm_define_native(uint32_t class_id, uint32_t name,
                                      uint32_t native_id);
extern uint64_t goose_vm_const_get(uint32_t name);
extern uint64_t goose_vm_obj_new(uint32_t class_id);
extern void goose_vm_set_arg(int64_t index, uint64_t value);
extern uint64_t goose_vm_call(uint64_t receiver, uint32_t method, int64_t argc);
extern int64_t goose_vm_register_binding(uint64_t instance, uint32_t binding_id,
                                         uint32_t getter_symbol);
extern int64_t goose_vm_flush_patches(uint64_t instance);
extern const uint8_t *goose_vm_patch_bytes(int64_t *out_len);
extern uint64_t goose_vm_make_string(goose_u8_slice bytes);
extern const uint8_t *goose_vm_string_bytes(uint64_t value, int64_t *out_len);
extern uint8_t goose_vm_is_string(uint64_t value);
extern uint8_t goose_vm_is_class(uint64_t value);

/* Called by the Goose VM when a registered native method is sent. */
void goose_abi_native_set_arg(int64_t index, uint64_t value);
uint64_t goose_abi_native_call(uint32_t native_id, uint64_t self, int64_t argc);

/* Loads compile-time registered mrbgems after the VM is open. */
void mochi_mrbgem_load_all(mrb_state *mrb);

static mrb_state *g_mrb = NULL;

static mrb_shim *shim_of(mrb_state *mrb) {
  if (!mrb) return NULL;
  return (mrb_shim *)mrb->shim;
}

static goose_u8_slice slice_of(const void *data, size_t length) {
  goose_u8_slice slice;
  slice.data = (uint8_t *)data;
  slice.len = (int64_t)length;
  return slice;
}

static uint32_t value_tag(mrb_value value) {
  return (uint32_t)(value >> MRB_TAG_SHIFT);
}

static uint64_t class_value(uint32_t class_id) {
  return ((uint64_t)MRB_TAG_CLASS << MRB_TAG_SHIFT) | (uint64_t)class_id;
}

static uint32_t class_id_of(mrb_value value) {
  return (uint32_t)(value & 0xFFFFFFFFu);
}

static uint64_t exception_value(void) {
  return ((uint64_t)MRB_TAG_EXCEPTION << MRB_TAG_SHIFT) | 1u;
}

static void clear_exc(mrb_state *mrb) {
  if (mrb) mrb->exc = NULL;
}

static void set_exc(mrb_state *mrb, const char *fallback) {
  mrb_shim *shim = shim_of(mrb);
  const uint8_t *message = NULL;
  int64_t length = 0;
  size_t copy = 0;

  if (!mrb || !shim) return;
  mrb->exc = &shim->exc_object;
  message = goose_vm_last_error(&length);
  if (!message || length <= 0) {
    message = (const uint8_t *)fallback;
    length = fallback ? (int64_t)strlen(fallback) : 0;
  }
  if (length >= SHIM_ERROR_SIZE) length = SHIM_ERROR_SIZE - 1;
  copy = (size_t)length;
  if (message && copy > 0) memcpy(shim->error_text, message, copy);
  shim->error_text[copy] = '\0';
}

static struct RClass *class_for_id(mrb_state *mrb, uint32_t class_id) {
  mrb_shim *shim = shim_of(mrb);
  int index = 0;

  if (!shim) return NULL;
  for (index = 0; index < shim->class_count; index++) {
    if (shim->classes[index].class_id == class_id) return &shim->classes[index];
  }
  if (shim->class_count >= SHIM_MAX_CLASSES) {
    set_exc(mrb, "class table full");
    return &shim->classes[0];
  }
  shim->classes[shim->class_count].class_id = class_id;
  shim->class_count += 1;
  return &shim->classes[shim->class_count - 1];
}

static mrb_value string_value(mrb_state *mrb, const char *text, size_t length) {
  mrb_value value = goose_vm_make_string(slice_of(text, length));
  if (goose_vm_has_error()) {
    set_exc(mrb, "string allocation failed");
    return mrb_nil_value();
  }
  return value;
}

mrb_state *mrb_open(void) {
  mrb_state *mrb;
  mrb_shim *shim;
  if (g_mrb) return g_mrb;
  mrb = (mrb_state *)calloc(1, sizeof(mrb_state));
  shim = (mrb_shim *)calloc(1, sizeof(mrb_shim));
  if (!mrb || !shim) {
    free(mrb);
    free(shim);
    return NULL;
  }
  mrb->shim = shim;
#ifdef MOCHI_ABI_OWNS_GOOSE_LIFECYCLE
  goose_init(0, NULL);
#endif
  if (goose_vm_open() != 0) {
    free(shim);
    free(mrb);
    return NULL;
  }
  g_mrb = mrb;
  mrb->object_class = class_for_id(mrb, SHIM_OBJECT_CLASS_ID);
  clear_exc(mrb);
  mochi_mrbgem_load_all(mrb);
  return mrb;
}

/* The host owns `goose_exit`: it frees the global stacks that still back the
 * ABI's retained bytecode. Closing an mrb state does not end Goose. */
void mrb_close(mrb_state *mrb) {
  mrb_shim *shim = shim_of(mrb);
  if (!mrb) return;
  goose_vm_close();
  if (shim) {
    free(shim->load_buf);
    free(shim);
  }
  if (g_mrb == mrb) g_mrb = NULL;
  free(mrb);
}

void *mrb_malloc(mrb_state *mrb, size_t size) {
  (void)mrb;
  return calloc(1, size > 0 ? size : 1);
}

mrb_sym mrb_intern_cstr(mrb_state *mrb, const char *name) {
  (void)mrb;
  if (!name) return 0;
  return goose_vm_intern(slice_of(name, strlen(name)));
}

mrb_value mrb_const_get(mrb_state *mrb, mrb_value mod, mrb_sym name) {
  mrb_value value;
  (void)mod;
  clear_exc(mrb);
  value = goose_vm_const_get(name);
  if (goose_vm_has_error()) {
    set_exc(mrb, "constant lookup failed");
    return mrb_nil_value();
  }
  return value;
}

struct RClass *mrb_class_ptr(mrb_value value) {
  if (value_tag(value) != MRB_TAG_CLASS || !g_mrb) return NULL;
  return class_for_id(g_mrb, class_id_of(value));
}

mrb_bool mrb_class_p(mrb_value value) {
  return (mrb_bool)(value_tag(value) == MRB_TAG_CLASS);
}

mrb_bool mrb_string_p(mrb_value value) {
  if (value_tag(value) == MRB_TAG_EXCEPTION) return 0;
  return goose_vm_is_string(value);
}

mrb_value mrb_obj_value(void *pointer) {
  mrb_shim *shim = shim_of(g_mrb);
  int index = 0;
  if (!pointer) return mrb_nil_value();
  if (shim && pointer == (void *)&shim->exc_object) return exception_value();
  if (shim) {
    for (index = 0; index < shim->class_count; index++) {
      if (pointer == (void *)&shim->classes[index]) {
        return class_value(shim->classes[index].class_id);
      }
    }
  }
  return mrb_nil_value();
}

mrb_value mrb_nil_value(void) { return 0; }

mrb_value mrb_false_value(void) {
  return (uint64_t)MRB_TAG_FALSE << MRB_TAG_SHIFT;
}

mrb_value mrb_true_value(void) {
  return (uint64_t)MRB_TAG_TRUE << MRB_TAG_SHIFT;
}

mrb_value mrb_bool_value(mrb_bool value) {
  return value ? mrb_true_value() : mrb_false_value();
}

mrb_value mrb_fixnum_value(mrb_int value) {
  return ((uint64_t)MRB_TAG_FIXNUM << MRB_TAG_SHIFT) |
         (uint64_t)(uint32_t)value;
}

mrb_int mrb_fixnum(mrb_value value) {
  return (mrb_int)(int32_t)(uint32_t)value;
}

mrb_bool mrb_nil_p(mrb_value value) {
  return (mrb_bool)(value_tag(value) == MRB_TAG_NIL);
}

mrb_bool mrb_fixnum_p(mrb_value value) {
  return (mrb_bool)(value_tag(value) == MRB_TAG_FIXNUM);
}

static void define_native(mrb_state *mrb, struct RClass *c, const char *name,
                          mrb_func_t func, mrb_aspec aspec) {
  mrb_shim *shim = shim_of(mrb);
  mrb_sym symbol;
  uint32_t native_id;
  if (!mrb || !shim || !c || !name || !func) {
    set_exc(mrb, "invalid native method");
    return;
  }
  if (shim->native_count >= SHIM_MAX_NATIVES) {
    set_exc(mrb, "native method table full");
    return;
  }
  native_id = shim->native_count;
  shim->natives[native_id].func = func;
  shim->natives[native_id].aspec = aspec;
  shim->native_count += 1;
  symbol = mrb_intern_cstr(mrb, name);
  if (goose_vm_define_native(c->class_id, symbol, native_id) != 0) {
    set_exc(mrb, "native method registration failed");
  }
}

mrb_value mrb_obj_new(mrb_state *mrb, struct RClass *c, mrb_int argc,
                      const mrb_value *argv) {
  mrb_value value;
  (void)argc;
  (void)argv;
  if (!c) {
    set_exc(mrb, "unknown class");
    return mrb_nil_value();
  }
  clear_exc(mrb);
  value = goose_vm_obj_new(c->class_id);
  if (goose_vm_has_error()) {
    set_exc(mrb, "object allocation failed");
    return mrb_nil_value();
  }
  return value;
}

void mrb_gc_register(mrb_state *mrb, mrb_value value) {
  (void)mrb;
  (void)value;
}

struct RClass *mrb_define_module(mrb_state *mrb, const char *name) {
  uint32_t class_id;
  if (!mrb || !name) return NULL;
  class_id = goose_vm_define_module(mrb_intern_cstr(mrb, name));
  if (class_id == SHIM_NULL_CLASS_ID) {
    set_exc(mrb, "module definition failed");
    return class_for_id(mrb, SHIM_OBJECT_CLASS_ID);
  }
  return class_for_id(mrb, class_id);
}

struct RClass *mrb_define_class(mrb_state *mrb, const char *name,
                                struct RClass *super) {
  uint32_t class_id;
  uint32_t super_id = super ? super->class_id : SHIM_OBJECT_CLASS_ID;
  if (!mrb || !name) return NULL;
  class_id = goose_vm_define_class(mrb_intern_cstr(mrb, name), super_id);
  if (class_id == SHIM_NULL_CLASS_ID) {
    set_exc(mrb, "class definition failed");
    return class_for_id(mrb, SHIM_OBJECT_CLASS_ID);
  }
  return class_for_id(mrb, class_id);
}

void mrb_define_method(mrb_state *mrb, struct RClass *c, const char *name,
                       mrb_func_t func, mrb_aspec aspec) {
  define_native(mrb, c, name, func, aspec);
}

void mrb_define_module_function(mrb_state *mrb, struct RClass *c,
                                const char *name, mrb_func_t func,
                                mrb_aspec aspec) {
  define_native(mrb, c, name, func, aspec);
}

mrb_int mrb_get_args(mrb_state *mrb, const char *format, ...) {
  mrb_shim *shim = shim_of(mrb);
  va_list args;
  int used = 0;
  const char *cursor = format;
  if (!mrb || !shim || !format) return 0;
  va_start(args, format);
  while (*cursor && used < shim->call_argc) {
    mrb_value value = shim->call_args[used];
    if (*cursor == 'z') {
      const char **out = va_arg(args, const char **);
      const char *text = mrb_string_p(value) ? mrb_string_ptr(value) : "";
      mrb_int length = mrb_string_p(value) ? mrb_string_len(value) : 0;
      size_t copy = length > 0 ? (size_t)length : 0;
      if (copy >= SHIM_ZARG_SIZE) copy = SHIM_ZARG_SIZE - 1;
      if (copy > 0 && text) memcpy(shim->zargs[used], text, copy);
      shim->zargs[used][copy] = '\0';
      if (out) *out = shim->zargs[used];
    } else if (*cursor == 'i') {
      mrb_int *out = va_arg(args, mrb_int *);
      if (out) *out = mrb_fixnum_p(value) ? mrb_fixnum(value) : 0;
    } else if (*cursor == 'S' || *cursor == 'o') {
      mrb_value *out = va_arg(args, mrb_value *);
      if (out) *out = value;
    } else {
      break;
    }
    used += 1;
    cursor += 1;
  }
  va_end(args);
  return used;
}

static int native_call_args(mrb_state *mrb, mrb_int argc) {
  mrb_shim *shim = shim_of(mrb);
  int count = 0;
  if (!shim) return 0;
  if (argc < 0) argc = 0;
  if (argc > SHIM_MAX_ARGS) argc = SHIM_MAX_ARGS;
  count = (int)argc;
  shim->call_argc = count;
  for (int index = 0; index < count; index++) {
    shim->call_args[index] = shim->native_args[index];
  }
  return count;
}

void goose_abi_native_set_arg(int64_t index, uint64_t value) {
  mrb_shim *shim = shim_of(g_mrb);
  if (!shim || index < 0 || index >= SHIM_MAX_ARGS) return;
  shim->native_args[index] = value;
}

uint64_t goose_abi_native_call(uint32_t native_id, uint64_t self, int64_t argc) {
  mrb_shim *shim = shim_of(g_mrb);
  mrb_value result;
  if (!shim || native_id >= shim->native_count) return SHIM_NATIVE_FAIL;
  native_call_args(g_mrb, argc);
  clear_exc(g_mrb);
  result = shim->natives[native_id].func(g_mrb, self);
  shim->call_argc = 0;
  if (g_mrb->exc) return SHIM_NATIVE_FAIL;
  return result;
}

mrb_value mrb_funcall_argv(mrb_state *mrb, mrb_value self, mrb_sym name,
                           mrb_int argc, const mrb_value *argv) {
  mrb_value result;
  if (!mrb || argc < 0 || argc > SHIM_MAX_ARGS) {
    set_exc(mrb, "bad argument count");
    return mrb_nil_value();
  }
  for (int index = 0; index < (int)argc; index++) {
    goose_vm_set_arg(index, argv ? argv[index] : 0);
  }
  clear_exc(mrb);
  result = goose_vm_call(self, name, argc);
  if (goose_vm_has_error()) {
    set_exc(mrb, "method call failed");
    return mrb_nil_value();
  }
  return result;
}

mrb_value mrb_funcall(mrb_state *mrb, mrb_value self, const char *name,
                      mrb_int argc, ...) {
  mrb_value argv[SHIM_MAX_ARGS];
  va_list args;
  int count = 0;
  if (!mrb || !name) return mrb_nil_value();
  if (argc < 0 || argc > SHIM_MAX_ARGS) {
    set_exc(mrb, "bad argument count");
    return mrb_nil_value();
  }
  if (value_tag(self) == MRB_TAG_EXCEPTION) {
    if (strcmp(name, "message") == 0) {
      mrb_shim *shim = shim_of(mrb);
      if (shim) return string_value(mrb, shim->error_text,
                                    strlen(shim->error_text));
    }
    return mrb_nil_value();
  }
  va_start(args, argc);
  for (count = 0; count < (int)argc; count++) {
    argv[count] = va_arg(args, mrb_value);
  }
  va_end(args);
  return mrb_funcall_argv(mrb, self, mrb_intern_cstr(mrb, name), argc, argv);
}

mrb_value mrb_load_irep(mrb_state *mrb, const uint8_t *irep) {
  uint32_t size;
  int64_t result;

  if (!mrb || !irep) {
    set_exc(mrb, "missing irep bytes");
    return mrb_nil_value();
  }
  if (memcmp(irep, "RITE", 4) != 0) {
    set_exc(mrb, "bad irep header");
    return mrb_nil_value();
  }
  size = ((uint32_t)irep[8] << 24) | ((uint32_t)irep[9] << 16) |
         ((uint32_t)irep[10] << 8) | (uint32_t)irep[11];
  if (size < 12) {
    set_exc(mrb, "bad irep size");
    return mrb_nil_value();
  }
  result = goose_vm_load_irep(slice_of(irep, (size_t)size));
  if (result != 0) {
    set_exc(mrb, "irep load failed");
    return mrb_nil_value();
  }
  clear_exc(mrb);
  return mrb_nil_value();
}

const char *mrb_abi_last_error(mrb_state *mrb) {
  mrb_shim *shim = shim_of(mrb);
  if (!shim) return "";
  return shim->error_text;
}

mrb_value mrb_load_irep_buf(mrb_state *mrb, const void *bytes, size_t length) {
  static const uint8_t rite_prefix[10] = {'R', 'I', 'T', 'E', '0',
                                          '4', '0', '0', 0, 0};
  mrb_shim *shim = shim_of(mrb);
  const uint8_t *source = (const uint8_t *)bytes;
  uint8_t *copy = NULL;
  size_t total = 0;
  size_t prefix = 0;
  int64_t result = 0;

  if (!mrb || !shim || !bytes) {
    set_exc(mrb, "missing irep bytes");
    return mrb_nil_value();
  }
  if (length >= 4 && memcmp(bytes, "RITE", 4) == 0) {
    prefix = 0;
  } else {
    prefix = sizeof(rite_prefix);
  }
  if (length > (size_t)-1 - prefix) {
    set_exc(mrb, "irep buffer too large");
    return mrb_nil_value();
  }
  total = prefix + length;
  copy = (uint8_t *)malloc(total > 0 ? total : 1);
  if (!copy) {
    set_exc(mrb, "irep allocation failed");
    return mrb_nil_value();
  }
  if (prefix > 0) memcpy(copy, rite_prefix, prefix);
  if (length > 0) memcpy(copy + prefix, source, length);

  result = goose_vm_load_irep(slice_of(copy, total));
  free(shim->load_buf);
  shim->load_buf = copy;
  shim->load_len = total;
  if (result != 0) {
    set_exc(mrb, "irep load failed");
    return mrb_nil_value();
  }
  clear_exc(mrb);
  return mrb_nil_value();
}

mrb_value mrb_str_new(mrb_state *mrb, const char *data, mrb_int len) {
  if (!mrb || len < 0) {
    set_exc(mrb, "bad string length");
    return mrb_nil_value();
  }
  return string_value(mrb, data ? data : "", (size_t)len);
}

const char *mrb_string_ptr(mrb_value value) {
  int64_t length = 0;
  return (const char *)goose_vm_string_bytes(value, &length);
}

mrb_int mrb_string_len(mrb_value value) {
  int64_t length = 0;
  (void)goose_vm_string_bytes(value, &length);
  return (mrb_int)length;
}

const char *mrb_str_to_cstr(mrb_state *mrb, mrb_value value) {
  mrb_shim *shim = shim_of(mrb);
  int64_t length = 0;
  const uint8_t *data = goose_vm_string_bytes(value, &length);
  size_t copy = length > 0 ? (size_t)length : 0;
  if (!shim) return "";
  if (copy >= SHIM_CSTR_SIZE) copy = SHIM_CSTR_SIZE - 1;
  if (copy > 0 && data) memcpy(shim->cstr, data, copy);
  shim->cstr[copy] = '\0';
  return shim->cstr;
}
