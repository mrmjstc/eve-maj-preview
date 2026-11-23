//! Character portraits from EVE's image server, kept on disk for good and in memory for the app's run; main thread only, bar the load threads.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const wic = @import("../../platform/wic.zig");
const files = @import("../../config/files.zig");
const session = @import("session.zig");
const http_client = @import("../../util/http_client.zig");
const rgba = @import("../../util/rgba.zig");
const detached = @import("../../util/detached.zig");
const handoff = @import("../../util/handoff.zig");
const messages = @import("../../messages.zig");
const atomic_file = @import("../../util/atomic_file.zig");
const log = @import("../../log.zig");

const Image = ui.component.Image;
const slog = log.Scoped("dialog_knots");

/// The image server's smallest size, still sharp for a 16px portrait at 200% scale.
const FETCH_SIZE = 32;
const URL_FORMAT = "https://images.evetech.net/characters/{s}/portrait?size={d}";
const PATH_FORMAT = files.PORTRAITS_DIR ++ "/{s}.jpg";
/// 3px at the roster's 16px; knots doesn't round images, so it's baked into the pixels.
pub const CORNER_RADIUS = 6;
/// A cached file past this isn't a 32px portrait, so it's fetched again.
const MAX_FILE_BYTES = 256 * 1024;
/// Fills a roster quickly without opening a connection per character at once.
const MAX_LOADS = 4;

/// Waits in `takeAll` until the main thread takes it.
pub const Loaded = struct {
    /// Owned; freed in deinit.
    id: []const u8,
    /// Null when it couldn't be read, fetched or decoded; owned, freed in deinit unless taken.
    image: ?wic.Decoded,
    /// The next result, linked by handoff.Stack.
    next: ?*Loaded = null,

    pub fn deinit(self: *Loaded) void {
        if (self.image) |decoded| decoded.deinit(g_allocator);
        g_allocator.free(self.id);
        g_allocator.destroy(self);
    }
};

const Entry = struct {
    image: ?wic.Decoded = null,
    is_loading: bool = true,
    /// Tells portraits' textures apart, since knots caches a texture by its key.
    serial: usize,
};

/// Set once by setAllocator, before any load thread starts; read by them too.
var g_allocator: std.mem.Allocator = undefined;
var g_timer_hwnd: ?win32.HWND = null;
var g_command: usize = 0;
/// Keyed by character ID. Keys and images owned; freed in deinit.
var g_entries: std.StringHashMapUnmanaged(Entry) = .empty;
var g_next_serial: usize = 0;
/// Pushed by load threads, taken by the main thread.
var g_results: handoff.Stack(Loaded) = .{};
/// IDs waiting for one of the MAX_LOADS, oldest first; each owned, freed in deinit.
var g_waiting: std.ArrayList([]const u8) = .empty;
/// Raised by the main thread as it starts a load, lowered by the load's thread before it hands back its result.
var g_load_count: std.atomic.Value(u32) = .init(0);

/// Once at startup, since a load thread can outlive the window that started it.
pub fn setAllocator(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Main thread: the portraits loaded since the last call, oldest first through `next`; pass each to `store`.
pub fn takeAll() ?*Loaded {
    return g_results.takeAll();
}

/// Each time the window opens: `timer_hwnd` receives `command` as each portrait loads, and portraits that failed are tried again.
pub fn init(timer_hwnd: ?win32.HWND, command: usize) void {
    g_timer_hwnd = timer_hwnd;
    g_command = command;
    var it = g_entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.image != null or entry.value_ptr.is_loading) continue;
        const key = entry.key_ptr.*;
        g_entries.removeByPtr(entry.key_ptr);
        g_allocator.free(key);
        it = g_entries.iterator();
    }
}

/// At app exit; a load still running leaves a result nothing takes, which goes with the process.
pub fn deinit() void {
    var it = g_entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.image) |decoded| decoded.deinit(g_allocator);
        g_allocator.free(entry.key_ptr.*);
    }
    g_entries.deinit(g_allocator);
    g_entries = .empty;
    for (g_waiting.items) |id| g_allocator.free(id);
    g_waiting.deinit(g_allocator);
    g_waiting = .empty;
}

/// Starts loading `name`'s portrait, if its ID is known, so it's ready before the roster is shown.
pub fn preload(name: []const u8) void {
    const id = lookUp(g_allocator, name) orelse return;
    defer g_allocator.free(id);
    if (!g_entries.contains(id)) request(id);
}

/// Null until loaded or while its ID is unknown; the first call starts loading it.
pub fn image(arena: std.mem.Allocator, key: ui.Key, name: []const u8, image_style: *const ui.Style) ?Image {
    const id = lookUp(arena, name) orelse return null;
    const entry = g_entries.getPtr(id) orelse {
        request(id);
        return null;
    };
    const decoded = entry.image orelse return null;
    return .{
        .key = key.indexed(entry.serial),
        .source = .{ .pixels = .{
            .data = decoded.pixels,
            .width = decoded.width,
            .height = decoded.height,
            .format = .rgba8_srgb,
            .upload_policy = .versioned,
            .version = 1,
        } },
        .style = image_style,
    };
}

/// Takes ownership of `loaded`, then starts any loads waiting for its slot.
pub fn store(loaded: *Loaded) void {
    defer startWaiting();
    defer loaded.deinit();
    const entry = g_entries.getPtr(loaded.id) orelse return;
    entry.is_loading = false;
    if (entry.image != null) return;
    entry.image = loaded.image;
    loaded.image = null;
}

/// Caller owns the result; null when the ID isn't known yet.
fn lookUp(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return session.appContext().character_ids.get(allocator, name) catch |err| {
        slog.warn("Failed to look up the character ID of '{s}': {}", .{ name, err });
        return null;
    };
}

/// A failure leaves the entry empty until the window reopens, rather than retrying every frame.
fn request(id: []const u8) void {
    const entry = addEntry(id) catch |err| {
        slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
        return;
    };
    queueLoad(id) catch |err| {
        slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
        entry.is_loading = false;
        return;
    };
    startWaiting();
}

fn queueLoad(id: []const u8) !void {
    const owned_id = try g_allocator.dupe(u8, id);
    errdefer g_allocator.free(owned_id);
    try g_waiting.append(g_allocator, owned_id);
}

/// One that can't start leaves its entry empty until the window reopens, as request does.
fn startWaiting() void {
    while (g_waiting.items.len > 0 and g_load_count.load(.acquire) < MAX_LOADS) {
        const id = g_waiting.orderedRemove(0);
        startLoad(id) catch |err| {
            slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
            if (g_entries.getPtr(id)) |entry| entry.is_loading = false;
            g_allocator.free(id);
        };
    }
}

fn addEntry(id: []const u8) !*Entry {
    const owned_id = try g_allocator.dupe(u8, id);
    errdefer g_allocator.free(owned_id);
    const slot = try g_entries.getOrPut(g_allocator, owned_id);
    slot.value_ptr.* = .{ .serial = g_next_serial };
    g_next_serial += 1;
    return slot.value_ptr;
}

/// Takes ownership of `id` once the load has started; only the main thread raises the count, so its check can't be raced.
fn startLoad(id: []const u8) !void {
    const timer_hwnd = g_timer_hwnd orelse return error.MissingTimerWindow;
    _ = g_load_count.fetchAdd(1, .monotonic);
    errdefer _ = g_load_count.fetchSub(1, .monotonic);
    try detached.spawn(loadThread, .{ session.appContext().io, timer_hwnd, g_command, id });
}

/// Takes ownership of `id`; shares only the allocator, the load count, the results and the posted message with the main thread.
fn loadThread(io: std.Io, timer_hwnd: win32.HWND, command: usize, id: []const u8) void {
    const loaded = g_allocator.create(Loaded) catch |err| {
        _ = g_load_count.fetchSub(1, .release);
        slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
        g_allocator.free(id);
        return;
    };
    loaded.* = .{ .id = id, .image = load(io, id) catch |err| blk: {
        slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
        break :blk null;
    } };
    // Before the result goes, so the main thread taking it finds the slot free for the next.
    _ = g_load_count.fetchSub(1, .release);
    g_results.push(loaded);
    // `id` belongs to the stack now, and the main thread may already have freed it.
    if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, command, 0))) {
        slog.warn("Failed to pass on a character portrait, it waits for the next one: error {d}", .{win32.GetLastError()});
    }
}

/// From the disk cache, or else fetched once and saved there; a cached file is never fetched again.
fn load(io: std.Io, id: []const u8) !wic.Decoded {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, PATH_FORMAT, .{id});
    if (readCached(io, path)) |cached| {
        defer g_allocator.free(cached);
        if (decode(cached)) |decoded| return decoded else |err| {
            slog.warn("Failed to decode the cached portrait '{s}', fetching it again: {}", .{ path, err });
        }
    }

    const body = try fetch(id);
    defer g_allocator.free(body);
    const decoded = try decode(body);
    save(io, path, body);
    return decoded;
}

fn decode(encoded: []const u8) !wic.Decoded {
    const decoded = try wic.decodeRgba(g_allocator, encoded);
    rgba.roundCorners(decoded.pixels, decoded.width, decoded.height, CORNER_RADIUS);
    return decoded;
}

/// Null when it isn't cached yet, or can't be read.
fn readCached(io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, g_allocator, .limited(MAX_FILE_BYTES)) catch |err| {
        if (err != error.FileNotFound) slog.warn("Failed to read the cached portrait '{s}', fetching it again: {}", .{ path, err });
        return null;
    };
}

/// Caller frees.
fn fetch(id: []const u8) ![]u8 {
    var http_session: http_client.Session = try .init();
    defer http_session.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, URL_FORMAT, .{ id, FETCH_SIZE });
    return http_session.fetch(g_allocator, url, .{});
}

/// A portrait that can't be saved still shows; it's fetched again next run.
fn save(io: std.Io, path: []const u8, body: []const u8) void {
    files.createDirIfMissing(io, files.PORTRAITS_DIR) catch |err| {
        slog.warn("Failed to create folder '{s}': {}", .{ files.PORTRAITS_DIR, err });
        return;
    };
    atomic_file.write(g_allocator, io, path, body) catch return;
}
