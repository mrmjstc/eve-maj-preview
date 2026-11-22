//! The texts a thumbnail can show, as placed on the Text Overlays preview: which settings each one reads, and its settings beside the preview; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../../config.zig");
const types = @import("../../../../config/types.zig");
const session = @import("../../session.zig");
const bind = @import("../../bind.zig");
const style = @import("../../style.zig");
const widgets = @import("../../widgets.zig");
const overlay_text = @import("../overlay_text.zig");
const panel_preview = @import("../panel_preview.zig");
const lang = @import("../../../../lang/lang.zig");

const Fields = overlay_text.Fields;

const STYLE_ROWS = [_]Row{ .{ .heading = "Style" }, .sync, .font, .background };
const WINDOW_HINT = "The rate is averaged over this time.";
const UPDATE_INTERVAL: Row = .{ .number = .{ .field = "update_interval_ms", .label = "Update Interval", .unit = "s", .shows_seconds = true, .hint = "How often the number changes.", .tracks = true } };
const RATE_WINDOW: Row = .{ .number = .{ .field = "window_seconds", .label = "Averaging Window", .unit = "s", .hint = WINDOW_HINT, .tracks = true } };
const NEEDS_LOGS = "Requires Log Monitoring to be enabled.";
const ALERTS_NEED_LOGS = "Without Log Monitoring, only alerts for your own actions, like Profile Switch, are shown.";

/// In Part's order.
pub const CHIPS = [_]Chip{
    .{
        .label = "Character Name",
        .sample = "Pilot Alpha",
        .section = .thumbnail,
        .fields = .camelCase("characterName"),
        .show_field = "showCharacterName",
        .needs_show_text = true,
        .unique_field = "useUniqueCharacterNameColors",
        .rows = &([_]Row{
            .{ .heading = "Style" },
            .sync,
            .{
                .toggle = .{
                    .field = "useUniqueCharacterNameColors",
                    .label = "Unique Colors",
                    .disables_color = true,
                    .hint = "Each character's name gets its own color.",
                },
            },
            .font,
            .background,
        }),
    },
    .{
        .label = "System Name",
        .sample = "Jita",
        .section = .thumbnail,
        .fields = .camelCase("systemName"),
        .show_field = "showSystemName",
        .needs_show_text = true,
        .unique_field = "useUniqueSystemColors",
        .sub_gate_field = "showSystemConnections",
        .chatlog_notice = NEEDS_LOGS,
        .rows = &([_]Row{
            .{ .heading = "Style" },
            .sync,
            .{
                .toggle = .{
                    .field = "useUniqueSystemColors",
                    .label = "Unique Colors",
                    .disables_color = true,
                    .hint = "Each system gets its own color; System Colors overrides it.",
                },
            },
            .font,
            .background,
            .{ .heading = "Connections" },
            .{ .toggle = .{ .field = "showSystemConnections", .label = "Show Connections", .hint = "Replaces the name with a small map of the system and those a few gates out." } },
            .{ .number = .{ .field = "systemConnectionJumps", .label = "Connection Jumps", .unit = "jumps", .singular_unit = "jump", .hint = "How many gates out the map reaches; it stops at the region's edge." } },
            .{ .number = .{ .field = "systemConnectionMapWidth", .label = "Map Width", .unit = "px", .hint = "Names that don't fit are left out, so a bigger map shows more." } },
            .{ .number = .{ .field = "systemConnectionMapHeight", .label = "Map Height", .unit = "px" } },
            .{ .toggle = .{ .field = "showSystemConnectionIntel", .label = "Mark Systems With Intel", .hint = "Circles systems named in intel channels, like the map. Needs an intel rule." } },
        }),
    },
    .{
        .label = "Group Badge",
        .sample = "Miners",
        .section = .thumbnail,
        .fields = .camelCase("quickGroupBadge"),
        .show_field = "showQuickGroupBadge",
        .needs_show_text = true,
        .rows = &STYLE_ROWS,
    },
    .{
        .label = "Session Timer",
        .sample = "1:42:07",
        .section = .thumbnail,
        .fields = .camelCase("sessionTimer"),
        .show_field = "showSessionTimer",
        .needs_show_text = true,
        .rows = &STYLE_ROWS,
    },
    .{
        .label = "Alert",
        .sample = "Fleet Invite",
        .section = .alert_text,
        .switch_section = .notifications,
        .fields = .snakeCase("", true),
        .show_field = "enabled",
        .needs_show_text = true,
        .chatlog_notice = ALERTS_NEED_LOGS,
        .rows = &STYLE_ROWS,
    },
    .{
        .label = "Incoming DPS",
        .sample = "IN: 412",
        .section = .combat_text,
        .tracking_section = .combat,
        .fields = .snakeCase("incoming_", true),
        .show_field = "show_incoming",
        .needs_show_text = true,
        .enabled_field = "shown",
        .chatlog_notice = NEEDS_LOGS,
        .rows = &([_]Row{
            .{ .heading = "Content" },
            .{ .toggle = .{ .field = "shown", .label = "Enable Combat Overlays", .hint = "Turns on both incoming and outgoing damage." } },
            .{ .toggle = .{ .field = "incoming_show_prefix", .label = "Show IN: Prefix", .hint = "Puts IN: before the number so it's easy to tell apart." } },
        } ++ STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .{ .text = .{
                .field = "damage_alert_excluded_weapons",
                .label = "Exclude Weapons",
                .placeholder = "e.g. Smartbomb, Warp Scrambler",
                .hint = "Weapon names to ignore, separated by commas. Stops only the Taking Damage alert; the damage still counts.",
                .tracks = true,
            } },
        }),
    },
    .{
        .label = "Outgoing DPS",
        .sample = "OUT: 980",
        .section = .combat_text,
        .tracking_section = .combat,
        .fields = .snakeCase("outgoing_", true),
        .show_field = "show_outgoing",
        .needs_show_text = true,
        .enabled_field = "shown",
        .chatlog_notice = NEEDS_LOGS,
        .rows = &([_]Row{
            .{ .heading = "Content" },
            .{ .toggle = .{ .field = "shown", .label = "Enable Combat Overlays", .hint = "Turns on both incoming and outgoing damage." } },
            .{ .toggle = .{ .field = "outgoing_show_prefix", .label = "Show OUT: Prefix", .hint = "Puts OUT: before the number so it's easy to tell apart." } },
        } ++ STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            RATE_WINDOW,
            UPDATE_INTERVAL,
        }),
    },
    .{
        .label = "Mining Rate",
        .sample = "M: 1,284 m3/hr",
        .section = .mining_text,
        .tracking_section = .mining,
        .fields = .snakeCase("", true),
        .show_field = "shown",
        .needs_show_text = true,
        .sub_gate_field = "show_isk_rate",
        .chatlog_notice = NEEDS_LOGS,
        .rows = &([_]Row{
            .{ .heading = "Content" },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show M: Prefix", .hint = "Puts M: before the rate so it's easy to tell apart." } },
        } ++ STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .{ .segmented = .{ .field = "m3_rate_unit", .label = "m3 Per", .options = &.{ "Minute", "Hour" }, .hint = "Shows m3 mined per minute or per hour.", .tracks = true } },
            .{ .heading = "ISK Rate" },
            .{ .toggle = .{ .field = "show_isk_rate", .label = "Show ISK Rate", .hint = "Uses the Mining tab's ore prices; fetch or enter them first." } },
            .{ .segmented = .{ .field = "isk_rate_unit", .label = "ISK Per", .options = &.{ "Minute", "Hour" }, .hint = "Shows ISK earned per minute or per hour.", .tracks = true } },
        }),
    },
    .{
        .label = "Bounty Rate",
        .sample = "ISK: 38.2m ISK/hr",
        .section = .bounty_text,
        .tracking_section = .bounty,
        .fields = .snakeCase("", true),
        .show_field = "shown",
        .needs_show_text = true,
        .chatlog_notice = NEEDS_LOGS,
        .rows = &([_]Row{
            .{ .heading = "Content" },
            .{ .toggle = .{ .field = "show_prefix", .label = "Show ISK: Prefix", .hint = "Puts ISK: before the rate so it's easy to tell apart." } },
        } ++ STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            RATE_WINDOW,
            UPDATE_INTERVAL,
            .{
                .segmented = .{
                    .field = "isk_rate_unit",
                    .label = "ISK Per",
                    .options = &.{ "Minute", "Hour" },
                    .hint = "Shows ISK earned per minute or per hour.",
                    .tracks = true,
                },
            },
        }),
    },
    .{
        .label = "Resource Usage",
        .sample = "CPU 12% 1.8G",
        .section = .resources_text,
        .tracking_section = .resources,
        .fields = .snakeCase("", true),
        .show_field = "shown",
        .needs_show_text = true,
        .rows = &([_]Row{
            .{ .heading = "Content" },
            .{ .toggle = .{ .field = "show_cpu", .label = "Show CPU %", .hint = "Just that client's share, not the whole PC's." } },
            .{ .toggle = .{ .field = "show_ram", .label = "Show RAM", .hint = "Just that client's memory, not the whole PC's." } },
            .{ .toggle = .{ .field = "show_vram", .label = "Show VRAM", .hint = "Just that client's video memory, not the whole graphics card's." } },
        } ++ STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            UPDATE_INTERVAL,
        }),
    },
    .{
        .label = "Ping",
        .sample = "38 ms",
        .section = .ping_text,
        .tracking_section = .ping,
        .fields = .snakeCase("", true),
        .show_field = "shown",
        .needs_show_text = true,
        .rows = &(STYLE_ROWS ++ [_]Row{
            .{ .heading = "Data" },
            UPDATE_INTERVAL,
        }),
    },
};

/// The texts in CHIPS' order, as the preview's parts.
pub const Part = enum(u8) {
    character_name,
    system_name,
    group_badge,
    session_timer,
    alert,
    incoming_dps,
    outgoing_dps,
    mining_rate,
    bounty_rate,
    resource_usage,
    ping,

    /// Where the part bar starts a new group: Alerts, Rates, then the client's own.
    pub fn startsGroup(self: Part) bool {
        return switch (self) {
            .alert, .incoming_dps, .resource_usage => true,
            .character_name, .system_name, .group_badge, .session_timer, .outgoing_dps, .mining_rate, .bounty_rate, .ping => false,
        };
    }
};

/// The settings struct a chip's fields live in.
pub const Section = enum { thumbnail, notifications, alert_text, combat, combat_text, mining, mining_text, bounty, bounty_text, resources, resources_text, ping, ping_text };

/// One row of a text's settings; a `hint` is a tooltip on the label, and a row that `tracks` binds the chip's tracking_section.
pub const Row = union(enum) {
    /// Starts a group of rows.
    heading: []const u8,
    /// A setting of the chip's section; `disables_color` greys out the colour row while it's on.
    toggle: struct { field: []const u8, label: []const u8, disables_color: bool = false, hint: ?[]const u8 = null },
    number: struct { field: []const u8, label: []const u8, unit: []const u8, singular_unit: ?[]const u8 = null, shows_seconds: bool = false, hint: ?[]const u8 = null, tracks: bool = false },
    /// `options` names each tag in declaration order.
    segmented: struct { field: []const u8, label: []const u8, options: []const []const u8, hint: ?[]const u8 = null, tracks: bool = false },
    text: struct { field: []const u8, label: []const u8, placeholder: []const u8, hint: ?[]const u8 = null, tracks: bool = false },
    /// Same for All Texts, which copies font and background changes to every text.
    sync,
    /// Name and size, then weight, then text colour, each on a row so they fit beside the preview.
    font,
    /// Opacity and colour on one row.
    background,
};

pub const Chip = struct {
    label: []const u8,
    /// What the stage draws for it.
    sample: []const u8,
    section: Section,
    /// Where show_field and the text colour are kept, when not in `section`.
    switch_section: ?Section = null,
    /// Where rows marked `tracks` are kept, when not in `section`.
    tracking_section: ?Section = null,
    fields: Fields,
    /// The switch at the top of its settings.
    show_field: []const u8,
    /// Enable Text Overlays has to be on too.
    needs_show_text: bool,
    /// Its section's master switch, e.g. Combat's `enabled`, which has to be on too.
    enabled_field: ?[]const u8 = null,
    unique_field: ?[]const u8 = null,
    /// A toggle whose later rows wait on it.
    sub_gate_field: ?[]const u8 = null,
    /// What its settings say while Log Monitoring is off; null for a text the logs don't drive.
    chatlog_notice: ?[]const u8 = null,
    rows: []const Row,
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
    /// The switch that has to be turned on for it to show, in English; null while it's shown.
    off_switch: ?[]const u8,
};

/// Same for All Texts; not saved.
pub var g_should_sync_styling: bool = true;

comptime {
    std.debug.assert(CHIPS.len == std.enums.values(Part).len);
}

pub fn look(comptime chip: Chip) Look {
    const ref = refFor(chip.section);
    const switch_ref = switchRef(chip);
    const thumbnail = &session.profile().ptr.thumbnail;
    const fields = chip.fields;
    const is_unique = if (chip.unique_field) |field| ref.get(field) else false;
    const is_enabled = if (chip.enabled_field) |field| ref.get(field) else true;
    const enabled_label: ?[]const u8 = comptime if (chip.enabled_field) |field| toggleLabel(chip, field) else null;
    const off_switch: ?[]const u8 = if (chip.needs_show_text and !thumbnail.showText)
        "Enable Text Overlays"
    else if (!is_enabled)
        enabled_label
    else if (!switch_ref.get(chip.show_field))
        chip.label
    else
        null;
    return .{
        .position = ref.get(fields.position),
        .offset_x = ref.get(fields.offset_x),
        .offset_y = ref.get(fields.offset_y),
        .font_size = ref.get(fields.font_size),
        .font_weight = ref.get(fields.font_weight),
        // Unique colours vary per character, so a sample stands in.
        .color = if (is_unique) style.UNIQUE_SAMPLE else if (fields.color) |field| switch_ref.get(field) else 0xFFFFFFFF,
        .background_color = ref.get(fields.bg_color),
        .off_switch = off_switch,
    };
}

/// What hovering a chip on the stage says, made in `arena`.
pub fn tipText(arena: std.mem.Allocator, off_switch: ?[]const u8) ![]const u8 {
    const how = lang.text("Drag to move, or click to edit.");
    const name = off_switch orelse return how;
    const off = try lang.format(arena, "Off: turn on {name}.", .{ .name = lang.text(name) });
    return std.mem.join(arena, " ", &.{ off, how });
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

/// A chip's settings under the preview or beside it: its name and on switch, its notice, then its rows.
pub fn showSettings(context: *ui.Frame, comptime chip: Chip, comptime index: usize) !void {
    // The search's index draws every tab with it, and they bind some of the same fields, so its rows need keys of their own.
    var ref = refFor(chip.section);
    ref.index = 1;
    var switch_ref = switchRef(chip);
    switch_ref.index = 1;
    var tracking_ref = refFor(chip.tracking_section orelse chip.section);
    tracking_ref.index = 1;
    const fields = chip.fields;
    const title = try panel_preview.openInspectorTitle(context, .str("knots.chip.title:" ++ chip.label), chip.label);
    try bind.toggle(context, switch_ref, chip.show_field, "");
    try title.close(context);

    if (chip.chatlog_notice) |notice| {
        if (!session.global().ptr.chatlog.enabled) try widgets.notice(context, .str("knots.chip.chatlog:" ++ chip.label), notice);
    }

    const font_before = ref.get(fields.font_name);
    const size_before = ref.get(fields.font_size);
    const weight_before = ref.get(fields.font_weight);
    const background_before = ref.get(fields.bg_color);

    var is_color_disabled = false;
    // Every row after the chip's sub-gate waits on it.
    var gate: ?widgets.Group = null;
    inline for (chip.rows) |row| {
        switch (row) {
            .heading => |heading| try widgets.subheading(context, .str("knots.chip.heading:" ++ chip.label ++ ":" ++ heading), heading),
            .toggle => |toggle| {
                try bind.toggle(context, ref, toggle.field, toggle.label);
                if (toggle.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ toggle.field), hint);
                if (toggle.disables_color and ref.get(toggle.field)) is_color_disabled = true;
                if (comptime isSubGate(chip, toggle.field)) gate = try widgets.openGroup(context, .str("knots.chip.gate:" ++ chip.label), ref.get(toggle.field));
            },
            .number => |number| {
                try bind.number(context, if (comptime number.tracks) tracking_ref else ref, number.field, number.label, .{
                    .unit = number.unit,
                    .singular_unit = number.singular_unit,
                    .shows_seconds = number.shows_seconds,
                });
                if (number.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ number.field), hint);
            },
            .segmented => |segmented| {
                try bind.segmented(context, if (comptime segmented.tracks) tracking_ref else ref, segmented.field, segmented.label, segmented.options);
                if (segmented.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ segmented.field), hint);
            },
            .text => |text| {
                try bind.text(context, if (comptime text.tracks) tracking_ref else ref, text.field, text.label, text.placeholder);
                if (text.hint) |hint| try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":" ++ text.field), hint);
            },
            .sync => {
                if (try widgets.checkbox(context, .str("knots.chip.sync:" ++ chip.label), "Same for All Texts", &g_should_sync_styling)) {
                    if (g_should_sync_styling) copyStyleToOthers(index);
                }
                try widgets.hintText(context, .str("knots.chip.sync.hint:" ++ chip.label), "Changing one text's font or background changes them all.");
            },
            .font => {
                const font = try widgets.openWrappingBinding(context, .str("knots.chip.font:" ++ chip.label), "Font");
                try bind.fontNameSize(context, ref, fields.font_name, fields.font_size);
                try font.close(context);
                try bind.choice(context, ref, fields.font_weight, "Weight");
                const color_row = try widgets.openBinding(context, .str("knots.chip.color:" ++ chip.label), "Text Color");
                const color_group = try widgets.openInlineGroup(context, .str("knots.chip.color_group:" ++ chip.label), !is_color_disabled);
                // Comptime: a chip listing .font without a colour field fails to compile.
                try bind.rgbBox(context, switch_ref, fields.color.?);
                try color_group.close(context);
                try color_row.close(context);
                if (chip.unique_field != null) try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":color"), "Used while unique colors are off.");
            },
            .background => {
                try bind.rgbAlpha(context, ref, fields.bg_color, "Background");
                try widgets.hintText(context, .str("knots.chip.hint:" ++ chip.label ++ ":background"), "A box behind the text, so it reads on busy scenes; 0% hides it.");
            },
        }
    }
    if (gate) |group| try group.close(context);

    const is_restyled = !std.mem.eql(u8, font_before, ref.get(fields.font_name)) or size_before != ref.get(fields.font_size) or
        weight_before != ref.get(fields.font_weight) or background_before != ref.get(fields.bg_color);
    if (g_should_sync_styling and is_restyled) copyStyleToOthers(index);
}

fn SectionType(comptime section: Section) type {
    return switch (section) {
        .thumbnail => config.ThumbnailConfig,
        .notifications => config.NotificationConfig,
        .alert_text => config.AlertTextStyle,
        .combat => config.CombatConfig,
        .combat_text => config.CombatTextStyle,
        .mining => config.MiningConfig,
        .mining_text => config.MiningTextStyle,
        .bounty => config.BountyConfig,
        .bounty_text => config.BountyTextStyle,
        .resources => config.ResourcesConfig,
        .resources_text => config.ResourcesTextStyle,
        .ping => config.PingConfig,
        .ping_text => config.PingTextStyle,
    };
}

fn refFor(comptime section: Section) session.Ref(SectionType(section)) {
    const profile = session.profile();
    return switch (section) {
        .thumbnail => profile.child("thumbnail"),
        .notifications => profile.child("notifications"),
        .alert_text => profile.child("thumbnail").child("alertText"),
        .combat => profile.child("combat"),
        .combat_text => profile.child("thumbnail").child("combatText"),
        .mining => profile.child("mining"),
        .mining_text => profile.child("thumbnail").child("miningText"),
        .bounty => profile.child("bounty"),
        .bounty_text => profile.child("thumbnail").child("bountyText"),
        .resources => profile.child("resources"),
        .resources_text => profile.child("thumbnail").child("resourcesText"),
        .ping => profile.child("ping"),
        .ping_text => profile.child("thumbnail").child("pingText"),
    };
}

fn switchRef(comptime chip: Chip) session.Ref(SectionType(chip.switch_section orelse chip.section)) {
    return refFor(chip.switch_section orelse chip.section);
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

/// The label of the chip's toggle for `field`.
fn toggleLabel(comptime chip: Chip, comptime field: []const u8) []const u8 {
    for (chip.rows) |row| switch (row) {
        .toggle => |toggle| if (std.mem.eql(u8, toggle.field, field)) return toggle.label,
        .heading, .number, .segmented, .text, .sync, .font, .background => {},
    };
    @compileError(chip.label ++ " has no toggle for " ++ field);
}

fn isSubGate(comptime chip: Chip, comptime field: []const u8) bool {
    const sub_gate_field = chip.sub_gate_field orelse return false;
    return std.mem.eql(u8, field, sub_gate_field);
}
