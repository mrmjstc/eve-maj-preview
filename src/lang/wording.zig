//! The app's language files, and filling the named {placeholders} in their strings; no I/O.
const std = @import("std");
const types = @import("../config/types.zig");

const Language = types.Language;

const ENGLISH = @embedFile("en.json");

/// The names between braces in a string, in order.
const Placeholders = struct {
    rest: []const u8,

    fn init(text: []const u8) Placeholders {
        return .{ .rest = text };
    }

    fn next(self: *Placeholders) ?[]const u8 {
        const open = std.mem.indexOfScalar(u8, self.rest, '{') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, self.rest, open + 1, '}') orelse return null;
        defer self.rest = self.rest[close + 1 ..];
        return self.rest[open + 1 .. close];
    }

    fn contains(text: []const u8, wanted: []const u8) bool {
        var names: Placeholders = .init(text);
        while (names.next()) |name| {
            if (std.mem.eql(u8, name, wanted)) return true;
        }
        return false;
    }
};

/// The language's own file of "English": "translation" pairs; English's lists every string, for translators to start from.
pub fn file(language: Language) []const u8 {
    return switch (language) {
        .en => ENGLISH,
        .de => @embedFile("de.json"),
        .es => @embedFile("es.json"),
        .fr => @embedFile("fr.json"),
        .pl => @embedFile("pl.json"),
        .pt => @embedFile("pt.json"),
        .ru => @embedFile("ru.json"),
    };
}

/// Writes `template` with each {name} replaced by `args`' field of that name, a string, integer or error; other braces stay as they are.
pub fn fill(writer: *std.Io.Writer, template: []const u8, args: anytype) std.Io.Writer.Error!void {
    var rest = template;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '}') orelse break;
        try writer.writeAll(rest[0..open]);
        if (!try writeArgument(writer, rest[open + 1 .. close], args)) try writer.writeAll(rest[open .. close + 1]);
        rest = rest[close + 1 ..];
    }
    try writer.writeAll(rest);
}

/// Whether `template`'s placeholders are the same set as `english`'s, so a translation can't lose or invent one.
fn hasSamePlaceholders(english: []const u8, template: []const u8) bool {
    var english_names: Placeholders = .init(english);
    while (english_names.next()) |name| {
        if (!Placeholders.contains(template, name)) return false;
    }
    var names: Placeholders = .init(template);
    while (names.next()) |name| {
        if (!Placeholders.contains(english, name)) return false;
    }
    return true;
}

fn writeArgument(writer: *std.Io.Writer, name: []const u8, args: anytype) std.Io.Writer.Error!bool {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    inline for (info.field_names) |field_name| {
        if (std.mem.eql(u8, field_name, name)) {
            try writeValue(writer, @field(args, field_name));
            return true;
        }
    }
    return false;
}

fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .error_set => try writer.writeAll(@errorName(value)),
        else => try writer.writeAll(value),
    }
}

const testing = std.testing;

fn filled(template: []const u8, args: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try fill(&out.writer, template, args);
    return out.toOwnedSlice();
}

/// The first key of `translated` that en.json lacks, or whose translation loses or invents a placeholder.
fn firstBadKey(english: std.json.Value, translated: std.json.Value) ?[]const u8 {
    var it = translated.object.iterator();
    while (it.next()) |entry| {
        const original = english.object.get(entry.key_ptr.*) orelse return entry.key_ptr.*;
        if (entry.value_ptr.* != .string or !hasSamePlaceholders(original.string, entry.value_ptr.string)) return entry.key_ptr.*;
    }
    return null;
}

test "fill replaces each named placeholder, wherever the translation puts it" {
    const text = try filled("'{name}' hat {n} Profile", .{ .n = 3, .name = "Main" });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("'Main' hat 3 Profile", text);
}

test "fill writes an error by its name" {
    const text = try filled("Failed to save: {err}", .{ .err = error.AccessDenied });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Failed to save: AccessDenied", text);
}

test "fill leaves braces it has no value for" {
    const text = try filled("{unknown} and {n} and {", .{ .n = 1 });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{unknown} and 1 and {", text);
}

test "hasSamePlaceholders catches a lost or invented placeholder" {
    try testing.expect(hasSamePlaceholders("Copy of '{name}'", "Kopie von '{name}'"));
    try testing.expect(!hasSamePlaceholders("Copy of '{name}'", "Kopie"));
    try testing.expect(!hasSamePlaceholders("Saved", "Gespeichert {n}"));
}

test "every translated string is an English one and keeps its placeholders" {
    const english = try std.json.parseFromSlice(std.json.Value, testing.allocator, ENGLISH, .{});
    defer english.deinit();
    for (std.enums.values(Language)) |language| {
        const translated = try std.json.parseFromSlice(std.json.Value, testing.allocator, file(language), .{});
        defer translated.deinit();
        // Compared as strings so a failure names the key.
        try testing.expectEqualStrings("", firstBadKey(english.value, translated.value) orelse "");
    }
}
