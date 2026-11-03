//! Following one log file as EVE appends to it.
const std = @import("std");
const lines_mod = @import("lines.zig");
const utf16 = @import("utf16.zig");
const log = @import("../log.zig");

const slog = log.Scoped("chatlog");

const READ_CHUNK_SIZE = 4096;
/// So a big backlog can't hold up the other files.
const MAX_CHUNKS_PER_POLL = 256;
const SCAN_CHUNK_SIZE = 8192;
/// How far back the starting system is looked for.
const MAX_BACKWARD_SCAN_BYTES: u64 = 8 * 1024 * 1024;
const UTF8_BOM = "\xEF\xBB\xBF";

pub const Backoff = struct {
    /// Unchanged polls before the interval doubles.
    idle_threshold: u32,
    max_multiplier: u8,
};

pub const LogFile = struct {
    /// Owned; freed in deinit.
    path: []const u8,
    /// Owned; freed in deinit.
    character_name: []const u8,
    /// UTF-16 LE if true, UTF-8 if not.
    is_chatlog: bool,
    /// Owned; freed in deinit; empty for a gamelog.
    channel_name: []const u8,
    /// Kept open between polls; Zig opens with full sharing, so EVE can still write and delete it.
    file: ?std.Io.File = null,
    position: u64 = 0,
    /// Until set, a poll skips the backlog rather than reading it from 0.
    has_started: bool = false,
    last_size: u64 = 0,
    last_modified_ns: i64 = 0,
    is_disabled: bool = false,
    idle_check_count: u32 = 0,
    skipped_cycle_count: u32 = 0,
    poll_interval_multiplier: u8 = 1,
    /// Failed polls in a row; only the first is logged.
    failure_count: u32 = 0,
    lines: lines_mod.LineAssembler = .{},
    u16_buffer: std.ArrayList(u16) = .empty,
    utf8_buffer: std.ArrayList(u8) = .empty,
    system_name_buffer: std.ArrayList(u8) = .empty,
    last_system_hash: u64 = 0,
    long_line_warning_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, character_name: []const u8, channel_name: []const u8, is_chatlog: bool) !LogFile {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_character = try allocator.dupe(u8, character_name);
        errdefer allocator.free(owned_character);
        return .{ .path = owned_path, .character_name = owned_character, .channel_name = try allocator.dupe(u8, channel_name), .is_chatlog = is_chatlog };
    }

    pub fn deinit(self: *LogFile, allocator: std.mem.Allocator, io: std.Io) void {
        self.closeFile(io);
        allocator.free(self.path);
        allocator.free(self.character_name);
        allocator.free(self.channel_name);
        self.lines.deinit(allocator);
        self.u16_buffer.deinit(allocator);
        self.utf8_buffer.deinit(allocator);
        self.system_name_buffer.deinit(allocator);
    }

    fn closeFile(self: *LogFile, io: std.Io) void {
        if (self.file) |file| file.close(io);
        self.file = null;
    }

    /// A log followed only for its chat, so it says nothing about a character's system.
    pub fn isChannelLog(self: *const LogFile) bool {
        return self.is_chatlog and !std.mem.eql(u8, self.channel_name, lines_mod.LOCAL_CHANNEL);
    }

    /// Returns the system the file last recorded, unless it's a channel log; later reads start from its current end.
    pub fn start(self: *LogFile, allocator: std.mem.Allocator, io: std.Io) !?lines_mod.SystemMatch {
        const file = try std.Io.Dir.cwd().openFile(io, self.path, .{});
        self.file = file;
        const stat = try file.stat(io);
        self.last_size = stat.size;
        self.last_modified_ns = @intCast(stat.mtime.nanoseconds);
        self.position = self.characterBoundary(stat.size);
        self.has_started = true;
        if (self.isChannelLog()) return null;

        const found = try self.findSystemBackward(allocator, io, file, stat.size);
        if (found == null and stat.size > MAX_BACKWARD_SCAN_BYTES) {
            slog.warn("No system for '{s}' in the last {} bytes of '{s}', so none is shown until the next jump or Local change", .{ self.character_name, MAX_BACKWARD_SCAN_BYTES, self.path });
        }
        return found;
    }

    /// Passes each complete line appended since the last poll to `handler`, logging its own failures; see LineAssembler.feed.
    pub fn poll(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, backoff: Backoff, handler: anytype) void {
        if (self.is_disabled) return;
        self.skipped_cycle_count += 1;
        if (self.skipped_cycle_count < @min(self.poll_interval_multiplier, backoff.max_multiplier)) return;
        self.skipped_cycle_count = 0;

        self.pollOnce(allocator, io, backoff, handler) catch |err| {
            // Reopened on the next poll, in case the handle itself went bad.
            self.closeFile(io);
            self.poll_interval_multiplier = @min(self.poll_interval_multiplier *| 2, backoff.max_multiplier);
            self.failure_count +|= 1;
            if (self.failure_count == 1) slog.err("Failed to read '{s}' for '{s}', retrying less often: {}", .{ self.path, self.character_name, err });
            return;
        };
        if (self.failure_count > 0 and self.file != null) {
            slog.info("Reading '{s}' again after {} failed attempt(s)", .{ self.path, self.failure_count });
            self.failure_count = 0;
        }
    }

    /// `handler` has `onLine([]const u8)` and `onLongLine(usize)`.
    fn pollOnce(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, backoff: Backoff, handler: anytype) !void {
        const file = self.file orelse try self.open(io) orelse return;
        if (!self.has_started) return self.skipToEnd(io, file);
        try self.readAppended(allocator, io, file, backoff, handler);
    }

    fn skipToEnd(self: *LogFile, io: std.Io, file: std.Io.File) !void {
        const stat = try file.stat(io);
        self.last_size = stat.size;
        self.last_modified_ns = @intCast(stat.mtime.nanoseconds);
        self.position = self.characterBoundary(stat.size);
        self.has_started = true;
        slog.info("Following '{s}' from its end, after its start failed", .{self.path});
    }

    /// Null when there's nothing to read yet, or ever.
    fn open(self: *LogFile, io: std.Io) !?std.Io.File {
        const file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| switch (err) {
            // Retried from the start, in case it's recreated.
            error.FileNotFound => {
                self.position = 0;
                self.last_size = 0;
                self.lines.reset();
                return null;
            },
            error.BadPathName => {
                slog.warn("Failed to open '{s}' for '{s}', disabling it: {}", .{ self.path, self.character_name, err });
                self.is_disabled = true;
                return null;
            },
            else => return err,
        };
        self.file = file;
        return file;
    }

    /// `handler` has `onLine([]const u8)` and `onLongLine(usize)`.
    fn readAppended(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, backoff: Backoff, handler: anytype) !void {
        const stat = try file.stat(io);
        const size = stat.size;
        const modified_ns: i64 = @intCast(stat.mtime.nanoseconds);

        if (size == self.last_size and modified_ns == self.last_modified_ns) {
            self.idle_check_count += 1;
            if (self.idle_check_count >= backoff.idle_threshold and self.poll_interval_multiplier < backoff.max_multiplier) {
                const old_multiplier = self.poll_interval_multiplier;
                self.poll_interval_multiplier = @min(self.poll_interval_multiplier * 2, backoff.max_multiplier);
                self.idle_check_count = 0;
                slog.debug("Poll backoff {s} ({s}): {}x -> {}x", .{ self.character_name, if (self.is_chatlog) "chatlog" else "gamelog", old_multiplier, self.poll_interval_multiplier });
            }
            return;
        }
        self.idle_check_count = 0;
        self.poll_interval_multiplier = 1;

        // EVE only appends, so a size below what's been read means something else (e.g. a sync client) rewrote it; replaying would refire old events.
        if (size < self.position) {
            self.position = self.characterBoundary(size);
            self.last_size = size;
            self.last_modified_ns = modified_ns;
            self.lines.reset();
            slog.info("'{s}' shrank, following it from its new end", .{self.path});
            return;
        }

        var chunk_count: usize = 0;
        while (chunk_count < MAX_CHUNKS_PER_POLL) : (chunk_count += 1) {
            var buffer: [READ_CHUNK_SIZE]u8 = undefined;
            const bytes_read = try file.readPositionalAll(io, &buffer, self.position);
            // A chatlog read can stop mid-character while EVE is writing; the rest is read next time.
            const usable = if (self.is_chatlog) utf16.completeLen(buffer[0..bytes_read]) else bytes_read;
            if (usable == 0) break;

            var data = buffer[0..usable];
            if (!self.is_chatlog and self.position == 0 and std.mem.startsWith(u8, data, UTF8_BOM)) data = data[UTF8_BOM.len..];
            self.position += usable;

            if (self.is_chatlog) {
                if (try self.decode(allocator, data)) |text| try self.lines.feed(allocator, text, handler);
            } else {
                try self.lines.feed(allocator, data, handler);
            }
            if (bytes_read < buffer.len) break;
        }

        // Only once caught up, so unread data makes the next poll read again.
        if (self.position >= size) {
            self.last_size = size;
            self.last_modified_ns = modified_ns;
        }
    }

    /// An odd size means EVE is mid-write, and starting there would misread everything after it as UTF-16.
    fn characterBoundary(self: *const LogFile, offset: u64) u64 {
        return if (self.is_chatlog) offset & ~@as(u64, 1) else offset;
    }

    fn decode(self: *LogFile, allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
        return utf16.decode(allocator, &self.u16_buffer, &self.utf8_buffer, data);
    }

    /// Copies the system into system_name_buffer, since the chunk doesn't outlive the scan.
    fn findSystemBackward(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, file_size: u64) !?lines_mod.SystemMatch {
        var buffer: [SCAN_CHUNK_SIZE]u8 = undefined;
        // Even for chatlogs, so each chunk starts on a UTF-16 character; an odd size means EVE is mid-write.
        var scan_offset: u64 = if (self.is_chatlog) file_size & ~@as(u64, 1) else file_size;
        // Longer than any line the scans look for, so a line split across a chunk boundary is whole in the earlier chunk.
        const overlap: u64 = 512;
        const scan_floor: u64 = file_size -| MAX_BACKWARD_SCAN_BYTES;

        while (scan_offset > scan_floor) {
            const chunk_size = @min(SCAN_CHUNK_SIZE, scan_offset);
            const start_offset = scan_offset - chunk_size;
            const bytes_read = try file.readPositionalAll(io, buffer[0..chunk_size], start_offset);
            if (bytes_read == 0) break;
            const chunk = buffer[0..bytes_read];

            const found = if (self.is_chatlog) blk: {
                // Checked in the raw bytes, so most chunks are never decoded.
                if (!utf16.containsAscii(chunk, "Channel")) break :blk null;
                const text = try self.decode(allocator, chunk) orelse break :blk null;
                break :blk lines_mod.lastSystemInChat(text);
            } else lines_mod.lastSystemInGame(chunk);

            if (found) |match| {
                self.system_name_buffer.clearRetainingCapacity();
                try self.system_name_buffer.appendSlice(allocator, match.system);
                return .{ .system = self.system_name_buffer.items, .event_timestamp = match.event_timestamp };
            }

            scan_offset = if (start_offset > 0) start_offset + overlap else 0;
        }
        return null;
    }
};
