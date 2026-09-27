const std = @import("std");
const win32 = @import("platform/win32.zig");

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
// std.debug.print's stderr handle is resolved once and cached forever on first use (Io.Threaded's
// global debug-io singleton), so calling it before AllocConsole() permanently poisons it with a
// stale pre-console handle. Guard it until openDebugConsole() has actually created one.
var console_ready = false;

pub const LOG_FILE_NAME = "eve-maj.log";
const LOG_FILE_NAME_OLD = "eve-maj.log.old";
// Rotated to .old at this size rather than trimmed, so a write never costs more than a size check plus (rarely) a rename.
const MAX_LOG_FILE_BYTES: u64 = 5 * 1024 * 1024;

var g_io: std.Io = undefined;
var log_file: ?std.Io.File = null;
var log_file_size: u64 = 0;
var log_mutex: std.Io.Mutex = .init;

// Buffers debug/info lines so the frequent debug-level scan tick costs a memcpy, not a write() syscall.
var log_buf: [16 * 1024]u8 = undefined;
var log_buf_len: usize = 0;

pub fn setLevel(level: LogLevel) void {
    current_level = level;
}

/// Must be called once before any logging happens.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Pops a console for debug logging, since the Windows GUI subsystem doesn't create one; std.debug.print's console mirror stays off until this runs (see console_ready).
pub fn openDebugConsole() void {
    _ = win32.AllocConsole();
    console_ready = true;
    // Closing the console window kills the process before any `defer` can run, so buffered lines are flushed from its ctrl handler instead.
    _ = win32.SetConsoleCtrlHandler(consoleCtrlHandler, win32.TRUE);
    disableQuickEdit();
}

/// A click in a QuickEdit console starts a selection that blocks every console write until it ends, freezing whichever thread logs next.
fn disableQuickEdit() void {
    const slog = scoped("log");
    const input = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse {
        slog.warn("No console input handle; clicking the debug console can pause the app", .{});
        return;
    };
    var mode: win32.DWORD = 0;
    if (!win32.toBool(win32.GetConsoleMode(input, &mode)) or
        !win32.toBool(win32.SetConsoleMode(input, (mode & ~win32.ENABLE_QUICK_EDIT_MODE) | win32.ENABLE_EXTENDED_FLAGS)))
    {
        slog.warn("Failed to disable console QuickEdit; clicking the debug console can pause the app", .{});
    }
}

fn consoleCtrlHandler(ctrl_type: win32.DWORD) callconv(.c) win32.BOOL {
    switch (ctrl_type) {
        win32.CTRL_C_EVENT, win32.CTRL_BREAK_EVENT, win32.CTRL_CLOSE_EVENT, win32.CTRL_LOGOFF_EVENT, win32.CTRL_SHUTDOWN_EVENT => {
            flush();
        },
        else => {},
    }
    // Never claim to have handled it: this only flushes, the OS's default behavior for the event (e.g. terminating the process) still applies.
    return win32.FALSE;
}

/// Lazily opens the log file so a session that never logs never touches disk.
/// Must be called with log_mutex held.
fn ensureFileOpen() bool {
    if (log_file != null) return true;

    const file = std.Io.Dir.cwd().createFile(g_io, LOG_FILE_NAME, .{ .truncate = false }) catch return false;
    const end_pos = file.length(g_io) catch 0;
    log_file = file;
    log_file_size = end_pos;
    return true;
}

/// Used by the console control handler, since closing that window kills the process before any `defer` can run.
pub fn flush() void {
    log_mutex.lock(g_io) catch return;
    defer log_mutex.unlock(g_io);
    flushLocked();
}

pub fn deinitFile() void {
    log_mutex.lock(g_io) catch return;
    defer log_mutex.unlock(g_io);
    flushLocked();
    if (log_file) |f| {
        f.close(g_io);
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
    if (log_file) |f| f.close(g_io);
    log_file = null;

    std.Io.Dir.cwd().deleteFile(g_io, LOG_FILE_NAME_OLD) catch {};
    std.Io.Dir.cwd().rename(LOG_FILE_NAME, std.Io.Dir.cwd(), LOG_FILE_NAME_OLD, g_io) catch {};

    log_file = std.Io.Dir.cwd().createFile(g_io, LOG_FILE_NAME, .{}) catch null;
    log_file_size = 0;
}

/// Writes any buffered lines to disk. Must be called with log_mutex held.
fn flushLocked() void {
    if (log_buf_len == 0) return;
    defer log_buf_len = 0;

    if (log_file_size >= MAX_LOG_FILE_BYTES) rotate();
    const file = log_file orelse return;

    file.writePositionalAll(g_io, log_buf[0..log_buf_len], log_file_size) catch return;
    log_file_size += log_buf_len;
}

/// Retries tryLock briefly to avoid missing the crash line, but bails instead of deadlocking if this thread already holds the lock (e.g. panicked inside the logger).
pub fn writeCrashLine(comptime fmt: []const u8, args: anytype) void {
    const lock_retries = 20;
    var attempt: u32 = 0;
    while (!log_mutex.tryLock()) {
        attempt += 1;
        if (attempt >= lock_retries) return;
        std.Io.sleep(g_io, .fromMilliseconds(1), .awake) catch {};
    }
    defer log_mutex.unlock(g_io);

    flushLocked();
    if (ensureFileOpen()) {
        var ts_buf: [23]u8 = undefined;
        const ts = formatTimestamp(&ts_buf);
        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "[{s}][CRASH] " ++ fmt ++ "\n", .{ts} ++ args) catch "[CRASH] (message too long to format)\n";
        if (log_file) |f| {
            f.writePositionalAll(g_io, line, log_file_size) catch {};
            log_file_size += line.len;
        }
    }
    if (log_file) |f| f.close(g_io);
    log_file = null;
}

// Callers already passed shouldLog(); warnings/errors flush immediately so they survive a crash right after.
inline fn writeToFile(comptime level: LogLevel, ts: []const u8, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lock(g_io) catch return;
    defer log_mutex.unlock(g_io);

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
        inline fn logImpl(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(level)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(level, ts, scope, fmt, args);
                if (console_ready) std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, level.asString(), scope } ++ args);
            }
        }

        pub inline fn debug(comptime fmt: []const u8, args: anytype) void {
            logImpl(.debug, fmt, args);
        }

        pub inline fn info(comptime fmt: []const u8, args: anytype) void {
            logImpl(.info, fmt, args);
        }

        pub inline fn warn(comptime fmt: []const u8, args: anytype) void {
            logImpl(.warn, fmt, args);
        }

        pub inline fn err(comptime fmt: []const u8, args: anytype) void {
            logImpl(.err, fmt, args);
        }
    };
}
