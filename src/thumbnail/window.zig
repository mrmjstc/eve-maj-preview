//! One tracked EVE client: its record, and the two windows (DWM thumbnail plus layered text/border overlay) that show it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const config_mod = @import("../config.zig");
const state = @import("state.zig");
const overlay = @import("overlay.zig");
const stack = @import("../notifications/stack.zig");
const scout = @import("../clients/scout.zig");
const connections_mod = @import("../map/connections.zig");
const log = @import("../log.zig");

const ThumbnailState = config_mod.ThumbnailState;
const slog = log.Scoped("thumbnail");

/// Shared with the hover zoom's windows.
pub const WINDOW_CLASS_NAME = "EVE_THUMBNAIL_CLASS";
pub const TEXT_WINDOW_CLASS_NAME = "EVE_TEXT_OVERLAY_CLASS";
/// The window property on both windows that holds the source client's HWND.
pub const SOURCE_HWND_PROP = "SOURCE_HWND";

/// The owned strings the render cache borrows, so only replaceText may swap them.
pub const OwnedText = enum { character_name, system_name, group_badge_label };

/// What the trackers last pushed; a null rate has too short a span yet (see activity/tracker.zig).
pub const ActivityStats = struct {
    incoming_dps: ?f32 = null,
    outgoing_dps: ?f32 = null,
    mining_rate: ?f32 = null,
    mining_isk_rate: ?f32 = null,
    bounty_isk_rate: ?f32 = null,
    cpu_percent: f32 = 0.0,
    ram_mb: f32 = 0.0,
    vram_mb: f32 = 0.0,
    /// Null until the server's first reply, and after a timeout.
    ping_ms: ?u32 = null,

    /// Tells never-reported (show nothing) from a reported null rate (show "??").
    has_dps: bool = false,
    has_mining: bool = false,
    has_bounty: bool = false,
    has_resources: bool = false,
    /// VRAM can stay unavailable once CPU and RAM are known.
    has_vram: bool = false,
    /// Connected to a game server, so there's a ping to show.
    has_ping: bool = false,

    /// Once reported: "??" while the rate is unknown, hidden while it's zero.
    pub fn showsIncoming(self: *const ActivityStats) bool {
        return self.has_dps and shown(self.incoming_dps);
    }

    pub fn showsOutgoing(self: *const ActivityStats) bool {
        return self.has_dps and shown(self.outgoing_dps);
    }

    pub fn showsMining(self: *const ActivityStats) bool {
        return self.has_mining and shown(self.mining_rate);
    }

    pub fn showsBounty(self: *const ActivityStats) bool {
        return self.has_bounty and shown(self.bounty_isk_rate);
    }

    fn shown(rate: ?f32) bool {
        return rate == null or rate.? > 0;
    }

    /// Each setter returns whether anything shown changed.
    pub fn setDps(self: *ActivityStats, incoming: ?f32, outgoing: ?f32) bool {
        const changed = !self.has_dps or self.incoming_dps != incoming or self.outgoing_dps != outgoing;
        self.has_dps = true;
        self.incoming_dps = incoming;
        self.outgoing_dps = outgoing;
        return changed;
    }

    pub fn setMining(self: *ActivityStats, rate: ?f32, isk_rate: ?f32) bool {
        const changed = !self.has_mining or self.mining_rate != rate or self.mining_isk_rate != isk_rate;
        self.has_mining = true;
        self.mining_rate = rate;
        self.mining_isk_rate = isk_rate;
        return changed;
    }

    pub fn setBounty(self: *ActivityStats, isk_rate: ?f32) bool {
        const changed = !self.has_bounty or self.bounty_isk_rate != isk_rate;
        self.has_bounty = true;
        self.bounty_isk_rate = isk_rate;
        return changed;
    }

    /// Back to never heard from the combat, mining and bounty trackers, keeping resource usage and ping.
    pub fn clearLogReadings(self: *ActivityStats) bool {
        const had_any = self.has_dps or self.has_mining or self.has_bounty;
        self.* = .{
            .cpu_percent = self.cpu_percent,
            .ram_mb = self.ram_mb,
            .vram_mb = self.vram_mb,
            .has_resources = self.has_resources,
            .has_vram = self.has_vram,
            .ping_ms = self.ping_ms,
            .has_ping = self.has_ping,
        };
        return had_any;
    }

    pub fn setResources(self: *ActivityStats, cpu_percent: f32, ram_mb: f32, vram_mb: f32, has_vram: bool) bool {
        const changed = !self.has_resources or self.cpu_percent != cpu_percent or self.ram_mb != ram_mb or
            self.vram_mb != vram_mb or self.has_vram != has_vram;
        self.has_resources = true;
        self.cpu_percent = cpu_percent;
        self.ram_mb = ram_mb;
        self.vram_mb = vram_mb;
        self.has_vram = has_vram;
        return changed;
    }

    pub fn setPing(self: *ActivityStats, is_connected: bool, ping_ms: ?u32) bool {
        const changed = self.has_ping != is_connected or self.ping_ms != ping_ms;
        self.has_ping = is_connected;
        self.ping_ms = ping_ms;
        return changed;
    }
};

/// ThumbnailSet records jumps; travel/left_behind.zig reads it and flags alerts.
pub const LeftBehindState = struct {
    /// Zero = hasn't jumped this session.
    last_jump: win32.Ticks = .{},
    /// Guards the left-behind alert to one per episode; cleared on jump.
    alert_fired: bool = false,

    pub fn recordJump(self: *LeftBehindState) void {
        self.last_jump = win32.Ticks.now();
        self.alert_fired = false;
    }
};

/// Only AutoMinimizer.check writes it after creation.
pub const AutoMinimizeState = struct {
    /// When check's delay counts from: the last tick the thumbnail was Active or Minimized.
    inactive_since: win32.Ticks,
};

pub const ThumbnailWindow = struct {
    hwnd: win32.HWND,
    /// The layered text and border overlay.
    text_hwnd: win32.HWND,
    thumbnail_id: win32.HTHUMBNAIL,
    source_hwnd: win32.HWND,
    is_eve_client: bool,
    /// Owned; ThumbnailSet frees it when it removes or renames the thumbnail.
    character_name: []const u8,
    /// Owned; ThumbnailSet frees the old one on each system change.
    system_name: []const u8,
    /// YYYYMMDD*1000000+HHMMSS of the event that set system_name; 0 if unreadable, which always applies.
    system_name_event_timestamp: u64 = 0,
    /// Empty while showSystemConnections is off, or system_name isn't on the gate map; only ThumbnailSet.updateConnections writes it.
    connections: connections_mod.Connections = .{},
    travel: LeftBehindState = .{},
    notifications: stack.NotificationStack = .{},
    last_click_time: win32.Ticks = .{},
    is_excluded_from_cycle: bool = false,
    /// Zero while no character is logged in.
    session_start: win32.Ticks = .{},
    needs_render: bool = false,
    is_win32_enabled: bool = true,
    /// Set by drag/thumbnail.zig for as long as either of its windows is dragged.
    is_dragged: bool = false,

    stats: ActivityStats = .{},

    render_cache: overlay.RenderCache = .{},

    visibility_state: state.VisibilityState = .visible,
    auto_minimize: AutoMinimizeState,
    /// Catches a minimize/restore with no focus change; refreshed each tick except while dragged.
    was_minimized: bool = false,

    cached_system_color: u32 = 0,
    /// Null when "Unique Character Name Colors" is off; callers fall back to their default.
    cached_character_color: ?u32 = null,
    /// Borrows from config or character_name.
    cached_display_name: []const u8 = "",
    cached_border_colors: ?config_mod.CharacterBorderColorsConfig = null,
    cached_excluded_from_minimize: bool = false,
    cached_hide_thumbnail: bool = false,
    cached_thumbnail_size: ?config_mod.CharacterThumbnailSizeConfig = null,
    cached_opacity: u8 = 255,
    /// Owned; the badge-enabled groups this character is in, comma-joined ("1, 3"), or "" for none.
    cached_group_badge_label: []const u8,

    /// Sole writer of the config-derived cached_* fields, all but the group badge label.
    pub fn refreshConfigCache(self: *ThumbnailWindow, config: *const config_mod.Config, auto_colors: *config_mod.AutoColorStore) void {
        self.cached_system_color = if (self.system_name.len > 0) auto_colors.systemNameColor(config, self.system_name) else config.shownColors().system_name_color;
        const is_logged_in = !scout.isGenericCharacterName(self.character_name);
        self.cached_character_color = if (is_logged_in) auto_colors.characterNameColor(config, self.character_name) else null;
        self.cached_display_name = config.getDisplayName(self.character_name);
        self.cached_border_colors = if (is_logged_in) auto_colors.characterBorderColors(config, self.character_name) else null;
        self.cached_excluded_from_minimize = config.isExcludedFromMinimize(self.character_name);
        self.cached_hide_thumbnail = config.isThumbnailHidden(self.character_name);
        self.cached_thumbnail_size = config.getCharacterSize(self.character_name);
        self.cached_opacity = config.getCharacterOpacity(self.character_name);
    }

    /// Takes ownership of `new_text`; drops the render cache that borrows the old string before freeing it.
    pub fn replaceText(self: *ThumbnailWindow, allocator: std.mem.Allocator, comptime text: OwnedText, new_text: []const u8) void {
        self.render_cache.settings = null;
        const slot = switch (text) {
            .character_name => blk: {
                self.render_cache.character_name.dims = null;
                break :blk &self.character_name;
            },
            .system_name => blk: {
                self.render_cache.system_name.dims = null;
                break :blk &self.system_name;
            },
            .group_badge_label => blk: {
                self.render_cache.group_badge.dims = null;
                break :blk &self.cached_group_badge_label;
            },
        };
        const old_text = slot.*;
        slot.* = new_text;
        allocator.free(old_text);
    }

    pub fn sessionMinutes(self: *const ThumbnailWindow, now: win32.Ticks) ?u64 {
        if (self.session_start.isZero()) return null;
        return now.elapsedSince(self.session_start) / std.time.ms_per_min;
    }

    pub fn isFocused(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) bool {
        return self.source_hwnd == active_source_hwnd;
    }

    /// Only a style-lookup key (getStateConfig), never stored.
    pub fn effectiveRenderState(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) ThumbnailState {
        return state.renderState(.{
            .is_dragged = self.is_dragged,
            .has_alert = !self.notifications.isEmpty(),
            .is_focused = self.isFocused(active_source_hwnd),
            .is_minimized = win32.isWindowIconic(self.source_hwnd),
        });
    }

    /// Always recorded, even while isShown keeps it up, so the hide applies once the alert or drag ends.
    pub fn setVisibility(self: *ThumbnailWindow, new_visibility: state.VisibilityState) void {
        if (self.visibility_state != new_visibility) {
            slog.debug("Visibility transition for '{s}': {} -> {}", .{ self.character_name, self.visibility_state, new_visibility });
        }
        self.visibility_state = new_visibility;
    }

    pub fn isVisible(self: *const ThumbnailWindow) bool {
        return self.visibility_state.isVisible();
    }

    /// Whether it's on screen: visible, or hidden but kept up by a revealing alert or a drag.
    pub fn isShown(self: *const ThumbnailWindow) bool {
        return self.isVisible() or self.notifications.revealsThumbnail() or self.is_dragged;
    }

    pub fn show(self: *const ThumbnailWindow, is_shown: bool) void {
        const show_command: c_int = if (is_shown) win32.SW_SHOW else win32.SW_HIDE;
        _ = win32.ShowWindow(self.hwnd, show_command);
        _ = win32.ShowWindow(self.text_hwnd, show_command);
    }

    /// Keeps the text overlay above the thumbnail.
    pub fn moveTo(self: *const ThumbnailWindow, x: i32, y: i32, size: ?Size) void {
        const width = if (size) |s| s.width else 0;
        const height = if (size) |s| s.height else 0;
        const size_flag: u32 = if (size == null) win32.SWP_NOSIZE else 0;
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, x, y, width, height, size_flag | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        _ = win32.SetWindowPos(self.text_hwnd, win32.HWND_TOPMOST, x, y, width, height, size_flag | win32.SWP_NOACTIVATE);
    }

    /// Updates the DWM thumbnail's rect at once, since DeferWindowPos won't.
    pub fn deferPlace(self: *const ThumbnailWindow, hdwp: win32.HDWP, x: i32, y: i32, size: ?Size) ?win32.HDWP {
        const width = if (size) |s| s.width else 0;
        const height = if (size) |s| s.height else 0;
        const size_flag: u32 = if (size == null) win32.SWP_NOSIZE else 0;
        const after_thumbnail = win32.DeferWindowPos(hdwp, self.hwnd, win32.HWND_NOTOPMOST, x, y, width, height, size_flag | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return null;
        const after_text = win32.DeferWindowPos(after_thumbnail, self.text_hwnd, win32.HWND_TOPMOST, x, y, width, height, size_flag | win32.SWP_NOACTIVATE) orelse return null;
        if (size) |s| self.setThumbnailRect(s);
        return after_text;
    }

    /// text_hwnd follows on its next render, through UpdateLayeredWindow.
    pub fn resize(self: *const ThumbnailWindow, size: Size) void {
        // HWND_TOP doesn't compile against the non-allowzero HWND; SWP_NOZORDER ignores it anyway.
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, 0, 0, size.width, size.height, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        self.setThumbnailRect(size);
    }

    fn setThumbnailRect(self: *const ThumbnailWindow, size: Size) void {
        const props = thumbnailProps(size, win32.DWM_TNP_RECTDESTINATION);
        _ = win32.DwmUpdateThumbnailProperties(self.thumbnail_id, &props);
    }
};

pub const Size = struct { width: i32, height: i32 };

pub const CreateOptions = struct {
    position: config_mod.Position,
    size: Size,
    opacity: u8,
    is_click_through: bool,
};

pub const Handles = struct {
    hwnd: win32.HWND,
    text_hwnd: win32.HWND,
    thumbnail_id: win32.HTHUMBNAIL,
};

/// Passed in, since input handling sits above thumbnail/.
pub const WindowProcs = struct {
    thumbnail: win32.WNDPROC,
    text: win32.WNDPROC,
};

var g_has_registered_classes: bool = false;

/// Once per process, since window classes outlive any one ThumbnailSet.
pub fn registerClasses(instance: win32.HINSTANCE, procs: WindowProcs) !void {
    if (g_has_registered_classes) return;

    // Black, not white COLOR_WINDOW: shows through whenever DWM has no live thumbnail frame to composite.
    const thumbnail_bg_brush = win32.CreateSolidBrush(0x00000000) orelse return error.CreateBrushFailed;
    // Owned by the class once registered.
    gdi_overlay.registerWindowClass(instance, procs.thumbnail, WINDOW_CLASS_NAME, thumbnail_bg_brush) catch |err| {
        _ = win32.DeleteObject(thumbnail_bg_brush);
        return err;
    };
    // No background brush for a layered window.
    try gdi_overlay.registerWindowClass(instance, procs.text, TEXT_WINDOW_CLASS_NAME, null);
    g_has_registered_classes = true;
}

/// Both windows stay hidden until the first render shows them.
pub fn create(allocator: std.mem.Allocator, instance: win32.HINSTANCE, source_hwnd: win32.HWND, character_name: []const u8, options: CreateOptions) !Handles {
    const position = options.position;
    const size = options.size;
    const name_z = try allocator.dupeSentinel(u8, character_name, 0);
    defer allocator.free(name_z);

    // Both windows, since the topmost text_hwnd is the one that gets mouse messages.
    const click_through_ex: win32.DWORD = if (options.is_click_through) win32.WS_EX_TRANSPARENT else 0;

    const hwnd = win32.CreateWindowExA(
        win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED | win32.WS_EX_NOACTIVATE | click_through_ex,
        WINDOW_CLASS_NAME,
        name_z.ptr,
        win32.WS_POPUP,
        position.x,
        position.y,
        size.width,
        size.height,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = win32.DestroyWindow(hwnd);

    if (!win32.toBool(win32.SetLayeredWindowAttributes(hwnd, 0, options.opacity, win32.LWA_ALPHA))) return error.SetLayeredWindowAttributesFailed;

    var thumbnail_id: win32.HTHUMBNAIL = undefined;
    if (win32.DwmRegisterThumbnail(hwnd, source_hwnd, &thumbnail_id) != 0) return error.DwmRegisterThumbnailFailed;
    errdefer _ = win32.DwmUnregisterThumbnail(thumbnail_id);

    const props = thumbnailProps(size, win32.DWM_TNP_VISIBLE | win32.DWM_TNP_RECTDESTINATION | win32.DWM_TNP_SOURCECLIENTAREAONLY);
    if (win32.DwmUpdateThumbnailProperties(thumbnail_id, &props) != 0) return error.DwmUpdateThumbnailPropertiesFailed;

    // Its own error name, since the error is the log's only clue to which window failed.
    const text_hwnd = win32.CreateWindowExA(
        win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | click_through_ex,
        TEXT_WINDOW_CLASS_NAME,
        name_z.ptr,
        win32.WS_POPUP,
        position.x,
        position.y,
        size.width,
        size.height,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateTextWindowFailed;
    errdefer _ = win32.DestroyWindow(text_hwnd);

    // Clicks resolve the source client through SOURCE_HWND; each window's userdata points at the other for drags.
    if (!win32.toBool(win32.SetPropA(hwnd, SOURCE_HWND_PROP, source_hwnd))) return error.SetPropFailed;
    if (!win32.toBool(win32.SetPropA(text_hwnd, SOURCE_HWND_PROP, source_hwnd))) return error.SetPropFailed;
    try link(hwnd, text_hwnd);
    try link(text_hwnd, hwnd);

    return .{ .hwnd = hwnd, .text_hwnd = text_hwnd, .thumbnail_id = thumbnail_id };
}

/// Shows the text overlay once its first render is in place, so it never flashes up empty.
pub fn showText(handles: Handles, position: config_mod.Position, size: Size) void {
    _ = win32.SetWindowPos(handles.text_hwnd, win32.HWND_TOPMOST, position.x, position.y, size.width, size.height, win32.SWP_NOACTIVATE);
    _ = win32.ShowWindow(handles.text_hwnd, win32.SW_SHOW);
    _ = win32.UpdateWindow(handles.text_hwnd);
}

/// Render cache GDI objects first, and the DWM thumbnail before the window it draws into.
pub fn destroy(thumbnail: *const ThumbnailWindow) void {
    thumbnail.render_cache.deinit();
    destroyHandles(.{ .hwnd = thumbnail.hwnd, .text_hwnd = thumbnail.text_hwnd, .thumbnail_id = thumbnail.thumbnail_id });
}

pub fn destroyHandles(handles: Handles) void {
    _ = win32.DestroyWindow(handles.text_hwnd);
    _ = win32.DwmUnregisterThumbnail(handles.thumbnail_id);
    _ = win32.DestroyWindow(handles.hwnd);
}

/// rcSource stays zeroed, meaning the whole source window.
pub fn thumbnailProps(size: Size, flags: u32) win32.DWM_THUMBNAIL_PROPERTIES {
    return .{
        .dwFlags = flags,
        .rcDestination = .{ .left = 0, .top = 0, .right = size.width, .bottom = size.height },
        .rcSource = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .opacity = 255,
        .fVisible = win32.TRUE,
        .fSourceClientAreaOnly = win32.TRUE,
    };
}

/// Stores `other` in `hwnd`'s userdata; only the last error tells a previous 0 from a failure.
fn link(hwnd: win32.HWND, other: win32.HWND) !void {
    win32.SetLastError(0);
    if (win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(other)) == 0 and win32.GetLastError() != 0) return error.SetWindowLongPtrFailed;
}
