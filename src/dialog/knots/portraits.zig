//! Character portraits from EVE's image server, kept on disk for good and in memory for the app's run; main thread only, bar the load threads.
const std = @import("std");
const ui = @import("ui");
const win32 = @import("../../platform/win32.zig");
const wic = @import("../../platform/wic.zig");
const files = @import("../../config/files.zig");
const dialog_host = @import("../dialog_host.zig");
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
    /// The Portraits' allocator, which the Loaded and what it owns came from.
    allocator: std.mem.Allocator,
    /// Owned; freed in deinit.
    id: []const u8,
    /// Null when it couldn't be read, fetched or decoded; owned, freed in deinit unless taken.
    image: ?wic.Decoded,
    /// The next result, linked by handoff.Stack.
    next: ?*Loaded = null,

    pub fn deinit(self: *Loaded) void {
        if (self.image) |decoded| decoded.deinit(self.allocator);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }
};

const Entry = struct {
    image: ?wic.Decoded = null,
    is_loading: bool = true,
    /// Tells portraits' textures apart, since knots caches a texture by its key.
    serial: usize,
};

pub const Portraits = struct {
    /// Borrowed from App; its allocator is read by the load threads too.
    context: dialog_host.Context,
    timer_hwnd: ?win32.HWND = null,
    command: usize = 0,
    /// Keyed by character ID. Keys and images owned; freed in deinit.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    next_serial: usize = 0,
    /// Pushed by load threads, taken by the main thread.
    results: handoff.Stack(Loaded) = .{},
    /// IDs waiting for one of the MAX_LOADS, oldest first; each owned, freed in deinit.
    waiting: std.ArrayList([]const u8) = .empty,
    /// Raised by the main thread as it starts a load, lowered by the load's thread before it hands back its result.
    load_count: std.atomic.Value(u32) = .init(0),

    pub fn init(app_context: dialog_host.Context) Portraits {
        return .{ .context = app_context };
    }

    /// Main thread: the portraits loaded since the last call, oldest first through `next`; pass each to `store`.
    pub fn takeAll(self: *Portraits) ?*Loaded {
        return self.results.takeAll();
    }

    /// Each time the window opens: `timer_hwnd` receives `command` as each portrait loads, and portraits that failed are tried again.
    pub fn begin(self: *Portraits, timer_hwnd: ?win32.HWND, command: usize) void {
        self.timer_hwnd = timer_hwnd;
        self.command = command;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.image != null or entry.value_ptr.is_loading) continue;
            const key = entry.key_ptr.*;
            self.entries.removeByPtr(entry.key_ptr);
            self.context.allocator.free(key);
            it = self.entries.iterator();
        }
    }

    /// At app exit; a load still running leaves a result nothing takes, which goes with the process.
    pub fn deinit(self: *Portraits) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.image) |decoded| decoded.deinit(self.context.allocator);
            self.context.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.context.allocator);
        self.entries = .empty;
        for (self.waiting.items) |id| self.context.allocator.free(id);
        self.waiting.deinit(self.context.allocator);
        self.waiting = .empty;
    }

    /// Starts loading `name`'s portrait, if its ID is known, so it's ready before the roster is shown.
    pub fn preload(self: *Portraits, name: []const u8) void {
        const id = self.lookUp(self.context.allocator, name) orelse return;
        defer self.context.allocator.free(id);
        if (!self.entries.contains(id)) self.request(id);
    }

    /// Null until loaded or while its ID is unknown; the first call starts loading it.
    pub fn image(self: *Portraits, arena: std.mem.Allocator, key: ui.Key, name: []const u8, image_style: *const ui.Style) ?Image {
        const id = self.lookUp(arena, name) orelse return null;
        const entry = self.entries.getPtr(id) orelse {
            self.request(id);
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
    pub fn store(self: *Portraits, loaded: *Loaded) void {
        defer self.startWaiting();
        defer loaded.deinit();
        const entry = self.entries.getPtr(loaded.id) orelse return;
        entry.is_loading = false;
        if (entry.image != null) return;
        entry.image = loaded.image;
        loaded.image = null;
    }

    /// Caller owns the result; null when the ID isn't known yet.
    fn lookUp(self: *const Portraits, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
        return self.context.character_ids.get(allocator, name) catch |err| {
            slog.warn("Failed to look up the character ID of '{s}': {}", .{ name, err });
            return null;
        };
    }

    /// A failure leaves the entry empty until the window reopens, rather than retrying every frame.
    fn request(self: *Portraits, id: []const u8) void {
        const entry = self.addEntry(id) catch |err| {
            slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
            return;
        };
        self.queueLoad(id) catch |err| {
            slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
            entry.is_loading = false;
            return;
        };
        self.startWaiting();
    }

    fn queueLoad(self: *Portraits, id: []const u8) !void {
        const owned_id = try self.context.allocator.dupe(u8, id);
        errdefer self.context.allocator.free(owned_id);
        try self.waiting.append(self.context.allocator, owned_id);
    }

    /// One that can't start leaves its entry empty until the window reopens, as request does.
    fn startWaiting(self: *Portraits) void {
        while (self.waiting.items.len > 0 and self.load_count.load(.acquire) < MAX_LOADS) {
            const id = self.waiting.orderedRemove(0);
            self.startLoad(id) catch |err| {
                slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
                if (self.entries.getPtr(id)) |entry| entry.is_loading = false;
                self.context.allocator.free(id);
            };
        }
    }

    fn addEntry(self: *Portraits, id: []const u8) !*Entry {
        const owned_id = try self.context.allocator.dupe(u8, id);
        errdefer self.context.allocator.free(owned_id);
        const slot = try self.entries.getOrPut(self.context.allocator, owned_id);
        slot.value_ptr.* = .{ .serial = self.next_serial };
        self.next_serial += 1;
        return slot.value_ptr;
    }

    /// Takes ownership of `id` once the load has started; only the main thread raises the count, so its check can't be raced.
    fn startLoad(self: *Portraits, id: []const u8) !void {
        const timer_hwnd = self.timer_hwnd orelse return error.MissingTimerWindow;
        _ = self.load_count.fetchAdd(1, .monotonic);
        errdefer _ = self.load_count.fetchSub(1, .monotonic);
        try detached.spawn(loadThread, .{ self, self.context.io, timer_hwnd, self.command, id });
    }

    /// Takes ownership of `id`; shares only the allocator, the load count, the results and the posted message with the main thread.
    fn loadThread(self: *Portraits, io: std.Io, timer_hwnd: win32.HWND, command: usize, id: []const u8) void {
        const loaded = self.context.allocator.create(Loaded) catch |err| {
            _ = self.load_count.fetchSub(1, .release);
            slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
            self.context.allocator.free(id);
            return;
        };
        loaded.* = .{ .allocator = self.context.allocator, .id = id, .image = self.load(io, id) catch |err| blk: {
            slog.warn("Failed to load the portrait of character '{s}': {}", .{ id, err });
            break :blk null;
        } };
        // Before the result goes, so the main thread taking it finds the slot free for the next.
        _ = self.load_count.fetchSub(1, .release);
        self.results.push(loaded);
        // `id` belongs to the stack now, and the main thread may already have freed it.
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, command, 0))) {
            slog.warn("Failed to pass on a character portrait, it waits for the next one: error {d}", .{win32.GetLastError()});
        }
    }

    /// From the disk cache, or else fetched once and saved there; a cached file is never fetched again.
    fn load(self: *const Portraits, io: std.Io, id: []const u8) !wic.Decoded {
        var path_buf: [128]u8 = undefined;
        const path = try std.mem.print(&path_buf, PATH_FORMAT, .{id});
        if (self.readCached(io, path)) |cached| {
            defer self.context.allocator.free(cached);
            if (self.decode(cached)) |decoded| return decoded else |err| {
                slog.warn("Failed to decode the cached portrait '{s}', fetching it again: {}", .{ path, err });
            }
        }

        const body = try self.fetch(id);
        defer self.context.allocator.free(body);
        const decoded = try self.decode(body);
        self.save(io, path, body);
        return decoded;
    }

    fn decode(self: *const Portraits, encoded: []const u8) !wic.Decoded {
        const decoded = try wic.decodeRgba(self.context.allocator, encoded);
        rgba.roundCorners(decoded.pixels, decoded.width, decoded.height, CORNER_RADIUS);
        return decoded;
    }

    /// Null when it isn't cached yet, or can't be read.
    fn readCached(self: *const Portraits, io: std.Io, path: []const u8) ?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.context.allocator, .limited(MAX_FILE_BYTES)) catch |err| {
            if (err != error.FileNotFound) slog.warn("Failed to read the cached portrait '{s}', fetching it again: {}", .{ path, err });
            return null;
        };
    }

    /// Caller frees.
    fn fetch(self: *const Portraits, id: []const u8) ![]u8 {
        var http_session: http_client.Session = try .init();
        defer http_session.deinit();
        var url_buf: [128]u8 = undefined;
        const url = try std.mem.print(&url_buf, URL_FORMAT, .{ id, FETCH_SIZE });
        return http_session.fetch(self.context.allocator, url, .{});
    }

    /// A portrait that can't be saved still shows; it's fetched again next run.
    fn save(self: *const Portraits, io: std.Io, path: []const u8, body: []const u8) void {
        files.createDirIfMissing(io, files.PORTRAITS_DIR) catch |err| {
            slog.warn("Failed to create folder '{s}': {}", .{ files.PORTRAITS_DIR, err });
            return;
        };
        atomic_file.write(self.context.allocator, io, path, body) catch return;
    }
};
