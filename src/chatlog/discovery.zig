//! Finding a character's newest logs among possibly tens of thousands, and noticing new ones.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const lines = @import("lines.zig");
const utf16 = @import("utf16.zig");
const CharacterIds = @import("character_ids.zig").CharacterIds;
const log = @import("../log.zig");

const slog = log.scoped("chatlog");

/// Files checked by header when a character's ID isn't cached; a live character's log is always among the newest.
const MAX_HEADER_CHECKS = 64;
/// Enough for a decoded MAX_PATH file name.
const NAME_BUF = win32.MAX_PATH * 3;

/// Folders where files were created since they were last rescanned.
pub const Changes = struct {
    chatlog: bool = false,
    gamelog: bool = false,

    pub fn any(self: Changes) bool {
        return self.chatlog or self.gamelog;
    }
};

pub const LogFinder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    chatlog_dir: []const u8,
    gamelog_dir: []const u8,
    /// Borrowed; outlives the finder.
    character_ids: ?*CharacterIds,
    chatlog_watcher: ?win32.HANDLE,
    gamelog_watcher: ?win32.HANDLE,
    /// A watch started late; rearm skips it once, so a log made during its catch-up rescan stays signalled.
    chatlog_watch_is_new: bool = false,
    gamelog_watch_is_new: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, chatlog_dir: []const u8, gamelog_dir: []const u8, character_ids: ?*CharacterIds) !LogFinder {
        if (!std.unicode.utf8ValidateSlice(chatlog_dir) or !std.unicode.utf8ValidateSlice(gamelog_dir)) {
            slog.err("Failed to watch log folders: a path contains invalid UTF-8", .{});
            return error.InvalidUtf8;
        }
        const owned_chatlog_dir = try allocator.dupe(u8, chatlog_dir);
        errdefer allocator.free(owned_chatlog_dir);
        const owned_gamelog_dir = try allocator.dupe(u8, gamelog_dir);
        const finder: LogFinder = .{
            .allocator = allocator,
            .io = io,
            .chatlog_dir = owned_chatlog_dir,
            .gamelog_dir = owned_gamelog_dir,
            .character_ids = character_ids,
            .chatlog_watcher = watchFolder(allocator, chatlog_dir),
            .gamelog_watcher = watchFolder(allocator, gamelog_dir),
        };
        if (finder.chatlog_watcher == null) slog.warn("Failed to watch '{s}', retrying until it exists", .{chatlog_dir});
        if (finder.gamelog_watcher == null) slog.warn("Failed to watch '{s}', retrying until it exists", .{gamelog_dir});
        return finder;
    }

    pub fn deinit(self: *LogFinder) void {
        if (self.chatlog_watcher) |watcher| _ = win32.FindCloseChangeNotification(watcher);
        if (self.gamelog_watcher) |watcher| _ = win32.FindCloseChangeNotification(watcher);
        self.allocator.free(self.chatlog_dir);
        self.allocator.free(self.gamelog_dir);
    }

    /// Without waiting; a folder whose watch only just started counts as changed, for logs made while it wasn't watched.
    pub fn changes(self: *LogFinder) Changes {
        return .{
            .chatlog = self.folderChanged(&self.chatlog_watcher, &self.chatlog_watch_is_new, self.chatlog_dir),
            .gamelog = self.folderChanged(&self.gamelog_watcher, &self.gamelog_watch_is_new, self.gamelog_dir),
        };
    }

    fn folderChanged(self: *LogFinder, watcher: *?win32.HANDLE, is_new: *bool, dir: []const u8) bool {
        const handle = watcher.* orelse {
            watcher.* = watchFolder(self.allocator, dir) orelse return false;
            is_new.* = true;
            slog.info("Watching '{s}' for new logs", .{dir});
            return true;
        };
        return win32.WaitForSingleObject(handle, 0) == win32.WAIT_OBJECT_0;
    }

    /// Resumes watching the folders in `done`, once their changes have been rescanned.
    pub fn rearm(self: *LogFinder, done: Changes) void {
        if (done.chatlog) rewatch(&self.chatlog_watcher, &self.chatlog_watch_is_new, self.chatlog_dir);
        if (done.gamelog) rewatch(&self.gamelog_watcher, &self.gamelog_watch_is_new, self.gamelog_dir);
    }

    /// Owned by the caller.
    pub fn find(self: *LogFinder, character_name: []const u8, is_chatlog: bool) ?[]u8 {
        const dir = if (is_chatlog) self.chatlog_dir else self.gamelog_dir;
        if (self.cachedId(character_name)) |id| {
            defer self.allocator.free(id);
            if (self.findById(dir, is_chatlog, id)) |path| return path;
            // Stale: the cached ID matched nothing.
        }
        return self.findByHeader(dir, is_chatlog, character_name);
    }

    fn cachedId(self: *LogFinder, character_name: []const u8) ?[]const u8 {
        const ids = self.character_ids orelse return null;
        return ids.get(self.allocator, character_name) catch |err| {
            slog.warn("Failed to look up cached character ID for '{s}': {}", .{ character_name, err });
            return null;
        };
    }

    /// Lets Windows filter the folder down to this ID's files, then keeps the newest.
    fn findById(self: *LogFinder, dir: []const u8, is_chatlog: bool, id: []const u8) ?[]u8 {
        var pattern_buf: [64]u8 = undefined;
        const pattern = std.mem.print(&pattern_buf, "{s}*_{s}.txt", .{ if (is_chatlog) "Local_" else "", id }) catch |err| {
            slog.warn("Failed to build log search for character ID '{s}': {}", .{ id, err });
            return null;
        };

        var best_ts: u64 = 0;
        var best_buf: [NAME_BUF]u8 = undefined;
        var best: []const u8 = "";

        var files = FileNames.open(self.allocator, dir, pattern) orelse return null;
        defer files.close();
        while (files.next()) |name| {
            if (!is_chatlog and std.mem.startsWith(u8, name, "Local_")) continue;
            const file_id = lines.characterIdFromFileName(name) orelse continue;
            if (!std.mem.eql(u8, file_id, id)) continue;
            const ts = lines.logFileTimestamp(name, is_chatlog);
            if (ts <= best_ts) continue;
            best_ts = ts;
            @memcpy(best_buf[0..name.len], name);
            best = best_buf[0..name.len];
        }

        if (best.len == 0) return null;
        return self.joinPath(dir, best);
    }

    const Candidate = struct { ts: u64, name: []u8 };

    /// Only the newest MAX_HEADER_CHECKS files are kept while listing, so a huge folder is never sorted or opened wholesale.
    fn findByHeader(self: *LogFinder, dir: []const u8, is_chatlog: bool, character_name: []const u8) ?[]u8 {
        var newest: [MAX_HEADER_CHECKS]Candidate = undefined;
        var count: usize = 0;
        defer for (newest[0..count]) |candidate| self.allocator.free(candidate.name);

        var files = FileNames.open(self.allocator, dir, if (is_chatlog) "Local_*.txt" else "*.txt") orelse return null;
        defer files.close();
        while (files.next()) |name| {
            if (!is_chatlog and std.mem.startsWith(u8, name, "Local_")) continue;
            // A client launch writes an ID-less gamelog with no listener, so it can never match.
            if (!is_chatlog and lines.characterIdFromFileName(name) == null) continue;
            const ts = lines.logFileTimestamp(name, is_chatlog);
            if (ts == 0) continue;
            if (count == newest.len and ts <= newest[count - 1].ts) continue;

            const owned = self.allocator.dupe(u8, name) catch |err| {
                slog.warn("Failed to copy log candidate name '{s}': {}", .{ name, err });
                continue;
            };
            if (count == newest.len) {
                count -= 1;
                self.allocator.free(newest[count].name);
            }
            // Newest first.
            var i = count;
            while (i > 0 and newest[i - 1].ts < ts) : (i -= 1) newest[i] = newest[i - 1];
            newest[i] = .{ .ts = ts, .name = owned };
            count += 1;
        }

        for (newest[0..count]) |candidate| {
            const path = self.joinPath(dir, candidate.name) orelse continue;
            if (self.isListener(path, is_chatlog, character_name)) {
                if (lines.characterIdFromFileName(candidate.name)) |id| self.cacheId(character_name, id);
                return path;
            }
            self.allocator.free(path);
        }
        return null;
    }

    fn cacheId(self: *LogFinder, character_name: []const u8, id: []const u8) void {
        const ids = self.character_ids orelse return;
        ids.put(character_name, id) catch |err| {
            slog.warn("Failed to cache character ID for '{s}': {}", .{ character_name, err });
        };
    }

    fn isListener(self: *LogFinder, path: []const u8, is_chatlog: bool, character_name: []const u8) bool {
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| {
            slog.warn("Failed to open '{s}' to read its listener: {}", .{ path, err });
            return false;
        };
        defer file.close(self.io);

        var header: [512]u8 = undefined;
        const bytes_read = file.readPositionalAll(self.io, &header, 0) catch |err| {
            slog.warn("Failed to read the header of '{s}': {}", .{ path, err });
            return false;
        };

        var units: [header.len / 2]u16 = undefined;
        var decoded: [units.len * 3]u8 = undefined;
        const text = if (is_chatlog) (utf16.decodeInto(&units, &decoded, header[0..bytes_read]) orelse return false) else header[0..bytes_read];
        const listener = lines.listenerName(text) orelse return false;
        return std.mem.eql(u8, listener, character_name);
    }

    fn joinPath(self: *LogFinder, dir: []const u8, name: []const u8) ?[]u8 {
        return std.Io.Dir.path.join(self.allocator, &.{ dir, name }) catch |err| {
            slog.warn("Failed to build path for log file '{s}': {}", .{ name, err });
            return null;
        };
    }
};

/// The files in a folder matching a wildcard pattern, filtered by Windows.
const FileNames = struct {
    handle: win32.HANDLE,
    find_data: win32.WIN32_FIND_DATAW,
    pending: bool,
    name_buf: [NAME_BUF]u8 = undefined,

    fn open(allocator: std.mem.Allocator, dir: []const u8, pattern: []const u8) ?FileNames {
        const search = std.Io.Dir.path.join(allocator, &.{ dir, pattern }) catch |err| {
            slog.warn("Failed to build log search path for '{s}': {}", .{ dir, err });
            return null;
        };
        defer allocator.free(search);
        const search_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, search) catch |err| {
            slog.warn("Failed to convert log search path for '{s}' to UTF-16: {}", .{ dir, err });
            return null;
        };
        defer allocator.free(search_w);

        var files: FileNames = .{ .handle = undefined, .find_data = undefined, .pending = true };
        files.handle = win32.FindFirstFileW(search_w.ptr, &files.find_data);
        // No match at all is also INVALID_HANDLE_VALUE.
        if (files.handle == win32.INVALID_HANDLE_VALUE) return null;
        return files;
    }

    fn close(self: *FileNames) void {
        _ = win32.FindClose(self.handle);
    }

    /// Valid until the next call.
    fn next(self: *FileNames) ?[]const u8 {
        while (true) {
            if (!self.pending) {
                if (win32.FindNextFileW(self.handle, &self.find_data) == win32.FALSE) return null;
            }
            self.pending = false;
            if (self.find_data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
            const raw: []const u16 = self.find_data.cFileName[0..];
            const len = std.mem.findScalar(u16, raw, 0) orelse raw.len;
            const written = std.unicode.utf16LeToUtf8(&self.name_buf, raw[0..len]) catch |err| {
                slog.warn("Failed to decode log file name: {}", .{err});
                continue;
            };
            return self.name_buf[0..written];
        }
    }
};

/// Null if the folder can't be watched (yet); the caller logs, since it's retried every worker loop.
fn watchFolder(allocator: std.mem.Allocator, dir: []const u8) ?win32.HANDLE {
    const dir_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, dir) catch return null;
    defer allocator.free(dir_w);
    // Only files being created or renamed, not written to.
    const handle = win32.FindFirstChangeNotificationW(dir_w.ptr, win32.FALSE, win32.FILE_NOTIFY_CHANGE_FILE_NAME);
    if (handle == win32.INVALID_HANDLE_VALUE) return null;
    return handle;
}

/// Drops a watch that can't be rearmed, e.g. its folder was deleted, so folderChanged starts a new one once the folder exists again.
fn rewatch(watcher: *?win32.HANDLE, is_new: *bool, dir: []const u8) void {
    if (is_new.*) {
        is_new.* = false;
        return;
    }
    const handle = watcher.* orelse return;
    if (win32.toBool(win32.FindNextChangeNotification(handle))) return;
    _ = win32.FindCloseChangeNotification(handle);
    watcher.* = null;
    slog.warn("Failed to keep watching '{s}', retrying until it exists", .{dir});
}
