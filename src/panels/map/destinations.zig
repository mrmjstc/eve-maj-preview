//! The Map Panel's Eve Stars state: who can be sent a destination, the account's Ansiblex gates and avoid list, a planned route, and how each call turned out; main thread only.
const std = @import("std");
const evestars = @import("../../map/evestars.zig");
const evestars_feed = @import("../../map/evestars_feed.zig");
const universe = @import("../../map/universe.zig");
const log = @import("../../log.zig");

const Notice = evestars.Notice;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// Soon enough for a login to show, well inside the lookups rate limit.
const TARGETS_STALE_MS: u64 = 5 * std.time.ms_per_s;
const NOTICE_MS: u64 = 6 * std.time.ms_per_s;
const FAILURE_NOTICE_MS: u64 = 20 * std.time.ms_per_s;
/// Past the send's own timeout, so its reply is what clears the message.
const SENDING_NOTICE_MS: u64 = 130 * std.time.ms_per_s;
/// Eve Stars reads the gates from the game hourly.
const BRIDGES_STALE_MS: u64 = 30 * std.time.ms_per_min;
/// While Eve Stars is still loading them, or a call failed.
const BRIDGES_RETRY_MS: u64 = 30 * std.time.ms_per_s;
/// While the map shows; the site can change the list too.
pub const AVOID_STALE_MS: u64 = std.time.ms_per_min;
/// Before a menu that can change it, so the change starts from the list as it stands.
pub const AVOID_MENU_STALE_MS: u64 = TARGETS_STALE_MS;

/// What every call that plans or sets a route takes.
pub const RouteRequest = struct {
    allocator: std.mem.Allocator,
    /// Borrowed for the call.
    token: []const u8,
    /// Borrowed for the call.
    options: *const evestars.RouteOptions,
    now_ms: u64,
};

/// Lives as long as the app, like its feed.
pub const Destinations = struct {
    feed: evestars_feed.EveStarsFeed = .{},
    targets: evestars.Targets = .{},
    /// Null until the first ask, and kept on a failure so a failing call isn't repeated at once; in ms since boot.
    targets_asked_ms: ?u64 = null,
    /// Null while there's nothing to report.
    notice: ?Notice = null,
    /// When `notice` goes, in ms since boot.
    notice_end_ms: u64 = 0,
    /// The newest Ansiblex gates; empty until the first answer.
    bridges: evestars.Bridges = .{},
    /// When the gates are next asked for, in ms since boot; 0 asks at once.
    bridges_due_ms: u64 = 0,
    /// The account's saved avoid list; empty until the first answer.
    avoid: evestars.AvoidList = .{},
    /// When the list was last asked for, in ms since boot; null asks at once.
    avoid_asked_ms: ?u64 = null,
    /// Raised by each change started, so a read begun before one is dropped.
    avoid_change_count: u32 = 0,
    /// avoid_change_count as the newest read started.
    avoid_read_change_count: u32 = 0,
    /// The ways to the system Show Route was asked for; null while none is shown.
    routes: ?evestars.Routes = null,
    /// Raised by anything shown changing, for the render signature.
    revision: u32 = 0,

    /// Only once the feed's threads have finished.
    pub fn deinit(self: *Destinations) void {
        self.feed.deinit();
    }

    /// Whether answers or timed changes are still to come.
    pub fn isWaiting(self: *const Destinations) bool {
        return self.feed.isBusy() or self.notice != null;
    }

    /// Takes any replies and drops an expired notice.
    pub fn poll(self: *Destinations, now_ms: u64) void {
        if (self.feed.characters.take()) |reply| {
            switch (reply) {
                .answer => |targets| self.targets = targets,
                .failure => |failure| self.showFailure(failure, now_ms),
            }
            self.revision +%= 1;
        }
        if (self.feed.bridges.take()) |reply| {
            switch (reply) {
                .answer => |bridges| {
                    self.bridges = bridges;
                    if (!bridges.is_ready) self.bridges_due_ms = now_ms + BRIDGES_RETRY_MS;
                    self.revision +%= 1;
                },
                // The feed logged it; the map keeps the gates it had.
                .failure => self.bridges_due_ms = now_ms + BRIDGES_RETRY_MS,
            }
        }
        if (self.feed.avoid.take()) |reply| {
            switch (reply) {
                .answer => |list| if (self.avoid_read_change_count == self.avoid_change_count and !self.feed.avoid_change.isBusy()) {
                    self.avoid = list;
                    self.revision +%= 1;
                },
                // The feed logged it; the map keeps the list it had.
                .failure => {},
            }
        }
        if (self.feed.avoid_change.take()) |reply| {
            switch (reply) {
                .answer => |list| self.avoid = list,
                .failure => |failure| {
                    self.showFailure(failure, now_ms);
                    // Reads back what the account holds, undoing the change already shown.
                    self.avoid_asked_ms = null;
                },
            }
            self.revision +%= 1;
        }
        if (self.feed.plan.take()) |reply| {
            switch (reply) {
                .answer => |routes| {
                    if (routes.count == 0) {
                        self.routes = null;
                        self.showFailureText(.print("Eve Stars found no route to {s}", .{universe.systemName(routes.to)}), now_ms);
                    } else if (routes.is_missing_ansiblex) {
                        self.routes = routes;
                        self.showInfo(.print("Ansiblex gates weren't loaded, so the routes go without them", .{}), now_ms);
                    } else {
                        self.routes = routes;
                        self.notice = null;
                    }
                },
                .failure => |failure| self.showFailure(failure, now_ms),
            }
            self.revision +%= 1;
        }
        if (self.feed.send.take()) |reply| {
            switch (reply) {
                .answer => |notice| self.show(notice, if (notice.is_failure) FAILURE_NOTICE_MS else NOTICE_MS, now_ms),
                .failure => |failure| self.showFailure(failure, now_ms),
            }
        }
        if (self.notice != null and now_ms >= self.notice_end_ms) {
            self.notice = null;
            self.revision +%= 1;
        }
    }

    /// While the menu is open; its list is the newest known until the answer comes.
    pub fn refreshTargets(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, now_ms: u64) void {
        if (self.targets_asked_ms) |asked_ms| {
            if (now_ms -| asked_ms < TARGETS_STALE_MS) return;
        }
        self.targets_asked_ms = now_ms;
        self.feed.startCharacters(allocator, token);
    }

    /// While the map shows Ansiblex gates; asking for the characters too while Eve Stars hasn't loaded the gates, as that's what starts it loading them.
    pub fn refreshBridges(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, now_ms: u64) void {
        if (now_ms < self.bridges_due_ms or self.feed.bridges.isBusy()) return;
        self.bridges_due_ms = now_ms + BRIDGES_STALE_MS;
        if (!self.bridges.is_ready) self.refreshTargets(allocator, token, now_ms);
        self.feed.startBridges(allocator, token);
    }

    /// Asks for the avoid list once it's older than `max_age_ms`, unless a change is under way.
    pub fn refreshAvoid(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, max_age_ms: u64, now_ms: u64) void {
        if (self.avoid_asked_ms) |asked_ms| {
            if (now_ms -| asked_ms < max_age_ms) return;
        }
        if (self.feed.avoid_change.isBusy() or !self.feed.startAvoid(allocator, token)) return;
        self.avoid_asked_ms = now_ms;
        self.avoid_read_change_count = self.avoid_change_count;
    }

    /// Names `system` on the account's avoid list or takes it off, showing the change before Eve Stars answers; one avoided only as part of an area says so instead.
    pub fn toggleAvoid(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, system: SystemIndex, now_ms: u64) void {
        const name = universe.systemName(system);
        if (self.avoid.avoidanceOf(system) == .in_area) {
            self.showInfo(.print("{s} is avoided as part of {s}: change that on Eve Stars", .{ name, self.avoid.areaName(system) orelse "an area" }), now_ms);
            return;
        }
        const changed = self.avoid.toggled(system) catch |err| {
            slog.warn("Failed to avoid '{s}': {}", .{ name, err });
            self.showFailureText(.print("The avoid list is full", .{}), now_ms);
            return;
        };
        const has_started = self.feed.startAvoidChange(allocator, token, &changed) catch |err| {
            slog.err("Failed to change whether routes avoid '{s}': {}", .{ name, err });
            self.showFailureText(.print("Couldn't change the avoid list", .{}), now_ms);
            return;
        };
        if (!has_started) {
            self.showFailureText(.print("The avoid list is still being changed: try again shortly", .{}), now_ms);
            return;
        }
        self.avoid_change_count +%= 1;
        self.avoid = changed;
        switch (changed.avoidanceOf(system)) {
            .none => self.showInfo(.print("Routes no longer avoid {s}", .{name}), now_ms),
            .listed => self.showInfo(.print("Routes avoid {s}", .{name}), now_ms),
            .in_area => self.showInfo(.print("{s} is still avoided as part of {s}", .{ name, changed.areaName(system) orelse "an area" }), now_ms),
        }
    }

    /// Asks Eve Stars for the ways from `from` to `to`, which replace any shown once they come.
    pub fn planRoute(self: *Destinations, request: RouteRequest, from: SystemIndex, to: SystemIndex) void {
        const now_ms = request.now_ms;
        if (from == to) {
            self.showInfo(.print("Already in {s}", .{universe.systemName(to)}), now_ms);
            return;
        }
        const has_started = self.feed.startPlan(request.allocator, request.token, universe.systemInfo(from).id, universe.systemInfo(to).id, request.options) catch |err| blk: {
            slog.err("Failed to plan a route to '{s}': {}", .{ universe.systemName(to), err });
            break :blk false;
        };
        if (!has_started) {
            self.showFailureText(.print("A route is still being planned: try again shortly", .{}), now_ms);
            return;
        }
        var notice: Notice = .{};
        notice.add(.print("Planning {s} to {s}", .{ universe.systemName(from), universe.systemName(to) }));
        self.show(notice, SENDING_NOTICE_MS, now_ms);
    }

    pub fn clearRoute(self: *Destinations) void {
        self.routes = null;
        self.revision +%= 1;
    }

    /// Sets the shown route at `index` for the character called `character_name`, an alternative through its pin.
    pub fn sendRoute(self: *Destinations, request: RouteRequest, index: usize, character_name: []const u8) void {
        const routes = if (self.routes) |*shown| shown else return;
        if (index >= routes.count) return;
        const target = self.characterNamed(character_name) orelse {
            self.showFailureText(.print("{s} isn't online on your Eve Stars account", .{character_name}), request.now_ms);
            return;
        };
        var pinned = request.options.*;
        pinned.via_id = if (routes.routes[index].via) |via| universe.systemInfo(via).id else null;
        var pinned_request = request;
        pinned_request.options = &pinned;
        self.send(pinned_request, target, routes.to);
    }

    /// Sets `system` as the destination of `target`, or says why it can't be.
    pub fn send(self: *Destinations, request: RouteRequest, target: *const evestars.Target, system: SystemIndex) void {
        if (!target.can_send) {
            self.showFailureText(.print("{s}: {s}", .{ target.name.slice(), target.why.slice() }), request.now_ms);
            return;
        }
        self.startSend(request, system, &.{target.id}, .print("Setting {s} for {s}", .{ universe.systemName(system), target.name.slice() }));
    }

    /// Sets `system` as the destination of every character that can take it, by id rather than `all`, which would count the offline ones too.
    pub fn sendToAll(self: *Destinations, request: RouteRequest, system: SystemIndex) void {
        var character_ids: [evestars.MAX_TARGETS]u64 = undefined;
        var character_count: usize = 0;
        for (self.targets.slice()) |*target| {
            if (!target.isSendableCharacter()) continue;
            character_ids[character_count] = target.id;
            character_count += 1;
        }
        if (character_count == 0) {
            self.showFailureText(.print("No characters can take a route", .{}), request.now_ms);
            return;
        }
        self.startSend(request, system, character_ids[0..character_count], .print("Setting {s} for {d} {s}", .{ universe.systemName(system), character_count, if (character_count == 1) "character" else "characters" }));
    }

    pub fn showInfo(self: *Destinations, text: evestars.Text, now_ms: u64) void {
        var notice: Notice = .{};
        notice.add(text);
        self.show(notice, NOTICE_MS, now_ms);
    }

    pub fn showFailureText(self: *Destinations, text: evestars.Text, now_ms: u64) void {
        var notice: Notice = .{ .is_failure = true };
        notice.add(text);
        self.show(notice, FAILURE_NOTICE_MS, now_ms);
    }

    /// `sending_text` shows until the reply does.
    fn startSend(self: *Destinations, request: RouteRequest, system: SystemIndex, target_ids: []const u64, sending_text: evestars.Text) void {
        const now_ms = request.now_ms;
        const has_started = self.feed.startSend(request.allocator, request.token, universe.systemInfo(system).id, target_ids, request.options) catch |err| blk: {
            slog.err("Failed to set '{s}' as a destination: {}", .{ universe.systemName(system), err });
            break :blk false;
        };
        if (!has_started) {
            self.showFailureText(.print("A destination is still being set: try again shortly", .{}), now_ms);
            return;
        }
        var notice: Notice = .{};
        notice.add(sending_text);
        self.show(notice, SENDING_NOTICE_MS, now_ms);
    }

    /// Searched linearly, as an account has only a few dozen.
    fn characterNamed(self: *const Destinations, name: []const u8) ?*const evestars.Target {
        for (self.targets.slice()) |*target| {
            if (target.kind == .character and std.ascii.eqlIgnoreCase(target.name.slice(), name)) return target;
        }
        return null;
    }

    fn showFailure(self: *Destinations, failure: evestars.Failure, now_ms: u64) void {
        self.showFailureText(failure.text, now_ms);
    }

    fn show(self: *Destinations, notice: Notice, duration_ms: u64, now_ms: u64) void {
        self.notice = notice;
        self.notice_end_ms = now_ms + duration_ms;
        self.revision +%= 1;
    }
};
