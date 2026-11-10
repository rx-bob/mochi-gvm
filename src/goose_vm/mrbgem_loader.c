/*
 * Lightweight mrbgem registration for the Goose ABI host.
 *
 * A gem entry may provide a C init function, a compiled `mrblib` RITE byte
 * array, or both. C init runs first so Ruby helpers can call methods that the
 * C side registers. The table is deliberately static: the host build chooses
 * which gems exist at compile time.
 */
#include <mruby.h>
#include <mruby/irep.h>

#include <stddef.h>

typedef void (*mochi_mrbgem_init)(mrb_state *mrb);

typedef struct {
  const char *name;
  const uint8_t *irep;
  mochi_mrbgem_init init;
} mochi_mrbgem;

#ifdef MOCHI_ABI_SAMPLE_GEM
extern const uint8_t sample_gem_mrblib[];
extern void mrb_sample_gem_init(mrb_state *mrb);
#endif

static const mochi_mrbgem g_mrbgems[] = {
#ifdef MOCHI_ABI_SAMPLE_GEM
    {"sample_gem", sample_gem_mrblib, mrb_sample_gem_init},
#endif
    {NULL, NULL, NULL},
};

#define MOCHI_MRBGEM_COUNT \
  ((sizeof(g_mrbgems) / sizeof(g_mrbgems[0])) - 1u)

void mochi_mrbgem_load_all(mrb_state *mrb) {
  size_t index;

  if (!mrb) return;
  for (index = 0; index < MOCHI_MRBGEM_COUNT; index++) {
    const mochi_mrbgem *gem = &g_mrbgems[index];
    if (gem->init) {
      gem->init(mrb);
      if (mrb->exc) return;
    }
    if (gem->irep) {
      mrb_load_irep(mrb, gem->irep);
      if (mrb->exc) return;
    }
  }
}
