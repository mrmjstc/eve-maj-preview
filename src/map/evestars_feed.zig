//! Calls Eve Stars on background threads, and hands each reply to the main thread.
const std = @import("std");
const evestars = @import("evestars.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const handoff = @import("../util/handoff.zig");
const log = @import("../log.zig");

const slog = log.Scoped("map");

/// A send answers only once every character's waypoints are set, an ESI call each.
const SEND_TIMEOUT_MS: c_int = 120_000;

const Method = enum { get, post, put };

/// Lives as long as the app, since its threads may outlast the panel's window.
pub const EveStarsFeed = struct {
    characters: Call(evestars.Targets, evestars.parseTargets) = .{},
    send: Call(evestars.Notice, evestars.parseSend) = .{},
    bridges: Call(evestars.Bridges, evestars.parseBridges) = .{},
    avoid: Call(evestars.AvoidList, evestars.parseAvoid) = .{},
    /// Apart from `avoid`, so a change isn't refused while the list is being read.
    avoid_change: Call(evestars.AvoidList, evestars.parseAvoid) = .{},
    plan: Call(evestars.Routes, evestars.parseRoutes) = .{},

    /// After the calls' threads have finished.
    pub fn deinit(self: *EveStarsFeed) void {
        _ = self.characters.take();
        _ = self.send.take();
        _ = self.bridges.take();
        _ = self.avoid.take();
        _ = self.avoid_change.take();
        _ = self.plan.take();
    }

    pub fn isBusy(self: *const EveStarsFeed) bool {
        return self.characters.isBusy() or self.send.isBusy() or self.bridges.isBusy() or self.avoid.isBusy() or self.avoid_change.isBusy() or self.plan.isBusy();
    }

    pub fn startCharacters(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8) void {
        _ = self.characters.start(allocator, token, evestars.CHARACTERS_URL, .get, null);
    }

    pub fn startBridges(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8) void {
        _ = self.bridges.start(allocator, token, evestars.ANSIBLEX_URL, .get, null);
    }

    /// Whether the read started.
    pub fn startAvoid(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8) bool {
        return self.avoid.start(allocator, token, evestars.AVOID_URL, .get, null);
    }

    /// Replaces the account's list with `list`; whether the change started.
    pub fn startAvoidChange(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8, list: *const evestars.AvoidList) !bool {
        const body = try evestars.avoidBody(allocator, list);
        defer allocator.free(body);
        return self.avoid_change.start(allocator, token, evestars.AVOID_URL, .put, body);
    }

    /// Plans from `from_id` to `to_id`, setting nothing; whether the plan started.
    pub fn startPlan(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8, from_id: u32, to_id: u32, options: *const evestars.RouteOptions) !bool {
        const url = try evestars.routeUrl(allocator, from_id, to_id, options);
        defer allocator.free(url);
        return self.plan.start(allocator, token, url, .get, null);
    }

    /// Whether the send started.
    pub fn startSend(self: *EveStarsFeed, allocator: std.mem.Allocator, token: []const u8, system_id: u32, target_ids: []const u64, options: *const evestars.RouteOptions) !bool {
        const url = try evestars.sendUrl(allocator, system_id, target_ids, options);
        defer allocator.free(url);
        return self.send.start(allocator, token, url, .post, null);
    }
};

pub fn Reply(comptime T: type) type {
    return union(enum) { answer: T, failure: evestars.Failure };
}

/// One endpoint: a call at a time, as two sends to one character would race in its client.
fn Call(comptime T: type, comptime parse: fn (std.mem.Allocator, []const u8) anyerror!T) type {
    return struct {
        /// Shared with the call's thread.
        job: handoff.Job(Delivery) = .{},

        const Self = @This();

        const Delivery = struct {
            allocator: std.mem.Allocator,
            reply: Reply(T),
        };

        /// What the call's thread owns, freed as it ends.
        const Request = struct {
            /// Owned.
            url: []u8,
            /// Owned.
            header: []u8,
            method: Method,
            /// Owned; null for a call that sends none.
            body: ?[]u8,

            fn deinit(self: Request, allocator: std.mem.Allocator) void {
                allocator.free(self.url);
                allocator.free(self.header);
                if (self.body) |body| allocator.free(body);
            }
        };

        pub fn isBusy(self: *const Self) bool {
            return self.job.isBusy();
        }

        /// Whether the call started, false if one is running or it couldn't, which it logs; `url`, `token` and `body` are copied.
        pub fn start(self: *Self, allocator: std.mem.Allocator, token: []const u8, url: []const u8, method: Method, body: ?[]const u8) bool {
            if (!self.job.claim()) return false;
            self.spawnCall(allocator, token, url, method, body) catch |err| {
                slog.err("Failed to start a call to Eve Stars: {}", .{err});
                self.job.finish();
                return false;
            };
            return true;
        }

        pub fn take(self: *Self) ?Reply(T) {
            const delivery = self.job.take() orelse return null;
            defer delivery.allocator.destroy(delivery);
            return delivery.reply;
        }

        fn spawnCall(self: *Self, allocator: std.mem.Allocator, token: []const u8, url: []const u8, method: Method, body: ?[]const u8) !void {
            const owned_url = try allocator.dupe(u8, url);
            errdefer allocator.free(owned_url);
            const header = try evestars.authorization(allocator, token);
            errdefer allocator.free(header);
            const owned_body: ?[]u8 = if (body) |text| try allocator.dupe(u8, text) else null;
            errdefer if (owned_body) |text| allocator.free(text);
            try detached.spawn(thread, .{ self, allocator, Request{ .url = owned_url, .header = header, .method = method, .body = owned_body } });
        }

        /// The call's thread, which owns `request`; touches nothing of the main thread's but this call's job and the allocator.
        fn thread(self: *Self, allocator: std.mem.Allocator, request: Request) void {
            defer self.job.finish();
            defer request.deinit(allocator);
            const delivery = allocator.create(Delivery) catch |err| {
                slog.err("Failed to keep Eve Stars' reply: {}", .{err});
                return;
            };
            delivery.* = .{ .allocator = allocator, .reply = call(allocator, &request) };
            if (self.job.deliver(delivery)) |unclaimed| allocator.destroy(unclaimed);
        }

        fn call(allocator: std.mem.Allocator, request: *const Request) Reply(T) {
            // Logs its own failures.
            var session = http_client.Session.init() catch return .{ .failure = .unreachedService() };
            defer session.deinit();
            const headers = [_]http_client.Header{.{ .name = "Authorization", .value = request.header }};
            var options: http_client.FetchOptions = .{ .extra_headers = &headers };
            switch (request.method) {
                .get => {},
                .post => {
                    options.payload = "";
                    options.receive_timeout_ms = SEND_TIMEOUT_MS;
                },
                .put => {
                    options.verb = .put;
                    options.payload = request.body orelse "";
                    options.content_type = "application/json";
                },
            }
            // Logs its own failures.
            const response = session.send(allocator, request.url, options) catch return .{ .failure = .unreachedService() };
            defer response.deinit(allocator);

            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            if (response.status != 200) {
                slog.warn("Failed to call Eve Stars at '{s}': status {d}: {s}", .{ request.url, response.status, http_client.loggedBody(response.body) });
                return .{ .failure = evestars.failureOf(arena.allocator(), response.status, response.body) };
            }
            const answer = parse(arena.allocator(), response.body) catch |err| {
                slog.warn("Failed to read Eve Stars' answer from '{s}': {}", .{ request.url, err });
                return .{ .failure = .unreadableAnswer() };
            };
            return .{ .answer = answer };
        }
    };
}
