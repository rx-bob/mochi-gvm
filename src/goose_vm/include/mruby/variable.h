#ifndef MRUBY_VARIABLE_H
#define MRUBY_VARIABLE_H

#include "mruby.h"

MRB_API mrb_value mrb_const_get(mrb_state *mrb, mrb_value mod, mrb_sym name);

#endif
