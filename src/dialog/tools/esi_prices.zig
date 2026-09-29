const std = @import("std");
const http_client = @import("../../util/http_client.zig");
const log = @import("../../log.zig");
const slog = log.scoped("esi_prices");

const ESI_BASE = "https://esi.evetech.net/latest";
const ESI_JITA_REGION_ID = 10000002;
const ESI_JITA_STATION_ID: i64 = 60003760;

/// Resolves "Compressed <name>" -> ESI type_id for each ore name via the public (no-auth) ESI name resolver.
/// Names with no market match are simply absent from the result. Caller frees both the keys and the map.
fn resolveOreTypeIds(allocator: std.mem.Allocator, client: *std.http.Client, names: []const []const u8) !std.StringHashMap(i64) {
    var result = std.StringHashMap(i64).init(allocator);
    errdefer result.deinit();
    if (names.len == 0) return result;

    const prefixed = try allocator.alloc([]const u8, names.len);
    defer {
        for (prefixed) |p| allocator.free(p);
        allocator.free(prefixed);
    }
    for (names, 0..) |name, i| {
        prefixed[i] = try std.fmt.allocPrint(allocator, "Compressed {s}", .{name});
    }

    const body = try std.json.Stringify.valueAlloc(allocator, prefixed, .{});
    defer allocator.free(body);

    const stdout = http_client.fetch(allocator, client, ESI_BASE ++ "/universe/ids/?datasource=tranquility", .{
        .content_type = "application/json",
        .payload = body,
    }) catch return result;
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch |err| {
        slog.warn("Failed to parse ESI universe/ids response: {}", .{err});
        return result;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        slog.warn("ESI universe/ids response was not a JSON object: {s}", .{stdout});
        return result;
    }
    const inventory_types = parsed.value.object.get("inventory_types") orelse {
        slog.warn("ESI universe/ids response had no inventory_types field: {s}", .{stdout});
        return result;
    };
    if (inventory_types != .array) {
        slog.warn("ESI universe/ids inventory_types was not an array: {s}", .{stdout});
        return result;
    }

    for (inventory_types.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const name_val = item.object.get("name") orelse continue;
        if (id_val != .integer or name_val != .string) continue;

        const prefix = "Compressed ";
        if (!std.mem.startsWith(u8, name_val.string, prefix)) continue;
        const base_name = name_val.string[prefix.len..];

        const key = try allocator.dupe(u8, base_name);
        errdefer allocator.free(key);
        try result.put(key, id_val.integer);
    }

    return result;
}

/// Highest current Jita 4-4 buy order price for type_id (what a seller would instantly receive), or null if unavailable/illiquid.
/// Only reads page 1 of the region's buy orders - fine for these commodity ore types, whose buy-order counts stay well under the 1000-order page size in practice.
fn fetchJitaBuyPrice(allocator: std.mem.Allocator, client: *std.http.Client, type_id: i64) ?f64 {
    const url = std.fmt.allocPrint(allocator, ESI_BASE ++ "/markets/{d}/orders/?datasource=tranquility&order_type=buy&type_id={d}", .{ ESI_JITA_REGION_ID, type_id }) catch |err| {
        slog.warn("Failed to build ESI price URL for type_id {}: {}", .{ type_id, err });
        return null;
    };
    defer allocator.free(url);

    const stdout = http_client.fetch(allocator, client, url, .{}) catch return null;
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch |err| {
        slog.warn("Failed to parse ESI price response for type_id {}: {}", .{ type_id, err });
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return null;

    var best: ?f64 = null;
    for (parsed.value.array.items) |order| {
        if (order != .object) continue;
        const location_val = order.object.get("location_id") orelse continue;
        if (location_val != .integer or location_val.integer != ESI_JITA_STATION_ID) continue;

        const price_val = order.object.get("price") orelse continue;
        const price: f64 = switch (price_val) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => continue,
        };
        if (best == null or price > best.?) best = price;
    }
    return best;
}

/// Caps how many HTTP requests run at once for a price fetch - bounded so this stays polite to ESI rather than opening dozens of connections at once.
const MAX_CONCURRENT_PRICE_REQUESTS = 8;

const PriceLookup = struct {
    name: []const u8,
    type_id: i64,
};

const PriceFetchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    lookups: []const PriceLookup,
    next_index: std.atomic.Value(usize),
    results_mutex: std.Io.Mutex = .init,
    results: *std.ArrayList(Price),
};

/// Pulls lookups off ctx's shared index until exhausted; safe to run on several threads (including the caller's) at once.
fn priceFetchWorker(ctx: *PriceFetchContext) void {
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.lookups.len) return;

        const lookup = ctx.lookups[i];
        const price = fetchJitaBuyPrice(ctx.allocator, ctx.client, lookup.type_id) orelse continue;

        ctx.results_mutex.lock(ctx.io) catch |err| {
            slog.warn("Failed to lock price results mutex for {s}: {}", .{ lookup.name, err });
            continue;
        };
        defer ctx.results_mutex.unlock(ctx.io);
        ctx.results.append(ctx.allocator, .{ .name = lookup.name, .price = price }) catch |err| {
            slog.warn("Failed to store price for {s}: {}", .{ lookup.name, err });
        };
    }
}

pub const Price = struct {
    name: []const u8,
    price: f64,
};

/// Serialized as a `{name: price}` object.
pub const Prices = struct {
    items: []const Price,

    pub fn jsonStringify(self: Prices, jw: anytype) !void {
        try jw.beginObject();
        for (self.items) |p| {
            try jw.objectField(p.name);
            try jw.write(p.price);
        }
        try jw.endObject();
    }
};

/// Looks up each ore name's Jita buy price via its compressed variant (readily liquid there) using the public ESI API - no key required.
/// Names with no market match are left out. `gpa` must be thread-safe, since the requests run in parallel; the result is allocated from `out`.
pub fn fetchOrePrices(gpa: std.mem.Allocator, out: std.mem.Allocator, io: std.Io, names: []const []const u8) !Prices {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var type_ids = try resolveOreTypeIds(gpa, &client, names);
    defer {
        var key_it = type_ids.keyIterator();
        while (key_it.next()) |k| gpa.free(k.*);
        type_ids.deinit();
    }

    var results: std.ArrayList(Price) = .empty;
    defer results.deinit(gpa);

    const lookups = try gpa.alloc(PriceLookup, type_ids.count());
    defer gpa.free(lookups);
    {
        var idx: usize = 0;
        var it = type_ids.iterator();
        while (it.next()) |entry| : (idx += 1) {
            lookups[idx] = .{ .name = entry.key_ptr.*, .type_id = entry.value_ptr.* };
        }
    }

    if (lookups.len > 0) {
        var ctx = PriceFetchContext{
            .allocator = gpa,
            .io = io,
            .client = &client,
            .lookups = lookups,
            .next_index = std.atomic.Value(usize).init(0),
            .results = &results,
        };

        // Spawn up to MAX_CONCURRENT_PRICE_REQUESTS - 1 background workers; the calling thread pulls from the same queue as the last one, so a failed spawn just means less parallelism, not less work done.
        const worker_count = @min(MAX_CONCURRENT_PRICE_REQUESTS, lookups.len);
        var threads = [_]?std.Thread{null} ** (MAX_CONCURRENT_PRICE_REQUESTS - 1);
        const background_workers = worker_count - 1;
        for (threads[0..background_workers]) |*slot| {
            slot.* = std.Thread.spawn(.{}, priceFetchWorker, .{&ctx}) catch |err| blk: {
                slog.warn("Failed to spawn price-fetch worker: {}", .{err});
                break :blk null;
            };
        }
        priceFetchWorker(&ctx);
        for (threads[0..background_workers]) |maybe_t| {
            if (maybe_t) |t| t.join();
        }
    }

    const copied = try out.alloc(Price, results.items.len);
    for (results.items, copied) |r, *c| c.* = .{ .name = try out.dupe(u8, r.name), .price = r.price };
    return .{ .items = copied };
}
