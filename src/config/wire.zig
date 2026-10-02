//! Generates each settings struct's saved JSON shape, loading, saving, freeing and preview patching from its fields.
const std = @import("std");
const key_list = @import("key_list.zig");
const log = @import("../log.zig");

const KeyList = key_list.KeyList;
const KeyListWire = key_list.KeyListWire;
const slog = log.scoped("config");

/// ARGB color, serialized as an 8-digit hex string, e.g. "0xFF606060".
pub const Argb = struct {
    value: u32,

    pub fn jsonStringify(self: Argb, jw: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "0x{X:0>8}", .{self.value}) catch unreachable;
        try jw.write(s);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Argb {
        // jsonParseFromValue may only return std.json.ParseFromValueError errors, so parseHexColor's can't propagate.
        if (source != .string) return error.UnexpectedToken;
        const value = parseHexColor(source.string) catch return error.UnexpectedToken;
        return .{ .value = value };
    }
};

/// A `u32`/`?u32` field whose name ends in "color"/"Color" is an ARGB colour, saved as a hex string.
/// Accepts "0xAARRGGBB", "#AARRGGBB" or bare hex.
pub fn parseHexColor(str: []const u8) !u32 {
    if (str.len < 3) return error.InvalidColorFormat;

    const start: usize = if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X"))
        2
    else if (std.mem.startsWith(u8, str, "#"))
        1
    else
        0;
    const hex_str = str[start..];

    return std.fmt.parseInt(u32, hex_str, 16) catch error.InvalidColorFormat;
}

pub fn isColorField(comptime name: []const u8) bool {
    // Compared by hand: std.mem.endsWith costs enough comptime branches to matter across every nested field.
    if (name.len < 5) return false;
    const tail = name[name.len - 5 ..];
    return (tail[0] == 'c' or tail[0] == 'C') and tail[1] == 'o' and tail[2] == 'l' and tail[3] == 'o' and tail[4] == 'r';
}

/// A field named "hotkey…" or "…Key" is a KeyList, saved as a hex string or an array of them.
pub fn isKeyField(comptime name: []const u8) bool {
    if (name.len >= 6 and name[0] == 'h' and name[1] == 'o' and name[2] == 't' and name[3] == 'k' and name[4] == 'e' and name[5] == 'y') return true;
    return name.len >= 3 and name[name.len - 3] == 'K' and name[name.len - 2] == 'e' and name[name.len - 1] == 'y';
}

/// Generated or hand-written, a type with a `Wire` saves, loads, frees and patches itself.
pub fn isNested(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Wire");
}

/// The section type inside an optional nested section, e.g. CharacterConfig's `?CharacterBorderColorsConfig`.
pub fn OptionalNested(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .optional or !isNested(info.optional.child)) return null;
    return info.optional.child;
}

/// The item type of a `std.ArrayList` field, which is saved as a JSON array.
pub fn ListItem(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "items") or !@hasField(T, "capacity")) return null;
    const Item = @typeInfo(@FieldType(T, "items")).pointer.child;
    return if (T == std.ArrayList(Item)) Item else null;
}

/// A field named in `R.runtime_fields` (an allocator, an id) only exists while the app runs and isn't saved.
fn isSaved(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "runtime_fields")) return true;
    inline for (R.runtime_fields) |runtime| {
        if (comptime std.mem.eql(u8, runtime, name)) return false;
    }
    return true;
}

/// A field in `R.wire_defaults` loads with that default when its key is missing, for defaults a runtime field can't hold (e.g. a non-empty list).
pub fn hasWireDefault(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "wire_defaults")) return false;
    return @hasField(@TypeOf(R.wire_defaults), name);
}

pub fn savedFields(comptime R: type) []const std.builtin.Type.StructField {
    comptime {
        var out: []const std.builtin.Type.StructField = &.{};
        for (@typeInfo(R).@"struct".fields) |f| {
            if (isSaved(R, f.name)) out = out ++ &[_]std.builtin.Type.StructField{f};
        }
        return out;
    }
}

pub fn WireOf(comptime T: type) type {
    return if (isNested(T)) T.Wire else T;
}

/// Prefers the type's own `toWire`; borrows the value's strings, so the result must not outlive it.
pub fn encode(comptime T: type, value: T) WireOf(T) {
    if (comptime !isNested(T)) return fieldToWire(T, "", value);
    if (comptime @hasDecl(T, "toWire")) return value.toWire();
    return toWire(T, value);
}

/// The counterpart of `encode`; the result owns its strings, so free it with `free`.
pub fn decode(comptime T: type, w: WireOf(T), allocator: std.mem.Allocator) !T {
    if (comptime !isNested(T)) return fieldFromWire(T, w, allocator);
    if (comptime @hasDecl(T, "fromWire")) return T.fromWire(w, allocator);
    return fromWire(T, w, allocator);
}

pub fn free(comptime T: type, value: *T, allocator: std.mem.Allocator) void {
    if (comptime !isNested(T)) return freeField(T, value, null, allocator);
    if (comptime @hasDecl(T, "deinit")) return value.deinit(allocator);
    deinit(T, value, allocator);
}

/// The saved type of field `name`: a section's `Wire`, a hex string for colours, or a KeyList's hex strings (see isColorField/isKeyField).
pub fn FieldWire(comptime T: type, comptime name: []const u8) type {
    if (isNested(T)) return T.Wire;
    if (OptionalNested(T)) |N| return ?N.Wire;
    if (ListItem(T)) |Item| return []const WireOf(Item);
    if (isColorField(name)) {
        if (T == u32) return Argb;
        if (T == ?u32) return ?Argb;
        @compileError("colour field '" ++ name ++ "' must be u32 or ?u32, found " ++ @typeName(T));
    }
    if (T == KeyList) return ?KeyListWire;
    if (isKeyField(name) and (T == u32 or T == ?u32)) @compileError("key field '" ++ name ++ "' must be a KeyList");
    return T;
}

/// Borrows rather than allocates, so it only takes lists whose items are already their saved form (e.g. names).
pub fn fieldToWire(comptime T: type, comptime name: []const u8, value: T) FieldWire(T, name) {
    if (comptime isNested(T)) return encode(T, value);
    if (comptime OptionalNested(T)) |N| return if (value) |v| encode(N, v) else null;
    if (comptime ListItem(T)) |Item| {
        if (WireOf(Item) != Item) @compileError(name ++ "'s items have their own saved form, so save it with toWireAlloc");
        return value.items;
    }
    return switch (FieldWire(T, name)) {
        Argb => .{ .value = value },
        ?Argb => if (value) |v| .{ .value = v } else null,
        ?KeyListWire => if (value.isEmpty()) null else .{ .value = value },
        else => value,
    };
}

fn plainFromWire(comptime T: type, value: anytype) T {
    return switch (@TypeOf(value)) {
        Argb => value.value,
        ?Argb => if (value) |v| v.value else null,
        ?KeyListWire => if (value) |v| v.value else .empty,
        else => value,
    };
}

/// Allocates list conversions from `allocator`, an arena freed once the result is serialized.
fn fieldToWireAlloc(comptime T: type, comptime name: []const u8, allocator: std.mem.Allocator, value: T) !FieldWire(T, name) {
    if (comptime ListItem(T)) |Item| return encodeList(Item, allocator, value.items);
    return fieldToWire(T, name, value);
}

/// Copies strings, so the result owns its memory independently of `w_value`.
pub fn fieldFromWire(comptime T: type, w_value: anytype, allocator: std.mem.Allocator) !T {
    if (comptime isNested(T)) return decode(T, w_value, allocator);
    if (comptime OptionalNested(T)) |N| return if (w_value) |v| try decode(N, v, allocator) else null;
    if (comptime ListItem(T)) |Item| {
        var list: T = .empty;
        errdefer freeList(Item, &list, allocator);
        try decodeList(Item, &list, allocator, w_value);
        return list;
    }
    if (T == []const u8) return try allocator.dupe(u8, w_value);
    if (T == ?[]const u8) return if (w_value) |s| try allocator.dupe(u8, s) else null;
    return plainFromWire(T, w_value);
}

/// Frees what `fieldFromWire` allocated; `default` is the field's default, which a string may still point at.
pub fn freeField(comptime T: type, value: *T, default: ?T, allocator: std.mem.Allocator) void {
    if (comptime isNested(T)) {
        free(T, value, allocator);
    } else if (comptime OptionalNested(T)) |N| {
        if (value.*) |*v| free(N, v, allocator);
    } else if (comptime ListItem(T)) |Item| {
        freeList(Item, value, allocator);
    } else if (T == []const u8) {
        freeOwnedString(allocator, value.*, default orelse "");
    } else if (T == ?[]const u8) {
        if (value.*) |s| allocator.free(s);
    }
}

/// `R`'s saved fields with the same names, order and defaults, colours and key codes as hex strings.
pub fn Wire(comptime R: type) type {
    return comptime blk: {
        const fields = savedFields(R);
        // Converting nested defaults (e.g. every notification type's settings) all counts against one budget; this is only a runaway-loop ceiling.
        @setEvalBranchQuota(10_000_000);
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attrs: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (fields, 0..) |f, i| {
            const W = FieldWire(f.type, f.name);
            const wire_default: W = if (hasWireDefault(R, f.name)) @field(R.wire_defaults, f.name) else if (ListItem(f.type) != null) &.{} else field_default: {
                const default = f.defaultValue() orelse @compileError(@typeName(R) ++ "." ++ f.name ++ " needs a default value to be saved");
                // deinit frees any non-null optional string, so a literal default would be freed.
                if (f.type == ?[]const u8) {
                    if (default != null) @compileError(@typeName(R) ++ "." ++ f.name ++ " must default to null");
                }
                break :field_default fieldToWire(f.type, f.name, default);
            };
            names[i] = f.name;
            types[i] = W;
            attrs[i] = .{ .default_value_ptr = @ptrCast(&wire_default) };
        }
        break :blk @Struct(.auto, null, &names, &types, &attrs);
    };
}

/// The generated `encode` for `R`; borrows `value`'s strings, so the result must not outlive it.
pub fn toWire(comptime R: type, value: R) Wire(R) {
    const W = Wire(R);
    var out: W = undefined;
    inline for (comptime savedFields(R)) |f| {
        @field(out, f.name) = fieldToWire(f.type, f.name, @field(value, f.name));
    }
    return out;
}

/// For types with lists of sections or maps; allocate from an arena freed once the result is serialized.
pub fn toWireAlloc(comptime R: type, allocator: std.mem.Allocator, value: *const R) !Wire(R) {
    const W = Wire(R);
    var out: W = undefined;
    inline for (comptime savedFields(R)) |f| {
        @field(out, f.name) = try fieldToWireAlloc(f.type, f.name, allocator, @field(value, f.name));
    }
    return out;
}

/// The generated `decode` for `R`: copies every string, so the result owns its memory independently of `w`.
pub fn fromWire(comptime R: type, w: Wire(R), allocator: std.mem.Allocator) !R {
    var out: R = .{};
    errdefer deinit(R, &out, allocator);
    try fromWireInto(R, w, allocator, &out);
    return out;
}

/// `out` must still hold its defaults; on failure it holds only what loaded, so `deinit` frees it.
pub fn fromWireInto(comptime R: type, w: Wire(R), allocator: std.mem.Allocator, out: *R) !void {
    inline for (comptime savedFields(R)) |f| {
        @field(out, f.name) = try fieldFromWire(f.type, @field(w, f.name), allocator);
    }
}

/// Skips strings still pointing at their default literal.
pub fn deinit(comptime R: type, value: *R, allocator: std.mem.Allocator) void {
    inline for (comptime savedFields(R)) |f| {
        freeField(f.type, &@field(value, f.name), f.defaultValue(), allocator);
    }
}

/// Borrows each item's strings like `encode`, so allocate from an arena freed once the result is serialized.
pub fn encodeList(comptime T: type, allocator: std.mem.Allocator, items: []const T) ![]const WireOf(T) {
    const out = try allocator.alloc(WireOf(T), items.len);
    for (items, out) |item, *w| w.* = encode(T, item);
    return out;
}

/// Appends a decoded copy of each of `wires`; on failure `list` holds only the items fully decoded so far.
pub fn decodeList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, wires: []const WireOf(T)) !void {
    try list.ensureUnusedCapacity(allocator, wires.len);
    for (wires) |w| list.appendAssumeCapacity(try decode(T, w, allocator));
}

/// Leaves `list` empty, so it can be refilled or freed again.
pub fn freeList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator) void {
    for (list.items) |*item| free(T, item, allocator);
    list.deinit(allocator);
    list.* = .empty;
}

/// Unlike an encode/decode round trip, keeps state a type's `toWire` leaves out (a temporary group's members).
pub fn clone(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    if (comptime !isNested(T)) return cloneField(T, value, allocator);
    if (comptime @hasDecl(T, "clone")) return value.clone(allocator);
    var out: T = .{};
    errdefer free(T, &out, allocator);
    try cloneInto(T, &value, allocator, &out);
    return out;
}

/// `out` must still hold its defaults; on failure it holds only what was copied, so `deinit` frees it.
/// Runtime fields are copied too when they hold no pointers (a list item's id); the caller sets the rest.
pub fn cloneInto(comptime R: type, value: *const R, allocator: std.mem.Allocator, out: *R) !void {
    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (comptime isSaved(R, f.name)) {
            @field(out, f.name) = try cloneField(f.type, @field(value, f.name), allocator);
        } else if (comptime !hasPointers(f.type)) {
            @field(out, f.name) = @field(value, f.name);
        }
    }
}

fn cloneField(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    if (comptime isNested(T)) return clone(T, value, allocator);
    if (comptime OptionalNested(T)) |N| return if (value) |v| try clone(N, v, allocator) else null;
    if (comptime ListItem(T)) |Item| {
        var list: T = .empty;
        errdefer freeList(Item, &list, allocator);
        try list.ensureTotalCapacity(allocator, value.items.len);
        for (value.items) |item| list.appendAssumeCapacity(try cloneField(Item, item, allocator));
        return list;
    }
    // Empty stays a literal, which freeOwnedString skips.
    if (T == []const u8) return if (value.len == 0) "" else try allocator.dupe(u8, value);
    if (T == ?[]const u8) return if (value) |s| try allocator.dupe(u8, s) else null;
    if (comptime hasPointers(T)) @compileError(@typeName(T) ++ " holds pointers, so it needs its own clone to avoid sharing them");
    return value;
}

pub fn hasPointers(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => return true,
        .optional => |o| return hasPointers(o.child),
        .array => |a| return hasPointers(a.child),
        inline .@"struct", .@"union" => |info| {
            inline for (info.fields) |f| {
                if (hasPointers(f.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Parses `json_text` into `T` via std.json.Value, since Argb and KeyListWire only implement jsonParseFromValue.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(T) {
    const tree = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer tree.deinit();
    return std.json.parseFromValue(T, allocator, tree.value, .{ .ignore_unknown_fields = true });
}

/// The indented JSON of `settings.toWire(arena)`, as saved to disk; caller owns the result.
pub fn toJsonAlloc(allocator: std.mem.Allocator, settings: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const saved = try settings.toWire(arena.allocator());
    return std.json.Stringify.valueAlloc(allocator, saved, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

/// One log call per JSON line, since the logger silently drops any single write over 2048 bytes.
pub fn logJson(allocator: std.mem.Allocator, settings: anytype) void {
    const json = toJsonAlloc(allocator, settings) catch |err| {
        slog.warn("Failed to serialize {s} for logging: {}", .{ @typeName(@TypeOf(settings.*)), err });
        return;
    };
    defer allocator.free(json);

    var lines = std.mem.splitScalar(u8, json, '\n');
    while (lines.next()) |line| slog.debug("{s}", .{line});
}

fn freeOwnedString(allocator: std.mem.Allocator, s: []const u8, default: []const u8) void {
    if (s.len != 0 and s.ptr != default.ptr) allocator.free(s);
}

const testing = std.testing;

test "parseHexColor reads 0x, # and bare hex" {
    try testing.expectEqual(@as(u32, 0xFF112233), try parseHexColor("0xFF112233"));
    try testing.expectEqual(@as(u32, 0xFF112233), try parseHexColor("0Xff112233"));
    try testing.expectEqual(@as(u32, 0x112233), try parseHexColor("#112233"));
    try testing.expectEqual(@as(u32, 0xABC), try parseHexColor("abc"));
}

test "parseHexColor rejects short and non-hex input" {
    try testing.expectError(error.InvalidColorFormat, parseHexColor("ab"));
    try testing.expectError(error.InvalidColorFormat, parseHexColor("0x"));
    try testing.expectError(error.InvalidColorFormat, parseHexColor("0xZZZ"));
    try testing.expectError(error.InvalidColorFormat, parseHexColor("0x1FFFFFFFF"));
}

test "isColorField and isKeyField recognise fields by name" {
    try testing.expect(isColorField("borderColor") and isColorField("color"));
    try testing.expect(!isColorField("colour") and !isColorField("colorMode"));
    try testing.expect(isKeyField("hotkeyMinimizeAll") and isKeyField("cycleForwardKey"));
    try testing.expect(!isKeyField("keyboardLayout") and !isKeyField("monkey"));
}
