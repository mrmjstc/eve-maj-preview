//! Edits to a settings document by path, the one way the config dialog changes settings and hears about the app's own changes.
//! A path is a JSON array of field names, with an item's `id` inside a keyed list: `["characters", 12, "opacity"]`.
//! Any field can be `set`; lists whose items have an `id` also take `insert`, `remove` and `move`.
const std = @import("std");
const wire = @import("wire.zig");

pub const Op = struct {
    op: []const u8,
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

fn hasId(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "id");
}

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
    if (comptime !wire.isNested(T)) return false;
    if (path.len == 0) return true;
    inline for (comptime wire.savedFields(T)) |f| {
        if (std.mem.eql(u8, path[0], f.name)) return isSection(comptime (wire.OptionalNested(f.type) orelse f.type), path[1..]);
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
        } else if (comptime wire.isNested(f.type) and !isKeyedMap(f.type)) {
            assignIds(f.type, &@field(value, f.name));
        }
    }
}

fn nextId() u32 {
    const id = g_next_id;
    g_next_id += 1;
    return id;
}

/// `value` in the dialog's shape: the saved JSON plus each keyed list item's `id`.
pub fn write(jw: anytype, comptime T: type, value: *const T) !void {
    return writeValue(jw, T, "", value);
}

fn writeValue(jw: anytype, comptime T: type, comptime name: []const u8, value: *const T) !void {
    if (comptime wire.isNested(T)) {
        if (comptime isKeyedMap(T)) return jw.write(wire.encode(T, value.*));
        try jw.beginObject();
        if (comptime hasId(T)) {
            try jw.objectField("id");
            try jw.write(value.id);
        }
        inline for (comptime wire.savedFields(T)) |f| {
            try jw.objectField(f.name);
            try writeValue(jw, f.type, f.name, &@field(value, f.name));
        }
        return jw.endObject();
    }
    if (comptime wire.OptionalNested(T)) |N| {
        if (value.*) |*v| return writeValue(jw, N, name, v);
        return jw.write(null);
    }
    if (comptime wire.ListItem(T)) |Item| {
        try jw.beginArray();
        for (value.items) |*item| try writeValue(jw, Item, name, item);
        return jw.endArray();
    }
    return jw.write(wire.fieldToWire(T, name, value.*));
}

/// The value at `path`, in the dialog's shape.
pub fn writeAt(jw: anytype, comptime T: type, target: *const T, path: []const std.json.Value) !void {
    if (path.len == 0) return write(jw, T, target);
    const key = try fieldKey(path[0]);
    if (comptime isKeyedMap(T)) {
        const child = target.childAtConst(key) orelse return error.UnknownPath;
        return writeAt(jw, ChildOf(T), child, path[1..]);
    } else {
        inline for (comptime wire.savedFields(T)) |f| {
            if (std.mem.eql(u8, key, f.name)) return writeFieldAt(jw, f.type, f.name, &@field(target, f.name), path[1..]);
        }
        return error.UnknownPath;
    }
}

fn writeFieldAt(jw: anytype, comptime F: type, comptime name: []const u8, ptr: *const F, path: []const std.json.Value) !void {
    if (path.len == 0) return writeValue(jw, F, name, ptr);
    if (comptime wire.ListItem(F)) |Item| {
        if (comptime hasId(Item)) {
            const index = try findItem(Item, ptr.items, path[0]);
            return writeAt(jw, Item, &ptr.items[index], path[1..]);
        } else return error.ListIsNotKeyed;
    }
    if (comptime wire.OptionalNested(F)) |N| {
        if (ptr.*) |*v| return writeAt(jw, N, v, path);
        return jw.write(null);
    }
    if (comptime wire.isNested(F)) return writeAt(jw, F, ptr, path);
    return error.InvalidPath;
}

/// Returns the id an `insert` gave its item. Validation is the caller's, once a batch is applied.
pub fn apply(comptime T: type, doc: *T, op: Op, ctx: Context) !?u32 {
    const kind = std.meta.stringToEnum(Kind, op.op) orelse return error.UnknownOp;
    return applyIn(T, doc, op.path, kind, op, ctx);
}

fn applyIn(comptime T: type, target: *T, path: []const std.json.Value, kind: Kind, op: Op, ctx: Context) !?u32 {
    if (path.len == 0) return error.InvalidPath;
    const key = try fieldKey(path[0]);
    if (comptime isKeyedMap(T)) {
        const child = target.childAt(key) orelse return error.UnknownPath;
        return applyIn(ChildOf(T), child, path[1..], kind, op, ctx);
    } else {
        inline for (comptime wire.savedFields(T)) |f| {
            if (std.mem.eql(u8, key, f.name)) return applyField(f.type, f.name, &@field(target, f.name), f.defaultValue(), path[1..], kind, op, ctx);
        }
        return error.UnknownPath;
    }
}

fn applyField(comptime F: type, comptime name: []const u8, ptr: *F, default: ?F, path: []const std.json.Value, kind: Kind, op: Op, ctx: Context) !?u32 {
    if (path.len == 0) {
        switch (kind) {
            .set => {
                try setValue(F, name, ptr, default, op.value, ctx);
                return null;
            },
            .insert => if (comptime wire.ListItem(F)) |Item| {
                if (comptime hasId(Item)) return try insertItem(Item, ptr, op, ctx) else return error.ListIsNotKeyed;
            } else return error.NotAList,
            .remove, .move => return error.InvalidPath,
        }
    }
    if (comptime wire.ListItem(F)) |Item| {
        if (comptime hasId(Item)) {
            const index = try findItem(Item, ptr.items, path[0]);
            if (path.len > 1) return applyIn(Item, &ptr.items[index], path[1..], kind, op, ctx);
            switch (kind) {
                .set => try replaceItem(Item, ptr, index, op.value, ctx),
                .remove => {
                    var removed = ptr.orderedRemove(index);
                    wire.free(Item, &removed, ctx.allocator);
                },
                .move => {
                    const to = op.index orelse return error.MissingIndex;
                    const item = ptr.orderedRemove(index);
                    ptr.insertAssumeCapacity(@min(to, ptr.items.len), item);
                },
                .insert => return error.InvalidPath,
            }
            return null;
        } else return error.ListIsNotKeyed;
    }
    if (comptime wire.OptionalNested(F)) |N| {
        // Editing one field of an unset override starts it from the defaults.
        if (ptr.* == null) ptr.* = N{};
        return applyIn(N, &ptr.*.?, path, kind, op, ctx);
    }
    if (comptime wire.isNested(F)) return applyIn(F, ptr, path, kind, op, ctx);
    return error.InvalidPath;
}

fn setValue(comptime F: type, comptime name: []const u8, ptr: *F, default: ?F, json: std.json.Value, ctx: Context) !void {
    const saved = std.json.parseFromValueLeaky(wire.FieldWire(F, name), ctx.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    const fresh = try wire.fieldFromWire(F, saved, ctx.allocator);
    wire.freeField(F, ptr, default, ctx.allocator);
    ptr.* = fresh;
}

fn replaceItem(comptime Item: type, list: *std.ArrayList(Item), index: usize, json: std.json.Value, ctx: Context) !void {
    const saved = std.json.parseFromValueLeaky(wire.WireOf(Item), ctx.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    var fresh = try wire.decode(Item, saved, ctx.allocator);
    fresh.id = list.items[index].id;
    wire.free(Item, &list.items[index], ctx.allocator);
    list.items[index] = fresh;
}

fn insertItem(comptime Item: type, list: *std.ArrayList(Item), op: Op, ctx: Context) !u32 {
    const json = op.value;
    const saved = std.json.parseFromValueLeaky(wire.WireOf(Item), ctx.arena, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidValue;
    var fresh = try wire.decode(Item, saved, ctx.allocator);
    errdefer wire.free(Item, &fresh, ctx.allocator);
    fresh.id = nextId();
    try list.insert(ctx.allocator, @min(op.index orelse list.items.len, list.items.len), fresh);
    return fresh.id;
}

fn findItem(comptime Item: type, items: []const Item, key: std.json.Value) !usize {
    const id: u32 = switch (key) {
        .integer => |i| std.math.cast(u32, i) orelse return error.UnknownItem,
        else => return error.InvalidPath,
    };
    for (items, 0..) |item, i| {
        if (item.id == id) return i;
    }
    return error.UnknownItem;
}

fn fieldKey(segment: std.json.Value) ![]const u8 {
    return switch (segment) {
        .string => |s| s,
        else => error.InvalidPath,
    };
}

/// The field paths `patch` sets, for patches shaped like ProfileStore.update's (nested anonymous structs down to leaf values of `T`'s fields).
pub fn leafPaths(comptime T: type, comptime P: type) []const []const []const u8 {
    comptime {
        var out: []const []const []const u8 = &.{};
        for (@typeInfo(P).@"struct".fields) |f| {
            const Field = @FieldType(T, f.name);
            const head: []const []const u8 = &.{f.name};
            if (f.type != Field and @typeInfo(Field) == .@"struct") {
                for (leafPaths(Field, f.type)) |sub| {
                    const full: []const []const u8 = head ++ sub;
                    out = out ++ &[_][]const []const u8{full};
                }
            } else {
                out = out ++ &[_][]const []const u8{head};
            }
        }
        return out;
    }
}
