// Bounds-checked byte readers shared by the RITE parser.
namespace vm;

// Reads a big-endian u16, reporting false instead of reading out of bounds.
fn read_u16(data: u8[:], at: i64) -> u16, bool {
    if at < 0 || at > data.len - 2 {
        return 0, false;
    }
    return (data[at]as u16 << 8) | data[at + 1], true;
}

// Reads a big-endian u32, reporting false instead of reading out of bounds.
fn read_u32(data: u8[:], at: i64) -> u32, bool {
    if at < 0 || at > data.len - 4 {
        return 0, false;
    }
    let value = (data[at]as u32 << 24)
        | (data[at + 1]as u32 << 16)
        | (data[at + 2]as u32 << 8)
        | data[at + 3];
    return value, true;
}

// Reports whether `expected` appears verbatim at `at`.
fn bytes_equal(data: u8[:], at: i64, expected: u8[:]) -> bool {
    if at < 0 || at + expected.len > data.len {
        return false;
    }
    let stop = at + expected.len;
    return compare(data[at..stop], expected) == 0;
}
