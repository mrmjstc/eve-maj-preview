//! Edits to a settings document by path, the one way the config dialog changes settings and hears about the app's own changes.
const std = @import("std");
const wire = @import("wire.zig");
const key_list = @import("key_list.zig");

pub const Op = struct {
    /// `set` for any field; lists whose items have an `id` also take `insert`, `remove` and `move`.
    op: []const u8,
    /// Field names, with an item's `id` inside a keyed list: `["characters", 12, "opacity"]`.
    path: []const std.json.Value,
    /// Not optional: std.json would read a `null` value, which unsets a setting, as the field being absent.
    value: std.json.Value = .null,
    /// Where `insert` and `move` put the item; `insert` appends without one.
    index: ?usize = null,
};

const Kind = enum { set, insert, remove, move };

pub const Context = struct {
    /// Parsing scratch, freed after the call.
    arena: std.mem.Allocator,
    /// The document's own allocator, which owns everything an edit stores.
    allocator: std.mem.Allocator,
};

/// Main thread only, like everything that edits a document.
var g_next_id: u32 = 1;

/// Whether `path` names a section (or keyed map child) whose fields can be set one by one, rather than a value set whole.
pub fn isSection(comptime T: type, path: []const []const u8) bool {
    if (comptime isKeyedMap(T)) return path.len == 0 or isSection(ChildOf(T), path[1..]);
    if (comptime !isStruct(T)) return false;
    if (path.len == 0) return true;
    inline for (comptime wire.savedFields(T)) |f| {
        if (std.mem.eql(u8, path[0], f.name)) return isSection(comptime (OptionalStruct(f.type) orelse f.type), path[1..]);
    }
    return false;
}

/// Gives every keyed list item still at id 0 a fresh one.
pub fn assignIds(comptime T: type, value: *T) void {
    inline for (comptime wire.savedFields(T)) |f| {
        if (comptime wire.ListItem(f.type)) |Item| {
            if (comptime hasId(Item)) {
                for (@field(value, f.name).items) |*item| {
                    if (item.id == 0) item.id = nextId();
                }
            }
        } else if (comptime isStruct(f.type)) {
            assignIds(f.type, &@field(value, f.name));
        }
    }
}

/// `value` in the dialog's shape: the saved JSON plus each keyed list item's `id`.
pub fn write(json_writer: anytype, comptime T: type, value: *const T) !void {
    return writeValue(json_writer, T, "", value);
}

pub fn writeAt(json_writer: anytype, comptime T: type, target: *const T, path: []const std.json.Value) !void {
    if (path.len == 0) return write(json_writer, T, target);
    const key = try fieldKey(path[0]);
    if (comptime isKeyedMap(T)) {
        const child = target.childAtConst(key) orelse return error.MissingField;
        return writeAt(json_writer, ChildOf(T), child, path[1..]);
    } else {
        inline for (comptime wire.savedFields(T)) |f| {
            if (std.mem.eql(u8, key, f.name)) return writeFieldAt(json_writer, f.type, f.name, &@field(target, f.name), path[1..]);
        }
        return error.MissingField;
    }
}

/// The id an `insert` gave its item; validation is the caller's, once a batch is applied.
pub fn apply(comptime T: type, document: *T, op: Op, context: Context) !?u32 {
    const kind = std.meta.stringToEnum(Kind, op.op) orelse return error.InvalidOp;
    return applyIn(T, document, op.path, kind, op, context);
}

/// A keyed map (NotificationTypeConfigs) is reached by child name rather than field, and saves in its own shape.
fn isKeyedMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "childAt");
}

fn ChildOf(comptime T: type) type {
    const Return = @typeInfo(@TypeOf(T.childAt)).@"fn".return_type.?;
    return @typeInfo(@typeInfo(Return).optional.child).pointer.child;
}

fn hasId(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "id");
}

/// A struct edited field by field: a section with a generated `Wire`, or a plain one saved as its own fields (SnappingConfig, Position).
fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and wire.ListItem(T) == null and !isKeyedMap(T) and T != key_list.KeyList;
}

fn OptionalStruct(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info != .optional or !isStruct(info.optional.child)) return null;
    return info.optional.child;
}

fn nextId() u32 {
    const id = g_next_id;
    g_next_id += 1;
    return id;
}

fn writeValue(json_writer: anytype, comptime T: type, comptime name: []const u8, value: *const T) !void {
    if (comptime wire.isNested(T)) {
        if (comptime isKeyedMap(T)) return json_writer.write(wire.encode(T, value.*));
        try json_writer.beginObject();
        if (comptime hasId(T)) {
            try json_writer.objectField("id");
            try json_writer.write(value.id);
        }
        inline for (comptime wire.savedFields(T)) |f| {
            try json_writer.objectField(f.name);
            try writeValue(json_writer, f.type, f.name, &@field(value, f.name));
        }
        return json_writer.endObject();
    }
    if (comptime wire.OptionalNested(T)) |N| {
        if (value.*) |*v| return writeValue(json_writer, N, name, v);
        return json_writer.write(null);
    }
    if (comptime wire.ListItem(T)) |Item| {
        try json_writer.beginArray();
        for (value.items) |*item| try writeValue(json_writer, Item, name, item);
        return json_writer.endArray();
    }
    return json_writer.write(wire.fieldToWire(T, name, value.*));
}

fn writeFieldAt(json_writer: anytype, comptime F: type, comptime name: []const u8, field: *const F, path: []const std.json.Value) !void {
    if (path.len == 0) return writeValue(json_writer, F, name, field);
    if (comptime wire.ListItem(F)) |Item| {
        if (comptime hasId(Item)) {
            const index = try findItem(Item, field.items, path[0]);
            return writeAt(json_writer, Item, &field.items[index], path[1..]);
        } else return error.ListIsNotKeyed;
    }
    if (comptime isKeyedMap(F)) return writeAt(json_writer, F, field, path);
    if (comptime OptionalStruct(F)) |N| {
        if (field.*) |*v| return writeAt(json_writer, N, v, path);
        return json_writer.write(null);
    }
    if (comptime isStruct(F)) return writeAt(json_writer, F, field, path);
    return error.InvalidPath;
}

fn applyIn(comptime T: type, target: *T, path: []const std.json.Value, kind: Kind, op: Op, context: Context) !?u32 {
    if (path.len == 0) return error.InvalidPath;
    const key = try fieldKey(path[0]);
    if (comptime isKeyedMap(T)) {
        const child = target.childAt(key) orelse return error.MissingField;
        return applyIn(ChildOf(T), child, path[1..], kind, op, context);
    } else {
        inline for (comptime wire.savedFields(T)) |f| {
            if (std.mem.eql(u8, key, f.name)) return applyField(f.type, f.name, &@field(target, f.name), f.defaultValue(), path[1..], kind, op, context);
        }
        return error.MissingField;
    }
}

fn applyField(comptime F: type, comptime name: []const u8, field: *F, default: ?F, path: []const std.json.Value, kind: Kind, op: Op, context: Context) !?u32 {
    if (path.len == 0) {
        switch (kind) {
            .set => {
                try setValue(F, name, field, default, op.value, context);
                return null;
            },
            .insert => if (comptime wire.ListItem(F)) |Item| {
                if (comptime hasId(Item)) return try insertItem(Item, field, op, context) else return error.ListIsNotKeyed;
            } else return error.NotAList,
            .remove, .move => return error.InvalidPath,
        }
    }
    if (comptime wire.ListItem(F)) |Item| {
        if (comptime hasId(Item)) {
            const index = try findItem(Item, field.items, path[0]);
            if (path.len > 1) return applyIn(Item, &field.items[index], path[1..], kind, op, context);
            switch (kind) {
                .set => try replaceItem(Item, field, index, op.value, context),
                .remove => {
                    var removed = field.orderedRemove(index);
                    wire.free(Item, &removed, context.allocator);
                },
                .move => {
                    const to = op.index orelse return error.MissingIndex;
                    const item = field.orderedRemove(index);
                    field.insertAssumeCapacity(@min(to, field.items.len), item);
                },
                .insert => return error.InvalidPath,
            }
            return null;
        } else return error.ListIsNotKeyed;
    }
    if (comptime isKeyedMap(F)) return applyIn(F, field, path, kind, op, context);
    if (comptime OptionalStruct(F)) |N| {
        // Editing one field of an unset override starts it from the defaults, and zero where there are none (Position).
        if (field.* == null) field.* = std.mem.zeroInit(N, .{});
        return applyIn(N, &field.*.?, path, kind, op, context);
    }
    if (comptime isStruct(F)) return applyIn(F, field, path, kind, op, context);
    return error.InvalidPath;
}

fn setValue(comptime F: type, comptime name: []const u8, field: *F, default: ?F, json: std.json.Value, context: Context) !void {
    const saved = std.json.parseFromValueLeaky(wire.FieldWire(F, name), context.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    const fresh = try wire.fieldFromWire(F, saved, context.allocator);
    wire.freeField(F, field, default, context.allocator);
    field.* = fresh;
}

fn replaceItem(comptime Item: type, list: *std.ArrayList(Item), index: usize, json: std.json.Value, context: Context) !void {
    const saved = std.json.parseFromValueLeaky(wire.WireOf(Item), context.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    var fresh = try wire.decode(Item, saved, context.allocator);
    fresh.id = list.items[index].id;
    wire.free(Item, &list.items[index], context.allocator);
    list.items[index] = fresh;
}

fn insertItem(comptime Item: type, list: *std.ArrayList(Item), op: Op, context: Context) !u32 {
    const json = op.value;
    const saved = std.json.parseFromValueLeaky(wire.WireOf(Item), context.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    var fresh = try wire.decode(Item, saved, context.allocator);
    errdefer wire.free(Item, &fresh, context.allocator);
    fresh.id = nextId();
    try list.insert(context.allocator, @min(op.index orelse list.items.len, list.items.len), fresh);
    return fresh.id;
}

fn findItem(comptime Item: type, items: []const Item, key: std.json.Value) !usize {
    const id: u32 = switch (key) {
        .integer => |i| std.math.cast(u32, i) orelse return error.MissingItem,
        else => return error.InvalidPath,
    };
    for (items, 0..) |item, i| {
        if (item.id == id) return i;
    }
    return error.MissingItem;
}

fn fieldKey(segment: std.json.Value) ![]const u8 {
    return switch (segment) {
        .string => |s| s,
        else => error.InvalidPath,
    };
}

const testing = std.testing;

/// A keyed list item, like a character.
const TestItem = struct {
    name: []const u8 = "",
    opacity: u8 = 255,
    id: u32 = 0,

    pub const runtime_fields = .{"id"};
    pub const Wire = wire.Wire(TestItem);
};

const TestSection = struct {
    width: i32 = 100,
    is_enabled: bool = false,

    pub const Wire = wire.Wire(TestSection);
};

/// A plain struct saved as its own fields, like a character's Position.
const TestPosition = struct { x: i32 = 0, y: i32 = 0 };

/// Every shape apply handles but a keyed map.
const TestDocument = struct {
    title: []const u8 = "",
    section: TestSection = .{},
    position: ?TestPosition = null,
    items: std.ArrayList(TestItem) = .empty,
    tags: std.ArrayList([]const u8) = .empty,

    pub const Wire = wire.Wire(TestDocument);
};

/// A document edited the way the config window does, by JSON ops; deinit frees it, so a leaked edit fails the test.
const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    document: TestDocument = .{},

    fn init() Fixture {
        return .{ .arena_state = .init(testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        wire.deinit(TestDocument, &self.document, testing.allocator);
        self.arena_state.deinit();
    }

    /// `op_format` is an Op as JSON, formatted with `args` so a test can name an item by the id it was given.
    fn edit(self: *Fixture, comptime op_format: []const u8, args: anytype) !?u32 {
        const arena = self.arena_state.allocator();
        const op = try std.json.parseFromSliceLeaky(Op, arena, try std.fmt.allocPrint(arena, op_format, args), .{});
        return apply(TestDocument, &self.document, op, .{ .arena = arena, .allocator = testing.allocator });
    }

    /// The value at the path in `path_format`, a JSON array, in the dialog's shape.
    fn read(self: *Fixture, comptime path_format: []const u8, args: anytype) ![]const u8 {
        const arena = self.arena_state.allocator();
        const path = try std.json.parseFromSliceLeaky([]const std.json.Value, arena, try std.fmt.allocPrint(arena, path_format, args), .{});
        var out: std.Io.Writer.Allocating = .init(arena);
        var json_writer: std.json.Stringify = .{ .writer = &out.writer };
        try writeAt(&json_writer, TestDocument, &self.document, path);
        return out.written();
    }

    fn names(self: *const Fixture, buf: [][]const u8) []const []const u8 {
        for (self.document.items.items, 0..) |item, i| buf[i] = item.name;
        return buf[0..self.document.items.items.len];
    }
};

test "set replaces a string field, freeing the copy it replaces" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    _ = try fixture.edit(
        \\{{"op":"set","path":["title"],"value":"Main"}}
    , .{});
    _ = try fixture.edit(
        \\{{"op":"set","path":["title"],"value":"Alts"}}
    , .{});
    try testing.expectEqualStrings("Alts", fixture.document.title);
}

test "set edits one field of a section and leaves the others" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    _ = try fixture.edit(
        \\{{"op":"set","path":["section","width"],"value":300}}
    , .{});
    try testing.expectEqual(300, fixture.document.section.width);
    try testing.expect(!fixture.document.section.is_enabled);
}

test "set on one field of an unset optional struct starts the rest from zero, and null clears it" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    _ = try fixture.edit(
        \\{{"op":"set","path":["position","x"],"value":5}}
    , .{});
    try testing.expectEqual(TestPosition{ .x = 5, .y = 0 }, fixture.document.position.?);
    _ = try fixture.edit(
        \\{{"op":"set","path":["position"],"value":null}}
    , .{});
    try testing.expectEqual(null, fixture.document.position);
}

test "set replaces a whole list of strings" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    _ = try fixture.edit(
        \\{{"op":"set","path":["tags"],"value":["mining","pvp"]}}
    , .{});
    _ = try fixture.edit(
        \\{{"op":"set","path":["tags"],"value":["haul"]}}
    , .{});
    try testing.expectEqual(1, fixture.document.tags.items.len);
    try testing.expectEqualStrings("haul", fixture.document.tags.items[0]);
}

test "insert gives each item its own id, appending unless given an index" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const first_id = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"A"}}}}
    , .{})).?;
    const second_id = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"B"}},"index":0}}
    , .{})).?;
    try testing.expect(first_id != 0 and second_id != 0 and first_id != second_id);
    var buf: [2][]const u8 = undefined;
    try testing.expectEqualDeep(&[_][]const u8{ "B", "A" }, fixture.names(&buf));
    try testing.expectEqual(first_id, fixture.document.items.items[1].id);
}

test "an item is reached by its id, wherever it has moved" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const added = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"A"}}}}
    , .{})).?;
    _ = try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"B"}}}}
    , .{});
    _ = try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"C"}}}}
    , .{});
    _ = try fixture.edit(
        \\{{"op":"move","path":["items",{d}],"index":2}}
    , .{added});
    var buf: [3][]const u8 = undefined;
    try testing.expectEqualDeep(&[_][]const u8{ "B", "C", "A" }, fixture.names(&buf));

    _ = try fixture.edit(
        \\{{"op":"set","path":["items",{d},"opacity"],"value":100}}
    , .{added});
    try testing.expectEqual(100, fixture.document.items.items[2].opacity);
}

test "set on an item replaces it but keeps its id, and remove frees it" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const id = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"Old","opacity":50}}}}
    , .{})).?;
    _ = try fixture.edit(
        \\{{"op":"set","path":["items",{d}],"value":{{"name":"New"}}}}
    , .{id});
    const item = fixture.document.items.items[0];
    try testing.expectEqualStrings("New", item.name);
    try testing.expectEqual(255, item.opacity);
    try testing.expectEqual(id, item.id);

    _ = try fixture.edit(
        \\{{"op":"remove","path":["items",{d}]}}
    , .{id});
    try testing.expectEqual(0, fixture.document.items.items.len);
}

test "apply rejects ops it can't carry out, leaving the document as it was" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try testing.expectError(error.InvalidOp, fixture.edit(
        \\{{"op":"rename","path":["title"],"value":"X"}}
    , .{}));
    try testing.expectError(error.InvalidPath, fixture.edit(
        \\{{"op":"set","path":[],"value":"X"}}
    , .{}));
    try testing.expectError(error.MissingField, fixture.edit(
        \\{{"op":"set","path":["nope"],"value":1}}
    , .{}));
    try testing.expectError(error.InvalidValue, fixture.edit(
        \\{{"op":"set","path":["section","width"],"value":"wide"}}
    , .{}));
    try testing.expectError(error.NotAList, fixture.edit(
        \\{{"op":"insert","path":["title"],"value":"X"}}
    , .{}));
    try testing.expectError(error.ListIsNotKeyed, fixture.edit(
        \\{{"op":"insert","path":["tags"],"value":"X"}}
    , .{}));
    try testing.expectError(error.MissingItem, fixture.edit(
        \\{{"op":"remove","path":["items",999999]}}
    , .{}));
    try testing.expectError(error.InvalidPath, fixture.edit(
        \\{{"op":"remove","path":["items"]}}
    , .{}));
    try testing.expectEqualStrings("", fixture.document.title);
    try testing.expectEqual(100, fixture.document.section.width);
}

test "move needs an index" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const id = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"A"}}}}
    , .{})).?;
    try testing.expectError(error.MissingIndex, fixture.edit(
        \\{{"op":"move","path":["items",{d}]}}
    , .{id}));
}

test "assignIds gives only the items still at 0 an id" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    try fixture.document.items.append(testing.allocator, .{ .id = 7 });
    try fixture.document.items.append(testing.allocator, .{});
    assignIds(TestDocument, &fixture.document);
    try testing.expectEqual(7, fixture.document.items.items[0].id);
    try testing.expect(fixture.document.items.items[1].id != 0);
}

test "writeAt reads a value back in the dialog's shape, with each keyed item's id" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    const id = (try fixture.edit(
        \\{{"op":"insert","path":["items"],"value":{{"name":"A","opacity":9}}}}
    , .{})).?;
    const expected = try std.fmt.allocPrint(fixture.arena_state.allocator(),
        \\{{"id":{d},"name":"A","opacity":9}}
    , .{id});
    try testing.expectEqualStrings(expected, try fixture.read(
        \\["items",{d}]
    , .{id}));
    try testing.expectEqualStrings("100", try fixture.read(
        \\["section","width"]
    , .{}));
    try testing.expectError(error.MissingField, fixture.read(
        \\["nope"]
    , .{}));
}

test "isSection is true for structs edited field by field, and false for values set whole" {
    try testing.expect(isSection(TestDocument, &.{}));
    try testing.expect(isSection(TestDocument, &.{"section"}));
    try testing.expect(isSection(TestDocument, &.{"position"}));
    try testing.expect(!isSection(TestDocument, &.{"title"}));
    try testing.expect(!isSection(TestDocument, &.{"items"}));
    try testing.expect(!isSection(TestDocument, &.{"nope"}));
}
