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

/// A keyed map (NotificationTypeConfigs) is reached by child name rather than field, and saves in its own shape.
pub fn isKeyedMap(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "childAt");
}

pub fn ChildOf(comptime T: type) type {
    const Return = @typeInfo(@TypeOf(T.childAt)).@"fn".return_type.?;
    return @typeInfo(@typeInfo(Return).optional.child).pointer.child;
}

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

/// The value at `path`, in the dialog's shape.
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

fn hasId(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "id");
}

/// A struct edited field by field: a section with a generated `Wire`, or a plain one saved as its own fields (SnappingConfig, Position).
fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and wire.ListItem(T) == null and !isKeyedMap(T) and T != key_list.KeyList;
}

/// The struct inside an optional one, such as a character's `?Position`.
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
