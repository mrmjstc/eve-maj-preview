//! Fills a notification's custom text with the event's values; no I/O.
const std = @import("std");

pub const Field = enum { source, target, character };

pub const Placeholder = struct {
    name: []const u8,
    field: Field,
};

/// Borrowed; null where the event didn't carry that value.
pub const Values = struct {
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,
    character: ?[]const u8 = null,

    fn get(self: Values, field: Field) ?[]const u8 {
        return switch (field) {
            .source => self.source,
            .target => self.target,
            .character => self.character,
        };
    }
};

const Output = struct {
    buf: []u8,
    len: usize = 0,
    is_full: bool = false,

    fn write(self: *Output, bytes: []const u8) void {
        if (self.is_full) return;
        var count = bytes.len;
        if (count > self.buf.len - self.len) {
            count = self.buf.len - self.len;
            while (count > 0 and isContinuationByte(bytes[count])) count -= 1;
            self.is_full = true;
        }
        @memcpy(self.buf[self.len..][0..count], bytes[0..count]);
        self.len += count;
    }

    fn slice(self: *const Output) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Null if a known `{name}` has no value; unknown names and other backslashes stay as typed, a typed `\n` becomes a line break, and the result points into `buf`.
pub fn render(template: []const u8, placeholders: []const Placeholder, values: Values, buf: []u8) ?[]const u8 {
    var out: Output = .{ .buf = buf };
    var i: usize = 0;
    while (i < template.len) {
        const special = std.mem.findAnyPos(u8, template, i, "{\\") orelse template.len;
        out.write(template[i..special]);
        if (special == template.len) break;

        if (template[special] == '\\') {
            const is_newline = special + 1 < template.len and template[special + 1] == 'n';
            out.write(if (is_newline) "\n" else "\\");
            i = special + if (is_newline) @as(usize, 2) else 1;
            continue;
        }

        const brace = special;
        if (std.mem.findScalarPos(u8, template, brace + 1, '}')) |close| {
            if (find(placeholders, template[brace + 1 .. close])) |placeholder| {
                const value = values.get(placeholder.field) orelse return null;
                if (value.len == 0) return null;
                out.write(value);
                i = close + 1;
                continue;
            }
        }
        out.write("{");
        i = brace + 1;
    }
    return out.slice();
}

/// For displays with one row per notification: line breaks become spaces, truncated on a UTF-8 boundary; the result points into `buf`.
pub fn oneLine(text: []const u8, buf: []u8) []const u8 {
    var n = @min(text.len, buf.len);
    if (n < text.len) {
        while (n > 0 and isContinuationByte(text[n])) n -= 1;
    }
    @memcpy(buf[0..n], text[0..n]);
    std.mem.replaceScalar(u8, buf[0..n], '\n', ' ');
    return buf[0..n];
}

fn find(placeholders: []const Placeholder, name: []const u8) ?Placeholder {
    for (placeholders) |placeholder| {
        if (std.ascii.eqlIgnoreCase(placeholder.name, name)) return placeholder;
    }
    return null;
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

const testing = std.testing;

const TEST_PLACEHOLDERS = [_]Placeholder{
    .{ .name = "pilot", .field = .source },
    .{ .name = "system", .field = .target },
    .{ .name = "character", .field = .character },
};

test "render fills each placeholder, ignoring case" {
    var buf: [64]u8 = undefined;
    const values: Values = .{ .source = "Some Pilot", .target = "Jita", .character = "Main" };
    try testing.expectEqualStrings("Main: Some Pilot in Jita", render("{character}: {PILOT} in {System}", &TEST_PLACEHOLDERS, values, &buf).?);
}

test "render keeps unknown names and stray braces as typed" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{ship} {x Some Pilot }", render("{ship} {x {pilot} }", &TEST_PLACEHOLDERS, .{ .source = "Some Pilot" }, &buf).?);
    try testing.expectEqualStrings("Ends with {", render("Ends with {", &TEST_PLACEHOLDERS, .{}, &buf).?);
}

test "render gives up when a used placeholder has no value" {
    var buf: [64]u8 = undefined;
    try testing.expect(render("Invite from {pilot}", &TEST_PLACEHOLDERS, .{}, &buf) == null);
    try testing.expect(render("{character} invited", &TEST_PLACEHOLDERS, .{ .character = "" }, &buf) == null);
    try testing.expectEqualStrings("Invite", render("Invite", &TEST_PLACEHOLDERS, .{}, &buf).?);
}

test "render turns a typed \\n into a line break and keeps other backslashes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Main\nin Jita", render("{character}\\nin {system}", &TEST_PLACEHOLDERS, .{ .character = "Main", .target = "Jita" }, &buf).?);
    try testing.expectEqualStrings("a\\b\\", render("a\\b\\", &TEST_PLACEHOLDERS, .{}, &buf).?);
}

test "oneLine turns line breaks into spaces" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Some Rat scrambling you", oneLine("Some Rat\nscrambling you", &buf));
}

test "oneLine truncates on a UTF-8 boundary" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abc", oneLine("abc\u{00e9}", &buf));
}

test "render truncates on a UTF-8 boundary" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abc", render("abc\u{00e9}", &TEST_PLACEHOLDERS, .{}, &buf).?);
    try testing.expectEqualStrings("Hi J", render("Hi {system}!", &TEST_PLACEHOLDERS, .{ .target = "Jita" }, &buf).?);
}
