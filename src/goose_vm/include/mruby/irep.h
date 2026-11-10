#ifndef MRUBY_IREP_H
#define MRUBY_IREP_H

#include "mruby.h"

MRB_API mrb_value mrb_load_irep_buf(mrb_state *mrb, const void *bytes,
                                    size_t length);

#endif
