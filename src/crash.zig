//! Crash reporting: fault and panic lines in eve-maj.log, and a minidump of the latest crash.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const log = @import("log.zig");

/// Overwritten on every crash - only the latest is kept, so a crash loop can't fill the disk.
/// Its folder exists by then: the crash line written just before creates it.
const MINIDUMP_FILE_NAME = std.unicode.utf8ToUtf16LeStringLiteral(log.MINIDUMP_FILE_NAME);

/// dbghelp.dll (MiniDumpWriteDump) isn't thread-safe; this flag serializes writes and resets after each attempt so a later crash can still dump.
var g_dump_write_in_progress = std.atomic.Value(bool).init(false);

/// Call first thing in main, before anything can fault.
pub fn install() void {
    _ = win32.AddVectoredExceptionHandler(1, firstChanceExceptionHandler);
    _ = win32.SetUnhandledExceptionFilter(unhandledExceptionFilter);
}

/// For main.zig's root `panic`: Zig's default handler only writes to stderr, which this GUI build doesn't show outside logLevel=debug.
pub fn handlePanic(msg: []const u8, ret_addr: ?usize) noreturn {
    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    // The base turns the trace's addresses into RVAs for llvm-symbolizer when the trace itself can't name them.
    log.writeCrashLine("PANIC: {s} (module base 0x{x})", .{ msg, base });
    logStackTrace(ret_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, ret_addr);
}

/// The panic's stack, symbolized from the .pdb beside the exe, one crash line per line of the trace.
fn logStackTrace(first_address: usize) void {
    var addresses: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = first_address }, &addresses);
    var buf: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    // Mid-crash there's nothing to do about a failed write but log what fit.
    std.debug.writeStackTrace(&trace, .{ .writer = &writer, .mode = .no_color }) catch {};
    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) log.writeCrashLine("  {s}", .{line});
    }
}

fn writeMinidump(info: *win32.EXCEPTION_POINTERS) void {
    if (g_dump_write_in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    defer g_dump_write_in_progress.store(false, .release);

    const file = win32.CreateFileW(MINIDUMP_FILE_NAME, win32.GENERIC_WRITE, win32.FILE_SHARE_READ, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win32.INVALID_HANDLE_VALUE) return;
    defer _ = win32.CloseHandle(file);

    var exc_info = win32.MINIDUMP_EXCEPTION_INFORMATION{
        .ThreadId = win32.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = win32.FALSE,
    };
    if (!win32.toBool(win32.MiniDumpWriteDump(win32.GetCurrentProcess(), win32.GetCurrentProcessId(), file, win32.MiniDumpNormal, &exc_info, null, null))) {
        log.writeCrashLine("MiniDumpWriteDump failed, GetLastError=0x{x}", .{win32.GetLastError()});
    }
}

/// Runs before Zig's segfault handler rewrites OS faults into an indistinguishable @breakpoint(); logs only the fault types Zig treats specially, passing everything else through silently.
fn firstChanceExceptionHandler(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const rec = info.ExceptionRecord orelse return win32.EXCEPTION_CONTINUE_SEARCH;
    switch (rec.ExceptionCode) {
        win32.EXCEPTION_ACCESS_VIOLATION, win32.EXCEPTION_ILLEGAL_INSTRUCTION, win32.EXCEPTION_DATATYPE_MISALIGNMENT, win32.EXCEPTION_STACK_OVERFLOW => {},
        else => return win32.EXCEPTION_CONTINUE_SEARCH,
    }

    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    const addr: usize = if (rec.ExceptionAddress) |a| @intFromPtr(a) else 0;
    if (rec.ExceptionCode == win32.EXCEPTION_ACCESS_VIOLATION and rec.NumberParameters >= 2) {
        const is_write = rec.ExceptionInformation[0] == 1;
        const fault_addr = rec.ExceptionInformation[1];
        log.writeCrashLine("First-chance access violation ({s}) at address 0x{x}, code address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ if (is_write) "write" else "read", fault_addr, addr, base, addr -% base });
    } else {
        log.writeCrashLine("First-chance exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ rec.ExceptionCode, addr, base, addr -% base });
    }
    return win32.EXCEPTION_CONTINUE_SEARCH;
}

/// Last handler in the chain, after Zig's own panic/segfault handling already ran (if any); returns EXCEPTION_CONTINUE_SEARCH so Windows' normal handling still runs after.
fn unhandledExceptionFilter(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    if (info.ExceptionRecord) |rec| {
        const addr: usize = if (rec.ExceptionAddress) |a| @intFromPtr(a) else 0;
        // Wrapping sub: a wild jump could fault below the module base and this handler must not itself panic on overflow.
        log.writeCrashLine("Unhandled exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ rec.ExceptionCode, addr, base, addr -% base });
    } else {
        log.writeCrashLine("Unhandled exception (no exception record), module base 0x{x}", .{base});
    }
    writeMinidump(info);
    return win32.EXCEPTION_CONTINUE_SEARCH;
}
