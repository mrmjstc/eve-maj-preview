//! The hotkey field: recording a key combo from the window's own messages, showing combos as key caps, and typing them in directly; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const vk = @import("../../platform/virtual_keys.zig");
const key_list = @import("../../config/key_list.zig");
const hotkeys = @import("../../hotkeys/manager.zig");
const keyboard_hook = @import("../../hotkeys/keyboard_hook.zig");
const main = @import("../../main.zig");
const session = @import("session.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const KeyList = key_list.KeyList;
const slog = log.scoped("dialog_knots");

/// Matches writeVirtualKey's order.
const MODIFIER_ORDER = [_]struct { flag: u32, name: []const u8 }{
    .{ .flag = vk.MOD_CONTROL, .name = "Ctrl" },
    .{ .flag = vk.MOD_ALT, .name = "Alt" },
    .{ .flag = vk.MOD_SHIFT, .name = "Shift" },
    .{ .flag = vk.MOD_WIN, .name = "Win" },
};

const CLICK_TO_BIND = "Click to bind";
const RECORDING_PROMPT = "Press keys...";

/// Bindings that may share a combo with others of their own kind: characters cycle through each other, and hotkey groups through their members in group order.
const HolderKind = enum { other, character, group_forward, group_backward };

/// How many bindings hold a combo, and whether they're all of one kind.
const Holders = struct { total: usize = 0, kind: HolderKind = .other, is_mixed: bool = false };

/// A field waiting for a key; the window's messages feed it until something is captured or it's cancelled.
const Recording = struct {
    id: u64,
    /// Set by onWindowMessage or onWinKey; the field applies it on its next frame.
    captured: ?u32 = null,
};

/// A field being typed into, e.g. "Ctrl+1, 1".
const ManualEdit = struct {
    id: u64,
    /// Owned; freed when the edit ends.
    text: std.ArrayList(u8),
    was_focused: bool = false,
};

var g_allocator: std.mem.Allocator = undefined;
var g_recording: ?Recording = null;
/// Combos bound more than once, found by beginFrame; empty until it runs.
var g_conflicts: []const u32 = &.{};
var g_manual: ?ManualEdit = null;
/// Called once a capture arrives from outside a frame, so the window redraws to apply it.
var g_on_capture: ?*const fn () void = null;

pub fn init(allocator: std.mem.Allocator, on_capture: *const fn () void) void {
    g_allocator = allocator;
    g_on_capture = on_capture;
    keyboard_hook.g_on_win_key = onWinKey;
}

/// Once the window has closed.
pub fn reset() void {
    stopRecording();
    endManual();
    keyboard_hook.g_on_win_key = null;
}

/// From the window procedure while a field records: takes the keys, mouse buttons and wheel turns it binds; returns whether it consumed the message.
pub fn onWindowMessage(msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) bool {
    _ = lParam;
    const recording = &(g_recording orelse return false);
    switch (msg) {
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            const code: u32 = @truncate(wParam);
            if (code == win32.VK_ESCAPE or recording.captured != null or modifierFlag(code) != null) return true;
            // Modifier state at keyup only reflects modifiers still held, so the main key is taken here.
            if (vk.keyName(code) != null) capture(code, vk.currentModifiers());
            return true;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            const code: u32 = @truncate(wParam);
            if (code == win32.VK_ESCAPE) {
                stopRecording();
                redraw();
                return true;
            }
            // A modifier released alone is the key itself; the others still held are its modifiers.
            if (recording.captured == null) {
                if (modifierFlag(code)) |own| capture(if (code == vk.VK_LWIN + 1) vk.VK_LWIN else code, vk.currentModifiers() & ~own);
            }
            return true;
        },
        win32.WM_MBUTTONUP => {
            if (recording.captured == null) capture(vk.VK_MBUTTON, vk.currentModifiers());
            return true;
        },
        win32.WM_XBUTTONUP => {
            const button: u16 = @truncate(wParam >> 16);
            if (recording.captured == null) capture(if (button == 1) vk.VK_XBUTTON1 else vk.VK_XBUTTON2, vk.currentModifiers());
            return true;
        },
        win32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
            if (recording.captured == null) capture(if (delta > 0) vk.VK_WHEELUP else vk.VK_WHEELDOWN, vk.currentModifiers());
            return true;
        },
        else => return false,
    }
}

/// A bare Win press, which Windows hands to the Start Menu before the window sees it, so the keyboard hook reports it.
fn onWinKey(modifiers: u32) void {
    const recording = &(g_recording orelse return);
    if (recording.captured == null) capture(vk.VK_LWIN, modifiers);
}

/// The field: its combos as key caps (click to record a new one), a clear button, and in Advanced Mode a button to type them in.
/// `ref` is a session.Ref, or anything with the same get, set and index.
pub fn field(context: *ui.Frame, ref: anytype, comptime field_name: []const u8) !void {
    // Typed by the setting's struct, so a character's and a group's hotkey at the same index differ.
    const key = ui.Key.str("knots.hotkey:" ++ @typeName(@TypeOf(ref)) ++ "." ++ field_name).indexed(ref.index);
    const id = key.hash();
    const current: KeyList = ref.get(field_name);
    const is_conflict = isConflict(current);

    if (g_recording) |recording| {
        if (recording.id == id) {
            if (recording.captured) |combo| {
                // Once it holds the most a binding takes, a capture starts it over.
                var next: KeyList = if (current.len >= key_list.MAX_KEYS) .empty else current;
                _ = next.append(combo);
                ref.set(field_name, next);
                stopRecording();
            }
        }
    }

    const row = Rect{ .key = key.indexed(1), .style = &style.inline_row };
    _ = try row.open(context);
    if (editing(id)) |edit| {
        try manualBox(context, edit, ref, field_name, key);
    } else {
        const is_recording = isRecordingField(id);
        const box = Button{ .key = key, .style = if (is_recording) &style.hotkey_box_recording else if (is_conflict) &style.hotkey_box_conflict else &style.hotkey_box };
        const response = try box.openResponse(context);
        if (is_recording) {
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = RECORDING_PROMPT, .style = &style.hotkey_prompt });
        } else if (current.len == 0) {
            try context.e(Text{ .selectable = false, .key = key.indexed(2), .content = CLICK_TO_BIND, .style = &style.hotkey_placeholder });
        } else {
            try keycaps(context, key, current);
        }
        try box.close(context);
        if (response.clicked) {
            if (is_recording) stopRecording() else startRecording(id);
            context.requestRedraw();
        }
    }
    if ((try context.interact(Button{ .key = key.indexed(3), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
        if (isRecordingField(id)) stopRecording();
        if (editing(id) != null) endManual();
        ref.set(field_name, KeyList.empty);
    }
    if (session.global().get("advancedMode")) {
        const is_editing = editing(id) != null;
        if (try widgets.glyphButton(context, key.indexed(4), .pencil, "", if (is_editing) &style.hotkey_edit_on else &style.icon_button, false)) {
            if (is_editing) commitManual(ref, field_name) else try startManual(id, current);
        }
    }
    try row.close(context);
}

/// Finds this frame's conflicting combos; ones shared only within a HolderKind cycle instead, so those don't count.
pub fn beginFrame(arena: std.mem.Allocator) !void {
    var holders: std.AutoArrayHashMapUnmanaged(u32, Holders) = .empty;
    try collect(arena, &holders, session.profile().ptr, .other);
    try collect(arena, &holders, session.global().ptr, .other);
    var conflicts: std.ArrayList(u32) = .empty;
    var it = holders.iterator();
    while (it.next()) |entry| {
        const counted = entry.value_ptr.*;
        if (counted.total > 1 and (counted.is_mixed or counted.kind == .other)) try conflicts.append(arena, entry.key_ptr.*);
    }
    g_conflicts = conflicts.items;
}

/// Whether any of `keys` is bound elsewhere too; see beginFrame.
pub fn isConflict(keys: KeyList) bool {
    for (keys.slice()) |combo| {
        if (std.mem.findScalar(u32, g_conflicts, combo) != null) return true;
    }
    return false;
}

/// Every KeyList in `value`, however deeply nested, counted under the HolderKind of the field it sits in.
fn collect(arena: std.mem.Allocator, holders: *std.AutoArrayHashMapUnmanaged(u32, Holders), value: anytype, kind: HolderKind) !void {
    const T = @TypeOf(value.*);
    if (T == KeyList) {
        // One binding listing a combo twice still counts once.
        for (value.slice(), 0..) |combo, index| {
            if (std.mem.findScalar(u32, value.slice()[0..index], combo) != null) continue;
            const gop = try holders.getOrPut(arena, combo);
            if (!gop.found_existing) gop.value_ptr.* = .{ .kind = kind };
            gop.value_ptr.total += 1;
            if (gop.value_ptr.kind != kind) gop.value_ptr.is_mixed = true;
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (@hasField(T, "items") and @hasField(T, "capacity")) {
                for (value.items) |*item| try collect(arena, holders, item, kind);
                return;
            }
            inline for (info.field_names, info.field_types) |name, F| {
                if (comptime holdsKeys(F)) try collect(arena, holders, &@field(value, name), if (kind != .other) kind else comptime holderKind(name));
            }
        },
        .optional => if (value.*) |*inner| try collect(arena, holders, inner, kind),
        else => {},
    }
}

fn holderKind(comptime field_name: []const u8) HolderKind {
    if (std.mem.eql(u8, field_name, "characters")) return .character;
    if (std.mem.eql(u8, field_name, "forwardKey")) return .group_forward;
    if (std.mem.eql(u8, field_name, "backwardKey")) return .group_backward;
    return .other;
}

/// Whether a field's type can contain a KeyList, so the walk skips strings, numbers and the like.
fn holdsKeys(comptime T: type) bool {
    if (T == KeyList) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            if (@hasField(T, "items") and @hasField(T, "capacity")) break :blk holdsKeys(@typeInfo(@FieldType(T, "items")).pointer.child);
            for (info.field_types) |F| {
                if (holdsKeys(F)) break :blk true;
            }
            break :blk false;
        },
        .optional => |info| holdsKeys(info.child),
        else => false,
    };
}

/// Combos as the app spells them, e.g. "Ctrl+1, 1".
pub fn writeKeys(writer: *std.Io.Writer, keys: KeyList) !void {
    for (keys.slice(), 0..) |combo, index| {
        if (index > 0) try writer.writeAll(", ");
        try vk.writeVirtualKey(writer, combo);
    }
}

fn keycaps(context: *ui.Frame, key: ui.Key, keys: KeyList) !void {
    const arena = context.arena();
    var part_index: usize = 0;
    for (keys.slice(), 0..) |combo, combo_index| {
        if (combo_index > 0) {
            try context.e(Text{ .selectable = false, .key = key.indexed(100 + part_index), .content = ",", .style = &style.keycap_separator });
            part_index += 1;
        }
        const modifiers = vk.extractModifiers(combo);
        for (MODIFIER_ORDER) |modifier| {
            if (modifiers & modifier.flag == 0) continue;
            try cap(context, key.indexed(100 + part_index), modifier.name, true);
            try context.e(Text{ .selectable = false, .key = key.indexed(100 + part_index + 1), .content = "+", .style = &style.keycap_plus });
            part_index += 2;
        }
        const code = vk.extractVk(combo);
        const name = vk.keyName(code) orelse try std.fmt.allocPrint(arena, "VK{X}", .{code});
        try cap(context, key.indexed(100 + part_index), name, false);
        part_index += 1;
    }
}

fn cap(context: *ui.Frame, key: ui.Key, name: []const u8, is_modifier: bool) !void {
    try context.e(.{
        Rect{ .key = key, .style = &style.keycap },
        .{Text{ .selectable = false, .key = key.indexed(1), .content = try std.ascii.allocUpperString(context.arena(), name), .style = if (is_modifier) &style.keycap_modifier_text else &style.keycap_text }},
    });
}

fn manualBox(context: *ui.Frame, edit: *ManualEdit, ref: anytype, comptime field_name: []const u8, key: ui.Key) !void {
    const box_key = key.indexed(5);
    const is_focused = context.ui().focused(box_key.hash());
    // Enter, or leaving the box, applies what was typed.
    if ((is_focused and context.ui().input.containsKey(.enter)) or (edit.was_focused and !is_focused)) {
        commitManual(ref, field_name);
        context.requestRedraw();
        return;
    }
    edit.was_focused = is_focused;
    try context.e(TextInput{ .key = box_key, .buf = &edit.text, .style = &style.text_input });
}

fn isRecordingField(id: u64) bool {
    const recording = g_recording orelse return false;
    return recording.id == id;
}

/// The manual edit open on field `id`, if any.
fn editing(id: u64) ?*ManualEdit {
    const edit = &(g_manual orelse return null);
    return if (edit.id == id) edit else null;
}

fn startManual(id: u64, current: KeyList) !void {
    stopRecording();
    endManual();
    var text: std.Io.Writer.Allocating = .init(g_allocator);
    errdefer text.deinit();
    try writeKeys(&text.writer, current);
    g_manual = .{ .id = id, .text = text.toArrayList() };
}

/// Only names the app knows are kept; anything else, or more than a binding holds, leaves the field as it was.
fn commitManual(ref: anytype, comptime field_name: []const u8) void {
    const edit = g_manual orelse return;
    defer endManual();
    var keys: KeyList = .empty;
    var parts = std.mem.splitSequence(u8, edit.text.items, ", ");
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        const combo = vk.parseVirtualKey(trimmed) orelse {
            slog.warn("Failed to set hotkey: '{s}' is not a key the app can bind", .{trimmed});
            return;
        };
        if (!keys.append(combo)) {
            slog.warn("Failed to set hotkey: a hotkey holds at most {d} keys", .{key_list.MAX_KEYS});
            return;
        }
    }
    ref.set(field_name, keys);
}

fn endManual() void {
    if (g_manual) |*edit| edit.text.deinit(g_allocator);
    g_manual = null;
}

fn startRecording(id: u64) void {
    stopRecording();
    endManual();
    g_recording = .{ .id = id };
    // The low-level hooks swallow matched keys system-wide, so the window would never see a bound key otherwise.
    if (hotkeys.g_hotkey_manager_ptr) |manager| manager.dialogSuspendHotkeys();
}

fn stopRecording() void {
    if (g_recording == null) return;
    g_recording = null;
    const manager = hotkeys.g_hotkey_manager_ptr orelse return;
    const timer = main.g_timer_hwnd orelse return;
    manager.dialogResumeHotkeys(timer);
}

fn capture(code: u32, modifiers: u32) void {
    const recording = &(g_recording orelse return);
    recording.captured = vk.combineKey(code, modifiers);
    redraw();
}

fn redraw() void {
    if (g_on_capture) |on_capture| on_capture();
}

fn modifierFlag(code: u32) ?u32 {
    return switch (code) {
        vk.VK_CONTROL => vk.MOD_CONTROL,
        vk.VK_MENU => vk.MOD_ALT,
        vk.VK_SHIFT => vk.MOD_SHIFT,
        vk.VK_LWIN, vk.VK_LWIN + 1 => vk.MOD_WIN,
        else => null,
    };
}
