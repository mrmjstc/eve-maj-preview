//! Jita buy prices for ores from EVE's public ESI API, fetched in parallel.
const std = @import("std");
const http_client = @import("../../util/http_client.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("esi_prices");

const ESI_BASE = "https://esi.evetech.net/latest";
const ESI_JITA_REGION_ID = 10000002;
const ESI_JITA_STATION_ID: i64 = 60003760;

/// Most requests a price fetch runs at once, to stay polite to ESI.
const MAX_CONCURRENT_PRICE_REQUESTS = 8;

/// name is copied into the caller's arena before it's returned.
pub const Price = struct {
    name: []const u8,
    price: f64,
};

/// Serialized as a `{name: price}` object.
pub const Prices = struct {
    items: []const Price,

    pub fn jsonStringify(self: Prices, json_writer: anytype) !void {
        try json_writer.beginObject();
        for (self.items) |entry| {
            try json_writer.objectField(entry.name);
            try json_writer.write(entry.price);
        }
        try json_writer.endObject();
    }
};

/// name borrows from the type ID map.
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
    /// Guarded by results_mutex.
    results: *std.ArrayList(Price),
};

/// Each ore's Jita buy price via its compressed variant, from the public ESI API, leaving out unmatched names; `allocator` must be thread-safe, and the result is in `arena`.
pub fn fetchOrePrices(allocator: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, names: []const []const u8) !Prices {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var type_ids = try resolveOreTypeIds(allocator, &client, names);
    defer {
        var it = type_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        type_ids.deinit();
    }

    var results: std.ArrayList(Price) = .empty;
    defer results.deinit(allocator);

    const lookups = try allocator.alloc(PriceLookup, type_ids.count());
    defer allocator.free(lookups);
    {
        var index: usize = 0;
        var it = type_ids.iterator();
        while (it.next()) |entry| : (index += 1) {
            lookups[index] = .{ .name = entry.key_ptr.*, .type_id = entry.value_ptr.* };
        }
    }

    if (lookups.len > 0) {
        var context = PriceFetchContext{
            .allocator = allocator,
            .io = io,
            .client = &client,
            .lookups = lookups,
            .next_index = .init(0),
            .results = &results,
        };

        // The calling thread works the queue too, so a failed spawn only costs parallelism.
        const worker_count = @min(MAX_CONCURRENT_PRICE_REQUESTS, lookups.len);
        var threads: [MAX_CONCURRENT_PRICE_REQUESTS - 1]?std.Thread = @splat(null);
        const background_workers = worker_count - 1;
        for (threads[0..background_workers]) |*slot| {
            slot.* = std.Thread.spawn(.{}, priceFetchWorker, .{&context}) catch |err| blk: {
                slog.warn("Failed to spawn price-fetch worker: {}", .{err});
                break :blk null;
            };
        }
        priceFetchWorker(&context);
        for (threads[0..background_workers]) |maybe_thread| {
            if (maybe_thread) |thread| thread.join();
        }
    }

    const copied = try arena.alloc(Price, results.items.len);
    for (results.items, copied) |result, *copy| copy.* = .{ .name = try arena.dupe(u8, result.name), .price = result.price };
    return .{ .items = copied };
}

/// ESI type IDs for each "Compressed <name>" from the public name resolver, leaving out unmatched names; the caller frees the keys and the map.
fn resolveOreTypeIds(allocator: std.mem.Allocator, client: *std.http.Client, names: []const []const u8) !std.StringHashMap(i64) {
    var result: std.StringHashMap(i64) = .init(allocator);
    errdefer {
        var it = result.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        result.deinit();
    }
    if (names.len == 0) return result;

    const prefixed = try allocator.alloc([]const u8, names.len);
    defer {
        for (prefixed) |name| allocator.free(name);
        allocator.free(prefixed);
    }
    for (names, 0..) |name, i| {
        prefixed[i] = try allocator.print("Compressed {s}", .{name});
    }

    const body = try std.json.Stringify.valueAlloc(allocator, prefixed, .{});
    defer allocator.free(body);

    const response = http_client.fetch(allocator, client, ESI_BASE ++ "/universe/ids/?datasource=tranquility", .{
        .content_type = "application/json",
        .payload = body,
    }) catch return result;
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| {
        slog.warn("Failed to parse ESI universe/ids response: {}", .{err});
        return result;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        slog.warn("Failed to read ESI type IDs: response isn't a JSON object: {s}", .{response});
        return result;
    }
    const inventory_types = parsed.value.object.get("inventory_types") orelse {
        slog.warn("Failed to read ESI type IDs: no inventory_types field: {s}", .{response});
        return result;
    };
    if (inventory_types != .array) {
        slog.warn("Failed to read ESI type IDs: inventory_types isn't an array: {s}", .{response});
        return result;
    }

    for (inventory_types.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        const name_value = item.object.get("name") orelse continue;
        if (id_value != .integer or name_value != .string) continue;

        const prefix = "Compressed ";
        if (!std.mem.startsWith(u8, name_value.string, prefix)) continue;
        const base_name = name_value.string[prefix.len..];

        const key = try allocator.dupe(u8, base_name);
        errdefer allocator.free(key);
        try result.put(key, id_value.integer);
    }

    return result;
}

/// The highest Jita 4-4 buy order for type_id, or null if there's none; reads only page 1, which these ores' order counts stay well under.
fn fetchJitaBuyPrice(allocator: std.mem.Allocator, client: *std.http.Client, type_id: i64) ?f64 {
    const url = allocator.print(ESI_BASE ++ "/markets/{d}/orders/?datasource=tranquility&order_type=buy&type_id={d}", .{ ESI_JITA_REGION_ID, type_id }) catch |err| {
        slog.warn("Failed to build ESI price URL for type_id {}: {}", .{ type_id, err });
        return null;
    };
    defer allocator.free(url);

    const response = http_client.fetch(allocator, client, url, .{}) catch return null;
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| {
        slog.warn("Failed to parse ESI price response for type_id {}: {}", .{ type_id, err });
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        slog.warn("Failed to read ESI prices for type_id {}: response isn't a JSON array", .{type_id});
        return null;
    }

    var best: ?f64 = null;
    for (parsed.value.array.items) |order| {
        if (order != .object) continue;
        const location_value = order.object.get("location_id") orelse continue;
        if (location_value != .integer or location_value.integer != ESI_JITA_STATION_ID) continue;

        const price_value = order.object.get("price") orelse continue;
        const price: f64 = switch (price_value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => continue,
        };
        best = if (best) |current| @max(current, price) else price;
    }
    return best;
}

/// Pulls lookups off context's shared index until exhausted; safe to run on several threads (including the caller's) at once.
fn priceFetchWorker(context: *PriceFetchContext) void {
    while (true) {
        const lookup_index = context.next_index.fetchAdd(1, .monotonic);
        if (lookup_index >= context.lookups.len) return;

        const lookup = context.lookups[lookup_index];
        const price = fetchJitaBuyPrice(context.allocator, context.client, lookup.type_id) orelse continue;

        context.results_mutex.lock(context.io) catch |err| {
            slog.warn("Failed to lock price results mutex for '{s}': {}", .{ lookup.name, err });
            continue;
        };
        defer context.results_mutex.unlock(context.io);
        context.results.append(context.allocator, .{ .name = lookup.name, .price = price }) catch |err| {
            slog.warn("Failed to store price for '{s}': {}", .{ lookup.name, err });
        };
    }
}
