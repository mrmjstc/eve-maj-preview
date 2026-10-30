//! The configuration window's Event Alerts tab: a list of notification types beside the selected type's settings; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const template = @import("../../../notifications/template.zig");
const overlay = @import("../../../thumbnail/overlay.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const pickers = @import("../pickers.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const glyphs = @import("../glyphs.zig");
const lang = @import("../../../lang/lang.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const Tooltip = ui.component.Tooltip;
const NotificationType = notification.NotificationType;
const TypeRef = session.Ref(config.NotificationTypeConfig);
const slog = log.Scoped("dialog_knots");

const CUSTOM_TEXT_MAX_LENGTH = 100;
/// Holds notification.defaultText, which the box and its preview both show.
const DEFAULT_TEXT_SIZE = 128;
/// knots' Tooltip keys its popup and text as its own key indexed 1 and 2, so what it wraps takes this.
const TOOLTIP_CHILD_INDEX = 3;
/// A chip's left and right borders together.
const CHIP_BORDERS = 2;

/// Every type, by category, then as declared; chat rules have settings of their own instead, on the Chat Alerts tab.
const TYPES_IN_ORDER = blk: {
    var ordered: [std.enums.values(NotificationType).len]NotificationType = undefined;
    var count: usize = 0;
    for (std.enums.values(notification.NotificationCategory)) |category| {
        if (category == .Chat) continue;
        for (std.enums.values(NotificationType)) |notification_type| {
            if (notification.notificationCategory(notification_type) != category) continue;
            ordered[count] = notification_type;
            count += 1;
        }
    }
    const listed = ordered[0..count].*;
    break :blk listed;
};

const TextField = enum { custom_text, custom_text_alt };

var g_selected: NotificationType = TYPES_IN_ORDER[0];
/// Where a placeholder chip inserts, per type; the first box until another is focused.
var g_last_text_field: std.EnumArray(NotificationType, TextField) = .initFill(.custom_text);

/// A notification type's own settings, by its index in NotificationType.
pub fn typeRef(index: usize) TypeRef {
    const configs = &session.profile().ptr.thumbnail.notifications.type_configs;
    return .{ .doc = .profile, .ptr = &configs.map.values[index], .layout = .none, .index = index };
}

pub fn show(context: *ui.Frame) !void {
    const is_enabled = session.profile().ptr.thumbnail.notifications.enabled;
    if (!is_enabled) {
        try widgets.noticeWithButton(context, .src(@src()), "Event Alerts requires Notification System switched on in the Notifications tab.", "Go to Notifications", .notifications);
    } else if (!session.profile().ptr.chatlog.enabled) {
        try widgets.noticeWithButton(context, .src(@src()), "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.", "Go to Log Monitoring", .log_monitoring);
    }
    const section = try widgets.openSection(context, "Event Alerts", "How each game event alerts you. Pick an event on the left to edit it.", &style.fill_section);
    const options = try widgets.openFillGroup(context, .src(@src()), is_enabled);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
    _ = try master_detail.open(context);
    try typeRoster(context);
    try typeDetail(context, g_selected);
    try master_detail.close(context);
    try options.close(context);
    try section.close(context);
}

/// Not in a frame that also draws another's, as the search's index would: their keys would clash.
pub fn alertSettings(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType, sound_target: pickers.Target, sound_index: usize) !void {
    try customText(context, ref, notification_type);
    try widgets.separator(context, .str("knots.events.separator.text"));

    const behavior = try widgets.openFieldGroup(context, .str("knots.events.behavior"), "Behavior");
    try bind.toggle(context, ref, "suppress_when_focused", "Suppress While Focused");
    try widgets.hintText(context, .src(@src()), "Skips the alert while you're on that character.");
    try bind.toggle(context, ref, "suppress_when_clicked", "Suppress After Click");
    try widgets.hintText(context, .src(@src()), "Skips the alert briefly after you click that character.");
    try bind.toggle(context, ref, "show_hidden_thumbnail", "Show Thumbnail Even If Hidden");
    try widgets.hintText(context, .src(@src()), "Only for as long as the alert lasts.");
    try bind.toggle(context, ref, "tts_enabled", "Speak Aloud (TTS)");
    try widgets.hintText(context, .src(@src()), "Reads the alert out loud. Voice settings are on the Notifications tab.");
    try behavior.close(context);
    try widgets.separator(context, .str("knots.events.separator.behavior"));

    const border = try widgets.openFieldGroup(context, .str("knots.events.border"), "Border");
    try bind.toggle(context, ref, "show_border", "Show Border");
    try widgets.hintText(context, .src(@src()), "Marks the thumbnail with a colored border during the alert.");
    // A hidden border has no colour to set and nothing to flash.
    const border_options = try widgets.openGroup(context, .src(@src()), ref.get("show_border"));
    try bind.toggle(context, ref, "flash_border", "Flash Border");
    try widgets.hintText(context, .src(@src()), "Makes the border blink.");
    const defaults = config.ThumbnailConfig{};
    try bind.optionalColor(context, ref, "border_color", "Border Color", defaults.inactiveBorderColor);
    try widgets.hintText(context, .src(@src()), "Reset uses the default color.");
    try border_options.close(context);
    try border.close(context);
    try widgets.separator(context, .str("knots.events.separator.border"));

    try sound(context, ref, sound_target, sound_index);
}

/// Fires an alert on every thumbnail with the settings the window has for it, saved or not.
pub fn testAlert(notification_type: NotificationType, alert: config.NotificationTypeConfig) void {
    const thumbnail_set = session.runningApp().thumbnail_set orelse {
        slog.warn("Failed to test notification: the thumbnail set isn't ready", .{});
        return;
    };
    thumbnail_set.showTestNotification(notification_type, alert) catch |err| {
        slog.err("Failed to test notification: {}", .{err});
        status.show(.failure, "Failed to test notification: {err}", .{ .err = err });
    };
}

/// The short name keeps the roster narrow; the detail header uses the full one.
fn typeShortLabel(notification_type: NotificationType) []const u8 {
    return lang.text(englishShortLabel(notification_type));
}

/// Returns whether it was clicked.
fn typeRow(context: *ui.Frame, notification_type: NotificationType, is_selected: bool) !bool {
    const index = @backingInt(notification_type);
    const row = Button{ .key = ui.Key.str("knots.events.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
    const is_clicked = (try widgets.openRosterRow(context, row)).clicked;
    const ref = typeRef(index);
    try context.e(Rect{ .key = ui.Key.str("knots.events.dot").indexed(index), .style = if (ref.get("enabled")) &style.event_dot_on else &style.event_dot_off });
    try context.e(Text{
        .selectable = false,
        .key = ui.Key.str("knots.events.name").indexed(index),
        .content = typeShortLabel(notification_type),
        .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
    });
    if (ref.get("tts_enabled")) try marker(context, ui.Key.str("knots.events.tts").indexed(index), .speech, "Speaks aloud");
    if (ref.get("sound_enabled")) try marker(context, ui.Key.str("knots.events.sound").indexed(index), .speaker, "Plays a custom sound");
    try row.close(context);
    return is_clicked;
}

fn typeDetail(context: *ui.Frame, notification_type: NotificationType) !void {
    const ref = typeRef(@backingInt(notification_type));
    const stack = try widgets.openScrollPane(context, .str("knots.events.detail"), style.detail_scroll);
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = typeLabel(notification_type), .style = &style.roster_name_selected });
    var is_enabled: bool = ref.get("enabled");
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("\u{25B6} Test"), .disabled = !is_enabled, .style = &style.plain_button })).clicked) {
        testAlert(notification_type, ref.ptr.*);
    }
    try header.close(context);
    if (try widgets.switchRow(context, ui.Key.str("knots.events.enabled").indexed(ref.index), "Enabled", &is_enabled)) ref.set("enabled", is_enabled);
    try widgets.hintText(context, .src(@src()), "When off, this event never alerts.");
    try widgets.separator(context, .str("knots.events.separator.enabled"));

    const rest = try widgets.openGroup(context, .src(@src()), is_enabled);
    const timing = try widgets.openFieldGroup(context, .str("knots.events.timing"), "Timing");
    try bind.number(context, ref, "duration_ms", "Duration", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long the alert shows; 0 keeps it until dismissed.");
    try bind.number(context, ref, "throttle_ms", "Cooldown", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Ignores repeats within this time.");
    try timing.close(context);
    try widgets.separator(context, .str("knots.events.separator.timing"));

    try alertSettings(context, ref, notification_type, .sound_file, ref.index);
    try rest.close(context);
    try stack.close(context);
}

fn typeLabel(notification_type: NotificationType) []const u8 {
    return lang.text(englishLabel(notification_type));
}

/// In English, capitalised like the sidebar's headings; boxedText translates it.
fn categoryHeading(category: notification.NotificationCategory) []const u8 {
    return switch (category) {
        .Fleet => "FLEET",
        .Mining => "MINING",
        .Combat => "COMBAT",
        .Navigation => "NAVIGATION",
        .Chat => "CHAT",
        .General => "GENERAL",
    };
}

fn englishLabel(notification_type: NotificationType) []const u8 {
    return switch (notification_type) {
        .AggressionCantJump => "Aggression Can't Jump",
        .AsteroidDepleted => "Asteroid Depleted",
        .AutoMinimizeToggle => "Auto-Minimize Toggle",
        .AutopilotApproaching => "Autopilot Approaching",
        .AutopilotReached => "Autopilot Reached",
        .BombLauncherEmpty => "Bomb Launcher Empty",
        .CargoFull => "Cargo Full",
        .ChatIntel => "Chat Intel",
        .ChatKeyword => "Chat Keyword",
        .CloakFailed => "Cloak Failed",
        .ConduitJump => "Conduit Jump",
        .ConversationInvite => "Conversation Invite",
        .CrystalBroke => "Crystal Broke",
        .CycleExclusion => "Cycle Exclusion",
        .Decloak => "Decloak",
        .Docking => "Docking",
        .FleetDisband => "Fleet Disband",
        .FleetFollow => "Fleet Follow into Warp",
        .FleetInvite => "Fleet Invite",
        .FleetRegroup => "Fleet Regrouped",
        .Generic => "Generic",
        .GroupMembership => "Group Membership",
        .HotkeySuspend => "Hotkeys Suspended/Resumed",
        .JumpCloning => "Jump Cloning",
        .JumpRange => "Jump Range",
        .MiningCompression => "Mining Compression",
        .MiningIdle => "Mining Idle",
        .MiningStopped => "Mining Stopped",
        .ObservatoryDecloak => "Observatory Decloak",
        .ProfileSwitch => "Profile Switch",
        .SavedPositionMove => "Moved to Saved Position",
        .SelfDestruct => "Self-Destruct",
        .SystemChange => "System Change",
        .TakingDamage => "Taking Damage",
        .TravelLeftBehind => "Left Behind",
        .WarpBubble => "Warp Disrupted Bubble",
        .WarpDisrupted => "Warp Disrupted",
        .WarpScrambled => "Warp Scrambled",
    };
}

fn englishShortLabel(notification_type: NotificationType) []const u8 {
    return switch (notification_type) {
        .AggressionCantJump => "Aggression Timer",
        .AsteroidDepleted => "Asteroid Empty",
        .AutoMinimizeToggle => "Auto-Minimize",
        .AutopilotApproaching => "AP Approaching",
        .AutopilotReached => "Waypoint Reached",
        .BombLauncherEmpty => "Out of Bombs",
        .CargoFull => "Cargo Full",
        .ChatIntel => "Chat Intel",
        .ChatKeyword => "Chat Keyword",
        .CloakFailed => "Cloak Failed",
        .ConduitJump => "Conduit Jump",
        .ConversationInvite => "Convo Invite",
        .CrystalBroke => "Crystal Broke",
        .CycleExclusion => "Cycle Exclusion",
        .Decloak => "Decloak",
        .Docking => "Docking",
        .FleetDisband => "Fleet Disband",
        .FleetFollow => "Fleet Follow",
        .FleetInvite => "Fleet Invite",
        .FleetRegroup => "Fleet Regrouped",
        .Generic => "Generic",
        .GroupMembership => "Group Membership",
        .HotkeySuspend => "Hotkey Suspend",
        .JumpCloning => "Jump Cloning",
        .JumpRange => "Jump Range",
        .MiningCompression => "Compression",
        .MiningIdle => "Mining Idle",
        .MiningStopped => "Mining Stopped",
        .ObservatoryDecloak => "Obs Decloak",
        .ProfileSwitch => "Profile Switch",
        .SavedPositionMove => "Saved Position",
        .SelfDestruct => "Self-Destruct",
        .SystemChange => "System Change",
        .TakingDamage => "Taking Damage",
        .TravelLeftBehind => "Left Behind",
        .WarpBubble => "Warp Bubble",
        .WarpDisrupted => "Warp Disrupted",
        .WarpScrambled => "Warp Scrambled",
    };
}

fn englishStateLabel(state: notification.State) []const u8 {
    return switch (state) {
        .started => "Started",
        .aborted => "Aborted",
        .suspended => "Suspended",
        .resumed => "Resumed",
        .on => "On",
        .off => "Off",
        .added => "Added",
        .removed => "Removed",
        .excluded => "Excluded",
        .included => "Included",
    };
}

/// Grouped under category headings; each row's dot is filled while its event is enabled.
fn typeRoster(context: *ui.Frame) !void {
    const roster = Rect{ .key = .src(@src()), .style = try rosterStyle(context) };
    _ = try roster.open(context);
    const rows = try widgets.openScrollPane(context, .str("knots.events.rows"), style.roster_scroll);
    var last_category: ?notification.NotificationCategory = null;
    for (TYPES_IN_ORDER) |notification_type| {
        const category = notification.notificationCategory(notification_type);
        if (last_category != category) {
            last_category = category;
            try widgets.boxedText(context, ui.Key.str("knots.events.category").indexed(@backingInt(category)), categoryHeading(category), &style.roster_category, &style.tab_category_text);
        }
        const is_selected = notification_type == g_selected;
        if (try typeRow(context, notification_type, is_selected) and !is_selected) {
            g_selected = notification_type;
            context.requestRedraw();
        }
    }
    try rows.close(context);
    try roster.close(context);
}

/// Widened so names' longest words don't break beside a dot and marker.
fn rosterStyle(context: *ui.Frame) !*const ui.Style {
    var widest: f32 = 0;
    for (TYPES_IN_ORDER) |notification_type| {
        var words = std.mem.tokenizeScalar(u8, typeShortLabel(notification_type), ' ');
        while (words.next()) |word| widest = @max(widest, try widgets.textWidth(context, word, &style.roster_name_selected));
    }
    const frame_padding = comptime style.roster.padding.?;
    const row_padding = comptime style.roster_row.padding.?;
    const row_gap = comptime style.roster_row.gap.?;
    const around = frame_padding.left() + frame_padding.right() + style.ROW_SCROLLBAR_GUTTER + row_padding.left() + row_padding.right() + style.EVENT_DOT_SIZE + 2 * row_gap + style.ROSTER_MARKER_SIZE;
    const width = std.math.clamp(@ceil(widest + around), style.ROSTER_WIDTH, style.ROSTER_MAX_WIDTH);
    return widgets.withWidth(context, &style.roster, width);
}

fn marker(context: *ui.Frame, key: ui.Key, glyph: glyphs.Glyph, tip: []const u8) !void {
    const tooltip = Tooltip{ .key = key, .content = lang.text(tip) };
    _ = try tooltip.open(context);
    const glyph_key = key.indexed(TOOLTIP_CHILD_INDEX);
    try context.e(Canvas{
        .key = glyph_key,
        .commands = try glyphs.commands(context.arena(), glyph, style.ROSTER_MARKER_SIZE, try glyphs.snapOffset(context, glyph_key), style.MUTED.value),
        .style = &style.roster_marker,
    });
    try tooltip.close(context);
}

fn customText(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType) !void {
    const primary_sample = notification.sample(notification_type);
    const alt_state = notification.altState(notification_type);
    const group = try widgets.openFieldGroup(context, .str("knots.events.text"), "Custom Text");
    try textBox(context, ref, notification_type, .custom_text, primary_sample, alt_state != null);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try textBox(context, ref, notification_type, .custom_text_alt, alt_sample, true);
    }

    try placeholderChips(context, ref, notification_type);

    try preview(context, notification_type, .custom_text, ref.get("custom_text"), primary_sample);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try preview(context, notification_type, .custom_text_alt, ref.get("custom_text_alt"), alt_sample);
    }
    try bind.optionalColor(context, ref, "text_color", "Text Color", session.profile().ptr.thumbnail.notifications.color);
    try widgets.hintText(context, .src(@src()), "Reset uses the Notification text's color on the Appearance tab.");
    try group.close(context);
}

/// A row per run of chips that fits, since knots only wraps text.
fn placeholderChips(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType) !void {
    const arena = context.arena();
    const placeholders = notification.placeholders(notification_type);
    const tokens = try arena.alloc([]const u8, placeholders.len);
    for (placeholders, tokens) |placeholder, *token| token.* = try std.fmt.allocPrint(arena, "{{{s}}}", .{placeholder.name});

    var first: usize = 0;
    while (first < tokens.len) {
        const end = try chipRowEnd(context, tokens, first);
        const row = Rect{ .key = ui.Key.str("knots.events.chip.row").indexed(first), .style = &style.chip_row };
        _ = try row.open(context);
        const box = Rect{ .key = ui.Key.str("knots.events.chip.box").indexed(first), .style = &style.chip_box };
        _ = try box.open(context);
        for (tokens[first..end], first..) |token, index| {
            if (try tagChip(context, ui.Key.str("knots.events.chip").indexed(index), token)) insertToken(context, ref, notification_type, token);
        }
        try box.close(context);
        try row.close(context);
        first = end;
    }
}

/// Past the last of `tokens` from `first` that fits on a row; always takes at least one.
fn chipRowEnd(context: *ui.Frame, tokens: []const []const u8, first: usize) !usize {
    const padding = comptime style.placeholder_chip.padding.?;
    const gap = comptime style.chip_box.gap.?;
    var used: f32 = 0;
    var end = first;
    while (end < tokens.len) : (end += 1) {
        const width = try widgets.textWidth(context, tokens[end], &style.placeholder_chip) + padding.left() + padding.right() + CHIP_BORDERS;
        const needed = if (end == first) width else used + gap + width;
        if (end > first and needed > style.CHIP_BOX_WIDTH) break;
        used = needed;
    }
    return end;
}

fn tagChip(context: *ui.Frame, key: ui.Key, token: []const u8) !bool {
    const tip = Tooltip{ .key = key, .content = lang.text("Inserts this into the text at the cursor.") };
    _ = try tip.open(context);
    const is_clicked = (try context.interact(Button{ .key = key.indexed(TOOLTIP_CHILD_INDEX), .label = token, .style = &style.placeholder_chip })).clicked;
    try tip.close(context);
    return is_clicked;
}

fn textBox(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType, comptime field: TextField, sample: notification.Notification, has_states: bool) !void {
    const name = @tagName(field);
    const state = sample.state orelse .on;
    const label = if (has_states) englishStateLabel(state) else "Text";
    const row = try widgets.openBinding(context, ui.Key.str("knots.events.text:" ++ name).indexed(ref.index), label);
    var buffer: [DEFAULT_TEXT_SIZE]u8 = undefined;
    // The box keeps its placeholder until the frame is drawn, so it can't point at this stack buffer.
    try bind.styledTextBox(context, ref, name, try context.arena().dupe(u8, notification.defaultText(sample, &buffer)), &style.custom_text_input);
    if (context.ui().focused(bind.boxKey(ref, name).hash())) g_last_text_field.set(notification_type, field);
    if ((try context.interact(Button{ .key = ui.Key.str("knots.events.text.clear:" ++ name).indexed(ref.index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
        ref.set(name, null);
    }
    try row.close(context);
    try widgets.hintText(context, ui.Key.str("knots.events.text.hint:" ++ name).indexed(ref.index), "Leave empty for the gray default. Type \\n for a new line.");
}

/// Inserts at the caret of the box last focused, as long as it still fits.
fn insertToken(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType, token: []const u8) void {
    switch (g_last_text_field.get(notification_type)) {
        inline .custom_text, .custom_text_alt => |field| {
            const name = @tagName(field);
            const current = ref.get(name) orelse "";
            if (current.len + token.len > CUSTOM_TEXT_MAX_LENGTH) return;
            const caret_state = context.ui().state.get(.text_input, bind.boxKey(ref, name).hash());
            const caret = @min(if (caret_state) |state| state.cursor else current.len, current.len);
            const inserted = std.mem.concat(context.arena(), u8, &.{ current[0..caret], token, current[caret..] }) catch |err| {
                slog.err("Failed to insert '{s}' into the custom text: {}", .{ token, err });
                return;
            };
            ref.set(name, inserted);
            if (caret_state) |state| state.cursor = @intCast(caret + token.len);
        },
    }
}

/// Mirrors notifications/template.zig's render with each placeholder's sample value.
fn preview(context: *ui.Frame, notification_type: NotificationType, comptime field: TextField, custom: ?[]const u8, sample: notification.Notification) !void {
    var default_buffer: [DEFAULT_TEXT_SIZE]u8 = undefined;
    var render_buffer: [notification.TEXT_MAX]u8 = undefined;
    const typed = std.mem.trim(u8, custom orelse "", " ");
    const shown = if (typed.len == 0) notification.defaultText(sample, &default_buffer) else template.render(typed, notification.placeholders(notification_type), notification.templateValues(sample, notification.SAMPLE_CHARACTER), &render_buffer) orelse typed;
    var lines = std.mem.splitScalar(u8, shown, '\n');
    var kept: std.ArrayList(u8) = .empty;
    var line_count: usize = 0;
    while (lines.next()) |line| : (line_count += 1) {
        if (line_count == overlay.MAX_LINES_PER_NOTIFICATION) break;
        if (line_count > 0) try kept.append(context.arena(), '\n');
        try kept.appendSlice(context.arena(), line);
    }
    // Under the text box, like the placeholder chips.
    const key = ui.Key.str("knots.events.preview:" ++ @tagName(field)).indexed(@backingInt(notification_type));
    const row = Rect{ .key = key, .style = &style.chip_row };
    _ = try row.open(context);
    try widgets.boxedText(context, key.indexed(1), try lang.format(context.arena(), "Preview: {text}", .{ .text = kept.items }), &style.chip_box, &style.hint);
    try row.close(context);
}

/// The file's name only; the full path is what's saved.
fn sound(context: *ui.Frame, ref: TypeRef, sound_target: pickers.Target, sound_index: usize) !void {
    const group = try widgets.openFieldGroup(context, .str("knots.events.sound"), "Sound");
    try bind.toggle(context, ref, "sound_enabled", "Play Custom Sound");
    try widgets.hintText(context, .src(@src()), "Plays a sound file of your choice with the alert.");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("sound_enabled"));
    const row = try widgets.openBinding(context, .src(@src()), "Sound File");
    const path = ref.get("sound_path") orelse "";
    try widgets.boxedText(context, .src(@src()), if (path.len == 0) "None" else std.fs.path.basename(path), &style.path_box, if (path.len == 0) &style.path_text_empty else &style.path_text);
    if (path.len > 0 and (try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) ref.set("sound_path", null);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Browse"), .style = &style.plain_button })).clicked) host.browseSoundFile(sound_target, sound_index);
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "A WAV or MP3 file.");
    try bind.slider(context, ref, "sound_volume", "Volume", .{ .display = .percent });
    try widgets.hintText(context, .src(@src()), "Only affects this alert's sound.");
    try options.close(context);
    try group.close(context);
}
