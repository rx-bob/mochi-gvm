// Shared types and views for the mruby 4.0 RITE0400 reader.
//
// Records are flat: the tree is addressed by indexes and byte offsets, never
// pointers. The symbol table is the one process-wide copy of every interned
// name, so a VM can compare compact u32 handles instead of text.
namespace vm;

import std;

let RITE_HEADER_BYTES = 20;
let RITE_SECTION_HEADER_BYTES = 8;
let IREP_SECTION_HEADER_BYTES = 12;
let IREP_RECORD_HEADER_BYTES = 16;
let IREP_CATCH_HANDLER_BYTES = 13;
let MIN_RITE_BYTES = 20;
let MAX_IREP_DEPTH = 32;
let MAX_IREP_RECORDS = 4096;
let MAX_IREP_POOL_ENTRIES = 4096;
let MAX_IREP_SYMBOL_ENTRIES = 4096;
let MAX_SYMBOL_ENTRIES = 4096;
let NULL_SYMBOL: u32 = 0xFFFFFFFF;
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
}

// One literal pool entry. `text_offset_bytes` and `text_length_bytes` view a
// string inside the input; `int_value` and `float_value` hold scalar literals.
struct PoolEntry {
    tag: u8,
    text_offset_bytes: i64,
    text_length_bytes: i64,
    int_value: i64,
    float_value: f64,
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
// across repeated parses and across separately loaded components.
root struct SymbolTable {
    blob: u8[>..] = [],
    entries: SymbolEntry[>..] = [],
}

// The result of parsing one RITE buffer. `records` is in pre-order: a parent
// precedes every descendant, and `first_child_index` / `next_sibling_index`
// link the children without any pointers.
root struct RiteFile {
    data: const u8[:] = "",
    records: IrepRecord[>..] = [],
    pools: PoolEntry[>..] = [],
    syms: SymbolId[>..] = [],
    error: ParseError = ParseError.Ok,
    binary_size_bytes: u32 = 0,
    irep_section_offset_bytes: i64 = 0,
    irep_section_size_bytes: u32 = 0,
}

var g_symbol_table = SymbolTable {
    ..
};

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
    if id == NULL_SYMBOL || id >= g_symbol_table.entries.len as u32 {
        return "";
    }
    let entry = g_symbol_table.entries[id];
    let start = entry.text_offset_bytes;
    let stop = start + entry.text_length_bytes;
    return g_symbol_table.blob[start..stop];
}

// Returns the number of interned names.
fn symbol_count() -> i64 {
    return g_symbol_table.entries.len;
}

// Returns the ID of `name`, appending it once when the table has no equal name.
fn intern_symbol(name: u8[:]) -> u32 {
    for index in 0..g_symbol_table.entries.len {
        let entry = g_symbol_table.entries[index];
        if entry.text_length_bytes == name.len {
            let start = entry.text_offset_bytes;
            let stop = start + entry.text_length_bytes;
            if compare(g_symbol_table.blob[start..stop], name) == 0 {
                return index as u32;
            }
        }
    }
    let offset = g_symbol_table.blob.len;
    let id = g_symbol_table.entries.len as u32;
    g_symbol_table.blob.append(name);
    g_symbol_table.entries.push(SymbolEntry {
            text_offset_bytes: offset,
            text_length_bytes: name.len,
        });
    return id;
}

// Returns the instruction bytes of `record` as a view of the parsed buffer.
fn record_iseq(file: RiteFile&, record: IrepRecord) -> const u8[:] {
    let start = record.iseq_offset_bytes;
    let stop = start + record.iseq_length_bytes;
    return file.data[start..stop];
}

// Returns the text of a string pool entry as a view of the parsed buffer.
fn pool_text(file: RiteFile&, entry: PoolEntry) -> const u8[:] {
    if entry.tag != 0 {
        return "";
    }
    let start = entry.text_offset_bytes;
    let stop = start + entry.text_length_bytes;
    return file.data[start..stop];
}

// Returns the first child of `record`, or -1 when it has none.
fn first_child(record: IrepRecord) -> i64 {
    return record.first_child_index;
}

// Returns the next sibling of `record`, or -1 at the end of its sibling list.
fn next_sibling(record: IrepRecord) -> i64 {
    return record.next_sibling_index;
}
