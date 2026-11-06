//! The Map Panel's words: its tooltips, legends, titles and labels; no I/O.
const std = @import("std");
const types = @import("../../config/types.zig");
const list_look = @import("../list_look.zig");
const look = @import("look.zig");
const panel_look = @import("../panel_look.zig");
const universe = @import("../../map/universe.zig");
const jump_range = @import("../../map/jump_range.zig");
const storms_mod = @import("../../map/storms.zig");
const incursions_mod = @import("../../map/incursions.zig");
const layout = @import("../../map/layout.zig");
const stats_mod = @import("../../map/stats.zig");
const evestars = @import("../../map/evestars.zig");
const fixed_text = @import("../../util/fixed_text.zig");
const utf8 = @import("../../util/utf8.zig");

const FixedText = fixed_text.FixedText;
const Incursions = incursions_mod.Incursions;
const MapMetric = types.MapMetric;
const RegionIndex = universe.RegionIndex;
const Snapshot = stats_mod.Snapshot;
const Storms = storms_mod.Storms;
const SystemIndex = universe.SystemIndex;

/// The most lines a tooltip holds, for a system with everything to report, two overlapping storms included.
pub const TOOLTIP_MAX_LINES = 13;
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
/// A region's size, in its tooltip and its summary.
const SYSTEMS_FORMAT = "{d} systems";
/// What a legend sums up past the ones it names.
const OTHERS_FORMAT = "Others ({d})";

/// The figures for the last hour of the systems shown.
pub const RegionTotals = struct {
    ship_kills: u32 = 0,
    npc_kills: u32 = 0,
    jumps: u32 = 0,

    pub fn fromNodes(snapshot: *const Snapshot, nodes: []const layout.Node) RegionTotals {
        var totals: RegionTotals = .{};
        for (nodes) |node| {
            const stats = snapshot.systems[node.system];
            totals.ship_kills += stats.ship_kills;
            totals.npc_kills += stats.npc_kills;
            totals.jumps += stats.jumps;
        }
        return totals;
    }
};

/// What the map's colours mean, drawn in its bottom left.
pub const Legend = struct {
    title: FixedText,
    /// Empty for none; static.
    ramp: []const u32 = &.{},
    ramp_low: FixedText = .{},
    ramp_high: FixedText = .{},
    rows: [LEGEND_MAX_ROWS]Row = undefined,
    row_count: usize = 0,

    pub const Row = struct { swatch: u32, text: FixedText };

    fn add(self: *Legend, swatch: u32, text: FixedText) void {
        if (self.row_count == LEGEND_MAX_ROWS) return;
        self.rows[self.row_count] = .{ .swatch = swatch, .text = text };
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
    is_avoided: bool = false,
    /// Null with no jump range showing.
    reach: ?*const jump_range.Reach = null,
    /// Null while they're hidden or unknown.
    storms: ?*const Storms = null,
    /// Null while they're hidden or unknown.
    incursions: ?*const Incursions = null,
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

/// Lines of text; owns them, so it can be measured and then drawn.
pub const Tooltip = struct {
    lines: [TOOLTIP_MAX_LINES][TOOLTIP_LINE_MAX]u8 = undefined,
    lengths: [TOOLTIP_MAX_LINES]usize = undefined,
    line_count: usize = 0,
    /// The first line's colour.
    title_color: u32 = list_look.NAME,

    pub fn line(self: *const Tooltip, index: usize) []const u8 {
        return self.lines[index][0..self.lengths[index]];
    }

    /// Per hover, and bounded: a long line is cut, which the reader can see.
    fn add(self: *Tooltip, comptime format: []const u8, args: anytype) void {
        if (self.line_count == TOOLTIP_MAX_LINES) return;
        var writer: std.Io.Writer = .fixed(&self.lines[self.line_count]);
        writer.print(format, args) catch {};
        const written = writer.buffered();
        self.lengths[self.line_count] = utf8.prefixLength(written, if (written.len == TOOLTIP_LINE_MAX) TOOLTIP_LINE_MAX - 1 else written.len);
        self.line_count += 1;
    }
};

pub fn buttonLabel(button: look.Button) []const u8 {
    return switch (button) {
        .regions => "Regions",
        .security => "Sec",
        .kills => "Kills",
        .npc_kills => "NPC",
        .jumps => "Jumps",
        .sovereignty => "Sov",
        .storms => "Storms",
        .incursions => "Incursions",
        .follow => "Follow",
    };
}

pub fn systemTooltip(facts: SystemFacts) Tooltip {
    var tooltip: Tooltip = .{};
    const info = universe.systemInfo(facts.system);
    tooltip.title_color = look.securityTextColor(info.security_tenths);
    var security_buf: [SECURITY_TEXT_MAX]u8 = undefined;
    tooltip.add("{s}  {s}", .{ universe.systemName(facts.system), securityText(&security_buf, info.security_tenths) });
    tooltip.add("{s} / {s}", .{ universe.regionName(info.region), universe.constellationName(info.constellation) });

    if (facts.stats) |snapshot| {
        const stats = snapshot.systems[facts.system];
        if (snapshot.has_kills) tooltip.add("Last hour: {d} ships, {d} pods, {d} NPCs", .{ stats.ship_kills, stats.pod_kills, stats.npc_kills });
        if (snapshot.has_jumps) tooltip.add("Last hour: {d} jumps", .{stats.jumps});
        if (snapshot.holderName(facts.system)) |holder| tooltip.add("Held by {s}", .{holder});
    }
    tooltip.add("{d} stations, {d} planets", .{ info.station_count, info.planet_count });
    if (facts.is_avoided) tooltip.add("Routes avoid this system", .{});
    if (facts.reach) |reach| addRange(&tooltip, reach, facts.system);
    if (facts.storms) |storms| addStorms(&tooltip, storms, facts.system);
    if (facts.incursions) |incursions| addIncursion(&tooltip, incursions, facts.system);

    addCharacters(&tooltip, facts.characters);
    if (facts.intel_message) |message| {
        var age_buf: [panel_look.TIME_TEXT_MAX]u8 = undefined;
        tooltip.add("Intel {s}: {s}", .{ panel_look.relativeTime(&age_buf, facts.intel_age_ms), message });
    }
    return tooltip;
}

/// `reach` is null with no jump range showing, and `storms` and `incursions` while they're hidden or unknown.
pub fn regionTooltip(region: RegionIndex, system_count: usize, client_count: usize, reach: ?*const jump_range.Reach, storms: ?*const Storms, incursions: ?*const Incursions) Tooltip {
    var tooltip: Tooltip = .{};
    tooltip.add("{s}", .{universe.regionName(region)});
    tooltip.add(SYSTEMS_FORMAT, .{system_count});
    if (client_count > 0) tooltip.add("{d} {s} here", .{ client_count, if (client_count == 1) "character" else "characters" });
    if (reach) |shown| tooltip.add("{d} in jump range", .{shown.region_counts[region]});
    if (storms) |reported| {
        for (reported.slice()) |*storm| {
            if (universe.systemInfo(storm.center).region == region) tooltip.add("{s} Storm at {s}", .{ stormName(storm.kind), universe.systemName(storm.center) });
        }
    }
    if (incursions) |reported| {
        for (reported.slice()) |*incursion| {
            if (universe.systemInfo(incursion.staging).region == region) tooltip.add("Incursion staging at {s}", .{universe.systemName(incursion.staging)});
        }
    }
    return tooltip;
}

pub fn regionSummary(system_count: usize, totals: ?RegionTotals) FixedText {
    const known = totals orelse return .print(SYSTEMS_FORMAT, .{system_count});
    return .print("{d} systems, {d} ship kills, {d} NPC kills, {d} jumps last hour", .{ system_count, known.ship_kills, known.npc_kills, known.jumps });
}

pub fn securityLegend() Legend {
    return .{ .title = .print("Security", .{}), .ramp = &look.SECURITY_SCALE, .ramp_low = .print("-1.0", .{}), .ramp_high = .print("1.0", .{}) };
}

pub fn heatLegend(metric: MapMetric, peak: u32, has_stats: bool) Legend {
    var legend: Legend = .{ .title = .print("{s}, last hour", .{switch (metric) {
        .Security, .Sovereignty => "",
        .ShipKills => "Ship kills",
        .NpcKills => "NPC kills",
        .Jumps => "Jumps",
    }}) };
    if (!has_stats) {
        legend.add(look.HEAT_NONE, .print("Waiting for figures", .{}));
    } else if (peak == 0) {
        legend.add(look.HEAT_NONE, .print("None on the map", .{}));
    } else {
        legend.ramp = &look.HEAT_RAMP;
        legend.ramp_low = .print("1", .{});
        legend.ramp_high = .print("{d}", .{peak});
    }
    return legend;
}

/// Null `snapshot` until the first fetch.
pub fn sovereigntyLegend(ranks: *const look.HolderRanks, snapshot: ?*const Snapshot) Legend {
    var legend: Legend = .{ .title = .print("Sovereignty", .{}) };
    const stats = snapshot orelse {
        legend.add(look.HEAT_NONE, .print("Waiting for figures", .{}));
        return legend;
    };
    const named_count = @min(ranks.count, LEGEND_MAX_ROWS - 2);
    for (ranks.holders[0..named_count], 0..) |ranked, index| {
        const name = stats.holder_names.items[ranked.holder];
        legend.add(ranks.colors[index], .print("{s} ({d})", .{ if (name.len > 0) name else "Unknown", ranked.system_count }));
    }
    var other_count = ranks.other_count;
    for (ranks.holders[named_count..ranks.count]) |ranked| other_count += ranked.system_count;
    if (other_count > 0) legend.add(list_look.MUTED, .print(OTHERS_FORMAT, .{other_count}));
    if (ranks.unclaimed_count > 0) legend.add(look.HEAT_NONE, .print("Unclaimed ({d})", .{ranks.unclaimed_count}));
    return legend;
}

/// The regions it reaches, most systems first, as the map shows only a few of them.
pub fn rangeLegend(reach: *const jump_range.Reach) Legend {
    var legend: Legend = .{ .title = .print("{s} from {s}", .{ jump_range.shipName(reach.ship), universe.systemName(reach.origin) }) };
    const range = jump_range.rangeLightYears(reach.ship);
    if (reach.count == 0) {
        legend.add(look.OUT_OF_RANGE, .print("No systems within {d:.1} ly", .{range}));
        return legend;
    }
    legend.add(look.RANGE, .print("{d} systems within {d:.1} ly", .{ reach.count, range }));

    var order: [universe.REGION_COUNT]RegionIndex = undefined;
    for (&order, 0..) |*region, index| region.* = @intCast(index);
    std.mem.sort(RegionIndex, &order, reach, reachesMore);
    var named_count: usize = 0;
    for (order[0..RANGE_LEGEND_REGIONS]) |region| {
        const count = reach.region_counts[region];
        if (count == 0) break;
        legend.add(look.RANGE, .print("{s} ({d})", .{ universe.regionName(region), count }));
        named_count += count;
    }
    if (named_count < reach.count) legend.add(list_look.MUTED, .print(OTHERS_FORMAT, .{reach.count - named_count}));
    return legend;
}

/// The storms reaching any of `nodes`, credited as EVE-Scout's terms aren't stated; null with none.
pub fn stormLegend(storms: *const Storms, nodes: []const layout.Node) ?Legend {
    var legend: Legend = .{ .title = .print("Storms (EVE-Scout)", .{}) };
    for (storms.slice()) |*storm| {
        for (nodes) |node| {
            if (storm.zoneOf(node.system) == null) continue;
            legend.add(look.stormColor(storm.kind), .print("{s}: {s}, {d}h ago", .{ stormName(storm.kind), universe.systemName(storm.center), storm.hours_in_system }));
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
            legend.add(look.INCURSION, .print("{s}: {s}, {d}% influence", .{ universe.systemName(incursion.staging), incursionStateName(incursion.state), incursion.influence_percent }));
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
    tooltip.add("{s} to {s}", .{ universe.systemName(from), universe.systemName(destination) });
    tooltip.add("Ctrl+click to show it alongside", .{});
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

fn incursionStateName(state: incursions_mod.State) []const u8 {
    return switch (state) {
        .established => "Established",
        .mobilizing => "Mobilizing",
        .withdrawing => "Withdrawing",
    };
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
        tooltip.add("{s} jump range from here", .{jump_range.shipName(reach.ship)});
        return;
    }
    const distance = jump_range.distanceLightYears(reach.origin, system);
    const origin = universe.systemName(reach.origin);
    if (reach.includes(system)) {
        tooltip.add("{d:.2} ly from {s}", .{ distance, origin });
    } else if (jump_range.acceptsJumps(system)) {
        tooltip.add("{d:.2} ly from {s}, out of range", .{ distance, origin });
    } else {
        tooltip.add("{d:.2} ly from {s}, no cyno possible", .{ distance, origin });
    }
}

/// One line a storm, as overlapping ones both apply.
fn addStorms(tooltip: *Tooltip, storms: *const Storms, system: SystemIndex) void {
    for (storms.slice()) |*storm| {
        const zone = storm.zoneOf(system) orelse continue;
        const name = stormName(storm.kind);
        const center = universe.systemName(storm.center);
        switch (zone) {
            .center => tooltip.add("{s} Storm centered here, reported {d}h ago", .{ name, storm.hours_in_system }),
            .core => tooltip.add("{s} Storm core, centered on {s}", .{ name, center }),
            .periphery => tooltip.add("{s} Storm periphery, centered on {s}", .{ name, center }),
        }
    }
}

/// A constellation holds one incursion at most, so the first found is the only one.
fn addIncursion(tooltip: *Tooltip, incursions: *const Incursions, system: SystemIndex) void {
    for (incursions.slice()) |*incursion| {
        if (!incursion.infested.isSet(system)) continue;
        const state = incursionStateName(incursion.state);
        if (incursion.staging == system) {
            tooltip.add("Incursion staging here: {s}, {d}% influence", .{ state, incursion.influence_percent });
        } else {
            tooltip.add("Incursion staged from {s}: {s}, {d}% influence", .{ universe.systemName(incursion.staging), state, incursion.influence_percent });
        }
        return;
    }
}

fn addCharacters(tooltip: *Tooltip, characters: []const []const u8) void {
    if (characters.len == 0) return;
    if (characters.len > MAX_CHARACTERS_NAMED) {
        tooltip.add("{d} characters here", .{characters.len});
        return;
    }
    var names_buf: [TOOLTIP_LINE_MAX]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&names_buf);
    for (characters, 0..) |name, index| {
        writer.print("{s}{s}", .{ if (index == 0) "" else ", ", name }) catch {};
    }
    tooltip.add("Here: {s}", .{writer.buffered()});
}

const testing = std.testing;

const STORM_REPLY =
    \\[{"observation_type":"gamma_a","observation_category":"storm","hours_in_system":17,"system_id":30000439}]
;
const INCURSION_REPLY =
    \\[{"infested_solar_systems":[30000142,30000144],"influence":0.5,"staging_solar_system_id":30000142,"state":"mobilizing"}]
;

test "the always on top control's tooltip gives its state" {
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
    try testing.expectEqualStrings("Unknown (3)", legend.rows[0].text.slice());
    try testing.expectEqualStrings("Others (18)", legend.rows[LEGEND_MAX_ROWS - 2].text.slice());
    try testing.expectEqualStrings("Unclaimed (2)", legend.rows[LEGEND_MAX_ROWS - 1].text.slice());
}

test "a heat legend says why it has no scale" {
    try testing.expectEqualStrings("Waiting for figures", heatLegend(.ShipKills, 0, false).rows[0].text.slice());
    try testing.expectEqualStrings("None on the map", heatLegend(.ShipKills, 0, true).rows[0].text.slice());
    const legend = heatLegend(.Jumps, 40, true);
    try testing.expectEqualStrings("Jumps, last hour", legend.title.slice());
    try testing.expectEqualStrings("40", legend.ramp_high.slice());
}

test "a region's summary leaves out figures it doesn't have" {
    try testing.expectEqualStrings("93 systems", regionSummary(93, null).slice());
    try testing.expectEqualStrings("93 systems, 1 ship kills, 2 NPC kills, 3 jumps last hour", regionSummary(93, .{ .ship_kills = 1, .npc_kills = 2, .jumps = 3 }).slice());
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
    try testing.expectEqualStrings("Jita  0.9", tooltip.line(0));
    try testing.expectEqualStrings("The Forge / Kimotoro", tooltip.line(1));
    try testing.expectEqualStrings("Last hour: 7 ships, 2 pods, 40 NPCs", tooltip.line(2));
    try testing.expectEqualStrings("Here: Bravo", tooltip.line(4));
    try testing.expectEqualStrings("Intel 5m ago: hostile", tooltip.line(5));
}

test "a tooltip without stats leaves those lines out" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").? });
    try testing.expectEqual(@as(usize, 3), tooltip.line_count);
}

test "a system's tooltip says when routes avoid it" {
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .is_avoided = true });
    try testing.expectEqualStrings("Routes avoid this system", tooltip.line(tooltip.line_count - 1));
}

test "many characters are counted rather than named" {
    const names = [_][]const u8{ "A", "B", "C", "D", "E" };
    const tooltip = systemTooltip(.{ .system = universe.findSystem("Jita").?, .characters = &names });
    try testing.expectEqualStrings("5 characters here", tooltip.line(tooltip.line_count - 1));
}

test "a system's tooltip says how far it is from a jump range's origin, and why it's out" {
    const origin = universe.findSystem("1DQ1-A").?;
    const titan: jump_range.Reach = .measure(origin, .titan);
    try testing.expectEqualStrings("Titan jump range from here", systemTooltip(.{ .system = origin, .reach = &titan }).line(3));
    try testing.expectEqualStrings("0.51 ly from 1DQ1-A", systemTooltip(.{ .system = universe.findSystem("8WA-Z6").?, .reach = &titan }).line(3));
    try testing.expectEqualStrings("6.46 ly from 1DQ1-A, out of range", systemTooltip(.{ .system = universe.findSystem("UEXO-Z").?, .reach = &titan }).line(3));
    const lowsec: jump_range.Reach = .measure(universe.findSystem("Amamake").?, .titan);
    try testing.expectEqualStrings("0.86 ly from Amamake, no cyno possible", systemTooltip(.{ .system = universe.findSystem("Osoggur").?, .reach = &lowsec }).line(3));
}

test "a range's legend gives the total, the biggest regions and sums up the rest" {
    const reach: jump_range.Reach = .measure(universe.findSystem("1DQ1-A").?, .jump_freighter);
    const legend = rangeLegend(&reach);
    try testing.expectEqualStrings("Jump Freighter from 1DQ1-A", legend.title.slice());
    try testing.expect(std.mem.endsWith(u8, legend.rows[0].text.slice(), " systems within 10.0 ly"));
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
    try testing.expectEqual(@as(usize, 2), regionTooltip(region, 10, 0, null, null, null).line_count);
    try testing.expectEqual(@as(usize, 3), regionTooltip(region, 10, 0, &reach, null, null).line_count);
}

test "a system's tooltip names the storm over it and how it stands" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const center = storms.storms[0].center;
    var links = universe.neighbours(center);
    try testing.expectEqualStrings("Gamma Ray Storm centered here, reported 17h ago", systemTooltip(.{ .system = center, .storms = &storms }).line(3));
    try testing.expectEqualStrings("Gamma Ray Storm core, centered on OEG-K9", systemTooltip(.{ .system = links.next().?, .storms = &storms }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Jita").?, .storms = &storms }).line_count);
}

test "a region's tooltip names the storms centred in it" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const region = universe.systemInfo(storms.storms[0].center).region;
    try testing.expectEqualStrings("Gamma Ray Storm at OEG-K9", regionTooltip(region, 10, 0, null, &storms, null).line(2));
}

test "the storm legend lists what reaches the map, and is absent without any" {
    const storms: Storms = try .parse(testing.allocator, STORM_REPLY);
    const nearby = [_]layout.Node{.{ .system = storms.storms[0].center, .x = 0, .y = 0 }};
    try testing.expectEqualStrings("Gamma Ray: OEG-K9, 17h ago", stormLegend(&storms, &nearby).?.rows[0].text.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Jita").?, .x = 0, .y = 0 }};
    try testing.expect(stormLegend(&storms, &distant) == null);
}

test "a system's tooltip says how it stands in an incursion" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const jita = universe.findSystem("Jita").?;
    try testing.expectEqualStrings("Incursion staging here: Mobilizing, 50% influence", systemTooltip(.{ .system = jita, .incursions = &incursions }).line(3));
    try testing.expectEqualStrings("Incursion staged from Jita: Mobilizing, 50% influence", systemTooltip(.{ .system = universe.findSystemById(30000144).?, .incursions = &incursions }).line(3));
    try testing.expectEqual(@as(usize, 3), systemTooltip(.{ .system = universe.findSystem("Amarr").?, .incursions = &incursions }).line_count);
}

test "a region's tooltip names the incursions staging in it" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const region = universe.systemInfo(incursions.incursions[0].staging).region;
    try testing.expectEqualStrings("Incursion staging at Jita", regionTooltip(region, 10, 0, null, null, &incursions).line(2));
}

test "the incursion legend lists what reaches the map, and is absent without any" {
    const incursions: Incursions = try .parse(testing.allocator, INCURSION_REPLY);
    const nearby = [_]layout.Node{.{ .system = incursions.incursions[0].staging, .x = 0, .y = 0 }};
    try testing.expectEqualStrings("Jita: Mobilizing, 50% influence", incursionLegend(&incursions, &nearby).?.rows[0].text.slice());
    const distant = [_]layout.Node{.{ .system = universe.findSystem("Amarr").?, .x = 0, .y = 0 }};
    try testing.expect(incursionLegend(&incursions, &distant) == null);
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
