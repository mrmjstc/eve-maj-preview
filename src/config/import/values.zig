//! Reading loosely typed values out of other tools' settings files, and the key and colour spellings they share.
const std = @import("std");
const vk = @import("../../platform/virtual_keys.zig");

const Value = std.json.Value;

pub fn get(object: ?Value, key: []const u8) ?Value {
    const value = object orelse return null;
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn has(object: ?Value, key: []const u8) bool {
    return get(object, key) != null;
}

/// The object at `key`, or null for anything else.
pub fn objectAt(object: ?Value, key: []const u8) ?Value {
    const value = get(object, key) orelse return null;
    return if (value == .object) value else null;
}

pub fn arrayAt(object: ?Value, key: []const u8) []const Value {
    const value = get(object, key) orelse return &.{};
    return if (value == .array) value.array.items else &.{};
}

pub fn stringAt(object: ?Value, key: []const u8) ?[]const u8 {
    const value = get(object, key) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn count(object: ?Value) usize {
    const value = object orelse return 0;
    return if (value == .object) value.object.count() else 0;
}

/// JavaScript truthiness, which the tools' JSON was written against: "0" is true, 0 is false.
pub fn truthy(value: ?Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0 and !std.math.isNan(f),
        .number_string, .string => |s| s.len > 0,
        .array, .object => true,
    };
}

/// A number, or a numeric string, since EVE-X Preview writes some numbers quoted depending on its version.
pub fn number(value: ?Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .bool => |b| if (b) 1 else 0,
        .number_string, .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null,
        else => null,
    };
}

/// Only an actual JSON number, for fields a tool always writes as one.
pub fn jsonNumber(value: ?Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

pub fn flag(value: ?Value) ?bool {
    const n = number(value) orelse return null;
    return n != 0;
}

/// Like JavaScript's parseInt: leading spaces and sign, then digits up to the first non-digit.
pub fn parseIntLoose(text: ?[]const u8) ?i64 {
    const s = std.mem.trimStart(u8, text orelse return null, " \t");
    var end: usize = 0;
    if (end < s.len and (s[end] == '-' or s[end] == '+')) end += 1;
    const digits_start = end;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == digits_start) return null;
    return std.fmt.parseInt(i64, s[0..end], 10) catch null;
}

/// A whole number as an integer, so it parses into integer settings.
pub fn numberValue(n: f64) Value {
    const rounded = @round(n);
    if (rounded == n and @abs(n) < 1e15) return .{ .integer = @intFromFloat(rounded) };
    return .{ .float = n };
}

/// "#RRGGBB", "RRGGBB" or "0xRRGGBB" as an opaque colour.
pub fn rgbColor(text: ?[]const u8) ?u32 {
    var s = std.mem.trim(u8, text orelse return null, " \t");
    if (std.mem.startsWith(u8, s, "#")) s = s[1..];
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) s = s[2..];
    if (s.len != 6) return null;
    const rgb = std.fmt.parseInt(u32, s, 16) catch return null;
    return 0xFF000000 | rgb;
}

pub fn withAlpha(color: u32, alpha: f64) u32 {
    const a: u32 = @intFromFloat(std.math.clamp(@round(alpha), 0, 255));
    return (a << 24) | (color & 0x00FFFFFF);
}

pub fn colorValue(arena: std.mem.Allocator, color: u32) !Value {
    return .{ .string = try std.fmt.allocPrint(arena, "0x{X:0>8}", .{color}) };
}

pub fn keyValue(arena: std.mem.Allocator, combined: u32) !Value {
    return .{ .string = try std.fmt.allocPrint(arena, "0x{X:0>2}", .{combined}) };
}

pub fn opacityFromPercent(percent: f64) f64 {
    return std.math.clamp(@round(percent * 2.55), 0, 255);
}

/// A key name the older tools share: A-Z, 0-9, F1-F24, Numpad0-9 and a few named keys, including their short forms.
pub fn legacyBaseKey(token: []const u8) ?u32 {
    const t = std.mem.trim(u8, token, " \t");
    if (t.len == 0) return null;
    if (t.len == 1) {
        const ch = std.ascii.toUpper(t[0]);
        if (std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch)) return ch;
    }
    var lower_buf: [32]u8 = undefined;
    if (t.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(&lower_buf, t);
    if (lower.len >= 2 and lower.len <= 3 and lower[0] == 'f') {
        const n = std.fmt.parseInt(u32, lower[1..], 10) catch return null;
        if (lower[1] != '0' and n >= 1 and n <= 24) return vk.VK_F1 + n - 1;
        return null;
    }
    if (lower.len == 7 and std.mem.startsWith(u8, lower, "numpad") and std.ascii.isDigit(lower[6])) return vk.VK_NUMPAD0 + (lower[6] - '0');
    const named = [_]struct { []const u8, u32 }{
        .{ "space", vk.VK_SPACE },         .{ "pageup", vk.VK_PRIOR },         .{ "pgup", vk.VK_PRIOR },
        .{ "pagedown", vk.VK_NEXT },       .{ "pgdn", vk.VK_NEXT },            .{ "end", vk.VK_END },
        .{ "home", vk.VK_HOME },           .{ "left", vk.VK_LEFT },            .{ "up", vk.VK_UP },
        .{ "right", vk.VK_RIGHT },         .{ "down", vk.VK_DOWN },            .{ "insert", vk.VK_INSERT },
        .{ "ins", vk.VK_INSERT },          .{ "delete", vk.VK_DELETE },        .{ "del", vk.VK_DELETE },
        .{ "numpadmult", vk.VK_MULTIPLY }, .{ "numpadmultiply", vk.VK_MULTIPLY }, .{ "numpadadd", vk.VK_ADD },
        .{ "numpadsub", vk.VK_SUBTRACT },  .{ "numpadsubtract", vk.VK_SUBTRACT }, .{ "numpaddot", vk.VK_DECIMAL },
        .{ "numpaddecimal", vk.VK_DECIMAL }, .{ "numpaddiv", vk.VK_DIVIDE }, .{ "numpaddivide", vk.VK_DIVIDE },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, lower, entry[0])) return entry[1];
    }
    return null;
}

/// An AutoHotkey-style hotkey (EVE-X Preview): modifier symbols "^!+#", "Ctrl & F1" combos, or a key name.
/// Null for anything the app can't bind, such as the left, right or middle mouse button.
pub fn ahkHotkey(raw: ?[]const u8) ?u32 {
    var s = std.mem.trim(u8, raw orelse return null, " \t");
    var modifiers: u32 = 0;
    while (s.len > 0) : (s = s[1..]) {
        switch (s[0]) {
            '^' => modifiers |= vk.MOD_CONTROL,
            '!' => modifiers |= vk.MOD_ALT,
            '+' => modifiers |= vk.MOD_SHIFT,
            '#' => modifiers |= vk.MOD_WIN,
            // Hook behaviour flags with no OS-level equivalent: "*F22" is just F22.
            '*', '~', '$' => {},
            else => break,
        }
    }

    if (std.mem.indexOf(u8, s, " & ")) |amp| {
        const left = std.mem.trim(u8, s[0..amp], " \t");
        modifiers |= modifierWord(left) orelse return null;
        s = s[amp + 3 ..];
    }

    const t = std.mem.trim(u8, s, " \t");
    const vk_code: u32 = if (std.ascii.eqlIgnoreCase(t, "xbutton1"))
        vk.VK_XBUTTON1
    else if (std.ascii.eqlIgnoreCase(t, "xbutton2"))
        vk.VK_XBUTTON2
    else if (std.ascii.eqlIgnoreCase(t, "wheelup"))
        vk.VK_WHEELUP
    else if (std.ascii.eqlIgnoreCase(t, "wheeldown"))
        vk.VK_WHEELDOWN
    else
        legacyBaseKey(t) orelse return null;
    return vk.combineKey(vk_code, modifiers);
}

fn modifierWord(word: []const u8) ?u32 {
    const words = [_]struct { []const u8, u32 }{
        .{ "ctrl", vk.MOD_CONTROL }, .{ "control", vk.MOD_CONTROL }, .{ "alt", vk.MOD_ALT },
        .{ "shift", vk.MOD_SHIFT },  .{ "win", vk.MOD_WIN },         .{ "lwin", vk.MOD_WIN },
        .{ "rwin", vk.MOD_WIN },
    };
    for (words) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return null;
}

/// A character's name from a key other tools file per-client settings under, with an "EVE - " window-title prefix dropped.
/// Null for the placeholders their default configs ship ("Example Name1", "Cycle Group 1") and for entries that aren't characters (an exe path).
pub fn characterName(raw: []const u8) ?[]const u8 {
    var name = std.mem.trim(u8, raw, " \t");
    if (std.mem.startsWith(u8, name, "EVE - ")) name = std.mem.trim(u8, name["EVE - ".len..], " \t");
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "eve")) return null;
    if (std.ascii.indexOfIgnoreCase(name, "example") != null) return null;
    if (std.mem.indexOfAny(u8, name, "\\/") != null or std.ascii.endsWithIgnoreCase(name, ".exe")) return null;
    if (name.len > "cycle group ".len and std.ascii.startsWithIgnoreCase(name, "cycle group ")) {
        for (name["cycle group ".len..]) |c| {
            if (!std.ascii.isDigit(c)) return name;
        }
        return null;
    }
    return name;
}

/// ASCII letters, digits, '-', '_' and spaces, cut to `max_len`, for a profile named after an imported file or profile.
pub fn profileName(arena: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, text, " \t")) |c| {
        if (out.items.len == max_len) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ' ') try out.append(arena, c);
    }
    return out.items;
}

const testing = std.testing;

test "rgbColor reads #, 0x and bare hex as an opaque colour" {
    try testing.expectEqual(@as(u32, 0xFF1A2B3C), rgbColor("#1A2B3C").?);
    try testing.expectEqual(@as(u32, 0xFF1A2B3C), rgbColor("0x1a2b3c").?);
    try testing.expectEqual(@as(u32, 0xFF1A2B3C), rgbColor(" 1A2B3C ").?);
    try testing.expect(rgbColor("#1A2B3") == null);
    try testing.expect(rgbColor("#1A2B3C4D") == null);
    try testing.expect(rgbColor("#GGGGGG") == null);
    try testing.expect(rgbColor(null) == null);
}

test "parseIntLoose reads a leading signed integer and ignores the rest" {
    try testing.expectEqual(@as(i64, 42), parseIntLoose(" 42px").?);
    try testing.expectEqual(@as(i64, -7), parseIntLoose("-7").?);
    try testing.expectEqual(@as(i64, 3), parseIntLoose("+3").?);
    try testing.expect(parseIntLoose("-") == null);
    try testing.expect(parseIntLoose("px42") == null);
    try testing.expect(parseIntLoose(null) == null);
}

test "numberValue keeps whole numbers as integers" {
    try testing.expectEqual(@as(i64, 3), numberValue(3.0).integer);
    try testing.expectEqual(@as(i64, -12), numberValue(-12.0).integer);
    try testing.expectEqual(@as(f64, 2.5), numberValue(2.5).float);
}

test "withAlpha and opacityFromPercent round and clamp to a byte" {
    try testing.expectEqual(@as(u32, 0x80123456), withAlpha(0xFF123456, 128.4));
    try testing.expectEqual(@as(u32, 0xFF123456), withAlpha(0x00123456, 300));
    try testing.expectEqual(@as(f64, 255), opacityFromPercent(100));
    try testing.expectEqual(@as(f64, 102), opacityFromPercent(40));
    try testing.expectEqual(@as(f64, 255), opacityFromPercent(150));
    try testing.expectEqual(@as(f64, 0), opacityFromPercent(-5));
}

test "legacyBaseKey reads letters, digits, F-keys, numpad and short names" {
    try testing.expectEqual(@as(u32, 'A'), legacyBaseKey("a").?);
    try testing.expectEqual(@as(u32, '7'), legacyBaseKey(" 7 ").?);
    try testing.expectEqual(vk.VK_F1, legacyBaseKey("F1").?);
    try testing.expectEqual(vk.VK_F1 + 23, legacyBaseKey("f24").?);
    try testing.expectEqual(vk.VK_NUMPAD0 + 7, legacyBaseKey("Numpad7").?);
    try testing.expectEqual(vk.VK_NEXT, legacyBaseKey("pgdn").?);
    try testing.expectEqual(vk.VK_DELETE, legacyBaseKey("Del").?);
    try testing.expectEqual(vk.VK_DIVIDE, legacyBaseKey("NumpadDiv").?);
}

test "legacyBaseKey rejects out-of-range F-keys and unknown names" {
    try testing.expect(legacyBaseKey("F0") == null);
    try testing.expect(legacyBaseKey("F25") == null);
    try testing.expect(legacyBaseKey("F01") == null);
    try testing.expect(legacyBaseKey("Escape") == null);
    try testing.expect(legacyBaseKey("") == null);
}

test "ahkHotkey reads modifier symbols, flag prefixes and & combos" {
    try testing.expectEqual(vk.combineKey(vk.VK_F1, vk.MOD_CONTROL | vk.MOD_ALT), ahkHotkey("^!F1").?);
    try testing.expectEqual(vk.combineKey('A', vk.MOD_WIN | vk.MOD_SHIFT), ahkHotkey("#+a").?);
    try testing.expectEqual(vk.combineKey(vk.VK_F1 + 21, 0), ahkHotkey("*F22").?);
    try testing.expectEqual(vk.combineKey(vk.VK_F1, vk.MOD_CONTROL), ahkHotkey("Ctrl & F1").?);
    try testing.expectEqual(vk.combineKey(vk.VK_XBUTTON1, vk.MOD_SHIFT), ahkHotkey("+XButton1").?);
    try testing.expectEqual(vk.combineKey(vk.VK_WHEELUP, 0), ahkHotkey("WheelUp").?);
}

test "ahkHotkey rejects keys the app can't bind" {
    try testing.expect(ahkHotkey("LButton") == null);
    try testing.expect(ahkHotkey("Hyper & F1") == null);
    try testing.expect(ahkHotkey("^") == null);
    try testing.expect(ahkHotkey(null) == null);
}

test "characterName drops the window-title prefix and rejects placeholders" {
    try testing.expectEqualStrings("Some Pilot", characterName("EVE - Some Pilot").?);
    try testing.expectEqualStrings("Some Pilot", characterName("  Some Pilot ").?);
    try testing.expectEqualStrings("Cycle Group Alpha", characterName("Cycle Group Alpha").?);
    try testing.expect(characterName("Example Name1") == null);
    try testing.expect(characterName("Cycle Group 2") == null);
    try testing.expect(characterName("EVE") == null);
    try testing.expect(characterName("C:/Games/EVE/exefile.exe") == null);
    try testing.expect(characterName("exefile.EXE") == null);
}

test "profileName keeps safe characters and caps the length" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("My Profilejson", try profileName(arena, "  My Profile!.json ", 32));
    try testing.expectEqualStrings("My_Pro", try profileName(arena, "My_Profile", 6));
    try testing.expectEqualStrings("", try profileName(arena, "!!!", 16));
}
