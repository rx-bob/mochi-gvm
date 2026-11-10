/*
 * Opaque mruby ABI for the Goose Direction C runtime.
 *
 * This header intentionally describes only the C surface used by Mochi
 * components and well-behaved opaque mrbgems. `mrb_value` is an eight-byte
 * Goose handle, not mruby's word-boxed representation; code must not inspect
 * it or mix this header with libmruby.
 */
#ifndef MRUBY_H
#define MRUBY_H

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MRB_API
#define MRB_BEGIN_DECL
#define MRB_END_DECL

typedef struct mrb_state mrb_state;
typedef struct RClass RClass;
typedef struct RObject RObject;

typedef uint64_t mrb_value;
typedef uint32_t mrb_sym;
typedef uint32_t mrb_aspec;
typedef int64_t mrb_int;
typedef unsigned char mrb_bool;
typedef mrb_value (*mrb_func_t)(mrb_state *, mrb_value);

/* A class token in this ABI carries only the stable Goose class id. */
struct RClass {
  uint32_t class_id;
};

struct RObject {
  struct RClass *c;
};

/* The public state is opaque except for the two fields mruby hosts inspect. */
struct mrb_state {
  struct RClass *object_class;
  struct RObject *exc;
  void *shim;
};

#define MRB_TAG_SHIFT 32
#define MRB_TAG_NIL 0
#define MRB_TAG_FALSE 1
#define MRB_TAG_TRUE 2
#define MRB_TAG_FIXNUM 3
#define MRB_TAG_SYMBOL 4
#define MRB_TAG_CLASS 5
#define MRB_TAG_ARENA 6
#define MRB_TAG_BLOCK 7
#define MRB_TAG_EXCEPTION 8

#define MRB_ARGS_REQ(n) ((mrb_aspec)(((n) & 0x1f) << 18))
#define MRB_ARGS_OPT(n) ((mrb_aspec)(((n) & 0x1f) << 13))
#define MRB_ARGS_REST() ((mrb_aspec)(1 << 12))
#define MRB_ARGS_POST(n) ((mrb_aspec)(((n) & 0x1f) << 7))
#define MRB_ARGS_KEY(n, r) ((mrb_aspec)((((n) & 0x1f) << 2) | (((r) & 1) << 1)))
#define MRB_ARGS_NONE() ((mrb_aspec)0)

MRB_API mrb_state *mrb_open(void);
MRB_API void mrb_close(mrb_state *mrb);
MRB_API void *mrb_malloc(mrb_state *mrb, size_t size);
MRB_API mrb_sym mrb_intern_cstr(mrb_state *mrb, const char *name);
MRB_API mrb_value mrb_obj_new(mrb_state *mrb, struct RClass *c, mrb_int argc,
                              const mrb_value *argv);
MRB_API mrb_value mrb_funcall(mrb_state *mrb, mrb_value self, const char *name,
                              mrb_int argc, ...);
MRB_API mrb_value mrb_funcall_argv(mrb_state *mrb, mrb_value self, mrb_sym name,
                                   mrb_int argc, const mrb_value *argv);
MRB_API void mrb_gc_register(mrb_state *mrb, mrb_value value);
MRB_API struct RClass *mrb_define_module(mrb_state *mrb, const char *name);
MRB_API struct RClass *mrb_define_class(mrb_state *mrb, const char *name,
                                        struct RClass *super);
MRB_API void mrb_define_method(mrb_state *mrb, struct RClass *c,
                               const char *name, mrb_func_t func,
                               mrb_aspec aspec);
MRB_API void mrb_define_module_function(mrb_state *mrb, struct RClass *c,
                                        const char *name, mrb_func_t func,
                                        mrb_aspec aspec);
MRB_API mrb_int mrb_get_args(mrb_state *mrb, const char *format, ...);

MRB_API mrb_value mrb_nil_value(void);
MRB_API mrb_value mrb_false_value(void);
MRB_API mrb_value mrb_true_value(void);
MRB_API mrb_value mrb_bool_value(mrb_bool value);
MRB_API mrb_value mrb_fixnum_value(mrb_int value);
MRB_API mrb_int mrb_fixnum(mrb_value value);
MRB_API mrb_bool mrb_nil_p(mrb_value value);
MRB_API mrb_bool mrb_fixnum_p(mrb_value value);
MRB_API mrb_bool mrb_class_p(mrb_value value);
MRB_API mrb_bool mrb_string_p(mrb_value value);
MRB_API mrb_value mrb_obj_value(void *pointer);
MRB_API struct RClass *mrb_class_ptr(mrb_value value);

#ifdef __cplusplus
}
#endif

#endif
