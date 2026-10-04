//! A hotkey binding's key combos: alternates that all trigger the same action.
const std = @import("std");
const vk = @import("../platform/virtual_keys.zig");
const log = @import("../log.zig");

const slog = log.scoped("config");

pub const MAX_KEYS = 4;

/// Each key is a combined value (see vk.combineKey). Holds no pointers, so it copies and clones as a plain value.
pub const KeyList = struct {
    keys: [MAX_KEYS]u32 = @splat(0),
    len: u8 = 0,

    pub const empty: KeyList = .{};

    pub fn one(combined: u32) KeyList {
        var list: KeyList = .empty;
        _ = list.append(combined);
        return list;
    }

    pub fn slice(self: *const KeyList) []const u32 {
        return self.keys[0..self.len];
    }

    pub fn isEmpty(self: KeyList) bool {
        return self.len == 0;
    }

    /// Returns false only when the list is full; a key already in it counts as added.
    pub fn append(self: *KeyList, combined: u32) bool {
        if (std.mem.indexOfScalar(u32, self.slice(), combined) != null) return true;
        if (self.len == MAX_KEYS) return false;
        self.keys[self.len] = combined;
        self.len += 1;
        return true;
    }
};

/// Saved as one "0x0278" string for a single key, the form profiles used before alternates, or as an array of them.
/// Loading also accepts combos like "Ctrl+F9" from hand-edited profiles.
pub const KeyListWire = struct {
    value: KeyList,

    pub fn jsonStringify(self: KeyListWire, jw: anytype) !void {
        const keys = self.value.slice();
        if (keys.len == 1) return writeKey(jw, keys[0]);
        try jw.beginArray();
        for (keys) |key| try writeKey(jw, key);
        try jw.endArray();
    }

    /// Lets config/readable.zig drop and report each unreadable key before this parser sees it.
    pub fn isReadableItem(item: std.json.Value) bool {
        return item == .string and (item.string.len == 0 or vk.parseVirtualKey(item.string) != null);
    }

    /// A key that can't be read is skipped with a warning rather than failing, which would load the whole profile as defaults.
    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !KeyListWire {
        var list: KeyList = .empty;
        switch (source) {
            .string => |text| appendParsed(&list, text),
            .array => |array| for (array.items) |item| {
                if (item != .string) {
                    slog.warn("Failed to read a hotkey: expected a key name or code, skipping it", .{});
                    continue;
                }
                appendParsed(&list, item.string);
            },
            else => slog.warn("Failed to read a hotkey: expected a key name, a code or a list of them, leaving it unbound", .{}),
        }
        return .{ .value = list };
    }
};

fn appendParsed(list: *KeyList, text: []const u8) void {
    if (text.len == 0) return;
    const combined = vk.parseVirtualKey(text) orelse {
        slog.warn("Failed to read hotkey '{s}': not a key this app can bind, skipping it", .{text});
        return;
    };
    if (!list.append(combined)) {
        slog.warn("Failed to keep hotkey '{s}': a binding holds at most {} keys", .{ text, MAX_KEYS });
    }
}

fn writeKey(jw: anytype, combined: u32) !void {
    var buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "0x{X:0>2}", .{combined}) catch unreachable;
    try jw.write(s);
}

const testing = std.testing;

fn parseJson(json: []const u8) !KeyList {
    const tree = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer tree.deinit();
    return (try KeyListWire.jsonParseFromValue(testing.allocator, tree.value, .{})).value;
}

fn stringify(list: KeyList) ![]u8 {
    return std.json.Stringify.valueAlloc(testing.allocator, KeyListWire{ .value = list }, .{});
}

test "a single key string loads as a one-key list" {
    const list = try parseJson("\"0x0278\"");
    try testing.expectEqualSlices(u32, &.{0x0278}, list.slice());
}

test "an array loads every key, in hex or by name" {
    const list = try parseJson("[\"0x70\", \"Ctrl+F9\", \"XButton1\"]");
    try testing.expectEqualSlices(u32, &.{ 0x70, vk.combineKey(vk.VK_F1 + 8, vk.MOD_CONTROL), vk.VK_XBUTTON1 }, list.slice());
}

test "an empty string or array loads as no keys" {
    try testing.expect((try parseJson("\"\"")).isEmpty());
    try testing.expect((try parseJson("[]")).isEmpty());
}

test "duplicate keys collapse and keys past MAX_KEYS are dropped" {
    const list = try parseJson("[\"F1\", \"F1\", \"F2\", \"F3\", \"F4\", \"F5\"]");
    try testing.expectEqualSlices(u32, &.{ vk.VK_F1, vk.VK_F1 + 1, vk.VK_F1 + 2, vk.VK_F1 + 3 }, list.slice());
}

test "an unknown key or a non-string entry is skipped, keeping the rest" {
    try testing.expect((try parseJson("\"NotAKey\"")).isEmpty());
    try testing.expectEqualSlices(u32, &.{ vk.VK_F1, vk.VK_F1 + 1 }, (try parseJson("[\"F1\", 5, \"NotAKey\", \"F2\"]")).slice());
    try testing.expect((try parseJson("12")).isEmpty());
}

test "one key saves as a plain string so older profiles stay readable" {
    const json = try stringify(.one(0x0278));
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("\"0x278\"", json);
}

test "several keys save as an array that loads back the same" {
    var list: KeyList = .empty;
    for ([_]u32{ 0x70, 0x0278, vk.VK_XBUTTON2 }) |key| _ = list.append(key);
    const json = try stringify(list);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[\"0x70\",\"0x278\",\"0x06\"]", json);
    try testing.expectEqualSlices(u32, list.slice(), (try parseJson(json)).slice());
}
