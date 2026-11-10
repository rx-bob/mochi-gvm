// RITE0400 parser tests.
//
// The three fixtures are the stripped component payloads shipped by poc_yiseq:
// each lost its first ten bytes at build time, so the tests restore the
// `RITE0400\0\0` prefix before parsing. Shape assertions pin the values that
// `mrbc -v` reports, and the synthetic buffers cover every rejection path.
//
// The comparison helpers return bool instead of asserting: goosetest's
// assertions use a non-local return, which is only valid directly in a test
// case, not inside a helper function.
namespace vm_rite_parser_test;

import std;

import goosetest;
import vm;

let RITE_PREFIX: const u8[:] = "RITE0400\x00\x00";
let COUNTER_CHI: const u8[:] = embed_file("../fixtures/counter.chi");
let TODO_CHI: const u8[:] = embed_file("../fixtures/todo.chi");
let USERS_CHI: const u8[:] = embed_file("../fixtures/users.chi");

// The recorded shape of one IREP, matching one row of `mrbc -v`.
struct RecordShape {
    nlocals: u16,
    nregs: u16,
    child_count: u16,
    iseq_length_bytes: u32,
    pool_count: u16,
    syms_count: u16,
}

// Inputs for building a synthetic record in the tests below.
struct RecordParts {
    iseq: const u8[:],
    pool: const u8[:],
    syms: const u8[:],
    pool_count: u16,
    sym_count: u16,
    child_count: u16,
}

fn record_shape_matches(file: vm::RiteFile&, index: i64, expected: RecordShape) -> bool {
    let record = file.records[index];
    return record.nlocals == expected.nlocals
        && record.nregs == expected.nregs
        && record.child_count == expected.child_count
        && record.iseq_length_bytes == expected.iseq_length_bytes
        && record.pool_count == expected.pool_count
        && record.syms_count == expected.syms_count
        && vm::record_iseq(file, record).len == expected.iseq_length_bytes;
}

fn record_shape(
    nlocals: u16, nregs: u16, child_count: u16, iseq_length_bytes: u32, pool_count: u16,
    syms_count: u16
) -> RecordShape {
    return RecordShape {
        nlocals: nlocals,
        nregs: nregs,
        child_count: child_count,
        iseq_length_bytes: iseq_length_bytes,
        pool_count: pool_count,
        syms_count: syms_count,
    };
}

fn symbol_is(
    file: vm::RiteFile&, record_index: i64, symbol_index: i64, expected: u8[:]
) -> bool {
    let record = file.records[record_index];
    let symbol = file.syms[record.syms_first_index + symbol_index];
    return vm::symbol_name(symbol.index) == expected;
}

fn pool_is(file: vm::RiteFile&, record_index: i64, pool_index: i64, expected: u8[:]) -> bool {
    let record = file.records[record_index];
    let entry = file.pools[record.pool_first_index + pool_index];
    return entry.tag == 0 && vm::pool_text(file, entry) == expected;
}

fn test_counter_parses_structure_and_literals(t: goosetest::Test&) {
    var bytes: u8[>..] = [];
    bytes.append(RITE_PREFIX);
    bytes.append(COUNTER_CHI);
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let err = vm::parse_rite(bytes[..], file);

    t.assert_eq(vm::ParseError.Ok, err);
    t.assert_eq(751, file.binary_size_bytes);
    t.assert_eq(701, file.irep_section_size_bytes);
    t.assert_eq(7, file.records.len);
    t.assert_true(record_shape_matches(file, 0, record_shape(1, 3, 1, 13, 0, 1)), "counter root");
    t.assert_true(record_shape_matches(file, 1, record_shape(1, 2, 5, 22, 0, 5)), "counter class");
    t.assert_true(record_shape_matches(file, 2, record_shape(2, 3, 0, 17, 1, 2)), "counter initialize");
    t.assert_true(record_shape_matches(file, 3, record_shape(2, 5, 0, 15, 0, 1)), "counter increment");
    t.assert_true(record_shape_matches(file, 4, record_shape(2, 5, 0, 15, 0, 1)), "counter decrement");
    t.assert_true(record_shape_matches(file, 5, record_shape(2, 3, 0, 11, 0, 1)), "counter reset");
    t.assert_true(record_shape_matches(file, 6, record_shape(2, 4, 0, 69, 10, 2)), "counter html");

    t.assert_eq(1, file.records[0].first_child_index);
    t.assert_eq(2, file.records[1].first_child_index);
    t.assert_eq(3, file.records[2].next_sibling_index);
    t.assert_eq(-1, file.records[6].next_sibling_index);
    t.assert_eq(2, file.records[6].depth);
    t.assert_eq(-1, file.records[0].parent_index);

    t.assert_true(symbol_is(file, 0, 0, "Counter"), "Counter symbol");
    t.assert_true(symbol_is(file, 1, 0, "initialize"), "initialize symbol");
    t.assert_true(symbol_is(file, 1, 4, "html"), "html symbol");
    t.assert_true(symbol_is(file, 2, 0, "@count"), "@count symbol");
    t.assert_true(symbol_is(file, 2, 1, "@label"), "@label symbol");
    t.assert_true(symbol_is(file, 6, 0, "@label"), "html @label symbol");
    t.assert_true(symbol_is(file, 6, 1, "@count"), "html @count symbol");

    t.assert_true(pool_is(file, 2, 0, "Click me"), "Click me literal");
    t.assert_true(pool_is(file, 6, 0, "<div class='counter'>"), "counter root literal");
    t.assert_true(pool_is(file, 6, 3, "<span class='count'>"), "count span literal");
    t.assert_true(pool_is(file, 6, 9, "</div>"), "closing div literal");
}

fn test_todo_parses_nested_render_block(t: goosetest::Test&) {
    var bytes: u8[>..] = [];
    bytes.append(RITE_PREFIX);
    bytes.append(TODO_CHI);
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let err = vm::parse_rite(bytes[..], file);

    t.assert_eq(vm::ParseError.Ok, err);
    t.assert_eq(1196, file.binary_size_bytes);
    t.assert_eq(8, file.records.len);
    t.assert_true(record_shape_matches(file, 3, record_shape(3, 9, 0, 58, 2, 6)), "todo add_item");
    t.assert_true(record_shape_matches(file, 6, record_shape(3, 6, 1, 88, 10, 4)), "todo html");
    t.assert_true(record_shape_matches(file, 7, record_shape(4, 8, 0, 86, 6, 2)), "todo render block");

    t.assert_eq(7, file.records[6].first_child_index);
    t.assert_eq(3, file.records[7].depth);
    t.assert_true(symbol_is(file, 0, 0, "TodoList"), "TodoList symbol");
    t.assert_true(symbol_is(file, 1, 3, "remove_last"), "remove_last symbol");
    t.assert_true(symbol_is(file, 3, 5, "<<"), "append symbol");
    t.assert_true(symbol_is(file, 7, 0, "done"), "done symbol");
    t.assert_true(symbol_is(file, 7, 1, "text"), "text symbol");

    t.assert_true(pool_is(file, 3, 0, "Task "), "task prefix literal");
    t.assert_true(pool_is(file, 3, 1, ""), "empty literal");
    t.assert_true(pool_is(file, 7, 2, "<li class='"), "list item literal");
    t.assert_true(pool_is(file, 7, 4, " \xE2\x9C\x93"), "check mark literal");
}

fn test_users_parses_parse_names_and_block(t: goosetest::Test&) {
    var bytes: u8[>..] = [];
    bytes.append(RITE_PREFIX);
    bytes.append(USERS_CHI);
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    let err = vm::parse_rite(bytes[..], file);

    t.assert_eq(vm::ParseError.Ok, err);
    t.assert_eq(1221, file.binary_size_bytes);
    t.assert_eq(8, file.records.len);
    t.assert_true(record_shape_matches(file, 5, record_shape(10, 15, 0, 155, 2, 6)), "users parse_names");
    t.assert_true(record_shape_matches(file, 7, record_shape(3, 5, 0, 19, 2, 0)), "users render block");

    t.assert_true(symbol_is(file, 0, 0, "UserList"), "UserList symbol");
    t.assert_true(symbol_is(file, 1, 3, "parse_names"), "parse_names symbol");
    t.assert_true(symbol_is(file, 5, 0, "Array"), "Array symbol");
    t.assert_true(symbol_is(file, 5, 5, "<<"), "append symbol");
    t.assert_true(pool_is(file, 5, 0, "\"name\":\""), "name key literal");
    t.assert_true(pool_is(file, 7, 0, "<li>"), "list item literal");
    t.assert_true(pool_is(file, 7, 1, "</li>"), "list end literal");
}

fn base_parts() -> RecordParts {
    return RecordParts {
        iseq: "",
        pool: "",
        syms: "",
        pool_count: 0,
        sym_count: 0,
        child_count: 0,
    };
}

fn push_u16_be(out: u8[>..]&, value: u16) {
    out.push((value >> 8)as!u8);
    out.push(value as!u8);
}

fn push_u32_be(out: u8[>..]&, value: u32) {
    out.push((value >> 24)as!u8);
    out.push((value >> 16)as!u8);
    out.push((value >> 8)as!u8);
    out.push(value as!u8);
}

fn put_u32_be(out: u8[>..]&, at: i64, value: u32) {
    out[at] = (value >> 24)as!u8;
    out[at + 1] = (value >> 16)as!u8;
    out[at + 2] = (value >> 8)as!u8;
    out[at + 3] = value as!u8;
}

fn make_record(parts: RecordParts, children: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    let own_size = 16 + parts.iseq.len + 2 + parts.pool.len + 2 + parts.syms.len;
    push_u32_be(out, own_size as u32);
    push_u16_be(out, 1);
    push_u16_be(out, 3);
    push_u16_be(out, parts.child_count);
    push_u16_be(out, 0);
    push_u32_be(out, parts.iseq.len as u32);
    out.append(parts.iseq);
    push_u16_be(out, parts.pool_count);
    out.append(parts.pool);
    push_u16_be(out, parts.sym_count);
    out.append(parts.syms);
    out.append(children);
    return out;
}

fn make_rite(irep: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("RITE0400");
    push_u32_be(out, 0);
    out.append("MATZ");
    out.append("0000");
    out.append("IREP");
    push_u32_be(out, (vm::IREP_SECTION_HEADER_BYTES + irep.len)as u32);
    out.append("0400");
    out.append(irep);
    out.append("END\0");
    push_u32_be(out, 8);
    let total = out.len as u32;
    put_u32_be(out, 8, total);
    return out;
}

fn test_synthetic_minimal_irep_is_accepted(t: goosetest::Test&) {
    var record = make_record(base_parts(), "");
    var bytes = make_rite(record[..]);
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::parse_rite(bytes[..], file));
    t.assert_eq(1, file.records.len);
    t.assert_eq(20, file.records[0].record_size_bytes);
    t.assert_eq(0, file.records[0].iseq_length_bytes);
}

fn test_numeric_pool_entries_decode(t: goosetest::Test&) {
    var pool: u8[>..] = [];
    pool.push(1);
    push_u32_be(pool, 0xFFFFFFFE);
    pool.push(3);
    push_u32_be(pool, 0xFFFFFFFF);
    push_u32_be(pool, 0xFFFFFFFE);
    pool.push(5);
    pool.append("\x00\x00\x00\x00\x00\x00\xF8\x3F");
    pool.push(7);
    pool.push(2);
    pool.push(1);
    pool.push(2);
    pool.push(3);

    var parts = base_parts();
    parts.pool = pool[..];
    parts.pool_count = 4;
    var record = make_record(parts, "");
    var bytes = make_rite(record[..]);
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::parse_rite(bytes[..], file));
    t.assert_eq(4, file.pools.len);

    t.assert_eq(1, file.pools[0].tag);
    t.assert_eq(-2, file.pools[0].int_value);
    t.assert_eq(3, file.pools[1].tag);
    t.assert_eq(-2, file.pools[1].int_value);
    t.assert_eq(5, file.pools[2].tag);
    t.assert_true(file.pools[2].float_value == 1.5, "float literal");
    t.assert_eq(7, file.pools[3].tag);
    t.assert_eq(4, file.pools[3].text_length_bytes);
    let blob_start = file.pools[3].text_offset_bytes;
    t.assert_true(file.data[blob_start..blob_start + 4] == "\x02\x01\x02\x03", "bigint blob");
}

fn test_malformed_headers_and_sections_are_rejected(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };

    var empty: u8[>..] = [];
    t.assert_eq(vm::ParseError.Truncated, vm::parse_rite(empty[..], file));

    var short: u8[>..] = [];
    short.append(RITE_PREFIX);
    t.assert_eq(vm::ParseError.Truncated, vm::parse_rite(short[..], file));

    var bad_magic: u8[>..] = [];
    bad_magic.append("XITE0400\x00\x00");
    bad_magic.append(COUNTER_CHI);
    t.assert_eq(vm::ParseError.BadMagic, vm::parse_rite(bad_magic[..], file));

    var bad_version: u8[>..] = [];
    bad_version.append("RITE0300\x00\x00");
    bad_version.append(COUNTER_CHI);
    t.assert_eq(vm::ParseError.BadVersion, vm::parse_rite(bad_version[..], file));

    var bad_size: u8[>..] = [];
    bad_size.append(RITE_PREFIX);
    bad_size.append(COUNTER_CHI);
    put_u32_be(bad_size, 8, 4096);
    t.assert_eq(vm::ParseError.BadBinarySize, vm::parse_rite(bad_size[..], file));

    var trailing: u8[>..] = [];
    trailing.append(RITE_PREFIX);
    trailing.append(COUNTER_CHI);
    trailing.push(0);
    t.assert_eq(vm::ParseError.BadBinarySize, vm::parse_rite(trailing[..], file));

    var bad_section: u8[>..] = [];
    bad_section.append(RITE_PREFIX);
    bad_section.append(COUNTER_CHI);
    put_u32_be(bad_section, 24, 4096);
    t.assert_eq(vm::ParseError.BadSection, vm::parse_rite(bad_section[..], file));

    var bad_rite_version: u8[>..] = [];
    bad_rite_version.append(RITE_PREFIX);
    bad_rite_version.append(COUNTER_CHI);
    bad_rite_version[28] = '3';
    t.assert_eq(vm::ParseError.BadRiteVersion, vm::parse_rite(bad_rite_version[..], file));

    var no_irep: u8[>..] = [];
    no_irep.append("RITE0400");
    push_u32_be(no_irep, 0);
    no_irep.append("MATZ0000");
    no_irep.append("END\0");
    push_u32_be(no_irep, 8);
    let no_irep_total = no_irep.len as u32;
    put_u32_be(no_irep, 8, no_irep_total);
    t.assert_eq(vm::ParseError.MissingIrep, vm::parse_rite(no_irep[..], file));

    var no_end: u8[>..] = [];
    no_end.append(RITE_PREFIX);
    no_end.append(COUNTER_CHI);
    no_end[no_end.len - 8] = 'X';
    t.assert_eq(vm::ParseError.BadSection, vm::parse_rite(no_end[..], file));
}

fn test_append_keeps_absolute_records_and_roots(t: goosetest::Test&) {
    var bytes: u8[>..] = [];
    bytes.append(RITE_PREFIX);
    bytes.append(COUNTER_CHI);
    let first_len = bytes.len;
    bytes.append(RITE_PREFIX);
    bytes.append(TODO_CHI);

    var file: vm::RiteFile = vm::RiteFile {
        ..
    };
    t.assert_eq(vm::ParseError.Ok, vm::parse_rite(bytes[..first_len], file));
    t.assert_eq(1, file.roots.len);
    t.assert_eq(0, file.roots[0]);
    t.assert_true(file.records[0].record_offset_bytes > 0);
    let first_record_count = file.records.len;
    let first_pool_count = file.pools.len;

    t.assert_eq(vm::ParseError.Ok, vm::parse_rite_append(bytes[..], file, first_len));
    t.assert_eq(2, file.roots.len);
    t.assert_eq(first_record_count, file.roots[1]);
    t.assert_true(file.records[file.roots[1]].record_offset_bytes > 0);
    t.assert_true(file.records[file.roots[1]].record_offset_bytes >= first_len);
    t.assert_eq(bytes.len as u32, file.binary_size_bytes);
    t.assert_true(file.pools.len > first_pool_count);

    t.assert_eq(
        vm::ParseError.BadMagic, vm::parse_rite_append(bytes[..], file, first_len + 1)
    );
    t.assert_eq(2, file.roots.len);
}

fn test_corrupt_records_are_rejected(t: goosetest::Test&) {
    var file: vm::RiteFile = vm::RiteFile {
        ..
    };

    var record = make_record(base_parts(), "");
    var bytes = make_rite(record[..]);
    put_u32_be(bytes, 32, 8);
    t.assert_eq(vm::ParseError.RecordSizeMismatch, vm::parse_rite(bytes[..], file));

    var big_iseq = make_rite(record[..]);
    put_u32_be(big_iseq, 44, 4096);
    t.assert_eq(vm::ParseError.Truncated, vm::parse_rite(big_iseq[..], file));

    var bad_pool: u8[>..] = [];
    bad_pool.push(9);
    var pool_parts = base_parts();
    pool_parts.pool = bad_pool[..];
    pool_parts.pool_count = 1;
    var pool_record = make_record(pool_parts, "");
    var pool_bytes = make_rite(pool_record[..]);
    t.assert_eq(vm::ParseError.BadPoolTag, vm::parse_rite(pool_bytes[..], file));

    var bad_syms: u8[>..] = [];
    push_u16_be(bad_syms, 100);
    var sym_parts = base_parts();
    sym_parts.syms = bad_syms[..];
    sym_parts.sym_count = 1;
    var sym_record = make_record(sym_parts, "");
    var sym_bytes = make_rite(sym_record[..]);
    t.assert_eq(vm::ParseError.Truncated, vm::parse_rite(sym_bytes[..], file));

    var nested = make_record(base_parts(), "");
    for _ in 40 {
        var parts = base_parts();
        parts.child_count = 1;
        let parent = make_record(parts, nested[..]);
        nested = copy(parent);
    }
    var deep_bytes = make_rite(nested[..]);
    t.assert_eq(vm::ParseError.TooDeep, vm::parse_rite(deep_bytes[..], file));
}
