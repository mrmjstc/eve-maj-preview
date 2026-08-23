const std = @import("std");
const log = @import("log.zig");
const slog = log.scoped("virtual_keys");

pub const VK_F1: u32 = 0x70;
pub const VK_F24: u32 = 0x87;
pub const VK_TAB: u32 = 0x09;
pub const VK_PAUSE: u32 = 0x13;
pub const VK_CAPITAL: u32 = 0x14;
pub const VK_SHIFT: u32 = 0x10;
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
pub const VK_XBUTTON1: u32 = 0x05;
pub const VK_XBUTTON2: u32 = 0x06;
pub const VK_WHEELUP: u32 = 0x0A;
pub const VK_WHEELDOWN: u32 = 0x0B;
pub const VK_NUMPAD0: u32 = 0x60;
pub const VK_NUMPAD9: u32 = 0x69;
pub const VK_MULTIPLY: u32 = 0x6A;
pub const VK_ADD: u32 = 0x6B;
pub const VK_SUBTRACT: u32 = 0x6D;
pub const VK_DECIMAL: u32 = 0x6E;
pub const VK_DIVIDE: u32 = 0x6F;
pub const MOD_ALT: u32 = 0x0001;
pub const MOD_CONTROL: u32 = 0x0002;
pub const MOD_SHIFT: u32 = 0x0004;
pub const MOD_WIN: u32 = 0x0008;
const MOD_SHIFT_AMOUNT: u5 = 8;

const VK_MASK: u32 = 0xFF;
const MOD_MASK: u32 = 0x0F;

/// Extract the base virtual key code from a combined key+modifiers value
pub fn extractVk(combined: u32) u32 {
    return combined & VK_MASK;
}

/// Extract the modifier flags (MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN) from a combined value
pub fn extractModifiers(combined: u32) u32 {
    return (combined >> MOD_SHIFT_AMOUNT) & MOD_MASK;
}

/// Pack a base virtual key code and modifier flags into a single combined value
pub fn combineKey(vk_code: u32, modifiers: u32) u32 {
    return (vk_code & VK_MASK) | ((modifiers & MOD_MASK) << MOD_SHIFT_AMOUNT);
}

/// Whether a base virtual key code is a mouse button or wheel direction that must be routed
/// through the low-level mouse hook rather than RegisterHotKey (see hotkeys.zig / mouse_hook.zig)
pub fn isMouseHookVk(vk_code: u32) bool {
    return vk_code == VK_XBUTTON1 or vk_code == VK_XBUTTON2 or vk_code == VK_WHEELUP or vk_code == VK_WHEELDOWN;
}

/// Write virtual key code (plus any modifiers) as a human-readable string, e.g. "Ctrl+F9"
pub fn writeVirtualKey(writer: anytype, combined: u32) !void {
    const modifiers = extractModifiers(combined);
    if (modifiers & MOD_CONTROL != 0) try writer.writeAll("Ctrl+");
    if (modifiers & MOD_ALT != 0) try writer.writeAll("Alt+");
    if (modifiers & MOD_SHIFT != 0) try writer.writeAll("Shift+");
    if (modifiers & MOD_WIN != 0) try writer.writeAll("Win+");

    const vk_code = extractVk(combined);

    if (vk_code >= VK_F1 and vk_code <= VK_F24) {
        try writer.print("F{d}", .{vk_code - VK_F1 + 1});
        return;
    }

    if (vk_code >= 'A' and vk_code <= 'Z') {
        try writer.writeByte(@intCast(vk_code));
        return;
    }

    if (vk_code >= '0' and vk_code <= '9') {
        try writer.writeByte(@intCast(vk_code));
        return;
    }

    if (vk_code >= VK_NUMPAD0 and vk_code <= VK_NUMPAD9) {
        try writer.print("Numpad{d}", .{vk_code - VK_NUMPAD0});
        return;
    }

    const key_name: ?[]const u8 = switch (vk_code) {
        VK_TAB => "Tab",
        VK_PAUSE => "Pause",
        VK_CAPITAL => "CapsLock",
        VK_NUMLOCK => "NumLock",
        VK_SCROLL => "ScrollLock",
        VK_SPACE => "Space",
        VK_PRIOR => "PageUp",
        VK_NEXT => "PageDown",
        VK_END => "End",
        VK_HOME => "Home",
        VK_LEFT => "Left",
        VK_UP => "Up",
        VK_RIGHT => "Right",
        VK_DOWN => "Down",
        VK_INSERT => "Insert",
        VK_DELETE => "Delete",
        VK_MULTIPLY => "NumpadMultiply",
        VK_ADD => "NumpadAdd",
        VK_SUBTRACT => "NumpadSubtract",
        VK_DECIMAL => "NumpadDecimal",
        VK_DIVIDE => "NumpadDivide",
        VK_XBUTTON1 => "XButton1",
        VK_XBUTTON2 => "XButton2",
        VK_WHEELUP => "WheelUp",
        VK_WHEELDOWN => "WheelDown",
        VK_OEM_1 => ";",
        VK_OEM_PLUS => "=",
        VK_OEM_COMMA => ",",
        VK_OEM_MINUS => "-",
        VK_OEM_PERIOD => ".",
        VK_OEM_2 => "/",
        VK_OEM_3 => "`",
        VK_OEM_4 => "[",
        VK_OEM_5 => "\\",
        VK_OEM_6 => "]",
        VK_OEM_7 => "'",
        else => null,
    };

    if (key_name) |name| {
        try writer.writeAll(name);
    } else {
        try writer.print("VK{X}", .{vk_code});
    }
}

/// Parse a single modifier token ("Ctrl", "Control", "Alt", "Shift", "Win", "LWin", "RWin").
/// Returns null if the token isn't a recognized modifier name.
fn parseModifierToken(token: []const u8) ?u32 {
    var lower_buf: [16]u8 = undefined;
    if (token.len == 0 or token.len > lower_buf.len) return null;
    const lower = std.ascii.lowerString(lower_buf[0..token.len], token);

    if (std.mem.eql(u8, lower, "ctrl") or std.mem.eql(u8, lower, "control")) return MOD_CONTROL;
    if (std.mem.eql(u8, lower, "alt")) return MOD_ALT;
    if (std.mem.eql(u8, lower, "shift")) return MOD_SHIFT;
    if (std.mem.eql(u8, lower, "win") or std.mem.eql(u8, lower, "lwin") or std.mem.eql(u8, lower, "rwin")) return MOD_WIN;
    return null;
}

/// Parse a single (non-combo) key token into its base virtual key code.
/// Supports: F1-F24, A-Z, 0-9, ; = , - . / ` [ \ ] ', Space, PageUp, PageDown, End, Home,
///           Left, Up, Right, Down, Insert, Delete, Numpad0-Numpad9, NumpadMultiply,
///           NumpadAdd, NumpadSubtract, NumpadDecimal, NumpadDivide
fn parseBaseKey(key_str: []const u8) ?u32 {
    if (key_str.len == 0) return null;

    if (key_str.len == 1) {
        const ch = std.ascii.toUpper(key_str[0]);
        if (ch >= 'A' and ch <= 'Z') {
            return ch;
        }
        if (ch >= '0' and ch <= '9') {
            return ch;
        }

        // OEM punctuation keys - see the VK_OEM_* comments above for why '+' is excluded.
        const oem_vk: ?u32 = switch (key_str[0]) {
            ';', ':' => VK_OEM_1,
            '=' => VK_OEM_PLUS,
            ',', '<' => VK_OEM_COMMA,
            '-', '_' => VK_OEM_MINUS,
            '.', '>' => VK_OEM_PERIOD,
            '/', '?' => VK_OEM_2,
            '`', '~' => VK_OEM_3,
            '[', '{' => VK_OEM_4,
            '\\', '|' => VK_OEM_5,
            ']', '}' => VK_OEM_6,
            '\'', '"' => VK_OEM_7,
            else => null,
        };
        if (oem_vk) |vk_code| return vk_code;
    }

    if (key_str.len >= 2 and (key_str[0] == 'F' or key_str[0] == 'f')) {
        const num_str = key_str[1..];
        const num = std.fmt.parseInt(u32, num_str, 10) catch return null;
        if (num >= 1 and num <= 24) {
            return VK_F1 + (num - 1);
        }
    }

    var lower_buf: [32]u8 = undefined;
    if (key_str.len > lower_buf.len) {
        slog.warn("Key name too long: '{s}'", .{key_str});
        return null;
    }
    const lower = std.ascii.lowerString(lower_buf[0..key_str.len], key_str);

    if (std.mem.eql(u8, lower, "tab")) return VK_TAB;
    if (std.mem.eql(u8, lower, "pause")) return VK_PAUSE;
    if (std.mem.eql(u8, lower, "capslock")) return VK_CAPITAL;
    if (std.mem.eql(u8, lower, "numlock")) return VK_NUMLOCK;
    if (std.mem.eql(u8, lower, "scrolllock")) return VK_SCROLL;
    if (std.mem.eql(u8, lower, "space")) return VK_SPACE;
    if (std.mem.eql(u8, lower, "pageup")) return VK_PRIOR;
    if (std.mem.eql(u8, lower, "pagedown")) return VK_NEXT;
    if (std.mem.eql(u8, lower, "end")) return VK_END;
    if (std.mem.eql(u8, lower, "home")) return VK_HOME;
    if (std.mem.eql(u8, lower, "left")) return VK_LEFT;
    if (std.mem.eql(u8, lower, "up")) return VK_UP;
    if (std.mem.eql(u8, lower, "right")) return VK_RIGHT;
    if (std.mem.eql(u8, lower, "down")) return VK_DOWN;
    if (std.mem.eql(u8, lower, "insert")) return VK_INSERT;
    if (std.mem.eql(u8, lower, "delete")) return VK_DELETE;
    if (std.mem.eql(u8, lower, "xbutton1")) return VK_XBUTTON1;
    if (std.mem.eql(u8, lower, "xbutton2")) return VK_XBUTTON2;
    if (std.mem.eql(u8, lower, "wheelup")) return VK_WHEELUP;
    if (std.mem.eql(u8, lower, "wheeldown")) return VK_WHEELDOWN;

    if (std.mem.startsWith(u8, lower, "numpad")) {
        const rest = lower["numpad".len..];
        if (rest.len == 1 and rest[0] >= '0' and rest[0] <= '9') {
            return VK_NUMPAD0 + (rest[0] - '0');
        }
        if (std.mem.eql(u8, rest, "multiply")) return VK_MULTIPLY;
        if (std.mem.eql(u8, rest, "add")) return VK_ADD;
        if (std.mem.eql(u8, rest, "subtract")) return VK_SUBTRACT;
        if (std.mem.eql(u8, rest, "decimal")) return VK_DECIMAL;
        if (std.mem.eql(u8, rest, "divide")) return VK_DIVIDE;
    }

    slog.warn("Unrecognized key format: '{s}'", .{key_str});
    return null;
}

/// Parse virtual key (+ optional modifiers) from a string.
/// Accepts a plain key ("F9"), a modifier combo ("Ctrl+Alt+F9", "LWin+M"), or a raw
/// hex-encoded combined value ("0x0278") as previously written to disk.
/// Returns a combined value packing the base virtual key in the low byte and modifier
/// flags in bits 8-11 - see combineKey/extractVk/extractModifiers.
pub fn parseVirtualKey(key_str: []const u8) ?u32 {
    if (key_str.len == 0) return null;

    if (key_str.len >= 3 and key_str[0] == '0' and (key_str[1] == 'x' or key_str[1] == 'X')) {
        const hex_str = key_str[2..];
        const combined = std.fmt.parseInt(u32, hex_str, 16) catch return null;
        const vk_code = combined & VK_MASK;
        if (vk_code >= 0x01 and vk_code <= 0xFE) {
            return combined;
        }
        return null;
    }

    // Combo format: everything before the last '+' is modifiers, the final token is the key.
    if (std.mem.lastIndexOfScalar(u8, key_str, '+')) |last_plus| {
        const key_part = std.mem.trim(u8, key_str[last_plus + 1 ..], " ");
        var modifiers: u32 = 0;
        var it = std.mem.splitScalar(u8, key_str[0..last_plus], '+');
        while (it.next()) |tok| {
            const mod_name = std.mem.trim(u8, tok, " ");
            if (mod_name.len == 0) continue;
            const mod_bit = parseModifierToken(mod_name) orelse {
                slog.warn("Unrecognized modifier: '{s}'", .{mod_name});
                return null;
            };
            modifiers |= mod_bit;
        }

        const vk_code = parseBaseKey(key_part) orelse return null;
        return combineKey(vk_code, modifiers);
    }

    return parseBaseKey(key_str);
}
