/*
 * Subprocess helper for `scripts/build_wasm.goose`.
 *
 * Goose has no process API, so the build script's sidecar supplies one. It
 * also prepares the Emscripten environment: emcc needs a Python 3.10+ and its
 * bundled LLVM on PATH before the first command runs.
 */
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../src/gvm/include/mochi_capacity_profile.h"

typedef struct {
  const uint8_t *data;
  int64_t len;
} mochi_slice;

static int find_executable(const char *name, char *out, size_t capacity) {
  const char *path = getenv("PATH");
  char *copy;
  char *dir;
  char *save = NULL;
  if (!name || !path || !*path) return 0;
  copy = strdup(path);
  if (!copy) return 0;
  for (dir = strtok_r(copy, ":", &save); dir; dir = strtok_r(NULL, ":", &save)) {
    if (!*dir) continue;
    snprintf(out, capacity, "%s/%s", dir, name);
    if (access(out, X_OK) == 0) {
      free(copy);
      return 1;
    }
  }
  free(copy);
  return 0;
}

static void prepend_path(const char *directory) {
  const char *old = getenv("PATH");
  size_t length = strlen(directory) + (old ? strlen(old) : 0) + 2;
  char *next = (char *)malloc(length);
  if (!next) return;
  if (old && *old) {
    snprintf(next, length, "%s:%s", directory, old);
  } else {
    snprintf(next, length, "%s", directory);
  }
  setenv("PATH", next, 1);
  free(next);
}

static int python_ok(const char *path) {
  char command[PATH_MAX + 160];
  int status;
  if (strchr(path, '\'')) return 0;
  snprintf(command, sizeof(command),
           "'%s' -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) "
           "else 1)'",
           path);
  status = system(command);
  return status != -1 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* Finds emcc, puts its bundled LLVM on PATH, and points EMSDK_PYTHON at a
 * Python that emcc accepts. Returns 0 on success. */
int32_t mochi_prepare_toolchain(void) {
  static const char *PYTHONS[] = {"python3.14", "python3.13", "python3.12",
                                  "python3.11", "python3.10"};
  char emcc[PATH_MAX];
  char real[PATH_MAX];
  char root[PATH_MAX];
  char llvm[PATH_MAX];
  char python[PATH_MAX];
  const char *configured;
  size_t index;

  if (!find_executable("emcc", emcc, sizeof(emcc))) {
    fprintf(stderr, "build_wasm: emcc is not on PATH\n");
    return -1;
  }
  if (!realpath(emcc, real)) {
    fprintf(stderr, "build_wasm: cannot resolve %s\n", emcc);
    return -1;
  }
  /* <root>/bin/emcc -> <root>/libexec/llvm/bin. */
  snprintf(root, sizeof(root), "%s", real);
  {
    char *slash = strrchr(root, '/');
    if (slash) *slash = '\0';
    slash = strrchr(root, '/');
    if (slash) *slash = '\0';
  }
  snprintf(llvm, sizeof(llvm), "%s/libexec/llvm/bin", root);
  if (access(llvm, X_OK) == 0) prepend_path(llvm);

  configured = getenv("EMSDK_PYTHON");
  if (configured && *configured) return 0;
  for (index = 0; index < sizeof(PYTHONS) / sizeof(PYTHONS[0]); index++) {
    if (find_executable(PYTHONS[index], python, sizeof(python))) {
      setenv("EMSDK_PYTHON", python, 1);
      return 0;
    }
  }
  if (find_executable("python3", python, sizeof(python)) && python_ok(python)) {
    setenv("EMSDK_PYTHON", python, 1);
    return 0;
  }
  fprintf(stderr,
          "build_wasm: emcc needs python 3.10+; set EMSDK_PYTHON to one\n");
  return -1;
}

/* Writes the build's normalized capacity identity beside its paired runtime. */
int32_t mochi_write_capacity_profile(void) {
  FILE *file = fopen("dist/mochi-gvm.capacity.json", "wb");
  size_t length = strlen(MOCHI_CAPACITY_PROFILE_JSON);
  int32_t status = 0;
  if (!file) return -1;
  if (fwrite(MOCHI_CAPACITY_PROFILE_JSON, 1, length, file) != length) status = -1;
  if (fclose(file) != 0) status = -1;
  return status;
}

/* Runs one shell command. Returns its exit status, or -1 when it cannot
 * start. */
int32_t mochi_run(mochi_slice command) {
  char *text;
  int status;
  if (!command.data || command.len <= 0) return -1;
  text = (char *)malloc((size_t)command.len + 1);
  if (!text) return -1;
  memcpy(text, command.data, (size_t)command.len);
  text[command.len] = '\0';
  fflush(NULL);
  status = system(text);
  free(text);
  if (status == -1) return -1;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 128;
}
