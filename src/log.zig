//! The app's log file, rotated at 20MB, with a scoped logger per module and an optional debug console.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("platform/win32.zig");

pub const LOG_DIR = "logs";
pub const LOG_FILE_NAME = LOG_DIR ++ "/eve-maj.log";
pub const LOG_FILE_NAME_OLD = LOG_DIR ++ "/eve-maj.log.old";
pub const MINIDUMP_FILE_NAME = LOG_DIR ++ "/eve-maj-crash.dmp";
/// Rotated to .old at this size rather than trimmed, so a write never costs more than a size check plus (rarely) a rename.
const MAX_LOG_FILE_BYTES: u64 = 20 * 1024 * 1024;

const TRUNCATED_MARKER = "...[truncated]\n";

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

var g_level: LogLevel = .err;
/// std.debug.print caches its stderr handle on first use, so printing before AllocConsole would keep a dead one; false until openDebugConsole.
var g_console_ready = false;

var g_io: std.Io = undefined;
var g_log_file: ?std.Io.File = null;
var g_log_mutex: std.Io.Mutex = .init;

/// Buffers debug/info lines, so the frequent debug-level scan tick costs a memcpy rather than a write syscall.
var g_log_buf: [16 * 1024]u8 = undefined;
var g_log_buf_len: usize = 0;

pub fn setLevel(level: LogLevel) void {
    g_level = level;
}

/// Must be called once before any logging happens.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Pops a console for debug logging, since the Windows GUI subsystem doesn't create one; std.debug.print's console mirror stays off until this runs (see g_console_ready).
pub fn openDebugConsole() void {
    _ = win32.AllocConsole();
    g_console_ready = true;
    // Closing the console window kills the process before any `defer` can run, so buffered lines are flushed from its ctrl handler instead.
    _ = win32.SetConsoleCtrlHandler(consoleCtrlHandler, win32.TRUE);
    disableQuickEdit();
}

pub fn deinitFile() void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    flushLocked();
    if (g_log_file) |f| {
        f.close(g_io);
        g_log_file = null;
    }
}

/// Retries tryLock briefly to avoid missing the crash line, but bails instead of deadlocking if this thread already holds the lock (e.g. panicked inside the logger).
pub fn writeCrashLine(comptime fmt: []const u8, args: anytype) void {
    const lock_retries = 20;
    var attempt: u32 = 0;
    while (!g_log_mutex.tryLock()) {
        attempt += 1;
        if (attempt >= lock_retries) return;
        std.Io.sleep(g_io, .fromMilliseconds(1), .awake) catch {};
    }
    defer g_log_mutex.unlock(g_io);

    flushLocked();
    var ts_buf: [23]u8 = undefined;
    var line_buf: [512]u8 = undefined;
    appendLocked(formatLine(&line_buf, "[{s}][CRASH] " ++ fmt ++ "\n", .{formatTimestamp(&ts_buf)} ++ args));
}

pub fn scoped(comptime scope: []const u8) type {
    return struct {
        inline fn logImpl(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
            if (shouldLog(level)) {
                var ts_buf: [23]u8 = undefined;
                const ts = formatTimestamp(&ts_buf);
                writeToFile(level, ts, scope, fmt, args);
                if (g_console_ready) std.debug.print("[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, level.asString(), scope } ++ args);
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

/// Opened lazily, so a session that never logs never touches disk; caller holds g_log_mutex.
fn ensureFileOpen() bool {
    if (g_log_file != null) return true;
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(g_io, LOG_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return false,
    };
    // On Windows, length() fails without read access.
    g_log_file = cwd.createFile(g_io, LOG_FILE_NAME, .{ .read = true, .truncate = false }) catch return false;
    return true;
}

fn flush() void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    flushLocked();
}

fn shouldLog(level: LogLevel) bool {
    // Tests never call setIo, so a write would go through an undefined Io.
    if (builtin.is_test) return false;
    return @intFromEnum(level) >= @intFromEnum(g_level);
}

fn formatTimestamp(buf: *[23]u8) []const u8 {
    var st: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&st);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
    }) catch "????-??-?? ??:??:??.???";
}

/// Keeps what fits of an overlong line, marked as cut, rather than losing it.
fn formatLine(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.print(fmt, args) catch {
        @memcpy(buf[buf.len - TRUNCATED_MARKER.len ..], TRUNCATED_MARKER);
        return buf;
    };
    return writer.buffered();
}

/// Rotates to .old, replacing any previous one; if another program holds the log open, keeps appending and tries again next flush. Caller holds g_log_mutex.
fn rotate() void {
    if (g_log_file) |f| f.close(g_io);
    g_log_file = null;

    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(g_io, LOG_FILE_NAME_OLD) catch {};
    const renamed = blk: {
        cwd.rename(LOG_FILE_NAME, cwd, LOG_FILE_NAME_OLD, g_io) catch break :blk false;
        break :blk true;
    };
    g_log_file = cwd.createFile(g_io, LOG_FILE_NAME, .{ .read = true, .truncate = renamed }) catch null;
}

/// Rotates first if the file is full; the end is read, not tracked, since a second instance may have appended. Caller holds g_log_mutex.
fn appendLocked(bytes: []const u8) void {
    if (!ensureFileOpen()) return;
    var end = g_log_file.?.length(g_io) catch return;
    if (end >= MAX_LOG_FILE_BYTES) {
        rotate();
        const file = g_log_file orelse return;
        end = file.length(g_io) catch return;
    }
    g_log_file.?.writePositionalAll(g_io, bytes, end) catch return;
}

/// Caller holds g_log_mutex.
fn flushLocked() void {
    if (g_log_buf_len == 0) return;
    defer g_log_buf_len = 0;
    appendLocked(g_log_buf[0..g_log_buf_len]);
}

/// Callers already passed shouldLog; warnings and errors flush at once, so they survive a crash right after.
inline fn writeToFile(comptime level: LogLevel, ts: []const u8, comptime scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);

    var line_buf: [2048]u8 = undefined;
    const line = formatLine(&line_buf, "[{s}][{s}][{s}] " ++ fmt ++ "\n", .{ ts, comptime level.asString(), scope } ++ args);

    if (line.len > g_log_buf.len - g_log_buf_len) flushLocked();
    @memcpy(g_log_buf[g_log_buf_len..][0..line.len], line);
    g_log_buf_len += line.len;

    if (comptime @intFromEnum(level) >= @intFromEnum(LogLevel.warn)) flushLocked();
}
