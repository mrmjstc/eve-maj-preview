//! Following one log file as EVE appends to it.
const std = @import("std");
const lines_mod = @import("lines.zig");
const utf16 = @import("utf16.zig");
const log = @import("../log.zig");

const slog = log.scoped("chatlog");

const READ_CHUNK_SIZE = 4096;
/// So a big backlog can't hold up the other files.
const MAX_CHUNKS_PER_POLL = 64;
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
    path: []const u8,
    character_name: []const u8,
    /// UTF-16 LE if true, UTF-8 if not.
    is_chatlog: bool,
    /// Kept open between polls; Zig opens with full sharing, so EVE can still write and delete it.
    file: ?std.Io.File = null,
    position: u64 = 0,
    last_size: u64 = 0,
    last_modified: i64 = 0,
    disabled: bool = false,
    idle_checks: u32 = 0,
    cycle_counter: u32 = 0,
    poll_interval_multiplier: u8 = 1,
    lines: lines_mod.LineAssembler = .{},
    u16_buffer: std.ArrayList(u16) = .empty,
    utf8_buffer: std.ArrayList(u8) = .empty,
    system_name_buffer: std.ArrayList(u8) = .empty,
    // Parse state the monitor keeps per file.
    last_system_hash: u64 = 0,
    long_line_warnings: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, character_name: []const u8, is_chatlog: bool) !LogFile {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{ .path = owned_path, .character_name = try allocator.dupe(u8, character_name), .is_chatlog = is_chatlog };
    }

    pub fn deinit(self: *LogFile, allocator: std.mem.Allocator, io: std.Io) void {
        self.closeFile(io);
        allocator.free(self.path);
        allocator.free(self.character_name);
        self.lines.deinit(allocator);
        self.u16_buffer.deinit(allocator);
        self.utf8_buffer.deinit(allocator);
        self.system_name_buffer.deinit(allocator);
    }

    fn closeFile(self: *LogFile, io: std.Io) void {
        if (self.file) |file| file.close(io);
        self.file = null;
    }

    /// Returns the system the file last recorded; later reads start from its current end.
    pub fn start(self: *LogFile, allocator: std.mem.Allocator, io: std.Io) !?lines_mod.SystemMatch {
        const file = try std.Io.Dir.cwd().openFile(io, self.path, .{});
        self.file = file;
        const stat = try file.stat(io);
        self.last_size = stat.size;
        self.last_modified = @intCast(stat.mtime.nanoseconds);
        self.position = stat.size;

        const found = try self.findSystemBackward(allocator, io, file, stat.size);
        if (found == null and stat.size > MAX_BACKWARD_SCAN_BYTES) {
            slog.warn("No system for '{s}' in the last {} bytes of '{s}', so none is shown until the next jump or Local change", .{ self.character_name, MAX_BACKWARD_SCAN_BYTES, self.path });
        }
        return found;
    }

    /// Passes each complete line appended since the last poll to `handler`; see LineAssembler.feed.
    pub fn poll(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, backoff: Backoff, handler: anytype) !void {
        if (self.disabled) return;
        self.cycle_counter += 1;
        if (self.cycle_counter < self.poll_interval_multiplier) return;
        self.cycle_counter = 0;

        const file = self.file orelse self.open(io) orelse return;
        self.readAppended(allocator, io, file, backoff, handler) catch |err| {
            // Reopened on the next poll, in case the handle itself went bad.
            self.closeFile(io);
            return err;
        };
    }

    fn open(self: *LogFile, io: std.Io) ?std.Io.File {
        const file = std.Io.Dir.cwd().openFile(io, self.path, .{}) catch |err| {
            switch (err) {
                // Retried from the start, in case it's recreated.
                error.FileNotFound => {
                    self.position = 0;
                    self.last_size = 0;
                    self.lines.reset();
                },
                error.BadPathName => {
                    slog.warn("Failed to open '{s}' for '{s}', disabling it: {}", .{ self.path, self.character_name, err });
                    self.disabled = true;
                },
                else => slog.warn("Failed to open '{s}': {}", .{ self.path, err }),
            }
            return null;
        };
        self.file = file;
        return file;
    }

    fn readAppended(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, backoff: Backoff, handler: anytype) !void {
        const stat = try file.stat(io);
        const size = stat.size;
        const modified: i64 = @intCast(stat.mtime.nanoseconds);

        if (size == self.last_size and modified == self.last_modified) {
            self.idle_checks += 1;
            if (self.idle_checks >= backoff.idle_threshold and self.poll_interval_multiplier < backoff.max_multiplier) {
                const old_multiplier = self.poll_interval_multiplier;
                self.poll_interval_multiplier *= 2;
                self.idle_checks = 0;
                slog.debug("Poll backoff {s} ({s}): {}x -> {}x", .{ self.character_name, if (self.is_chatlog) "chatlog" else "gamelog", old_multiplier, self.poll_interval_multiplier });
            }
            return;
        }
        self.idle_checks = 0;
        self.poll_interval_multiplier = 1;

        // Shrunk: rewritten from the start.
        if (size < self.last_size) {
            self.position = 0;
            self.lines.reset();
        }

        var chunks: usize = 0;
        while (chunks < MAX_CHUNKS_PER_POLL) : (chunks += 1) {
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
            self.last_modified = modified;
        }
    }

    fn decode(self: *LogFile, allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
        return utf16.decode(allocator, &self.u16_buffer, &self.utf8_buffer, data);
    }

    /// Copies the system into system_name_buffer, since the chunk doesn't outlive the scan.
    fn findSystemBackward(self: *LogFile, allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, file_size: u64) !?lines_mod.SystemMatch {
        var buffer: [SCAN_CHUNK_SIZE]u8 = undefined;
        // Even for chatlogs, so each chunk starts on a UTF-16 character; an odd size means EVE is mid-write.
        var scan_pos: u64 = if (self.is_chatlog) file_size & ~@as(u64, 1) else file_size;
        // Overlapping chunks catch a line split across a chunk boundary.
        const overlap: u64 = if (self.is_chatlog) 128 else 256;
        const scan_floor: u64 = file_size -| MAX_BACKWARD_SCAN_BYTES;

        while (scan_pos > scan_floor) {
            const chunk_size = @min(SCAN_CHUNK_SIZE, scan_pos);
            const start_pos = scan_pos - chunk_size;
            const bytes_read = try file.readPositionalAll(io, buffer[0..chunk_size], start_pos);
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
                return .{ .system = self.system_name_buffer.items, .event_ts = match.event_ts };
            }

            scan_pos = if (start_pos > overlap) start_pos + overlap else 0;
        }
        return null;
    }
};
