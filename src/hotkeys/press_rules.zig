//! Which presses the low-level hooks pass on as hotkeys and which they swallow; no I/O.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const vk = @import("../platform/virtual_keys.zig");

/// Far more clients and window-filter matches than anyone runs.
const MAX_FOCUS_WINDOWS = 128;

/// What the require-EVE-focus setting checks a match against; built by the main thread, with a copy kept on the hook thread.
pub const FocusFilter = struct {
    is_required: bool = false,
    /// Matches anywhere, so the suspend hotkey still resumes outside EVE.
    exempt_id: ?c_int = null,
    /// Every tracked window, window-filter matches included, as HotkeyManager.foregroundEveWindow counts them.
    windows: [MAX_FOCUS_WINDOWS]win32.HWND = undefined,
    window_count: usize = 0,

    /// False once full, leaving `hwnd` out.
    pub fn add(self: *FocusFilter, hwnd: win32.HWND) bool {
        if (self.window_count == self.windows.len) return false;
        self.windows[self.window_count] = hwnd;
        self.window_count += 1;
        return true;
    }

    pub fn eql(self: *const FocusFilter, other: *const FocusFilter) bool {
        return self.is_required == other.is_required and
            std.meta.eql(self.exempt_id, other.exempt_id) and
            std.mem.eql(win32.HWND, self.windows[0..self.window_count], other.windows[0..other.window_count]);
    }

    pub fn allows(self: *const FocusFilter, id: c_int, foreground: ?win32.HWND) bool {
        if (!self.is_required) return true;
        if (self.exempt_id) |exempt_id| {
            if (id == exempt_id) return true;
        }
        const window = foreground orelse return false;
        return std.mem.indexOfScalar(win32.HWND, self.windows[0..self.window_count], window) != null;
    }
};

/// One event as the keyboard hook reports it.
pub const KeyEvent = struct {
    vk_code: u8,
    is_key_up: bool,
    is_extended: bool,
    timestamp_ms: u32,
};

/// What a key-down asks of the hook.
pub const Down = enum {
    /// Its press was passed through, so this goes through too, unmatched.
    pass,
    /// Its press was swallowed: dispatch it as a repeat and swallow it.
    repeat,
    /// A new press: match it, then record the verdict with `decide`.
    first,
};

/// Every key's press as decided at its first key-down, so an app sees whole presses or none; hook thread only.
pub const KeyPresses = struct {
    presses: [256]Press = @splat(.released),
    /// The last event, if it was a Shift release.
    shift_release: ?ShiftRelease = null,
    /// The navigation key pressed as Shift+Numpad.
    shifted_navigation_vk: ?u8 = null,

    const Press = enum { released, swallowed, passed };

    const ShiftRelease = struct { timestamp_ms: u32, is_extended: bool };

    pub fn keyDown(self: *KeyPresses, vk_code: u8, is_shifted_numpad: bool) Down {
        if (is_shifted_numpad) self.shifted_navigation_vk = vk_code;
        return switch (self.presses[vk_code]) {
            .released => .first,
            .swallowed => .repeat,
            .passed => .pass,
        };
    }

    /// After a `.first` keyDown: whether its press, repeats and release are swallowed.
    pub fn decide(self: *KeyPresses, vk_code: u8, is_swallowed: bool) void {
        self.presses[vk_code] = if (is_swallowed) .swallowed else .passed;
    }

    /// Whether to swallow it: a client given a key-up it never saw go down drops its held modifiers, which would break holding Ctrl through a cycle.
    pub fn keyUp(self: *KeyPresses, vk_code: u8) bool {
        const press = self.presses[vk_code];
        self.presses[vk_code] = .released;
        if (self.isShiftedNavigation(vk_code)) self.shifted_navigation_vk = null;
        // The conduit hotkey only consumes the down; a stray up reaching the new client makes it drop held modifiers.
        if (vk_code == vk.VK_FOCUS_GRANT) return true;
        return press == .swallowed;
    }

    /// After every event, so a Shift release is remembered only until the next.
    pub fn noteEvent(self: *KeyPresses, event: KeyEvent) void {
        const is_shift_release = event.is_key_up and (event.vk_code == vk.VK_LSHIFT or event.vk_code == vk.VK_RSHIFT);
        self.shift_release = if (is_shift_release) .{ .timestamp_ms = event.timestamp_ms, .is_extended = event.is_extended } else null;
    }

    /// With NumLock on, Windows sends Shift+Numpad as a Shift release it marks extended or stamps with the key's time, then the navigation key.
    pub fn isShiftedNumpad(self: *const KeyPresses, event: KeyEvent) bool {
        if (event.is_extended or vk.numpadForNavigation(event.vk_code) == null) return false;
        const release = self.shift_release orelse return false;
        return release.is_extended or release.timestamp_ms == event.timestamp_ms;
    }

    pub fn isShiftedNavigation(self: *const KeyPresses, vk_code: u32) bool {
        const shifted = self.shifted_navigation_vk orelse return false;
        return shifted == vk_code;
    }
};

/// The hotkey ID a press fires: its exact combo, else its bare key's unless `requires_exact_modifiers`, so a held modifier can't block it.
pub fn bindingFor(map: *const std.AutoHashMap(u32, c_int), base_vk: u32, modifiers: u32, requires_exact_modifiers: bool) ?c_int {
    if (map.get(vk.combineKey(base_vk, modifiers))) |id| return id;
    if (modifiers == 0 or requires_exact_modifiers) return null;
    return map.get(vk.combineKey(base_vk, 0));
}

const testing = std.testing;
const SUSPEND_ID: c_int = 1001;

fn bindingMap(entries: []const struct { u32, c_int }) !std.AutoHashMap(u32, c_int) {
    var map: std.AutoHashMap(u32, c_int) = .init(testing.allocator);
    errdefer map.deinit();
    for (entries) |entry| try map.put(entry[0], entry[1]);
    return map;
}

fn fakeHwnd(value: usize) win32.HWND {
    return @ptrFromInt(value);
}

fn keyPress(vk_code: u8, timestamp_ms: u32) KeyEvent {
    return .{ .vk_code = vk_code, .is_key_up = false, .is_extended = false, .timestamp_ms = timestamp_ms };
}

test "a press fires its exact combo's hotkey before its bare key's" {
    var map = try bindingMap(&.{ .{ vk.combineKey('A', vk.MOD_CONTROL), 1 }, .{ vk.combineKey('A', 0), 2 } });
    defer map.deinit();
    try testing.expectEqual(@as(?c_int, 1), bindingFor(&map, 'A', vk.MOD_CONTROL, false));
    try testing.expectEqual(@as(?c_int, 2), bindingFor(&map, 'A', 0, false));
}

test "an unbound combo falls back to its bare key unless modifiers must match exactly" {
    var map = try bindingMap(&.{.{ vk.combineKey('A', 0), 2 }});
    defer map.deinit();
    try testing.expectEqual(@as(?c_int, 2), bindingFor(&map, 'A', vk.MOD_CONTROL | vk.MOD_SHIFT, false));
    try testing.expectEqual(@as(?c_int, null), bindingFor(&map, 'A', vk.MOD_CONTROL, true));
}

test "a modified binding never fires for its bare key" {
    var map = try bindingMap(&.{.{ vk.combineKey('A', vk.MOD_CONTROL), 1 }});
    defer map.deinit();
    try testing.expectEqual(@as(?c_int, null), bindingFor(&map, 'A', 0, false));
    try testing.expectEqual(@as(?c_int, null), bindingFor(&map, 'B', vk.MOD_CONTROL, false));
}

test "the focus filter lets everything through unless EVE focus is required" {
    const filter: FocusFilter = .{};
    try testing.expect(filter.allows(7, null));
    try testing.expect(filter.allows(7, fakeHwnd(99)));
}

test "with EVE focus required, only a tracked foreground window passes" {
    var filter: FocusFilter = .{ .is_required = true };
    try testing.expect(filter.add(fakeHwnd(10)));
    try testing.expect(filter.allows(7, fakeHwnd(10)));
    try testing.expect(!filter.allows(7, fakeHwnd(11)));
    try testing.expect(!filter.allows(7, null));
}

test "the exempt hotkey passes outside EVE, so suspend can still resume" {
    const filter: FocusFilter = .{ .is_required = true, .exempt_id = SUSPEND_ID };
    try testing.expect(filter.allows(SUSPEND_ID, fakeHwnd(11)));
    try testing.expect(filter.allows(SUSPEND_ID, null));
    try testing.expect(!filter.allows(7, fakeHwnd(11)));
}

test "the focus filter refuses windows past its capacity" {
    var filter: FocusFilter = .{};
    for (0..MAX_FOCUS_WINDOWS) |i| try testing.expect(filter.add(fakeHwnd(i + 1)));
    try testing.expect(!filter.add(fakeHwnd(MAX_FOCUS_WINDOWS + 1)));
}

test "focus filters compare by setting and tracked windows only" {
    var first: FocusFilter = .{ .is_required = true };
    var second: FocusFilter = .{ .is_required = true };
    _ = first.add(fakeHwnd(10));
    _ = second.add(fakeHwnd(10));
    try testing.expect(first.eql(&second));
    _ = second.add(fakeHwnd(11));
    try testing.expect(!first.eql(&second));
    second = .{ .is_required = true, .exempt_id = SUSPEND_ID };
    _ = second.add(fakeHwnd(10));
    try testing.expect(!first.eql(&second));
}

test "a swallowed press swallows its repeats and its release" {
    var presses: KeyPresses = .{};
    try testing.expectEqual(Down.first, presses.keyDown('A', false));
    presses.decide('A', true);
    try testing.expectEqual(Down.repeat, presses.keyDown('A', false));
    try testing.expect(presses.keyUp('A'));
    try testing.expectEqual(Down.first, presses.keyDown('A', false));
}

test "a passed press passes its repeats and its release" {
    var presses: KeyPresses = .{};
    try testing.expectEqual(Down.first, presses.keyDown('A', false));
    presses.decide('A', false);
    try testing.expectEqual(Down.pass, presses.keyDown('A', false));
    try testing.expect(!presses.keyUp('A'));
}

test "a release whose press the hook never saw goes through" {
    var presses: KeyPresses = .{};
    try testing.expect(!presses.keyUp(vk.VK_LCONTROL));
}

test "keys are decided independently" {
    var presses: KeyPresses = .{};
    _ = presses.keyDown(vk.VK_LCONTROL, false);
    presses.decide(vk.VK_LCONTROL, false);
    _ = presses.keyDown('A', false);
    presses.decide('A', true);
    try testing.expect(presses.keyUp('A'));
    try testing.expect(!presses.keyUp(vk.VK_LCONTROL));
}

test "the focus grant key's release is always swallowed" {
    var presses: KeyPresses = .{};
    try testing.expect(presses.keyUp(vk.VK_FOCUS_GRANT));
    _ = presses.keyDown(vk.VK_FOCUS_GRANT, false);
    presses.decide(vk.VK_FOCUS_GRANT, false);
    try testing.expect(presses.keyUp(vk.VK_FOCUS_GRANT));
}

test "a navigation key after an extended Shift release is Shift+Numpad" {
    var presses: KeyPresses = .{};
    presses.noteEvent(.{ .vk_code = vk.VK_LSHIFT, .is_key_up = true, .is_extended = true, .timestamp_ms = 500 });
    try testing.expect(presses.isShiftedNumpad(keyPress(vk.VK_END, 900)));
}

test "a navigation key stamped with the Shift release's time is Shift+Numpad" {
    var presses: KeyPresses = .{};
    presses.noteEvent(.{ .vk_code = vk.VK_RSHIFT, .is_key_up = true, .is_extended = false, .timestamp_ms = 500 });
    try testing.expect(presses.isShiftedNumpad(keyPress(vk.VK_END, 500)));
    try testing.expect(!presses.isShiftedNumpad(keyPress(vk.VK_END, 501)));
}

test "an extended or non-navigation key is never Shift+Numpad" {
    var presses: KeyPresses = .{};
    presses.noteEvent(.{ .vk_code = vk.VK_LSHIFT, .is_key_up = true, .is_extended = true, .timestamp_ms = 500 });
    try testing.expect(!presses.isShiftedNumpad(.{ .vk_code = vk.VK_END, .is_key_up = false, .is_extended = true, .timestamp_ms = 500 }));
    try testing.expect(!presses.isShiftedNumpad(keyPress('A', 500)));
}

test "a Shift release is forgotten after the next event, and a Shift press isn't one" {
    var presses: KeyPresses = .{};
    presses.noteEvent(.{ .vk_code = vk.VK_LSHIFT, .is_key_up = true, .is_extended = true, .timestamp_ms = 500 });
    presses.noteEvent(keyPress('A', 600));
    try testing.expect(!presses.isShiftedNumpad(keyPress(vk.VK_END, 600)));
    presses.noteEvent(.{ .vk_code = vk.VK_LSHIFT, .is_key_up = false, .is_extended = true, .timestamp_ms = 700 });
    try testing.expect(!presses.isShiftedNumpad(keyPress(vk.VK_END, 700)));
}

test "a Shift+Numpad press is remembered until its release" {
    var presses: KeyPresses = .{};
    _ = presses.keyDown(vk.VK_END, true);
    try testing.expect(presses.isShiftedNavigation(vk.VK_END));
    try testing.expect(!presses.isShiftedNavigation(vk.VK_HOME));
    _ = presses.keyUp(vk.VK_END);
    try testing.expect(!presses.isShiftedNavigation(vk.VK_END));
}
