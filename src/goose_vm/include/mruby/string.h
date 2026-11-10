#ifndef MRUBY_STRING_H
#define MRUBY_STRING_H

#include "mruby.h"

#define RSTRING_PTR(value) mrb_string_ptr(value)
#define RSTRING_LEN(value) mrb_string_len(value)

MRB_API const char *mrb_string_ptr(mrb_value value);
MRB_API mrb_int mrb_string_len(mrb_value value);
MRB_API mrb_value mrb_str_new(mrb_state *mrb, const char *data, mrb_int len);
MRB_API const char *mrb_str_to_cstr(mrb_state *mrb, mrb_value value);

#endif
