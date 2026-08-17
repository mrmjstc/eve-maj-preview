const std = @import("std");
const win32 = @import("win32.zig");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

var current_level: LogLevel = .err;

pub const LOG_FILE_NAME = "eve-maj.log";
const LOG_FILE_NAME_OLD = "eve-maj.log.old";
// Rotated to .old at this size rather than trimmed, so a write never costs more than a size check plus (rarely) a rename.
const MAX_LOG_FILE_BYTES: u64 = 5 * 1024 * 1024;

var log_file: ?std.fs.File = null;
var log_file_size: u64 = 0;
var log_mutex: std.Thread.Mutex = .{};

// Buffers debug/info lines so the frequent debug-level scan tick costs a memcpy, not a write() syscall.
var log_buf: [16 * 1024]u8 = undefined;
var log_buf_len: usize = 0;

pub fn setLevel(level: LogLevel) void {
    current_level = level;
}

/// Lazily opens the log file so a session that never logs never touches disk.
/// Must be called with log_mutex held.
fn ensureFileOpen() bool {
    if (log_file != null) return true;

    const file = std.fs.cwd().createFile(LOG_FILE_NAME, .{ .truncate = false }) catch return false;
    const end_pos = file.getEndPos() catch 0;
    file.seekTo(end_pos) catch {};
    log_file = file;
    log_file_size = end_pos;
    return true;
}

/// Used by the console control handler, since closing that window kills the process before any `defer` can run.
pub fn flush() void {
    log_mutex.lock();
    defer log_mutex.unlock();
    flushLocked();
}

pub fn deinitFile() void {
    log_mutex.lock();
    defer log_mutex.unlock();
    flushLocked();
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
}

fn shouldLog(level: LogLevel) bool {
    return @intFromEnum(level) >= @intFromEnum(current_level);
}

fn formatTimestamp(buf: *[23]u8) []const u8 {
    var st: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&st);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
    }) catch "????-??-?? ??:??:??.???";
}

/// Rotates to .old (discarding any previous .old) and starts fresh. Must be called with log_mutex held.
fn rotate() void {
    if (log_file) |f| f.close();
    log_file = null;

    std.fs.cwd().deleteFile(LOG_FILE_NAME_OLD) catch {};
    std.fs.cwd().rename(LOG_FILE_NAME, LOG_FILE_NAME_OLD) catch {};

    log_file = std.fs.cwd().createFile(LOG_FILE_NAME, .{}) catch null;
    log_file_size = 0;
}

/// Writes any buffered lines to disk. Must be called with log_mutex held.
fn flushLocked() void {
    if (log_buf_len == 0) return;
    defer log_buf_len = 0;

    if (log_file_size >= MAX_LOG_FILE_BYTES) rotate();
    const file = log_file orelse return;

    file.writeAll(log_buf[0..log_buf_len]) catch return;
    log_file_size += log_buf_len;
}

/// Retries tryLock briefly to avoid missing the crash line, but bails instead of deadlocking if this thread already holds the lock (e.g. panicked inside the logger).
pub fn writeCrashLine(comptime fmt: []const u8, args: anytype) void {
    const lock_retries = 20;
    var attempt: u32 = 0;
    while (!log_mutex.tryLock()) {
        attempt += 1;
        if (attempt >= lock_retries) return;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    defer log_mutex.unlock();

    flushLocked();
    if (ensureFileOpen()) {
        var ts_buf: [23]u8 = undefined;
        const ts = formatTimestamp(&ts_buf);
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{s}][CRASH] " ++ fmt ++ "\n", .{ts} ++ args) catch "[CRASH] (message too long to format)\n";
        if (log_file) |f| f.writeAll(line) catch {};
    }
    if (log_file) |f| f.close();
    log_file = null;
}

// Callers already passed shouldLog(); warnings/errors flush immediately so they survive a crash right after.
inline fn writeToFile(comptime level: LogLevel, ts: []const u8, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lock();
    defer log_mutex.unlock();

    if (!ensureFileOpen()) return;

    var line_buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, comptime level.asString(), scope } ++ args) catch return;

    if (line.len > log_buf.len - log_buf_len) flushLocked();
    @memcpy(log_buf[log_buf_len..][0..line.len], line);
    log_buf_len += line.len;

    if (comptime @intFromEnum(level) >= @intFromEnum(LogLevel.warn)) flushLocked();
}

pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(.debug)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(.debug, ts, scope, fmt, args);
                std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, LogLevel.debug.asString(), scope } ++ args);
            }
        }

        pub inline fn info(comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(.info)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(.info, ts, scope, fmt, args);
                std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, LogLevel.info.asString(), scope } ++ args);
            }
        }

        pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(.warn)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(.warn, ts, scope, fmt, args);
                std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, LogLevel.warn.asString(), scope } ++ args);
            }
        }

        pub inline fn err(comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(.err)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(.err, ts, scope, fmt, args);
                std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, LogLevel.err.asString(), scope } ++ args);
            }
        }
    };
}
