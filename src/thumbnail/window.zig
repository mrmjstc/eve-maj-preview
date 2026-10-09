//! One tracked EVE client: its record, and the two windows (DWM thumbnail plus layered text/border overlay) that show it.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const gdi_overlay = @import("../platform/gdi_overlay.zig");
const config_mod = @import("../config.zig");
const input = @import("input.zig");
const state = @import("state.zig");
const overlay = @import("overlay.zig");
const thumbnail_drag = @import("../drag/thumbnail.zig");
const travel_left_behind = @import("../travel/left_behind.zig");
const stack = @import("../notifications/stack.zig");
const auto_minimize_mod = @import("../clients/auto_minimize.zig");
const scout = @import("../clients/scout.zig");
const log = @import("../log.zig");

const ThumbnailState = state.ThumbnailState;
const slog = log.scoped("thumbnail");

/// Shared with the hover zoom's windows.
pub const WINDOW_CLASS_NAME = "EVE_THUMBNAIL_CLASS";
pub const TEXT_WINDOW_CLASS_NAME = "EVE_TEXT_OVERLAY_CLASS";

/// What the activity trackers last pushed; `null` rates mean not enough span yet to trust one (see activity/tracker.zig).
pub const ActivityStats = struct {
    incoming_dps: ?f32 = null,
    outgoing_dps: ?f32 = null,
    mining_rate: ?f32 = null,
    mining_isk_rate: ?f32 = null,
    bounty_isk_rate: ?f32 = null,
    cpu_percent: f32 = 0.0,
    ram_mb: f32 = 0.0,
    vram_mb: f32 = 0.0,

    // False until a tracker's first push arrives, to tell "never heard from it" (show nothing) from a reported null rate (show "??").
    has_dps: bool = false,
    has_mining: bool = false,
    has_bounty: bool = false,
    has_resources: bool = false,
    // Separate from has_resources: VRAM can stay unavailable (no PDH support, no matching GPU instance) once CPU/RAM are known.
    has_vram: bool = false,

    /// Whether each stat is shown: once its tracker has reported, as "??" while the rate is unknown, and not at all while it's zero.
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
};

pub const ThumbnailWindow = struct {
    hwnd: win32.HWND,
    /// Layered window used for both the text overlay and the border.
    text_hwnd: win32.HWND,
    thumbnail_id: win32.HTHUMBNAIL,
    source_hwnd: win32.HWND,
    is_eve_client: bool,
    /// Owned; Painter frees it when it removes or renames the thumbnail.
    character_name: []const u8,
    /// Owned; Painter frees the old one on each system change.
    system_name: []const u8,
    /// In-game timestamp of the event that set system_name (YYYYMMDD*1000000+HHMMSS); 0 = untimestamped source (e.g. live tailing), which always applies.
    system_name_event_ts: u64 = 0,
    travel: travel_left_behind.LeftBehindState = .{},
    notifications: stack.NotificationStack = .{},
    last_click_time: win32.Ticks = .{},
    is_excluded_from_cycle: bool = false,
    /// Zero while no character is logged in.
    session_start: win32.Ticks = .{},
    needs_render: bool = false,
    win32_enabled: bool = true,

    stats: ActivityStats = .{},

    render_cache: overlay.RenderCache = .{},

    visibility_state: state.VisibilityState = .visible,
    /// Set while a Test Notification has force-shown a hidden thumbnail; restored once its notifications clear.
    test_restore_visibility: ?state.VisibilityState = null,
    auto_minimize: auto_minimize_mod.AutoMinimizeState,
    /// Edge-detector so a minimize/restore with no accompanying focus change still marks this dirty for repaint; refreshed each tick by Painter.updateThumbnailStates, except while dragged.
    was_minimized: bool = false,

    // Config-derived per-character values, set only by refreshConfigCache: resolved on character_name change or (re)creation rather than every tick (list_view.zig hashes these every ~50ms per thumbnail, createRenderSettings reads them per dirty thumbnail).
    cached_system_color: u32 = 0,
    /// Auto-generated per-character name color; null when "Unique Character Name Colors" is disabled, and callers fall back to their own default.
    cached_character_color: ?u32 = null,
    cached_display_name: []const u8 = "",
    cached_border_colors: ?config_mod.CharacterBorderColorsConfig = null,
    cached_excluded_from_minimize: bool = false,
    cached_hide_thumbnail: bool = false,
    cached_thumbnail_size: ?config_mod.CharacterThumbnailSizeConfig = null,
    cached_opacity: u8 = 255,
    /// Owned, comma-joined label of the badge-enabled groups this character is in ("1, 3"); "" = none.
    cached_group_badge_label: []const u8,

    /// Re-resolves every config-derived cached_* field (except the owned group badge label) for the current character_name/system_name.
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

    pub fn sessionMinutes(self: *const ThumbnailWindow, now: win32.Ticks) ?u64 {
        if (self.session_start.isZero()) return null;
        return now.elapsedSince(self.session_start) / std.time.ms_per_min;
    }

    /// Whether this thumbnail's source_hwnd is the live "who's focused" pointer.
    pub fn isFocused(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) bool {
        return self.source_hwnd == active_source_hwnd;
    }

    /// The one place a thumbnail's state is decided; only a style-lookup key (getStateConfig), never stored.
    pub fn effectiveRenderState(self: *const ThumbnailWindow, active_source_hwnd: ?win32.HWND) ThumbnailState {
        if (thumbnail_drag.isDragging(self)) return .dragging;
        if (!self.notifications.isEmpty()) return .alert;
        if (self.isFocused(active_source_hwnd)) return .active;
        if (win32.isWindowIconic(self.source_hwnd)) return .minimized;
        return .inactive;
    }

    /// Refuses to hide while alerting or dragging; an invalid transition is logged and ignored.
    pub fn setVisibility(self: *ThumbnailWindow, new_visibility: state.VisibilityState) void {
        const blocks_hiding = !self.notifications.isEmpty() or thumbnail_drag.isDragging(self);
        if (new_visibility != .visible and blocks_hiding) {
            slog.warn("Cannot hide '{s}' while it's alerting or being dragged", .{self.character_name});
            return;
        }

        const transitioned_visibility = state.tryTransitionVisibility(
            self.visibility_state,
            new_visibility,
            self.character_name,
        );

        self.visibility_state = transitioned_visibility;
    }

    pub fn isVisible(self: *const ThumbnailWindow) bool {
        return self.visibility_state.isVisible();
    }

    pub fn show(self: *const ThumbnailWindow, shown: bool) void {
        const cmd: c_int = if (shown) win32.SW_SHOW else win32.SW_HIDE;
        _ = win32.ShowWindow(self.hwnd, cmd);
        _ = win32.ShowWindow(self.text_hwnd, cmd);
    }

    /// Moves (and, given a size, resizes) both windows, keeping the text overlay above the thumbnail.
    pub fn moveTo(self: *const ThumbnailWindow, x: i32, y: i32, size: ?Size) void {
        const w = if (size) |s| s.width else 0;
        const h = if (size) |s| s.height else 0;
        const size_flag: u32 = if (size == null) win32.SWP_NOSIZE else 0;
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, x, y, w, h, size_flag | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        _ = win32.SetWindowPos(self.text_hwnd, win32.HWND_TOPMOST, x, y, w, h, size_flag | win32.SWP_NOACTIVATE);
    }

    /// Queues moving (and, given a size, resizing) both windows; the DWM thumbnail's own rect is updated straight away, since DeferWindowPos won't.
    pub fn deferPlace(self: *const ThumbnailWindow, hdwp: win32.HDWP, x: i32, y: i32, size: ?Size) ?win32.HDWP {
        const w = if (size) |s| s.width else 0;
        const h = if (size) |s| s.height else 0;
        const size_flag: u32 = if (size == null) win32.SWP_NOSIZE else 0;
        const after_thumb = win32.DeferWindowPos(hdwp, self.hwnd, win32.HWND_NOTOPMOST, x, y, w, h, size_flag | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE) orelse return null;
        const after_text = win32.DeferWindowPos(after_thumb, self.text_hwnd, win32.HWND_TOPMOST, x, y, w, h, size_flag | win32.SWP_NOACTIVATE) orelse return null;
        if (size) |s| self.setThumbnailRect(s);
        return after_text;
    }

    /// Resizes the DWM thumbnail window; text_hwnd resizes itself on its next render (UpdateLayeredWindow).
    pub fn resize(self: *const ThumbnailWindow, size: Size) void {
        // HWND_NOTOPMOST, not HWND_TOP (a zero-valued sentinel the non-allowzero HWND type can't represent); SWP_NOZORDER makes the value irrelevant anyway.
        _ = win32.SetWindowPos(self.hwnd, win32.HWND_NOTOPMOST, 0, 0, size.width, size.height, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        self.setThumbnailRect(size);
    }

    fn setThumbnailRect(self: *const ThumbnailWindow, size: Size) void {
        const props = thumbnailProps(size, win32.DWM_TNP_RECTDESTINATION);
        _ = win32.DwmUpdateThumbnailProperties(self.thumbnail_id, &props);
    }
};

pub const Size = struct { width: i32, height: i32 };

/// The handles `create` made; the caller builds the ThumbnailWindow record around them.
pub const Handles = struct {
    hwnd: win32.HWND,
    text_hwnd: win32.HWND,
    thumbnail_id: win32.HTHUMBNAIL,
};

var g_classes_registered: bool = false;

/// Once per process, since window classes outlive any one Painter.
pub fn registerClasses(instance: win32.HINSTANCE) !void {
    if (g_classes_registered) return;

    // Black, not white COLOR_WINDOW: shows through whenever DWM has no live thumbnail frame to composite.
    const thumbnail_bg_brush = win32.CreateSolidBrush(0x00000000) orelse return error.CreateBrushFailed;
    try gdi_overlay.registerWindowClass(instance, input.windowProc, WINDOW_CLASS_NAME, thumbnail_bg_brush);
    // No background brush for a layered window.
    try gdi_overlay.registerWindowClass(instance, input.textWindowProc, TEXT_WINDOW_CLASS_NAME, null);
    g_classes_registered = true;
}

/// Creates the thumbnail window showing `source_hwnd` through DWM and its text overlay, linked to each other and the source; both stay hidden until the first render shows them.
pub fn create(allocator: std.mem.Allocator, instance: win32.HINSTANCE, source_hwnd: win32.HWND, character_name: []const u8, pos: config_mod.Position, size: Size, opacity: u8, click_through: bool) !Handles {
    const name_z = try allocator.dupeSentinel(u8, character_name, 0);
    defer allocator.free(name_z);

    // Needed on both windows since text_hwnd, being topmost, is the one that actually receives mouse messages.
    const click_through_ex: win32.DWORD = if (click_through) win32.WS_EX_TRANSPARENT else 0;

    const hwnd = win32.CreateWindowExA(
        win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_LAYERED | win32.WS_EX_NOACTIVATE | click_through_ex,
        WINDOW_CLASS_NAME,
        name_z.ptr,
        win32.WS_POPUP,
        pos.x,
        pos.y,
        size.width,
        size.height,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = win32.DestroyWindow(hwnd);

    _ = win32.SetLayeredWindowAttributes(hwnd, 0, opacity, win32.LWA_ALPHA);

    var thumbnail_id: win32.HTHUMBNAIL = undefined;
    if (win32.DwmRegisterThumbnail(hwnd, source_hwnd, &thumbnail_id) != 0) return error.DwmRegisterThumbnailFailed;
    errdefer _ = win32.DwmUnregisterThumbnail(thumbnail_id);

    var client_rect: win32.RECT = undefined;
    _ = win32.GetClientRect(hwnd, &client_rect);
    const props = thumbnailProps(.{ .width = client_rect.right, .height = client_rect.bottom }, win32.DWM_TNP_VISIBLE | win32.DWM_TNP_RECTDESTINATION | win32.DWM_TNP_SOURCECLIENTAREAONLY);
    if (win32.DwmUpdateThumbnailProperties(thumbnail_id, &props) != 0) return error.DwmUpdateThumbnailPropertiesFailed;

    const text_hwnd = win32.CreateWindowExA(
        win32.WS_EX_LAYERED | win32.WS_EX_TOPMOST | win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE | click_through_ex,
        TEXT_WINDOW_CLASS_NAME,
        name_z.ptr,
        win32.WS_POPUP,
        pos.x,
        pos.y,
        size.width,
        size.height,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateTextWindowFailed;

    // Clicks resolve the source client through SOURCE_HWND; each window's userdata points at the other for drags.
    _ = win32.SetPropA(hwnd, "SOURCE_HWND", source_hwnd);
    _ = win32.SetPropA(text_hwnd, "SOURCE_HWND", source_hwnd);
    _ = win32.SetWindowLongPtrA(hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(text_hwnd));
    _ = win32.SetWindowLongPtrA(text_hwnd, win32.GWLP_USERDATA, win32.hwndToUserData(hwnd));

    return .{ .hwnd = hwnd, .text_hwnd = text_hwnd, .thumbnail_id = thumbnail_id };
}

/// Shows the text overlay once its first render is in place, so it never flashes up empty.
pub fn showText(handles: Handles, pos: config_mod.Position, size: Size) void {
    _ = win32.SetWindowPos(handles.text_hwnd, win32.HWND_TOPMOST, pos.x, pos.y, size.width, size.height, win32.SWP_NOACTIVATE);
    _ = win32.ShowWindow(handles.text_hwnd, win32.SW_SHOW);
    _ = win32.UpdateWindow(handles.text_hwnd);
}

/// Destroys a Thumbnails-mode thumbnail's windows; its render cache's GDI objects go first, and the DWM thumbnail before the window it draws into.
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
        .rcDestination = win32.RECT{ .left = 0, .top = 0, .right = size.width, .bottom = size.height },
        .rcSource = win32.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .opacity = 255,
        .fVisible = win32.TRUE,
        .fSourceClientAreaOnly = win32.TRUE,
    };
}
