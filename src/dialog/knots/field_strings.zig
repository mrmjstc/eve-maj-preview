//! Which string fields of a settings struct hold their default literal and which hold owned copies; no I/O.
const std = @import("std");

/// The default of string field `field` of `T`, or "" if it has none or defaults to null.
pub fn fieldDefault(comptime T: type, comptime field: []const u8) []const u8 {
    const F = @FieldType(T, field);
    const index = std.meta.fieldIndex(T, field).?;
    const default = @typeInfo(T).@"struct".field_attrs[index].defaultValue(F) orelse return "";
    return if (F == ?[]const u8) default orelse "" else default;
}

/// A field still holding its default points at a string literal.
pub fn isOwned(bytes: []const u8, default: []const u8) bool {
    return bytes.len > 0 and bytes.ptr != default.ptr;
}

/// Copies each non-default string field into `allocator`; on failure every field is back at its default.
pub fn ownStrings(comptime Item: type, allocator: std.mem.Allocator, item: *Item) !void {
    if (@typeInfo(Item) != .@"struct") return;
    const info = @typeInfo(Item).@"struct";
    // Every field is reset before any is copied, so a failed copy frees only copies.
    var texts: [info.field_names.len][]const u8 = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        if (F == []const u8) {
            texts[i] = @field(item, name);
            @field(item, name) = fieldDefault(Item, name);
        }
    }
    errdefer freeOwnedStrings(Item, allocator, item);
    inline for (info.field_names, info.field_types, 0..) |name, F, i| {
        if (F == []const u8) {
            const text = texts[i];
            if (isOwned(text, fieldDefault(Item, name))) @field(item, name) = try allocator.dupe(u8, text);
        }
    }
}

/// Frees each string field of `item` that ownStrings copied, and puts it back to its default.
pub fn freeOwnedStrings(comptime Item: type, allocator: std.mem.Allocator, item: *Item) void {
    if (@typeInfo(Item) != .@"struct") return;
    const info = @typeInfo(Item).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (F == []const u8) {
            const text = @field(item, name);
            if (isOwned(text, fieldDefault(Item, name))) allocator.free(text);
            @field(item, name) = fieldDefault(Item, name);
        }
    }
}

pub fn ListItem(comptime List: type) type {
    return @typeInfo(@FieldType(List, "items")).pointer.child;
}

const testing = std.testing;

const Sample = struct {
    name: []const u8 = "default name",
    note: []const u8 = "",
    label: ?[]const u8 = "default label",
    alias: ?[]const u8 = null,
    count: u32 = 0,
};

test "fieldDefault reads a string field's default, and an optional's" {
    try testing.expectEqualStrings("default name", fieldDefault(Sample, "name"));
    try testing.expectEqualStrings("default label", fieldDefault(Sample, "label"));
}

test "fieldDefault gives an empty string for an empty or null default" {
    try testing.expectEqualStrings("", fieldDefault(Sample, "note"));
    try testing.expectEqualStrings("", fieldDefault(Sample, "alias"));
}

test "isOwned tells a copy from the default literal it equals" {
    const sample: Sample = .{};
    try testing.expect(!isOwned(sample.name, fieldDefault(Sample, "name")));
    const copy = try testing.allocator.dupe(u8, sample.name);
    defer testing.allocator.free(copy);
    try testing.expect(isOwned(copy, fieldDefault(Sample, "name")));
}

test "isOwned treats an empty string as never owned" {
    try testing.expect(!isOwned("", fieldDefault(Sample, "name")));
}

test "ownStrings copies changed strings and leaves defaults pointing at their literal" {
    var item: Sample = .{ .note = "borrowed note" };
    try ownStrings(Sample, testing.allocator, &item);
    defer freeOwnedStrings(Sample, testing.allocator, &item);
    try testing.expectEqualStrings("borrowed note", item.note);
    try testing.expect(isOwned(item.note, fieldDefault(Sample, "note")));
    try testing.expect(!isOwned(item.name, fieldDefault(Sample, "name")));
}

test "freeOwnedStrings puts every string field back to its default" {
    var item: Sample = .{ .name = "custom name", .note = "custom note" };
    try ownStrings(Sample, testing.allocator, &item);
    freeOwnedStrings(Sample, testing.allocator, &item);
    try testing.expectEqualStrings("default name", item.name);
    try testing.expectEqualStrings("", item.note);
}

test "ownStrings that runs out of memory frees the copies it made and leaves defaults" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var item: Sample = .{ .name = "custom name", .note = "custom note" };
    try testing.expectError(error.OutOfMemory, ownStrings(Sample, failing.allocator(), &item));
    try testing.expectEqualStrings("default name", item.name);
    try testing.expectEqualStrings("", item.note);
}

test "ListItem is an ArrayList's element type" {
    try testing.expect(ListItem(std.ArrayList(u32)) == u32);
}
