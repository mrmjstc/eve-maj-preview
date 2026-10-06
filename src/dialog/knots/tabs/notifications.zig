//! The configuration window's Notifications tab: the notification system, speech, per-event alerts, the history panel and travel mode; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const template = @import("../../../notifications/template.zig");
const painter_mod = @import("../../../painter.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const lang = @import("../lang.zig");
const status = @import("../status.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const log = @import("../../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const TextInput = ui.component.TextInput;
const NotificationType = notification.NotificationType;
const TypeRef = session.Ref(config.NotificationTypeConfig);
const slog = log.scoped("dialog_knots");

/// The most a custom text box takes.
const CUSTOM_TEXT_MAX_LENGTH = 100;
/// Matches thumbnail/overlay.zig's MAX_LINES_PER_NOTIFICATION.
const MAX_PREVIEW_LINES = 3;
const NEWLINE_TOKEN = "\\n";

/// Every type, by category, then as declared.
const TYPES_IN_ORDER = blk: {
    var ordered: [std.enums.values(NotificationType).len]NotificationType = undefined;
    var count: usize = 0;
    for (std.enums.values(notification.NotificationCategory)) |category| {
        for (std.enums.values(NotificationType)) |ntype| {
            if (notification.notificationCategory(ntype) != category) continue;
            ordered[count] = ntype;
            count += 1;
        }
    }
    break :blk ordered;
};

const TextField = enum { custom_text, custom_text_alt };

var g_allocator: std.mem.Allocator = undefined;
var g_selected: NotificationType = TYPES_IN_ORDER[0];
/// The Event Alerts search box's text. Owned; freed in reset.
var g_search: std.ArrayList(u8) = .empty;
/// Where a placeholder chip inserts, per type; the first box until another is focused.
var g_last_text_field: std.EnumArray(NotificationType, TextField) = .initFill(.custom_text);

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    g_search.deinit(g_allocator);
    g_search = .empty;
}

/// A notification type's own settings, by its index in NotificationType.
pub fn typeRef(index: usize) TypeRef {
    const configs = &session.profile().ptr.thumbnail.notifications.type_configs;
    return .{ .doc = .profile, .ptr = &configs.map.values[index], .layout = .none, .index = index };
}

pub fn show(context: *ui.Frame) !void {
    const profile = session.profile();
    if (!profile.ptr.chatlog.enabled) {
        try widgets.notice(context, .src(@src()), "Notifications requires Log Monitoring enabled to read logs and trigger alerts.");
    }
    try system(context);
    try speech(context);
    try eventAlerts(context);
    try historyPanel(context);
    try travel(context);
}

fn system(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Notification System", "Configure position, duration, and suppression behavior for event notifications.", .profile, &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    try bind.toggle(context, ref, "enabled", "Enable Notifications");
    // Its placement and font are edited from its chip on the Thumbnails tab's Text Overlays preview.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "suppress_click_duration_ms", "Click Suppress Duration (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "Suppresses further notifications on a thumbnail for this long after you click it.");
    try bind.number(context, ref, "notified_cycle_retention_seconds", "Recently-Notified Cycle Retention (s)", .{});
    try widgets.hintText(context, .src(@src()), "How long a character stays in the \"recently notified\" cycle group after its last alert.");
    try options.close(context);
    try section.close(context);
}

fn speech(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Text-to-Speech", "Speak alerts aloud using the Windows system voice. Enable individual event types below in the \"TTS\" column.", .profile, &style.section);
    const ref = session.profile().child("thumbnail").child("notifications");
    // Speech only means something while notifications fire, so the section dims with them.
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.toggle(context, ref, "tts_speak_character_name", "Prefix Spoken Alerts with the Character Name");
    const display_name = try widgets.openGroup(context, .src(@src()), ref.get("tts_speak_character_name"));
    try bind.toggle(context, ref, "tts_use_display_name", "Speak Display Name Instead of Character Name");
    try display_name.close(context);
    try widgets.hintText(context, .src(@src()), "Only takes effect while Prefix Spoken Alerts with the Character Name is also on.");
    const columns = Rect{ .key = .src(@src()), .style = &style.columns };
    _ = try columns.open(context);
    const volume = Rect{ .key = .src(@src()), .style = &style.column };
    _ = try volume.open(context);
    try bind.slider(context, ref, "tts_volume", "Volume", .{});
    try volume.close(context);
    const rate = Rect{ .key = .src(@src()), .style = &style.column };
    _ = try rate.open(context);
    try bind.slider(context, ref, "tts_rate", "Speed", .{});
    try widgets.hintText(context, .src(@src()), "0 is normal speaking speed; negative is slower, positive is faster.");
    try rate.close(context);
    try columns.close(context);
    try options.close(context);
    try section.close(context);
}

fn eventAlerts(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Event Alerts", "Per-event notification, suppression, speech, and border behavior. Select an event on the left to edit it.", .profile, &style.section);
    const enabled = session.profile().ptr.thumbnail.notifications.enabled;
    const options = try widgets.openGroup(context, .src(@src()), enabled);
    try searchBox(context);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    try typeRoster(context);
    try typeDetail(context, g_selected);
    try master_detail.close(context);
    try options.close(context);
    try section.close(context);
}

fn searchBox(context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.search_row };
    _ = try row.open(context);
    try context.e(TextInput{ .key = .str("knots.events.search"), .buf = &g_search, .style = &style.text_input, .placeholder = "Search events..." });
    if (g_search.items.len > 0) {
        if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
            g_search.clearRetainingCapacity();
            context.requestRedraw();
        }
    }
    try row.close(context);
}

fn typeLabel(ntype: NotificationType) []const u8 {
    return lang.textFmt("notification.{s}.label", .{@tagName(ntype)}, @tagName(ntype));
}

/// The short name keeps the roster narrow; the detail header uses the full one.
fn typeShortLabel(ntype: NotificationType) []const u8 {
    return lang.textFmt("notification.{s}.shortLabel", .{@tagName(ntype)}, typeLabel(ntype));
}

fn matchesSearch(ntype: NotificationType) bool {
    const query = std.mem.trim(u8, g_search.items, " ");
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(typeShortLabel(ntype), query) != null or std.ascii.findIgnoreCase(typeLabel(ntype), query) != null;
}

fn typeRoster(context: *ui.Frame) !void {
    const roster = Rect{ .key = .src(@src()), .style = &style.roster_events };
    _ = try roster.open(context);
    for (TYPES_IN_ORDER) |ntype| {
        if (!matchesSearch(ntype)) continue;
        const index = @backingInt(ntype);
        const is_selected = ntype == g_selected;
        const row = Button{ .key = ui.Key.str("knots.events.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
        if ((try row.openResponse(context)).clicked and !is_selected) {
            g_selected = ntype;
            context.requestRedraw();
        }
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.events.name").indexed(index),
            .content = typeShortLabel(ntype),
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        try row.close(context);
    }
    try roster.close(context);
}

fn typeDetail(context: *ui.Frame, ntype: NotificationType) !void {
    const ref = typeRef(@backingInt(ntype));
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);
    const previous_label = widgets.useLabelStyle(&style.rail_label);
    defer _ = widgets.useLabelStyle(previous_label);

    const header = Rect{ .key = .src(@src()), .style = &style.detail_header };
    _ = try header.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = typeLabel(ntype), .style = &style.heading });
    try header.close(context);

    const is_enabled = ref.get("enabled");
    const timing = try rail(context, .src(@src()), "Notification");
    try bind.toggle(context, ref, "enabled", "Enable");
    const timing_options = try widgets.openGroup(context, .src(@src()), is_enabled);
    try inlineNumber(context, ref, "duration_ms", "Duration (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "How long the alert stays on screen; 0 keeps it up until dismissed.");
    try inlineNumber(context, ref, "throttle_ms", "Limit (s)", .{ .ms_as_seconds = true });
    try widgets.hintText(context, .src(@src()), "Drops repeats of this alert that happen within this many seconds of the last one shown.");
    try timing_options.close(context);
    try closeRail(context, timing);

    const rest = try widgets.openGroup(context, .src(@src()), is_enabled);
    try customText(context, ref, ntype);

    const behavior = try rail(context, .src(@src()), "Behavior");
    try bind.toggle(context, ref, "suppress_when_focused", "Suppress While Focused");
    try widgets.hintText(context, .src(@src()), "Skips this alert while that character's EVE window is the one currently focused.");
    try bind.toggle(context, ref, "suppress_when_clicked", "Suppress After Click");
    try widgets.hintText(context, .src(@src()), "Skips this alert for a short time after you click the character's thumbnail.");
    try bind.toggle(context, ref, "tts_enabled", "Speak Aloud (TTS)");
    try bind.toggle(context, ref, "sound_enabled", "Play Custom Sound");
    try bind.toggle(context, ref, "show_border", "Show Border");
    // A hidden border has no colour to set and nothing to flash.
    const flash = try widgets.openGroup(context, .src(@src()), ref.get("show_border"));
    try bind.toggle(context, ref, "flash_border", "Flash Border");
    try flash.close(context);
    try closeRail(context, behavior);

    const colors = try rail(context, .src(@src()), "Colors");
    const defaults = config.ThumbnailConfig{};
    try optionalColor(context, ref, "text_color", "Text Color", defaults.characterNameColor);
    const border_color = try widgets.openGroup(context, .src(@src()), ref.get("show_border"));
    try optionalColor(context, ref, "border_color", "Border Color", defaults.inactiveBorderColor);
    try border_color.close(context);
    try closeRail(context, colors);

    try sound(context, ref, @backingInt(ntype));

    if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{25B6} Test Notification", .style = &style.plain_button })).clicked) {
        testNotification(ntype, ref.get("enabled"));
    }
    try rest.close(context);
    try stack.close(context);
}

/// A detail-form row: a label on the left rail, with the caller's controls stacked beside it.
fn rail(context: *ui.Frame, key: ui.Key, label: []const u8) !Rect {
    const row = Rect{ .key = key, .style = &style.rail_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = key.indexed(1), .content = label, .style = &style.rail_label });
    const body = Rect{ .key = key.indexed(2), .style = &style.rail_body };
    _ = try body.open(context);
    return row;
}

fn closeRail(context: *ui.Frame, row: Rect) !void {
    context.ui().close();
    try row.close(context);
}

fn inlineNumber(context: *ui.Frame, ref: TypeRef, comptime field: []const u8, label: []const u8, options: bind.NumberOptions) !void {
    const row = Rect{ .key = ui.Key.str("knots.events.inline:" ++ field).indexed(ref.index), .style = &style.inline_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.events.inline.label:" ++ field).indexed(ref.index), .content = label, .style = &style.inline_label });
    try bind.numberBox(context, ref, field, options);
    try row.close(context);
}

/// One box per state the type has, the placeholder chips that fill in event values, and a preview of each box.
fn customText(context: *ui.Frame, ref: TypeRef, ntype: NotificationType) !void {
    const primary_sample = notification.sample(ntype);
    const alt_state = notification.altState(ntype);
    const row = try rail(context, .src(@src()), "Custom Text");
    try textBox(context, ref, ntype, .custom_text, primary_sample, alt_state != null);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try textBox(context, ref, ntype, .custom_text_alt, alt_sample, true);
    }

    const chips = Rect{ .key = .src(@src()), .style = &style.chip_row };
    _ = try chips.open(context);
    for (notification.placeholders(ntype), 0..) |placeholder, index| {
        const token = try std.fmt.allocPrint(context.arena(), "{{{s}}}", .{placeholder.name});
        if ((try context.interact(Button{ .key = ui.Key.str("knots.events.chip").indexed(index), .label = token, .style = &style.placeholder_chip })).clicked) {
            insertToken(context, ref, ntype, token);
        }
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = NEWLINE_TOKEN, .style = &style.placeholder_chip })).clicked) {
        insertToken(context, ref, ntype, NEWLINE_TOKEN);
    }
    try chips.close(context);

    try preview(context, ntype, .custom_text, ref.get("custom_text"), primary_sample);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try preview(context, ntype, .custom_text_alt, ref.get("custom_text_alt"), alt_sample);
    }
    try widgets.hintText(context, .src(@src()), "Leave empty to use the default wording shown in grey. Click a placeholder to insert it; it's filled in from the event. Type \\n for a new line.");
    try closeRail(context, row);
}

fn textBox(context: *ui.Frame, ref: TypeRef, ntype: NotificationType, comptime field: TextField, sample: notification.Notification, has_states: bool) !void {
    const name = @tagName(field);
    const row = Rect{ .key = ui.Key.str("knots.events.text:" ++ name).indexed(ref.index), .style = &style.inline_row };
    _ = try row.open(context);
    if (has_states) {
        const state = sample.state orelse .on;
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.events.text.state:" ++ name).indexed(ref.index),
            .content = lang.textFmt("notification.state.{s}.label", .{@tagName(state)}, @tagName(state)),
            .style = &style.inline_label,
        });
    }
    var buf: [128]u8 = undefined;
    // The box keeps its placeholder until the frame is drawn, so it can't point at this stack buffer.
    try bind.textBox(context, ref, name, try context.arena().dupe(u8, notification.defaultText(sample, &buf)));
    if (context.ui().focused(bind.boxKey(ref, name).hash())) g_last_text_field.set(ntype, field);
    if ((try context.interact(Button{ .key = ui.Key.str("knots.events.text.clear:" ++ name).indexed(ref.index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
        ref.set(name, null);
    }
    try row.close(context);
}

/// Inserts at the caret of the box last focused, as long as it still fits.
fn insertToken(context: *ui.Frame, ref: TypeRef, ntype: NotificationType, token: []const u8) void {
    switch (g_last_text_field.get(ntype)) {
        inline else => |field| {
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
fn preview(context: *ui.Frame, ntype: NotificationType, comptime field: TextField, custom: ?[]const u8, sample: notification.Notification) !void {
    var default_buf: [128]u8 = undefined;
    var render_buf: [256]u8 = undefined;
    const typed = std.mem.trim(u8, custom orelse "", " ");
    const shown = if (typed.len == 0) notification.defaultText(sample, &default_buf) else template.render(typed, notification.placeholders(ntype), .{
        .source = sample.source,
        .target = sample.target,
        .character = notification.SAMPLE_CHARACTER,
    }, &render_buf) orelse typed;
    var lines = std.mem.splitScalar(u8, shown, '\n');
    var kept: std.ArrayList(u8) = .empty;
    var line_count: usize = 0;
    while (lines.next()) |line| : (line_count += 1) {
        if (line_count == MAX_PREVIEW_LINES) break;
        if (line_count > 0) try kept.append(context.arena(), '\n');
        try kept.appendSlice(context.arena(), line);
    }
    try widgets.paragraph(context, ui.Key.str("knots.events.preview:" ++ @tagName(field)).indexed(@backingInt(ntype)), try std.fmt.allocPrint(context.arena(), "Preview: {s}", .{kept.items}));
}

/// Unticked leaves it unset, inheriting `fallback`; picking a colour ticks it.
fn optionalColor(context: *ui.Frame, ref: TypeRef, comptime field: []const u8, label: []const u8, fallback: u32) !void {
    const row = Rect{ .key = ui.Key.str("knots.events.color:" ++ field).indexed(ref.index), .style = &style.inline_row };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.events.color.label:" ++ field).indexed(ref.index), .content = label, .style = &style.inline_label_fixed });
    var is_set = ref.get(field) != null;
    if (try widgets.checkbox(context, ui.Key.str("knots.events.color.set:" ++ field).indexed(ref.index), "", &is_set)) {
        ref.set(field, if (is_set) fallback else null);
    }
    var value = widgets.colorFromArgb(ref.get(field) orelse fallback);
    if ((try context.interact(ui.component.ColorPicker{
        .key = ui.Key.str("knots.events.color.picker:" ++ field).indexed(ref.index),
        .value = &value,
        .style = &style.color_picker,
        .parts = .{ .swatch = &style.color_swatch, .popup = &style.color_popup },
    })).changed) ref.set(field, widgets.argbFromColor(value));
    try row.close(context);
}

/// The file's name only; the full path is what's saved.
fn sound(context: *ui.Frame, ref: TypeRef, type_index: usize) !void {
    const path_row = try rail(context, .src(@src()), "Custom Sound");
    const line = Rect{ .key = .src(@src()), .style = &style.inline_row };
    _ = try line.open(context);
    const path = ref.get("sound_path") orelse "";
    try context.e(Text{
        .selectable = false,
        .key = .src(@src()),
        .content = if (path.len == 0) "No file selected" else std.fs.path.basename(path),
        .style = if (path.len == 0) &style.path_box_empty else &style.path_box,
    });
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Browse", .style = &style.plain_button })).clicked) host.browseSoundFile(type_index);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) ref.set("sound_path", null);
    try line.close(context);
    try closeRail(context, path_row);

    const volume_row = try rail(context, .src(@src()), "");
    try bind.slider(context, ref, "sound_volume", "Volume", .{});
    try closeRail(context, volume_row);
}

/// Fires the type on every thumbnail with the settings the window has for it, saved or not.
fn testNotification(ntype: NotificationType, is_enabled: bool) void {
    if (!is_enabled) return;
    const painter = painter_mod.g_painter_ptr orelse return;
    painter.showTestNotification(ntype, session.profile().ptr.thumbnail.notifications.getTypeConfig(ntype)) catch |err| {
        slog.err("Failed to test notification: {}", .{err});
        status.show(.failure, "Failed to test notification: {}", .{err});
    };
}

fn historyPanel(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "History Panel", "A draggable, resizable panel showing recent notification history. Click a row to jump to that character.", .profile, &style.section);
    const ref = session.profile().child("display");
    try bind.toggle(context, ref, "showNotifInfoPanel", "Show History Panel");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("showNotifInfoPanel"));
    try bind.number(context, ref, "notifInfoPanelWidth", "Panel Width (px)", .{});
    try bind.number(context, ref, "notifInfoPanelHeight", "Panel Height (px)", .{});
    try bind.number(context, ref, "notifInfoPanelMaxRows", "Max History Rows", .{});
    try bind.slider(context, ref, "notifInfoPanelOpacity", "Panel Opacity", .{ .display = .percent_of_255 });

    try widgets.subheading(context, .src(@src()), "Font");
    try bind.fontName(context, ref, "notifInfoPanelFontName", "Font Name");
    try bind.number(context, ref, "notifInfoPanelFontSize", "Font Size (px)", .{});
    try bind.choice(context, ref, "notifInfoPanelFontWeight", "Font Weight");

    try widgets.subheading(context, .src(@src()), "Behavior");
    try bind.toggle(context, ref, "rememberNotifInfoPanelPosition", "Remember History Panel Position");
    try bind.toggle(context, ref, "hideNotifInfoPanelWhenNoCharacters", "Hide Panel When No Characters Are Logged In");
    try bind.toggle(context, ref, "notifInfoPanelShowTimestamp", "Show Relative Timestamps");
    try widgets.hintText(context, .src(@src()), "Shows times like \"5m ago\" instead of a fixed clock time.");
    try bind.toggle(context, ref, "notifInfoPanelShowCategoryFilters", "Show Category Filters");
    try widgets.hintText(context, .src(@src()), "Adds filter buttons for each notification category to the panel.");
    try bind.toggle(context, ref, "notifInfoPanelMergeEnabled", "Merge Repeated Notifications");
    try widgets.hintText(context, .src(@src()), "Combines identical notifications fired back to back into one row with a +N count. Click a merged row to expand it.");
    const merge = try widgets.openGroup(context, .src(@src()), ref.get("notifInfoPanelMergeEnabled"));
    try bind.number(context, ref, "notifInfoPanelMergeWindowSec", "Merge Window (seconds)", .{});
    try merge.close(context);
    try options.close(context);
    try section.close(context);
}

fn travel(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Travel Mode", "Detects when a tracked character falls behind while the rest of the group jumps together, and fires a notification. Runs automatically once enabled below - no manual start/stop needed. Border color, duration, and TTS for the alert are configured above under \"Left Behind\".", .profile, &style.section);
    const ref = session.profile().child("travel");
    try bind.toggle(context, ref, "enabled", "Enable Travel Mode");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("enabled"));
    try bind.number(context, ref, "window_seconds", "Catch-Up Window (seconds)", .{});
    try widgets.hintText(context, .src(@src()), "How long a character can lag behind the group's jump before this fires.");
    try bind.choice(context, ref, "threshold_mode", "Group Size Threshold");
    try widgets.hintText(context, .src(@src()), "Minimum group size required before a straggler triggers an alert.");
    switch (ref.get("threshold_mode")) {
        .percent => try bind.number(context, ref, "threshold_percent", "Minimum Percentage", .{}),
        .count => try bind.number(context, ref, "threshold_count", "Minimum Count", .{}),
    }
    try options.close(context);
    try section.close(context);
}
