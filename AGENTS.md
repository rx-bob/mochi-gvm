## Rules 
* Python is not allowed 
* Scripts are written in Goose too 
* src/ contains the source code 
* tests/ contains the test code 
* src and tests mirror their folder hierarchy 
* All goose code follows the references/GOOSE_STYLEGUIDE.md 
* We use goosefmt for formatting and linting 
* All our tests follow goosetest

## Payload Size & Codegen Guardrails
Keep `dist/mochi-gvm.wasm` and `dist/mochi-gvm.js` small when editing `scripts/build_wasm.goose`, `src/build/static_storage.goose`, `src/gvm/*.goose`, or `src/gvm/*.c`:

* **No Emscripten Virtual Filesystem (`FS` / `MEMFS`):** Do not pull in POSIX/stdio/poll/filesystem syscalls (`pause()`, `poll()`, `fopen()`, etc.) that force Emscripten's JS `FS`/`MEMFS`/`TTY`/`PATH` runtime into `dist/mochi-gvm.js` (~45+ KB). Build with `-sFILESYSTEM=0`, `-sMALLOC=emmalloc`, `-flto`, `--closure 1`, and `wasm-opt -Oz --converge`.
* **Avoid Goose Specialization Duplication:**
  * Pass `machine.pool` and `machine.scratch` through a `machine: Vm&` parameter (not `g_abi_pool`/`g_abi_scratch` globals or `g_abi_machine.pool`/`g_abi_machine.scratch` directly in `src/gvm/abi.goose`) so Goose does not emit a separate global-rooted specialization of `json_parse_*`, `promote_to_state_at`, `state_store_ivar_raw`, and `builtin_hash_*`.
  * Keep slice mutability consistent across callers of `vm_call_args` / `vm_exec_method` (do not mix `var` array slices `MrbValue[:]` with `let` array slices `const MrbValue[:]`, which duplicates `vm_exec_method` → `vm_exec_with_args` → `vm_exec_frame`).
  * Avoid calling `binding_json_append_value` (and `num_format_float`) with both local `u8[>..]` buffers and global `u8[>..]` buffers (format into a local `u8[>..]` and copy to the global buffer if needed).
* **Do Not Pull In Musl `vfprintf` / `fmt_fp`:** Never use `snprintf`, `vsnprintf`, or `fprintf` in C bridge code (`src/gvm/mochi_gvm_bridge.c`, etc.) or panic paths—even trivial `"%d"`/`"%s"` format strings link musl's full `printf_core` + `fmt_fp` + 128-bit float formatting (~8.5 KB), duplicating Goose's built-in formatters. Use small integer-to-ASCII helpers and `memcpy` instead.
* **No Wasm Exceptions or `setjmp`/`longjmp`:** Do not rely on `setjmp`/`longjmp` or C++ exceptions (or `-fwasm-exceptions -sSUPPORT_LONGJMP=wasm`); strip dead `gs_contain` `longjmp` branches in `src/build/static_storage.goose`.
* **Keep `.rodata` & Bounds Checks Lean:** Avoid embedding duplicate or pretty-printed JSON profiles in `.rodata` (`src/gvm/include/mochi_capacity_profile.h`), keep `GS_IDX` bounds checks free of per-file path strings (`gs_fileN`) so trap blocks merge, and strip unused POSIX `sigaction`/`mmap` region-init paths in `src/build/static_storage.goose`.
