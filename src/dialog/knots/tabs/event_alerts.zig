//! The configuration window's Event Alerts tab: a searchable list of notification types beside the selected type's settings; main thread only.
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
/// The roster's search text. Owned; freed in reset.
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
    const is_enabled = session.profile().ptr.thumbnail.notifications.enabled;
    if (!session.profile().ptr.chatlog.enabled) {
        try widgets.notice(context, .src(@src()), "Event Alerts requires Log Monitoring enabled to read logs and trigger alerts.");
    } else if (!is_enabled) {
        try widgets.notice(context, .src(@src()), "Event Alerts requires Enable Notifications on the Notifications tab.");
    }
    const section = try widgets.openSection(context, "Event Alerts", "Per-event notification, suppression, speech, and border behavior. Select an event on the left to edit it.", &style.fill_section);
    const options = try widgets.openFillGroup(context, .src(@src()), is_enabled);
    try searchBox(context);
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail_fill };
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
    const roster = Rect{ .key = .src(@src()), .style = &style.roster };
    _ = try roster.open(context);
    const rows = Rect{ .key = .src(@src()), .style = &style.roster_rows };
    _ = try rows.open(context);
    for (TYPES_IN_ORDER) |ntype| {
        if (!matchesSearch(ntype)) continue;
        const index = @backingInt(ntype);
        const is_selected = ntype == g_selected;
        const row = Button{ .key = ui.Key.str("knots.events.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
        if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
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
    try rows.close(context);
    try roster.close(context);
}

fn typeDetail(context: *ui.Frame, ntype: NotificationType) !void {
    const ref = typeRef(@backingInt(ntype));
    const stack = try widgets.openScrollPane(context, .str("knots.events.detail"), style.detail_scroll);
    const previous_rows = widgets.useDetailRows();
    defer widgets.restoreRows(previous_rows);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = typeLabel(ntype), .style = &style.roster_name_selected });
    var is_enabled: bool = ref.get("enabled");
    if ((try context.interact(Button{ .key = .src(@src()), .label = "\u{25B6} Test", .disabled = !is_enabled, .style = &style.plain_button })).clicked) {
        testNotification(ntype);
    }
    try header.close(context);
    if (try widgets.switchRow(context, ui.Key.str("knots.events.enabled").indexed(ref.index), "Enabled", &is_enabled)) ref.set("enabled", is_enabled);
    try widgets.separator(context, .str("knots.events.separator.enabled"));

    const rest = try widgets.openGroup(context, .src(@src()), is_enabled);
    const timing = try widgets.openFieldGroup(context, .str("knots.events.timing"), "Timing");
    try bind.number(context, ref, "duration_ms", "Duration", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long the alert stays on screen; 0 keeps it up until dismissed.");
    try bind.number(context, ref, "throttle_ms", "Limit", .{ .ms_as_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Drops repeats of this alert that happen within this many seconds of the last one shown.");
    try timing.close(context);
    try widgets.separator(context, .str("knots.events.separator.timing"));

    try customText(context, ref, ntype);
    try widgets.separator(context, .str("knots.events.separator.text"));

    const behavior = try widgets.openFieldGroup(context, .str("knots.events.behavior"), "Behavior");
    try bind.toggle(context, ref, "suppress_when_focused", "Suppress While Focused");
    try widgets.hintText(context, .src(@src()), "Skips this alert while that character's EVE window is the one currently focused.");
    try bind.toggle(context, ref, "suppress_when_clicked", "Suppress After Click");
    try widgets.hintText(context, .src(@src()), "Skips this alert for a short time after you click the character's thumbnail.");
    try bind.toggle(context, ref, "tts_enabled", "Speak Aloud (TTS)");
    try behavior.close(context);
    try widgets.separator(context, .str("knots.events.separator.behavior"));

    const border = try widgets.openFieldGroup(context, .str("knots.events.border"), "Border");
    try bind.toggle(context, ref, "show_border", "Show Border");
    // A hidden border has no colour to set and nothing to flash.
    const border_options = try widgets.openGroup(context, .src(@src()), ref.get("show_border"));
    try bind.toggle(context, ref, "flash_border", "Flash Border");
    const defaults = config.ThumbnailConfig{};
    try bind.optionalColor(context, ref, "border_color", "Border Color", defaults.inactiveBorderColor);
    try border_options.close(context);
    try border.close(context);
    try widgets.separator(context, .str("knots.events.separator.border"));

    try sound(context, ref, @backingInt(ntype));
    try rest.close(context);
    try stack.close(context);
}

/// One box per state the type has, the placeholder chips that fill in event values, a preview of each box, and the text colour.
fn customText(context: *ui.Frame, ref: TypeRef, ntype: NotificationType) !void {
    const primary_sample = notification.sample(ntype);
    const alt_state = notification.altState(ntype);
    const group = try widgets.openFieldGroup(context, .str("knots.events.text"), "Custom Text");
    try textBox(context, ref, ntype, .custom_text, primary_sample, alt_state != null);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try textBox(context, ref, ntype, .custom_text_alt, alt_sample, true);
    }

    const chips = Rect{ .key = .src(@src()), .style = &style.chip_row };
    _ = try chips.open(context);
    const chip_box = Rect{ .key = .src(@src()), .style = &style.chip_box };
    _ = try chip_box.open(context);
    for (notification.placeholders(ntype), 0..) |placeholder, index| {
        const token = try std.fmt.allocPrint(context.arena(), "{{{s}}}", .{placeholder.name});
        if ((try context.interact(Button{ .key = ui.Key.str("knots.events.chip").indexed(index), .label = token, .style = &style.placeholder_chip })).clicked) {
            insertToken(context, ref, ntype, token);
        }
    }
    if ((try context.interact(Button{ .key = .src(@src()), .label = NEWLINE_TOKEN, .style = &style.placeholder_chip })).clicked) {
        insertToken(context, ref, ntype, NEWLINE_TOKEN);
    }
    try chip_box.close(context);
    try chips.close(context);

    try preview(context, ntype, .custom_text, ref.get("custom_text"), primary_sample);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try preview(context, ntype, .custom_text_alt, ref.get("custom_text_alt"), alt_sample);
    }
    try widgets.hintText(context, .src(@src()), "Leave empty to use the default wording shown in grey. Click a placeholder to insert it; it's filled in from the event. Type \\n for a new line.");
    try bind.optionalColor(context, ref, "text_color", "Text Color", session.profile().ptr.thumbnail.notifications.color);
    try group.close(context);
}

fn textBox(context: *ui.Frame, ref: TypeRef, ntype: NotificationType, comptime field: TextField, sample: notification.Notification, has_states: bool) !void {
    const name = @tagName(field);
    const state = sample.state orelse .on;
    const label = if (has_states) lang.textFmt("notification.state.{s}.label", .{@tagName(state)}, @tagName(state)) else "Text";
    const row = try widgets.openBinding(context, ui.Key.str("knots.events.text:" ++ name).indexed(ref.index), label);
    var buf: [128]u8 = undefined;
    // The box keeps its placeholder until the frame is drawn, so it can't point at this stack buffer.
    try bind.styledTextBox(context, ref, name, try context.arena().dupe(u8, notification.defaultText(sample, &buf)), &style.custom_text_input);
    if (context.ui().focused(bind.boxKey(ref, name).hash())) g_last_text_field.set(ntype, field);
    if ((try context.interact(Button{ .key = ui.Key.str("knots.events.text.clear:" ++ name).indexed(ref.index), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) {
        ref.set(name, null);
    }
    try row.close(context);
}

/// Inserts at the caret of the box last focused, as long as it still fits.
fn insertToken(context: *ui.Frame, ref: TypeRef, ntype: NotificationType, token: []const u8) void {
    switch (g_last_text_field.get(ntype)) {
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

/// The file's name only; the full path is what's saved.
fn sound(context: *ui.Frame, ref: TypeRef, type_index: usize) !void {
    const group = try widgets.openFieldGroup(context, .str("knots.events.sound"), "Sound");
    try bind.toggle(context, ref, "sound_enabled", "Play Custom Sound");
    const options = try widgets.openGroup(context, .src(@src()), ref.get("sound_enabled"));
    const row = try widgets.openBinding(context, .src(@src()), "Sound File");
    const path = ref.get("sound_path") orelse "";
    try widgets.boxedText(context, .src(@src()), if (path.len == 0) "None" else std.fs.path.basename(path), &style.path_box, if (path.len == 0) &style.path_text_empty else &style.path_text);
    if (path.len > 0 and (try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) ref.set("sound_path", null);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Browse", .style = &style.plain_button })).clicked) host.browseSoundFile(type_index);
    try row.close(context);
    try bind.slider(context, ref, "sound_volume", "Volume", .{});
    try options.close(context);
    try group.close(context);
}

/// Fires the type on every thumbnail with the settings the window has for it, saved or not.
fn testNotification(ntype: NotificationType) void {
    const painter = painter_mod.g_painter_ptr orelse {
        slog.warn("Failed to test notification: the painter isn't ready", .{});
        return;
    };
    painter.showTestNotification(ntype, session.profile().ptr.thumbnail.notifications.getTypeConfig(ntype)) catch |err| {
        slog.err("Failed to test notification: {}", .{err});
        status.show(.failure, "Failed to test notification: {}", .{err});
    };
}
