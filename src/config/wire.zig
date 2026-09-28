//! Generates each settings struct's saved JSON shape, loading, saving, freeing and preview patching from its fields.
const std = @import("std");
const vk = @import("../platform/virtual_keys.zig");
const log = @import("../log.zig");
const slog = log.scoped("config");

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

/// Saved as e.g. "0x1B"; loading also accepts combos like "Ctrl+F9" from hand-edited profiles.
pub const VkCode = struct {
    value: u32,

    pub fn jsonStringify(self: VkCode, jw: anytype) !void {
        var buf: [10]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "0x{X:0>2}", .{self.value}) catch unreachable;
        try jw.write(s);
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !VkCode {
        // Same constraint as Argb.jsonParseFromValue above: an unparseable key maps to UnexpectedToken.
        if (source != .string) return error.UnexpectedToken;
        const parsed = vk.parseVirtualKey(source.string) orelse return error.UnexpectedToken;
        return .{ .value = parsed };
    }
};

/// String-to-string map, serialized as a JSON object (used for characterIdMap).
pub const StringMap = struct {
    entries: []const Entry = &.{},

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn jsonStringify(self: StringMap, jw: anytype) !void {
        try jw.beginObject();
        for (self.entries) |e| {
            try jw.objectField(e.key);
            try jw.write(e.value);
        }
        try jw.endObject();
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !StringMap {
        if (source != .object) return .{};
        const entries = try allocator.alloc(Entry, source.object.count());
        var it = source.object.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            if (entry.value_ptr.* != .string) return error.UnexpectedToken;
            // Copied, since `parse` frees the source tree before the result is used.
            entries[i] = .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try allocator.dupe(u8, entry.value_ptr.string) };
        }
        return .{ .entries = entries };
    }
};

/// A `u32`/`?u32` field whose name ends in "color"/"Color" is an ARGB colour, saved as a hex string.
fn isColorField(comptime name: []const u8) bool {
    // Compared by hand: std.mem.endsWith costs enough comptime branches to matter across every nested field.
    if (name.len < 5) return false;
    const tail = name[name.len - 5 ..];
    return (tail[0] == 'c' or tail[0] == 'C') and tail[1] == 'o' and tail[2] == 'l' and tail[3] == 'o' and tail[4] == 'r';
}

/// A `u32`/`?u32` field named "hotkey…" or "…Key" is a virtual-key code, saved as a hex string.
fn isKeyField(comptime name: []const u8) bool {
    if (name.len >= 6 and name[0] == 'h' and name[1] == 'o' and name[2] == 't' and name[3] == 'k' and name[4] == 'e' and name[5] == 'y') return true;
    return name.len >= 3 and name[name.len - 3] == 'K' and name[name.len - 2] == 'e' and name[name.len - 1] == 'y';
}

/// Generated or hand-written, a type with a `Wire` saves, loads, frees and patches itself.
fn isNested(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Wire");
}

/// The section type inside an optional nested section, e.g. CharacterConfig's `?CharacterBorderColorsConfig`.
fn OptionalNested(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .optional or !isNested(info.optional.child)) return null;
    return info.optional.child;
}

/// The item type of a `std.ArrayList` field, which is saved as a JSON array.
fn ListItem(comptime T: type) ?type {
    if (@typeInfo(T) != .@"struct" or !@hasField(T, "items") or !@hasField(T, "capacity")) return null;
    const Item = @typeInfo(@FieldType(T, "items")).pointer.child;
    return if (T == std.ArrayList(Item)) Item else null;
}

/// A string-to-string map field, which is saved as a JSON object (see StringMap).
fn isStringMap(comptime T: type) bool {
    return T == std.StringHashMap([]const u8);
}

/// A field named in `R.runtime_fields` (an allocator, a mutex) only exists while the app runs and isn't saved.
fn isSaved(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "runtime_fields")) return true;
    inline for (R.runtime_fields) |runtime| {
        if (comptime std.mem.eql(u8, runtime, name)) return false;
    }
    return true;
}

/// A field in `R.wire_defaults` loads with that default when its key is missing, for defaults a runtime field can't hold (e.g. a non-empty list).
fn hasWireDefault(comptime R: type, comptime name: []const u8) bool {
    if (!@hasDecl(R, "wire_defaults")) return false;
    return @hasField(@TypeOf(R.wire_defaults), name);
}

fn savedFields(comptime R: type) []const std.builtin.Type.StructField {
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

/// The saved type of field `name`: a section's `Wire`, or a hex string for colours and key codes (see isColorField/isKeyField).
pub fn FieldWire(comptime T: type, comptime name: []const u8) type {
    if (isNested(T)) return T.Wire;
    if (OptionalNested(T)) |N| return ?N.Wire;
    if (ListItem(T)) |Item| return []const WireOf(Item);
    if (isStringMap(T)) return StringMap;
    if (isColorField(name)) {
        if (T == u32) return Argb;
        if (T == ?u32) return ?Argb;
        @compileError("colour field '" ++ name ++ "' must be u32 or ?u32, found " ++ @typeName(T));
    }
    if (isKeyField(name)) {
        if (T == u32) return VkCode;
        if (T == ?u32) return ?VkCode;
    }
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
    if (comptime isStringMap(T)) @compileError(name ++ " is a map, so save it with toWireAlloc");
    return switch (FieldWire(T, name)) {
        Argb, VkCode => .{ .value = value },
        ?Argb, ?VkCode => if (value) |v| .{ .value = v } else null,
        else => value,
    };
}

fn plainFromWire(comptime T: type, value: anytype) T {
    return switch (@TypeOf(value)) {
        Argb, VkCode => value.value,
        ?Argb, ?VkCode => if (value) |v| v.value else null,
        else => value,
    };
}

/// Allocates list and map conversions from `allocator`, an arena freed once the result is serialized.
fn fieldToWireAlloc(comptime T: type, comptime name: []const u8, allocator: std.mem.Allocator, value: T) !FieldWire(T, name) {
    if (comptime ListItem(T)) |Item| return encodeList(Item, allocator, value.items);
    if (comptime isStringMap(T)) {
        const entries = try allocator.alloc(StringMap.Entry, value.count());
        var it = value.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) {
            entries[i] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        }
        return .{ .entries = entries };
    }
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
    if (comptime isStringMap(T)) {
        var map = T.init(allocator);
        errdefer freeStringMap(allocator, &map);
        for (w_value.entries) |entry| {
            const key = try allocator.dupe(u8, entry.key);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, entry.value);
            errdefer allocator.free(value);
            // A key repeated in the JSON keeps its last value.
            if (try map.fetchPut(key, value)) |old| {
                allocator.free(old.key);
                allocator.free(old.value);
            }
        }
        return map;
    }
    if (T == []const u8) return try allocator.dupe(u8, w_value);
    if (T == ?[]const u8) return if (w_value) |s| try allocator.dupe(u8, s) else null;
    return plainFromWire(T, w_value);
}

fn freeStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Frees what `fieldFromWire` allocated; `default` is the field's default, which a string may still point at.
pub fn freeField(comptime T: type, value: *T, default: ?T, allocator: std.mem.Allocator) void {
    if (comptime isNested(T)) {
        free(T, value, allocator);
    } else if (comptime OptionalNested(T)) |N| {
        if (value.*) |*v| free(N, v, allocator);
    } else if (comptime ListItem(T)) |Item| {
        freeList(Item, value, allocator);
    } else if (comptime isStringMap(T)) {
        freeStringMap(allocator, value);
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
            const wire_default: W = if (hasWireDefault(R, f.name)) @field(R.wire_defaults, f.name) else if (ListItem(f.type) != null) &.{} else if (isStringMap(f.type)) .{} else field_default: {
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

/// Parses `json_text` into `T` via std.json.Value, since Argb and VkCode only implement jsonParseFromValue.
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

/// Nested sections are merged, unknown keys ignored, and a malformed value is logged and skipped so it can't discard the rest.
pub fn applyPatch(comptime R: type, target: *R, obj: std.json.ObjectMap, allocator: std.mem.Allocator) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (obj.get(f.name)) |json_value| {
            if (comptime isNested(f.type)) {
                try patchNested(f.type, &@field(target, f.name), json_value, allocator);
            } else if (std.json.parseFromValueLeaky(@FieldType(Wire(R), f.name), scratch.allocator(), json_value, .{})) |wire_value| {
                if (comptime OptionalNested(f.type) != null) {
                    const replacement = try fieldFromWire(f.type, wire_value, allocator);
                    freeField(f.type, &@field(target, f.name), null, allocator);
                    @field(target, f.name) = replacement;
                } else if (f.type == []const u8) {
                    try replaceString(allocator, &@field(target, f.name), wire_value, f.defaultValue().?);
                } else if (f.type == ?[]const u8) {
                    try replaceOptionalString(allocator, &@field(target, f.name), wire_value);
                } else {
                    @field(target, f.name) = plainFromWire(f.type, wire_value);
                }
            } else |err| {
                slog.warn("Ignoring invalid {s}.{s} in preview patch: {}", .{ @typeName(R), f.name, err });
            }
        }
    }
}

/// A type with its own `applyPatch` (e.g. a keyed map) handles the value itself; otherwise it must be an object merged field by field.
fn patchNested(comptime T: type, target: *T, json_value: std.json.Value, allocator: std.mem.Allocator) !void {
    if (comptime @hasDecl(T, "applyPatch")) return T.applyPatch(target, json_value, allocator);
    if (json_value != .object) {
        slog.warn("Ignoring non-object {s} in preview patch", .{@typeName(T)});
        return;
    }
    try applyPatch(T, target, json_value.object, allocator);
}

/// Unchanged strings keep their allocation, since thumbnails and render settings borrow slices of them.
fn replaceString(allocator: std.mem.Allocator, field: *[]const u8, new_value: []const u8, default: []const u8) !void {
    if (std.mem.eql(u8, field.*, new_value)) return;
    const old = field.*;
    field.* = try allocator.dupe(u8, new_value);
    freeOwnedString(allocator, old, default);
}

fn replaceOptionalString(allocator: std.mem.Allocator, field: *?[]const u8, new_value: ?[]const u8) !void {
    const old = field.*;
    if (old == null and new_value == null) return;
    if (old != null and new_value != null and std.mem.eql(u8, old.?, new_value.?)) return;
    field.* = if (new_value) |s| try allocator.dupe(u8, s) else null;
    if (old) |s| allocator.free(s);
}
