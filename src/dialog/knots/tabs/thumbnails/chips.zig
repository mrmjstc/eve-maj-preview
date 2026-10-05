//! The texts a thumbnail can show, as chips on the Appearance page's stage: which settings each one reads, and its settings pane; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../../config.zig");
const types = @import("../../../../config/types.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const status = @import("../../status.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const overlay_text = @import("../overlay_text.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Fields = overlay_text.Fields;

/// The settings struct a chip's fields live in.
pub const Section = enum { thumbnail, notifications, combat, mining, bounty, resources };

pub const Chip = struct {
    label: []const u8,
    /// What the stage draws for it.
    sample: []const u8,
    section: Section,
    fields: Fields,
    show_field: []const u8,
    show_label: []const u8,
    /// The thumbnail's Show Text Overlays has to be on too.
    needs_show_text: bool,
    /// Its section's master switch, set on another tab, e.g. Combat's `enabled`.
    enabled_field: ?[]const u8 = null,
    /// Where `enabled_field` is turned on.
    enabled_tab: []const u8 = "",
    unique_field: ?[]const u8 = null,
    unique_label: []const u8 = "",
};

pub const CHIPS = [_]Chip{
    .{ .label = "Character Name", .sample = "Character Name", .section = .thumbnail, .fields = .camelCase("characterName"), .show_field = "showCharacterName", .show_label = "Show Character Name", .needs_show_text = true, .unique_field = "useUniqueCharacterNameColors", .unique_label = "Unique Color per Character" },
    .{ .label = "System Name", .sample = "Jita", .section = .thumbnail, .fields = .camelCase("systemName"), .show_field = "showSystemName", .show_label = "Show System Name", .needs_show_text = true, .unique_field = "useUniqueSystemColors", .unique_label = "Unique Color per System" },
    .{ .label = "Group Badge", .sample = "Miners", .section = .thumbnail, .fields = .camelCase("quickGroupBadge"), .show_field = "showQuickGroupBadge", .show_label = "Show Group Badge", .needs_show_text = true },
    .{ .label = "Session Timer", .sample = "1:42:07", .section = .thumbnail, .fields = .camelCase("sessionTimer"), .show_field = "showSessionTimer", .show_label = "Show Session Timer", .needs_show_text = true },
    .{ .label = "Notification", .sample = "Fleet Invite", .section = .notifications, .fields = .snakeCase("", false), .show_field = "enabled", .show_label = "Show Notifications", .needs_show_text = true },
    .{ .label = "Incoming DPS", .sample = "IN: 412", .section = .combat, .fields = .snakeCase("incoming_", true), .show_field = "show_incoming", .show_label = "Show Incoming Damage", .needs_show_text = false, .enabled_field = "enabled", .enabled_tab = "Combat" },
    .{ .label = "Outgoing DPS", .sample = "OUT: 980", .section = .combat, .fields = .snakeCase("outgoing_", true), .show_field = "show_outgoing", .show_label = "Show Outgoing Damage", .needs_show_text = false, .enabled_field = "enabled", .enabled_tab = "Combat" },
    .{ .label = "Mining Rate", .sample = "M: 21.4 m3/s", .section = .mining, .fields = .snakeCase("", true), .show_field = "enabled", .show_label = "Show the Mining Overlay", .needs_show_text = false },
    .{ .label = "Bounty Rate", .sample = "ISK: 38.2M/h", .section = .bounty, .fields = .snakeCase("", true), .show_field = "enabled", .show_label = "Show the Bounty Overlay", .needs_show_text = false },
    .{ .label = "Resource Usage", .sample = "CPU 12% 1.8G", .section = .resources, .fields = .snakeCase("", true), .show_field = "enabled", .show_label = "Show the Resource Overlay", .needs_show_text = false },
};

pub fn SectionType(comptime section: Section) type {
    return switch (section) {
        .thumbnail => config.ThumbnailConfig,
        .notifications => config.NotificationConfig,
        .combat => config.CombatConfig,
        .mining => config.MiningConfig,
        .bounty => config.BountyConfig,
        .resources => config.ResourcesConfig,
    };
}

pub fn refFor(comptime section: Section) session.Ref(SectionType(section)) {
    const profile = session.profile();
    return switch (section) {
        .thumbnail => profile.child("thumbnail"),
        .notifications => profile.child("thumbnail").child("notifications"),
        .combat => profile.child("combat"),
        .mining => profile.child("mining"),
        .bounty => profile.child("bounty"),
        .resources => profile.child("resources"),
    };
}

/// What the stage needs to draw a chip, read from the edited settings.
pub const Look = struct {
    position: types.TextPosition,
    offset_x: i32,
    offset_y: i32,
    font_size: i32,
    color: u32,
    bg_color: u32,
    is_shown: bool,
};

pub fn look(comptime chip: Chip) Look {
    const ref = refFor(chip.section);
    const thumbnail = &session.profile().ptr.thumbnail;
    const fields = chip.fields;
    const unique = if (chip.unique_field) |field| ref.get(field) else false;
    const enabled = if (chip.enabled_field) |field| ref.get(field) else true;
    return .{
        .position = ref.get(fields.position),
        .offset_x = ref.get(fields.offset_x),
        .offset_y = ref.get(fields.offset_y),
        .font_size = ref.get(fields.font_size),
        // A notification has no text colour of its own; unique colours vary per character, so a sample stands in.
        .color = if (unique) UNIQUE_SAMPLE else if (fields.color) |field| ref.get(field) else 0xFFFFFFFF,
        .bg_color = ref.get(fields.bg_color),
        .is_shown = ref.get(chip.show_field) and enabled and (!chip.needs_show_text or thumbnail.showText),
    };
}

/// Stands in for each character's or system's own colour while a "unique colors" setting is on.
pub const UNIQUE_SAMPLE = 0xFF5EC9C9;

/// Saves a drag's result; `offset_x`/`offset_y` are already clamped to the field's range.
pub fn place(comptime chip: Chip, position: types.TextPosition, offset_x: i32, offset_y: i32) void {
    const ref = refFor(chip.section);
    ref.set(chip.fields.position, position);
    ref.set(chip.fields.offset_x, offset_x);
    ref.set(chip.fields.offset_y, offset_y);
}

/// [min, max] of a chip's offset settings, in real pixels.
pub fn offsetRange(comptime chip: Chip) [2]f32 {
    return bind.rangeOf(SectionType(chip.section), chip.fields.offset_x) orelse .{ -1000, 1000 };
}

/// A chip's popover: whether it's shown, where, its font and its colours. Returns whether its close button was pressed.
pub fn showSettings(context: *ui.Frame, comptime chip: Chip, comptime index: usize) !bool {
    const ref = refFor(chip.section);
    const fields = chip.fields;
    const title = Rect{ .key = .str("knots.chip.title:" ++ chip.label), .style = &style.popover_title };
    _ = try title.open(context);
    try context.e(Text{ .key = .str("knots.chip.heading:" ++ chip.label), .content = chip.label, .style = &style.heading });
    const close_clicked = (try context.interact(Button{ .key = .str("knots.chip.close:" ++ chip.label), .label = "\u{00D7}", .style = &style.popover_close })).clicked;
    try title.close(context);

    try bind.toggle(context, ref, chip.show_field, chip.show_label);
    if (chip.needs_show_text and !session.profile().ptr.thumbnail.showText) {
        try widgets.hintText(context, .str("knots.chip.needs_text:" ++ chip.label), "Hidden while Show Text Overlays is off.");
    }
    if (chip.enabled_field) |field| {
        if (!ref.get(field)) try widgets.hintText(context, .str("knots.chip.needs_enabled:" ++ chip.label), "Hidden until the overlay is enabled on the " ++ chip.enabled_tab ++ " tab.");
    }

    try widgets.subheading(context, .str("knots.chip.place:" ++ chip.label), "Placement");
    const position_before = ref.get(fields.position);
    try bind.choice(context, ref, fields.position, "Position");
    // Picking a spot means that spot, not the spot plus a nudge made from the old one.
    if (ref.get(fields.position) != position_before) {
        ref.set(fields.offset_x, 0);
        ref.set(fields.offset_y, 0);
    }
    const offset_x = ref.get(fields.offset_x);
    const offset_y = ref.get(fields.offset_y);
    if (offset_x != 0 or offset_y != 0) {
        const nudge = try widgets.openBinding(context, .str("knots.chip.nudge:" ++ chip.label), "Nudged By");
        try context.e(Text{
            .key = .str("knots.chip.nudge.value:" ++ chip.label),
            .content = try std.fmt.allocPrint(context.arena(), "{d}, {d} px", .{ offset_x, offset_y }),
            .style = &style.muted_text,
        });
        if ((try context.interact(Button{ .key = .str("knots.chip.nudge.reset:" ++ chip.label), .label = "Reset Nudge", .style = &style.plain_button })).clicked) {
            ref.set(fields.offset_x, 0);
            ref.set(fields.offset_y, 0);
        }
        try nudge.close(context);
    } else {
        try widgets.hintText(context, .str("knots.chip.drag_hint:" ++ chip.label), "Drag the text on the preview to nudge it from this spot.");
    }

    try widgets.subheading(context, .str("knots.chip.font:" ++ chip.label), "Font");
    try bind.fontName(context, ref, fields.font_name, "Font Name");
    try bind.number(context, ref, fields.font_size, "Font Size (px)", .{});
    try bind.choice(context, ref, fields.font_weight, "Font Weight");

    try widgets.subheading(context, .str("knots.chip.colors:" ++ chip.label), "Colors");
    if (chip.unique_field) |field| try bind.toggle(context, ref, field, chip.unique_label);
    const unique = if (chip.unique_field) |field| ref.get(field) else false;
    if (fields.color) |field| {
        if (!unique) try bind.color(context, ref, field, "Text Color");
    }
    try bind.colorAndOpacity(context, ref, fields.bg_color, "Background Color", "Background Opacity");

    if ((try context.interact(Button{
        .key = .str("knots.chip.apply_all:" ++ chip.label),
        .label = "Use This Font and Background for All Texts",
        .style = &style.plain_button,
    })).clicked) {
        copyStyleToOthers(index);
        status.show(.success, "Copied the {s} font and background to the other texts", .{chip.label});
    }
    return close_clicked;
}

fn copyStyleToOthers(comptime source_index: usize) void {
    const source = CHIPS[source_index];
    const from = refFor(source.section);
    inline for (CHIPS, 0..) |chip, index| {
        if (index != source_index) {
            const to = refFor(chip.section);
            to.set(chip.fields.font_name, from.get(source.fields.font_name));
            to.set(chip.fields.font_size, from.get(source.fields.font_size));
            to.set(chip.fields.font_weight, from.get(source.fields.font_weight));
            to.set(chip.fields.bg_color, from.get(source.fields.bg_color));
        }
    }
}
