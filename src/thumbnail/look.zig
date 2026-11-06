//! What a thumbnail's overlay shows (RenderSettings, compared to skip redundant redraws), decided from the thumbnail and the profile; no drawing.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const color_mod = @import("../util/color.zig");
const stack = @import("../notifications/stack.zig");
const connections_mod = @import("../map/connections.zig");
const activity_stats = @import("activity_stats.zig");

const ActivityStats = activity_stats.ActivityStats;
const TextPosition = types.TextPosition;
const BorderStyle = types.BorderStyle;
const scalePixels = win32.scalePixels;

const OVERLAY_ALPHA = 255;
/// Custom text can split a notification over lines (see notifications/template.zig).
pub const MAX_LINES_PER_NOTIFICATION = 3;
pub const MAX_NOTIFICATION_LINES = stack.CAPACITY * MAX_LINES_PER_NOTIFICATION;

/// One resolved line of the notification block.
pub const NotificationLine = struct {
    text: []const u8 = "",
    color: u32 = 0xFFFFFF,
    /// Bytes of `text` drawn in lead_color; 0 for none.
    lead_length: usize = 0,
    lead_color: u32 = 0,
};

/// All an overlay depends on except the stat config, which every config edit's cache clear covers.
pub const RenderSettings = struct {
    /// Every overlay text; the per-element flags below are already false without it.
    show_text: bool = true,
    show_character_name: bool = true,
    /// Borrows from the thumbnail's cached_display_name.
    display_name: []const u8 = "",
    show_system_name: bool = false,
    /// Borrows from the thumbnail.
    system_name: []const u8 = "",
    /// Shown in place of system_name unless empty.
    connections: connections_mod.Connections = .{},
    character_name_color: u32 = 0xFFFFFF,
    system_name_color: u32 = 0xFFFFFF,
    /// For every connection but the character's own system, which keeps system_name_color.
    connection_color: u32 = 0xFFFFFF,
    connection_map_width: i32 = 0,
    connection_map_height: i32 = 0,
    character_name_bg_color: u32 = 0x80000000,
    system_name_bg_color: u32 = 0x80000000,
    /// Borrows from config.
    character_name_font_name: []const u8 = "Segoe UI",
    character_name_font_size: i32 = 14,
    character_name_font_weight: types.FontWeight = .Regular,
    character_name_position: TextPosition = .TopLeft,
    character_name_offset_x: i32 = 0,
    character_name_offset_y: i32 = 0,
    system_name_position: TextPosition = .BottomLeft,
    system_name_offset_x: i32 = 0,
    system_name_offset_y: i32 = 0,
    /// Borrows from config.
    system_name_font_name: []const u8 = "Segoe UI",
    system_name_font_size: i32 = 12,
    system_name_font_weight: types.FontWeight = .Regular,
    show_notifications: bool = false,
    /// Borrows the notification stack's text, freed as entries expire, so compare by notification_revision.
    notification_lines: [MAX_NOTIFICATION_LINES]NotificationLine = @splat(.{}),
    notification_line_count: usize = 0,
    notification_revision: u32 = 0,
    notifications_position: TextPosition = .Center,
    notifications_offset_x: i32 = 0,
    notifications_offset_y: i32 = 0,
    /// Borrows from config.
    notifications_font_name: []const u8 = "Segoe UI",
    notifications_font_size: i32 = 12,
    notifications_font_weight: types.FontWeight = .Regular,
    notifications_bg_color: u32 = 0x80000000,

    show_border: bool = true,
    border_width: u8 = 2,
    border_color: u32 = 0xFF606060,
    border_style: BorderStyle = .Solid,

    show_exclusion_overlay: bool = false,
    exclusion_overlay_style: types.ExclusionOverlayStyle = .X,
    exclusion_overlay_color: u32 = 0x33A62222,

    show_group_badge: bool = false,
    /// Borrows from the thumbnail.
    group_badge_text: []const u8 = "",
    group_badge_color: u32 = 0xFF44FF44,
    group_badge_position: TextPosition = .RightCenter,
    group_badge_offset_x: i32 = 0,
    group_badge_offset_y: i32 = 0,
    /// Borrows from config.
    group_badge_font_name: []const u8 = "Segoe UI",
    group_badge_font_size: i32 = 12,
    group_badge_font_weight: types.FontWeight = .Regular,
    group_badge_bg_color: u32 = 0x80000000,

    show_session_timer: bool = false,
    /// 0 while not shown.
    session_minutes: u64 = 0,
    session_timer_color: u32 = 0xFFFFFF,
    session_timer_position: TextPosition = .RightCenter,
    session_timer_offset_x: i32 = 0,
    session_timer_offset_y: i32 = -24,
    /// Borrows from config.
    session_timer_font_name: []const u8 = "Segoe UI",
    session_timer_font_size: i32 = 12,
    session_timer_font_weight: types.FontWeight = .Regular,
    session_timer_bg_color: u32 = 0x80000000,

    combat_incoming_bg_color: u32 = 0x80000000,
    combat_outgoing_bg_color: u32 = 0x80000000,
    mining_bg_color: u32 = 0x80000000,
    bounty_bg_color: u32 = 0x80000000,
    resources_bg_color: u32 = 0x80000000,
    ping_bg_color: u32 = 0x80000000,

    show_thumbnail: bool = true,
    overlay_alpha: u8 = OVERLAY_ALPHA,

    overlay_width: c_int,
    overlay_height: c_int,

    // -1 stands in for a rate still being calculated (null); no real rate is negative.
    dps_incoming: f32 = 0.0,
    dps_outgoing: f32 = 0.0,
    mining_rate: f32 = 0.0,
    mining_isk_rate: f32 = 0.0,
    bounty_isk_rate: f32 = 0.0,
    resource_cpu_percent: f32 = 0.0,
    resource_ram_mb: f32 = 0.0,
    resource_vram_mb: f32 = 0.0,
    ping_ms: ?u32 = null,
    // So a tracker's first report redraws even when the (sentinel) rate itself didn't change.
    has_dps_data: bool = false,
    has_mining_data: bool = false,
    has_bounty_data: bool = false,
    has_resource_data: bool = false,
    has_vram_data: bool = false,
    has_ping_data: bool = false,
};

/// What renderSettings reads off a thumbnail; overlay.zig gathers it, along with what only Win32 can tell.
pub const Subject = struct {
    state: config_mod.ThumbnailState,
    is_shown: bool,
    is_focused: bool,
    is_excluded_from_cycle: bool,
    /// The character's own hideThumbnail.
    is_hidden_for_character: bool,
    /// Borrows from the thumbnail.
    display_name: []const u8,
    /// Borrows from the thumbnail.
    system_name: []const u8,
    /// Borrows from the thumbnail.
    group_badge_label: []const u8,
    /// Borrows from the thumbnail.
    connections: *const connections_mod.Connections,
    /// Null when unique character colours are off or no character is logged in.
    character_color: ?u32,
    system_color: u32,
    border_colors: ?config_mod.CharacterBorderColorsConfig,
    opacity: u8,
    /// Null while no character is logged in.
    session_minutes: ?u64,
    /// Borrows from the thumbnail.
    stats: *const ActivityStats,
    /// Borrows from the thumbnail.
    notifications: *const stack.NotificationStack,
    /// Already at the window's DPI.
    overlay_width: c_int,
    /// Already at the window's DPI.
    overlay_height: c_int,
    dpi_scale: f32,
    now: win32.Ticks,
};

const Border = struct { is_shown: bool, width: u8, color: u32, style: BorderStyle };

/// The single point where a thumbnail's state and the profile decide everything its overlay shows.
pub fn renderSettings(config: *const config_mod.Config, subject: *const Subject) RenderSettings {
    const thumbnail_config = &config.thumbnail;
    const state_config = thumbnail_config.getStateConfig(subject.state);
    const is_shown = subject.is_shown;
    const is_active_hidden = subject.state == .active and thumbnail_config.activeThumbnailHidden;
    // A hidden thumbnail shows no border or text either.
    const hides_all = !is_shown or subject.is_hidden_for_character or is_active_hidden;
    const show_text = !hides_all and thumbnail_config.showText;
    const forces_opaque_backgrounds = thumbnail_config.applyOpacityToOverlayTexts;
    const border = resolveBorder(thumbnail_config, subject, state_config, hides_all);
    const dpi_scale = subject.dpi_scale;
    const stats = subject.stats;
    const session_minutes = if (show_text and thumbnail_config.showSessionTimer) subject.session_minutes else null;

    var settings: RenderSettings = .{
        .show_text = show_text,
        .show_character_name = show_text and thumbnail_config.showCharacterName,
        .display_name = subject.display_name,
        .show_system_name = show_text and thumbnail_config.showSystemName and subject.system_name.len > 0,
        .system_name = subject.system_name,
        .connections = subject.connections.*,
        .connection_color = thumbnail_config.systemNameColor,
        .connection_map_width = scalePixels(thumbnail_config.systemConnectionMapWidth, dpi_scale),
        .connection_map_height = scalePixels(thumbnail_config.systemConnectionMapHeight, dpi_scale),
        // Unique character colours win over the state's text colour.
        .character_name_color = subject.character_color orelse state_config.textColor orelse thumbnail_config.characterNameColor,
        .system_name_color = subject.system_color,
        .character_name_bg_color = resolveTextBgColor(state_config, thumbnail_config.characterNameBgColor, forces_opaque_backgrounds),
        .system_name_bg_color = resolveTextBgColor(state_config, thumbnail_config.systemNameBgColor, forces_opaque_backgrounds),
        .group_badge_bg_color = resolveTextBgColor(state_config, thumbnail_config.quickGroupBadgeBgColor, forces_opaque_backgrounds),
        .notifications_bg_color = resolveTextBgColor(state_config, thumbnail_config.notifications.bg_color, forces_opaque_backgrounds),
        .combat_incoming_bg_color = resolveTextBgColor(state_config, config.combat.incoming_bg_color, forces_opaque_backgrounds),
        .combat_outgoing_bg_color = resolveTextBgColor(state_config, config.combat.outgoing_bg_color, forces_opaque_backgrounds),
        .mining_bg_color = resolveTextBgColor(state_config, config.mining.bg_color, forces_opaque_backgrounds),
        .bounty_bg_color = resolveTextBgColor(state_config, config.bounty.bg_color, forces_opaque_backgrounds),
        .resources_bg_color = resolveTextBgColor(state_config, config.resources.bg_color, forces_opaque_backgrounds),
        .ping_bg_color = resolveTextBgColor(state_config, config.ping.bg_color, forces_opaque_backgrounds),
        .character_name_font_name = thumbnail_config.characterNameFontName,
        .character_name_font_size = scalePixels(thumbnail_config.characterNameFontSize, dpi_scale),
        .character_name_font_weight = thumbnail_config.characterNameFontWeight,
        .character_name_position = thumbnail_config.characterNamePosition,
        .character_name_offset_x = thumbnail_config.characterNameOffsetX,
        .character_name_offset_y = thumbnail_config.characterNameOffsetY,
        .system_name_position = thumbnail_config.systemNamePosition,
        .system_name_offset_x = thumbnail_config.systemNameOffsetX,
        .system_name_offset_y = thumbnail_config.systemNameOffsetY,
        .system_name_font_name = thumbnail_config.systemNameFontName,
        .system_name_font_size = scalePixels(thumbnail_config.systemNameFontSize, dpi_scale),
        .system_name_font_weight = thumbnail_config.systemNameFontWeight,
        .show_notifications = show_text and thumbnail_config.notifications.enabled,
        .notifications_position = thumbnail_config.notifications.position,
        .notifications_offset_x = thumbnail_config.notifications.offset_x,
        .notifications_offset_y = thumbnail_config.notifications.offset_y,
        .notifications_font_name = thumbnail_config.notifications.font_name,
        .notifications_font_size = scalePixels(thumbnail_config.notifications.font_size, dpi_scale),
        .notifications_font_weight = thumbnail_config.notifications.font_weight,
        .show_border = border.is_shown,
        .border_width = border.width,
        .border_color = border.color,
        .border_style = border.style,
        .show_exclusion_overlay = subject.is_excluded_from_cycle and is_shown,
        .exclusion_overlay_style = thumbnail_config.exclusionOverlayStyle,
        .exclusion_overlay_color = thumbnail_config.exclusionOverlayColor,
        .show_group_badge = show_text and thumbnail_config.showQuickGroupBadge and subject.group_badge_label.len > 0,
        .group_badge_text = subject.group_badge_label,
        .group_badge_color = thumbnail_config.quickGroupBadgeColor,
        .group_badge_position = thumbnail_config.quickGroupBadgePosition,
        .group_badge_offset_x = thumbnail_config.quickGroupBadgeOffsetX,
        .group_badge_offset_y = thumbnail_config.quickGroupBadgeOffsetY,
        .group_badge_font_name = thumbnail_config.quickGroupBadgeFontName,
        .group_badge_font_size = scalePixels(thumbnail_config.quickGroupBadgeFontSize, dpi_scale),
        .group_badge_font_weight = thumbnail_config.quickGroupBadgeFontWeight,
        .show_session_timer = session_minutes != null,
        .session_minutes = session_minutes orelse 0,
        .session_timer_color = thumbnail_config.sessionTimerColor,
        .session_timer_position = thumbnail_config.sessionTimerPosition,
        .session_timer_offset_x = thumbnail_config.sessionTimerOffsetX,
        .session_timer_offset_y = thumbnail_config.sessionTimerOffsetY,
        .session_timer_font_name = thumbnail_config.sessionTimerFontName,
        .session_timer_font_size = scalePixels(thumbnail_config.sessionTimerFontSize, dpi_scale),
        .session_timer_font_weight = thumbnail_config.sessionTimerFontWeight,
        .session_timer_bg_color = resolveTextBgColor(state_config, thumbnail_config.sessionTimerBgColor, forces_opaque_backgrounds),
        // Visibility and the character's own hideThumbnail win over the state's showThumbnail.
        .show_thumbnail = if (!is_shown or subject.is_hidden_for_character) false else state_config.showThumbnail orelse !is_active_hidden,
        .overlay_alpha = if (forces_opaque_backgrounds) subject.opacity else OVERLAY_ALPHA,
        .overlay_width = subject.overlay_width,
        .overlay_height = subject.overlay_height,
        .dps_incoming = if (config.combat.enabled) (stats.incoming_dps orelse -1.0) else 0.0,
        .dps_outgoing = if (config.combat.enabled) (stats.outgoing_dps orelse -1.0) else 0.0,
        .mining_rate = if (config.mining.enabled) (stats.mining_rate orelse -1.0) else 0.0,
        .mining_isk_rate = if (config.mining.enabled and config.mining.show_isk_rate) (stats.mining_isk_rate orelse -1.0) else 0.0,
        .bounty_isk_rate = if (config.bounty.enabled) (stats.bounty_isk_rate orelse -1.0) else 0.0,
        .resource_cpu_percent = if (config.resources.enabled) stats.cpu_percent else 0.0,
        .resource_ram_mb = if (config.resources.enabled) stats.ram_mb else 0.0,
        .resource_vram_mb = if (config.resources.enabled) stats.vram_mb else 0.0,
        .ping_ms = if (config.ping.enabled) stats.ping_ms else null,
        .has_dps_data = stats.has_dps,
        .has_mining_data = stats.has_mining,
        .has_bounty_data = stats.has_bounty,
        .has_resource_data = config.resources.enabled and stats.has_resources,
        .has_vram_data = stats.has_vram,
        .has_ping_data = config.ping.enabled and stats.has_ping,
    };
    if (settings.show_notifications) {
        settings.notification_line_count = notificationLines(&settings.notification_lines, subject.notifications, subject.is_focused, thumbnail_config.notifications.color);
        settings.notification_revision = subject.notifications.revision;
    }
    return settings;
}

pub fn renderSettingsEqual(first: RenderSettings, second: RenderSettings) bool {
    return first.show_thumbnail == second.show_thumbnail and visualEqual(first, second);
}

pub fn renderSettingsOnlyVisibilityChanged(first: RenderSettings, second: RenderSettings) bool {
    return first.show_thumbnail != second.show_thumbnail and visualEqual(first, second);
}

/// Unchanged config and notification slices keep their pointer and length, so those are checked first.
pub fn stringsEqualFast(first: []const u8, second: []const u8) bool {
    return (first.ptr == second.ptr and first.len == second.len) or std.mem.eql(u8, first, second);
}

/// All fields but show_thumbnail, walked at comptime so new fields are always compared.
fn visualEqual(first: RenderSettings, second: RenderSettings) bool {
    const info = @typeInfo(RenderSettings).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        if (comptime std.mem.eql(u8, name, "show_thumbnail")) continue;
        if (!valuesEqual(F, @field(first, name), @field(second, name))) return false;
    }
    return true;
}

fn valuesEqual(comptime T: type, first: T, second: T) bool {
    if (T == []const u8) return stringsEqualFast(first, second);
    // The cached line's text may have been freed; notification_revision catches a change its address and length miss.
    if (T == NotificationLine) return first.text.ptr == second.text.ptr and first.text.len == second.text.len and first.color == second.color and first.lead_length == second.lead_length and first.lead_color == second.lead_color;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, F| {
                if (!valuesEqual(F, @field(first, name), @field(second, name))) return false;
            }
            return true;
        },
        .array => |info| {
            for (first, second) |x, y| {
                if (!valuesEqual(info.child, x, y)) return false;
            }
            return true;
        },
        else => return first == second,
    }
}

/// Forced opaque when the window's Opacity applies, so the two alphas don't compound.
fn resolveTextBgColor(state_config: config_mod.StateVisualConfig, base_color: u32, is_forced_opaque: bool) u32 {
    const resolved = state_config.textBgColor orelse base_color;
    return if (is_forced_opaque) color_mod.withAlpha(resolved, 255) else resolved;
}

/// Lowest first: Active/Inactive base, state override, newest alert's type, then the character's colours.
fn resolveBorder(thumbnail_config: *const config_mod.ThumbnailConfig, subject: *const Subject, state_config: config_mod.StateVisualConfig, hides_all: bool) Border {
    const state = subject.state;
    const is_focused = subject.is_focused;
    // Alert builds on Active, being an attention event.
    const uses_focused_look = state == .active or state == .alert;
    // Only the newest notification drives border effects; older entries only add text lines.
    const newest = if (state == .alert) subject.notifications.newest() else null;

    // Not for the focused character, so it can't fight its active border.
    const notification_hides = if (newest) |notification| !is_focused and (!notification.show_border or notification.isFlashOff(subject.now)) else false;
    const is_shown = !hides_all and !notification_hides and (state_config.showBorder orelse (if (uses_focused_look) thumbnail_config.showBorderWhenFocused else thumbnail_config.showBorderWhenInactive));

    // With suppress_when_focused, a focused character's alert borders as Active.
    const is_suppressed = if (newest) |notification| notification.suppress_when_focused and is_focused else false;
    var color = state_config.borderColor orelse (if (uses_focused_look) thumbnail_config.borderColor else thumbnail_config.inactiveBorderColor);
    if (newest) |notification| {
        if (!is_suppressed) {
            if (notification.border_color_override) |override| color = override;
        }
    }
    if (subject.border_colors) |character_colors| {
        const override = switch (state) {
            .active => character_colors.activeBorderColor,
            .alert => if (is_suppressed) character_colors.activeBorderColor else null,
            .inactive, .minimized => character_colors.inactiveBorderColor,
            .dragging => null,
        };
        if (override) |c| color = c;
    }

    return .{
        .is_shown = is_shown,
        .width = state_config.borderWidth orelse (if (uses_focused_look) thumbnail_config.borderWidth else thumbnail_config.inactiveBorderWidth),
        .color = color,
        .style = state_config.borderStyle orelse (if (uses_focused_look) thumbnail_config.borderStyle else thumbnail_config.inactiveBorderStyle),
    };
}

/// Newest first; each entry filters and colours itself.
fn notificationLines(out: *[MAX_NOTIFICATION_LINES]NotificationLine, notifications: *const stack.NotificationStack, is_focused: bool, base_color: u32) usize {
    var count: usize = 0;
    for (notifications.items()) |entry| {
        if (!entry.shows_text or (entry.suppress_when_focused and is_focused)) continue;
        const color = entry.text_color_override orelse base_color;
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        var line_index: usize = 0;
        while (lines.next()) |line| : (line_index += 1) {
            if (line_index == MAX_LINES_PER_NOTIFICATION) break;
            out[count] = .{ .text = line, .color = color };
            if (entry.lead) |lead| {
                if (line_index == 0 and lead.length <= line.len) {
                    out[count].lead_length = lead.length;
                    out[count].lead_color = lead.color;
                }
            }
            count += 1;
        }
    }
    return count;
}

const testing = std.testing;
const NO_STATS: ActivityStats = .{};
const NO_CONNECTIONS: connections_mod.Connections = .{};
const NO_NOTIFICATIONS: stack.NotificationStack = .{};
const TEST_START: win32.Ticks = .{ .ms = 1000 };

fn testConfig() !config_mod.Config {
    return config_mod.Config.getDefaultsWithProfile(testing.allocator, "Test");
}

// Shown, at 96 DPI, focused only when Active, with nothing to report.
fn testSubject(state: config_mod.ThumbnailState) Subject {
    return .{
        .state = state,
        .is_shown = true,
        .is_focused = state == .active,
        .is_excluded_from_cycle = false,
        .is_hidden_for_character = false,
        .display_name = "Pilot",
        .system_name = "",
        .group_badge_label = "",
        .connections = &NO_CONNECTIONS,
        .character_color = null,
        .system_color = 0xFFFFFF,
        .border_colors = null,
        .opacity = 255,
        .session_minutes = null,
        .stats = &NO_STATS,
        .notifications = &NO_NOTIFICATIONS,
        .overlay_width = 282,
        .overlay_height = 158,
        .dpi_scale = 1.0,
        .now = TEST_START,
    };
}

fn testEntry(text: []const u8) stack.ActiveNotification {
    return .{ .text = text, .notification_type = .FleetInvite, .start_time = TEST_START, .duration_ms = 5000, .suppress_when_focused = false, .suppress_when_clicked = false };
}

// Borrows `entry.text`, so the stack is never deinited.
fn testStack(entry: stack.ActiveNotification) stack.NotificationStack {
    var notifications: stack.NotificationStack = .{};
    notifications.entries[0] = entry;
    notifications.entry_count = 1;
    return notifications;
}

test "an unfocused thumbnail hides its border by default" {
    var config = try testConfig();
    defer config.deinit();
    const subject = testSubject(.inactive);
    const settings = renderSettings(&config, &subject);
    try testing.expect(!settings.show_border);
    try testing.expectEqual(config.thumbnail.inactiveBorderColor, settings.border_color);
}

test "the focused thumbnail shows the focused border" {
    var config = try testConfig();
    defer config.deinit();
    const subject = testSubject(.active);
    const settings = renderSettings(&config, &subject);
    try testing.expect(settings.show_border);
    try testing.expectEqual(config.thumbnail.borderColor, settings.border_color);
    try testing.expectEqual(config.thumbnail.borderWidth, settings.border_width);
}

test "a state's own border colour wins over the base colour" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.active.borderColor = 0xFF112233;
    const subject = testSubject(.active);
    try testing.expectEqual(@as(u32, 0xFF112233), renderSettings(&config, &subject).border_color);
}

test "an unfocused character's alert takes its type's border colour" {
    var config = try testConfig();
    defer config.deinit();
    var entry = testEntry("Fleet invite");
    entry.border_color_override = 0xFFFF0000;
    const notifications = testStack(entry);
    var subject = testSubject(.alert);
    subject.notifications = &notifications;
    const settings = renderSettings(&config, &subject);
    try testing.expect(settings.show_border);
    try testing.expectEqual(@as(u32, 0xFFFF0000), settings.border_color);
}

test "a focused character's suppressed alert keeps its active border colour" {
    var config = try testConfig();
    defer config.deinit();
    var entry = testEntry("Fleet invite");
    entry.border_color_override = 0xFFFF0000;
    entry.suppress_when_focused = true;
    const notifications = testStack(entry);
    var subject = testSubject(.alert);
    subject.is_focused = true;
    subject.notifications = &notifications;
    try testing.expectEqual(config.thumbnail.borderColor, renderSettings(&config, &subject).border_color);
    subject.border_colors = .{ .activeBorderColor = 0xFF00FF00 };
    try testing.expectEqual(@as(u32, 0xFF00FF00), renderSettings(&config, &subject).border_color);
}

test "the character's inactive border colour applies to a minimized thumbnail" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.showBorderWhenInactive = true;
    var subject = testSubject(.minimized);
    subject.border_colors = .{ .inactiveBorderColor = 0xFF0000FF };
    const settings = renderSettings(&config, &subject);
    try testing.expect(settings.show_border);
    try testing.expectEqual(@as(u32, 0xFF0000FF), settings.border_color);
}

test "a flashing alert hides the border in its off phase, except on the focused character" {
    var config = try testConfig();
    defer config.deinit();
    var entry = testEntry("Fleet invite");
    entry.flash_border = true;
    const notifications = testStack(entry);
    var subject = testSubject(.alert);
    subject.notifications = &notifications;
    subject.now = .{ .ms = TEST_START.ms + 150 };
    try testing.expect(entry.isFlashOff(subject.now));
    try testing.expect(!renderSettings(&config, &subject).show_border);
    subject.is_focused = true;
    try testing.expect(renderSettings(&config, &subject).show_border);
}

test "a hidden thumbnail shows no border, text, picture or exclusion mark" {
    var config = try testConfig();
    defer config.deinit();
    var subject = testSubject(.active);
    subject.is_shown = false;
    subject.is_excluded_from_cycle = true;
    const settings = renderSettings(&config, &subject);
    try testing.expect(!settings.show_border);
    try testing.expect(!settings.show_text);
    try testing.expect(!settings.show_character_name);
    try testing.expect(!settings.show_thumbnail);
    try testing.expect(!settings.show_exclusion_overlay);
}

test "a character's own hideThumbnail hides its picture and text" {
    var config = try testConfig();
    defer config.deinit();
    var subject = testSubject(.inactive);
    subject.is_hidden_for_character = true;
    const settings = renderSettings(&config, &subject);
    try testing.expect(!settings.show_thumbnail);
    try testing.expect(!settings.show_text);
}

test "activeThumbnailHidden hides the focused picture unless the Active state overrides it" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.activeThumbnailHidden = true;
    const subject = testSubject(.active);
    try testing.expect(!renderSettings(&config, &subject).show_thumbnail);
    config.thumbnail.active.showThumbnail = true;
    try testing.expect(renderSettings(&config, &subject).show_thumbnail);
}

test "opacity on texts makes their backgrounds opaque and moves the alpha to the window" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.characterNameBgColor = 0xE6000000;
    var subject = testSubject(.inactive);
    subject.opacity = 128;
    config.thumbnail.applyOpacityToOverlayTexts = true;
    const applied = renderSettings(&config, &subject);
    try testing.expectEqual(@as(u32, 0xFF000000), applied.character_name_bg_color);
    try testing.expectEqual(@as(u8, 128), applied.overlay_alpha);
    config.thumbnail.applyOpacityToOverlayTexts = false;
    const unapplied = renderSettings(&config, &subject);
    try testing.expectEqual(@as(u32, 0xE6000000), unapplied.character_name_bg_color);
    try testing.expectEqual(@as(u8, 255), unapplied.overlay_alpha);
}

test "the system name shows only once one is known" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.showSystemName = true;
    var subject = testSubject(.inactive);
    try testing.expect(!renderSettings(&config, &subject).show_system_name);
    subject.system_name = "Jita";
    try testing.expect(renderSettings(&config, &subject).show_system_name);
}

test "the session timer shows only for a logged-in character with the timer on" {
    var config = try testConfig();
    defer config.deinit();
    var subject = testSubject(.inactive);
    subject.session_minutes = 42;
    config.thumbnail.showSessionTimer = false;
    try testing.expect(!renderSettings(&config, &subject).show_session_timer);
    config.thumbnail.showSessionTimer = true;
    const shown = renderSettings(&config, &subject);
    try testing.expect(shown.show_session_timer);
    try testing.expectEqual(@as(u64, 42), shown.session_minutes);
    subject.session_minutes = null;
    try testing.expect(!renderSettings(&config, &subject).show_session_timer);
}

test "a rate still being calculated is sent as -1, and one from a disabled tracker as 0" {
    var config = try testConfig();
    defer config.deinit();
    const stats: ActivityStats = .{ .has_dps = true };
    var subject = testSubject(.inactive);
    subject.stats = &stats;
    config.combat.enabled = false;
    try testing.expectEqual(@as(f32, 0.0), renderSettings(&config, &subject).dps_incoming);
    config.combat.enabled = true;
    try testing.expectEqual(@as(f32, -1.0), renderSettings(&config, &subject).dps_incoming);
}

test "font sizes and the connection map scale with the window's DPI" {
    var config = try testConfig();
    defer config.deinit();
    config.thumbnail.characterNameFontSize = 12;
    config.thumbnail.systemConnectionMapWidth = 180;
    var subject = testSubject(.inactive);
    subject.dpi_scale = 1.5;
    const settings = renderSettings(&config, &subject);
    try testing.expectEqual(@as(i32, 18), settings.character_name_font_size);
    try testing.expectEqual(@as(i32, 270), settings.connection_map_width);
}

test "a notification's text splits into at most three lines, with the lead coloured on the first" {
    var config = try testConfig();
    defer config.deinit();
    var entry = testEntry("one\ntwo\nthree\nfour");
    entry.text_color_override = 0x00FF00;
    entry.lead = .{ .length = 3, .color = 0xFFFF00 };
    const notifications = testStack(entry);
    var subject = testSubject(.alert);
    subject.notifications = &notifications;
    const settings = renderSettings(&config, &subject);
    try testing.expectEqual(@as(usize, 3), settings.notification_line_count);
    const lines = settings.notification_lines[0..3];
    try testing.expectEqualStrings("one", lines[0].text);
    try testing.expectEqual(@as(usize, 3), lines[0].lead_length);
    try testing.expectEqual(@as(u32, 0xFFFF00), lines[0].lead_color);
    try testing.expectEqual(@as(usize, 0), lines[1].lead_length);
    try testing.expectEqualStrings("three", lines[2].text);
    for (lines) |line| try testing.expectEqual(@as(u32, 0x00FF00), line.color);
    try testing.expectEqual(notifications.revision, settings.notification_revision);
}

test "a focused character's suppressed notification adds no lines" {
    var config = try testConfig();
    defer config.deinit();
    var entry = testEntry("Fleet invite");
    entry.suppress_when_focused = true;
    const notifications = testStack(entry);
    var subject = testSubject(.alert);
    subject.is_focused = true;
    subject.notifications = &notifications;
    try testing.expectEqual(@as(usize, 0), renderSettings(&config, &subject).notification_line_count);
}

test "equal names in different buffers don't force a redraw" {
    var config = try testConfig();
    defer config.deinit();
    var buffer = "Pilot".*;
    const first_subject = testSubject(.inactive);
    var second_subject = testSubject(.inactive);
    second_subject.display_name = &buffer;
    try testing.expect(renderSettingsEqual(renderSettings(&config, &first_subject), renderSettings(&config, &second_subject)));
}

test "a change to show_thumbnail alone is a visibility change, not a redraw" {
    var config = try testConfig();
    defer config.deinit();
    const subject = testSubject(.inactive);
    const first = renderSettings(&config, &subject);
    var second = first;
    second.show_thumbnail = !first.show_thumbnail;
    try testing.expect(!renderSettingsEqual(first, second));
    try testing.expect(renderSettingsOnlyVisibilityChanged(first, second));
    second.border_color +%= 1;
    try testing.expect(!renderSettingsOnlyVisibilityChanged(first, second));
}
