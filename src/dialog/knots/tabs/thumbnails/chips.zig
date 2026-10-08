//! The texts a thumbnail can show, as chips on the Text Overlays stage: which settings each one reads, and its popover; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../../config.zig");
const types = @import("../../../../config/types.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const overlay_text = @import("../overlay_text.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Fields = overlay_text.Fields;

/// The settings struct a chip's fields live in.
pub const Section = enum { thumbnail, notifications, combat, mining, bounty, resources };

/// One row of a chip's popover.
pub const PopoverField = union(enum) {
    /// A setting of the chip's section; `disables_color` greys out the text colour while it's on.
    toggle: struct { field: []const u8, label: []const u8, disables_color: bool = false },
    /// The chip's text colour, under this label.
    color: []const u8,
    /// Name and size on one row.
    font,
    font_weight,
    /// Colour and opacity on one row.
    background,
};

pub const Chip = struct {
    label: []const u8,
    /// What the stage draws for it.
    sample: []const u8,
    section: Section,
    fields: Fields,
    show_field: []const u8,
    /// The thumbnail's Show Text Overlays has to be on too.
    needs_show_text: bool,
    /// Its section's master switch, e.g. Combat's `enabled`, which has to be on too.
    enabled_field: ?[]const u8 = null,
    unique_field: ?[]const u8 = null,
    /// Driven by the chat and game logs, so its popover says when Log Monitoring is off.
    needs_chatlog: bool = false,
    popover: []const PopoverField,
};

const STYLE_ROWS = [_]PopoverField{ .font, .font_weight, .background };

pub const CHIPS = [_]Chip{
    .{
        .label = "Character Name",
        .sample = "Character Name",
        .section = .thumbnail,
        .fields = .camelCase("characterName"),
        .show_field = "showCharacterName",
        .needs_show_text = true,
        .unique_field = "useUniqueCharacterNameColors",
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showCharacterName", .label = "Show Character Name" } },
            .{ .toggle = .{ .field = "useUniqueCharacterNameColors", .label = "Unique Character Name Colors", .disables_color = true } },
            .{ .color = "Character Name Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "System Name",
        .sample = "Jita",
        .section = .thumbnail,
        .fields = .camelCase("systemName"),
        .show_field = "showSystemName",
        .needs_show_text = true,
        .unique_field = "useUniqueSystemColors",
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showSystemName", .label = "Show System Name" } },
            .{ .toggle = .{ .field = "useUniqueSystemColors", .label = "Unique System Colors", .disables_color = true } },
            .{ .color = "System Name Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Group Badge",
        .sample = "Miners",
        .section = .thumbnail,
        .fields = .camelCase("quickGroupBadge"),
        .show_field = "showQuickGroupBadge",
        .needs_show_text = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showQuickGroupBadge", .label = "Show Group Badge" } },
            .{ .color = "Badge Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Session Timer",
        .sample = "1:42:07",
        .section = .thumbnail,
        .fields = .camelCase("sessionTimer"),
        .show_field = "showSessionTimer",
        .needs_show_text = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showSessionTimer", .label = "Show Session Timer" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Notification",
        .sample = "Fleet Invite",
        .section = .notifications,
        .fields = .snakeCase("", false),
        .show_field = "enabled",
        .needs_show_text = true,
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Notifications" } },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Incoming DPS",
        .sample = "IN: 412",
        .section = .combat,
        .fields = .snakeCase("incoming_", true),
        .show_field = "show_incoming",
        .needs_show_text = true,
        .enabled_field = "enabled",
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Enable Combat Overlays" } },
            .{ .toggle = .{ .field = "show_incoming", .label = "Show Incoming Damage" } },
            .{ .toggle = .{ .field = "incoming_show_prefix", .label = "Show IN: Prefix" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Outgoing DPS",
        .sample = "OUT: 980",
        .section = .combat,
        .fields = .snakeCase("outgoing_", true),
        .show_field = "show_outgoing",
        .needs_show_text = true,
        .enabled_field = "enabled",
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Enable Combat Overlays" } },
            .{ .toggle = .{ .field = "show_outgoing", .label = "Show Outgoing Damage" } },
            .{ .toggle = .{ .field = "outgoing_show_prefix", .label = "Show OUT: Prefix" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Mining Rate",
        .sample = "M: 21.4 m3/s",
        .section = .mining,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Mining Rate" } },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show M: Prefix" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Bounty Rate",
        .sample = "ISK: 38.2M/h",
        .section = .bounty,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .needs_chatlog = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Bounty Rate" } },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show ISK: Prefix" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Resource Usage",
        .sample = "CPU 12% 1.8G",
        .section = .resources,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Resource Usage" } },
            .{ .toggle = .{ .field = "show_cpu", .label = "Show CPU %" } },
            .{ .toggle = .{ .field = "show_ram", .label = "Show RAM" } },
            .{ .toggle = .{ .field = "show_vram", .label = "Show VRAM" } },
            .{ .color = "Text Color" },
        } ++ STYLE_ROWS),
    },
};

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

/// The Text Overlays section's Sync Fonts and Backgrounds; not saved.
pub var g_sync_styling: bool = false;

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

/// A chip's popover with its title, notice and fields; returns whether close was pressed.
pub fn showSettings(context: *ui.Frame, comptime chip: Chip, comptime index: usize) !bool {
    const ref = refFor(chip.section);
    const fields = chip.fields;
    const title = Rect{ .key = .str("knots.chip.title:" ++ chip.label), .style = &style.popover_title };
    _ = try title.open(context);
    try context.e(Text{ .selectable = false, .key = .str("knots.chip.heading:" ++ chip.label), .content = chip.label, .style = &style.heading });
    const close_clicked = (try context.interact(Button{ .key = .str("knots.chip.close:" ++ chip.label), .label = "\u{00D7}", .style = &style.popover_close })).clicked;
    try title.close(context);

    if (chip.needs_chatlog and !session.profile().ptr.chatlog.enabled) {
        try widgets.notice(context, .str("knots.chip.chatlog:" ++ chip.label), "Requires Log Monitoring to be enabled.");
    }

    const font_before = ref.get(fields.font_name);
    const size_before = ref.get(fields.font_size);
    const weight_before = ref.get(fields.font_weight);
    const background_before = ref.get(fields.bg_color);

    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    var color_disabled = false;
    inline for (chip.popover) |row| {
        switch (row) {
            .toggle => |toggle| {
                try bind.toggle(context, ref, toggle.field, toggle.label);
                if (toggle.disables_color and ref.get(toggle.field)) color_disabled = true;
            },
            .color => |label| {
                const color = try widgets.openGroup(context, .str("knots.chip.color:" ++ chip.label), !color_disabled);
                try bind.rgb(context, ref, fields.color.?, label);
                try color.close(context);
            },
            .font => {
                const font = try widgets.openBinding(context, .str("knots.chip.font:" ++ chip.label), "Font");
                try bind.fontBox(context, ref, fields.font_name);
                try bind.unitNumberBox(context, ref, fields.font_size, "px", .{});
                try font.close(context);
            },
            .font_weight => try bind.choice(context, ref, fields.font_weight, "Weight"),
            .background => {
                const background = try widgets.openBinding(context, .str("knots.chip.background:" ++ chip.label), "Background");
                try bind.rgbBox(context, ref, fields.bg_color);
                try bind.alphaBox(context, ref, fields.bg_color);
                try background.close(context);
            },
        }
    }

    const is_restyled = !std.mem.eql(u8, font_before, ref.get(fields.font_name)) or size_before != ref.get(fields.font_size) or
        weight_before != ref.get(fields.font_weight) or background_before != ref.get(fields.bg_color);
    if (g_sync_styling and is_restyled) copyStyleToOthers(index);
    return close_clicked;
}

/// Turning sync on unifies every text to the Character Name's styling.
pub fn syncFromCharacterName() void {
    copyStyleToOthers(0);
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
