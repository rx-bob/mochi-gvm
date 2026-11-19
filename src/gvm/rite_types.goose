// Shared types and views for the mruby 4.0 RITE0400 reader.
//
// Records are flat: the tree is addressed by indexes and byte offsets, never
// pointers. The symbol table is the one process-wide copy of every interned
// name, so a VM can compare compact u32 handles instead of text.
namespace vm;

import std;

import.slab;

let RITE_HEADER_BYTES = 20;
let RITE_SECTION_HEADER_BYTES = 8;
let IREP_SECTION_HEADER_BYTES = 12;
let IREP_RECORD_HEADER_BYTES = 16;
let IREP_CATCH_HANDLER_BYTES = 13;
let MIN_RITE_BYTES = 20;
let MAX_IREP_DEPTH = 32;
// These tables accumulate across every IREP appended to the runtime, not per
// file. A lazily loaded single-page application can span hundreds of packages,
// so the bounds leave room for the whole application rather than one bundle.
let MAX_IREP_RECORDS = 16384;
let MAX_IREP_POOL_ENTRIES = 16384;
let MAX_IREP_SYMBOL_ENTRIES = 16384;
let MAX_SYMBOL_ENTRIES = 16384;
let NULL_SYMBOL: u32 = 0xFFFFFFFF;
let NO_PACKAGE_ID: u32 = 0xFFFFFFFF;
let MRB_NULL_SYM_LENGTH = 0xFFFF;

let RITE_MAGIC: const u8[:] = "RITE";
let RITE_MAJOR_VERSION: const u8[:] = "04";
let RITE_MINOR_VERSION: const u8[:] = "00";
let RITE_VM_VERSION: const u8[:] = "0400";
let IREP_SECTION_IDENT: const u8[:] = "IREP";
let DBG_SECTION_IDENT: const u8[:] = "DBG\0";
let LVAR_SECTION_IDENT: const u8[:] = "LVAR";
let END_SECTION_IDENT: const u8[:] = "END\0";

// A rejection reason for a malformed or truncated RITE buffer. Parser entry
// points return the same value they store in `RiteFile.error`.
enum ParseError {
    Ok,
    Truncated,
    BadMagic,
    BadVersion,
    BadBinarySize,
    MissingIrep,
    BadSection,
    BadRiteVersion,
    RecordSizeMismatch,
    BadPoolTag,
    MissingTerminator,
    BadLocals,
    TooDeep,
    TooManyEntries,
}

// The append-only table that rejected a package for capacity. The ABI layer
// maps these to `CapacityResource` so parser failures report the same named
// resource and counts as runtime allocation failures.
enum ParseResource {
    None,
    IrepRecords,
    IrepPools,
    IrepSymbols,
    SymbolTable,
}

// One parsed IREP record. Every field is a scalar: the record is flat, has no
// pointer graph, and addresses the payload only through offsets into the input.
struct IrepRecord {
    record_offset_bytes: i64,
    record_size_bytes: u32,
    nlocals: u16,
    nregs: u16,
    child_count: u16,
    catch_count: u16,
    iseq_length_bytes: u32,
    iseq_offset_bytes: i64,
    catch_offset_bytes: i64,
    pool_first_index: i64,
    pool_count: u16,
    syms_first_index: i64,
    syms_count: u16,
    parent_index: i64,
    first_child_index: i64,
    next_sibling_index: i64,
    depth: u16,
    package_id: u32 = NO_PACKAGE_ID,
}

// One literal pool entry. `text_offset_bytes` and `text_length_bytes` view a
// string inside the input; `int_value` and `float_value` hold scalar literals.
struct PoolEntry {
    tag: u8,
    text_offset_bytes: i64,
    text_length_bytes: i64,
    int_value: i64,
    float_value: f64,
    package_id: u32 = NO_PACKAGE_ID,
}

// A compact symbol handle. `NULL_SYMBOL` marks an entry that mruby dumped as
// a null symbol; every other value indexes `SymbolTable.entries`.
struct SymbolId {
    index: u32,
}

// One interned symbol name that views the shared symbol byte buffer.
struct SymbolEntry {
    next_in_bucket: i32 = -1,
    hash: u32 = 0,
    text_offset_bytes: i64,
    text_length_bytes: i64,
}

// The process-wide symbol table. Names are appended once, so IDs stay stable
// across repeated parses and across separately loaded components. The bytes
// live in the C slab's 16 KB blocks; entries hold absolute block offsets.
root struct SymbolTable {
    metadata_handle: i64 = -1,
}

// The result of parsing one or more RITE buffers. `records` is in pre-order: a
// parent precedes every descendant, and `first_child_index` /
// `next_sibling_index` link the children without any pointers. `roots` holds
// the absolute record index of each loaded program's root. The tables live in
// C slab chunks and are reached only through the accessors below.
root struct RiteFile {
    data: const u8[:] = "",
    metadata_handle: i64 = -1,
    error: ParseError = ParseError.Ok,
    error_resource: ParseResource = ParseResource.None,
    error_requested: i64 = 0,
    error_used: i64 = 0,
    error_capacity: i64 = 0,
    binary_size_bytes: u32 = 0,
    irep_section_offset_bytes: i64 = 0,
    irep_section_size_bytes: u32 = 0,
    current_package_id: u32 = NO_PACKAGE_ID,
}

var g_symbol_table = SymbolTable {
    ..
};

// Read and mutation accessors for the segmented RITE tables.
//
// Every parser and interpreter call site goes through these helpers so the
// backing storage can change without touching its consumers. Each owner has a
// C table-set handle; the first accessor call allocates it lazily, so a fresh
// `RiteFile` cannot alias a previous test or VM's chunks.

extern fn mochi_meta_record_at(handle: i64, index: i64) -> IrepRecord;

extern fn mochi_meta_record_push(handle: i64, record: IrepRecord) -> bool;

extern fn mochi_meta_record_truncate(handle: i64, count: i64);

extern fn mochi_meta_record_set_first_child(
    handle: i64, index: i64, child_index: i64
);

extern fn mochi_meta_record_set_next_sibling(
    handle: i64, index: i64, sibling_index: i64
);

extern fn mochi_meta_pool_at(handle: i64, index: i64) -> PoolEntry;

extern fn mochi_meta_pool_push(handle: i64, entry: PoolEntry) -> bool;

extern fn mochi_meta_pool_truncate(handle: i64, count: i64);

extern fn mochi_meta_symbol_ref_at(handle: i64, index: i64) -> SymbolId;

extern fn mochi_meta_symbol_ref_push(handle: i64, reference: SymbolId) -> bool;

extern fn mochi_meta_symbol_ref_truncate(handle: i64, count: i64);

extern fn mochi_meta_root_at(handle: i64, index: i64) -> i64;

extern fn mochi_meta_root_push(handle: i64, record_index: i64) -> bool;

extern fn mochi_meta_root_truncate(handle: i64, count: i64);

fn file_metadata(file: RiteFile&) -> i64 {
    if file.metadata_handle < 0 {
        file.metadata_handle = mochi_meta_new_file();
    }
    return file.metadata_handle;
}

fn record_count(file: RiteFile&) -> i64 {
    return mochi_meta_count(file_metadata(file), 0);
}

fn record_at(file: RiteFile&, index: i64) -> IrepRecord {
    return mochi_meta_record_at(file_metadata(file), index);
}

fn record_set_first_child(file: RiteFile&, index: i64, child_index: i64) {
    mochi_meta_record_set_first_child(file_metadata(file), index, child_index);
}

fn record_set_next_sibling(file: RiteFile&, index: i64, sibling_index: i64) {
    mochi_meta_record_set_next_sibling(file_metadata(file), index, sibling_index);
}

fn record_push(file: RiteFile&, record: IrepRecord) -> bool {
    return mochi_meta_record_push(file_metadata(file), record);
}

fn record_clear(file: RiteFile&) {
    mochi_meta_record_truncate(file_metadata(file), 0);
}

fn record_truncate(file: RiteFile&, count: i64) {
    mochi_meta_record_truncate(file_metadata(file), count);
}

fn pool_count(file: RiteFile&) -> i64 {
    return mochi_meta_count(file_metadata(file), 1);
}

fn pool_at(file: RiteFile&, index: i64) -> PoolEntry {
    return mochi_meta_pool_at(file_metadata(file), index);
}

fn pool_push(file: RiteFile&, entry: PoolEntry) -> bool {
    return mochi_meta_pool_push(file_metadata(file), entry);
}

fn pool_clear(file: RiteFile&) {
    mochi_meta_pool_truncate(file_metadata(file), 0);
}

fn pool_truncate(file: RiteFile&, count: i64) {
    mochi_meta_pool_truncate(file_metadata(file), count);
}

fn symbol_ref_count(file: RiteFile&) -> i64 {
    return mochi_meta_count(file_metadata(file), 2);
}

fn symbol_ref_at(file: RiteFile&, index: i64) -> SymbolId {
    return mochi_meta_symbol_ref_at(file_metadata(file), index);
}

fn symbol_ref_push(file: RiteFile&, reference: SymbolId) -> bool {
    return mochi_meta_symbol_ref_push(file_metadata(file), reference);
}

fn symbol_ref_clear(file: RiteFile&) {
    mochi_meta_symbol_ref_truncate(file_metadata(file), 0);
}

fn symbol_ref_truncate(file: RiteFile&, count: i64) {
    mochi_meta_symbol_ref_truncate(file_metadata(file), count);
}

fn root_count(file: RiteFile&) -> i64 {
    return mochi_meta_count(file_metadata(file), 3);
}

fn root_at(file: RiteFile&, index: i64) -> i64 {
    return mochi_meta_root_at(file_metadata(file), index);
}

fn root_push(file: RiteFile&, record_index: i64) -> bool {
    return mochi_meta_root_push(file_metadata(file), record_index);
}

fn root_clear(file: RiteFile&) {
    mochi_meta_root_truncate(file_metadata(file), 0);
}

fn root_truncate(file: RiteFile&, count: i64) {
    mochi_meta_root_truncate(file_metadata(file), count);
}

// Symbol table accessors. IDs index C chunks; each entry views the C slab's
// 16 KB string blocks without copying, and appending a name keeps existing IDs
// stable.

extern fn mochi_meta_symbol_at(handle: i64, index: i64) -> SymbolEntry;

extern fn mochi_meta_symbol_find(handle: i64, name: const u8[:]) -> i64;

extern fn mochi_meta_symbol_push(handle: i64, entry: SymbolEntry) -> bool;

extern fn mochi_meta_symbol_truncate(handle: i64, count: i64);

fn symbol_metadata() -> i64 {
    if g_symbol_table.metadata_handle < 0 {
        g_symbol_table.metadata_handle = mochi_meta_new_symbols();
    }
    return g_symbol_table.metadata_handle;
}

fn symbol_entry_at(index: u32) -> SymbolEntry {
    return mochi_meta_symbol_at(symbol_metadata(), index);
}

fn symbol_entry_push(entry: SymbolEntry) -> bool {
    return mochi_meta_symbol_push(symbol_metadata(), entry);
}

fn symbol_blob_length() -> i64 {
    return slab_symbol_blob_length();
}

fn symbol_blob_slice(start: i64, stop: i64) -> const u8[:] {
    if start < 0 || stop <= start {
        return "";
    }
    if stop > g_slab_symbol_view.len {
        return "";
    }
    return g_slab_symbol_view[start..stop];
}

fn symbol_table_truncate(entries: i64, blob_length: i64) {
    mochi_meta_symbol_truncate(symbol_metadata(), entries);
    slab_truncate_symbol_bytes(blob_length);
}

// Returns a human-readable name for a parse result.
fn parse_error_name(err: ParseError) -> u8[:] {
    return match err {
        Ok => "ok",
        Truncated => "truncated",
        BadMagic => "bad RITE magic",
        BadVersion => "unsupported RITE version",
        BadBinarySize => "bad binary size",
        MissingIrep => "missing IREP section",
        BadSection => "bad section framing",
        BadRiteVersion => "unsupported IREP version",
        RecordSizeMismatch => "record size mismatch",
        BadPoolTag => "bad literal pool tag",
        MissingTerminator => "missing NUL terminator",
        BadLocals => "record has no locals",
        TooDeep => "IREP nesting too deep",
        TooManyEntries => "IREP entry limit exceeded",
    };
}

// Returns the interned name of a symbol, or an empty view for a null symbol.
fn symbol_name(id: u32) -> const u8[:] {
    if id == NULL_SYMBOL || id >= symbol_count()as u32 {
        return "";
    }
    let entry = symbol_entry_at(id);
    let start = entry.text_offset_bytes;
    let stop = start + entry.text_length_bytes;
    return symbol_blob_slice(start, stop);
}

// Returns the number of interned names.
fn symbol_count() -> i64 {
    return mochi_meta_count(symbol_metadata(), 0);
}

// Returns the ID of `name`, appending it once when the table has no equal name.
fn intern_symbol(name: u8[:]) -> u32 {
    let id, ok = intern_symbol_checked(name);
    if !ok {
        return NULL_SYMBOL;
    }
    return id;
}

// Interning variant for callers that must distinguish a slab rejection from
// `NULL_SYMBOL`. A failed call leaves the table unchanged.
fn intern_symbol_checked(name: u8[:]) -> u32, bool {
    let found = mochi_meta_symbol_find(symbol_metadata(), name);
    if found >= 0 {
        return found as u32, true;
    }
    let saved_blob = slab_symbol_blob_length();
    let offset = slab_intern_bytes(name);
    if offset < 0 {
        return NULL_SYMBOL, false;
    }
    let id = symbol_count()as u32;
    if !symbol_entry_push(SymbolEntry {
            text_offset_bytes: offset,
            text_length_bytes: name.len,
        }) {
        slab_truncate_symbol_bytes(saved_blob);
        return NULL_SYMBOL,
        false;
    }
    return id, true;
}

// Returns the bytes for `entry` from its owning package or the standalone parse
// buffer. Package views live in immutable C slab allocations.
fn pool_bytes(file: RiteFile&, entry: PoolEntry) -> const u8[:] {
    let start = entry.text_offset_bytes;
    let stop = start + entry.text_length_bytes;
    if entry.package_id == NO_PACKAGE_ID {
        if start < 0 || stop < start || stop > file.data.len {
            return "";
        }
        return file.data[start..stop];
    }
    return slab_package_bytes(entry.package_id, start, stop - start);
}

// Returns the instruction bytes of `record` as a view of its parsed buffer.
fn record_iseq(file: RiteFile&, record: IrepRecord) -> const u8[:] {
    let start = record.iseq_offset_bytes;
    let stop = start + record.iseq_length_bytes;
    if record.package_id == NO_PACKAGE_ID {
        return file.data[start..stop];
    }
    return slab_package_bytes(record.package_id, start, stop - start);
}

// Returns the text of a string pool entry as a view of its parsed buffer.
fn pool_text(file: RiteFile&, entry: PoolEntry) -> const u8[:] {
    if entry.tag != 0 {
        return "";
    }
    return pool_bytes(file, entry);
}

// Returns the first child of `record`, or -1 when it has none.
fn first_child(record: IrepRecord) -> i64 {
    return record.first_child_index;
}

// Returns the next sibling of `record`, or -1 at the end of its sibling list.
fn next_sibling(record: IrepRecord) -> i64 {
    return record.next_sibling_index;
}
