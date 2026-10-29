//! The hotkey field: recording a key combo from the window's own messages, showing combos as key caps, and typing them in directly; main thread only.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const vk = @import("../../platform/virtual_keys.zig");
const config = @import("../../config.zig");
const key_list = @import("../../config/key_list.zig");
const keyboard_hook = @import("../../hotkeys/keyboard_hook.zig");
const session = @import("session.zig");
const labels = @import("labels.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const Tooltip = ui.component.Tooltip;
const KeyList = key_list.KeyList;
const slog = log.Scoped("dialog_knots");

/// Matches writeVirtualKey's order.
const MODIFIER_ORDER = [_]struct { flag: u32, name: []const u8 }{
    .{ .flag = vk.MOD_CONTROL, .name = "Ctrl" },
    .{ .flag = vk.MOD_ALT, .name = "Alt" },
    .{ .flag = vk.MOD_SHIFT, .name = "Shift" },
    .{ .flag = vk.MOD_WIN, .name = "Win" },
};

const SET_KEY = "Set key";
const ADD_KEY = "Add another key";
const RECORDING_PROMPT = "Press keys...";
/// The field keys each combo, and the "or" before it, as its own key indexed past these, clear of its other parts.
const COMBO_KEY_BASE = 20;
const OR_KEY_BASE = 30;
/// A combo's caps start here, clear of its button's own indexed keys.
const KEYCAP_KEY_BASE = 100;
/// How writeHolders names each of a hotkey group's keys.
const GROUP_KEY_LABELS = [_]struct { field: []const u8, label: []const u8 }{
    .{ .field = "forwardKey", .label = "Group '{name}' (forward)" },
    .{ .field = "backwardKey", .label = "Group '{name}' (back)" },
    .{ .field = "assignKey", .label = "Group '{name}' (assign)" },
    .{ .field = "minimizeKey", .label = "Group '{name}' (minimize)" },
    .{ .field = "closeKey", .label = "Group '{name}' (close)" },
};

comptime {
    var key_count = 0;
    for (@typeInfo(config.HotkeyGroupConfig).@"struct".field_types) |F| {
        if (F == KeyList) key_count += 1;
    }
    std.debug.assert(key_count == GROUP_KEY_LABELS.len);
}

/// Bindings that may share a combo with their own kind, cycling through each other in order.
const HolderKind = enum { other, character, group_forward, group_backward };

const Holders = struct { total: usize = 0, kind: HolderKind = .other, is_mixed: bool = false };

/// A field waiting for a key; the window's messages feed it until something is captured or it's cancelled.
const Recording = struct {
    id: u64,
    /// The combo the capture replaces, or null to add one.
    slot: ?usize,
    /// Set by onWindowMessage or onWinKey; the field applies it on its next frame.
    captured: ?u32 = null,
    /// MOD_* flags held so far, shown in the recording label before the key that completes the combo.
    held: u32 = 0,
    /// Set by the fake Shift release before a Shift+Numpad press.
    is_shift_faked: bool = false,
};

/// What a combo's caps or remove button asked for this frame.
const ComboAction = enum { none, replace, remove };

/// A field being typed into, e.g. "Ctrl+1, 1".
const ManualEdit = struct {
    id: u64,
    /// Owned; freed when the edit ends.
    text: std.ArrayList(u8),
    was_focused: bool = false,
};

var g_allocator: std.mem.Allocator = undefined;
var g_recording: ?Recording = null;
/// Combos bound more than once, found by beginFrame; borrows from that frame's arena, so only that frame may read it.
var g_conflicts: []const u32 = &.{};
var g_manual: ?ManualEdit = null;
/// Called once a capture arrives from outside a frame, so the window redraws to apply it.
var g_on_capture: ?*const fn () void = null;
/// A field changed outside a frame; the frame drawing it asks for one more, since its row measures it a frame late.
var g_is_layout_stale: bool = false;

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

/// From the window procedure while a field records; returns whether it consumed the message.
pub fn onWindowMessage(msg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) bool {
    const recording = if (g_recording) |*active| active else return false;
    switch (msg) {
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN => {
            const virtual_key: u32 = @truncate(wParam);
            if (virtual_key == win32.VK_ESCAPE or recording.captured != null) return true;
            if (recording.is_shift_faked and lParam & win32.KEY_EXTENDED_BIT == 0) {
                if (vk.numpadForNavigation(virtual_key)) |numpad| {
                    capture(numpad, vk.currentModifiers() | vk.MOD_SHIFT);
                    return true;
                }
            }
            if (modifierFlag(virtual_key)) |own| {
                const held = vk.currentModifiers() | own;
                // Key repeat sends this again while the modifier is held.
                if (held != recording.held) {
                    recording.held = held;
                    redraw();
                }
                return true;
            }
            // Modifier state at keyup only reflects modifiers still held, so the main key is taken here.
            if (vk.keyName(virtual_key) != null) capture(virtual_key, vk.currentModifiers());
            return true;
        },
        win32.WM_KEYUP, win32.WM_SYSKEYUP => {
            const virtual_key: u32 = @truncate(wParam);
            if (virtual_key == win32.VK_ESCAPE) {
                stopRecording();
                redraw();
                return true;
            }
            if (recording.captured == null) {
                if (virtual_key == vk.VK_SHIFT and isFakeShiftRelease(lParam)) {
                    recording.is_shift_faked = true;
                    return true;
                }
                // A modifier released alone is the key itself; the others still held are its modifiers.
                if (modifierFlag(virtual_key)) |own| capture(if (virtual_key == vk.VK_RWIN) vk.VK_LWIN else virtual_key, vk.currentModifiers() & ~own);
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

/// Each combo as key caps joined by "or", each removable on its own, then + to add one, plus a typing button in Advanced Mode; `ref` needs session.Ref's get, set and index.
pub fn field(context: *ui.Frame, ref: anytype, comptime field_name: []const u8) !void {
    // Typed by the setting's struct, so a character's and a group's hotkey at the same index differ.
    const key = ui.Key.str("knots.hotkey:" ++ @typeName(@TypeOf(ref)) ++ "." ++ field_name).indexed(ref.index);
    const id = key.hash();
    var current: KeyList = ref.get(field_name);

    if (g_recording) |recording| {
        if (recording.id == id) {
            if (recording.captured) |combo| {
                applyCapture(&current, recording.slot, combo);
                ref.set(field_name, current);
                stopRecording();
                context.requestRedraw();
            }
        }
    }

    // A click on the row's label does what the + does.
    if (widgets.takeRowClick() and !isRecordingField(id) and manualEditFor(id) == null and current.len < key_list.MAX_KEYS) startRecording(context, id, null);

    const width = widgets.hotkeyWidth();
    // knots offsets an end-justified row before growing its children, so the typing box, which grows in a detail pane, keeps a start-justified row.
    const row_style = if (width != null) &style.hotkey_row_fit else if (manualEditFor(id) != null) &style.hotkey_row_typing else &style.hotkey_row;
    const keycaps = if (try needsCompact(context, current)) &style.keycaps_compact else &style.keycaps;
    const row = Rect{ .key = key.indexed(1), .style = try withGap(context, row_style, keycaps.size.combo_gap) };
    _ = try row.open(context);
    if (manualEditFor(id)) |edit| {
        try manualBox(context, edit, ref, field_name, key, width);
    } else {
        var removed: ?usize = null;
        const shows_remove = widgets.isRowLit() or hasComboFocus(context, key, current.len);
        for (current.slice(), 0..) |combo, index| {
            if (index > 0) try orText(context, key.indexed(OR_KEY_BASE + index), keycaps);
            const combo_key = key.indexed(COMBO_KEY_BASE + index);
            if (isRecordingSlot(id, index)) {
                try recordingLabel(context, combo_key, keycaps);
                continue;
            }
            switch (try comboControl(context, combo_key, combo, keycaps, shows_remove)) {
                .none => {},
                .replace => startRecording(context, id, index),
                .remove => removed = index,
            }
        }
        if (isRecordingSlot(id, null)) {
            if (current.len > 0) try orText(context, key.indexed(OR_KEY_BASE), keycaps);
            try recordingLabel(context, key.indexed(6), keycaps);
        }
        // The same + throughout, so the row doesn't change under the pointer; a second click cancels.
        if (current.len < key_list.MAX_KEYS) {
            if (try addKeyButton(context, key.indexed(7), if (current.len == 0) SET_KEY else ADD_KEY)) {
                if (isRecordingField(id)) cancelRecording(context) else startRecording(context, id, null);
            }
        }
        if (removed) |index| {
            // A recording into a later slot would land on the wrong combo once the rest move up.
            if (isRecordingField(id)) stopRecording();
            current.remove(index);
            ref.set(field_name, current);
            context.requestRedraw();
        }
    }
    if (session.global().get("advancedMode")) {
        const is_editing = manualEditFor(id) != null;
        if (try widgets.glyphButton(context, key.indexed(4), .pencil, "", if (is_editing) &style.hotkey_edit_on else &style.icon_button, false)) {
            if (is_editing) commitManual(ref, field_name) else try startManual(id, current);
            // The row was drawn before the click switched it, so the box or the keys show from the next frame.
            context.requestRedraw();
        }
    }
    try row.close(context);
}

pub fn beginFrame(context: *ui.Frame) !void {
    if (g_is_layout_stale) {
        g_is_layout_stale = false;
        context.requestRedraw();
    }
    g_conflicts = try findConflicts(context.arena());
}

/// Combos the edited documents bind more than once outside one HolderKind cycle; allocated in `arena`.
pub fn findConflicts(arena: std.mem.Allocator) ![]const u32 {
    var holders: std.AutoArrayHashMapUnmanaged(u32, Holders) = .empty;
    try collect(arena, &holders, session.profile().ptr, .other);
    try collect(arena, &holders, session.global().ptr, .other);
    var conflicts: std.ArrayList(u32) = .empty;
    var it = holders.iterator();
    while (it.next()) |entry| {
        const counted = entry.value_ptr.*;
        if (counted.total > 1 and (counted.is_mixed or counted.kind == .other)) try conflicts.append(arena, entry.key_ptr.*);
    }
    return conflicts.items;
}

/// Every binding in the edited documents holding `combo`, named as the window shows it and joined with ", "; names are made in `arena`.
pub fn writeHolders(arena: std.mem.Allocator, writer: *std.Io.Writer, combo: u32) !void {
    var names: std.ArrayList([]const u8) = .empty;
    const profile = session.profile().ptr;
    const global = session.global().ptr;
    try addFixedHolders(arena, &names, &profile.hotkeys, combo);
    for (profile.characters.items) |character| {
        if (holds(character.hotkey, combo)) try names.append(arena, try lang.format(arena, "Character '{name}'", .{ .name = character.name }));
    }
    for (profile.hotkeyGroups.items) |group| {
        inline for (GROUP_KEY_LABELS) |group_key| {
            if (holds(@field(group, group_key.field), combo)) try names.append(arena, try lang.format(arena, group_key.label, .{ .name = group.name }));
        }
    }
    try addFixedHolders(arena, &names, global, combo);
    for (global.profileSwitchHotkeys.items) |entry| {
        if (holds(entry.hotkey, combo)) try names.append(arena, try lang.format(arena, "Switch to: {name}", .{ .name = config.profileDisplayName(entry.targetProfile) }));
    }
    for (global.appHotkeys.items) |entry| {
        if (holds(entry.hotkey, combo)) try names.append(arena, try lang.format(arena, "App '{name}'", .{ .name = entry.executableName }));
    }
    for (global.urlHotkeys.items) |entry| {
        if (holds(entry.hotkey, combo)) try names.append(arena, try lang.format(arena, "URL '{url}'", .{ .url = entry.url }));
    }
    for (names.items, 0..) |name, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeAll(name);
    }
}

/// Combos as the app spells them, e.g. "Ctrl+1, 1".
pub fn writeKeys(writer: *std.Io.Writer, keys: KeyList) !void {
    try writeCombos(writer, keys.slice());
}

pub fn writeCombos(writer: *std.Io.Writer, combos: []const u32) !void {
    for (combos, 0..) |combo, index| {
        if (index > 0) try writer.writeAll(", ");
        try vk.writeVirtualKey(writer, combo);
    }
}

/// `settings` points to a struct whose KeyList fields are all labels.hotkeyLabel's fixed bindings.
fn addFixedHolders(arena: std.mem.Allocator, names: *std.ArrayList([]const u8), settings: anytype, combo: u32) !void {
    const info = @typeInfo(@TypeOf(settings.*)).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (comptime F == KeyList) {
            if (holds(@field(settings, name), combo)) try names.append(arena, try fixedName(arena, comptime labels.hotkeyLabel(name)));
        }
    }
}

/// A pair's half is told apart by its direction.
fn fixedName(arena: std.mem.Allocator, label: labels.HotkeyLabel) ![]const u8 {
    const action = lang.text(label.text);
    return switch (label.half) {
        .none => action,
        .back => lang.format(arena, "{action} (back)", .{ .action = action }),
        .forward => lang.format(arena, "{action} (forward)", .{ .action = action }),
    };
}

fn holds(keys: KeyList, combo: u32) bool {
    return std.mem.findScalar(u32, keys.slice(), combo) != null;
}

/// Every KeyList in `value`, however deeply nested, counted under the HolderKind of the field it sits in.
fn collect(arena: std.mem.Allocator, holders: *std.AutoArrayHashMapUnmanaged(u32, Holders), value: anytype, kind: HolderKind) !void {
    const T = @TypeOf(value.*);
    if (T == KeyList) {
        // One binding listing a combo twice still counts once.
        for (value.slice(), 0..) |combo, index| {
            if (std.mem.findScalar(u32, value.slice()[0..index], combo) != null) continue;
            const entry = try holders.getOrPut(arena, combo);
            if (!entry.found_existing) entry.value_ptr.* = .{ .kind = kind };
            entry.value_ptr.total += 1;
            if (entry.value_ptr.kind != kind) entry.value_ptr.is_mixed = true;
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

/// Windows hands a bare Win press to the Start Menu first, so the keyboard hook reports it.
fn onWinKey(modifiers: u32) void {
    const recording = if (g_recording) |*active| active else return;
    if (recording.captured == null) capture(vk.VK_LWIN, modifiers);
}

/// Lit while hovered or focused, like a settings row; its remove badge shows then and whenever `shows_remove`, and Delete on its caps removes it too.
fn comboControl(context: *ui.Frame, key: ui.Key, combo: u32, keycaps: *const style.Keycaps, shows_remove: bool) !ComboAction {
    const ui_state = context.ui();
    const caps_key = key.indexed(1);
    const remove_key = key.indexed(2);
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, key.hash());
    _ = try ui_state.state.getOrCreate(.measured, ui_state.allocator, remove_key.hash());
    const mouse: [2]f32 = .{ @floatCast(ui_state.input.mouse_pos[0]), @floatCast(ui_state.input.mouse_pos[1]) };
    const box = widgets.measuredBox(ui_state, key);
    // The badge overhangs the combo, so the pointer on its overhang still counts.
    const is_hovered = box.contains(mouse) or widgets.measuredBox(ui_state, remove_key).contains(mouse);
    const is_caps_focused = ui_state.focused(caps_key.hash());
    const is_lit = is_hovered or is_caps_focused or ui_state.focused(remove_key.hash());

    const holder = Rect{ .key = key, .style = if (is_lit) &keycaps.combo_lit else &keycaps.combo };
    _ = try holder.open(context);
    const caps = Button{ .key = caps_key, .style = &keycaps.caps };
    const response = try caps.openResponse(context);
    try comboCaps(context, caps_key, combo, keycaps, std.mem.findScalar(u32, g_conflicts, combo) != null);
    try caps.close(context);
    var action: ComboAction = if (response.clicked) .replace else .none;
    // Laid over the combo's top-right corner rather than beside it, so lighting a combo doesn't shift the row.
    if ((is_lit or shows_remove) and box.w() > 0) {
        const badge = try context.arena().create(ui.Style);
        // knots places an absolute child from inside its parent's padding, which a combo has only at its sides.
        badge.* = style.hotkey_remove.with(.{ .offset = .{ box.w() - keycaps.size.combo_padding_x - style.HOTKEY_REMOVE_SIZE + style.HOTKEY_REMOVE_OVERHANG, -style.HOTKEY_REMOVE_OVERHANG } });
        if ((try context.interact(Button{ .key = remove_key, .label = "\u{00D7}", .style = badge })).clicked) action = .remove;
    }
    try holder.close(context);
    if (is_caps_focused and ui_state.input.containsKey(.delete)) action = .remove;
    return action;
}

/// Whether any of the field's `count` combos, keyed under `key` as field draws them, has keyboard focus.
fn hasComboFocus(context: *ui.Frame, key: ui.Key, count: usize) bool {
    const ui_state = context.ui();
    for (0..count) |index| {
        const combo_key = key.indexed(COMBO_KEY_BASE + index);
        if (ui_state.focused(combo_key.indexed(1).hash()) or ui_state.focused(combo_key.indexed(2).hash())) return true;
    }
    return false;
}

/// Red while `is_conflict`, since the combo has no box of its own to mark it.
fn comboCaps(context: *ui.Frame, key: ui.Key, combo: u32, keycaps: *const style.Keycaps, is_conflict: bool) !void {
    const cap_style = if (is_conflict) &keycaps.cap_conflict else &keycaps.cap;
    const modifier_text = if (is_conflict) &keycaps.conflict_text else &keycaps.modifier_text;
    const key_text = if (is_conflict) &keycaps.conflict_text else &keycaps.text;
    const part_index = try modifierCaps(context, key, vk.extractModifiers(combo), keycaps, cap_style, modifier_text);
    try cap(context, key.indexed(KEYCAP_KEY_BASE + part_index), try keyCapName(context, combo), cap_style, key_text);
}

/// A cap and a + for each of `modifiers`' MOD_* flags; returns how many parts it keyed, so what follows takes the next.
fn modifierCaps(context: *ui.Frame, key: ui.Key, modifiers: u32, keycaps: *const style.Keycaps, cap_style: *const ui.Style, text_style: *const ui.Style) !usize {
    var part_index: usize = 0;
    for (MODIFIER_ORDER) |modifier| {
        if (modifiers & modifier.flag == 0) continue;
        try cap(context, key.indexed(KEYCAP_KEY_BASE + part_index), modifier.name, cap_style, text_style);
        try context.e(Text{ .selectable = false, .key = key.indexed(KEYCAP_KEY_BASE + part_index + 1), .content = "+", .style = &keycaps.plus });
        part_index += 2;
    }
    return part_index;
}

/// Whether the combos at full size would overrun the room beside the row's label, so they're drawn compact.
fn needsCompact(context: *ui.Frame, keys: KeyList) !bool {
    const room = try widgets.controlsRoom(context) orelse return false;
    return try fieldWidth(context, keys, &style.keycaps) > room;
}

/// How wide field lays out `keys` with `keycaps`, with its + and, in Advanced Mode, its typing button.
fn fieldWidth(context: *ui.Frame, keys: KeyList, keycaps: *const style.Keycaps) !f32 {
    var width: f32 = 0;
    var part_count: usize = 0;
    for (keys.slice(), 0..) |combo, index| {
        if (index > 0) {
            width += try widgets.textWidth(context, lang.text("or"), &keycaps.@"or");
            part_count += 1;
        }
        width += try comboWidth(context, combo, keycaps);
        part_count += 1;
    }
    if (keys.len < key_list.MAX_KEYS) {
        width += comptime style.hotkey_add_gap.padding.?.left() + style.CONTROL_HEIGHT;
        part_count += 1;
    }
    if (session.global().get("advancedMode")) {
        width += style.CONTROL_HEIGHT;
        part_count += 1;
    }
    return width + keycaps.size.combo_gap * @as(f32, @floatFromInt(part_count -| 1));
}

fn comboWidth(context: *ui.Frame, combo: u32, keycaps: *const style.Keycaps) !f32 {
    const modifiers = vk.extractModifiers(combo);
    var width = 2 * keycaps.size.combo_padding_x + try capWidth(context, try keyCapName(context, combo), keycaps);
    var part_count: usize = 1;
    for (MODIFIER_ORDER) |modifier| {
        if (modifiers & modifier.flag == 0) continue;
        width += try capWidth(context, modifier.name, keycaps) + try widgets.textWidth(context, "+", &keycaps.plus);
        part_count += 2;
    }
    return width + keycaps.size.gap * @as(f32, @floatFromInt(part_count - 1));
}

fn capWidth(context: *ui.Frame, name: []const u8, keycaps: *const style.Keycaps) !f32 {
    const text_width = try widgets.textWidth(context, try std.ascii.allocUpperString(context.arena(), name), &keycaps.text);
    return text_width + 2 * (keycaps.size.cap_padding_x + style.KEYCAP_BORDER);
}

/// `combo`'s key as its cap shows it; a key without a name is written as hex, made in the frame's arena.
fn keyCapName(context: *ui.Frame, combo: u32) ![]const u8 {
    const virtual_key = vk.extractVk(combo);
    return vk.keyName(virtual_key) orelse std.fmt.allocPrint(context.arena(), "VK{X}", .{virtual_key});
}

fn orText(context: *ui.Frame, key: ui.Key, keycaps: *const style.Keycaps) !void {
    try context.e(Text{ .selectable = false, .key = key, .content = lang.text("or"), .style = &keycaps.@"or" });
}

/// Replaces `slot`'s combo, or adds one when it's null.
fn applyCapture(keys: *KeyList, slot: ?usize, combo: u32) void {
    if (slot) |index| {
        // The list may have shrunk while recording, e.g. on a profile switch; the key is then added instead.
        if (index < keys.len) return keys.replace(index, combo);
    }
    if (!keys.append(combo)) slog.warn("Failed to add hotkey: a hotkey holds at most {d} keys", .{key_list.MAX_KEYS});
}

fn cap(context: *ui.Frame, key: ui.Key, name: []const u8, cap_style: *const ui.Style, text_style: *const ui.Style) !void {
    try context.e(.{
        Rect{ .key = key, .style = cap_style },
        .{Text{ .selectable = false, .key = key.indexed(1), .content = try std.ascii.allocUpperString(context.arena(), name), .style = text_style }},
    });
}

/// Where the combo being recorded will go: a prompt, then the modifiers held so far as they're pressed.
fn recordingLabel(context: *ui.Frame, key: ui.Key, keycaps: *const style.Keycaps) !void {
    const held = if (g_recording) |recording| recording.held else 0;
    const label = Rect{ .key = key, .style = &keycaps.combo };
    _ = try label.open(context);
    if (held == 0) {
        try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = lang.text(RECORDING_PROMPT), .style = &style.hotkey_prompt });
    } else {
        const part_index = try modifierCaps(context, key, held, keycaps, &keycaps.cap, &keycaps.modifier_text);
        try context.e(Text{ .selectable = false, .key = key.indexed(KEYCAP_KEY_BASE + part_index), .content = "\u{2026}", .style = &style.hotkey_prompt });
    }
    try label.close(context);
}

/// Records a hotkey's first combo or another one; `tip_text` names which, since the + alone doesn't.
fn addKeyButton(context: *ui.Frame, key: ui.Key, tip_text: []const u8) !bool {
    const tip = Tooltip{ .key = key, .content = lang.text(tip_text), .style = &style.hotkey_add_gap };
    _ = try tip.open(context);
    const is_clicked = try widgets.glyphButton(context, key.indexed(3), .add, "", &style.icon_button, false);
    try tip.close(context);
    return is_clicked;
}

/// `base` unchanged when it already has `gap`, else a copy made in the frame's arena.
fn withGap(context: *ui.Frame, base: *const ui.Style, gap: f32) !*const ui.Style {
    if (base.gap) |current| {
        if (current == gap) return base;
    }
    const gapped = try context.arena().create(ui.Style);
    gapped.* = base.with(.{ .gap = gap });
    return gapped;
}

fn sized(context: *ui.Frame, base: *const ui.Style, width: ?*const ui.Style) !*const ui.Style {
    const over = width orelse return base;
    const box_style = try context.arena().create(ui.Style);
    box_style.* = base.with(over.*);
    return box_style;
}

/// `ref` has session.Ref's get and set for `field_name`.
fn manualBox(context: *ui.Frame, edit: *ManualEdit, ref: anytype, comptime field_name: []const u8, key: ui.Key, width: ?*const ui.Style) !void {
    const box_key = key.indexed(5);
    const is_focused = context.ui().focused(box_key.hash());
    // Enter, or leaving the box, applies what was typed.
    if ((is_focused and context.ui().input.containsKey(.enter)) or (edit.was_focused and !is_focused)) {
        commitManual(ref, field_name);
        context.requestRedraw();
        return;
    }
    edit.was_focused = is_focused;
    try context.e(TextInput{ .key = box_key, .buf = &edit.text, .style = try sized(context, &style.text_input, width) });
}

fn isRecordingField(id: u64) bool {
    const recording = g_recording orelse return false;
    return recording.id == id;
}

/// Whether field `id` records into `slot`, null meaning a combo being added.
fn isRecordingSlot(id: u64, slot: ?usize) bool {
    const recording = g_recording orelse return false;
    if (recording.id != id) return false;
    const recorded = recording.slot orelse return slot == null;
    const asked = slot orelse return false;
    return recorded == asked;
}

fn manualEditFor(id: u64) ?*ManualEdit {
    const edit = if (g_manual) |*open| open else return null;
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

fn startRecording(context: *ui.Frame, id: u64, slot: ?usize) void {
    stopRecording();
    endManual();
    g_recording = .{ .id = id, .slot = slot };
    // The low-level hooks swallow matched keys system-wide, so the window would never see a bound key otherwise.
    if (session.runningApp().hotkey_manager) |manager| manager.dialogSuspendHotkeys();
    context.requestRedraw();
}

fn cancelRecording(context: *ui.Frame) void {
    stopRecording();
    context.requestRedraw();
}

fn stopRecording() void {
    if (g_recording == null) return;
    g_recording = null;
    const app = session.runningApp();
    const manager = app.hotkey_manager orelse return;
    const timer_hwnd = app.timer_hwnd orelse return;
    manager.dialogResumeHotkeys(timer_hwnd);
}

fn capture(virtual_key: u32, modifiers: u32) void {
    const recording = if (g_recording) |*active| active else return;
    recording.captured = vk.combineKey(virtual_key, modifiers);
    redraw();
}

fn redraw() void {
    g_is_layout_stale = true;
    if (g_on_capture) |on_capture| on_capture();
}

/// Marked extended, or followed by a queued numpad navigation key-down.
fn isFakeShiftRelease(lParam: win32.LPARAM) bool {
    if (lParam & win32.KEY_EXTENDED_BIT != 0) return true;
    var next: win32.MSG = undefined;
    if (!win32.toBool(win32.PeekMessageA(&next, null, win32.WM_KEYDOWN, win32.WM_KEYDOWN, win32.PM_NOREMOVE))) return false;
    return next.lParam & win32.KEY_EXTENDED_BIT == 0 and vk.numpadForNavigation(@truncate(next.wParam)) != null;
}

fn modifierFlag(virtual_key: u32) ?u32 {
    return switch (virtual_key) {
        vk.VK_CONTROL => vk.MOD_CONTROL,
        vk.VK_MENU => vk.MOD_ALT,
        vk.VK_SHIFT => vk.MOD_SHIFT,
        vk.VK_LWIN, vk.VK_RWIN => vk.MOD_WIN,
        else => null,
    };
}
