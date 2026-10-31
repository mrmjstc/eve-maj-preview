//! Calls Eve Stars on background threads, and hands each reply to the main thread.
const std = @import("std");
const evestars = @import("evestars.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const slog = log.Scoped("map");

/// A group's send answers only once every character's waypoints are set.
const SEND_TIMEOUT_MS: c_int = 60_000;

const Method = enum { get, post };

/// Lives as long as the app, since its threads may outlast the panel's window.
pub const EveStarsFeed = struct {
    search: Call(evestars.Hits, evestars.parseHits) = .{},
    characters: Call(evestars.Targets, evestars.parseTargets) = .{},
    send: Call(evestars.Notice, evestars.parseSend) = .{},

    /// After the calls' threads have finished.
    pub fn deinit(self: *EveStarsFeed) void {
        _ = self.search.take();
        _ = self.characters.take();
        _ = self.send.take();
    }

    pub fn isBusy(self: *const EveStarsFeed) bool {
        return self.search.isBusy() or self.characters.isBusy() or self.send.isBusy();
    }

    pub fn startSearch(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8, query: []const u8) !void {
        const url = try evestars.searchUrl(allocator, query);
        defer allocator.free(url);
        _ = self.search.start(allocator, token, url, .get);
    }

    pub fn startCharacters(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8) void {
        _ = self.characters.start(allocator, token, evestars.CHARACTERS_URL, .get);
    }

    /// Whether the send started.
    pub fn startSend(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8, system_id: u32, target_id: u64) !bool {
        const url = try evestars.sendUrl(allocator, system_id, target_id);
        defer allocator.free(url);
        return self.send.start(allocator, token, url, .post);
    }
};

pub fn Reply(comptime T: type) type {
    return union(enum) { answer: T, failure: evestars.Failure };
}

/// One endpoint: a call at a time, as two sends to one character would race in its client.
fn Call(comptime T: type, comptime parse: fn (std.mem.Allocator, []const u8) anyerror!T) type {
    return struct {
        /// Set while the call's thread runs.
        is_busy: std.atomic.Value(bool) = .init(false),
        /// The newest reply not yet taken; ownership passes with the swap.
        ready: std.atomic.Value(?*Delivery) = .init(null),

        const Self = @This();

        const Delivery = struct {
            allocator: std.mem.Allocator,
            reply: Reply(T),
        };

        pub fn isBusy(self: *const Self) bool {
            return self.is_busy.load(.acquire);
        }

        /// Whether the call started, false if one is running or it couldn't, which it logs; `url` and `token` are copied.
        pub fn start(self: *Self, allocator: std.mem.Allocator, token: []const u8, url: []const u8, method: Method) bool {
            if (self.is_busy.swap(true, .acq_rel)) return false;
            self.spawnCall(allocator, token, url, method) catch |err| {
                slog.err("Failed to start a call to Eve Stars: {}", .{err});
                self.is_busy.store(false, .release);
                return false;
            };
            return true;
        }

        pub fn take(self: *Self) ?Reply(T) {
            const delivery = self.ready.swap(null, .acq_rel) orelse return null;
            defer delivery.allocator.destroy(delivery);
            return delivery.reply;
        }

        fn spawnCall(self: *Self, allocator: std.mem.Allocator, token: []const u8, url: []const u8, method: Method) !void {
            const owned_url = try allocator.dupe(u8, url);
            errdefer allocator.free(owned_url);
            const header = try evestars.authorization(allocator, token);
            errdefer allocator.free(header);
            try detached.spawn(thread, .{ self, allocator, owned_url, header, method });
        }

        /// The call's thread, which owns `url` and `header`; touches nothing of the main thread's but this slot's atomics and the allocator.
        fn thread(self: *Self, allocator: std.mem.Allocator, url: []u8, header: []u8, method: Method) void {
            defer self.is_busy.store(false, .release);
            defer allocator.free(url);
            defer allocator.free(header);
            const delivery = allocator.create(Delivery) catch |err| {
                slog.err("Failed to keep Eve Stars' reply: {}", .{err});
                return;
            };
            delivery.* = .{ .allocator = allocator, .reply = request(allocator, url, header, method) };
            if (self.ready.swap(delivery, .acq_rel)) |unclaimed| allocator.destroy(unclaimed);
        }

        fn request(allocator: std.mem.Allocator, url: []const u8, header: []const u8, method: Method) Reply(T) {
            // Logs its own failures.
            var session = http_client.Session.init() catch return .{ .failure = .unreachedService() };
            defer session.deinit();
            const headers = [_]http_client.Header{.{ .name = "Authorization", .value = header }};
            var options: http_client.FetchOptions = .{ .extra_headers = &headers };
            if (method == .post) {
                options.payload = "";
                options.receive_timeout_ms = SEND_TIMEOUT_MS;
            }
            // Logs its own failures.
            const response = session.send(allocator, url, options) catch return .{ .failure = .unreachedService() };
            defer response.deinit(allocator);

            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            if (response.status != 200) {
                slog.warn("Failed to call Eve Stars at '{s}': status {d}: {s}", .{ url, response.status, response.body });
                return .{ .failure = evestars.failureOf(arena.allocator(), response.status, response.body, response.retry_after_seconds) };
            }
            const answer = parse(arena.allocator(), response.body) catch |err| {
                slog.warn("Failed to read Eve Stars' answer from '{s}': {}", .{ url, err });
                return .{ .failure = .unreadableAnswer() };
            };
            return .{ .answer = answer };
        }
    };
}
