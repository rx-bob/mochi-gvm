// Lower default-zero persistent storage initialization directly into its
// static destination. Goose v2026.4 otherwise zeroes a full bounded-array
// temporary on the small data stack before copying it to the global.
namespace static_storage;

import std;

fn joined(parts: const u8[:][:]) -> u8[>..] {
    var result: u8[>..] = [];
    for part in parts {
        result.append(part);
    }
    return result;
}

// Deliberately recognize only the complete zero/copy sequence. An upstream
// code-generation change must be reviewed, never partially rewritten.
fn lower(source: const u8[:], output: u8[>..]&) -> i64 {
    let body_start = find(source, "static void gs_init_globals(void) {");
    if body_start < 0 {
        return -1;
    }
    let body_end = find(source[body_start..], "\n}");
    if body_end < 0 {
        return -1;
    }
    let body = source[body_start..body_start + body_end];
    let lines = split(source, '\n');
    var inside = false;
    var changed = 0;
    var index = 0;
    while index < lines.len {
        let line = lines[index];
        if line == "static void gs_init_globals(void) {" {
            inside = true;
        }
        if inside && line == "}" {
            inside = false;
        }
        if inside && index + 4 < lines.len {
            let destination, value, assigned = split_once(trim(lines[index + 4]), " = ");
            if assigned && starts_with(destination, "GS_GL->gs_component_vm_g_abi_pool_")
                && starts_with(value, "(*") && ends_with(value, ");") {
                let temporary = value[2..value.len - 2];
                let reference = joined(["(*", temporary, ")"]);
                // Two references in MEMZERO, one length assignment and one
                // copy. Any additional use would need a real temporary.
                if split(body, reference[..]).len != 5 {
                    return -1;
                }
                let type_name, rest, declared = split_once(trim(line), " *");
                let declaration = joined([temporary, " = (", type_name, " *)"]);
                if !declared || !starts_with(rest, declaration[..]) || !ends_with(rest, ")->top;") {
                    return -1;
                }
                let stack_top = rest[declaration.len..rest.len - 1];
                if !starts_with(stack_top, "GS(0 + ") {
                    return -1;
                }
                let advance = joined([stack_top, " += sizeof(", type_name, ");"]);
                let clear = joined(["GS_MEMZERO(&(*", temporary, "), sizeof((*", temporary, ")));"]);
                let length = joined(["(*", temporary, ").len = 0;"]);
                if trim(lines[index + 1]) != advance[..]
                    || trim(lines[index + 2]) != clear[..]
                    || trim(lines[index + 3]) != length[..] {
                    return -1;
                }
                // Keep the saved watermark: later generated rewinds still
                // refer to it. No array temporary occupies the stack.
                output.append("    uint8_t *");
                output.append(temporary);
                output.append(" = ");
                output.append(stack_top);
                output.append(";\n    GS_MEMZERO(&");
                output.append(destination);
                output.append(", sizeof(");
                output.append(destination);
                output.append("));\n");
                changed += 1;
                index += 5;
                continue;
            }
        }
        output.append(line);
        if index + 1 < lines.len {
            output.push('\n');
        }
        index += 1;
    }
    return changed;
}

fn find_matching_brace_line(lines: const u8[:][:], start_index: i64) -> i64 {
    var index = start_index + 1;
    while index < lines.len {
        if lines[index] == "}" {
            return index;
        }
        index += 1;
    }
    return -1;
}

fn wasm_body_replacement(line: const u8[:]) -> const u8[:], bool {
    if line == "static GS_NORETURN void gs_fail(const void *msg, int64_t len, const char *file, int line) {" {
        return "    (void)msg; (void)len; (void)file; (void)line;\n    __builtin_trap();", true;
    }
    if line == "static GS_NORETURN void gs_failf(const char *file, int line, const char *fmt, ...) {" {
        return "    (void)file; (void)line; (void)fmt;\n    __builtin_trap();", true;
    }
    if line == "GS_API void gs_stack_stats(int64_t stacks) {" {
        return "    (void)stacks;", true;
    }
    if line == "static void gs_fault_handler(int sig, siginfo_t *info, void *ctx) {" {
        return "    (void)sig; (void)info; (void)ctx;\n    __builtin_trap();", true;
    }
    if line == "static void gs_regions_init(void) {" {
        return "    gs_page_size = gs_os_page_size();", true;
    }
    if line == "static void gs_native_stack_init(void) {"
        || line == "static void gs_native_stack_free(void) {"
        || line == "static void gs_fault_uninstall(void) {" {
        return "", true;
    }
    return "", false;
}

// Strip POSIX-only signal/stdio/setjmp runtime code and per-file bounds-check
// metadata from the generated C when targeting Wasm.
fn lower_wasm_runtime(source: const u8[:], output: u8[>..]&) -> bool {
    let lines = split(source, '\n');
    var index = 0;
    while index < lines.len {
        let line = lines[index];
        let body, matched_fn = wasm_body_replacement(line);
        if matched_fn {
            let end_index = find_matching_brace_line(lines, index);
            if end_index < 0 {
                return false;
            }
            output.append(line);
            output.push('\n');
            if body.len > 0 {
                output.append(body);
                output.push('\n');
            }
            output.append("}");
            if end_index + 1 < lines.len {
                output.push('\n');
            }
            index = end_index + 1;
            continue;
        }
        if line == "                                   : (gs_idxfail((int64_t)(i), (n), (f), (l)), (int64_t)0))" {
            output.append("                                   : (__builtin_trap(), (int64_t)0))");
        } else if line == "    fprintf(stderr, \"goose runtime error: %s\\n\", msg);" {
            output.append("    (void)msg; __builtin_trap();");
        } else if line == "    for (;;) pause();" {
            output.append("    __builtin_trap();");
        } else if line == "    setvbuf(stdout, NULL, _IONBF, 0);"
            || line == "    fflush(NULL);" {
            output.append("    /* stripped for wasm */");
        } else if starts_with(line, "static const char gs_file") {
            let eq_at = find(line, " = \"");
            if eq_at >= 0 {
                output.append(line[..eq_at]);
                output.append(" = \"\";");
            } else {
                output.append(line);
            }
        } else {
            output.append(line);
        }
        if index + 1 < lines.len {
            output.push('\n');
        }
        index += 1;
    }
    return true;
}
