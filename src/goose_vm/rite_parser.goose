// Zero-copy mruby 4.0 RITE0400 bytecode reader.
//
// The parser walks the binary once and records the offset and size of every
// IREP record in a flat tree. Instruction streams and literal strings are never
// copied out of the caller's buffer; the accessors in `rite_types.goose`
// return views of the original bytes. Every read is bounds-checked, so a
// truncated or corrupt buffer yields a structured `ParseError`.
namespace vm;

import.rite_bytes;
import.rite_pool;
import.rite_types;

// Which of the four legal top-level sections have been seen so far.
struct SectionState {
    found_irep: bool,
    found_dbg: bool,
    found_lvar: bool,
    saw_end: bool,
}

// The fixed part of one IREP record, before its literal pool and symbol table.
struct RecordHeader {
    record_offset_bytes: i64,
    record_size_bytes: u32,
    nlocals: u16,
    nregs: u16,
    child_count: u16,
    catch_count: u16,
    iseq_length_bytes: u32,
    iseq_offset_bytes: i64,
    catch_offset_bytes: i64,
}

// Parses the complete RITE buffer in `data` into `file`. Returns `Ok` and fills
// `file` on success; on failure the file may hold partial metadata, and the
// return value names the first structural problem encountered.
fn parse_rite(data: u8[:], file: RiteFile&) -> ParseError {
    file.data = data;
    file.records.clear();
    file.pools.clear();
    file.syms.clear();
    file.roots.clear();
    file.error = ParseError.Ok;
    file.binary_size_bytes = 0;
    file.irep_section_offset_bytes = 0;
    file.irep_section_size_bytes = 0;
    return parse_rite_window(data, file, 0, true);
}

// Appends one RITE program to a file whose record, pool and symbol arrays are
// already populated. `data_base` is the program's byte offset in `file.data`.
fn parse_rite_append(data: u8[:], file: RiteFile&, data_base: i64) -> ParseError {
    file.data = data;
    file.error = ParseError.Ok;
    return parse_rite_window(data, file, data_base, false);
}

fn parse_rite_window(
    data: u8[:], file: RiteFile&, data_base: i64, reset_size: bool
) -> ParseError {
    if data_base < 0 || data_base + RITE_HEADER_BYTES > data.len {
        return parse_rite_fail(file, ParseError.Truncated);
    }
    if !bytes_equal(data, data_base, RITE_MAGIC) {
        return parse_rite_fail(file, ParseError.BadMagic);
    }
    if !bytes_equal(data, data_base + 4, RITE_MAJOR_VERSION) ||
    !bytes_equal(data, data_base + 6, RITE_MINOR_VERSION) {
        return parse_rite_fail(file, ParseError.BadVersion);
    }

    let binary_size_raw, size_ok = read_u32(data, data_base + 8);
    if !size_ok {
        return parse_rite_fail(file, ParseError.Truncated);
    }
    let binary_size: i64 = binary_size_raw;
    if binary_size < MIN_RITE_BYTES || data_base + binary_size > data.len {
        return parse_rite_fail(file, ParseError.BadBinarySize);
    }
    if reset_size && binary_size != data.len {
        return parse_rite_fail(file, ParseError.BadBinarySize);
    }

    let root_index = file.records.len;
    let err = parse_rite_sections(data, data_base, data_base + binary_size, file);
    if err != ParseError.Ok {
        return parse_rite_fail(file, err);
    }
    if reset_size {
        file.binary_size_bytes = binary_size_raw;
    } else {
        file.binary_size_bytes += binary_size_raw;
    }
    file.roots.push(root_index);
    return ParseError.Ok;
}

// Walks the top-level sections. Exactly one IREP section must come first,
// followed by optional DBG and LVAR sections, and terminated by END.
fn parse_rite_sections(
    data: u8[:], start: i64, limit: i64, file: RiteFile&
) -> ParseError {
    var at = start + RITE_HEADER_BYTES;
    var state = SectionState {
        found_irep: false,
        found_dbg: false,
        found_lvar: false,
        saw_end: false,
    };

    while at < limit {
        if at + RITE_SECTION_HEADER_BYTES > limit {
            return ParseError.Truncated;
        }
        let section_size_raw, size_ok = read_u32(data, at + 4);
        if !size_ok {
            return ParseError.Truncated;
        }
        let section_size: i64 = section_size_raw;
        if section_size < RITE_SECTION_HEADER_BYTES || at + section_size > limit {
            return ParseError.BadSection;
        }
        let section_end = at + section_size;

        if bytes_equal(data, at, IREP_SECTION_IDENT) {
            let err = parse_rite_irep(data, at, section_size_raw, state, file);
            if err != ParseError.Ok {
                return err;
            }
        } else if bytes_equal(data, at, END_SECTION_IDENT) {
            if section_size != RITE_SECTION_HEADER_BYTES || section_end != limit {
                return ParseError.BadSection;
            }
            state.saw_end = true;
            at = section_end;
            break;
        } else if bytes_equal(data, at, DBG_SECTION_IDENT) {
            if !state.found_irep || state.found_dbg || state.found_lvar {
                return ParseError.BadSection;
            }
            state.found_dbg = true;
        } else if bytes_equal(data, at, LVAR_SECTION_IDENT) {
            if !state.found_irep || state.found_lvar {
                return ParseError.BadSection;
            }
            state.found_lvar = true;
        } else {
            return ParseError.BadSection;
        }
        at = section_end;
    }

    if !state.found_irep {
        return ParseError.MissingIrep;
    }
    if !state.saw_end {
        return ParseError.BadSection;
    }
    return ParseError.Ok;
}

// Validates and parses the only IREP section.
fn parse_rite_irep(
    data: u8[:],
    at: i64,
    section_size_raw: u32,
    state: SectionState&,
    file: RiteFile&,
) -> ParseError {
    if state.found_irep || state.found_dbg || state.found_lvar {
        return ParseError.BadSection;
    }
    let section_size: i64 = section_size_raw;
    if section_size < IREP_SECTION_HEADER_BYTES {
        return ParseError.BadSection;
    }
    if !bytes_equal(data, at + 8, RITE_VM_VERSION) {
        return ParseError.BadRiteVersion;
    }
    let limit = at + section_size;
    let err = parse_rite_irep_section(data, at + IREP_SECTION_HEADER_BYTES, limit, file);
    if err != ParseError.Ok {
        return err;
    }
    file.irep_section_offset_bytes = at;
    file.irep_section_size_bytes = section_size_raw;
    state.found_irep = true;
    return ParseError.Ok;
}

// Parses the record tree that fills exactly one IREP section.
fn parse_rite_irep_section(data: u8[:], at: i64, limit: i64, file: RiteFile&) -> ParseError {
    if at >= limit {
        return ParseError.Truncated;
    }
    let next, err = parse_record(data, at, limit, 0, -1, file);
    if err != ParseError.Ok {
        return err;
    }
    if next != limit {
        return ParseError.BadSection;
    }
    return ParseError.Ok;
}

// Parses one record and all of its descendants, returning the offset just past
// the subtree. `limit` is the end of the enclosing IREP section. The format is
// recursive by nature, so the depth is capped and every child must fit.
recursive fn parse_record(
    data: u8[:], at: i64, limit: i64, depth: u16, parent_index: i64, file: RiteFile&
) -> i64, ParseError {
    if depth > MAX_IREP_DEPTH {
        return 0, ParseError.TooDeep;
    }
    let header, record_end, header_err = parse_record_header(data, at, limit);
    if header_err != ParseError.Ok {
        return 0, header_err;
    }
    let record_index, body_err = parse_record_body(data, header, record_end, depth, parent_index, file);
    if body_err != ParseError.Ok {
        return 0, body_err;
    }

    var child_at = record_end;
    var previous_child: i64 = -1;
    for _ in header.child_count {
        if file.records.len >= MAX_IREP_RECORDS {
            return 0, ParseError.TooManyEntries;
        }
        let child_index = file.records.len;
        if previous_child < 0 {
            file.records[record_index].first_child_index = child_index;
        } else {
            file.records[previous_child].next_sibling_index = child_index;
        }
        let next_at, child_err = parse_record(data, child_at, limit, depth + 1, record_index, file);
        if child_err != ParseError.Ok {
            return 0, child_err;
        }
        child_at = next_at;
        previous_child = child_index;
    }
    return child_at, ParseError.Ok;
}

// Reads and validates the fixed header of one record.
fn parse_record_header(data: u8[:], at: i64, limit: i64) -> RecordHeader, i64, ParseError {
    if at + IREP_RECORD_HEADER_BYTES > limit {
        return empty_record_header(), 0, ParseError.Truncated;
    }
    let record_size_raw, size_ok = read_u32(data, at);
    if !size_ok {
        return empty_record_header(), 0, ParseError.Truncated;
    }
    let record_size: i64 = record_size_raw;
    let record_end = at + record_size;
    if record_size < IREP_RECORD_HEADER_BYTES || record_end > limit {
        return empty_record_header(), 0, ParseError.RecordSizeMismatch;
    }

    let nlocals, nlocals_ok = read_u16(data, at + 4);
    let nregs, nregs_ok = read_u16(data, at + 6);
    let child_count, children_ok = read_u16(data, at + 8);
    let catch_count, catch_ok = read_u16(data, at + 10);
    let iseq_length_raw, iseq_ok = read_u32(data, at + 12);
    if !nlocals_ok || !nregs_ok || !children_ok || !catch_ok || !iseq_ok {
        return empty_record_header(), 0, ParseError.Truncated;
    }
    if nlocals == 0 {
        return empty_record_header(), 0, ParseError.BadLocals;
    }

    let iseq_length: i64 = iseq_length_raw;
    let iseq_offset = at + IREP_RECORD_HEADER_BYTES;
    let catch_offset = iseq_offset + iseq_length;
    let catch_length = catch_count as i64 * IREP_CATCH_HANDLER_BYTES;
    if catch_offset + catch_length > record_end {
        return empty_record_header(), 0, ParseError.Truncated;
    }

    let header = RecordHeader {
        record_offset_bytes: at,
        record_size_bytes: record_size_raw,
        nlocals: nlocals,
        nregs: nregs,
        child_count: child_count,
        catch_count: catch_count,
        iseq_length_bytes: iseq_length_raw,
        iseq_offset_bytes: iseq_offset,
        catch_offset_bytes: catch_offset,
    };
    return header, record_end, ParseError.Ok;
}

// Parses a record's pool and symbols, then appends its flat record. Returns the
// index of the new record, whose children are parsed by the caller.
fn parse_record_body(
    data: u8[:], header: RecordHeader, record_end: i64, depth: u16, parent_index: i64,
    file: RiteFile&
) -> i64, ParseError {
    var cursor = header.catch_offset_bytes + header.catch_count as i64 * IREP_CATCH_HANDLER_BYTES;
    let pool_first = file.pools.len;
    let pool_at, pool_count, pool_err = parse_record_pool_block(data, cursor, record_end, file);
    if pool_err != ParseError.Ok {
        return 0, pool_err;
    }
    cursor = pool_at;

    let syms_first = file.syms.len;
    let syms_at, syms_count, syms_err = parse_record_symbol_block(data, cursor, record_end, file);
    if syms_err != ParseError.Ok {
        return 0, syms_err;
    }
    cursor = syms_at;

    // The record size covers this record's own bytes only. Children follow it
    // and each carries its own size, so this equality is a strong checksum.
    if cursor != record_end {
        return 0, ParseError.RecordSizeMismatch;
    }
    if file.records.len >= MAX_IREP_RECORDS {
        return 0, ParseError.TooManyEntries;
    }

    let record_index = file.records.len;
    file.records.push(IrepRecord {
            record_offset_bytes: header.record_offset_bytes,
            record_size_bytes: header.record_size_bytes,
            nlocals: header.nlocals,
            nregs: header.nregs,
            child_count: header.child_count,
            catch_count: header.catch_count,
            iseq_length_bytes: header.iseq_length_bytes,
            iseq_offset_bytes: header.iseq_offset_bytes,
            catch_offset_bytes: header.catch_offset_bytes,
            pool_first_index: pool_first,
            pool_count: pool_count,
            syms_first_index: syms_first,
            syms_count: syms_count,
            parent_index: parent_index,
            first_child_index: -1,
            next_sibling_index: -1,
            depth: depth,
        });
    return record_index, ParseError.Ok;
}

// Parses the u16 count and all literal pool entries of one record.
fn parse_record_pool_block(
    data: u8[:], at: i64, limit: i64, file: RiteFile&
) -> i64, u16, ParseError {
    if at + 2 > limit {
        return at, 0, ParseError.Truncated;
    }
    let count, count_ok = read_u16(data, at);
    if !count_ok {
        return at, 0, ParseError.Truncated;
    }
    var cursor = at + 2;
    for _ in count {
        if file.pools.len >= MAX_IREP_POOL_ENTRIES {
            return cursor, count, ParseError.TooManyEntries;
        }
        let entry, next, err = parse_pool_entry(data, cursor, limit);
        if err != ParseError.Ok {
            return cursor, count, err;
        }
        file.pools.push(entry);
        cursor = next;
    }
    return cursor, count, ParseError.Ok;
}

// Parses the u16 count and all symbol names of one record, interning each one.
fn parse_record_symbol_block(
    data: u8[:], at: i64, limit: i64, file: RiteFile&
) -> i64, u16, ParseError {
    if at + 2 > limit {
        return at, 0, ParseError.Truncated;
    }
    let count, count_ok = read_u16(data, at);
    if !count_ok {
        return at, 0, ParseError.Truncated;
    }
    var cursor = at + 2;
    for _ in count {
        if file.syms.len >= MAX_IREP_SYMBOL_ENTRIES ||
        g_symbol_table.entries.len >= MAX_SYMBOL_ENTRIES {
            return cursor, count, ParseError.TooManyEntries;
        }
        if cursor + 2 > limit {
            return cursor, count, ParseError.Truncated;
        }
        let length, length_ok = read_u16(data, cursor);
        if !length_ok {
            return cursor, count, ParseError.Truncated;
        }
        cursor += 2;
        if length == MRB_NULL_SYM_LENGTH {
            file.syms.push(SymbolId {
                    index: NULL_SYMBOL
                });
            continue;
        }
        let name_length: i64 = length;
        let name_end = cursor + name_length;
        if name_end + 1 > limit {
            return cursor, count, ParseError.Truncated;
        }
        if data[name_end] != 0 {
            return cursor, count, ParseError.MissingTerminator;
        }
        let id = intern_symbol(data[cursor..name_end]);
        file.syms.push(SymbolId {
                index: id
            });
        cursor = name_end + 1;
    }
    return cursor, count, ParseError.Ok;
}

// Marks `file` as failed and returns the same code.
fn parse_rite_fail(file: RiteFile&, err: ParseError) -> ParseError {
    file.error = err;
    return err;
}

// A default header used on the error path of `parse_record_header`.
fn empty_record_header() -> RecordHeader {
    return RecordHeader {
        record_offset_bytes: 0,
        record_size_bytes: 0,
        nlocals: 0,
        nregs: 0,
        child_count: 0,
        catch_count: 0,
        iseq_length_bytes: 0,
        iseq_offset_bytes: 0,
        catch_offset_bytes: 0,
    };
}
