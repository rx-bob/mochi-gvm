// C-slab ownership for package bytecode and symbol string bytes.
namespace vm;

let SLAB_SYMBOL_BLOCK_BYTES = 16384;

extern fn mochi_slab_set_limit(limit: i64);

extern fn mochi_slab_used_bytes() -> i64;

extern fn mochi_slab_limit_bytes() -> i64;

extern fn mochi_slab_package_bytes_used() -> i64;

extern fn mochi_slab_package_count() -> i64;

extern fn mochi_slab_package_offset(id: i64) -> i64;

extern fn mochi_slab_push_package(bytes: const u8[:]) -> i64;

extern fn mochi_slab_truncate_packages(count: i64);

extern fn mochi_slab_intern_bytes(name: const u8[:]) -> i64;

extern fn mochi_slab_truncate_symbol_bytes(saved_offset: i64);

extern fn mochi_meta_new_file() -> i64;

extern fn mochi_meta_new_vm() -> i64;

extern fn mochi_meta_new_pool() -> i64;

extern fn mochi_meta_new_symbols() -> i64;

extern fn mochi_meta_count(handle: i64, slot: i64) -> i64;

// C publishes each region as one global view. A single view has an exact root,
// so slices of package bytes and symbol names stay borrow-safe.
var g_slab_package_view: const u8[:] = "";
var g_slab_symbol_view: const u8[:] = "";
var g_slab_symbol_blob_bytes: i64 = 0;

export fn goose_slab_attach_packages(bytes: const u8[:]) -> bool {
    g_slab_package_view = bytes;
    return true;
}

export fn goose_slab_attach_symbols(bytes: const u8[:]) -> bool {
    g_slab_symbol_view = bytes;
    return true;
}

fn slab_use_default_limit() {
    mochi_slab_set_limit(METADATA_MAX_BYTES);
}

fn slab_set_limit(limit: i64) {
    mochi_slab_set_limit(limit);
}

fn slab_used_bytes() -> i64 {
    return mochi_slab_used_bytes();
}

fn slab_limit_bytes() -> i64 {
    return mochi_slab_limit_bytes();
}

fn slab_package_bytes_used() -> i64 {
    return mochi_slab_package_bytes_used();
}

fn slab_package_count() -> i64 {
    return mochi_slab_package_count();
}

fn slab_push_package(bytes: const u8[:]) -> i64 {
    return mochi_slab_push_package(bytes);
}

fn slab_package_bytes(package_id: u32, offset: i64, length: i64) -> const u8[:] {
    let id = package_id as i64;
    let base = mochi_slab_package_offset(id);
    if base < 0 || offset < 0 || length < 0 {
        return "";
    }
    let start = base + offset;
    let stop = start + length;
    if stop > g_slab_package_view.len {
        return "";
    }
    return g_slab_package_view[start..stop];
}

fn slab_truncate_packages(count: i64) {
    var keep = count;
    if keep < 0 {
        keep = 0;
    }
    let total = mochi_slab_package_count();
    if keep > total {
        keep = total;
    }
    mochi_slab_truncate_packages(keep);
}

fn slab_intern_bytes(name: const u8[:]) -> i64 {
    let offset = mochi_slab_intern_bytes(name);
    if offset >= 0 && name.len > 0 {
        g_slab_symbol_blob_bytes = offset + name.len;
    }
    return offset;
}

fn slab_symbol_blob_length() -> i64 {
    return g_slab_symbol_blob_bytes;
}

fn slab_symbol_bytes(offset: i64, length: i64) -> const u8[:] {
    if offset < 0 || length <= 0 {
        return "";
    }
    let stop = offset + length;
    if stop > g_slab_symbol_view.len {
        return "";
    }
    return g_slab_symbol_view[offset..stop];
}

fn slab_truncate_symbol_bytes(saved_offset: i64) {
    var target = saved_offset;
    if target < 0 {
        target = 0;
    }
    if target > g_slab_symbol_blob_bytes {
        target = g_slab_symbol_blob_bytes;
    }
    mochi_slab_truncate_symbol_bytes(target);
    g_slab_symbol_blob_bytes = target;
}
