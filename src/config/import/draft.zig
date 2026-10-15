//! What an import brings in: a partial profile in its saved shape, and notes for the user; `toOps` turns it into edit ops (see config/patch.zig) against the profile being edited.
const std = @import("std");
const config = @import("../../config.zig");
const patch = @import("../patch.zig");
const values = @import("values.zig");
const key_list = @import("../key_list.zig");

const Value = std.json.Value;
const KeyList = key_list.KeyList;
const ObjectMap = std.json.ObjectMap;
const Config = config.Config;

const MERGED_LISTS = [_]MergedList{
    .{ .name = "characters", .key_field = "name", .keeps_ids = true },
    .{ .name = "hotkeyGroups", .key_field = "name", .keeps_ids = true },
    .{ .name = "thumbnailSpaces", .key_field = "name", .keeps_ids = true },
    .{ .name = "systemColors", .key_field = "systemName", .keeps_ids = false },
    .{ .name = "windowFilters", .key_field = "name", .keeps_ids = false },
};

/// A list whose items are matched on `key_field`; one that `keeps_ids` is edited item by item, any other is replaced whole.
const MergedList = struct { name: []const u8, key_field: []const u8, keeps_ids: bool };

/// English text and its {parameters}, which the config dialog translates and fills in.
pub const Text = struct {
    key: []const u8,
    parameters: []const Parameter = &.{},

    pub fn jsonStringify(self: Text, json_writer: anytype) !void {
        try json_writer.beginObject();
        try json_writer.objectField("key");
        try json_writer.write(self.key);
        try json_writer.objectField("params");
        try json_writer.beginObject();
        for (self.parameters) |parameter| {
            try json_writer.objectField(parameter.name);
            if (parameter.should_translate) try json_writer.write(.{ .t = parameter.value }) else try json_writer.write(parameter.value);
        }
        try json_writer.endObject();
        try json_writer.endObject();
    }
};

/// A part of a settings file the user can choose to import; `available` is false when the file has nothing for it.
pub const Section = struct {
    id: []const u8,
    title: []const u8,
    hint: Text,
    available: bool,
};

/// `should_translate` marks `value` as English text to translate too, e.g. the label of the hotkey a note is about.
pub const Parameter = struct { name: []const u8, value: []const u8, should_translate: bool = false };

pub const Draft = struct {
    arena: std.mem.Allocator,
    root: ObjectMap = .empty,
    notes: std.ArrayList(Text) = .empty,
    /// Dotted paths of the file's settings that couldn't be read; shown apart from `notes`.
    skipped: std.ArrayList([]const u8) = .empty,

    pub fn init(arena: std.mem.Allocator) Draft {
        return .{ .arena = arena };
    }

    pub fn note(self: *Draft, key: []const u8, parameters: []const Parameter) !void {
        try self.notes.append(self.arena, .{ .key = key, .parameters = try self.arena.dupe(Parameter, parameters) });
    }

    /// Copies `parameters`, which callers build on the stack.
    pub fn text(self: *const Draft, key: []const u8, parameters: []const Parameter) !Text {
        return .{ .key = key, .parameters = try self.arena.dupe(Parameter, parameters) };
    }

    pub fn countText(self: *const Draft, key: []const u8, item_count: usize) !Text {
        return self.text(key, &.{.{ .name = "n", .value = try self.format(item_count) }});
    }

    pub fn noteCount(self: *Draft, key: []const u8, name: []const u8, item_count: usize) !void {
        try self.note(key, &.{.{ .name = name, .value = try self.format(item_count) }});
    }

    /// `number` is any integer or float.
    pub fn format(self: *const Draft, number: anytype) ![]const u8 {
        return self.arena.print("{d}", .{number});
    }

    /// Sets a field by its dotted path, e.g. "thumbnail.borderWidth".
    pub fn set(self: *Draft, path: []const u8, value: Value) !void {
        try setIn(self.arena, &self.root, path, value);
    }

    pub fn setNumber(self: *Draft, path: []const u8, value: ?f64) !void {
        if (value) |v| try self.set(path, values.numberValue(v));
    }

    pub fn setBool(self: *Draft, path: []const u8, value: ?bool) !void {
        if (value) |v| try self.set(path, .{ .bool = v });
    }

    pub fn setString(self: *Draft, path: []const u8, value: ?[]const u8) !void {
        if (value) |v| try self.set(path, .{ .string = v });
    }

    pub fn setColor(self: *Draft, path: []const u8, color: ?u32) !void {
        if (color) |c| try self.set(path, try values.colorValue(self.arena, c));
    }

    pub fn setKeys(self: *Draft, path: []const u8, keys: KeyList) !void {
        if (!keys.isEmpty()) try self.set(path, try values.keysValue(self.arena, keys));
    }

    /// Older tools had one overlay font, which here each overlay text has its own of.
    pub fn setOverlayFont(self: *Draft, name: ?[]const u8, size: ?f64) !void {
        inline for (.{ "thumbnail.characterName", "thumbnail.systemName", "thumbnail.quickGroupBadge" }) |prefix| {
            try self.setString(prefix ++ "FontName", name);
            try self.setNumber(prefix ++ "FontSize", size);
        }
        try self.setString("thumbnail.notifications.font_name", name);
        try self.setNumber("thumbnail.notifications.font_size", size);
    }

    /// The character's entry in the draft, added the first time it's named; valid until the next item is added.
    pub fn character(self: *Draft, name: []const u8) !*ObjectMap {
        return self.item("characters", "name", name);
    }

    /// A list item by its key field, added the first time it's named.
    pub fn item(self: *Draft, list_name: []const u8, key_field: []const u8, key: []const u8) !*ObjectMap {
        const list = try self.listNamed(list_name);
        for (list.items) |*entry| {
            const existing = entry.object.get(key_field) orelse continue;
            if (existing == .string and std.mem.eql(u8, existing.string, key)) return &entry.object;
        }
        var fields: ObjectMap = .empty;
        try fields.put(self.arena, key_field, .{ .string = key });
        try list.append(.{ .object = fields });
        return &list.items[list.items.len - 1].object;
    }

    fn listNamed(self: *Draft, name: []const u8) !*std.json.Array {
        const entry = try self.root.getOrPut(self.arena, name);
        if (!entry.found_existing) entry.value_ptr.* = .{ .array = .init(self.arena) };
        return &entry.value_ptr.array;
    }

    pub fn put(self: *Draft, fields: *ObjectMap, path: []const u8, value: Value) !void {
        try setIn(self.arena, fields, path, value);
    }
};

pub fn isChosen(chosen: []const []const u8, id: []const u8) bool {
    for (chosen) |chosen_id| {
        if (std.mem.eql(u8, chosen_id, id)) return true;
    }
    return false;
}

/// `value` in its saved shape (plus each keyed list item's id), for merging.
pub fn toValue(arena: std.mem.Allocator, comptime T: type, value: *const T, path: []const Value) !Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json_writer: std.json.Stringify = .{ .writer = &out.writer };
    try patch.writeAt(&json_writer, T, value, path);
    return std.json.parseFromSliceLeaky(Value, arena, out.written(), .{});
}

/// The ops that bring `draft` into `doc`, matching list items by name (case-insensitively) and dropping the dialog's untouched placeholder once real entries arrive.
pub fn toOps(arena: std.mem.Allocator, draft: *const Draft, doc: *const Config) ![]const patch.Op {
    var ops: std.ArrayList(patch.Op) = .empty;
    var it = draft.root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (findMergedList(key)) |merged| {
            if (value != .array) continue;
            const existing = try toValue(arena, Config, doc, &.{.{ .string = key }});
            if (merged.keeps_ids) {
                try keyedListOps(arena, &ops, key, merged.key_field, existing.array.items, value.array.items);
            } else {
                try ops.append(arena, try setOp(arena, &.{key}, try mergedList(arena, merged.key_field, existing.array.items, value.array.items)));
            }
        } else {
            try fieldOps(arena, &ops, &.{key}, value);
        }
    }
    return ops.items;
}

fn setIn(arena: std.mem.Allocator, root: *ObjectMap, path: []const u8, value: Value) !void {
    var node = root;
    var it = std.mem.splitScalar(u8, path, '.');
    var key = it.first();
    while (it.next()) |next| : (key = next) {
        const entry = try node.getOrPut(arena, key);
        if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
        node = &entry.value_ptr.object;
    }
    try node.put(arena, key, value);
}

fn findMergedList(name: []const u8) ?MergedList {
    for (MERGED_LISTS) |merged| {
        if (std.mem.eql(u8, merged.name, name)) return merged;
    }
    return null;
}

/// Sections are set field by field; anything else, even a small struct, whole.
fn fieldOps(arena: std.mem.Allocator, ops: *std.ArrayList(patch.Op), path: []const []const u8, value: Value) !void {
    if (value != .object or !patch.isSection(Config, path)) return ops.append(arena, try setOp(arena, path, value));
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const child = try arena.alloc([]const u8, path.len + 1);
        @memcpy(child[0..path.len], path);
        child[path.len] = entry.key_ptr.*;
        try fieldOps(arena, ops, child, entry.value_ptr.*);
    }
}

fn setOp(arena: std.mem.Allocator, names: []const []const u8, value: Value) !patch.Op {
    const path = try arena.alloc(Value, names.len);
    for (names, path) |name, *segment| segment.* = .{ .string = name };
    return .{ .op = "set", .path = path, .value = value };
}

fn keyedListOps(arena: std.mem.Allocator, ops: *std.ArrayList(patch.Op), list_name: []const u8, key_field: []const u8, existing: []const Value, incoming: []const Value) !void {
    var removed: std.ArrayList(i64) = .empty;
    if (namesAny(incoming, key_field)) {
        for (existing) |entry| {
            if (!isPlaceholder(entry, key_field)) continue;
            const id = (entry.object.get("id") orelse continue).integer;
            try removed.append(arena, id);
            const path = try arena.dupe(Value, &.{ .{ .string = list_name }, .{ .integer = id } });
            try ops.append(arena, .{ .op = "remove", .path = path });
        }
    }

    for (incoming) |item| {
        const key = keyOf(item, key_field) orelse continue;
        const match = findByKey(existing, key_field, key, removed.items);
        const target = match orelse {
            try ops.append(arena, .{ .op = "insert", .path = try arena.dupe(Value, &.{.{ .string = list_name }}), .value = try withoutId(arena, item) });
            continue;
        };
        const id = target.object.get("id") orelse continue;
        var it = item.object.iterator();
        while (it.next()) |field| {
            const name = field.key_ptr.*;
            if (std.mem.eql(u8, name, key_field) or std.mem.eql(u8, name, "id")) continue;
            // A nested setting such as borderColors takes the fields the import names on top of those already set.
            const value = if (field.value_ptr.* == .object)
                try overlay(arena, target.object.get(name), field.value_ptr.*)
            else
                field.value_ptr.*;
            const path = try arena.dupe(Value, &.{ .{ .string = list_name }, id, .{ .string = name } });
            try ops.append(arena, .{ .op = "set", .path = path, .value = value });
        }
    }
}

/// The existing list with each incoming item merged over the one of the same name, or added.
fn mergedList(arena: std.mem.Allocator, key_field: []const u8, existing: []const Value, incoming: []const Value) !Value {
    var out: std.json.Array = .init(arena);
    const should_drop_placeholders = namesAny(incoming, key_field);
    for (existing) |entry| {
        if (should_drop_placeholders and isPlaceholder(entry, key_field)) continue;
        try out.append(entry);
    }
    for (incoming) |item| {
        const key = keyOf(item, key_field) orelse continue;
        const index: ?usize = for (out.items, 0..) |entry, i| {
            const name = keyOf(entry, key_field) orelse continue;
            if (std.ascii.eqlIgnoreCase(name, key)) break i;
        } else null;
        if (index) |i| out.items[i] = try overlay(arena, out.items[i], item) else try out.append(item);
    }
    return .{ .array = out };
}

fn overlay(arena: std.mem.Allocator, base: ?Value, top: Value) !Value {
    var fields: ObjectMap = .empty;
    if (base) |base_value| {
        if (base_value == .object) {
            var it = base_value.object.iterator();
            while (it.next()) |entry| try fields.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    var it = top.object.iterator();
    while (it.next()) |entry| try fields.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    return .{ .object = fields };
}

fn withoutId(arena: std.mem.Allocator, item: Value) !Value {
    var copy = try overlay(arena, null, item);
    _ = copy.object.orderedRemove("id");
    return copy;
}

fn keyOf(item: Value, key_field: []const u8) ?[]const u8 {
    if (item != .object) return null;
    const key = item.object.get(key_field) orelse return null;
    if (key != .string) return null;
    const trimmed = std.mem.trim(u8, key.string, " \t");
    return if (trimmed.len == 0) null else trimmed;
}

fn namesAny(items: []const Value, key_field: []const u8) bool {
    for (items) |item| {
        if (keyOf(item, key_field) != null) return true;
    }
    return false;
}

fn findByKey(items: []const Value, key_field: []const u8, key: []const u8, skip_ids: []const i64) ?Value {
    for (items) |item| {
        const name = keyOf(item, key_field) orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, key)) continue;
        const id = (item.object.get("id") orelse continue).integer;
        if (std.mem.findScalar(i64, skip_ids, id) != null) continue;
        return item;
    }
    return null;
}

/// Unnamed, with every other field empty: what the dialog seeds so an empty list has a row to edit.
fn isPlaceholder(item: Value, key_field: []const u8) bool {
    if (item != .object or keyOf(item, key_field) != null) return false;
    var it = item.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, key_field) or std.mem.eql(u8, name, "id")) continue;
        switch (entry.value_ptr.*) {
            .null => {},
            .bool => |b| if (b) return false,
            .string => |s| if (s.len > 0) return false,
            .array => |a| if (a.items.len > 0) return false,
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;

fn parseTestJson(arena: std.mem.Allocator, text: []const u8) ![]const Value {
    return (try std.json.parseFromSliceLeaky(Value, arena, text, .{})).array.items;
}

test "mergedList overlays an item of the same name, ignoring case, and appends new ones" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const existing = try parseTestJson(arena, "[{\"systemName\":\"Jita\",\"color\":\"0xFF000000\"}]");
    const incoming = try parseTestJson(arena, "[{\"systemName\":\"jita\",\"color\":\"0xFFFFFFFF\"},{\"systemName\":\"Amarr\"}]");
    const merged = try mergedList(arena, "systemName", existing, incoming);
    try testing.expectEqual(@as(usize, 2), merged.array.items.len);
    try testing.expectEqualStrings("0xFFFFFFFF", merged.array.items[0].object.get("color").?.string);
    try testing.expectEqualStrings("Amarr", merged.array.items[1].object.get("systemName").?.string);
}

test "mergedList drops an unnamed placeholder once the import names real entries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const existing = try parseTestJson(arena, "[{\"name\":\"\",\"executable\":\"\",\"enabled\":false}]");
    const incoming = try parseTestJson(arena, "[{\"name\":\"Discord\"}]");
    const merged = try mergedList(arena, "name", existing, incoming);
    try testing.expectEqual(@as(usize, 1), merged.array.items.len);
    try testing.expectEqualStrings("Discord", merged.array.items[0].object.get("name").?.string);
}

test "isPlaceholder needs an empty name and every other field empty" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = try parseTestJson(arena, "[{\"name\":\"\",\"id\":3,\"enabled\":false},{\"name\":\"\",\"enabled\":true},{\"name\":\"Pilot\"}]");
    try testing.expect(isPlaceholder(items[0], "name"));
    try testing.expect(!isPlaceholder(items[1], "name"));
    try testing.expect(!isPlaceholder(items[2], "name"));
}
