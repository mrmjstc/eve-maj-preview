//! The guided tests: settings to enter first, then timed steps that say what the app should show after each.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const universe = @import("../map/universe.zig");
const fleet_mod = @import("fleet.zig");
const lines = @import("lines.zig");
const log = @import("../log.zig");

const Fleet = fleet_mod.Fleet;
const slog = log.Scoped("sim");

const CHAT_INTERVAL_MS = 5000;
/// Lets the app read every client's move before the first message.
const CHAT_SETTLE_MS = 2000;
const COLOR_INTERVAL_MS = 6000;
const STORM_INTERVAL_MS = 1500;
const CHAT_CHANNELS = [_][]const u8{ "east.imperium", "Intel Test", "Fleet", "Corp" };
/// The chat test's distances are measured from these.
const NEAR_SYSTEM = "Jita";
const FAR_SYSTEM = "Amarr";
const OTHERS_SYSTEM = "Dodixie";
/// One per client in the unique color test.
const SPREAD_SYSTEMS = [_][]const u8{
    "Jita",        "Amarr",        "Dodixie", "Rens",     "Hek",          "Perimeter", "Sobaseki", "Tama",
    "Uedama",      "Old Man Star", "Ashab",   "Alentene", "Nourvukaiken", "Amamake",   "Rancer",   "Aunia",
    "Iyen-Oursta", "Villore",      "Enaluri", "Stacmon",  "Osmon",        "Nagamanen", "Balle",    "Aset",
    "Onnamon",
};
const STORM_ALERTS = [_]lines.Alert{ .fleet_invite, .cargo_full, .decloak, .docking, .conversation_invite };

pub const Scenario = enum {
    chat_alerts,
    system_colors,
    unique_colors,
    travel_mode,
    alert_storm,

    pub fn label(self: Scenario) []const u8 {
        return switch (self) {
            .chat_alerts => "Chat alerts",
            .system_colors => "System colors",
            .unique_colors => "Unique colors",
            .travel_mode => "Travel Mode",
            .alert_storm => "Alert storm",
        };
    }

    pub fn summary(self: Scenario) []const u8 {
        return switch (self) {
            .chat_alerts => "Intel and keyword rules: range, spelling, exclusions, cooldowns, duplicates across clients and EVE's own lines. Uses the first two logged-in clients.",
            .system_colors => "Patterns, comma lists and precedence, on one route through the systems the rules name. Uses the first picked client.",
            .unique_colors => "Every logged-in client jumps to a different system, so each should get its own color.",
            .travel_mode => "The picked clients jump together, except one left behind, for the Left Behind alert.",
            .alert_storm => "Five different alerts 1.5s apart on each picked client, so they stack and the oldest is evicted.",
        };
    }

    /// What to enter in the app before starting; empty when there's nothing.
    pub fn setup(self: Scenario) []const []const u8 {
        return switch (self) {
            .chat_alerts => &.{
                "Chat Events tab: add these rows, then Save.",
                "Intel    channels: *.imperium, Intel Test, Fleet    Max Jumps 5    exclude: clr, nv",
                "Keyword  channels: Fleet    keywords: bubble, warp in",
            },
            .system_colors => &.{
                "Settings > System Colors, with Unique System Colors OFF; add in this order:",
                "jita, PERIMETER  ->  gold",
                "J######  ->  cyan",
                "J100000  ->  red",
                "Ama*  ->  green",
                "Amarr  ->  magenta",
            },
            .unique_colors => &.{"Turn on Unique System Colors (and Unique Character Name Colors, to check names too)."},
            .travel_mode => &.{"Turn on Travel Mode, with these clients in one group."},
            .alert_storm => &.{},
        };
    }

    /// How many picked clients it needs; 0 when it chooses its own.
    pub fn pickedNeeded(self: Scenario) usize {
        return switch (self) {
            .system_colors, .alert_storm => 1,
            .travel_mode => 2,
            .chat_alerts, .unique_colors => 0,
        };
    }
};

const ChatStep = struct {
    channel: []const u8,
    /// "{near}" is the near client's own name.
    speaker: []const u8,
    text: []const u8,
    /// "{near}" and "{far}" are the two clients' names.
    expect: []const u8,
};

/// Each alerts or stays quiet for one reason; the near client sits in Jita, the far one in Amarr, everyone else in Dodixie.
const CHAT_STEPS = [_]ChatStep{
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "Perimeter 3 hostiles on gate", .expect = "Chat Intel, once only, on {near} (Perimeter, 1j)" },
    .{ .channel = "Intel Test", .speaker = "Scout One", .text = "amarr red gang", .expect = "NOTHING (a plain-word name must be written as spelled)" },
    .{ .channel = "Intel Test", .speaker = "Scout One", .text = "Amarr red gang", .expect = "Chat Intel on {far} (Amarr, 0j), the nearer client" },
    .{ .channel = "east.imperium", .speaker = "Scout Two", .text = "Amarr gang still there", .expect = "NOTHING (Amarr is on cooldown, though the message is new)" },
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "C-J6MT neut in local", .expect = "NOTHING (out of range of every client)" },
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "Sobaseki clr", .expect = "NOTHING (clr is excluded)" },
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "New Caldari spike", .expect = "Chat Intel on {near} (New Caldari, 1j: a two-word name)" },
    .{ .channel = "Corp", .speaker = "Scout One", .text = "Maurasi hostile, bubble up", .expect = "NOTHING (Corp is in no rule)" },
    .{ .channel = "east.imperium", .speaker = "{near}", .text = "Maurasi spike", .expect = "NOTHING (your own character said it)" },
    .{ .channel = "east.imperium", .speaker = "EVE System", .text = "Channel MOTD: Maurasi is lovely", .expect = "NOTHING (EVE's own line)" },
    .{ .channel = "Fleet", .speaker = "Fleet Commander", .text = "BUBBLE on the gate", .expect = "Chat Keyword (bubble), once only, on any client" },
    .{ .channel = "Fleet", .speaker = "Fleet Commander", .text = "bubbles everywhere", .expect = "NOTHING (keywords match whole words)" },
    .{ .channel = "Fleet", .speaker = "Fleet Commander", .text = "Warp In now", .expect = "Chat Keyword (warp in, a phrase in any case)" },
    .{ .channel = "Fleet", .speaker = "Fleet Commander", .text = "warp in to Muvolailen", .expect = "Chat Intel only on {near} (Muvolailen, 1j): intel beats a keyword" },
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "Perimeter clr?", .expect = "NOTHING (a question: the Map Panel pin on Perimeter stays red)" },
    .{ .channel = "east.imperium", .speaker = "Scout One", .text = "Perimeter clr", .expect = "No alert (clr is excluded), but the Map Panel pin on Perimeter turns yellow and shrinks again" },
};

const ColorStep = struct { system: []const u8, expect: []const u8 };

const COLOR_STEPS = [_]ColorStep{
    .{ .system = "Jita", .expect = "gold (first in a comma list; the rule is lowercase)" },
    .{ .system = "Perimeter", .expect = "gold (second in a comma list; the rule is uppercase)" },
    .{ .system = "J123456", .expect = "cyan (# matches digits)" },
    .{ .system = "J100000", .expect = "red (exact beats the J###### pattern)" },
    .{ .system = "Jakri", .expect = "DEFAULT (J###### must not match letters)" },
    .{ .system = "J12345", .expect = "DEFAULT (only 5 digits; the pattern needs 6)" },
    .{ .system = "Amamake", .expect = "green (the Ama* pattern)" },
    .{ .system = "Amarr", .expect = "magenta (exact beats Ama* despite row order)" },
    .{ .system = "Rens", .expect = "DEFAULT (no rule)" },
};

/// `picked` are the client list's picked rows, in order; `straggler` is travel_mode's one left behind, among them.
pub fn start(fleet: *Fleet, scenario: Scenario, picked: []const usize, straggler: ?usize) void {
    if (picked.len < scenario.pickedNeeded()) {
        fleet.note(.warning, "{s} needs {d} picked client(s)", .{ scenario.label(), scenario.pickedNeeded() });
        return;
    }
    var arena_state: std.heap.ArenaAllocator = .init(fleet.allocator);
    defer arena_state.deinit();
    const result = switch (scenario) {
        .chat_alerts => startChatAlerts(fleet, arena_state.allocator()),
        .system_colors => startSystemColors(fleet, picked[0]),
        .unique_colors => startUniqueColors(fleet),
        .travel_mode => startTravelMode(fleet, picked, straggler orelse picked[picked.len - 1]),
        .alert_storm => startAlertStorm(fleet, picked),
    };
    result catch |err| {
        slog.err("Failed to start the {s} test: {}", .{ scenario.label(), err });
        _ = fleet.schedule.cancel(null, .scenario);
        fleet.note(.failure, "Failed to start {s}: {t}", .{ scenario.label(), err });
    };
}

/// `template` with "{near}" and "{far}" replaced, made in `arena`.
fn fillNames(arena: std.mem.Allocator, template: []const u8, near: []const u8, far: []const u8) ![]const u8 {
    const with_near = try std.mem.replaceOwned(u8, arena, template, "{near}", near);
    return std.mem.replaceOwned(u8, arena, with_near, "{far}", far);
}

fn startChatAlerts(fleet: *Fleet, arena: std.mem.Allocator) !void {
    var present: std.ArrayList(usize) = .empty;
    for (fleet.clients.items, 0..) |client, index| {
        if (client.state == .logged_in) try present.append(arena, index);
    }
    if (present.items.len < 2) {
        fleet.note(.warning, "The chat alerts test needs 2 logged-in clients", .{});
        return;
    }
    const near = fleet.clients.items[present.items[0]].name;
    const far = fleet.clients.items[present.items[1]].name;
    for (present.items, 0..) |index, position| {
        _ = fleet.schedule.cancel(fleet.clients.items[index].name, .route);
        for (CHAT_CHANNELS) |channel| fleet.join(index, channel);
        const base = switch (position) {
            0 => NEAR_SYSTEM,
            1 => FAR_SYSTEM,
            else => OTHERS_SYSTEM,
        };
        if (!std.mem.eql(u8, fleet.clients.items[index].system, base)) fleet.move(index, base, .both, 0);
    }
    fleet.note(.info, "{s} is in {s}, {s} in {s}, the rest in {s}", .{ near, NEAR_SYSTEM, far, FAR_SYSTEM, OTHERS_SYSTEM });

    const first_due = win32.Ticks.now().ms + CHAT_SETTLE_MS;
    for (CHAT_STEPS, 0..) |step, step_index| {
        const due = first_due + @as(u64, step_index) * CHAT_INTERVAL_MS;
        const expect = try fillNames(arena, step.expect, near, far);
        const numbered = try arena.print("step {d} of {d}: {s}", .{ step_index + 1, CHAT_STEPS.len, expect });
        try fleet.schedule.add(due, "", .scenario, .{ .expect = numbered });
        try fleet.schedule.add(due, "", .scenario, .{ .chat = .{
            .channel = step.channel,
            .speaker = try fillNames(arena, step.speaker, near, far),
            .text = step.text,
        } });
    }
    const done_due = first_due + @as(u64, CHAT_STEPS.len) * CHAT_INTERVAL_MS;
    try fleet.schedule.add(done_due, "", .scenario, .{ .expect = "the History panel lists one row per alert above, under the Chat filter" });
}

fn startSystemColors(fleet: *Fleet, index: usize) !void {
    const client = &fleet.clients.items[index];
    _ = fleet.schedule.cancel(client.name, .route);
    const now = win32.Ticks.now().ms;
    for (COLOR_STEPS, 0..) |step, step_index| {
        const due = now + @as(u64, step_index) * COLOR_INTERVAL_MS;
        try fleet.schedule.add(due, client.name, .scenario, .{ .move = .{ .system = step.system } });
        try fleet.schedule.add(due, "", .scenario, .{ .expect = step.expect });
    }
    fleet.note(.success, "{s} is touring the System Colors rules, {d}s apart", .{ client.name, COLOR_INTERVAL_MS / std.time.ms_per_s });
}

fn startUniqueColors(fleet: *Fleet) !void {
    var moved_count: usize = 0;
    for (fleet.clients.items, 0..) |client, index| {
        if (client.state != .logged_in) continue;
        fleet.move(index, SPREAD_SYSTEMS[moved_count % SPREAD_SYSTEMS.len], .both, 0);
        moved_count += 1;
    }
    if (moved_count == 0) {
        fleet.note(.warning, "No logged-in clients", .{});
        return;
    }
    fleet.note(.expect, "Expect: every system (and, with Unique Character Name Colors on, every character) has a clearly different color", .{});
    fleet.note(.expect, "Expect: after restarting the app, each keeps its color (stored in data\\colors.json)", .{});
}

fn startTravelMode(fleet: *Fleet, group: []const usize, straggler: usize) !void {
    const left_behind = &fleet.clients.items[straggler];
    var destination = SPREAD_SYSTEMS[fleet.random_source.random().uintLessThan(usize, SPREAD_SYSTEMS.len)];
    if (std.mem.eql(u8, destination, left_behind.system)) destination = if (std.mem.eql(u8, destination, NEAR_SYSTEM)) FAR_SYSTEM else NEAR_SYSTEM;
    for (group) |index| {
        if (index != straggler) fleet.move(index, destination, .both, 0);
    }
    fleet.note(.info, "{s} stayed behind in {s}", .{ left_behind.name, left_behind.system });
    fleet.note(.expect, "Expect: once Travel Mode's Catch-Up Window passes, {s}'s thumbnail shows Left Behind", .{left_behind.name});
    fleet.note(.expect, "Expect: jumping {s} to {s} clears it", .{ left_behind.name, destination });
}

fn startAlertStorm(fleet: *Fleet, group: []const usize) !void {
    const now = win32.Ticks.now().ms;
    for (group) |index| {
        const name = fleet.clients.items[index].name;
        for (STORM_ALERTS, 0..) |alert, alert_index| {
            try fleet.schedule.add(now + @as(u64, alert_index) * STORM_INTERVAL_MS, name, .storm, .{ .alert = alert });
        }
    }
    fleet.note(.expect, "Expect: the alerts stack on each thumbnail, and past three the oldest makes way", .{});
}

const testing = std.testing;

test "chat steps name the near and far clients" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const filled = try fillNames(arena_state.allocator(), "Chat Intel on {far}, not {near}", "Aria Kestrel", "Dax Solano");
    try testing.expectEqualStrings("Chat Intel on Dax Solano, not Aria Kestrel", filled);
}

test "the chat test's systems are as many jumps from Jita as its steps say" {
    const jita = universe.findSystem(NEAR_SYSTEM) orelse return error.TestUnexpectedResult;
    var distances: universe.Distances = undefined;
    universe.measureDistances(jita, 5, &distances);
    for ([_][]const u8{ "Perimeter", "New Caldari", "Muvolailen" }) |name| {
        const system = universe.findSystem(name) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u8, 1), distances[system]);
    }
    const out_of_range = universe.findSystem("C-J6MT") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(universe.UNREACHED, distances[out_of_range]);
}
