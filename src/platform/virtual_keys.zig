//! Virtual-key codes, and the combined key+modifier value hotkeys are stored as, with its names and parsing.
const std = @import("std");
const win32 = @import("win32.zig");
const log = @import("../log.zig");

const slog = log.scoped("virtual_keys");

pub const VK_F1: u32 = 0x70;
pub const VK_TAB: u32 = 0x09;
pub const VK_PAUSE: u32 = 0x13;
pub const VK_CAPITAL: u32 = 0x14;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = win32.VK_CONTROL;
/// Reserved/unassigned in the Windows VK table, so no physical key generates it.
pub const VK_FOCUS_GRANT: u32 = 0xE8;
pub const VK_MENU: u32 = win32.VK_MENU;
pub const VK_LWIN: u32 = win32.VK_LWIN;
pub const VK_SPACE: u32 = 0x20;
pub const VK_PRIOR: u32 = 0x21;
pub const VK_NEXT: u32 = 0x22;
pub const VK_END: u32 = 0x23;
pub const VK_HOME: u32 = 0x24;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_INSERT: u32 = 0x2D;
pub const VK_DELETE: u32 = 0x2E;
pub const VK_NUMLOCK: u32 = 0x90;
pub const VK_SCROLL: u32 = 0x91;
pub const VK_OEM_1: u32 = 0xBA;
pub const VK_OEM_PLUS: u32 = 0xBB;
pub const VK_OEM_COMMA: u32 = 0xBC;
pub const VK_OEM_MINUS: u32 = 0xBD;
pub const VK_OEM_PERIOD: u32 = 0xBE;
pub const VK_OEM_2: u32 = 0xBF;
pub const VK_OEM_3: u32 = 0xC0;
pub const VK_OEM_4: u32 = 0xDB;
pub const VK_OEM_5: u32 = 0xDC;
pub const VK_OEM_6: u32 = 0xDD;
pub const VK_OEM_7: u32 = 0xDE;
pub const VK_MBUTTON: u32 = 0x04;
pub const VK_XBUTTON1: u32 = 0x05;
pub const VK_XBUTTON2: u32 = 0x06;
pub const VK_WHEELUP: u32 = 0x0A;
pub const VK_WHEELDOWN: u32 = 0x0B;
pub const VK_NUMPAD0: u32 = 0x60;
pub const VK_MULTIPLY: u32 = 0x6A;
pub const VK_ADD: u32 = 0x6B;
pub const VK_SUBTRACT: u32 = 0x6D;
pub const VK_DECIMAL: u32 = 0x6E;
pub const VK_DIVIDE: u32 = 0x6F;
pub const VK_BACK: u32 = 0x08;
pub const VK_RETURN: u32 = 0x0D;
pub const VK_SNAPSHOT: u32 = 0x2C;
pub const VK_APPS: u32 = 0x5D;
pub const VK_VOLUME_MUTE: u32 = 0xAD;
pub const VK_VOLUME_DOWN: u32 = 0xAE;
pub const VK_VOLUME_UP: u32 = 0xAF;
pub const VK_MEDIA_NEXT_TRACK: u32 = 0xB0;
pub const VK_MEDIA_PREV_TRACK: u32 = 0xB1;
pub const VK_MEDIA_STOP: u32 = 0xB2;
pub const VK_MEDIA_PLAY_PAUSE: u32 = 0xB3;
pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
const MOD_SHIFT_AMOUNT: u5 = 8;

const VK_MASK: u32 = 0xFF;
const MOD_MASK: u32 = 0x0F;

pub const KeyName = struct { vk: u32, name: []const u8 };

/// Every key a binding can use, in the spelling it's shown and typed in; the config dialog's recorder offers exactly these.
pub const KEY_NAMES: []const KeyName = blk: {
    @setEvalBranchQuota(10_000);
    var list: []const KeyName = &.{};
    for (1..25) |n| list = list ++ &[_]KeyName{.{ .vk = VK_F1 + @as(u32, @intCast(n)) - 1, .name = std.fmt.comptimePrint("F{d}", .{n}) }};
    for ('A'..'Z' + 1) |c| list = list ++ &[_]KeyName{.{ .vk = @intCast(c), .name = &[_]u8{@intCast(c)} }};
    for ('0'..'9' + 1) |c| list = list ++ &[_]KeyName{.{ .vk = @intCast(c), .name = &[_]u8{@intCast(c)} }};
    for (0..10) |n| list = list ++ &[_]KeyName{.{ .vk = VK_NUMPAD0 + @as(u32, @intCast(n)), .name = std.fmt.comptimePrint("Numpad{d}", .{n}) }};
    list = list ++ &[_]KeyName{
        // A bare modifier as the trigger key itself, e.g. plain "Shift", or "Ctrl+Shift" with Shift as the trigger.
        .{ .vk = VK_CONTROL, .name = "Ctrl" },
        .{ .vk = VK_MENU, .name = "Alt" },
        .{ .vk = VK_SHIFT, .name = "Shift" },
        .{ .vk = VK_LWIN, .name = "Win" },
        .{ .vk = VK_TAB, .name = "Tab" },
        .{ .vk = VK_RETURN, .name = "Enter" },
        .{ .vk = VK_BACK, .name = "Backspace" },
        .{ .vk = VK_PAUSE, .name = "Pause" },
        .{ .vk = VK_CAPITAL, .name = "CapsLock" },
        .{ .vk = VK_NUMLOCK, .name = "NumLock" },
        .{ .vk = VK_SCROLL, .name = "ScrollLock" },
        .{ .vk = VK_SNAPSHOT, .name = "PrintScreen" },
        .{ .vk = VK_APPS, .name = "Menu" },
        .{ .vk = VK_SPACE, .name = "Space" },
        .{ .vk = VK_PRIOR, .name = "PageUp" },
        .{ .vk = VK_NEXT, .name = "PageDown" },
        .{ .vk = VK_END, .name = "End" },
        .{ .vk = VK_HOME, .name = "Home" },
        .{ .vk = VK_LEFT, .name = "Left" },
        .{ .vk = VK_UP, .name = "Up" },
        .{ .vk = VK_RIGHT, .name = "Right" },
        .{ .vk = VK_DOWN, .name = "Down" },
        .{ .vk = VK_INSERT, .name = "Insert" },
        .{ .vk = VK_DELETE, .name = "Delete" },
        .{ .vk = VK_MULTIPLY, .name = "NumpadMultiply" },
        .{ .vk = VK_ADD, .name = "NumpadAdd" },
        .{ .vk = VK_SUBTRACT, .name = "NumpadSubtract" },
        .{ .vk = VK_DECIMAL, .name = "NumpadDecimal" },
        .{ .vk = VK_DIVIDE, .name = "NumpadDivide" },
        .{ .vk = VK_VOLUME_MUTE, .name = "VolumeMute" },
        .{ .vk = VK_VOLUME_DOWN, .name = "VolumeDown" },
        .{ .vk = VK_VOLUME_UP, .name = "VolumeUp" },
        .{ .vk = VK_MEDIA_NEXT_TRACK, .name = "MediaNext" },
        .{ .vk = VK_MEDIA_PREV_TRACK, .name = "MediaPrevious" },
        .{ .vk = VK_MEDIA_STOP, .name = "MediaStop" },
        .{ .vk = VK_MEDIA_PLAY_PAUSE, .name = "MediaPlayPause" },
        .{ .vk = VK_MBUTTON, .name = "MButton" },
        .{ .vk = VK_XBUTTON1, .name = "XButton1" },
        .{ .vk = VK_XBUTTON2, .name = "XButton2" },
        .{ .vk = VK_WHEELUP, .name = "WheelUp" },
        .{ .vk = VK_WHEELDOWN, .name = "WheelDown" },
        .{ .vk = VK_OEM_1, .name = ";" },
        .{ .vk = VK_OEM_PLUS, .name = "=" },
        .{ .vk = VK_OEM_COMMA, .name = "," },
        .{ .vk = VK_OEM_MINUS, .name = "-" },
        .{ .vk = VK_OEM_PERIOD, .name = "." },
        .{ .vk = VK_OEM_2, .name = "/" },
        .{ .vk = VK_OEM_3, .name = "`" },
        .{ .vk = VK_OEM_4, .name = "[" },
        .{ .vk = VK_OEM_5, .name = "\\" },
        .{ .vk = VK_OEM_6, .name = "]" },
        .{ .vk = VK_OEM_7, .name = "'" },
    };
    break :blk list;
};

/// The prefix each modifier flag is written with, in the order they're written.
pub const MODIFIER_NAMES = [_]struct { flag: u32, name: []const u8 }{
    .{ .flag = MOD_CONTROL, .name = "Ctrl" },
    .{ .flag = MOD_ALT, .name = "Alt" },
    .{ .flag = MOD_SHIFT, .name = "Shift" },
    .{ .flag = MOD_WIN, .name = "Win" },
};

pub fn extractVk(combined: u32) u32 {
    return combined & VK_MASK;
}

pub fn extractModifiers(combined: u32) u32 {
    return (combined >> MOD_SHIFT_AMOUNT) & MOD_MASK;
}

/// The base key in the low byte and MOD_* flags in bits 8-11; the form every hotkey is stored in.
pub fn combineKey(vk_code: u32, modifiers: u32) u32 {
    return (vk_code & VK_MASK) | ((modifiers & MOD_MASK) << MOD_SHIFT_AMOUNT);
}

/// Whether vk_code is a mouse button or wheel direction, bound via mouse_hook.zig instead of keyboard_hook.zig.
pub fn isMouseHookVk(vk_code: u32) bool {
    return vk_code == VK_MBUTTON or vk_code == VK_XBUTTON1 or vk_code == VK_XBUTTON2 or vk_code == VK_WHEELUP or vk_code == VK_WHEELDOWN;
}

/// Currently-held modifier keys, read via GetAsyncKeyState; shared by mouse_hook.zig and keyboard_hook.zig.
pub fn currentModifiers() u32 {
    var mods: u32 = 0;
    if (win32.isCtrlPressed()) mods |= MOD_CONTROL;
    if (win32.isAltPressed()) mods |= MOD_ALT;
    if (win32.isShiftPressed()) mods |= MOD_SHIFT;
    if (win32.isWinPressed()) mods |= MOD_WIN;
    return mods;
}

pub fn keyName(vk_code: u32) ?[]const u8 {
    for (KEY_NAMES) |key| {
        if (key.vk == vk_code) return key.name;
    }
    return null;
}

/// e.g. "Ctrl+F9"; a key without a name is written "VK<hex>".
pub fn writeVirtualKey(writer: anytype, combined: u32) !void {
    const modifiers = extractModifiers(combined);
    for (MODIFIER_NAMES) |modifier| {
        if (modifiers & modifier.flag != 0) try writer.print("{s}+", .{modifier.name});
    }
    const vk_code = extractVk(combined);
    if (keyName(vk_code)) |name| {
        try writer.writeAll(name);
    } else {
        try writer.print("VK{X}", .{vk_code});
    }
}

fn parseModifierToken(token: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) return MOD_CONTROL;
    if (std.ascii.eqlIgnoreCase(token, "alt")) return MOD_ALT;
    if (std.ascii.eqlIgnoreCase(token, "shift")) return MOD_SHIFT;
    if (std.ascii.eqlIgnoreCase(token, "win") or std.ascii.eqlIgnoreCase(token, "lwin") or std.ascii.eqlIgnoreCase(token, "rwin")) return MOD_WIN;
    return null;
}

/// A name from KEY_NAMES, or one of the aliases hand-edited profiles may use (a shifted OEM character, "Control", "LWin", "RWin").
fn parseBaseKey(key_text: []const u8) ?u32 {
    for (KEY_NAMES) |key| {
        if (std.ascii.eqlIgnoreCase(key.name, key_text)) return key.vk;
    }

    if (key_text.len == 1) {
        // '+' itself is never a valid base key here since it's the modifier-combo delimiter; only '=' maps to VK_OEM_PLUS.
        const shifted_vk: ?u32 = switch (key_text[0]) {
            ':' => VK_OEM_1,
            '<' => VK_OEM_COMMA,
            '_' => VK_OEM_MINUS,
            '>' => VK_OEM_PERIOD,
            '?' => VK_OEM_2,
            '~' => VK_OEM_3,
            '{' => VK_OEM_4,
            '|' => VK_OEM_5,
            '}' => VK_OEM_6,
            '"' => VK_OEM_7,
            else => null,
        };
        if (shifted_vk) |vk_code| return vk_code;
    }
    if (std.ascii.eqlIgnoreCase(key_text, "control")) return VK_CONTROL;
    if (std.ascii.eqlIgnoreCase(key_text, "lwin") or std.ascii.eqlIgnoreCase(key_text, "rwin")) return VK_LWIN;

    return null;
}

/// A combined value (see combineKey) from "F9", "Ctrl+Alt+F9", or the hex form older profiles saved ("0x0278").
/// Null for anything that isn't a bindable key; the caller logs it, with the setting it came from.
pub fn parseVirtualKey(key_text: []const u8) ?u32 {
    if (key_text.len == 0) return null;

    if (key_text.len >= 3 and key_text[0] == '0' and (key_text[1] == 'x' or key_text[1] == 'X')) {
        const hex_text = key_text[2..];
        const combined = std.fmt.parseInt(u32, hex_text, 16) catch return null;
        const vk_code = combined & VK_MASK;
        if (vk_code >= 0x01 and vk_code <= 0xFE) {
            return combined;
        }
        return null;
    }

    // Combo format: everything before the last '+' is modifiers, the final token is the key.
    if (std.mem.findScalarLast(u8, key_text, '+')) |last_plus| {
        const key_part = std.mem.trim(u8, key_text[last_plus + 1 ..], " ");
        var modifiers: u32 = 0;
        var it = std.mem.splitScalar(u8, key_text[0..last_plus], '+');
        while (it.next()) |tok| {
            const mod_name = std.mem.trim(u8, tok, " ");
            if (mod_name.len == 0) continue;
            const mod_bit = parseModifierToken(mod_name) orelse return null;
            modifiers |= mod_bit;
        }

        const vk_code = parseBaseKey(key_part) orelse return null;

        // e.g. "Shift+Shift" would otherwise parse into a binding that can never fire (its own bit is always excluded from the match).
        const self_referential = switch (vk_code) {
            VK_CONTROL => modifiers & MOD_CONTROL != 0,
            VK_MENU => modifiers & MOD_ALT != 0,
            VK_SHIFT => modifiers & MOD_SHIFT != 0,
            VK_LWIN => modifiers & MOD_WIN != 0,
            else => false,
        };
        if (self_referential) {
            slog.warn("Failed to parse hotkey '{s}': '{s}' is already its modifier", .{ key_text, key_part });
            return null;
        }

        return combineKey(vk_code, modifiers);
    }

    return parseBaseKey(key_text);
}

const testing = std.testing;

fn formatKey(buf: []u8, combined: u32) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    try writeVirtualKey(&writer, combined);
    return writer.buffered();
}

test "combineKey packs the key and modifiers so they extract back out" {
    const combined = combineKey(VK_F1, MOD_CONTROL | MOD_SHIFT);
    try testing.expectEqual(VK_F1, extractVk(combined));
    try testing.expectEqual(MOD_CONTROL | MOD_SHIFT, extractModifiers(combined));
    try testing.expectEqual(@as(u32, 0x0678), combineKey(0x78, MOD_CONTROL | MOD_SHIFT));
}

test "parseVirtualKey reads combos regardless of case and spacing" {
    const f9 = VK_F1 + 8;
    try testing.expectEqual(combineKey(f9, MOD_CONTROL | MOD_ALT), parseVirtualKey("Ctrl+Alt+F9").?);
    try testing.expectEqual(combineKey(f9, MOD_CONTROL), parseVirtualKey("ctrl + f9").?);
    try testing.expectEqual(combineKey(f9, MOD_CONTROL), parseVirtualKey("Control+F9").?);
    try testing.expectEqual(combineKey('A', MOD_WIN), parseVirtualKey("LWin+A").?);
    try testing.expectEqual(f9, parseVirtualKey("F9").?);
    try testing.expectEqual(VK_SHIFT, parseVirtualKey("Shift").?);
    try testing.expectEqual(combineKey(VK_SHIFT, MOD_CONTROL), parseVirtualKey("Ctrl+Shift").?);
}

test "parseVirtualKey reads the hex form older profiles saved" {
    try testing.expectEqual(combineKey(VK_F1 + 8, MOD_CONTROL), parseVirtualKey("0x0278").?);
    try testing.expect(parseVirtualKey("0x0200") == null);
    try testing.expect(parseVirtualKey("0x00FF") == null);
    try testing.expect(parseVirtualKey("0xZZ") == null);
}

test "parseVirtualKey accepts shifted OEM characters as their key" {
    try testing.expectEqual(VK_OEM_1, parseVirtualKey(":").?);
    try testing.expectEqual(VK_OEM_1, parseVirtualKey(";").?);
    try testing.expectEqual(combineKey(VK_OEM_4, MOD_ALT), parseVirtualKey("Alt+{").?);
}

test "parseVirtualKey rejects unknown names and self-referential modifiers" {
    try testing.expect(parseVirtualKey("") == null);
    try testing.expect(parseVirtualKey("Hyper+F9") == null);
    try testing.expect(parseVirtualKey("Ctrl+NotAKey") == null);
    try testing.expect(parseVirtualKey("Shift+Shift") == null);
    try testing.expect(parseVirtualKey("Ctrl+Control") == null);
    try testing.expect(parseVirtualKey("Win+LWin") == null);
}

test "writeVirtualKey writes back what parseVirtualKey reads" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "Ctrl+Shift+F9", "Alt+Numpad5", "Ctrl+Alt+Shift+Win+PageDown", "XButton1", "Shift+;" }) |text| {
        try testing.expectEqualStrings(text, try formatKey(&buf, parseVirtualKey(text).?));
    }
}

test "writeVirtualKey writes a key without a name as hex" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Ctrl+VKE8", try formatKey(&buf, combineKey(VK_FOCUS_GRANT, MOD_CONTROL)));
}

test "isMouseHookVk covers the mouse buttons and wheel only" {
    try testing.expect(isMouseHookVk(VK_MBUTTON) and isMouseHookVk(VK_XBUTTON1) and isMouseHookVk(VK_XBUTTON2));
    try testing.expect(isMouseHookVk(VK_WHEELUP) and isMouseHookVk(VK_WHEELDOWN));
    try testing.expect(!isMouseHookVk(VK_F1) and !isMouseHookVk('A'));
}
