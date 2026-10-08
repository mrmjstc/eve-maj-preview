//! Character portraits from EVE's image server, kept on disk for good and in memory for the app's run; main thread only, bar the load threads.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const wic = @import("../../platform/wic.zig");
const files = @import("../../config/files.zig");
const main = @import("../../main.zig");
const http_client = @import("../../util/http_client.zig");
const rgba = @import("../../util/rgba.zig");
const log = @import("../../log.zig");

const Image = ui.component.Image;
const slog = log.scoped("dialog_knots");

/// The image server's smallest size, still sharp for a 16px portrait at 200% scale.
const FETCH_SIZE = 32;
const URL_FORMAT = "https://images.evetech.net/characters/{s}/portrait?size={d}";
const PATH_FORMAT = files.PORTRAITS_DIR ++ "/{s}.jpg";
/// 3px at the roster's 16px; knots doesn't round images, so it's baked into the pixels.
const CORNER_RADIUS = 6;
/// A cached file past this isn't a 32px portrait, so it's fetched again.
const MAX_FILE_SIZE = 256 * 1024;

/// Sent to the main thread as WM_KNOTS_COMMAND's lParam.
pub const Loaded = struct {
    /// Owned; freed in deinit.
    id: []const u8,
    /// Null when it couldn't be read, fetched or decoded. Owned; freed in deinit unless taken.
    image: ?wic.Decoded,

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

/// Read by the load threads too; set before any starts.
var g_allocator: std.mem.Allocator = undefined;
var g_timer: ?win32.HWND = null;
var g_command: usize = 0;
/// Keyed by character ID. Keys and images owned; freed in deinit.
var g_entries: std.StringHashMapUnmanaged(Entry) = .empty;
var g_next_serial: usize = 0;

/// Each time the window opens: `timer` receives `command` with each *Loaded, and portraits that failed are tried again.
pub fn init(allocator: std.mem.Allocator, timer: ?win32.HWND, command: usize) void {
    g_allocator = allocator;
    g_timer = timer;
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

/// At app exit; a load still running is freed when its result lands.
pub fn deinit() void {
    var it = g_entries.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.image) |decoded| decoded.deinit(g_allocator);
        g_allocator.free(entry.key_ptr.*);
    }
    g_entries.deinit(g_allocator);
    g_entries = .empty;
}

/// Starts loading `name`'s portrait, if its ID is known, so it's ready before the roster is shown.
pub fn preload(name: []const u8) void {
    const id = lookUp(g_allocator, name) orelse return;
    defer g_allocator.free(id);
    if (!g_entries.contains(id)) request(id);
}

/// `name`'s portrait, or null until it has loaded or when its ID isn't known yet; starts loading it the first time.
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

/// Takes ownership of `loaded`.
pub fn store(loaded: *Loaded) void {
    defer loaded.deinit();
    const entry = g_entries.getPtr(loaded.id) orelse return;
    entry.is_loading = false;
    if (entry.image != null) return;
    entry.image = loaded.image;
    loaded.image = null;
}

/// Caller owns the result; null when the ID isn't known yet.
fn lookUp(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return main.g_character_ids.get(allocator, name) catch |err| {
        slog.warn("Failed to look up the character ID of '{s}': {}", .{ name, err });
        return null;
    };
}

/// Adds the entry, then loads it; a failure leaves the entry empty until the window next opens, rather than retrying every frame.
fn request(id: []const u8) void {
    const entry = addEntry(id) catch |err| {
        slog.warn("Failed to load the portrait of character {s}: {}", .{ id, err });
        return;
    };
    startLoad(id) catch |err| {
        slog.warn("Failed to load the portrait of character {s}: {}", .{ id, err });
        entry.is_loading = false;
    };
}

fn addEntry(id: []const u8) !*Entry {
    const owned_id = try g_allocator.dupe(u8, id);
    errdefer g_allocator.free(owned_id);
    const slot = try g_entries.getOrPut(g_allocator, owned_id);
    slot.value_ptr.* = .{ .serial = g_next_serial };
    g_next_serial += 1;
    return slot.value_ptr;
}

fn startLoad(id: []const u8) !void {
    const timer = g_timer orelse return error.MissingTimerWindow;
    const thread_id = try g_allocator.dupe(u8, id);
    errdefer g_allocator.free(thread_id);
    const thread = try std.Thread.spawn(.{}, loadThread, .{ timer, g_command, thread_id });
    thread.detach();
}

/// The load's thread; takes ownership of `id`, and touches nothing of the main thread's but the allocator and the posted message.
fn loadThread(timer: win32.HWND, command: usize, id: []const u8) void {
    const loaded = g_allocator.create(Loaded) catch |err| {
        slog.warn("Failed to load the portrait of character {s}: {}", .{ id, err });
        g_allocator.free(id);
        return;
    };
    loaded.* = .{ .id = id, .image = load(id) catch |err| blk: {
        slog.warn("Failed to load the portrait of character {s}: {}", .{ id, err });
        break :blk null;
    } };
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_KNOTS_COMMAND, command, @bitCast(@intFromPtr(loaded))))) {
        slog.warn("Failed to pass on the portrait of character {s}: error {d}", .{ id, win32.GetLastError() });
        loaded.deinit();
    }
}

/// From the disk cache, or else fetched once and saved there; a cached file is never fetched again.
fn load(id: []const u8) !wic.Decoded {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, PATH_FORMAT, .{id});
    if (readCached(path)) |cached| {
        defer g_allocator.free(cached);
        if (decode(cached)) |decoded| return decoded else |err| {
            slog.warn("Failed to decode the cached portrait '{s}', fetching it again: {}", .{ path, err });
        }
    }

    const body = try fetch(id);
    defer g_allocator.free(body);
    const decoded = try decode(body);
    save(path, body);
    return decoded;
}

fn decode(encoded: []const u8) !wic.Decoded {
    const decoded = try wic.decodeRgba(g_allocator, encoded);
    rgba.roundCorners(decoded.pixels, decoded.width, decoded.height, CORNER_RADIUS);
    return decoded;
}

/// Null when it isn't cached yet, or can't be read.
fn readCached(path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(files.g_io, path, g_allocator, .limited(MAX_FILE_SIZE)) catch |err| {
        if (err != error.FileNotFound) slog.warn("Failed to read the cached portrait '{s}', fetching it again: {}", .{ path, err });
        return null;
    };
}

/// Caller frees.
fn fetch(id: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = g_allocator, .io = files.g_io };
    defer client.deinit();
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, URL_FORMAT, .{ id, FETCH_SIZE });
    return http_client.fetch(g_allocator, &client, url, .{});
}

/// A portrait that can't be saved still shows; it's fetched again next run.
fn save(path: []const u8, body: []const u8) void {
    files.createDirIfMissing(files.PORTRAITS_DIR) catch |err| {
        slog.warn("Failed to create folder '{s}': {}", .{ files.PORTRAITS_DIR, err });
        return;
    };
    files.atomicWriteFile(g_allocator, files.g_io, path, body) catch return;
}
