/*
 * 32-bit host acceptance test for the opaque mruby ABI.
 *
 * `mochi_bridge.c` stores pointers in `int`, so this test must run in a
 * 32-bit process. Generate the Goose C and header with:
 *
 *   goose --standalone --header abi.h -o abi.c <entry importing src/goose_vm>
 *
 * Then compile this file with `mrb_abi_shim.c` (and
 * `-DMOCHI_ABI_OWNS_GOOSE_LIFECYCLE`), the generated `abi.c`, and
 * `poc_yiseq/mochi_bridge.c` (with `-Dmain=mochi_bridge_sidecar_main`).
 */
#include "abi.h"

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int mochi_init_runtime(void);
extern int mochi_load_iseq(int ptr, int len);
extern int mochi_hydrate_component(int id_ptr, int class_ptr, int state_ptr);
extern int mochi_render(int id_ptr);
extern int mochi_render_buffer_offset(void);
extern int mochi_write_event(int line_ptr);
extern int mochi_process_events(void);
extern int mochi_fetch_outbox_offset(void);
extern int mochi_fetch_outbox_len(void);

static const char EXPECTED_HTML[] =
    "<div class='counter'><h2>Click me</h2><span class='count'>1</span>"
    "<div class='buttons'><button data-action='decrement'>-</button>"
    "<button data-action='increment'>+</button>"
    "<button data-action='reset'>Reset</button></div></div>";
static const char FETCH_LINE[] = "1|counter|handler|https://example.test/data\n";

static void fail(const char *what, int got) {
  fprintf(stderr, "FAIL %s: %d\n", what, got);
  exit(1);
}

static mrb_value host_ping(mrb_state *mrb, mrb_value self) {
  (void)mrb;
  (void)self;
  return mrb_fixnum_value(7);
}

static unsigned char *read_file(const char *path, long *size) {
  FILE *file = fopen(path, "rb");
  unsigned char *bytes;
  if (!file) fail("open counter.chi", -1);
  if (fseek(file, 0, SEEK_END) != 0) fail("seek", -1);
  *size = ftell(file);
  if (*size <= 0) fail("size", (int)*size);
  if (fseek(file, 0, SEEK_SET) != 0) fail("rewind", -1);
  bytes = (unsigned char *)malloc((size_t)*size);
  if (!bytes) fail("malloc chi", -1);
  if (fread(bytes, 1, (size_t)*size, file) != (size_t)*size) fail("read chi", -1);
  fclose(file);
  return bytes;
}

int main(void) {
  long size = 0;
  unsigned char *chi = read_file("counter.chi", &size);
  int slot;
  int rendered;
  int events;
  mrb_state *mrb;
  struct RClass *host_class;
  mrb_value mochi;
  mrb_value component;
  mrb_value url;
  mrb_value callback;
  mrb_value host_object;
  mrb_value ping;
  const char *outbox;
  const char *html;

  if (mochi_init_runtime() != 0) fail("mochi_init_runtime", -1);

  mrb = mrb_open();
  if (!mrb) fail("mrb_open", -1);
  mochi = mrb_const_get(mrb, mrb_obj_value(mrb->object_class),
                        mrb_intern_cstr(mrb, "Mochi"));
  component = mrb_str_new(mrb, "counter", 7);
  url = mrb_str_new(mrb, "https://example.test/data", 25);
  callback = mrb_str_new(mrb, "handler", 7);
  mrb_funcall(mrb, mochi, "fetch", 3, component, url, callback);
  if (mrb->exc) fail("mochi fetch raised", -1);
  outbox = (const char *)(intptr_t)mochi_fetch_outbox_offset();
  if (mochi_fetch_outbox_len() != (int)strlen(FETCH_LINE)) {
    fail("fetch length", mochi_fetch_outbox_len());
  }
  if (memcmp(outbox, FETCH_LINE, strlen(FETCH_LINE)) != 0) fail("fetch payload", -1);

  if (mochi_load_iseq((int)(intptr_t)chi, (int)size) != 0) fail("mochi_load_iseq", -1);
  slot = mochi_hydrate_component((int)(intptr_t)"counter",
                                 (int)(intptr_t)"Counter", 0);
  if (slot != 0) fail("mochi_hydrate_component", slot);
  events = mochi_write_event((int)(intptr_t)"counter|click|increment");
  if (events != (int)strlen("counter|click|increment")) fail("write event", events);
  if (mochi_process_events() != 1) fail("process events", -1);
  rendered = mochi_render((int)(intptr_t)"counter");
  if (rendered != (int)strlen(EXPECTED_HTML)) fail("render length", rendered);
  html = (const char *)(intptr_t)mochi_render_buffer_offset();
  if (memcmp(html, EXPECTED_HTML, strlen(EXPECTED_HTML)) != 0) fail("render html", -1);

  host_class = mrb_define_class(mrb, "HostBase", mrb->object_class);
  if (!host_class) fail("mrb_define_class", -1);
  mrb_define_method(mrb, host_class, "ping", host_ping, MRB_ARGS_NONE());
  host_object = mrb_obj_new(mrb, host_class, 0, NULL);
  if (mrb->exc) fail("mrb_obj_new", -1);
  ping = mrb_funcall(mrb, host_object, "ping", 0);
  if (mrb->exc) fail("host method raised", -1);
  if (mrb_fixnum(ping) != 7) fail("host method result", (int)mrb_fixnum(ping));

  mrb_close(mrb);
  goose_exit();
  free(chi);
  printf("abi bridge ok: fetch, load, hydrate, render, host class/method (%d bytes)\n",
         rendered);
  return 0;
}
