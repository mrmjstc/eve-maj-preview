//! The Map Panel's words: its tooltips, legends, titles and labels; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const list_look = @import("../list_look.zig");
const look = @import("look.zig");
const panel_look = @import("../panel_look.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const storms_mod = @import("../../map/storms.zig");
const campaigns_mod = @import("../../map/campaigns.zig");
const wormholes_mod = @import("../../map/wormholes.zig");
const faction_warfare = @import("../../map/faction_warfare.zig");
const zkill = @import("../../map/zkill.zig");
const incursions_mod = @import("../../map/incursions.zig");
const layout = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const evestars = @import("../../map/evestars.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const utf8 = @import("../../util/utf8.zig");

const Campaign = campaigns_mod.Campaign;
const Campaigns = campaigns_mod.Campaigns;
const Bridges = evestars.Bridges;
const Kill = zkill.Kill;
const KillNames = zkill.Names;
const Connections = wormholes_mod.Connections;
const FixedText = fixed_text.FixedText;
const Incursions = incursions_mod.Incursions;
const MapMetric = types.MapMetric;
const RegionIndex = universe.RegionIndex;
const Snapshot = stats_mod.Snapshot;
const Storms = storms_mod.Storms;
const SystemIndex = universe.SystemIndex;

/// The most lines a tooltip holds, for a system with everything to report, two overlapping storms included.
pub const TOOLTIP_MAX_LINES = 14;
/// Fits a line's longest text, cut to size past that.
pub const TOOLTIP_LINE_MAX = 128;
/// Below a legend's title and scale.
const LEGEND_MAX_ROWS = 6;
/// The rows of a range's legend left to name regions, past its total and what the rest sum to.
const RANGE_LEGEND_REGIONS = LEGEND_MAX_ROWS - 2;
/// Past this, a line of who's in a system stops naming them.
const MAX_CHARACTERS_NAMED = 4;
/// Fits securityText's longest result.
pub const SECURITY_TEXT_MAX = 8;
/// A count of systems, in a legend or a tooltip.
const SYSTEMS_FORMAT = "{d} systems";
/// The widest a sov timer's text under a name gets, for the room names keep for it.
pub const TIMER_TEXT_SAMPLES = [_][]const u8{ "23h 59m", "99d 23h", "def 100%" };
/// What a legend sums up past the ones it names.
const OTHERS_TEXT = "Others";

/// What the map's colours mean, drawn in its bottom left.
pub const Legend = struct {
    title: FixedText,
    /// Empty for none; static.
    ramp: []const u32 = &.{},
    ramp_low: FixedText = .{},
    ramp_high: FixedText = .{},
    rows: [LEGEND_MAX_ROWS]Row = undefined,
    row_count: usize = 0,

    pub const Row = struct {
        swatch: u32,
        text: FixedText,
        /// Right-aligned beside `text`; empty for none.
        value: FixedText = .{},
        /// Swatched like the tinted area it marks on the map, rather than solid like a marker.
        is_area: bool = false,
    };

    fn add(self: *Legend, row: Row) void {
        if (self.row_count == LEGEND_MAX_ROWS) return;
        self.rows[self.row_count] = row;
        self.row_count += 1;
    }
};

/// What a system's tooltip reports; its slices are borrowed for the call.
pub const SystemFacts = struct {
    system: SystemIndex,
    /// Null until the first fetch.
    stats: ?*const Snapshot = null,
    characters: []const []const u8 = &.{},
    /// Null without a live intel pin.
    intel_message: ?[]const u8 = null,
    intel_age_ms: u64 = 0,
    is_intel_clear: bool = false,
    is_avoided: bool = false,
    /// Null with no jump range showing.
    reach: ?*const jump_range.Reach = null,
    /// Null while they're hidden or unknown.
    storms: ?*const Storms = null,
    /// Null while they're hidden or unknown.
    incursions: ?*const Incursions = null,
    /// Null while they're hidden or unknown.
    campaigns: ?*const Campaigns = null,
    /// Null while they're hidden or unknown.
    wormholes: ?*const Connections = null,
    /// Null while they're hidden or unknown.
    bridges: ?*const Bridges = null,
    /// Seconds since 1970, UTC, for a sov timer's countdown.
    now_seconds: i64 = 0,
};

/// Formats as the regions' names joined by " + "; borrows `regions`.
const RegionNames = struct {
    regions: []const RegionIndex,

    pub fn format(self: RegionNames, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.regions, 0..) |region, index| {
            if (index > 0) try writer.writeAll(" + ");
            try writer.writeAll(universe.regionName(region));
        }
    }
};

/// A title over lines of text; owns them, so it can be measured and then drawn.
pub const Tooltip = struct {
    lines: [TOOLTIP_MAX_LINES][TOOLTIP_LINE_MAX]u8 = undefined,
    lengths: [TOOLTIP_MAX_LINES]usize = undefined,
    /// Each line's label, in a column before its text; empty for none; static.
    labels: [TOOLTIP_MAX_LINES][]const u8 = undefined,
    colors: [TOOLTIP_MAX_LINES]u32 = undefined,
    line_count: usize = 0,
    /// The first line's colour.
    title_color: u32 = list_look.NAME,
    /// After the title in `accent_color`, like a system's security; empty for none.
    accent: FixedText = .{},
    accent_color: u32 = list_look.NAME,
    /// Muted, flush right of the title, like a system's region; empty for none.
    aside: FixedText = .{},

    pub fn line(self: *const Tooltip, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    pub fn label(self: *const Tooltip, index: usize) []const u8 {
        return self.labels[index];
    }

    pub fn lineColor(self: *const Tooltip, index: usize) u32 {
        return if (index == 0) self.title_color else self.colors[index];
    }

    /// Set when any line has a label, which draws it as a card: a heavier title over a rule, and the labels in a column.
    pub fn isDetailed(self: *const Tooltip) bool {
        for (self.labels[0..self.line_count]) |line_label| {
            if (line_label.len > 0) return true;
        }
        return false;
    }

    /// The first is the title.
    fn add(self: *Tooltip, comptime format: []const u8, args: anytype) void {
        self.addColoredRow("", list_look.NAME, format, args);
    }

    fn addRow(self: *Tooltip, comptime row_label: []const u8, comptime format: []const u8, args: anytype) void {
        self.addColoredRow(row_label, list_look.NAME, format, args);
    }

    /// Per hover, and bounded: a long line is cut, which the reader can see.
    fn addColoredRow(self: *Tooltip, comptime row_label: []const u8, row_color: u32, comptime format: []const u8, args: anytype) void {
        if (self.line_count == TOOLTIP_MAX_LINES) return;
        var writer: std.Io.Writer = .fixed(&self.lines[self.line_count]);
        writer.print(format, args) catch {};
        const written = writer.buffered();
        self.lengths[self.line_count] = utf8.prefixLength(written, if (written.len == TOOLTIP_LINE_MAX) TOOLTIP_LINE_MAX - 1 else written.len);
        self.labels[self.line_count] = row_label;
        self.colors[self.line_count] = row_color;
        self.line_count += 1;
    }
};

pub fn metricLabel(metric: MapMetric) []const u8 {
    return switch (metric) {
        .Security => "Security",
        .ShipKills => "Kills",
        .PodKills => "Pods",
        .NpcKills => "NPC",
        .NpcDelta => "NPC delta",
        .Jumps => "Jumps",
        .Sovereignty => "Sov",
        .FactionWarfare => "FW",
    };
}

pub fn toggleLabel(toggle: look.Toggle) []const u8 {
    return switch (toggle) {
        .layers => "Layers",
        .follow => "Follow",
    };
}

pub fn layerLabel(layer: look.Layer) []const u8 {
    return switch (layer) {
        .storms => "Storms",
        .incursions => "Incursions",
        .sov_timers => "Sov Timers",
        .wormholes => "Thera & Turnur",
        .ansiblex => "Ansiblex Gates",
        .kills => "zKillboard Kills",
        .intel => "Intel",
        .names => "Character Names",
    };
}

pub fn systemTooltip(facts: SystemFacts) Tooltip {
    var tooltip: Tooltip = .{};
    const info = universe.systemInfo(facts.system);
    tooltip.add("{s}", .{universe.systemName(facts.system)});
    var security_buf: [SECURITY_TEXT_MAX]u8 = undefined;
    tooltip.accent = .print("{s}", .{securityText(&security_buf, info.security_tenths)});
    tooltip.accent_color = look.securityTextColor(info.security_tenths);
    tooltip.aside = .print("{s}", .{universe.regionName(info.region)});
    tooltip.addRow("Constellation", "{s}", .{universe.constellationName(info.constellation)});

    if (facts.stats) |snapshot| {
        const stats = snapshot.systems[facts.system];
        if (snapshot.has_kills) {
            tooltip.addRow("Ship kills", "{d} ships, {d} pods", .{ stats.ship_kills, stats.pod_kills });
            if (snapshot.has_npc_delta) {
                tooltip.addRow("NPC kills", "{d}, {s}{d} on the hour before", .{ stats.npc_kills, if (stats.npc_delta > 0) "+" else "", stats.npc_delta });
            } else {
                tooltip.addRow("NPC kills", "{d}", .{stats.npc_kills});
            }
        }
        if (snapshot.has_jumps) tooltip.addRow("Jumps", "{d}", .{stats.jumps});
        if (snapshot.holderName(facts.system)) |holder| tooltip.addRow("Sovereignty", "{s}", .{holder});
        if (snapshot.has_warfare) addWarfare(&tooltip, snapshot.warfare[facts.system]);
    }
    tooltip.addRow("Planets", "{d} planets, {d} stations", .{ info.planet_count, info.station_count });
    if (facts.is_avoided) tooltip.addRow("Routes", "Avoided", .{});
    if (facts.reach) |reach| addRange(&tooltip, reach, facts.system);
    if (facts.storms) |storms| addStorms(&tooltip, storms, facts.system);
    if (facts.incursions) |incursions| addIncursion(&tooltip, incursions, facts.system);
    if (facts.campaigns) |campaigns| addCampaign(&tooltip, campaigns, facts.stats, facts.system, facts.now_seconds);
    if (facts.wormholes) |connections| addWormholes(&tooltip, connections, facts.system);
    if (facts.bridges) |bridges| addBridges(&tooltip, bridges, facts.system);

    addCharacters(&tooltip, facts.characters);
    if (facts.intel_message) |message| {
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        tooltip.addColoredRow("Intel", look.intelColor(facts.is_intel_clear), "{s}: {s}", .{ panel_look.relativeTime(&age_buf, facts.intel_age_ms), message });
    }
    return tooltip;
}

/// `reach` is null with no jump range showing, and `storms`, `incursions` and `campaigns` while they're hidden or unknown.
pub fn regionTooltip(region: RegionIndex, system_count: usize, client_count: usize, reach: ?*const jump_range.Reach, storms: ?*const Storms, incursions: ?*const Incursions, campaigns: ?*const Campaigns) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(region)});
    tooltip.addRow("Systems", "{d}", .{system_count});
    if (client_count > 0) tooltip.addRow("Characters", "{d}", .{client_count});
    if (reach) |shown| tooltip.addRow("Jump range", SYSTEMS_FORMAT, .{shown.region_counts[region]});
    if (storms) |reported| {
        for (reported.slice()) |*storm| {
            if (universe.systemInfo(storm.center).region == region) tooltip.addColoredRow("Storm", look.stormColor(storm.kind), "{s} at {s}", .{ stormName(storm.kind), universe.systemName(storm.center) });
        }
    }
    if (incursions) |reported| {
        for (reported.slice()) |*incursion| {
            if (universe.systemInfo(incursion.staging).region == region) tooltip.addColoredRow("Incursion", look.INCURSION, "Staging at {s}", .{universe.systemName(incursion.staging)});
        }
    }
    if (campaigns) |reported| {
        var count: usize = 0;
        for (reported.slice()) |*campaign| count += @intFromBool(universe.systemInfo(campaign.system).region == region);
        if (count > 0) tooltip.addColoredRow("Sov timers", look.SOV_TIMER, "{d}", .{count});
    }
    return tooltip;
}

/// What shows beside a name: the time to its start, then the defender's score once it runs.
pub fn timerText(campaign: *const Campaign, now_seconds: i64) FixedText {
    if (campaign.hasStarted(now_seconds)) return .print("def {d}%", .{campaign.defender_percent});
    return countdownText(campaign.start_seconds - now_seconds);
}

pub fn securityLegend() Legend {
    return .{ .title = .print("Security", .{}), .ramp = &look.SECURITY_SCALE, .ramp_low = .print("-1.0", .{}), .ramp_high = .print("1.0", .{}) };
}

pub fn heatLegend(metric: MapMetric, peak: u32, has_stats: bool) Legend {
    var legend: Legend = .{ .title = .print("{s}", .{switch (metric) {
        .Security, .Sovereignty, .FactionWarfare => "",
        .ShipKills => "Ship kills",
        .PodKills => "Pod kills",
        .NpcKills => "NPC kills",
        .NpcDelta => "NPC delta",
        .Jumps => "Jumps",
    }}) };
    if (!has_stats) {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("Waiting for figures", .{}) });
    } else if (peak == 0) {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("None on the map", .{}) });
    } else {
        legend.ramp = &look.HEAT_RAMP;
        legend.ramp_low = .print("1", .{});
        legend.ramp_high = .print("{d}", .{peak});
    }
    return legend;
}

/// NPC kills' change on the hour, from the steepest fall to the steepest rise among those shown, `peak`; `has_delta` once two hours were seen.
pub fn deltaLegend(peak: u32, has_delta: bool) Legend {
    var legend: Legend = .{ .title = .print("NPC delta", .{}) };
    if (!has_delta) {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("Waiting for a second hour", .{}) });
    } else if (peak == 0) {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("No change on the map", .{}) });
    } else {
        legend.ramp = &look.DELTA_RAMP;
        legend.ramp_low = .print("-{d}", .{peak});
        legend.ramp_high = .print("+{d}", .{peak});
    }
    return legend;
}

/// Null `snapshot` until the first fetch.
pub fn sovereigntyLegend(ranks: *const look.HolderRanks, snapshot: ?*const Snapshot) Legend {
    var legend: Legend = .{ .title = .print("Sovereignty", .{}) };
    const stats = snapshot orelse {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("Waiting for figures", .{}) });
        return legend;
    };
    const named_count = @min(ranks.count, LEGEND_MAX_ROWS - 2);
    for (ranks.holders[0..named_count], 0..) |ranked, index| {
        const name = stats.holder_names.items[ranked.holder];
        legend.add(.{ .swatch = ranks.colors[index], .text = .print("{s}", .{if (name.len > 0) name else "Unknown"}), .value = .print("{d}", .{ranked.system_count}) });
    }
    var other_count = ranks.other_count;
    for (ranks.holders[named_count..ranks.count]) |ranked| other_count += ranked.system_count;
    if (other_count > 0) legend.add(.{ .swatch = list_look.MUTED, .text = .print(OTHERS_TEXT, .{}), .value = .print("{d}", .{other_count}) });
    if (ranks.unclaimed_count > 0) legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("Unclaimed", .{}), .value = .print("{d}", .{ranks.unclaimed_count}) });
    return legend;
}

/// The occupiers of any of `nodes`, most systems first, with how far each system's contested as a ramp; null `snapshot` until the first fetch.
pub fn warfareLegend(snapshot: ?*const Snapshot, nodes: []const layout.Node) Legend {
    var legend: Legend = .{ .title = .print("Faction warfare", .{}) };
    const stats = snapshot orelse {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("Waiting for figures", .{}) });
        return legend;
    };
    var counts: [faction_warfare.FACTIONS.len + 1]usize = @splat(0);
    for (nodes) |node| counts[stats.warfare[node.system].occupier] += 1;
    if (std.mem.allEqual(usize, counts[1..], 0)) {
        legend.add(.{ .swatch = look.HEAT_NONE, .text = .print("No warzone on the map", .{}) });
        return legend;
    }
    legend.ramp = &look.WARFARE_RAMP;
    legend.ramp_low = .print("Calm", .{});
    legend.ramp_high = .print("Contested", .{});
    var places: [faction_warfare.FACTIONS.len]u8 = undefined;
    for (&places, 1..) |*place, index| place.* = @intCast(index);
    std.mem.sort(u8, &places, &counts, occupiesMore);
    for (places) |place| {
        if (counts[place] == 0) break;
        legend.add(.{ .swatch = look.factionColorOf(place), .text = .print("{s}", .{faction_warfare.faction(place).name}), .value = .print("{d}", .{counts[place]}) });
    }
    return legend;
}

/// The regions it reaches, most systems first, as the map shows only a few of them.
pub fn rangeLegend(reach: *const jump_range.Reach) Legend {
    var legend: Legend = .{ .title = .print("{s} from {s}", .{ jump_range.shipName(reach.ship), universe.systemName(reach.origin) }) };
    const range = jump_range.rangeLightYears(reach.ship);
    if (reach.count == 0) {
        legend.add(.{ .swatch = look.OUT_OF_RANGE, .text = .print("No systems within {d:.1} ly", .{range}) });
        return legend;
    }
    legend.add(.{ .swatch = look.RANGE, .text = .print("Within {d:.1} ly", .{range}), .value = .print(SYSTEMS_FORMAT, .{reach.count}) });

    var order: [universe.REGION_COUNT]RegionIndex = undefined;
    for (&order, 0..) |*region, index| region.* = @intCast(index);
    std.mem.sort(RegionIndex, &order, reach, reachesMore);
    var named_count: usize = 0;
    for (order[0..RANGE_LEGEND_REGIONS]) |region| {
        const count = reach.region_counts[region];
        if (count == 0) break;
        legend.add(.{ .swatch = look.RANGE, .text = .print("{s}", .{universe.regionName(region)}), .value = .print("{d}", .{count}) });
        named_count += count;
    }
    if (named_count < reach.count) legend.add(.{ .swatch = list_look.MUTED, .text = .print(OTHERS_TEXT, .{}), .value = .print("{d}", .{reach.count - named_count}) });
    return legend;
}

/// The storms reaching any of `nodes`, credited as EVE-Scout's terms aren't stated; null with none.
pub fn stormLegend(storms: *const Storms, nodes: []const layout.Node) ?Legend {
    var legend: Legend = .{ .title = .print("Storms, from EVE-Scout", .{}) };
    for (storms.slice()) |*storm| {
        for (nodes) |node| {
            if (storm.zoneOf(node.system) == null) continue;
            legend.add(.{ .swatch = look.stormColor(storm.kind), .text = .print("{s}", .{stormName(storm.kind)}), .value = .print("{s}, {d}h", .{ universe.systemName(storm.center), storm.hours_in_system }), .is_area = true });
            break;
        }
    }
    return if (legend.row_count > 0) legend else null;
}

/// The incursions reaching any of `nodes`; null with none.
pub fn incursionLegend(incursions: *const Incursions, nodes: []const layout.Node) ?Legend {
    var legend: Legend = .{ .title = .print("Incursions", .{}) };
    for (incursions.slice()) |*incursion| {
        for (nodes) |node| {
            if (!incursion.infested.isSet(node.system)) continue;
            legend.add(.{ .swatch = look.INCURSION, .text = .print("{s}", .{universe.systemName(incursion.staging)}), .value = .print("{s}, {d}%", .{ incursionStateName(incursion.state), incursion.influence_percent }), .is_area = true });
            break;
        }
    }
    return if (legend.row_count > 0) legend else null;
}

/// `name` is the first of those in a system, and the others follow as a count.
pub fn clientTagText(name: []const u8, other_count: usize) FixedText {
    return if (other_count > 0) .print("{s} +{d}", .{ name, other_count }) else .print("{s}", .{name});
}

/// As the game shows it, e.g. "0.5" or "-0.4"; `buffer` holds what's returned.
pub fn securityText(buffer: *[SECURITY_TEXT_MAX]u8, security_tenths: i8) []const u8 {
    const magnitude = @abs(security_tenths);
    const sign = if (security_tenths < 0) "-" else "";
    return std.fmt.bufPrint(buffer, "{s}{d}.{d}", .{ sign, magnitude / 10, magnitude % 10 }) catch unreachable;
}

/// The system a gate to a region not shown leads to, and the region it's in.
pub fn exitLabel(exit: layout.Exit) FixedText {
    return .print("{s} - {s}", .{ universe.systemName(exit.destination), universe.regionName(exit.region) });
}

pub fn exitTooltip(from: SystemIndex, destination: SystemIndex) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(universe.systemInfo(destination).region)});
    tooltip.addRow("Gate", "{s} to {s}", .{ universe.systemName(from), universe.systemName(destination) });
    tooltip.addColoredRow("", list_look.MUTED, "Ctrl+click to show it alongside", .{});
    return tooltip;
}

/// What a map showing `regions` is called.
pub fn regionsTitle(regions: []const RegionIndex) FixedText {
    return .print("{f}", .{RegionNames{ .regions = regions }});
}

pub fn mapControlTooltip(control: look.MapControl, is_always_on_top: bool) Tooltip {
    var tooltip: Tooltip = .{};
    switch (control) {
        .zoom_in => tooltip.add("Zoom in", .{}),
        .zoom_out => tooltip.add("Zoom out", .{}),
        .fit => tooltip.add("Reset zoom", .{}),
        .always_on_top => tooltip.add("Always on Top: {s}", .{if (is_always_on_top) "On" else "Off"}),
    }
    return tooltip;
}

pub fn noticeTooltip(notice: *const evestars.Notice) Tooltip {
    var tooltip: Tooltip = .{ .title_color = if (notice.is_failure) look.INTEL else list_look.NAME };
    for (0..notice.line_count) |index| tooltip.add("{s}", .{notice.line(index)});
    return tooltip;
}

/// A hub's name, or the far end's for an Ansiblex gate.
pub fn portalLabel(target: layout.PortalTarget) []const u8 {
    return switch (target) {
        .hub => |hub| hubName(hub),
        .system => |system| universe.systemName(system),
    };
}

/// The gate from `from` to `to`, and whether it's one way.
pub fn bridgeTooltip(bridges: *const Bridges, from: SystemIndex, to: SystemIndex) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.systemName(to)});
    tooltip.aside = .print("{s}", .{universe.regionName(universe.systemInfo(to).region)});
    const way = if (bridges.isTwoWay(.{ .from = from, .to = to })) "both ways" else "one way";
    tooltip.addColoredRow("Ansiblex", look.ANSIBLEX, "{s} to {s}, {s}", .{ universe.systemName(from), universe.systemName(to), way });
    tooltip.addColoredRow("", list_look.MUTED, "Ctrl+click to show its region alongside", .{});
    return tooltip;
}

/// As short as the wormhole card's rows need: "S", "M", "L", "XL" or "Cap".
pub fn shipSizeShort(size: wormholes_mod.ShipSize) []const u8 {
    return switch (size) {
        .small => "S",
        .medium => "M",
        .large => "L",
        .xlarge => "XL",
        .capital => "Cap",
        .unknown => "?",
    };
}

pub fn hubName(hub: wormholes_mod.Hub) []const u8 {
    return switch (hub) {
        .thera => "Thera",
        .turnur => "Turnur",
    };
}

/// Each of `system`'s connections to `hub`: its signatures, the largest ship it takes and how long it has left.
pub fn portalTooltip(connections: *const Connections, system: SystemIndex, hub: wormholes_mod.Hub) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{hubName(hub)});
    tooltip.aside = .print("from {s}", .{universe.systemName(system)});
    for (connections.slice()) |*connection| {
        if (connection.system != system or connection.hub != hub) continue;
        tooltip.addColoredRow("Signatures", look.WORMHOLE, "{s} here, {s} in {s}", .{ signatureText(&connection.signature), signatureText(&connection.hub_signature), hubName(hub) });
        tooltip.addRow("Ship size", "{s}, about {d}h left", .{ shipSizeName(connection.ship_size), connection.remaining_hours });
    }
    return tooltip;
}

/// Borrows from `names`.
pub fn killShipName(names: ?*const KillNames, kill: *const Kill) []const u8 {
    const known = names orelse return "Unknown ship";
    return known.get(kill.ship_type_id) orelse "Unknown ship";
}

/// The victim's alliance or corporation; empty while unknown; borrows from `names`.
pub fn killVictimName(names: ?*const KillNames, kill: *const Kill) []const u8 {
    const known = names orelse return "";
    return known.get(kill.victim_id) orelse "";
}

/// "4m ago"; `buffer` holds what's returned.
pub fn killAge(buffer: *[panel_look.TIME_TEXT_MAX]u8, kill: *const Kill, now_seconds: i64) []const u8 {
    return panel_look.relativeTime(buffer, @as(u64, @intCast(@max(0, now_seconds - kill.time_seconds))) * std.time.ms_per_s);
}

fn campaignKindName(kind: campaigns_mod.Kind) []const u8 {
    return switch (kind) {
        .ihub_defense => "Sov hub defense",
        .tcu_defense => "TCU defense",
        .station_defense => "Station defense",
        .station_freeport => "Station freeport",
        .other => "Sov campaign",
    };
}

fn occupiesMore(counts: *const [faction_warfare.FACTIONS.len + 1]usize, first: u8, second: u8) bool {
    if (counts[first] != counts[second]) return counts[first] > counts[second];
    return first < second;
}

/// Who occupies a warzone system, how far it's contested, and who owns it when that's another.
fn addWarfare(tooltip: *Tooltip, system: faction_warfare.System) void {
    if (system.occupier == faction_warfare.NO_FACTION) return;
    const occupier = faction_warfare.faction(system.occupier).name;
    const shade = look.factionColorOf(system.occupier);
    switch (system.state) {
        .vulnerable => tooltip.addColoredRow("Warfare", shade, "{s}, vulnerable", .{occupier}),
        .captured => tooltip.addColoredRow("Warfare", shade, "{s}, captured", .{occupier}),
        .uncontested, .contested => tooltip.addColoredRow("Warfare", shade, "{s}, {d}% contested", .{ occupier, system.contested_percent }),
    }
    if (system.owner != system.occupier) tooltip.addRow("Owned by", "{s}", .{faction_warfare.faction(system.owner).name});
}

/// "45m", "2h 10m" or "1d 4h"; at least a minute.
fn countdownText(seconds: i64) FixedText {
    const minutes = @max(1, @divFloor(seconds + std.time.s_per_min - 1, std.time.s_per_min));
    if (minutes < 60) return .print("{d}m", .{minutes});
    const hours = @divFloor(minutes, 60);
    if (hours < 24) return .print("{d}h {d:0>2}m", .{ hours, @mod(minutes, 60) });
    return .print("{d}d {d}h", .{ @divFloor(hours, 24), @mod(hours, 24) });
}

fn incursionStateName(state: incursions_mod.State) []const u8 {
    return switch (state) {
        .established => "Established",
        .mobilizing => "Mobilizing",
        .withdrawing => "Withdrawing",
    };
}

fn shipSizeName(size: wormholes_mod.ShipSize) []const u8 {
    return switch (size) {
        .small => "Small",
        .medium => "Medium",
        .large => "Large",
        .xlarge => "Extra large",
        .capital => "Capital",
        .unknown => "Unknown",
    };
}

fn signatureText(signature: *const FixedText) []const u8 {
    return if (signature.length > 0) signature.slice() else "unscanned";
}

/// A line a hub `system` links to, and for Turnur itself how many link to it.
fn addWormholes(tooltip: *Tooltip, connections: *const Connections, system: SystemIndex) void {
    if (universe.systemInfo(system).id == wormholes_mod.TURNUR_ID) tooltip.addColoredRow("Wormholes", look.WORMHOLE, "{d} connections from Turnur", .{connections.countTo(.turnur)});
    for (connections.slice()) |*connection| {
        if (connection.system != system) continue;
        tooltip.addColoredRow("Wormhole", look.WORMHOLE, "{s} via {s}, {s}, {d}h left", .{ hubName(connection.hub), signatureText(&connection.signature), shipSizeName(connection.ship_size), connection.remaining_hours });
    }
}

/// A line a gate out of `system`.
fn addBridges(tooltip: *Tooltip, bridges: *const Bridges, system: SystemIndex) void {
    for (bridges.slice()) |bridge| {
        if (bridge.from != system) continue;
        tooltip.addColoredRow("Ansiblex", look.ANSIBLEX, "To {s}{s}", .{ universe.systemName(bridge.to), if (bridges.isTwoWay(bridge)) "" else ", one way" });
    }
}

fn stormName(kind: storms_mod.Kind) []const u8 {
    return switch (kind) {
        .electric => "Electric",
        .exotic => "Exotic",
        .gamma => "Gamma Ray",
        .plasma => "Plasma",
    };
}

fn reachesMore(reach: *const jump_range.Reach, first: RegionIndex, second: RegionIndex) bool {
    const first_count = reach.region_counts[first];
    const second_count = reach.region_counts[second];
    if (first_count != second_count) return first_count > second_count;
    return first < second;
}

/// Distances to two places, as one just past the range would round to it at one.
fn addRange(tooltip: *Tooltip, reach: *const jump_range.Reach, system: SystemIndex) void {
    if (system == reach.origin) {
        tooltip.addRow("Jump range", "{s}, from here", .{jump_range.shipName(reach.ship)});
        return;
    }
    const is_reached = reach.includes(system);
    const why_not = if (is_reached) "" else if (jump_range.acceptsJumps(system)) ", out of range" else ", no cyno possible";
    tooltip.addColoredRow("Jump range", if (is_reached) list_look.NAME else list_look.MUTED, "{d:.2} ly from {s}{s}", .{ jump_range.distanceLightYears(reach.origin, system), universe.systemName(reach.origin), why_not });
}

/// One line a storm, as overlapping ones both apply.
fn addStorms(tooltip: *Tooltip, storms: *const Storms, system: SystemIndex) void {
    for (storms.slice()) |*storm| {
        const zone = storm.zoneOf(system) orelse continue;
        const name = stormName(storm.kind);
        const center = universe.systemName(storm.center);
        const storm_color = look.stormColor(storm.kind);
        switch (zone) {
            .center => tooltip.addColoredRow("Storm", storm_color, "{s}, centered here, reported {d}h ago", .{ name, storm.hours_in_system }),
            .core => tooltip.addColoredRow("Storm", storm_color, "{s} core, centered on {s}", .{ name, center }),
            .periphery => tooltip.addColoredRow("Storm", storm_color, "{s} periphery, centered on {s}", .{ name, center }),
        }
    }
}

/// A constellation holds one incursion at most, so the first found is the only one.
fn addIncursion(tooltip: *Tooltip, incursions: *const Incursions, system: SystemIndex) void {
    for (incursions.slice()) |*incursion| {
        if (!incursion.infested.isSet(system)) continue;
        const state = incursionStateName(incursion.state);
        if (incursion.staging == system) {
            tooltip.addColoredRow("Incursion", look.INCURSION, "Staging here: {s}, {d}% influence", .{ state, incursion.influence_percent });
        } else {
            tooltip.addColoredRow("Incursion", look.INCURSION, "Staged from {s}: {s}, {d}% influence", .{ universe.systemName(incursion.staging), state, incursion.influence_percent });
        }
        return;
    }
}

/// `stats` names the defender, null until the first fetch.
fn addCampaign(tooltip: *Tooltip, campaigns: *const Campaigns, stats: ?*const Snapshot, system: SystemIndex, now_seconds: i64) void {
    const campaign = campaigns.soonestIn(system) orelse return;
    const kind = campaignKindName(campaign.kind);
    if (campaign.hasStarted(now_seconds)) {
        tooltip.addColoredRow("Sov timer", look.SOV_TIMER, "{s}, running: defender {d}%, attackers {d}%", .{ kind, campaign.defender_percent, campaign.attackers_percent });
    } else {
        tooltip.addColoredRow("Sov timer", look.SOV_TIMER, "{s}, starts in {s}", .{ kind, countdownText(campaign.start_seconds - now_seconds).slice() });
    }
    const snapshot = stats orelse return;
    if (snapshot.allianceName(campaign.defender_id)) |defender| tooltip.addRow("Defender", "{s}", .{defender});
}

fn addCharacters(tooltip: *Tooltip, characters: []const []const u8) void {
    if (characters.len == 0) return;
    if (characters.len > MAX_CHARACTERS_NAMED) {
        tooltip.addRow("Here", "{d} characters", .{characters.len});
        return;
    }
    var names_buf: [TOOLTIP_LINE_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&names_buf);
    for (characters, 0..) |name, index| {
        writer.print("{s}{s}", .{ if (index == 0) "" else ", ", name }) catch {};
    }
    tooltip.addRow("Here", "{s}", .{writer.buffered()});
}

const testing = std.testing;

const STORM_REPLY =
    \\[{"observation_type":"gamma_a","observation_category":"storm","hours_in_system":17,"system_id":30000439}]
;
const INCURSION_REPLY =
    \\[{"infested_solar_systems":[30000142,30000144],"influence":0.5,"staging_solar_system_id":30000142,"state":"mobilizing"}]
;

const CAMPAIGN_REPLY =
    \\[{"attackers_score":0.4,"defender_id":99,"defender_score":0.6,"event_type":"ihub_defense","solar_system_id":30000142,"start_time":"2026-11-09T22:00:00Z"}]
;

test "the always on top control's tooltip gives its state, as a plain line" {
    try testing.expect(!mapControlTooltip(.always_on_top, true).isDetailed());
    try testing.expectEqualStrings("Always on Top: On", mapControlTooltip(.always_on_top, true).line(0));
    try testing.expectEqualStrings("Always on Top: Off", mapControlTooltip(.always_on_top, false).line(0));
}

test "the sovereignty legend sums up what it doesn't name" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    var ranks: look.HolderRanks = .{ .colors = @splat(0), .unclaimed_count = 2 };
    ranks.count = ranks.holders.len;
    for (&ranks.holders, 0..) |*ranked, index| {
        ranked.* = .{ .holder = @intCast(index), .system_count = 3 };
        try snapshot.holder_ids.append(testing.allocator, @intCast(index));
        try snapshot.holder_names.append(testing.allocator, "");
    }
    const legend = sovereigntyLegend(&ranks, &snapshot);
    try testing.expectEqual(@as(usize, LEGEND_MAX_ROWS), legend.row_count);
    try testing.expectEqualStrings("Unknown", legend.rows[0].text.slice());
    try testing.expectEqualStrings("3", legend.rows[0].value.slice());
    try testing.expectEqualStrings("Others", legend.rows[LEGEND_MAX_ROWS - 2].text.slice());
    try testing.expectEqualStrings("18", legend.rows[LEGEND_MAX_ROWS - 2].value.slice());
    try testing.expectEqualStrings("Unclaimed", legend.rows[LEGEND_MAX_ROWS - 1].text.slice());
    try testing.expectEqualStrings("2", legend.rows[LEGEND_MAX_ROWS - 1].value.slice());
}

test "the delta legend waits for a second hour, then spans the largest change" {
    try testing.expectEqualStrings("Waiting for a second hour", deltaLegend(0, false).rows[0].text.slice());
    const legend = deltaLegend(12, true);
    try testing.expectEqualStrings("-12", legend.ramp_low.slice());
    try testing.expectEqualStrings("+12", legend.ramp_high.slice());
}

test "a heat legend says why it has no scale" {
    try testing.expectEqualStrings("Waiting for figures", heatLegend(.ShipKills, 0, false).rows[0].text.slice());
    try testing.expectEqualStrings("None on the map", heatLegend(.ShipKills, 0, true).rows[0].text.slice());
    const legend = heatLegend(.Jumps, 40, true);
    try testing.expectEqualStrings("Jumps", legend.title.slice());
    try testing.expectEqualStrings("40", legend.ramp_high.slice());
}

test "an exit's label names the system it leads to and its region" {
    const jita = universe.findSystem("Jita").?;
    const exit: layout.Exit = .{ .from_index = 0, .destination = jita, .region = universe.systemInfo(jita).region, .x = 0, .y = 0 };
    try testing.expectEqualStrings("Jita - The Forge", exitLabel(exit).slice());
}

test "a map of several regions is titled with all their names" {
    const forge = universe.systemInfo(universe.findSystem("Jita").?).region;
    const domain = universe.systemInfo(universe.findSystem("Amarr").?).region;
    try testing.expectEqualStrings("The Forge", regionsTitle(&.{forge}).slice());
    try testing.expectEqualStrings("The Forge + Domain", regionsTitle(&.{ forge, domain }).slice());
}

test "a client tag counts the others in the system" {
    try testing.expectEqualStrings("Alpha", clientTagText("Alpha", 0).slice());
    try testing.expectEqualStrings("Alpha +2", clientTagText("Alpha", 2).slice());
}

test "a system's tooltip reports what's known about it" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const jita = universe.findSystem("Jita").?;
    try snapshot.applyKills("[{\"npc_kills\":40,\"pod_kills\":2,\"ship_kills\":7,\"system_id\":30000142}]");

    const tooltip = systemTooltip(.{ .system = jita, .stats = &snapshot, .characters = &.{"Bravo"}, .intel_message = "hostile", .intel_age_ms = 300_000 });
    try testing.expectEqualStrings("Jita", tooltip.line(0));
    try testing.expectEqualStrings("0.9", tooltip.accent.slice());
    try testing.expectEqualStrings("The Forge", tooltip.aside.slice());
    try testing.expectEqualStrings("Constellation", tooltip.label(1));
    try testing.expectEqualStrings("Kimotoro", tooltip.line(1));
    try testing.expectEqualStrings("7 ships, 2 pods", tooltip.line(2));
    try testing.expectEqualStrings("40", tooltip.line(3));
    try testing.expectEqualStrings("Bravo", tooltip.line(5));
    try testing.expectEqualStrings("Intel", tooltip.label(6));
    try testing.expectEqualStrings("5m ago: hostile", tooltip.line(6));
    try testing.expect(tooltip.isDetailed());
}

test "a tooltip without stats leaves those lines out" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").? });
    try testing.expectEqual(@as(usize, 3), tooltip.line_count);
}

test "a system's tooltip says when routes avoid it" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .is_avoided = true });
    try testing.expectEqualStrings("Avoided", tooltip.line(tooltip.line_count - 1));
}

test "many characters are counted rather than named" {
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .characters = &names });
    try testing.expectEqualStrings("5 characters", tooltip.line(tooltip.line_count - 1));
}

test "a system's tooltip says how far it is from a jump range's origin, and why it's out" {
    const origin = universe.findSystem("1DQ1-A").?;
    const titan: jump_range.Reach = .measure(origin, .titan);
    try testing.expectEqualStrings("Titan, from here", systemTooltip(.{ .system = origin, .reach = &titan }).line(3));
    try testing.expectEqualStrings("0.51 ly from 1DQ1-A", systemTooltip(.{ .system = universe.findSystem("8WA-Z6").?, .reach = &titan }).line(3));
    try testing.expectEqualStrings("6.46 ly from 1DQ1-A, out of range", systemTooltip(.{ .system = universe.findSystem("UEXO-Z").?, .reach = &titan }).line(3));
    const lowsec: jump_range.Reach = .measure(universe.findSystem("Amamake").?, .titan);
    try testing.expectEqualStrings("0.86 ly from Amamake, no cyno possible", systemTooltip(.{ .system = universe.findSystem("Osoggur").?, .reach = &lowsec }).line(3));
}

test "a range's legend gives the total, the biggest regions and sums up the rest" {
    const reach: jump_range.Reach = .measure(universe.findSystem("1DQ1-A").?, .jump_freighter);
    const legend = rangeLegend(&reach);
    try testing.expectEqualStrings("Jump Freighter from 1DQ1-A", legend.title.slice());
    try testing.expectEqualStrings("Within 10.0 ly", legend.rows[0].text.slice());
    try testing.expect(std.mem.endsWith(u8, legend.rows[0].value.slice(), " systems"));
    try testing.expect(legend.row_count >= 2);
    try testing.expect(legend.row_count <= LEGEND_MAX_ROWS);
}

test "a range with nothing in it says so" {
    var reach: jump_range.Reach = .{ .origin = universe.findSystem("Jita").?, .ship = .titan };
    reach.count = 0;
    try testing.expectEqualStrings("No systems within 6.0 ly", rangeLegend(&reach).rows[0].text.slice());
}

test "a region's tooltip counts what's in jump range only while one shows" {
    const reach: jump_range.Reach = .measure(universe.findSystem("1DQ1-A").?, .titan);
    const region = universe.systemInfo(reach.origin).region;
    try testing.expectEqual(@as(usize, 2), regionTooltip(region, 10, 0, null, null, null, null).line_count);
    try testing.expectEqual(@as(usize, 3), regionTooltip(region, 10, 0, &reach, null, null, null).line_count);
}

test "a system's tooltip names the storm over it and how it stands" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const center = storms.storms[0].center;
    var links = universe.neighbours(center);
    try testing.expectEqualStrings("Gamma Ray, centered here, reported 17h ago", systemTooltip(.{ .system = center, .storms = &storms }).line(3));
    try testing.expectEqualStrings("Gamma Ray core, centered on OEG-K9", systemTooltip(.{ .system = links.next().?, .storms = &storms }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Jita").?, .storms = &storms }).line_count);
}

test "a region's tooltip names the storms centred in it" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const region = universe.systemInfo(storms.storms[0].center).region;
    try testing.expectEqualStrings("Gamma Ray at OEG-K9", regionTooltip(region, 10, 0, null, &storms, null, null).line(2));
}

test "the storm legend lists what reaches the map, and is absent without any" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const nearby = [_]layout.Node{.{ .system = storms.storms[0].center, .x = 0, .y = 0 }};
    const row = stormLegend(&storms, &nearby).?.rows[0];
    try testing.expectEqualStrings("Gamma Ray", row.text.slice());
    try testing.expectEqualStrings("OEG-K9, 17h", row.value.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Jita").?, .x = 0, .y = 0 }};
    try testing.expect(stormLegend(&storms, &distant) == null);
}

test "a system's tooltip says how it stands in an incursion" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const jita = universe.findSystem("Jita").?;
    try testing.expectEqualStrings("Staging here: Mobilizing, 50% influence", systemTooltip(.{ .system = jita, .incursions = &incursions }).line(3));
    try testing.expectEqualStrings("Staged from Jita: Mobilizing, 50% influence", systemTooltip(.{ .system = universe.findSystemById(30000144).?, .incursions = &incursions }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Amarr").?, .incursions = &incursions }).line_count);
}

test "a region's tooltip names the incursions staging in it" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const region = universe.systemInfo(incursions.incursions[0].staging).region;
    try testing.expectEqualStrings("Staging at Jita", regionTooltip(region, 10, 0, null, null, &incursions, null).line(2));
}

test "the incursion legend lists what reaches the map, and is absent without any" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const nearby = [_]layout.Node{.{ .system = incursions.incursions[0].staging, .x = 0, .y = 0 }};
    const row = incursionLegend(&incursions, &nearby).?.rows[0];
    try testing.expectEqualStrings("Jita", row.text.slice());
    try testing.expectEqualStrings("Mobilizing, 50%", row.value.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Amarr").?, .x = 0, .y = 0 }};
    try testing.expect(incursionLegend(&incursions, &distant) == null);
}

test "a timer counts down to its start, then gives the defender's score" {
    const campaigns: Campaigns = try .parse(testing.allocator, CAMPAIGN_REPLY);
    const start = campaigns.campaigns[0].start_seconds;
    try testing.expectEqualStrings("45m", timerText(&campaigns.campaigns[0], start - 45 * 60).slice());
    try testing.expectEqualStrings("1m", timerText(&campaigns.campaigns[0], start - 5).slice());
    try testing.expectEqualStrings("2h 05m", timerText(&campaigns.campaigns[0], start - (2 * 60 + 5) * 60).slice());
    try testing.expectEqualStrings("1d 4h", timerText(&campaigns.campaigns[0], start - 28 * 3600).slice());
    try testing.expectEqualStrings("def 60%", timerText(&campaigns.campaigns[0], start).slice());
}

test "a system's tooltip gives its sov timer and defender" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applyCampaigns(CAMPAIGN_REPLY);
    try snapshot.applyNames("[{\"id\":99,\"name\":\"Defenders\"}]");
    const jita = universe.findSystem("Jita").?;
    const start = snapshot.campaigns.campaigns[0].start_seconds;
    const upcoming = systemTooltip(.{ .system = jita, .stats = &snapshot, .campaigns = &snapshot.campaigns, .now_seconds = start - 600 });
    try testing.expectEqualStrings("Sov hub defense, starts in 10m", upcoming.line(upcoming.line_count - 2));
    try testing.expectEqualStrings("Defenders", upcoming.line(upcoming.line_count - 1));
    const running = systemTooltip(.{ .system = jita, .campaigns = &snapshot.campaigns, .now_seconds = start });
    try testing.expectEqualStrings("Sov hub defense, running: defender 60%, attackers 40%", running.line(running.line_count - 1));
}

test "a portal's tooltip lists each connection between its system and hub" {
    var connections: Connections = .{};
    try connections.add(testing.allocator, "[{\"in_system_id\":30000205,\"in_signature\":\"UQL-360\",\"out_signature\":\"WJF-372\",\"max_ship_size\":\"large\",\"remaining_hours\":3},{\"in_system_id\":30000205}]", .thera);
    const obe = universe.findSystemById(30000205).?;
    const tooltip = portalTooltip(&connections, obe, .thera);
    try testing.expectEqualStrings("Thera", tooltip.line(0));
    try testing.expectEqualStrings("UQL-360 here, WJF-372 in Thera", tooltip.line(1));
    try testing.expectEqualStrings("Large, about 3h left", tooltip.line(2));
    try testing.expectEqualStrings("unscanned here, unscanned in Thera", tooltip.line(3));
    try testing.expectEqualStrings("Thera via UQL-360, Large, 3h left", systemTooltip(.{ .system = obe, .wormholes = &connections }).line(3));
}

test "a system's tooltip lists its Ansiblex gates, and a bridge's tooltip says which way it goes" {
    var bridges: Bridges = .{ .is_ready = true };
    const jita = universe.findSystem("Jita").?;
    const amarr = universe.findSystem("Amarr").?;
    bridges.bridges[0] = .{ .from = jita, .to = amarr };
    bridges.count = 1;
    const tooltip = systemTooltip(.{ .system = jita, .bridges = &bridges });
    try testing.expectEqualStrings("To Amarr, one way", tooltip.line(tooltip.line_count - 1));
    try testing.expectEqualStrings("Jita to Amarr, one way", bridgeTooltip(&bridges, jita, amarr).line(1));
    bridges.bridges[1] = .{ .from = amarr, .to = jita };
    bridges.count = 2;
    try testing.expectEqualStrings("Jita to Amarr, both ways", bridgeTooltip(&bridges, jita, amarr).line(1));
}

test "Turnur's tooltip counts its connections" {
    var connections: Connections = .{};
    try connections.add(testing.allocator, "[{\"in_system_id\":30000205},{\"in_system_id\":30000142}]", .turnur);
    const turnur = universe.findSystemById(wormholes_mod.TURNUR_ID).?;
    try testing.expectEqualStrings("2 connections from Turnur", systemTooltip(.{ .system = turnur, .wormholes = &connections }).line(3));
}

test "a warzone system's tooltip names its occupier, contest and owner" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    try snapshot.applyWarfare("[{\"contested\":\"contested\",\"occupier_faction_id\":500003,\"owner_faction_id\":500002,\"solar_system_id\":30002957,\"victory_points\":37500,\"victory_points_threshold\":75000}]");
    const system = universe.findSystemById(30002957).?;
    const tooltip = systemTooltip(.{ .system = system, .stats = &snapshot });
    try testing.expectEqualStrings("Amarr Empire, 50% contested", tooltip.line(tooltip.line_count - 3));
    try testing.expectEqualStrings("Minmatar Republic", tooltip.line(tooltip.line_count - 2));
}

test "the warfare legend lists the occupiers on the map, most systems first" {
    var snapshot: Snapshot = try .init(testing.allocator);
    defer snapshot.deinit();
    const nodes = [_]layout.Node{ .{ .system = 0, .x = 0, .y = 0 }, .{ .system = 1, .x = 0, .y = 0 }, .{ .system = 2, .x = 0, .y = 0 } };
    try testing.expectEqualStrings("No warzone on the map", warfareLegend(&snapshot, &nodes).rows[0].text.slice());
    snapshot.warfare[0] = .{ .occupier = 4 };
    snapshot.warfare[1] = .{ .occupier = 1 };
    snapshot.warfare[2] = .{ .occupier = 1 };
    const legend = warfareLegend(&snapshot, &nodes);
    try testing.expectEqual(@as(usize, 2), legend.row_count);
    try testing.expectEqualStrings("Caldari State", legend.rows[0].text.slice());
    try testing.expectEqualStrings("2", legend.rows[0].value.slice());
}

test "a long intel line is cut to its buffer" {
    const message: [TOOLTIP_LINE_MAX * 2]u8 = @splat('x');
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .intel_message = &message });
    try testing.expectEqual(TOOLTIP_LINE_MAX - 1, tooltip.line(tooltip.line_count - 1).len);
}

test "securityText reads as the game shows it" {
    var buffer: [SECURITY_TEXT_MAX]u8 = undefined;
    try testing.expectEqualStrings("0.5", securityText(&buffer, 5));
    try testing.expectEqualStrings("1.0", securityText(&buffer, 10));
    try testing.expectEqualStrings("-0.4", securityText(&buffer, -4));
}
