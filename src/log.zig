//! The app's log file, rotated at 20MB, with a scoped logger per module and an optional debug console.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("platform/win32.zig");

const slog = Scoped("log");

pub const LOG_DIR = "logs";
pub const LOG_FILE_NAME = LOG_DIR ++ "/eve-maj.log";
pub const LOG_FILE_NAME_OLD = LOG_DIR ++ "/eve-maj.log.old";
pub const MINIDUMP_FILE_NAME = LOG_DIR ++ "/eve-maj-crash.dmp";
/// Rotated to .old at this size rather than trimmed, so a write never costs more than a size check plus (rarely) a rename.
const MAX_LOG_FILE_BYTES: u64 = 20 * 1024 * 1024;

const TRUNCATED_MARKER = "...[truncated]\n";
/// A held line's level byte and two-byte length, before the line itself.
const HELD_HEADER_SIZE = 3;

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,

    fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Set by the main thread, read by every logging thread.
var g_level: std.atomic.Value(LogLevel) = .init(.err);
/// Until the first setLevel, lines below err are held rather than filtered, since the level they'd be judged by isn't known yet.
var g_is_level_set: std.atomic.Value(bool) = .init(false);
/// Main thread writes it under g_log_mutex; printing before AllocConsole would cache a dead stderr handle.
var g_is_console_shown = false;
/// The console is hidden rather than freed, since a reallocated one would get a handle the cached one doesn't match.
var g_has_console = false;

/// Set once by setIo before any thread logs, then only read.
var g_io: std.Io = undefined;
/// Guards the file and buffers below, which every logging thread writes.
var g_log_mutex: std.Io.Mutex = .init;
var g_log_file: ?std.Io.File = null;
/// Buffers debug/info lines, so the frequent debug-level scan tick costs a memcpy rather than a write syscall.
var g_log_buf: [16 * 1024]u8 = undefined;
var g_log_buf_length: usize = 0;
/// The console's copy of the lines, written out together by flushConsole: each console write costs far more than a file write.
var g_console_buf: [16 * 1024]u8 = undefined;
var g_console_buf_length: usize = 0;
/// Lines logged before the first setLevel, each after its HELD_HEADER_SIZE header; guarded by g_log_mutex.
var g_held_buf: [16 * 1024]u8 = undefined;
var g_held_length: usize = 0;
/// Held lines that didn't fit; guarded by g_log_mutex.
var g_held_dropped_count: usize = 0;

/// The first call writes out the lines held until then that `level` lets through.
pub fn setLevel(level: LogLevel) void {
    g_level.store(level, .monotonic);
    if (g_is_level_set.swap(true, .acq_rel)) return;
    const dropped_count = releaseHeld(level);
    if (dropped_count > 0) slog.warn("Failed to keep {d} line(s) logged before the log level was set: the startup buffer was full", .{dropped_count});
}

/// Must be called once before any logging happens.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Allocates or re-shows a console, since the GUI subsystem has none.
pub fn openDebugConsole() void {
    if (g_is_console_shown) return;
    if (g_has_console) {
        if (win32.GetConsoleWindow()) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
    } else {
        _ = win32.AllocConsole();
        g_has_console = true;
        // Closing the console ends the process before any defer runs, so its ctrl handler flushes instead.
        _ = win32.SetConsoleCtrlHandler(consoleCtrlHandler, win32.TRUE);
        disableQuickEdit();
    }
    setConsoleShown(true);
}

/// Hides the console and stops mirroring to it; openDebugConsole shows it again.
pub fn closeDebugConsole() void {
    if (!g_is_console_shown) return;
    setConsoleShown(false);
    if (win32.GetConsoleWindow()) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
}

/// From the app's tick, so console lines show within one tick of being logged.
pub fn flushConsole() void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    flushConsoleLocked();
}

/// Writes buffered lines out now, for when the process may end without reaching deinitFile.
pub fn flush() void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    flushLocked();
    flushConsoleLocked();
}

pub fn deinitFile() void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    flushLocked();
    flushConsoleLocked();
    if (g_log_file) |f| {
        f.close(g_io);
        g_log_file = null;
    }
}

/// Retries tryLock briefly rather than locking, so a crash inside the logger can't deadlock.
pub fn writeCrashLine(comptime text_format: []const u8, args: anytype) void {
    const lock_retries = 20;
    var attempt_count: u32 = 0;
    while (!g_log_mutex.tryLock()) {
        attempt_count += 1;
        if (attempt_count >= lock_retries) return;
        std.Io.sleep(g_io, .fromMilliseconds(1), .awake) catch {};
    }
    defer g_log_mutex.unlock(g_io);

    flushLocked();
    flushConsoleLocked();
    var timestamp_buf: [23]u8 = undefined;
    var line_buf: [512]u8 = undefined;
    appendLocked(formatLine(&line_buf, "[{s}][CRASH] " ++ text_format ++ "\n", .{formatTimestamp(&timestamp_buf)} ++ args));
}

pub fn Scoped(comptime scope: []const u8) type {
    return struct {
        inline fn logImpl(comptime level: LogLevel, comptime text_format: []const u8, args: anytype) void {
            if (shouldLog(level)) {
                var timestamp_buf: [23]u8 = undefined;
                writeLine(level, formatTimestamp(&timestamp_buf), scope, text_format, args);
            }
        }

        pub inline fn debug(comptime text_format: []const u8, args: anytype) void {
            logImpl(.debug, text_format, args);
        }

        pub inline fn info(comptime text_format: []const u8, args: anytype) void {
            logImpl(.info, text_format, args);
        }

        pub inline fn warn(comptime text_format: []const u8, args: anytype) void {
            logImpl(.warn, text_format, args);
        }

        pub inline fn err(comptime text_format: []const u8, args: anytype) void {
            logImpl(.err, text_format, args);
        }
    };
}

/// A click in a QuickEdit console starts a selection that blocks every console write until it ends, freezing whichever thread logs next.
fn disableQuickEdit() void {
    const input = win32.GetStdHandle(win32.STD_INPUT_HANDLE) orelse {
        slog.warn("Failed to get the console input handle; clicking the debug console can pause the app", .{});
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
    // Unhandled, so the event's default action (e.g. ending the process) still runs.
    return win32.FALSE;
}

/// Opened lazily, so a session that never logs never touches disk; caller holds g_log_mutex.
fn logFile() ?std.Io.File {
    if (g_log_file) |file| return file;
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(g_io, LOG_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };
    // On Windows, length() fails without read access.
    g_log_file = cwd.createFile(g_io, LOG_FILE_NAME, .{ .read = true, .truncate = false }) catch return null;
    return g_log_file;
}

/// Main thread only; on hiding, writes out what the console has buffered first.
fn setConsoleShown(is_shown: bool) void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);
    if (!is_shown) flushConsoleLocked();
    g_is_console_shown = is_shown;
}

fn shouldLog(level: LogLevel) bool {
    // Tests never call setIo, so a write would go through an undefined Io.
    if (builtin.is_test) return false;
    return !g_is_level_set.load(.monotonic) or @backingInt(level) >= @backingInt(g_level.load(.monotonic));
}

/// Returns how many lines didn't fit while held.
fn releaseHeld(level: LogLevel) usize {
    if (builtin.is_test) return 0;
    g_log_mutex.lock(g_io) catch return 0;
    defer g_log_mutex.unlock(g_io);
    var index: usize = 0;
    while (index < g_held_length) {
        const line_level: LogLevel = @fromBackingInt(g_held_buf[index]);
        const line_length = std.mem.readInt(u16, g_held_buf[index + 1 ..][0..2], .little);
        const line = g_held_buf[index + HELD_HEADER_SIZE ..][0..line_length];
        index += HELD_HEADER_SIZE + line_length;
        if (@backingInt(line_level) >= @backingInt(level)) bufferLocked(line);
    }
    g_held_length = 0;
    flushLocked();
    const dropped_count = g_held_dropped_count;
    g_held_dropped_count = 0;
    return dropped_count;
}

fn formatTimestamp(buf: *[23]u8) []const u8 {
    var system_time: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&system_time);
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        system_time.wYear, system_time.wMonth, system_time.wDay, system_time.wHour, system_time.wMinute, system_time.wSecond, system_time.wMilliseconds,
    }) catch "????-??-?? ??:??:??.???";
}

/// Keeps what fits of an overlong line, marked as cut, rather than losing it.
fn formatLine(buf: []u8, comptime text_format: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    writer.print(text_format, args) catch {
        @memcpy(buf[buf.len - TRUNCATED_MARKER.len ..], TRUNCATED_MARKER);
        return buf;
    };
    return writer.buffered();
}

/// Rotates to .old, replacing any previous one; if another program holds the log open, keeps appending and tries again next flush; caller holds g_log_mutex.
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

/// Rotates first if the file is full; the end is read, not tracked, since a second instance may have appended; caller holds g_log_mutex.
fn appendLocked(bytes: []const u8) void {
    var file = logFile() orelse return;
    var end = file.length(g_io) catch return;
    if (end >= MAX_LOG_FILE_BYTES) {
        rotate();
        file = g_log_file orelse return;
        end = file.length(g_io) catch return;
    }
    file.writePositionalAll(g_io, bytes, end) catch return;
}

/// Caller holds g_log_mutex.
fn flushLocked() void {
    if (g_log_buf_length == 0) return;
    defer g_log_buf_length = 0;
    appendLocked(g_log_buf[0..g_log_buf_length]);
}

/// Caller holds g_log_mutex.
fn bufferLocked(line: []const u8) void {
    if (line.len > g_log_buf.len - g_log_buf_length) flushLocked();
    @memcpy(g_log_buf[g_log_buf_length..][0..line.len], line);
    g_log_buf_length += line.len;
}

/// Caller holds g_log_mutex.
fn holdLocked(level: LogLevel, line: []const u8) void {
    if (HELD_HEADER_SIZE + line.len > g_held_buf.len - g_held_length) {
        g_held_dropped_count += 1;
        return;
    }
    g_held_buf[g_held_length] = @backingInt(level);
    std.mem.writeInt(u16, g_held_buf[g_held_length + 1 ..][0..2], @intCast(line.len), .little);
    @memcpy(g_held_buf[g_held_length + HELD_HEADER_SIZE ..][0..line.len], line);
    g_held_length += HELD_HEADER_SIZE + line.len;
}

/// Caller holds g_log_mutex.
fn flushConsoleLocked() void {
    if (g_console_buf_length == 0) return;
    defer g_console_buf_length = 0;
    if (g_is_console_shown) std.debug.print("{s}", .{g_console_buf[0..g_console_buf_length]});
}

/// Buffers the line for the file, and the console while it's shown; warnings and errors flush at once, so they survive a crash right after.
inline fn writeLine(comptime level: LogLevel, timestamp: []const u8, comptime scope: []const u8, comptime text_format: []const u8, args: anytype) void {
    g_log_mutex.lock(g_io) catch return;
    defer g_log_mutex.unlock(g_io);

    var line_buf: [2048]u8 = undefined;
    const line = formatLine(&line_buf, "[{s}][{s}][{s}] " ++ text_format ++ "\n", .{ timestamp, comptime level.asString(), scope } ++ args);

    // An error passes any level, so it's written at once, in case startup crashes before the level is set.
    if (comptime level != .err) {
        if (!g_is_level_set.load(.monotonic)) return holdLocked(level, line);
    }
    bufferLocked(line);

    if (g_is_console_shown) {
        if (line.len > g_console_buf.len - g_console_buf_length) flushConsoleLocked();
        @memcpy(g_console_buf[g_console_buf_length..][0..line.len], line);
        g_console_buf_length += line.len;
    }

    if (comptime @backingInt(level) >= @backingInt(LogLevel.warn)) {
        flushLocked();
        flushConsoleLocked();
    }
}
