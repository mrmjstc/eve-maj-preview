const std = @import("std");
const webui = @import("webui");
const http_client = @import("http_client.zig");
const log = @import("log.zig");
const slog = log.scoped("esi_prices");

var g_allocator: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    g_allocator = allocator;
    g_io = io;
}

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
    }) orelse return result;
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
    const url = std.fmt.allocPrint(allocator, ESI_BASE ++ "/markets/{d}/orders/?datasource=tranquility&order_type=buy&type_id={d}", .{ ESI_JITA_REGION_ID, type_id }) catch return null;
    defer allocator.free(url);

    const stdout = http_client.fetch(allocator, client, url, .{}) orelse return null;
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch return null;
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
    client: *std.http.Client,
    lookups: []const PriceLookup,
    next_index: std.atomic.Value(usize),
    results_mutex: std.Io.Mutex = .init,
    results: *std.json.ObjectMap,
};

/// Pulls lookups off ctx's shared index until exhausted; safe to run on several threads (including the caller's) at once.
fn priceFetchWorker(ctx: *PriceFetchContext) void {
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.lookups.len) return;

        const lookup = ctx.lookups[i];
        const price = fetchJitaBuyPrice(ctx.allocator, ctx.client, lookup.type_id) orelse continue;

        ctx.results_mutex.lock(g_io) catch continue;
        defer ctx.results_mutex.unlock(g_io);
        ctx.results.put(ctx.allocator, lookup.name, .{ .float = price }) catch {};
    }
}

/// Looks up each ore name's Jita buy price via its compressed variant (readily liquid there) using the public ESI API - no key required.
/// Request body: JSON array of ore names. Response: JSON object of {name: price}, omitting names with no market match.
pub fn fetchOrePrices(e: *webui.Event) void {
    const allocator = g_allocator;
    const json_data = e.getString();

    var client: std.http.Client = .{ .allocator = allocator, .io = g_io };
    defer client.deinit();

    const parsed_names = std.json.parseFromSlice([]const []const u8, allocator, json_data, .{}) catch |err| {
        slog.warn("Failed to parse fetchOrePrices request: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer parsed_names.deinit();

    var type_ids = resolveOreTypeIds(allocator, &client, parsed_names.value) catch |err| {
        slog.warn("Failed to resolve ore type ids via ESI: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer {
        var key_it = type_ids.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        type_ids.deinit();
    }

    var results: std.json.ObjectMap = .empty;
    defer results.deinit(allocator);

    const lookups = allocator.alloc(PriceLookup, type_ids.count()) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(lookups);
    {
        var idx: usize = 0;
        var it = type_ids.iterator();
        while (it.next()) |entry| : (idx += 1) {
            lookups[idx] = .{ .name = entry.key_ptr.*, .type_id = entry.value_ptr.* };
        }
    }

    if (lookups.len > 0) {
        var ctx = PriceFetchContext{
            .allocator = allocator,
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

    const json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = results }, .{}) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(json);
    const json_z = allocator.dupeZ(u8, json) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}
