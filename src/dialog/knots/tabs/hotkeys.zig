//! The configuration window's Hotkeys tab: how hotkeys behave, then cycling and every other fixed binding by what it does, profile switching, and app and URL hotkeys; main thread only.
const std = @import("std");
const ui = @import("ui");
const global_mod = @import("../../../config/global.zig");
const key_list = @import("../../../config/key_list.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const hotkey = @import("../hotkey.zig");
const labels = @import("../labels.zig");
const profiles = @import("../profiles.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");
const lang = @import("../../../lang/lang.zig");
const window_mod = @import("../window.zig");

const Rect = ui.component.Rect;
const KeyList = key_list.KeyList;
const Window = window_mod.Window;

const DOTLAN_URL = "https://evemaps.dotlan.net/";
const ADASHBOARD_URL = "https://adashboard.info/intel";

/// Stands in for a session.Ref for one profile's switch hotkey, which is only saved while it's bound.
const ProfileSwitch = struct {
    /// Borrows the window whose draft it edits.
    window: *Window,
    index: usize,
    /// Borrows from profiles.list.
    target: []const u8,

    pub fn get(self: ProfileSwitch, comptime _: []const u8) KeyList {
        const entry = self.find() orelse return .empty;
        return self.window.session.global().item("profileSwitchHotkeys", entry).get("hotkey");
    }

    /// Keeps the saved order; an unbound row has no entry.
    pub fn set(self: ProfileSwitch, comptime _: []const u8, value: KeyList) void {
        const global = self.window.session.global();
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
        for (self.window.session.global().ptr.profileSwitchHotkeys.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.targetProfile, self.target)) return index;
        }
        return null;
    }
};

/// Stands in for a session.Ref for draftAppRow's hotkey: binding a key there adds the app hotkey it belongs to.
const DraftAppHotkey = struct {
    /// Borrows the window whose draft it edits.
    window: *Window,
    /// Where the entry will go, so its hotkey box is keyed apart from the saved ones'.
    index: usize,

    pub fn get(_: DraftAppHotkey, comptime _: []const u8) KeyList {
        return .empty;
    }

    pub fn set(self: DraftAppHotkey, comptime _: []const u8, value: KeyList) void {
        if (!value.isEmpty()) addAppHotkey(self.window, "hotkey", value);
    }
};

/// DraftAppHotkey for draftUrlRow, carrying the URL a preset row shows.
const DraftUrlHotkey = struct {
    /// Borrows the window whose draft it edits.
    window: *Window,
    index: usize,
    /// Borrows a comptime preset, or is empty.
    url: []const u8,

    pub fn get(_: DraftUrlHotkey, comptime _: []const u8) KeyList {
        return .empty;
    }

    pub fn set(self: DraftUrlHotkey, comptime _: []const u8, value: KeyList) void {
        if (value.isEmpty()) return;
        const added = self.window.session.global().append("urlHotkeys", .{}) orelse return;
        added.set("hotkey", value);
        if (self.url.len > 0) added.set("url", self.url);
    }
};

/// One window's, reset as each opens.
pub const State = struct {
    picker: ?window_picker.Picker = null,
    /// The URL hotkey Add URL Hotkey just added, kept while blank until its box has had focus.
    fresh_url_index: ?usize = null,

    pub fn deinit(self: *State) void {
        window_picker.close(&self.picker);
    }
};

pub fn show(window: *Window, context: *ui.Frame) !void {
    const profile_hotkeys = window.session.profile().child("hotkeys");
    const global = window.session.global();

    const system = try window.widgets.openSection(context, "Hotkey System", "Controls how the hotkeys below are registered and triggered.", &style.section);
    try window.bind.toggle(context, profile_hotkeys, "requireEveFocus", "Require EVE Focus");
    try window.widgets.hintText(context, .src(@src()), "Stops hotkeys clashing with other apps.");
    try window.bind.toggle(context, profile_hotkeys, "allowHotkeyAutoRepeat", "Repeat Hotkey While Held");
    try window.widgets.hintText(context, .src(@src()), "When off, holding a key fires it once.");
    try window.bind.toggle(context, profile_hotkeys, "exactHotkeyModifiers", "Match Modifiers Exactly");
    try window.widgets.hintText(context, .src(@src()), "A hotkey on 1 won't fire on Alt+1, so Alt+1 still reaches the game.");
    try system.close(context);

    const clients = try window.widgets.openSharedSection(context, "Client Cycling", "Step through every open EVE client, in the loaded profile's Characters order.", &style.section);
    try window.bind.toggle(context, global, "cycleAllClientsRespectExclusions", "Skip Excluded Characters");
    try window.widgets.hintText(context, .src(@src()), "Uses the excluded characters from the Mouse tab.");
    try pair(window, context, global, "hotkeyCycleAllClientsBackward", "hotkeyCycleAllClientsForward", "Every logged-in client, in Characters tab order.");
    try pair(window, context, global, "hotkeyCycleNotLoggedInBackward", "hotkeyCycleNotLoggedInForward", "Clients at the login screen, oldest logout first.");
    try clients.close(context);

    const cycling = try window.widgets.openSection(context, "Special Cycling", "Step through the excluded characters, or the ones that recently notified.", &style.section);
    try pair(window, context, profile_hotkeys, "hotkeyPreviousExcluded", "hotkeyNextExcluded", "Steps through only the characters you've excluded.");
    try pair(window, context, profile_hotkeys, "hotkeyPreviousNotified", "hotkeyCycleNotified", "Characters with a recent alert. Set how recent on the Alert Options tab.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleExclusion");
    try window.widgets.hintText(context, .src(@src()), "Acts on the EVE window you're in, not the thumbnail under the mouse.");
    try cycling.close(context);

    const actions = try window.widgets.openSection(context, "Window Actions", "Close or minimize clients, hide thumbnails, or restore saved positions.", &style.section);
    try binding(window, context, profile_hotkeys, "hotkeyCloseAll");
    try window.widgets.hintText(context, .src(@src()), "Closes every EVE client, except those set below.");
    const close_all = window.session.profile().child("closeAll");
    {
        // Its own switches, so they read as part of its row.
        const was_undivided = window.widgets.useUndividedRows(true);
        defer _ = window.widgets.useUndividedRows(was_undivided);
        try window.bind.toggle(context, close_all, "excludeCycleExcludedClients", "Skip Excluded Characters");
        try window.widgets.hintText(context, .src(@src()), "Uses the excluded characters from the Mouse tab.");
        try window.bind.toggle(context, close_all, "excludeLoginScreenClients", "Skip Logged-Out Clients");
        try window.widgets.hintText(context, .src(@src()), "Leaves clients at the login screen running.");
    }
    try binding(window, context, profile_hotkeys, "hotkeyCloseActive");
    try window.widgets.hintText(context, .src(@src()), "Closes the EVE client you're in.");
    try binding(window, context, profile_hotkeys, "hotkeyMinimizeAll");
    try window.widgets.hintText(context, .src(@src()), "Minimizes every EVE client at once.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleVisibility");
    try window.widgets.hintText(context, .src(@src()), "Hides or shows all thumbnails.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleAutoMinimize");
    try window.widgets.hintText(context, .src(@src()), "Lasts until restart; it isn't saved.");
    try binding(window, context, profile_hotkeys, "hotkeyMoveToSavedPositions");
    try window.widgets.hintText(context, .src(@src()), "Uses the window positions saved on the Characters tab.");
    try actions.close(context);

    const modes = try window.widgets.openSection(context, "Modes", "Turn thumbnail dragging or Travel Mode on and off. Also in the tray menu.", &style.section);
    try binding(window, context, profile_hotkeys, "hotkeyToggleDragging");
    try window.widgets.hintText(context, .src(@src()), "Lets you move thumbnails with the mouse.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleTravelMode");
    try window.widgets.hintText(context, .src(@src()), "Alerts you when a character is left behind on a jump.");
    try modes.close(context);

    const panels = try window.widgets.openSection(context, "Panels", "Show or hide the panels, or clear the alert history. Also in the tray menu.", &style.section);
    try binding(window, context, profile_hotkeys, "hotkeyToggleNotificationHistory");
    try window.widgets.hintText(context, .src(@src()), "Shows or hides the alert history.");
    try binding(window, context, profile_hotkeys, "hotkeyClearNotificationHistory");
    try window.widgets.hintText(context, .src(@src()), "Empties the alert history.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleMapPanel");
    try window.widgets.hintText(context, .src(@src()), "Shows or hides the map.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleIntelPanel");
    try window.widgets.hintText(context, .src(@src()), "Shows or hides the intel panel.");
    try panels.close(context);

    const suspend_exit = try window.widgets.openSection(context, "Suspend, Mute and Exit", "Pause hotkeys or audio alerts, or close EVE-Maj Preview.", &style.section);
    try binding(window, context, profile_hotkeys, "hotkeySuspend");
    try window.widgets.hintText(context, .src(@src()), "This hotkey keeps working while the others are off.");
    try binding(window, context, profile_hotkeys, "hotkeyToggleAlertMute");
    try window.widgets.hintText(context, .src(@src()), "Mutes spoken and sound alerts until restart. Also in the tray menu.");
    try binding(window, context, profile_hotkeys, "hotkeyExitApp");
    try window.widgets.hintText(context, .src(@src()), "Closes EVE-Maj Preview; your EVE clients stay open.");
    try suspend_exit.close(context);

    const profile_section = try window.widgets.openSharedSection(context, "Profiles", "Cycle through profiles, or switch straight to one.", &style.section);
    try pair(window, context, global, "hotkeyPreviousProfile", "hotkeyNextProfile", "Loads the previous or next profile.");
    try profileSwitchRows(window, context);
    try profile_section.close(context);

    const outside = try window.widgets.openSharedSection(context, "Outside EVE", "Jump to the last app you used, a running app, or a URL in your browser.", &style.section);
    try pair(window, context, global, "hotkeyCycleAppsBackward", "hotkeyCycleAppsForward", "Steps through the running apps below, in order.");
    try binding(window, context, global, "hotkeyReturnToLastApp");
    try window.widgets.hintText(context, .src(@src()), "Jumps back to the app you used before EVE.");
    try window.widgets.separator(context, .str("knots.hotkeys.separator.last_app"));
    try window.widgets.subheading(context, .src(@src()), "App Hotkeys");
    try appHotkeys(window, context);
    try window.widgets.subheading(context, .src(@src()), "URL Hotkeys");
    try urlHotkeys(window, context);
    try outside.close(context);
}

/// `ref` has session.Ref's get and set for `field`.
fn binding(window: *Window, context: *ui.Frame, ref: anytype, comptime field: []const u8) !void {
    const label = comptime labels.hotkeyLabel(field);
    comptime std.debug.assert(label.half == .none);
    const row = try window.widgets.openWrappingBinding(context, .str("knots.hotkeys.binding:" ++ field), label.text);
    try window.hotkey.field(context, ref, field);
    try row.close(context);
}

/// Backward and forward a row each under the pair's name, like Hotkey Groups' keys, both explained by `hint`.
/// `ref`: session.Ref's get and set for both.
fn pair(window: *Window, context: *ui.Frame, ref: anytype, comptime previous: []const u8, comptime next: []const u8, comptime hint: []const u8) !void {
    const label = comptime labels.hotkeyLabel(previous);
    comptime std.debug.assert(label.half == .back and labels.hotkeyLabel(next).half == .forward and std.mem.eql(u8, label.text, labels.hotkeyLabel(next).text));
    const group = try window.widgets.openFieldGroup(context, .str("knots.hotkeys.pair:" ++ previous), label.text);
    inline for (.{ .{ previous, "Cycle Backward" }, .{ next, "Cycle Forward" } }) |half| {
        const row = try window.widgets.openWrappingBinding(context, .str("knots.hotkeys.half:" ++ half[0]), half[1]);
        try window.hotkey.field(context, ref, half[0]);
        try row.close(context);
        try window.widgets.hintText(context, .str("knots.hotkeys.half.hint:" ++ half[0]), hint);
    }
    try group.close(context);
}

fn profileSwitchRows(window: *Window, context: *ui.Frame) !void {
    for (profiles.list(window), 0..) |name, index| {
        const label = try lang.format(context.arena(), "Switch to: {name}", .{ .name = profiles.displayName(name) });
        const row = try window.widgets.openWrappingBinding(context, ui.Key.str("knots.hotkeys.profile").indexed(index), label);
        try window.hotkey.field(context, ProfileSwitch{ .window = window, .index = index, .target = name }, "hotkey");
        try row.close(context);
        try window.widgets.hintText(context, ui.Key.str("knots.hotkeys.profile.hint").indexed(index), "Loads this profile.");
    }
}

/// Hotkey boxes line up with the bindings above; a row left with no name and no key is removed.
fn appHotkeys(window: *Window, context: *ui.Frame) !void {
    const global = window.session.global();
    var index: usize = 0;
    while (index < global.ptr.appHotkeys.items.len) : (index += 1) {
        const entry = global.item("appHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.app").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try window.bind.textBox(context, entry, "executableName", "e.g., Discord.exe");
        if (try widgets.glyphButton(context, ui.Key.str("knots.hotkeys.app.pick").indexed(index), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(&window.status, window.allocator, &window.hotkeys.picker, index);
        try window.hotkey.field(context, entry, "hotkey");
        try row.close(context);
        try picker(window, context, entry);
        if (isBlank(context, entry, "executableName")) {
            global.remove("appHotkeys", index);
            window_picker.close(&window.hotkeys.picker);
            break;
        }
    }
    try draftAppRow(window, context, global.ptr.appHotkeys.items.len);
}

/// Keeps the list from looking empty; typing, binding or picking into it adds the entry.
fn draftAppRow(window: *Window, context: *ui.Frame, index: usize) !void {
    const row = Rect{ .key = .str("knots.hotkeys.app.draft"), .style = &style.list_row };
    _ = try row.open(context);
    if (try window.bind.stringBox(context, .str("knots.hotkeys.app.draft.name"), "", "e.g., Discord.exe", &style.text_input)) |typed| {
        if (std.mem.trim(u8, typed, " ").len > 0) addAppHotkey(window, "executableName", typed);
    }
    if (try widgets.glyphButton(context, .str("knots.hotkeys.app.draft.pick"), .refresh, "Pick Running Window", &style.add_button, false)) window_picker.open(&window.status, window.allocator, &window.hotkeys.picker, index);
    try window.hotkey.field(context, DraftAppHotkey{ .window = window, .index = index }, "hotkey");
    try row.close(context);
    if (try window_picker.select(context, &window.hotkeys.picker, .str("knots.hotkeys.app.picker"), index)) |chosen| {
        addAppHotkey(window, "executableName", chosen.executable);
        window_picker.close(&window.hotkeys.picker);
    }
}

/// A new app hotkey with just `field` set; `value` is of that field's type, e.g. the executable's name.
fn addAppHotkey(window: *Window, comptime field: []const u8, value: anytype) void {
    const added = window.session.global().append("appHotkeys", .{}) orelse return;
    added.set(field, value);
}

fn picker(window: *Window, context: *ui.Frame, entry: session.Ref(global_mod.AppHotkeyConfig)) !void {
    const chosen = try window_picker.select(context, &window.hotkeys.picker, .str("knots.hotkeys.app.picker"), entry.index) orelse return;
    entry.set("executableName", chosen.executable);
    window_picker.close(&window.hotkeys.picker);
}

/// Like appHotkeys, ending in the presets.
fn urlHotkeys(window: *Window, context: *ui.Frame) !void {
    const global = window.session.global();
    var index: usize = 0;
    while (index < global.ptr.urlHotkeys.items.len) : (index += 1) {
        const entry = global.item("urlHotkeys", index);
        const row = Rect{ .key = ui.Key.str("knots.hotkeys.url").indexed(index), .style = &style.list_row };
        _ = try row.open(context);
        try window.bind.textBox(context, entry, "url", "https://example.com");
        try window.hotkey.field(context, entry, "hotkey");
        try row.close(context);
        // Only aDashboard takes a clipboard upload, so the option is cleared for any other URL.
        if (isAdashboard(entry.get("url"))) {
            try window.bind.toggle(context, entry, "uploadClipboard", "Upload Clipboard Content (dscan/local)");
            try window.widgets.hintText(context, ui.Key.str("knots.hotkeys.url.upload.hint").indexed(index), "Sends the clipboard to aDashboard and opens the result.");
        } else if (entry.get("uploadClipboard")) {
            entry.set("uploadClipboard", false);
        }
        // A just-added row starts blank, so it stays until its box has had focus.
        if (window.hotkeys.fresh_url_index == index and context.ui().focused(bind.boxKey(entry, "url").hash())) window.hotkeys.fresh_url_index = null;
        if (window.hotkeys.fresh_url_index != index and isBlank(context, entry, "url")) {
            global.remove("urlHotkeys", index);
            break;
        }
    }
    // The presets wait, filled in, until they're bound, so they're offered without being saved.
    const count = global.ptr.urlHotkeys.items.len;
    if (!hasUrlHotkey(window, isDotlan)) try draftUrlRow(window, context, .str("knots.hotkeys.url.draft.dotlan"), count, DOTLAN_URL);
    if (!hasUrlHotkey(window, isAdashboard)) try draftUrlRow(window, context, .str("knots.hotkeys.url.draft.adashboard"), count + 1, ADASHBOARD_URL);
    const add = Rect{ .key = .src(@src()), .style = &style.button_row_end };
    _ = try add.open(context);
    if (try widgets.glyphButton(context, .str("knots.hotkeys.url.add"), .add, "Add URL Hotkey", &style.add_button, false)) {
        if (global.append("urlHotkeys", .{})) |added| window.hotkeys.fresh_url_index = added.index;
    }
    try add.close(context);
}

fn hasUrlHotkey(window: *Window, comptime matches: fn ([]const u8) bool) bool {
    for (window.session.global().ptr.urlHotkeys.items) |entry| {
        if (matches(entry.url)) return true;
    }
    return false;
}

/// Like draftAppRow, prefilled with `url`; typing another URL or binding a key adds the entry.
fn draftUrlRow(window: *Window, context: *ui.Frame, key: ui.Key, index: usize, url: []const u8) !void {
    const row = Rect{ .key = key, .style = &style.list_row };
    _ = try row.open(context);
    if (try window.bind.stringBox(context, key.indexed(1), url, "https://example.com", &style.text_input)) |typed| {
        if (std.mem.trim(u8, typed, " ").len > 0) {
            const added = window.session.global().append("urlHotkeys", .{}) orelse return;
            added.set("url", typed);
        }
    }
    try window.hotkey.field(context, DraftUrlHotkey{ .window = window, .index = index, .url = url }, "hotkey");
    try row.close(context);
}

fn isDotlan(url: []const u8) bool {
    return std.ascii.findIgnoreCase(url, "evemaps.dotlan.net") != null;
}

/// No text and no key, once its box isn't being typed in; `entry` is a hotkey's session.Ref.
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
