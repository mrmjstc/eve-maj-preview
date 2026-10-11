//! The configuration window's Hotkeys tab: how hotkeys behave, then every fixed binding by what it does, profile switching, and app and URL hotkeys; main thread only.
const std = @import("std");
const ui = @import("ui");
const global_mod = @import("../../../config/global.zig");
const key_list = @import("../../../config/key_list.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const profiles = @import("../profiles.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const KeyList = key_list.KeyList;

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
        const added = global.append("profileSwitchHotkeys", .{}) orelse return;
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

/// Stands in for a session.Ref for draftAppRow's hotkey: binding a key there adds the app hotkey it belongs to.
const DraftAppHotkey = struct {
    /// Where the entry will go, so its hotkey box is keyed apart from the saved ones'.
    index: usize,

    pub fn get(_: DraftAppHotkey, comptime _: []const u8) KeyList {
        return .empty;
    }

    pub fn set(_: DraftAppHotkey, comptime _: []const u8, value: KeyList) void {
        if (!value.isEmpty()) addAppHotkey("hotkey", value);
    }
};

/// DraftAppHotkey for draftUrlRow, carrying the URL a preset row shows.
const DraftUrlHotkey = struct {
    index: usize,
    /// Borrows a comptime preset, or is empty.
    url: []const u8,

    pub fn get(_: DraftUrlHotkey, comptime _: []const u8) KeyList {
        return .empty;
    }

    pub fn set(self: DraftUrlHotkey, comptime _: []const u8, value: KeyList) void {
        if (value.isEmpty()) return;
        const added = session.global().append("urlHotkeys", .{}) orelse return;
        added.set("hotkey", value);
        if (self.url.len > 0) added.set("url", self.url);
    }
};

var g_allocator: std.mem.Allocator = undefined;
/// The open "Pick Running Window" dropdown, under one app hotkey.
var g_picker: ?window_picker.Picker = null;
/// The URL hotkey Add URL Hotkey just added, kept while blank until its box has had focus.
var g_fresh_url_index: ?usize = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    window_picker.close(&g_picker);
    g_fresh_url_index = null;
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
    try binding(context, profile_hotkeys, "hotkeyCloseAll", "Close All Clients");
    // Straight under the hotkey they qualify.
    const close_all = session.profile().child("closeAll");
    try bind.toggle(context, close_all, "excludeCycleExcludedClients", "Don't Close Excluded Clients");
    try widgets.hintText(context, .src(@src()), "Same exclusion list as Character Exclusion on the Behavior tab.");
    try bind.toggle(context, close_all, "excludeLoginScreenClients", "Don't Close Logged-Out Clients");
    try widgets.hintText(context, .src(@src()), "Skips any client still sitting at the character-selection screen.");
    try binding(context, profile_hotkeys, "hotkeyCloseActive", "Close Active Client");
    try binding(context, profile_hotkeys, "hotkeyMinimizeAll", "Minimize All Clients");
    try binding(context, profile_hotkeys, "hotkeyToggleVisibility", "Toggle Thumbnail Visibility");
    try binding(context, profile_hotkeys, "hotkeyToggleAutoMinimize", "Toggle Auto-Minimize");
    try widgets.hintText(context, .src(@src()), "Toggle Auto-Minimize only flips the setting for this session; it isn't saved and reverts to the profile's saved value on restart.");
    try binding(context, profile_hotkeys, "hotkeyMoveToSavedPositions", "Move Windows to Saved Positions");
    try actions.close(context);

    const cycling = try widgets.openSection(context, "Special Cycling", "Step through the excluded characters, or the ones that recently notified.", &style.section);
    try pair(context, profile_hotkeys, "hotkeyPreviousExcluded", "hotkeyNextExcluded", "Excluded Characters");
    try pair(context, profile_hotkeys, "hotkeyPreviousNotified", "hotkeyCycleNotified", "Notified Characters");
    try widgets.hintText(context, .src(@src()), "How long a character counts as \"recently notified\" is set by Keep in Notified Cycle For on the Notifications tab.");
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
    try pair(context, global, "hotkeyCycleAppsBackward", "hotkeyCycleAppsForward", "Cycle Apps");
    try widgets.hintText(context, .src(@src()), "Steps through the App Hotkeys below, in list order, skipping any that aren't running.");
    try widgets.subheading(context, .src(@src()), "App Hotkeys");
    try appHotkeys(context);
    try widgets.subheading(context, .src(@src()), "URL Hotkeys");
    try urlHotkeys(context);
    try outside.close(context);
}

/// `ref` has session.Ref's get and set for `field`.
fn binding(context: *ui.Frame, ref: anytype, comptime field: []const u8, label: []const u8) !void {
    const row = try widgets.openBinding(context, .str("knots.hotkeys.binding:" ++ field), label);
    try hotkey.field(context, ref, field);
    try row.close(context);
}

/// A backward/forward set in one row, each half marked with its direction; `ref` has session.Ref's get and set for both fields.
fn pair(context: *ui.Frame, ref: anytype, comptime previous: []const u8, comptime next: []const u8, label: []const u8) !void {
    const row = try widgets.openMarkedBinding(context, .str("knots.hotkeys.pair:" ++ previous), label, "\u{2190}");
    const halves = Rect{ .key = .str("knots.hotkeys.pair.halves:" ++ previous), .style = &style.inline_row_fit };
    _ = try halves.open(context);
    try hotkey.field(context, ref, previous);
    try context.e(Text{ .selectable = false, .key = .str("knots.hotkeys.pair.arrow:" ++ next), .content = "\u{2192}", .style = &style.binding_arrow });
    try hotkey.field(context, ref, next);
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

/// Each row ends in its hotkey box, lined up with the bindings above; a row left with no name and no key is removed.
fn appHotkeys(context: *ui.Frame) !void {
    const global = session.global();
    var index: usize = 0;
    while (index < global.ptr.appHotkeys.items.len) : (index += 1) {
        const entry = global.item("appHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.app").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "executableName", "e.g., Discord.exe");
        if (try widgets.glyphButton(context, ui.Key.str("knots.hotkeys.app.pick").indexed(index), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(g_allocator, &g_picker, index);
        try hotkey.field(context, entry, "hotkey");
        try row.close(context);
        try picker(context, entry);
        if (isBlank(context, entry, "executableName")) {
            global.remove("appHotkeys", index);
            window_picker.close(&g_picker);
            break;
        }
    }
    try draftAppRow(context, global.ptr.appHotkeys.items.len);
    try widgets.hintText(context, .src(@src()), "Fill in the empty row to add one; clear a row's name and key to remove it.");
}

/// An empty row after the app hotkeys, so the list never looks empty; typing, binding or picking into it adds the entry.
fn draftAppRow(context: *ui.Frame, index: usize) !void {
    const row = Rect{ .key = .str("knots.hotkeys.app.draft"), .style = &style.list_row };
    _ = try row.open(context);
    if (try bind.stringBox(context, .str("knots.hotkeys.app.draft.name"), "", "e.g., Discord.exe", &style.text_input)) |typed| {
        if (std.mem.trim(u8, typed, " ").len > 0) addAppHotkey("executableName", typed);
    }
    if (try widgets.glyphButton(context, .str("knots.hotkeys.app.draft.pick"), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(g_allocator, &g_picker, index);
    try hotkey.field(context, DraftAppHotkey{ .index = index }, "hotkey");
    try row.close(context);
    if (try window_picker.select(context, &g_picker, .str("knots.hotkeys.app.picker"), index)) |chosen| {
        addAppHotkey("executableName", chosen.executable);
        window_picker.close(&g_picker);
    }
}

/// A new app hotkey with just `field` set; `value` is of that field's type, e.g. the executable's name.
fn addAppHotkey(comptime field: []const u8, value: anytype) void {
    const added = session.global().append("appHotkeys", .{}) orelse return;
    added.set(field, value);
}

/// Picking a window fills in its executable name.
fn picker(context: *ui.Frame, entry: session.Ref(global_mod.AppHotkeyConfig)) !void {
    const chosen = try window_picker.select(context, &g_picker, .str("knots.hotkeys.app.picker"), entry.index) orelse return;
    entry.set("executableName", chosen.executable);
    window_picker.close(&g_picker);
}

/// Like appHotkeys, ending in the presets.
fn urlHotkeys(context: *ui.Frame) !void {
    const global = session.global();
    var index: usize = 0;
    while (index < global.ptr.urlHotkeys.items.len) : (index += 1) {
        const entry = global.item("urlHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.url").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try bind.textBox(context, entry, "url", "https://example.com");
        try hotkey.field(context, entry, "hotkey");
        try row.close(context);
        // Only aDashboard takes a clipboard upload, so the option hangs under its row and is cleared for any other URL.
        if (isAdashboard(entry.get("url"))) {
            try bind.toggle(context, entry, "uploadClipboard", "Upload Clipboard Content (dscan/local)");
        } else if (entry.get("uploadClipboard")) {
            entry.set("uploadClipboard", false);
        }
        // A just-added row starts blank, so it stays until its box has had focus.
        if (g_fresh_url_index == index and context.ui().focused(bind.boxKey(entry, "url").hash())) g_fresh_url_index = null;
        if (g_fresh_url_index != index and isBlank(context, entry, "url")) {
            global.remove("urlHotkeys", index);
            break;
        }
    }
    // The presets wait, filled in, until they're bound, so they're offered without being saved.
    const count = global.ptr.urlHotkeys.items.len;
    if (!hasUrlHotkey(isDotlan)) try draftUrlRow(context, .str("knots.hotkeys.url.draft.dotlan"), count, DOTLAN_URL);
    if (!hasUrlHotkey(isAdashboard)) try draftUrlRow(context, .str("knots.hotkeys.url.draft.adashboard"), count + 1, ADASHBOARD_URL);
    const add = Rect{ .key = .src(@src()), .style = &style.button_row_end };
    _ = try add.open(context);
    if (try widgets.glyphButton(context, .str("knots.hotkeys.url.add"), .add, "Add URL Hotkey", &style.add_button, false)) {
        if (global.append("urlHotkeys", .{})) |added| g_fresh_url_index = added.index;
    }
    try add.close(context);
}

fn hasUrlHotkey(comptime matches: fn ([]const u8) bool) bool {
    for (session.global().ptr.urlHotkeys.items) |entry| {
        if (matches(entry.url)) return true;
    }
    return false;
}

/// A preset's row after the URL hotkeys, like draftAppRow's, showing `url` filled in; typing a different URL or binding a key adds the entry.
fn draftUrlRow(context: *ui.Frame, key: ui.Key, index: usize, url: []const u8) !void {
    const row = Rect{ .key = key, .style = &style.list_row };
    _ = try row.open(context);
    if (try bind.stringBox(context, key.indexed(1), url, "https://example.com", &style.text_input)) |typed| {
        if (std.mem.trim(u8, typed, " ").len > 0) {
            const added = session.global().append("urlHotkeys", .{}) orelse return;
            added.set("url", typed);
        }
    }
    try hotkey.field(context, DraftUrlHotkey{ .index = index, .url = url }, "hotkey");
    try row.close(context);
}

fn isDotlan(url: []const u8) bool {
    return std.ascii.findIgnoreCase(url, "evemaps.dotlan.net") != null;
}

/// `entry` is an app or URL hotkey's session.Ref; true with no text in `text_field` and no key, once its box isn't being typed in.
fn isBlank(context: *ui.Frame, entry: anytype, comptime text_field: []const u8) bool {
    if (context.ui().focused(bind.boxKey(entry, text_field).hash())) return false;
    return std.mem.trim(u8, entry.get(text_field), " ").len == 0 and entry.get("hotkey").isEmpty();
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
