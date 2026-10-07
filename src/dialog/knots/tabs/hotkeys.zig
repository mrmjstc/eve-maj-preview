//! The configuration window's Hotkeys tab: how hotkeys behave, then every fixed binding by what it does, profile switching, and app and URL hotkeys; main thread only.
const std = @import("std");
const ui = @import("ui");
const global_config = @import("../../../config/global.zig");
const key_list = @import("../../../config/key_list.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const profiles = @import("../profiles.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const KeyList = key_list.KeyList;
const slog = log.scoped("dialog_knots");

const DOTLAN_URL = "https://evemaps.dotlan.net/";
const ADASHBOARD_URL = "https://adashboard.info/intel";

/// Stands in for a session.Ref for one profile's switch hotkey, which is only saved while it's bound.
const ProfileSwitch = struct {
    index: usize,
    target: []const u8,

    pub fn get(self: ProfileSwitch, comptime _: []const u8) KeyList {
        const entry = self.find() orelse return .empty;
        return session.global().item("profileSwitchHotkeys", entry).get("hotkey");
    }

    /// Keeps the saved order; an unbound row has no entry.
    pub fn set(self: ProfileSwitch, comptime _: []const u8, value: KeyList) void {
        const global = session.global();
        if (self.find()) |entry| {
            if (value.isEmpty()) global.remove("profileSwitchHotkeys", entry) else global.item("profileSwitchHotkeys", entry).set("hotkey", value);
            return;
        }
        if (value.isEmpty()) return;
        global.append("profileSwitchHotkeys", .{});
        const added = global.item("profileSwitchHotkeys", global.ptr.profileSwitchHotkeys.items.len - 1);
        added.set("targetProfile", self.target);
        added.set("hotkey", value);
    }

    fn find(self: ProfileSwitch) ?usize {
        for (session.global().ptr.profileSwitchHotkeys.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.targetProfile, self.target)) return index;
        }
        return null;
    }
};

var g_allocator: std.mem.Allocator = undefined;
/// The open "Pick Running Window" dropdown, under one app hotkey.
var g_picker: ?window_picker.Picker = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    window_picker.close(&g_picker);
}

pub fn show(context: *ui.Frame) !void {
    const profile_hotkeys = session.profile().child("hotkeys");
    const global = session.global();

    const system = try widgets.openSection(context, "Hotkey System", "Controls how the hotkeys below are registered and triggered.", &style.section);
    try bind.toggle(context, profile_hotkeys, "requireEveFocus", "Require EVE Focus");
    try widgets.hintText(context, .src(@src()), "Hotkeys are ignored unless an EVE window is currently focused.");
    try bind.toggle(context, profile_hotkeys, "allowHotkeyAutoRepeat", "Repeat Hotkey While Held");
    try widgets.hintText(context, .src(@src()), "Holding a hotkey down repeats its action instead of firing once.");
    try bind.toggle(context, profile_hotkeys, "exactHotkeyModifiers", "Match Modifiers Exactly");
    try widgets.hintText(context, .src(@src()), "Only fire a hotkey when exactly its modifiers are held, so a hotkey on 1 won't fire on Alt+1 and Alt+1 reaches the game.");
    try system.close(context);

    const actions = try widgets.openSection(context, "Window Actions", "Minimize, close, hide thumbnails, toggle auto-minimize, or send every window back to its saved position.", &style.section);
    const close_all = session.profile().child("closeAll");
    try bind.toggle(context, close_all, "excludeCycleExcludedClients", "Don't Close Excluded Clients");
    try widgets.hintText(context, .src(@src()), "Same exclusion list as Character Exclusion on the Behavior tab.");
    try bind.toggle(context, close_all, "excludeLoginScreenClients", "Don't Close Clients On Login Screen");
    try widgets.hintText(context, .src(@src()), "Skips any client still sitting at the character-selection screen.");
    try binding(context, profile_hotkeys, "hotkeyCloseAll", "Close All Clients");
    try binding(context, profile_hotkeys, "hotkeyCloseActive", "Close Active Client");
    try binding(context, profile_hotkeys, "hotkeyMinimizeAll", "Minimize All Clients");
    try binding(context, profile_hotkeys, "hotkeyToggleVisibility", "Toggle Thumbnail Visibility");
    try binding(context, profile_hotkeys, "hotkeyToggleAutoMinimize", "Toggle Auto-Minimize");
    try widgets.hintText(context, .src(@src()), "Toggle Auto-Minimize only flips the setting for this session; it isn't saved and reverts to the profile's saved value on restart.");
    try binding(context, profile_hotkeys, "hotkeyMoveToSavedPositions", "Move Windows to Saved Positions");
    try actions.close(context);

    const cycling = try widgets.openSection(context, "Special Cycling", "Step through the characters this profile sets apart - the excluded ones, or the ones that recently notified.", &style.section);
    try pair(context, profile_hotkeys, "hotkeyPreviousExcluded", "hotkeyNextExcluded", "Excluded Characters");
    try pair(context, profile_hotkeys, "hotkeyPreviousNotified", "hotkeyCycleNotified", "Notified Characters");
    try widgets.hintText(context, .src(@src()), "How long a character counts as \"recently notified\" is set by Recently-Notified Cycle Retention on the Notifications tab.");
    try binding(context, profile_hotkeys, "hotkeyToggleExclusion", "Toggle Character Exclusion");
    try widgets.hintText(context, .src(@src()), "Applies to whichever EVE window currently has Windows focus, not the thumbnail under your cursor.");
    try cycling.close(context);

    const suspend_exit = try widgets.openSection(context, "Suspend and Exit", "Suspend or resume every hotkey (the suspend hotkey itself always works), or close EVE-Maj Preview. EVE clients stay open.", &style.section);
    try binding(context, profile_hotkeys, "hotkeySuspend", "Toggle Suspend Hotkeys");
    try binding(context, profile_hotkeys, "hotkeyToggleAlertMute", "Mute Audio Alerts");
    try widgets.hintText(context, .src(@src()), "Mutes every TTS and sound alert for this session; it isn't saved and resets on restart. Also in the tray menu.");
    try binding(context, profile_hotkeys, "hotkeyExitApp", "Exit App");
    try suspend_exit.close(context);

    const clients = try widgets.openSection(context, "Client Cycling", "Step through open EVE client windows, ordered by the Characters list of whichever profile is loaded.", &style.section);
    try bind.toggle(context, global, "cycleAllClientsRespectExclusions", "Skip Excluded Characters");
    try widgets.hintText(context, .src(@src()), "Same exclusion list as Character Exclusion on the Behavior tab.");
    try pair(context, global, "hotkeyCycleAllClientsBackward", "hotkeyCycleAllClientsForward", "Logged-In Clients");
    try pair(context, global, "hotkeyCycleNotLoggedInBackward", "hotkeyCycleNotLoggedInForward", "Logged-Out Clients");
    try widgets.hintText(context, .src(@src()), "Steps through EVE client windows still sitting at the login/character-select screen.");
    try clients.close(context);

    const profile_section = try widgets.openSection(context, "Profiles", "Cycle through profiles, or switch straight to one.", &style.section);
    try pair(context, global, "hotkeyPreviousProfile", "hotkeyNextProfile", "Profile");
    try profileSwitchRows(context);
    try profile_section.close(context);

    const outside = try widgets.openSection(context, "Outside EVE", "Jump to the app you last had focused, to a specific running application, or to a URL in your browser.", &style.section);
    try binding(context, global, "hotkeyReturnToLastApp", "Return to Last App");
    try widgets.subheading(context, .src(@src()), "App Hotkeys");
    try appHotkeys(context);
    try widgets.subheading(context, .src(@src()), "URL Hotkeys");
    try urlHotkeys(context);
    try outside.close(context);
}

fn binding(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, .str("knots.hotkeys.binding:" ++ field), label);
    try hotkey.field(context, ref, field);
    try row.close(context);
}

/// A backward/forward set in one row, each half marked with its direction.
fn pair(context: *ui.Frame, ref: anytype, comptime previous: []const u8, comptime next: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, .str("knots.hotkeys.pair:" ++ previous), label);
    const halves = Rect{ .key = .str("knots.hotkeys.pair.halves:" ++ previous), .style = &style.pair_column };
    _ = try halves.open(context);
    inline for (.{ .{ previous, "\u{2190}" }, .{ next, "\u{2192}" } }) |half| {
        const line = Rect{ .key = .str("knots.hotkeys.pair.half:" ++ half[0]), .style = &style.inline_row };
        _ = try line.open(context);
        try context.e(Text{ .selectable = false, .key = .str("knots.hotkeys.pair.arrow:" ++ half[0]), .content = half[1], .style = &style.binding_arrow });
        try hotkey.field(context, ref, half[0]);
        try line.close(context);
    }
    try halves.close(context);
    try row.close(context);
}

/// One row per existing profile rather than a list of its own, so adding or deleting a profile changes the rows.
fn profileSwitchRows(context: *ui.Frame) !void {
    for (profiles.list(), 0..) |name, index| {
        const label = try std.fmt.allocPrint(context.arena(), "Switch to: {s}", .{profiles.displayName(name)});
        const row = try widgets.openBinding(context, ui.Key.str("knots.hotkeys.profile").indexed(index), label);
        try hotkey.field(context, ProfileSwitch{ .index = index, .target = name }, "hotkey");
        try row.close(context);
    }
}

fn appHotkeys(context: *ui.Frame) !void {
    const global = session.global();
    var index: usize = 0;
    while (index < global.ptr.appHotkeys.items.len) : (index += 1) {
        const entry = global.item("appHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.app").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "executableName", "e.g., Discord.exe");
        try hotkey.field(context, entry, "hotkey");
        if (try widgets.glyphButton(context, ui.Key.str("knots.hotkeys.app.pick").indexed(index), .refresh, "Pick Running Window", &style.plain_button, false)) window_picker.open(g_allocator, &g_picker, index);
        const removed = try widgets.confirmButton(context, ui.Key.str("knots.hotkeys.app.remove").indexed(index), "Remove", "Confirm", &style.remove_button, &style.confirm_remove_button);
        try row.close(context);
        try picker(context, entry);
        if (removed) {
            global.remove("appHotkeys", index);
            window_picker.close(&g_picker);
            break;
        }
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add App Hotkey", .style = &style.full_width_button })).clicked) {
        global.append("appHotkeys", .{});
    }
}

/// Picking a window fills in its executable name.
fn picker(context: *ui.Frame, entry: session.Ref(global_config.AppHotkeyConfig)) !void {
    const chosen = try window_picker.select(context, &g_picker, .str("knots.hotkeys.app.picker"), entry.index) orelse return;
    entry.set("executableName", chosen.exe);
    window_picker.close(&g_picker);
}

fn urlHotkeys(context: *ui.Frame) !void {
    const global = session.global();
    var index: usize = 0;
    while (index < global.ptr.urlHotkeys.items.len) : (index += 1) {
        const entry = global.item("urlHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.url").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "url", "https://example.com");
        try hotkey.field(context, entry, "hotkey");
        const removed = try widgets.confirmButton(context, ui.Key.str("knots.hotkeys.url.remove").indexed(index), "Remove", "Confirm", &style.remove_button, &style.confirm_remove_button);
        try row.close(context);
        // Only aDashboard takes a clipboard upload, so the option hangs under its row and is cleared for any other URL.
        if (isAdashboard(entry.get("url"))) {
            try bind.toggle(context, entry, "uploadClipboard", "Upload Clipboard Content (dscan/local)");
        } else if (entry.get("uploadClipboard")) {
            entry.set("uploadClipboard", false);
        }
        if (removed) {
            global.remove("urlHotkeys", index);
            break;
        }
    }
    const buttons = Rect{ .key = .src(@src()), .style = &style.button_row };
    _ = try buttons.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Add URL Hotkey", .style = &style.plain_button })).clicked) addUrlHotkey("");
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ Dotlan", .style = &style.plain_button })).clicked) addUrlHotkey(DOTLAN_URL);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "+ aDashboard Intel", .style = &style.plain_button })).clicked) addUrlHotkey(ADASHBOARD_URL);
    try buttons.close(context);
}

fn addUrlHotkey(url: []const u8) void {
    const global = session.global();
    global.append("urlHotkeys", .{});
    if (url.len > 0) global.item("urlHotkeys", global.ptr.urlHotkeys.items.len - 1).set("url", url);
}

fn isAdashboard(url: []const u8) bool {
    // Text that isn't a URL yet, e.g. half typed, just isn't aDashboard's.
    const uri = std.Uri.parse(std.mem.trim(u8, url, " ")) catch return false;
    const host = uri.host orelse return false;
    const name = switch (host) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    return std.ascii.eqlIgnoreCase(name, "adashboard.info");
}
