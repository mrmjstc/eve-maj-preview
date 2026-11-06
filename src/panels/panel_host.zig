//! What App lends the panels and what their windows ask of it, since App owns them and so can't be imported by them.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const universe = @import("../map/universe.zig");
const set = @import("../thumbnail/set.zig");

const ThumbnailSet = set.ThumbnailSet;

/// What a panel builds its window from; App's.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Borrowed from App, which outlives every panel.
    store: *config_mod.ProfileStore,
    instance: win32.HINSTANCE,
};

/// What a panel's input asks App to do.
pub const Request = union(enum) {
    /// As a thumbnail click does.
    activate: win32.HWND,
    /// On the Map Panel, for an Intel Panel row.
    show_system: universe.SystemIndex,
    /// While the Map Panel's search has the keyboard.
    suspend_hotkeys,
    resume_hotkeys,
};

/// App fills it in; main thread only.
pub const Host = struct {
    /// Null outside the run and while a rebuild failed; read each time, as it's rebuilt.
    thumbnail_set: *const fn () ?*ThumbnailSet,
    run: *const fn (request: Request) void,
};
