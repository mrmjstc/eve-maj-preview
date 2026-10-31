//! The Map Panel's Eve Stars state: who can be sent a destination, the system search, and how each call turned out; main thread only.
const std = @import("std");
const evestars = @import("evestars.zig");
const evestars_feed = @import("evestars_feed.zig");
const universe = @import("universe.zig");
const log = @import("../log.zig");

const Notice = evestars.Notice;
const SystemIndex = universe.SystemIndex;
const slog = log.Scoped("map");

/// Lets a word be typed before it's searched for.
const SEARCH_PAUSE_MS: u64 = 200;
pub const MIN_QUERY_LENGTH = 2;
/// /characters shares its rate limit with routes, so opening the menu repeatedly doesn't ask each time.
const TARGETS_STALE_MS: u64 = 30 * std.time.ms_per_s;
const NOTICE_MS: u64 = 6 * std.time.ms_per_s;
const FAILURE_NOTICE_MS: u64 = 20 * std.time.ms_per_s;
/// Past the send's own timeout, so its reply is what clears the message.
const SENDING_NOTICE_MS: u64 = 70 * std.time.ms_per_s;

/// Lives as long as the app, like its feed.
pub const Destinations = struct {
    feed: evestars_feed.EveStarsFeed = .{},
    targets: evestars.Targets = .{},
    /// Null until the first answer; in ms since boot.
    targets_fetched_ms: ?u64 = null,
    hits: evestars.Hits = .{},
    /// Null while there's nothing to report.
    notice: ?Notice = null,
    /// When `notice` goes, in ms since boot.
    notice_end_ms: u64 = 0,
    query_buffer: [evestars.MAX_QUERY_LENGTH]u8 = undefined,
    query_length: usize = 0,
    /// When the typed text is next searched for, in ms since boot; null once it has been.
    search_due_ms: ?u64 = null,
    /// Raised by anything shown changing, for the render signature.
    revision: u32 = 0,

    /// Only once the feed's threads have finished.
    pub fn deinit(self: *Destinations) void {
        self.feed.deinit();
    }

    pub fn query(self: *const Destinations) []const u8 {
        return self.query_buffer[0..self.query_length];
    }

    /// Whether answers or timed changes are still to come.
    pub fn isWaiting(self: *const Destinations) bool {
        return self.feed.isBusy() or self.search_due_ms != null or self.notice != null;
    }

    /// Takes any replies, starts a search that's due and drops an expired notice.
    pub fn poll(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, now_ms: u64) void {
        if (self.feed.characters.take()) |reply| {
            switch (reply) {
                .answer => |targets| {
                    self.targets = targets;
                    self.targets_fetched_ms = now_ms;
                },
                .failure => |failure| self.showFailure(failure, now_ms),
            }
            self.revision +%= 1;
        }
        if (self.feed.search.take()) |reply| {
            switch (reply) {
                .answer => |hits| self.hits = hits,
                .failure => |failure| {
                    self.showFailure(failure, now_ms);
                    if (failure.retry_after_seconds) |seconds| self.search_due_ms = now_ms + @as(u64, seconds) * std.time.ms_per_s;
                },
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

        const due_ms = self.search_due_ms orelse return;
        if (now_ms < due_ms or self.feed.search.isBusy()) return;
        self.search_due_ms = null;
        self.feed.startSearch(allocator, token, self.query()) catch |err| {
            slog.warn("Failed to search Eve Stars for '{s}': {}", .{ self.query(), err });
        };
    }

    /// For the menu's opening; its list is the newest known until the answer comes.
    pub fn refreshTargets(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, now_ms: u64) void {
        if (self.targets_fetched_ms) |fetched_ms| {
            if (now_ms -| fetched_ms < TARGETS_STALE_MS) return;
        }
        self.feed.startCharacters(allocator, token);
    }

    /// Sets `system` as the destination of `target`, or says why it can't be.
    pub fn send(self: *Destinations, allocator: std.mem.Allocator, token: []const u8, target: *const evestars.Target, system: SystemIndex, now_ms: u64) void {
        if (!target.can_send) {
            self.showFailureText(.print("{s}: {s}", .{ target.name.slice(), target.why.slice() }), now_ms);
            return;
        }
        const has_started = self.feed.startSend(allocator, token, universe.systemInfo(system).id, target.id) catch |err| blk: {
            slog.err("Failed to set '{s}' as the destination of '{s}': {}", .{ universe.systemName(system), target.name.slice(), err });
            break :blk false;
        };
        if (has_started) {
            var notice: Notice = .{};
            notice.add(.print("Setting {s} for {s}", .{ universe.systemName(system), target.name.slice() }));
            self.show(notice, SENDING_NOTICE_MS, now_ms);
        } else {
            self.showFailureText(.print("A destination is still being set: try again shortly", .{}), now_ms);
        }
    }

    pub fn beginSearch(self: *Destinations) void {
        self.query_length = 0;
        self.search_due_ms = null;
        self.hits = .{};
        self.revision +%= 1;
    }

    /// Ignores what would run past the length Eve Stars takes.
    pub fn typeChar(self: *Destinations, char: u8, now_ms: u64) void {
        if (self.query_length == self.query_buffer.len) return;
        self.query_buffer[self.query_length] = char;
        self.query_length += 1;
        self.queryChanged(now_ms);
    }

    pub fn eraseChar(self: *Destinations, now_ms: u64) void {
        self.query_length -|= 1;
        self.queryChanged(now_ms);
    }

    fn queryChanged(self: *Destinations, now_ms: u64) void {
        self.revision +%= 1;
        if (self.query_length < MIN_QUERY_LENGTH) {
            self.search_due_ms = null;
            self.hits = .{};
            return;
        }
        self.search_due_ms = now_ms + SEARCH_PAUSE_MS;
    }

    fn showFailure(self: *Destinations, failure: evestars.Failure, now_ms: u64) void {
        self.showFailureText(failure.text, now_ms);
    }

    fn showFailureText(self: *Destinations, text: evestars.Text, now_ms: u64) void {
        var notice: Notice = .{ .is_failure = true };
        notice.add(text);
        self.show(notice, FAILURE_NOTICE_MS, now_ms);
    }

    fn show(self: *Destinations, notice: Notice, duration_ms: u64, now_ms: u64) void {
        self.notice = notice;
        self.notice_end_ms = now_ms + duration_ms;
        self.revision +%= 1;
    }
};
