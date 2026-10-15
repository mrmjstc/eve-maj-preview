//! The texts a thumbnail can show, as placed on the Appearance tab's thumbnail preview: which settings each one reads, and its popover; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../../config.zig");
const types = @import("../../../../config/types.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const overlay_text = @import("../overlay_text.zig");

const Fields = overlay_text.Fields;

const STYLE_ROWS = [_]PopoverField{ .font, .background };
const WINDOW_HINT = "The rate is averaged over this time.";
const UPDATE_INTERVAL = PopoverField{ .number = .{ .field = "update_interval_ms", .label = "Update Interval", .unit = "s", .shows_seconds = true, .hint = "How often the number on the thumbnail changes." } };
const RATE_WINDOW = PopoverField{ .number = .{ .field = "window_seconds", .label = "Window", .unit = "s", .hint = WINDOW_HINT } };
const NEEDS_LOGS = "Requires Log Monitoring to be enabled.";
const ALERTS_NEED_LOGS = "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.";

pub const CHIPS = [_]Chip{
    .{
        .label = "Character Name",
        .sample = "Pilot Alpha",
        .section = .thumbnail,
        .fields = .camelCase("characterName"),
        .show_field = "showCharacterName",
        .needs_show_text = true,
        .unique_field = "useUniqueCharacterNameColors",
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showCharacterName", .label = "Show Character Name", .hint = "Uses the Display Name when a character has one." } },
            .{ .toggle = .{ .field = "useUniqueCharacterNameColors", .label = "Unique Character Name Colors", .disables_color = true, .hint = "Each character's name gets its own color." } },
            .color,
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
        .chatlog_notice = NEEDS_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "showSystemName", .label = "Show System Name", .hint = "Needs Log Monitoring to know where each character is." } },
            .{ .toggle = .{ .field = "useUniqueSystemColors", .label = "Unique System Colors", .disables_color = true, .hint = "Each system gets its own color; System Colors overrides it." } },
            .color,
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
            .{ .toggle = .{ .field = "showQuickGroupBadge", .label = "Show Group Badge", .hint = "Shows the hotkey group a character is in." } },
            .color,
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
            .{ .toggle = .{ .field = "showSessionTimer", .label = "Show Session Timer", .hint = "How long the character has been logged in." } },
            .color,
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Notification",
        .sample = "Fleet Invite",
        .section = .notifications,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .chatlog_notice = ALERTS_NEED_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Notifications", .hint = "Shows alert text, like Fleet Invite, on the thumbnail." } },
            .color,
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
        .chatlog_notice = NEEDS_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Enable Combat Overlays", .hint = "Turns on both incoming and outgoing damage." } },
            .{ .toggle = .{ .field = "show_incoming", .label = "Show Incoming Damage", .hint = "Damage the character is taking per second." } },
            .{ .toggle = .{ .field = "incoming_show_prefix", .label = "Show IN: Prefix", .hint = "Puts IN: before the number so it's easy to tell apart." } },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .{ .text = .{
                .field = "damage_alert_excluded_weapons",
                .label = "Exclude Weapons",
                .placeholder = "e.g. Smartbomb, Warp Scrambler",
                .hint = "Weapon names to ignore, separated by commas. Stops only the Taking Damage alert; the damage still counts.",
            } },
            .color,
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
        .chatlog_notice = NEEDS_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Enable Combat Overlays", .hint = "Turns on both incoming and outgoing damage." } },
            .{ .toggle = .{ .field = "show_outgoing", .label = "Show Outgoing Damage", .hint = "Damage the character is dealing per second." } },
            .{ .toggle = .{ .field = "outgoing_show_prefix", .label = "Show OUT: Prefix", .hint = "Puts OUT: before the number so it's easy to tell apart." } },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .color,
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Mining Rate",
        .sample = "M: 21.4 m3/s",
        .section = .mining,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .chatlog_notice = NEEDS_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Mining Rate", .hint = "How much the character mines per minute." } },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show M: Prefix", .hint = "Puts M: before the rate so it's easy to tell apart." } },
            .color,
        } ++ STYLE_ROWS),
    },
    .{
        .label = "Bounty Rate",
        .sample = "ISK: 38.2M/h",
        .section = .bounty,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .chatlog_notice = NEEDS_LOGS,
        .popover = &([_]PopoverField{
            .{ .toggle = .{ .field = "enabled", .label = "Show Bounty Rate", .hint = "ISK the character earns from bounties." } },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show ISK: Prefix", .hint = "Puts ISK: before the rate so it's easy to tell apart." } },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .{ .choice = .{ .field = "isk_rate_unit", .label = "ISK Rate Unit", .hint = "Shows ISK earned per minute or per hour." } },
            .color,
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
            .{ .toggle = .{ .field = "enabled", .label = "Show Resource Usage", .hint = "How hard each client is working your PC." } },
            .{ .toggle = .{ .field = "show_cpu", .label = "Show CPU %", .hint = "Just that client's share, not the whole PC's." } },
            .{ .toggle = .{ .field = "show_ram", .label = "Show RAM", .hint = "Just that client's memory, not the whole PC's." } },
            .{ .toggle = .{ .field = "show_vram", .label = "Show VRAM", .hint = "Just that client's video memory, not the whole graphics card's." } },
            UPDATE_INTERVAL,
            .color,
        } ++ STYLE_ROWS),
    },
};

/// The settings struct a chip's fields live in.
pub const Section = enum { thumbnail, notifications, combat, mining, bounty, resources };

/// Number, choice and text rows show only in Advanced Mode; a `hint` is a tooltip on the label.
pub const PopoverField = union(enum) {
    /// A setting of the chip's section; `disables_color` greys out the text colour while it's on.
    toggle: struct { field: []const u8, label: []const u8, disables_color: bool = false, hint: ?[]const u8 = null },
    number: struct { field: []const u8, label: []const u8, unit: []const u8, shows_seconds: bool = false, hint: ?[]const u8 = null },
    choice: struct { field: []const u8, label: []const u8, hint: ?[]const u8 = null },
    text: struct { field: []const u8, label: []const u8, placeholder: []const u8, hint: ?[]const u8 = null },
    /// The chip's text colour.
    color,
    /// Name, size and weight on one row.
    font,
    /// Colour, with an opacity slider row beneath it.
    background,
};

pub const Chip = struct {
    label: []const u8,
    /// What the stage draws for it.
    sample: []const u8,
    section: Section,
    fields: Fields,
    show_field: []const u8,
    /// The Text Overlays section's switch has to be on too.
    needs_show_text: bool,
    /// Its section's master switch, e.g. Combat's `enabled`, which has to be on too.
    enabled_field: ?[]const u8 = null,
    unique_field: ?[]const u8 = null,
    /// What its popover says while Log Monitoring is off; null for a text the logs don't drive.
    chatlog_notice: ?[]const u8 = null,
    popover: []const PopoverField,
};

/// What the stage needs to draw a chip, read from the edited settings.
pub const Look = struct {
    position: types.TextPosition,
    offset_x: i32,
    offset_y: i32,
    font_size: i32,
    font_weight: types.FontWeight,
    color: u32,
    background_color: u32,
    is_shown: bool,
};

/// The Text Overlays section's Sync Fonts and Backgrounds; not saved.
pub var g_should_sync_styling: bool = false;

pub fn look(comptime chip: Chip) Look {
    const ref = refFor(chip.section);
    const thumbnail = &session.profile().ptr.thumbnail;
    const fields = chip.fields;
    const is_unique = if (chip.unique_field) |field| ref.get(field) else false;
    const is_enabled = if (chip.enabled_field) |field| ref.get(field) else true;
    return .{
        .position = ref.get(fields.position),
        .offset_x = ref.get(fields.offset_x),
        .offset_y = ref.get(fields.offset_y),
        .font_size = ref.get(fields.font_size),
        .font_weight = ref.get(fields.font_weight),
        // Unique colours vary per character, so a sample stands in.
        .color = if (is_unique) style.UNIQUE_SAMPLE else if (fields.color) |field| ref.get(field) else 0xFFFFFFFF,
        .background_color = ref.get(fields.bg_color),
        .is_shown = ref.get(chip.show_field) and is_enabled and (!chip.needs_show_text or thumbnail.showText),
    };
}

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
    const close_clicked = try widgets.popoverTitle(context, .str("knots.chip.title:" ++ chip.label), chip.label);

    if (chip.chatlog_notice) |notice| {
        if (!session.profile().ptr.chatlog.enabled) try widgets.notice(context, .str("knots.chip.chatlog:" ++ chip.label), notice);
    }

    const font_before = ref.get(fields.font_name);
    const size_before = ref.get(fields.font_size);
    const weight_before = ref.get(fields.font_weight);
    const background_before = ref.get(fields.bg_color);

    const was_aligned = widgets.useAlignedRows(true);
    defer _ = widgets.useAlignedRows(was_aligned);
    const is_advanced = session.global().get("advancedMode");
    var is_color_disabled = false;
    // Every row after the section's master switch, or the chip's show switch, waits on it.
    var gates: [2]widgets.Group = undefined;
    var gate_count: usize = 0;
    inline for (chip.popover) |row| {
        switch (row) {
            .toggle => |toggle| {
                try bind.toggle(context, ref, toggle.field, toggle.label);
                if (toggle.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ toggle.field), hint);
                if (toggle.disables_color and ref.get(toggle.field)) is_color_disabled = true;
                if (comptime isGate(chip, toggle.field)) {
                    gates[gate_count] = try widgets.openGroup(context, .str("knots.chip.gate:" ++ chip.label ++ ":" ++ toggle.field), ref.get(toggle.field));
                    gate_count += 1;
                }
            },
            .number => |number| if (is_advanced) {
                try bind.number(context, ref, number.field, number.label, .{ .unit = number.unit, .shows_seconds = number.shows_seconds });
                if (number.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ number.field), hint);
            },
            .choice => |choice| if (is_advanced) {
                try bind.choice(context, ref, choice.field, choice.label);
                if (choice.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ choice.field), hint);
            },
            .text => |text| if (is_advanced) {
                try bind.text(context, ref, text.field, text.label, text.placeholder);
                if (text.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ text.field), hint);
            },
            .color => {
                const color = try widgets.openGroup(context, .str("knots.chip.color:" ++ chip.label), !is_color_disabled);
                // Comptime: a chip listing .color without a colour field fails to compile.
                try bind.rgb(context, ref, fields.color.?, "Text Color");
                try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":color"), if (chip.unique_field != null) "Used while unique colors are off." else "The color of this text.");
                try color.close(context);
            },
            .font => {
                const font = try widgets.openBinding(context, .str("knots.chip.font:" ++ chip.label), "Font");
                try bind.fontBox(context, ref, fields.font_name);
                try bind.unitNumberBox(context, ref, fields.font_size, "px", .{});
                try bind.choiceBox(context, ref, fields.font_weight);
                try font.close(context);
                try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":font"), "With Sync Fonts and Backgrounds on, this changes every text.");
            },
            .background => {
                try bind.rgb(context, ref, fields.bg_color, "Background");
                try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":background"), "A box behind the text, so it reads on busy scenes.");
                try bind.alphaSlider(context, ref, fields.bg_color, "Background Opacity");
                try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":background_opacity"), "0% hides the box.");
            },
        }
    }
    while (gate_count > 0) {
        gate_count -= 1;
        try gates[gate_count].close(context);
    }

    const is_restyled = !std.mem.eql(u8, font_before, ref.get(fields.font_name)) or size_before != ref.get(fields.font_size) or
        weight_before != ref.get(fields.font_weight) or background_before != ref.get(fields.bg_color);
    if (g_should_sync_styling and is_restyled) copyStyleToOthers(index);
    return close_clicked;
}

/// Turning sync on unifies every text to the Character Name's styling.
pub fn syncFromCharacterName() void {
    copyStyleToOthers(0);
}

fn SectionType(comptime section: Section) type {
    return switch (section) {
        .thumbnail => config.ThumbnailConfig,
        .notifications => config.NotificationConfig,
        .combat => config.CombatConfig,
        .mining => config.MiningConfig,
        .bounty => config.BountyConfig,
        .resources => config.ResourcesConfig,
    };
}

fn refFor(comptime section: Section) session.Ref(SectionType(section)) {
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

fn isGate(comptime chip: Chip, comptime field: []const u8) bool {
    if (std.mem.eql(u8, field, chip.show_field)) return true;
    const enabled_field = chip.enabled_field orelse return false;
    return std.mem.eql(u8, field, enabled_field);
}
