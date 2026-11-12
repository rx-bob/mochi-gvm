// Two-zone value arena and the 64-bit opaque `mrb_value` used by the VM.
//
// The VM never hands out pointers. `MrbValue` packs a tag and a 32-bit payload
// into a `u64`: immediates (nil, booleans, fixnums, symbols, class IDs) carry
// their value directly, while objects carry a 1-bit zone tag (scratch or state),
// a 15-bit object index and a 16-bit generation into that zone's object table.
//
// Tick scratch is a fixed inline arena. Allocation reuses free headers, slots,
// ivars and string ranges during a long entry, and `scratch_reset` returns every
// cursor to zero in O(1), so a render tick always leaves the arena exactly as
// it found it. State storage is reused by the tracing collector in
// `state_reclaim.goose`, which frees unreachable headers, ivars, slots and
// string ranges, and each reused header carries a new generation so a stale
// handle fails safely instead of aliasing the next object. Values entering
// state still pass through `promote_to_state`, which deep-copies scratch
// strings and nested instances so they survive the next tick reset.
namespace vm;

import.capacity_config;
import.ivar_mask;

let MRB_TAG_SHIFT: u64 = 32;
let MRB_PAYLOAD_MASK: u64 = 0xFFFFFFFF;
let MRB_TAG_NIL: u64 = 0;
let MRB_TAG_FALSE: u64 = 1;
let MRB_TAG_TRUE: u64 = 2;
let MRB_TAG_FIXNUM: u64 = 3;
let MRB_TAG_SYMBOL: u64 = 4;
let MRB_TAG_CLASS: u64 = 5;
let MRB_TAG_ARENA: u64 = 6;
let MRB_TAG_BLOCK: u64 = 7;
// Boxed numbers keep the same 32-bit arena-handle payload as `MRB_TAG_ARENA`.
// The distinct tag lets predicates and diagnostics identify the kind without
// looking up the object; the payload still names the scratch or state zone,
// object index and generation.
let MRB_TAG_INT64: u64 = 9;
let MRB_TAG_FLOAT: u64 = 10;

let MRB_ARENA_TAG_SHIFT: u64 = 31;
// State object indices stop at `MAX_STATE_OBJECTS` (32768), which fits in 15
// bits. The remaining 16 payload bits are a generation; 65536 reuses of one
// slot wrap it, so a handle older than that is documented as not detectable.
let MRB_ARENA_INDEX_MASK: u64 = 0x7FFF;
let MRB_ARENA_GENERATION_SHIFT: u64 = 15;
let MRB_ARENA_GENERATION_MASK: u64 = 0xFFFF;
let MRB_ARENA_SCRATCH: u8 = 0;
let MRB_ARENA_STATE: u8 = 1;

let MRB_FIXNUM_MIN: i64 = -2147483648;
let MRB_FIXNUM_MAX: i64 = 2147483647;

// Scratch is inline and fixed. Reclamation keeps the live set small during
// nested row builds; a workload whose live temporaries exceed these ceilings
// fails with a named, recoverable resource error instead of growing the
// process. The ceilings leave the WASM data-stack reserve intact.
type MrbValue = u64;

// The kinds the arena can own. Strings live in the zone byte blob; instances
// own a linked list of ivar slots; arrays and hashes own a linked list of
// `ArenaSlot` nodes in the zone slot table.
enum ArenaObjectKind {
    String,
    Instance,
    Array,
    Hash,
    // Boxed numeric leaves. `integer_value` is exact across the signed 64-bit
    // range; `float_value` holds one binary64 value.
    Int64,
    Float,
}

// One object header. `text_offset_bytes` and `text_length_bytes` view the
// zone blob for strings. `ivar_head_index` is -1 or the first `IvarSlot`.
// Arrays and hashes use the item fields to bracket their linked slot list.
//
// Instances also carry the reactive signal bookkeeping: `ivar_count` is the
// number of distinct ivars ever seen (and therefore the next free bit),
// while `dirty_ivars` records the ivars changed since the binding flush.
struct ArenaObject {
    kind: ArenaObjectKind,
    text_offset_bytes: i64,
    text_length_bytes: i64,
    class_index: u32,
    ivar_head_index: i64,
    ivar_count: u16,
    dirty_ivars: IvarMask,
    items_first_index: i64,
    items_last_index: i64,
    item_count: i64,
    // Numeric leaves use exactly one of these fields according to `kind`.
    integer_value: i64,
    float_value: f64,
    // Instances keep their header so shared references stay valid after
    // disposal. Every host entry checks this flag before touching the object.
    disposed: bool,
    // `allocated` is false for a header on the state free list. The generation
    // changes every time a header is freed, so stale handles fail lookup.
    allocated: bool,
    generation: u16,
}

// One instance variable. Slots form a per-object singly linked list, so
// assigning unrelated objects never has to move or compact earlier slots.
// `bit_index` is the slot's stable position in the instance's 256-bit mask.
struct IvarSlot {
    key: u32,
    bit_index: u8,
    value: MrbValue,
    next_index: i64,
    allocated: bool,
}

// One array element or hash key-value pair. Slots form a doubly linked list so
// `push` is O(1), `pop` can unlink the tail, and hashes keep insertion order.
struct ArenaSlot {
    key: MrbValue,
    value: MrbValue,
    previous_index: i64,
    next_index: i64,
    allocated: bool,
}

// One reclaimed string-byte range. Freed ranges stay sorted and coalesce with
// their neighbours so repeated row builds reuse the same tick blob.
struct ScratchByteRange {
    offset: i64,
    length: i64,
}

// The resource that rejected a scratch allocation, plus the size and arena
// occupancy at the failure point. The first rejection is kept so a later
// overflow cannot overwrite the useful diagnostic.
enum ScratchResource {
    None,
    Objects,
    Bytes,
    Ivars,
    Slots,
}

enum CapacityResource {
    None,
    ScratchObjects,
    ScratchBytes,
    ScratchIvars,
    ScratchSlots,
    StateBytes,
    StateObjects,
    StateIvars,
    StateSlots,
    IvarsPerObject,
    Components,
    Bindings,
    Classes,
    AbiBytecode,
}

struct CapacityFailure {
    resource: CapacityResource,
    requested: i64,
    used: i64,
    capacity: i64,
    active: bool,
}

struct ScratchFailure {
    resource: ScratchResource,
    requested: i64,
    used: i64,
    capacity: i64,
    active: bool,
}

// Tick-scoped allocations. Growable buffers are rewound in O(1) by
// `scratch_reset` while enforcing high safety ceilings without aborting.
// Reclaimed headers, slots, ivars and string ranges stay on free lists for the
// rest of the entry; `scratch_reclaim.goose` rebuilds those lists at instruction
// boundaries when the arena starts to fill.
struct ScratchArena {
    blob: u8[..SCRATCH_CAPACITY_BYTES] = [],
    objects: ArenaObject[..SCRATCH_CAPACITY_OBJECTS] = [],
    ivars: IvarSlot[..SCRATCH_CAPACITY_IVARS] = [],
    slots: ArenaSlot[..SCRATCH_CAPACITY_SLOTS] = [],
    free_objects: i64[..SCRATCH_CAPACITY_OBJECTS] = [],
    free_ivars: i64[..SCRATCH_CAPACITY_IVARS] = [],
    free_slots: i64[..SCRATCH_CAPACITY_SLOTS] = [],
    free_bytes: ScratchByteRange[..SCRATCH_CAPACITY_OBJECTS] = [],
    marks: u32[..SCRATCH_CAPACITY_OBJECTS] = [],
    ivar_marks: u32[..SCRATCH_CAPACITY_IVARS] = [],
    slot_marks: u32[..SCRATCH_CAPACITY_SLOTS] = [],
    mark_stack: MrbValue[..SCRATCH_CAPACITY_OBJECTS] = [],
    mark_epoch: u32 = 0,
    allocations_since_collect: i64 = 0,
    failure: ScratchFailure = ScratchFailure {
        resource: ScratchResource.None,
        requested: 0,
        used: 0,
        capacity: 0,
        active: false,
    },
    allocated_objects_total: i64 = 0,
    allocated_bytes_total: i64 = 0,
    reset_count: i64 = 0,
    overflow: bool = false,
}

// Returns the numeric tag of any `MrbValue`.
fn mrb_value_tag(value: MrbValue) -> u64 {
    return value >> MRB_TAG_SHIFT;
}

fn mrb_nil() -> MrbValue {
    return MRB_TAG_NIL << MRB_TAG_SHIFT;
}

fn mrb_false() -> MrbValue {
    return MRB_TAG_FALSE << MRB_TAG_SHIFT;
}

fn mrb_true() -> MrbValue {
    return MRB_TAG_TRUE << MRB_TAG_SHIFT;
}

fn mrb_bool(value: bool) -> MrbValue {
    if value {
        return mrb_true();
    }
    return mrb_false();
}

// Encodes a signed 32-bit immediate. Values outside the fixnum range use an
// arena object through `num_from_i64`; this entry point rejects them instead
// of silently truncating.
fn mrb_fixnum(value: i64) -> MrbValue {
    assert(value >= MRB_FIXNUM_MIN);
    assert(value <= MRB_FIXNUM_MAX);
    let payload = (value as!u64) & MRB_PAYLOAD_MASK;
    return (MRB_TAG_FIXNUM << MRB_TAG_SHIFT) | payload;
}

fn mrb_fixnum_value(value: MrbValue) -> i64 {
    assert(mrb_is_fixnum(value));
    let payload = value & MRB_PAYLOAD_MASK;
    if (payload & 0x80000000) != 0 {
        return (payload | 0xFFFFFFFF00000000)as!i64;
    }
    return payload as!i64;
}

// Appends the decimal form of `number`. Integers render without touching an
// arena, which keeps `to_s` and `Array#join` allocation-free for scalars.
fn mrb_format_fixnum(out: u8[>..]&, number: i64) {
    if number == -9223372036854775808 {
        out.append("-9223372036854775808");
        return;
    }
    var magnitude = number;
    if magnitude < 0 {
        out.push(45);
        magnitude = -magnitude;
    }
    if magnitude == 0 {
        out.push(48);
        return;
    }
    var digits: u8[>..] = [];
    while magnitude > 0 {
        digits.push((48 + magnitude % 10)as u8);
        magnitude /= 10;
    }
    var index = digits.len - 1;
    while index >= 0 {
        out.push(digits[index]);
        index -= 1;
    }
}

fn mrb_symbol(symbol_id: u32) -> MrbValue {
    return (MRB_TAG_SYMBOL << MRB_TAG_SHIFT) | symbol_id;
}

fn mrb_symbol_id(value: MrbValue) -> u32 {
    assert(mrb_is_symbol(value));
    return (value & MRB_PAYLOAD_MASK)as u32;
}

fn mrb_class(class_id: u32) -> MrbValue {
    return (MRB_TAG_CLASS << MRB_TAG_SHIFT) | class_id;
}

fn mrb_class_id(value: MrbValue) -> u32 {
    assert(mrb_is_class(value));
    return (value & MRB_PAYLOAD_MASK)as u32;
}

let MRB_BLOCK_RECORD_MASK: u64 = 0x00FFFFFF;
let MRB_BLOCK_ENV_SHIFT: u64 = 24;

// Packs an absolute child-IREP index and optional lexical parent frame index.
fn mrb_block(record_index: i64) -> MrbValue {
    return mrb_block_with_env(record_index, -1);
}

fn mrb_block_with_env(record_index: i64, env_frame: i64) -> MrbValue {
    assert(record_index >= 0);
    assert(record_index <= MRB_BLOCK_RECORD_MASK as i64);
    let encoded_env: u64 = if env_frame >= 0 && env_frame < 255 {
        (env_frame + 1)as!u64
    } else {
        0
    };
    return (MRB_TAG_BLOCK << MRB_TAG_SHIFT)
        | (encoded_env << MRB_BLOCK_ENV_SHIFT)
        | (record_index as!u64);
}

fn mrb_block_record_index(value: MrbValue) -> i64 {
    assert(mrb_is_block(value));
    return (value & MRB_BLOCK_RECORD_MASK)as i64;
}

fn mrb_block_env_frame(value: MrbValue) -> i64 {
    assert(mrb_is_block(value));
    let encoded = (value >> MRB_BLOCK_ENV_SHIFT) & 0xFF;
    return (encoded as i64) - 1;
}

// Packs a zone tag and an object-table index into one arena handle.
fn mrb_arena_value(arena_tag: u8, index: u32) -> MrbValue {
    return mrb_arena_value_versioned(arena_tag, index, 0);
}

// Packs a zone tag, an object-table index and a generation. State allocations
// use the current header generation so a freed slot cannot answer to an old
// handle. The fixed scratch arena always uses generation zero.
fn mrb_arena_value_versioned(arena_tag: u8, index: u32, generation: u16) -> MrbValue {
    return mrb_typed_arena_value(MRB_TAG_ARENA, arena_tag, index, generation);
}

// Packs a boxed-number tag with the same zone/index/generation payload used by
// ordinary arena handles.
fn mrb_typed_arena_value(
    tag: u64, arena_tag: u8, index: u32, generation: u16
) -> MrbValue {
    assert(index <= MRB_ARENA_INDEX_MASK as u32);
    return (tag << MRB_TAG_SHIFT)
        | ((arena_tag as u64) << MRB_ARENA_TAG_SHIFT)
        | ((generation as u64) << MRB_ARENA_GENERATION_SHIFT)
        | index;
}

fn mrb_arena_tag(value: MrbValue) -> u8 {
    assert(mrb_is_arena(value));
    return ((value >> MRB_ARENA_TAG_SHIFT) & 1)as u8;
}

fn mrb_arena_index(value: MrbValue) -> u32 {
    assert(mrb_is_arena(value));
    return (value & MRB_ARENA_INDEX_MASK)as u32;
}

fn mrb_arena_generation(value: MrbValue) -> u16 {
    assert(mrb_is_arena(value));
    return ((value >> MRB_ARENA_GENERATION_SHIFT) & MRB_ARENA_GENERATION_MASK)as u16;
}

fn mrb_is_nil(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_NIL;
}

fn mrb_is_false(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_FALSE;
}

fn mrb_is_true(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_TRUE;
}

fn mrb_is_bool(value: MrbValue) -> bool {
    return mrb_is_false(value) || mrb_is_true(value);
}

fn mrb_is_fixnum(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_FIXNUM;
}

fn mrb_is_symbol(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_SYMBOL;
}

fn mrb_is_class(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_CLASS;
}

fn mrb_is_block(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_BLOCK;
}

fn mrb_is_int64(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_INT64;
}

fn mrb_is_float(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_FLOAT;
}

// Boxed numbers are arena handles too, so shared lookup, promotion and
// reclamation code addresses every heap value through one path.
fn mrb_is_arena(value: MrbValue) -> bool {
    let tag = mrb_value_tag(value);
    return tag == MRB_TAG_ARENA || tag == MRB_TAG_INT64 || tag == MRB_TAG_FLOAT;
}

fn mrb_is_scratch(value: MrbValue) -> bool {
    return mrb_is_arena(value) && mrb_arena_tag(value) == MRB_ARENA_SCRATCH;
}

fn mrb_is_state(value: MrbValue) -> bool {
    return mrb_is_arena(value) && mrb_arena_tag(value) == MRB_ARENA_STATE;
}

// mruby truthiness: only nil and false are falsey; zero is truthy.
fn mrb_truthy(value: MrbValue) -> bool {
    return !mrb_is_nil(value) && !mrb_is_false(value);
}

// Compares the opaque handles, not Ruby `==`: two distinct string objects
// with equal bytes are different handles.
fn mrb_value_identical(left: MrbValue, right: MrbValue) -> bool {
    return left == right;
}

// Returns a short zone-aware name for diagnostics and tests.
fn mrb_value_kind_name(value: MrbValue) -> u8[:] {
    let tag = mrb_value_tag(value);
    if tag == MRB_TAG_NIL {
        return "nil";
    }
    if tag == MRB_TAG_FALSE {
        return "false";
    }
    if tag == MRB_TAG_TRUE {
        return "true";
    }
    if tag == MRB_TAG_FIXNUM {
        return "fixnum";
    }
    if tag == MRB_TAG_SYMBOL {
        return "symbol";
    }
    if tag == MRB_TAG_CLASS {
        return "class";
    }
    if tag == MRB_TAG_BLOCK {
        return "block";
    }
    if tag == MRB_TAG_INT64 {
        return "int64";
    }
    if tag == MRB_TAG_FLOAT {
        return "float";
    }
    if tag == MRB_TAG_ARENA {
        if ((value >> MRB_ARENA_TAG_SHIFT) & 1) != 0 {
            return "state";
        }
        return "scratch";
    }
    return "invalid";
}

fn empty_arena_object(kind: ArenaObjectKind) -> ArenaObject {
    return ArenaObject {
        kind: kind,
        text_offset_bytes: 0,
        text_length_bytes: 0,
        class_index: 0,
        ivar_head_index: -1,
        ivar_count: 0,
        dirty_ivars: mask_clear(),
        items_first_index: -1,
        items_last_index: -1,
        item_count: 0,
        integer_value: 0,
        float_value: 0.0,
        disposed: false,
        allocated: true,
        generation: 0,
    };
}
