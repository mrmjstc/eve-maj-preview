//! The Map Panel's Eve Stars state: who can be sent a destination, and how each call turned out; main thread only.
const std = @import("std");
const evestars = @import("evestars.zig");
const evestars_feed = @import("evestars_feed.zig");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const Notice = evestars.Notice;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// Soon enough for a login to show, well inside the lookups rate limit.
const TARGETS_STALE_MS: u64 = 5 * std.time.ms_per_s;
const NOTICE_MS: u64 = 6 * std.time.ms_per_s;
const FAILURE_NOTICE_MS: u64 = 20 * std.time.ms_per_s;
/// Past the send's own timeout, so its reply is what clears the message.
const SENDING_NOTICE_MS: u64 = 130 * std.time.ms_per_s;

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

    /// Sets `system` as the destination of `target`, or says why it can't be.
    pub fn send(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, target: *const evestars.Target, system: SystemIndex, options: *const evestars.RouteOptions, now_ms: u64) void {
        if (!target.can_send) {
            self.showFailureText(.print("{s}: {s}", .{ target.name.slice(), target.why.slice() }), now_ms);
            return;
        }
        self.startSend(allocator, token, system, &.{target.id}, options, .print("Setting {s} for {s}", .{ universe.systemName(system), target.name.slice() }), now_ms);
    }

    /// Sets `system` as the destination of every character that can take it, by id rather than `all`, which would count the offline ones too.
    pub fn sendToAll(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, system: SystemIndex, options: *const evestars.RouteOptions, now_ms: u64) void {
        var character_ids: [evestars.MAX_TARGETS]u64 = undefined;
        var character_count: usize = 0;
        for (self.targets.slice()) |*target| {
            if (!target.isSendableCharacter()) continue;
            character_ids[character_count] = target.id;
            character_count += 1;
        }
        if (character_count == 0) {
            self.showFailureText(.print("No characters can take a route", .{}), now_ms);
            return;
        }
        self.startSend(allocator, token, system, character_ids[0..character_count], options, .print("Setting {s} for {d} {s}", .{ universe.systemName(system), character_count, if (character_count == 1) "character" else "characters" }), now_ms);
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
    fn startSend(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, system: SystemIndex, target_ids: []const u64, options: *const evestars.RouteOptions, sending_text: evestars.Text, now_ms: u64) void {
        const has_started = self.feed.startSend(allocator, token, universe.systemInfo(system).id, target_ids, options) catch |err| blk: {
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

    fn showFailure(self: *Destinations, failure: evestars.Failure, now_ms: u64) void {
        self.showFailureText(failure.text, now_ms);
    }

    fn show(self: *Destinations, notice: Notice, duration_ms: u64, now_ms: u64) void {
        self.notice = notice;
        self.notice_end_ms = now_ms + duration_ms;
        self.revision +%= 1;
    }
};
