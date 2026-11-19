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
    text_offset_bytes: i64,
    text_length_bytes: i64,
}

// The process-wide symbol table. Names are appended once, so IDs stay stable
// across repeated parses and across separately loaded components. The bytes
// live in the C slab's 16 KB blocks; entries hold absolute block offsets.
root struct SymbolTable {
    entries: SymbolEntry[>..] = [],
}

// The result of parsing one or more RITE buffers. `records` is in pre-order: a
// parent precedes every descendant, and `first_child_index` /
// `next_sibling_index` link the children without any pointers. `roots` holds
// the absolute record index of each loaded program's root.
root struct RiteFile {
    data: const u8[:] = "",
    records: IrepRecord[>..] = [],
    pools: PoolEntry[>..] = [],
    syms: SymbolId[>..] = [],
    roots: i64[>..] = [],
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

// Read and mutation accessors for the flat RITE tables.
//
// Every parser and interpreter call site goes through these helpers so the
// backing storage can change without touching its consumers. Goose compiles the
// whole program into one translation unit at `-O2`, so these wrappers inline.

fn record_count(file: RiteFile&) -> i64 {
    return file.records.len;
}

fn record_at(file: RiteFile&, index: i64) -> IrepRecord {
    return file.records[index];
}

fn record_set_first_child(file: RiteFile&, index: i64, child_index: i64) {
    file.records[index].first_child_index = child_index;
}

fn record_set_next_sibling(file: RiteFile&, index: i64, sibling_index: i64) {
    file.records[index].next_sibling_index = sibling_index;
}

fn record_push(file: RiteFile&, record: IrepRecord) {
    file.records.push(record);
}

fn record_clear(file: RiteFile&) {
    file.records.clear();
}

fn record_truncate(file: RiteFile&, count: i64) {
    file.records.resize(count);
}

fn pool_count(file: RiteFile&) -> i64 {
    return file.pools.len;
}

fn pool_at(file: RiteFile&, index: i64) -> PoolEntry {
    return file.pools[index];
}

fn pool_push(file: RiteFile&, entry: PoolEntry) {
    file.pools.push(entry);
}

fn pool_clear(file: RiteFile&) {
    file.pools.clear();
}

fn pool_truncate(file: RiteFile&, count: i64) {
    file.pools.resize(count);
}

fn symbol_ref_count(file: RiteFile&) -> i64 {
    return file.syms.len;
}

fn symbol_ref_at(file: RiteFile&, index: i64) -> SymbolId {
    return file.syms[index];
}

fn symbol_ref_push(file: RiteFile&, reference: SymbolId) {
    file.syms.push(reference);
}

fn symbol_ref_clear(file: RiteFile&) {
    file.syms.clear();
}

fn symbol_ref_truncate(file: RiteFile&, count: i64) {
    file.syms.resize(count);
}

fn root_count(file: RiteFile&) -> i64 {
    return file.roots.len;
}

fn root_at(file: RiteFile&, index: i64) -> i64 {
    return file.roots[index];
}

fn root_push(file: RiteFile&, record_index: i64) {
    file.roots.push(record_index);
}

fn root_clear(file: RiteFile&) {
    file.roots.clear();
}

fn root_truncate(file: RiteFile&, count: i64) {
    file.roots.resize(count);
}

// Symbol table accessors. IDs index `entries`; each entry views the C slab's
// 16 KB string blocks without copying, and appending a name keeps existing IDs
// stable.

fn symbol_entry_at(index: u32) -> SymbolEntry {
    return g_symbol_table.entries[index];
}

fn symbol_entry_push(entry: SymbolEntry) {
    g_symbol_table.entries.push(entry);
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
    g_symbol_table.entries.resize(entries);
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
    return g_symbol_table.entries.len;
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
    for index in 0..symbol_count() {
        let entry = symbol_entry_at(index as u32);
        if entry.text_length_bytes == name.len {
            let start = entry.text_offset_bytes;
            let stop = start + entry.text_length_bytes;
            if compare(symbol_blob_slice(start, stop), name) == 0 {
                return index as u32, true;
            }
        }
    }
    let offset = slab_intern_bytes(name);
    if offset < 0 {
        return NULL_SYMBOL, false;
    }
    let id = symbol_count()as u32;
    symbol_entry_push(SymbolEntry {
            text_offset_bytes: offset,
            text_length_bytes: name.len,
        });
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
