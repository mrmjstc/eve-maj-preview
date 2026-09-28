//! Each character's EVE character ID, learned from its log files' names, kept in character_ids.json so a later lookup skips reading log headers.
//! Used by the chatlog monitor, whose worker thread adds to it, and by the config window's portraits, so it locks its map; only it writes its file.
const std = @import("std");
const files = @import("../config/files.zig");
const log = @import("../log.zig");

const slog = log.scoped("chatlog");

const FILE = "character_ids.json";

pub const CharacterIds = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
    mutex: std.Io.Mutex = .init,

    /// Starts empty if the file is missing or unreadable; the monitor learns the IDs again as it needs them.
    pub fn load(allocator: std.mem.Allocator) CharacterIds {
        var ids: CharacterIds = .{ .allocator = allocator };
        const content = std.Io.Dir.cwd().readFileAlloc(files.g_io, FILE, allocator, .limited(files.MAX_CONFIG_FILE_SIZE)) catch |err| {
            if (err != error.FileNotFound) slog.warn("Failed to read '{s}': {}", .{ FILE, err });
            return ids;
        };
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
            slog.warn("Failed to parse '{s}': {}", .{ FILE, err });
            return ids;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            slog.warn("'{s}' isn't a JSON object, ignoring it", .{FILE});
            return ids;
        }
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            ids.putOwned(entry.key_ptr.*, entry.value_ptr.string) catch |err| {
                slog.warn("Failed to load character ID for {s}: {}", .{ entry.key_ptr.*, err });
                return ids;
            };
        }
        return ids;
    }

    /// Doesn't log, since it runs in shutdown defers.
    pub fn deinit(self: *CharacterIds) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn putOwned(self: *CharacterIds, name: []const u8, id: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        if (try self.map.fetchPut(self.allocator, name_copy, id_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }

    pub fn contains(self: *CharacterIds, name: []const u8) !bool {
        try self.mutex.lock(files.g_io);
        defer self.mutex.unlock(files.g_io);
        return self.map.contains(name);
    }

    /// Caller owns the result.
    pub fn get(self: *CharacterIds, allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
        try self.mutex.lock(files.g_io);
        defer self.mutex.unlock(files.g_io);
        const id = self.map.get(name) orelse return null;
        return try allocator.dupe(u8, id);
    }

    /// Saves the file when `id` is new for `name`.
    pub fn put(self: *CharacterIds, name: []const u8, id: []const u8) !void {
        const json = blk: {
            try self.mutex.lock(files.g_io);
            defer self.mutex.unlock(files.g_io);
            if (self.map.get(name)) |existing| {
                if (std.mem.eql(u8, existing, id)) return;
            }
            try self.putOwned(name, id);
            break :blk try self.toJson(self.allocator);
        };
        defer self.allocator.free(json);
        slog.info("Cached character ID: {s} -> {s}", .{ name, id });
        try files.atomicWriteFile(self.allocator, files.g_io, FILE, json);
    }

    /// `{name: id}`.
    pub fn write(self: *CharacterIds, jw: *std.json.Stringify) !void {
        try self.mutex.lock(files.g_io);
        defer self.mutex.unlock(files.g_io);
        try writeMap(&self.map, jw);
    }

    fn toJson(self: *const CharacterIds, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        try writeMap(&self.map, &jw);
        return out.toOwnedSlice();
    }
};

fn writeMap(map: *const std.StringHashMapUnmanaged([]const u8), jw: *std.json.Stringify) !void {
    try jw.beginObject();
    var it = map.iterator();
    while (it.next()) |entry| {
        try jw.objectField(entry.key_ptr.*);
        try jw.write(entry.value_ptr.*);
    }
    try jw.endObject();
}
