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

/// Lists merged item by item, matching on this field; characters and hotkey groups keep their ids, the others are replaced whole.
const MERGED_LISTS = [_]struct { []const u8, []const u8 }{
    .{ "characters", "name" },
    .{ "hotkeyGroups", "name" },
    .{ "systemColors", "systemName" },
    .{ "windowFilters", "name" },
};

/// A translation key and its parameters, which the config dialog puts into words.
pub const Text = struct {
    key: []const u8,
    params: []const Param = &.{},

    pub fn jsonStringify(self: Text, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("key");
        try jw.write(self.key);
        try jw.objectField("params");
        try jw.beginObject();
        for (self.params) |param| {
            try jw.objectField(param.name);
            if (param.translate) try jw.write(.{ .t = param.value }) else try jw.write(param.value);
        }
        try jw.endObject();
        try jw.endObject();
    }
};

/// A part of a settings file the user can choose to import; `available` is false when the file has nothing for it.
pub const Section = struct {
    id: []const u8,
    title: []const u8,
    hint: Text,
    available: bool,
};

/// `translate` marks `value` as a translation key of its own, e.g. the label of the hotkey a note is about.
pub const Param = struct { name: []const u8, value: []const u8, translate: bool = false };

pub const Draft = struct {
    arena: std.mem.Allocator,
    root: ObjectMap = .empty,
    notes: std.ArrayList(Text) = .empty,

    pub fn init(arena: std.mem.Allocator) Draft {
        return .{ .arena = arena };
    }

    pub fn note(self: *Draft, key: []const u8, params: []const Param) !void {
        try self.notes.append(self.arena, .{ .key = key, .params = try self.arena.dupe(Param, params) });
    }

    /// Copies `params`, which callers build on the stack.
    pub fn text(self: *Draft, key: []const u8, params: []const Param) !Text {
        return .{ .key = key, .params = try self.arena.dupe(Param, params) };
    }

    pub fn countText(self: *Draft, key: []const u8, n: usize) !Text {
        return self.text(key, &.{.{ .name = "n", .value = try self.format(n) }});
    }

    pub fn noteCount(self: *Draft, key: []const u8, name: []const u8, n: usize) !void {
        try self.note(key, &.{.{ .name = name, .value = try self.format(n) }});
    }

    pub fn format(self: *Draft, n: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{d}", .{n});
    }

    /// Sets a field by its dotted path, e.g. "thumbnail.borderWidth".
    pub fn set(self: *Draft, path: []const u8, value: Value) !void {
        try setIn(self.arena, &self.root, path, value);
    }

    pub fn setNumber(self: *Draft, path: []const u8, n: ?f64) !void {
        if (n) |v| try self.set(path, values.numberValue(v));
    }

    pub fn setBool(self: *Draft, path: []const u8, b: ?bool) !void {
        if (b) |v| try self.set(path, .{ .bool = v });
    }

    pub fn setString(self: *Draft, path: []const u8, s: ?[]const u8) !void {
        if (s) |v| try self.set(path, .{ .string = v });
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

    /// The character's entry in the draft, added the first time it's named.
    /// Valid until the next item is added.
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
        if (!entry.found_existing) entry.value_ptr.* = .{ .array = std.json.Array.init(self.arena) };
        return &entry.value_ptr.array;
    }

    pub fn itemCount(self: *Draft, list_name: []const u8) usize {
        const entry = self.root.get(list_name) orelse return 0;
        return if (entry == .array) entry.array.items.len else 0;
    }

    pub fn put(self: *Draft, fields: *ObjectMap, path: []const u8, value: Value) !void {
        try setIn(self.arena, fields, path, value);
    }
};

fn setIn(arena: std.mem.Allocator, root: *ObjectMap, path: []const u8, value: Value) !void {
    var node = root;
    var it = std.mem.splitScalar(u8, path, '.');
    var key = it.next().?;
    while (it.next()) |next| : (key = next) {
        const entry = try node.getOrPut(arena, key);
        if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
        node = &entry.value_ptr.object;
    }
    try node.put(arena, key, value);
}

/// `value` in its saved shape (plus each keyed list item's id), for merging.
pub fn toValue(arena: std.mem.Allocator, comptime T: type, value: *const T, path: []const Value) !Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try patch.writeAt(&jw, T, value, path);
    return std.json.parseFromSliceLeaky(Value, arena, out.written(), .{});
}

/// The ops that bring `draft` into `doc`: fields are set, and list items are matched by name (case-insensitively), updated or added.
/// An untouched, unnamed placeholder the dialog seeds into an empty list goes once the import names real entries.
pub fn toOps(arena: std.mem.Allocator, draft: *const Draft, doc: *const Config) ![]const patch.Op {
    var ops: std.ArrayList(patch.Op) = .empty;
    var it = draft.root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (mergedListKey(key)) |key_field| {
            if (value != .array) continue;
            const existing = try toValue(arena, Config, doc, &.{.{ .string = key }});
            if (std.mem.eql(u8, key, "characters") or std.mem.eql(u8, key, "hotkeyGroups")) {
                try keyedListOps(arena, &ops, key, key_field, existing.array.items, value.array.items);
            } else {
                try ops.append(arena, try setOp(arena, &.{key}, try mergedList(arena, key_field, existing.array.items, value.array.items)));
            }
        } else {
            try fieldOps(arena, &ops, &.{key}, value);
        }
    }
    return ops.items;
}

fn mergedListKey(name: []const u8) ?[]const u8 {
    for (MERGED_LISTS) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

/// A section is gone into field by field; anything else, including a small struct like a position, is set whole.
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
            const id = entry.object.get("id").?.integer;
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
        const id = target.object.get("id").?;
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
    var out = std.json.Array.init(arena);
    const drop_placeholders = namesAny(incoming, key_field);
    for (existing) |entry| {
        if (drop_placeholders and isPlaceholder(entry, key_field)) continue;
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
    if (base) |b| {
        if (b == .object) {
            var it = b.object.iterator();
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
        const id = item.object.get("id").?.integer;
        if (std.mem.indexOfScalar(i64, skip_ids, id) != null) continue;
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
