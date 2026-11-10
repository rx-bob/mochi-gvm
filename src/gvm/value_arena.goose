// Two-zone value arena and the 64-bit opaque `mrb_value` used by the VM.
//
// The VM never hands out pointers. `MrbValue` packs a tag and a 32-bit payload
// into a `u64`: immediates (nil, booleans, fixnums, symbols, class IDs) carry
// their value directly, while objects carry a 1-bit zone tag (scratch or state)
// and a 31-bit index into that zone's object table.
//
// Tick scratch is a fixed inline arena: every allocation bumps `blob.len` and
// `objects.len`, and `scratch_reset` clears both to zero in O(1), so a render
// tick always leaves the arena exactly as it found it. State is a grow-only
// pool for classes, component instances and their ivars; values entering it
// must pass through `promote_to_state`, which deep-copies scratch strings and
// nested instances so they survive the next tick reset.
namespace vm;

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

let MRB_ARENA_TAG_SHIFT: u64 = 31;
let MRB_ARENA_INDEX_MASK: u64 = 0x7FFFFFFF;
let MRB_ARENA_SCRATCH: u8 = 0;
let MRB_ARENA_STATE: u8 = 1;

let MRB_FIXNUM_MIN: i64 = -2147483648;
let MRB_FIXNUM_MAX: i64 = 2147483647;

// Scratch is inline and fixed: a tick that needs more than these limits aborts
// instead of growing the process. The values comfortably cover the counter,
// todo and users components while leaving the WASM stack reserve intact.
let SCRATCH_CAPACITY_BYTES = 16384;
let SCRATCH_CAPACITY_OBJECTS = 1024;
let SCRATCH_CAPACITY_IVARS = 1024;
let SCRATCH_CAPACITY_SLOTS = 2048;

type MrbValue = u64;

// The kinds the arena can own. Strings live in the zone byte blob; instances
// own a linked list of ivar slots; arrays and hashes own a linked list of
// `ArenaSlot` nodes in the zone slot table.
enum ArenaObjectKind {
    String,
    Instance,
    Array,
    Hash,
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
    ivar_count: u8,
    dirty_ivars: u64,
    items_first_index: i64,
    items_last_index: i64,
    item_count: i64,
}

// One instance variable. Slots form a per-object singly linked list, so
// assigning unrelated objects never has to move or compact earlier slots.
// `bit_index` is the slot's stable position in the instance's u64 masks.
struct IvarSlot {
    key: u32,
    bit_index: u8,
    value: MrbValue,
    next_index: i64,
}

// One array element or hash key-value pair. Slots form a doubly linked list so
// `push` is O(1), `pop` can unlink the tail, and hashes keep insertion order.
struct ArenaSlot {
    key: MrbValue,
    value: MrbValue,
    previous_index: i64,
    next_index: i64,
}

// Tick-scoped allocations. The arrays are inline limited arrays, so the arena
// has a fixed size and `scratch_reset` only rewinds their lengths. The VM owns
// exactly one instance for its lifetime; do not construct one per tick.
struct ScratchArena {
    blob: u8[..SCRATCH_CAPACITY_BYTES] = [],
    objects: ArenaObject[..SCRATCH_CAPACITY_OBJECTS] = [],
    ivars: IvarSlot[..SCRATCH_CAPACITY_IVARS] = [],
    slots: ArenaSlot[..SCRATCH_CAPACITY_SLOTS] = [],
    allocated_objects_total: i64 = 0,
    allocated_bytes_total: i64 = 0,
    reset_count: i64 = 0,
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

// Encodes a signed 32-bit immediate. Values outside the fixnum range belong in
// a future heap object, so this rejects them rather than silently truncating.
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

// Packs an absolute child-IREP index as a block closure handle. The fixtures
// only need the block body, so the closure carries no captured environment.
fn mrb_block(record_index: i64) -> MrbValue {
    assert(record_index >= 0);
    assert(record_index <= MRB_PAYLOAD_MASK as i64);
    return (MRB_TAG_BLOCK << MRB_TAG_SHIFT) | (record_index as!u64);
}

fn mrb_block_record_index(value: MrbValue) -> i64 {
    assert(mrb_is_block(value));
    return (value & MRB_PAYLOAD_MASK)as i64;
}

// Packs a zone tag and an object-table index into one arena handle.
fn mrb_arena_value(arena_tag: u8, index: u32) -> MrbValue {
    assert(index <= MRB_ARENA_INDEX_MASK);
    return (MRB_TAG_ARENA << MRB_TAG_SHIFT)
        | ((arena_tag as u64) << MRB_ARENA_TAG_SHIFT)
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

fn mrb_is_arena(value: MrbValue) -> bool {
    return mrb_value_tag(value) == MRB_TAG_ARENA;
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
        dirty_ivars: 0,
        items_first_index: -1,
        items_last_index: -1,
        item_count: 0,
    };
}

fn scratch_bytes_used(arena: ScratchArena&) -> i64 {
    return arena.blob.len;
}

fn scratch_object_count(arena: ScratchArena&) -> i64 {
    return arena.objects.len;
}

fn scratch_ivar_count(arena: ScratchArena&) -> i64 {
    return arena.ivars.len;
}

// Rewinds both bump cursors. Total allocation counters deliberately survive so
// tests and telemetry can prove that many ticks reused the same fixed arena.
fn scratch_reset(arena: ScratchArena&) {
    arena.blob.clear();
    arena.objects.clear();
    arena.ivars.clear();
    arena.slots.clear();
    arena.reset_count += 1;
}

fn scratch_object(arena: ScratchArena&, value: MrbValue) -> ArenaObject, bool {
    if !mrb_is_arena(value) {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    if mrb_arena_tag(value) != MRB_ARENA_SCRATCH {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    let index = mrb_arena_index(value)as i64;
    if index < 0 || index >= arena.objects.len {
        return empty_arena_object(ArenaObjectKind.String), false;
    }
    return arena.objects[index], true;
}

// Copies `text` into the tick arena and returns a scratch string handle.
fn scratch_alloc_string(arena: ScratchArena&, text: u8[:]) -> MrbValue {
    assert(arena.objects.len < SCRATCH_CAPACITY_OBJECTS);
    assert(arena.blob.len + text.len <= SCRATCH_CAPACITY_BYTES);
    let offset = arena.blob.len;
    arena.blob.append(text);
    let index = arena.objects.len;
    arena.objects.push(ArenaObject {
            kind: ArenaObjectKind.String,
            text_offset_bytes: offset,
            text_length_bytes: text.len,
            class_index: 0,
            ivar_head_index: -1,
            ivar_count: 0,
            dirty_ivars: 0,
            items_first_index: -1,
            items_last_index: -1,
            item_count: 0,
        });
    arena.allocated_objects_total += 1;
    arena.allocated_bytes_total += text.len;
    return mrb_arena_value(MRB_ARENA_SCRATCH, index as u32);
}

// Allocates a scratch instance bound to a state-pool class ID.
fn scratch_alloc_instance(arena: ScratchArena&, class_id: u32) -> MrbValue {
    assert(arena.objects.len < SCRATCH_CAPACITY_OBJECTS);
    let index = arena.objects.len;
    arena.objects.push(ArenaObject {
            kind: ArenaObjectKind.Instance,
            text_offset_bytes: 0,
            text_length_bytes: 0,
            class_index: class_id,
            ivar_head_index: -1,
            ivar_count: 0,
            dirty_ivars: 0,
            items_first_index: -1,
            items_last_index: -1,
            item_count: 0,
        });
    arena.allocated_objects_total += 1;
    return mrb_arena_value(MRB_ARENA_SCRATCH, index as u32);
}

fn scratch_is_string(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.String;
}

fn scratch_is_instance(arena: ScratchArena&, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, value);
    return ok && object.kind == ArenaObjectKind.Instance;
}

// Returns a view of the string bytes, or an empty view for a non-string.
fn scratch_string_bytes(arena: ScratchArena&, value: MrbValue) -> const u8[:] {
    let object, ok = scratch_object(arena, value);
    if !ok || object.kind != ArenaObjectKind.String {
        return "";
    }
    let start = object.text_offset_bytes;
    let stop = start + object.text_length_bytes;
    if start < 0 || stop > arena.blob.len {
        return "";
    }
    return arena.blob[start..stop];
}

// Allocates a fresh scratch string holding `left` followed by `right`.
fn scratch_concat_string(arena: ScratchArena&, left: MrbValue, right: MrbValue) -> MrbValue {
    if !scratch_is_string(arena, left) || !scratch_is_string(arena, right) {
        return mrb_nil();
    }
    var joined: u8[>..] = [];
    joined.append(scratch_string_bytes(arena, left));
    joined.append(scratch_string_bytes(arena, right));
    return scratch_alloc_string(arena, joined[..]);
}

fn scratch_set_ivar(arena: ScratchArena&, instance: MrbValue, key: u32, value: MrbValue) -> bool {
    let object, ok = scratch_object(arena, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return false;
    }
    let index = mrb_arena_index(instance)as i64;
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        if arena.ivars[slot_index].key == key {
            arena.ivars[slot_index].value = value;
            return true;
        }
        slot_index = arena.ivars[slot_index].next_index;
    }
    assert(arena.ivars.len < SCRATCH_CAPACITY_IVARS);
    let new_index = arena.ivars.len;
    arena.ivars.push(IvarSlot {
            key: key,
            bit_index: 0,
            value: value,
            next_index: object.ivar_head_index,
        });
    arena.objects[index].ivar_head_index = new_index;
    return true;
}

fn scratch_get_ivar(arena: ScratchArena&, instance: MrbValue, key: u32) -> MrbValue, bool {
    let object, ok = scratch_object(arena, instance);
    if !ok || object.kind != ArenaObjectKind.Instance {
        return mrb_nil(), false;
    }
    var slot_index = object.ivar_head_index;
    while slot_index >= 0 {
        let slot = arena.ivars[slot_index];
        if slot.key == key {
            return slot.value, true;
        }
        slot_index = slot.next_index;
    }
    return mrb_nil(), false;
}
