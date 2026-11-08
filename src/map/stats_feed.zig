//! Fetches the Map Panel's ESI figures, faction warfare and sov campaigns, EVE-Scout's storms and wormhole hubs, and alliances' logo colours on a background thread, and hands each to the main thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wic = @import("../platform/wic.zig");
const files = @import("../config/files.zig");
const stats = @import("stats.zig");
const holder_colors = @import("holder_colors.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const LogoColors = holder_colors.LogoColors;
const Snapshot = stats.Snapshot;
const slog = log.Scoped("map");

const ESI_BASE = "https://esi.evetech.net/latest";
const ESI_QUERY = "/?datasource=tranquility";
const EVE_SCOUT_OBSERVATIONS = "https://api.eve-scout.com/v2/public/observations";
const EVE_SCOUT_SIGNATURES = "https://api.eve-scout.com/v2/public/signatures?system_name=";
/// ESI's per-system figures refresh hourly; asked more often so a new hour shows soon after it lands.
const REFRESH_INTERVAL_MS: u64 = 15 * std.time.ms_per_min;
const RETRY_INTERVAL_MS: u64 = 2 * std.time.ms_per_min;
/// /universe/names/ takes at most this many ids.
const MAX_NAMES_REQUESTED = 1000;
const LOGO_URL_FORMAT = "https://images.evetech.net/alliances/{d}/logo?size={d}";
/// Enough pixels to tell a logo's colours apart, at a few KB a logo.
const LOGO_SIZE = 64;
/// Far past MAX_ALLIANCES' worth of entries.
const MAX_LOGO_COLORS_FILE_SIZE = 64 * 1024;

/// Lives as long as the app, since its thread may outlast the panel's window.
pub const StatsFeed = struct {
    /// Main thread only.
    next_fetch: win32.Ticks = .{},
    /// Set while the fetch thread runs.
    is_busy: std.atomic.Value(bool) = .init(false),
    /// Set by the fetch thread when nothing arrived; the main thread clears it.
    has_failed: std.atomic.Value(bool) = .init(false),
    /// The newest snapshot not yet taken; ownership passes with the swap.
    ready: std.atomic.Value(?*Snapshot) = .init(null),
    /// The newest logo colours not yet taken; ownership passes with the swap.
    colors_ready: std.atomic.Value(?*LogoColors) = .init(null),

    /// After the fetch thread has finished; `allocator` is the one poll was given.
    pub fn deinit(self: *StatsFeed, allocator: std.mem.Allocator) void {
        if (self.take()) |snapshot| destroySnapshot(snapshot);
        if (self.takeColors()) |colors| allocator.destroy(colors);
    }

    /// Per tick while the panel shows: starts a fetch once one is due.
    pub fn poll(self: *StatsFeed, allocator: std.mem.Allocator, io: std.Io, now: win32.Ticks) void {
        if (self.has_failed.swap(false, .acq_rel)) self.next_fetch = .{ .ms = now.ms + RETRY_INTERVAL_MS };
        if (now.ms < self.next_fetch.ms or self.is_busy.swap(true, .acq_rel)) return;
        self.next_fetch = .{ .ms = now.ms + REFRESH_INTERVAL_MS };
        detached.spawn(fetchThread, .{ self, allocator, io }) catch |err| {
            slog.err("Failed to fetch map stats: {}", .{err});
            self.is_busy.store(false, .release);
        };
    }

    /// The caller owns the result, and frees it with destroySnapshot.
    pub fn take(self: *StatsFeed) ?*Snapshot {
        return self.ready.swap(null, .acq_rel);
    }

    /// The caller owns the result, and frees it with the allocator poll was given.
    pub fn takeColors(self: *StatsFeed) ?*LogoColors {
        return self.colors_ready.swap(null, .acq_rel);
    }
};

pub fn destroySnapshot(snapshot: *Snapshot) void {
    const allocator = snapshot.allocator;
    snapshot.deinit();
    allocator.destroy(snapshot);
}

/// The fetch's thread; touches nothing of the main thread's but the feed's atomics and the allocator, and alone reads and writes the logo colours' file.
fn fetchThread(feed: *StatsFeed, allocator: std.mem.Allocator, io: std.Io) void {
    defer feed.is_busy.store(false, .release);
    const snapshot = fetchSnapshot(allocator) catch |err| {
        slog.warn("Failed to fetch map stats: {}", .{err});
        feed.has_failed.store(true, .release);
        return;
    };
    // Listed before the snapshot's handed over, as the main thread owns it from then on.
    const alliance_ids: []const u32 = allianceIds(allocator, snapshot) catch |err| blk: {
        slog.warn("Failed to list the alliances holding space: {}", .{err});
        break :blk &.{};
    };
    defer allocator.free(alliance_ids);
    if (feed.ready.swap(snapshot, .acq_rel)) |unclaimed| destroySnapshot(unclaimed);
    // After the figures, so a first run's logos don't hold them up.
    fetchLogoColors(feed, allocator, io, alliance_ids);
}

/// Caller frees.
fn allianceIds(allocator: std.mem.Allocator, snapshot: *const Snapshot) ![]u32 {
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);
    for (snapshot.holder_ids.items) |id| {
        if (!holder_colors.isFaction(id)) try ids.append(allocator, id);
    }
    return ids.toOwnedSlice(allocator);
}

/// Hands over the cached colours at once, then fetches only logos never looked at, so each is fetched once.
fn fetchLogoColors(feed: *StatsFeed, allocator: std.mem.Allocator, io: std.Io, alliance_ids: []const u32) void {
    if (alliance_ids.len == 0) return;
    var colors = readLogoColors(allocator, io);
    if (colors.count > 0) publishColors(feed, allocator, &colors);

    var session = http_client.Session.init() catch |err| {
        slog.warn("Failed to fetch alliance logos: {}", .{err});
        return;
    };
    defer session.deinit();
    var fetched_count: usize = 0;
    for (alliance_ids) |id| {
        if (colors.get(id) != null) continue;
        const logo_color = fetchLogoColor(&session, allocator, id) catch |err| {
            slog.warn("Failed to read the logo of alliance {d}: {}", .{ id, err });
            continue;
        };
        colors.put(id, logo_color);
        fetched_count += 1;
    }
    if (fetched_count == 0) return;
    slog.info("Picked {d} alliance logo colours", .{fetched_count});
    saveLogoColors(allocator, io, &colors);
    publishColors(feed, allocator, &colors);
}

/// NO_COLOR for a logo with no colour to pick.
fn fetchLogoColor(session: *const http_client.Session, allocator: std.mem.Allocator, id: u32) !u32 {
    var url_buf: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, LOGO_URL_FORMAT, .{ id, LOGO_SIZE });
    const body = try session.fetch(allocator, url, .{});
    defer allocator.free(body);
    const decoded = try wic.decodeRgba(allocator, body);
    defer decoded.deinit(allocator);
    return holder_colors.logoColor(decoded.pixels) orelse holder_colors.NO_COLOR;
}

/// Empty while there's no file yet, or it can't be read.
fn readLogoColors(allocator: std.mem.Allocator, io: std.Io) LogoColors {
    const json_text = std.Io.Dir.cwd().readFileAlloc(io, files.LOGO_COLORS_FILE, allocator, .limited(MAX_LOGO_COLORS_FILE_SIZE)) catch |err| {
        if (err != error.FileNotFound) slog.warn("Failed to read '{s}', fetching the logos again: {}", .{ files.LOGO_COLORS_FILE, err });
        return .{};
    };
    defer allocator.free(json_text);
    return .parse(allocator, json_text);
}

/// Colours that can't be saved still show; their logos are fetched again next run.
fn saveLogoColors(allocator: std.mem.Allocator, io: std.Io, colors: *const LogoColors) void {
    const json_text = colors.toJson(allocator) catch |err| {
        slog.warn("Failed to save alliance logo colours: {}", .{err});
        return;
    };
    defer allocator.free(json_text);
    files.atomicWriteFile(allocator, io, files.LOGO_COLORS_FILE, json_text) catch return;
}

fn publishColors(feed: *StatsFeed, allocator: std.mem.Allocator, colors: *const LogoColors) void {
    const handed = allocator.create(LogoColors) catch |err| {
        slog.warn("Failed to pass on alliance logo colours: {}", .{err});
        return;
    };
    handed.* = colors.*;
    if (feed.colors_ready.swap(handed, .acq_rel)) |unclaimed| allocator.destroy(unclaimed);
}

/// Keeps what arrived, each reply's failure logged where it happened; an error only when nothing did.
fn fetchSnapshot(allocator: std.mem.Allocator) !*Snapshot {
    var session = try http_client.Session.init();
    defer session.deinit();

    const snapshot = try allocator.create(Snapshot);
    errdefer allocator.destroy(snapshot);
    snapshot.* = try .init(allocator);
    errdefer snapshot.deinit();

    fetchInto(&session, snapshot, "/universe/system_kills", Snapshot.applyKills);
    fetchInto(&session, snapshot, "/universe/system_jumps", Snapshot.applyJumps);
    fetchInto(&session, snapshot, "/sovereignty/map", Snapshot.applySovereignty);
    fetchInto(&session, snapshot, "/incursions", Snapshot.applyIncursions);
    fetchInto(&session, snapshot, "/sovereignty/campaigns", Snapshot.applyCampaigns);
    fetchInto(&session, snapshot, "/fw/systems", Snapshot.applyWarfare);
    fetchEveScout(&session, snapshot, EVE_SCOUT_OBSERVATIONS, Snapshot.applyStorms, "storms");
    fetchEveScout(&session, snapshot, EVE_SCOUT_SIGNATURES ++ "Thera", Snapshot.applyThera, "Thera connections");
    fetchEveScout(&session, snapshot, EVE_SCOUT_SIGNATURES ++ "Turnur", Snapshot.applyTurnur, "Turnur connections");
    if (!snapshot.hasAnything()) return error.StatsFetchFailed;

    if (snapshot.holder_ids.items.len > 0) fetchHolderNames(&session, snapshot);
    snapshot.fetched_ms = win32.Ticks.now().ms;
    return snapshot;
}

fn fetchInto(session: *const http_client.Session, snapshot: *Snapshot, comptime path: []const u8, comptime apply: fn (*Snapshot, []const u8) anyerror!void) void {
    const allocator = snapshot.allocator;
    // Logs its own failures.
    const body = session.fetch(allocator, ESI_BASE ++ path ++ ESI_QUERY, .{}) catch return;
    defer allocator.free(body);
    apply(snapshot, body) catch |err| {
        slog.warn("Failed to read ESI's '{s}': {}", .{ path, err });
    };
}

/// `what` names the reply in the log.
fn fetchEveScout(session: *const http_client.Session, snapshot: *Snapshot, comptime url: []const u8, comptime apply: fn (*Snapshot, []const u8) anyerror!void, comptime what: []const u8) void {
    const allocator = snapshot.allocator;
    // Logs its own failures.
    const body = session.fetch(allocator, url, .{}) catch return;
    defer allocator.free(body);
    apply(snapshot, body) catch |err| {
        slog.warn("Failed to read EVE-Scout's " ++ what ++ ": {}", .{err});
    };
}

/// Without names the panel only leaves out who holds a system, so a failure isn't one worth retrying.
fn fetchHolderNames(session: *const http_client.Session, snapshot: *Snapshot) void {
    var arena: std.heap.ArenaAllocator = .init(snapshot.allocator);
    defer arena.deinit();
    const ids = snapshot.holder_ids.items;
    if (ids.len == 0) return;
    const request = stats.namesRequest(arena.allocator(), ids[0..@min(ids.len, MAX_NAMES_REQUESTED)]) catch |err| {
        slog.warn("Failed to ask ESI who holds systems: {}", .{err});
        return;
    };
    // Logs its own failures.
    const body = session.fetch(arena.allocator(), ESI_BASE ++ "/universe/names" ++ ESI_QUERY, .{ .content_type = "application/json", .payload = request }) catch return;
    snapshot.applyNames(body) catch |err| {
        slog.warn("Failed to read who holds systems: {}", .{err});
    };
}
