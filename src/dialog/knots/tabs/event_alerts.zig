//! The configuration window's Events tab: a list of notification types, each opening its settings under its row; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const notification = @import("../../../notifications/notification.zig");
const template = @import("../../../notifications/template.zig");
const overlay = @import("../../../thumbnail/overlay.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
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

/// The most a custom text box takes.
const CUSTOM_TEXT_MAX_LENGTH = 100;
const NEWLINE_TOKEN = "\\n";
/// Holds notification.defaultText, which the box and its preview both show.
const DEFAULT_TEXT_SIZE = 128;
/// knots' Tooltip keys its popup and text as its own key indexed 1 and 2, so what it wraps takes this.
const TOOLTIP_CHILD_INDEX = 3;

/// Every type, by category, then as declared.
const TYPES_IN_ORDER = blk: {
    var ordered: [std.enums.values(NotificationType).len]NotificationType = undefined;
    var count: usize = 0;
    for (std.enums.values(notification.NotificationCategory)) |category| {
        for (std.enums.values(NotificationType)) |notification_type| {
            if (notification.notificationCategory(notification_type) != category) continue;
            ordered[count] = notification_type;
            count += 1;
        }
    }
    break :blk ordered;
};

const TextField = enum { custom_text, custom_text_alt };

/// Which events the list shows, besides matching the filter text.
const Shown = enum { all, on, off };

var g_allocator: std.mem.Allocator = undefined;
/// The type whose settings are open under its row, or null while every row is closed.
var g_expanded: ?NotificationType = null;
/// What the list is filtered by; owned, freed in reset.
var g_filter: std.ArrayList(u8) = .empty;
var g_shown: Shown = .all;
/// Where a placeholder chip inserts, per type; the first box until another is focused.
var g_last_text_field: std.EnumArray(NotificationType, TextField) = .initFill(.custom_text);

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    g_filter.deinit(g_allocator);
    g_filter = .empty;
    g_shown = .all;
}

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
        try widgets.noticeWithButton(context, .src(@src()), "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.", "Go to Log Files", .log_monitoring);
    }
    const options = try widgets.openSectionsGroup(context, .src(@src()), is_enabled);
    try typeList(context);
    try options.close(context);
}

fn typeLabel(notification_type: NotificationType) []const u8 {
    return lang.text(englishLabel(notification_type));
}

/// In English, in capitals like a menu's heading; boxedText translates it.
fn categoryHeading(category: notification.NotificationCategory) []const u8 {
    return switch (category) {
        .Fleet => "FLEET",
        .Mining => "MINING",
        .Combat => "COMBAT",
        .Navigation => "NAVIGATION",
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

/// Grouped under category headings, each with how many of its events are on; a row's switch turns its event on and off.
fn typeList(context: *ui.Frame) !void {
    const arena = context.arena();
    const toolbar = Rect{ .key = .src(@src()), .style = &style.list_toolbar };
    _ = try toolbar.open(context);
    try widgets.searchBox(context, .str("knots.events.filter"), &g_filter, "Filter events");
    if (try widgets.segmented(context, .src(@src()), &.{ "All", "On", "Off" }, @backingInt(g_shown))) |picked| g_shown = @fromBackingInt(@intCast(picked));
    try toolbar.close(context);

    var on_counts: std.EnumArray(notification.NotificationCategory, usize) = .initFill(0);
    var totals: std.EnumArray(notification.NotificationCategory, usize) = .initFill(0);
    for (TYPES_IN_ORDER) |notification_type| {
        const category = notification.notificationCategory(notification_type);
        totals.getPtr(category).* += 1;
        if (typeRef(@backingInt(notification_type)).get("enabled")) on_counts.getPtr(category).* += 1;
    }

    const query = std.mem.trim(u8, g_filter.items, " ");
    const section = try widgets.openSection(context, "Event Alerts", "How each game event alerts you. Click one to open its settings.", &style.list_section);
    var last_category: ?notification.NotificationCategory = null;
    var shown_count: usize = 0;
    for (TYPES_IN_ORDER) |notification_type| {
        const index = @backingInt(notification_type);
        const category = notification.notificationCategory(notification_type);
        const is_enabled = typeRef(index).get("enabled");
        const is_listed = switch (g_shown) {
            .all => true,
            .on => is_enabled,
            .off => !is_enabled,
        };
        if (!is_listed or (query.len > 0 and std.ascii.findIgnoreCase(typeLabel(notification_type), query) == null)) continue;
        shown_count += 1;
        if (last_category != category) {
            last_category = category;
            const counts = try lang.format(arena, "{on} of {total} on", .{ .on = on_counts.get(category), .total = totals.get(category) });
            const heading = try std.fmt.allocPrint(arena, "{s} \u{00B7} {s}", .{ lang.text(categoryHeading(category)), counts });
            try widgets.boxedText(context, ui.Key.str("knots.events.category").indexed(@backingInt(category)), heading, &style.list_category, &style.tab_category_text);
        }
        const row = Button{ .key = ui.Key.str("knots.events.row").indexed(index), .style = &style.event_item };
        const is_row_clicked = (try widgets.openRosterRow(context, row)).clicked;
        const ref = typeRef(index);
        var is_on = is_enabled;
        const is_switched = try widgets.checkbox(context, ui.Key.str("knots.events.switch").indexed(index), "", &is_on);
        if (is_switched) ref.set("enabled", is_on);
        // The row hears a click on its switch too, which only flips the switch.
        const is_expanded = g_expanded == notification_type;
        if (is_row_clicked and !is_switched) {
            g_expanded = if (is_expanded) null else notification_type;
            context.requestRedraw();
        }
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.events.name").indexed(index),
            .content = typeLabel(notification_type),
            .style = if (ref.get("enabled")) &style.list_item_name else &style.event_name_off,
        });
        if (ref.get("tts_enabled")) try marker(context, ui.Key.str("knots.events.tts").indexed(index), .speech, "Speaks aloud");
        if (ref.get("sound_enabled")) try marker(context, ui.Key.str("knots.events.sound").indexed(index), .speaker, "Plays a custom sound");
        const chevron_key = ui.Key.str("knots.events.chevron").indexed(index);
        try context.e(Canvas{
            .key = chevron_key,
            .commands = try glyphs.commands(arena, if (is_expanded) .chevron_up else .chevron_down, glyphs.TAB_SIZE, try glyphs.snapOffset(context, chevron_key), style.BORDER_STRONG.value),
            .style = &style.tab_glyph,
        });
        try row.close(context);
        if (is_expanded) try typeEditor(context, notification_type);
    }
    if (shown_count == 0) try widgets.paragraph(context, .src(@src()), "No events match.");
    try section.close(context);
}

/// A small glyph after an event's name, which a tooltip names.
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

/// The open event's settings, under its row in the list.
fn typeEditor(context: *ui.Frame, notification_type: NotificationType) !void {
    const ref = typeRef(@backingInt(notification_type));
    const is_enabled: bool = ref.get("enabled");
    const editor = Rect{ .key = ui.Key.str("knots.events.editor").indexed(ref.index), .style = &style.inline_editor };
    _ = try editor.open(context);
    const rest = try widgets.openGroup(context, .src(@src()), is_enabled);

    try widgets.subheading(context, .src(@src()), "Timing");
    try bind.number(context, ref, "duration_ms", "Duration", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How long the alert shows; 0 keeps it until dismissed.");
    try bind.number(context, ref, "throttle_ms", "Cooldown", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "Ignores repeats within this time.");

    try widgets.subheading(context, .src(@src()), "Custom Text");
    try customText(context, ref, notification_type);

    try widgets.subheading(context, .src(@src()), "Alert Behavior");
    try bind.toggle(context, ref, "suppress_when_focused", "Suppress While Focused");
    try widgets.hintText(context, .src(@src()), "Skips the alert while you're on that character.");
    try bind.toggle(context, ref, "suppress_when_clicked", "Suppress After Click");
    try widgets.hintText(context, .src(@src()), "Skips the alert briefly after you click that character.");
    try bind.toggle(context, ref, "show_hidden_thumbnail", "Show Thumbnail Even If Hidden");
    try widgets.hintText(context, .src(@src()), "Only for as long as the alert lasts.");
    try bind.toggle(context, ref, "tts_enabled", "Speak Aloud (TTS)");
    try widgets.hintText(context, .src(@src()), "Reads the alert out loud. Voice settings are on the Notifications tab.");

    try widgets.subheading(context, .src(@src()), "Border");
    try bind.toggle(context, ref, "show_border", "Show Border");
    try widgets.hintText(context, .src(@src()), "Marks the thumbnail with a colored border during the alert.");
    // A hidden border has no colour to set and nothing to flash.
    const border_options = try widgets.openNestedGroup(context, .src(@src()), ref.get("show_border"));
    try bind.toggle(context, ref, "flash_border", "Flash Border");
    try widgets.hintText(context, .src(@src()), "Makes the border blink.");
    const defaults = config.ThumbnailConfig{};
    try bind.optionalColor(context, ref, "border_color", "Border Color", defaults.inactiveBorderColor);
    try widgets.hintText(context, .src(@src()), "Reset uses the default color.");
    try border_options.close(context);

    try widgets.subheading(context, .src(@src()), "Sound");
    try sound(context, ref, @backingInt(notification_type));

    const actions = Rect{ .key = .src(@src()), .style = &style.inline_editor_actions };
    _ = try actions.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("\u{25B6} Test"), .style = &style.plain_button })).clicked) testNotification(notification_type);
    try actions.close(context);
    try rest.close(context);
    try editor.close(context);
}

fn customText(context: *ui.Frame, ref: TypeRef, notification_type: NotificationType) !void {
    const primary_sample = notification.sample(notification_type);
    const alt_state = notification.altState(notification_type);
    try textBox(context, ref, notification_type, .custom_text, primary_sample, alt_state != null);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try textBox(context, ref, notification_type, .custom_text_alt, alt_sample, true);
    }

    const chips = Rect{ .key = .src(@src()), .style = &style.chip_row };
    _ = try chips.open(context);
    const chip_box = Rect{ .key = .src(@src()), .style = &style.chip_box };
    _ = try chip_box.open(context);
    for (notification.placeholders(notification_type), 0..) |placeholder, index| {
        const token = try std.fmt.allocPrint(context.arena(), "{{{s}}}", .{placeholder.name});
        if (try tagChip(context, ui.Key.str("knots.events.chip").indexed(index), token)) insertToken(context, ref, notification_type, token);
    }
    if (try tagChip(context, .str("knots.events.chip.newline"), NEWLINE_TOKEN)) insertToken(context, ref, notification_type, NEWLINE_TOKEN);
    try chip_box.close(context);
    try chips.close(context);

    try preview(context, notification_type, .custom_text, ref.get("custom_text"), primary_sample);
    if (alt_state) |state| {
        var alt_sample = primary_sample;
        alt_sample.state = state;
        try preview(context, notification_type, .custom_text_alt, ref.get("custom_text_alt"), alt_sample);
    }
    try bind.optionalColor(context, ref, "text_color", "Text Color", session.profile().ptr.thumbnail.notifications.color);
    try widgets.hintText(context, .src(@src()), "Reset uses the Notification text's color on the Thumbnails tab.");
}

/// A placeholder chip, whose tooltip says what clicking it does; returns whether it was clicked.
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
    // A type with two texts labels each by the state it's for.
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
    const shown = if (typed.len == 0) notification.defaultText(sample, &default_buffer) else template.render(typed, notification.placeholders(notification_type), .{
        .source = sample.source,
        .target = sample.target,
        .character = notification.SAMPLE_CHARACTER,
    }, &render_buffer) orelse typed;
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
fn sound(context: *ui.Frame, ref: TypeRef, type_index: usize) !void {
    try bind.toggle(context, ref, "sound_enabled", "Play Custom Sound");
    try widgets.hintText(context, .src(@src()), "Plays a sound file of your choice with the alert.");
    const options = try widgets.openNestedGroup(context, .src(@src()), ref.get("sound_enabled"));
    const row = try widgets.openBinding(context, .src(@src()), "Sound File");
    const path = ref.get("sound_path") orelse "";
    try widgets.boxedText(context, .src(@src()), if (path.len == 0) "None" else std.fs.path.basename(path), &style.path_box, if (path.len == 0) &style.path_text_empty else &style.path_text);
    if (path.len > 0 and (try context.interact(Button{ .key = .src(@src()), .label = "\u{00D7}", .style = &style.icon_button_danger_text })).clicked) ref.set("sound_path", null);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Browse"), .style = &style.plain_button })).clicked) host.browseSoundFile(type_index);
    try row.close(context);
    try widgets.hintText(context, .src(@src()), "A WAV or MP3 file.");
    try bind.slider(context, ref, "sound_volume", "Volume", .{ .display = .percent });
    try widgets.hintText(context, .src(@src()), "Only affects this alert's sound.");
    try options.close(context);
}

/// Fires the type on every thumbnail with the settings the window has for it, saved or not.
fn testNotification(notification_type: NotificationType) void {
    const thumbnail_set = session.runningApp().thumbnail_set orelse {
        slog.warn("Failed to test notification: the thumbnail set isn't ready", .{});
        return;
    };
    thumbnail_set.showTestNotification(notification_type, session.profile().ptr.thumbnail.notifications.getTypeConfig(notification_type)) catch |err| {
        slog.err("Failed to test notification: {}", .{err});
        status.show(.failure, "Failed to test notification: {err}", .{ .err = err });
    };
}
