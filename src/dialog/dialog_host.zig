//! What App lends the configuration window and what the window asks of it, since App starts the window and so can't be imported by it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config = @import("../config.zig");
const scout_mod = @import("../clients/scout.zig");
const character_ids_mod = @import("../chatlog/character_ids.zig");
const set = @import("../thumbnail/set.zig");
const panel_host = @import("../panels/panel_host.zig");

const GlobalConfig = config.GlobalConfig;
const ThumbnailSet = set.ThumbnailSet;

/// How far a live profile edit moves thumbnails; `spaces` reflows only active spaces.
pub const LiveLayout = enum { none, spaces, all };

/// What the window builds from; App's, which outlives every window.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Borrowed from App; `live` is what the window edits.
    store: *config.ProfileStore,
    /// Borrowed from App: the running settings, which the window edits through a draft.
    global_settings: *GlobalConfig,
    /// Borrowed from App.
    scout: *const scout_mod.Scout,
    /// Borrowed from App; locks its own map.
    character_ids: *character_ids_mod.CharacterIds,
};

/// What the window asks App to do.
pub const Request = union(enum) {
    live_profile_edited: LiveLayout,
    /// Done before returning, unlike a hotkey's switch; borrowed for the call.
    switch_profile: []const u8,
    /// While the window records a hotkey.
    suspend_hotkeys_for_recording,
    resume_hotkeys_for_recording,
};

/// What a Save hands App.
pub const Save = struct {
    is_profile_dirty: bool,
    /// Borrowed; App adopts a copy, so it's left as it was whether or not the save fails.
    global_draft: ?*const GlobalConfig,
};

/// App fills it in; main thread only.
pub const Host = struct {
    /// Null outside the run and while a rebuild failed; read each time, as it's rebuilt.
    thumbnail_set: *const fn () ?*ThumbnailSet,
    /// The hidden window commands are posted to; null until main.zig creates it.
    timer_window: *const fn () ?win32.HWND,
    /// Commits the profile, restarts what reads settings only at setup, then writes and applies the global settings.
    save: *const fn (save: Save) anyerror!void,
    run: *const fn (request: Request) void,
};

/// What App asks of the window, which knots_host.init hands back.
pub const DialogHooks = struct {
    /// Draws a frame soon, for a change made outside one.
    redraw: *const fn () void,
    is_open: *const fn () bool,
    /// Returns whether the exit waits for the window to close, which then posts the quit itself.
    close_for_exit: *const fn () bool,
    /// The global settings as the window is editing them, else the saved ones.
    live_global: *const fn () *const GlobalConfig,
    /// Opens the window, or brings it forward, on `page`'s tab.
    open_at: *const fn (page: panel_host.SettingsPage) void,
};
