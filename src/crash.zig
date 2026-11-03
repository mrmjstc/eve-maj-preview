//! Crash reporting: fault and panic lines in eve-maj.log, and a minidump of the latest crash.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const log = @import("log.zig");

/// Overwritten on every crash, so a crash loop can't fill the disk; the crash line written just before creates its folder.
const MINIDUMP_FILE_NAME = std.unicode.utf8ToUtf16LeStringLiteral(log.MINIDUMP_FILE_NAME);
/// Room for a MAX_PATH module path and a 64-bit offset.
const LOCATION_LEN = 400;

/// MiniDumpWriteDump isn't thread-safe; cleared after each attempt so a later crash can still dump.
var g_dump_write_in_progress = std.atomic.Value(bool).init(false);

/// Call first thing in main, before anything can fault.
pub fn install() void {
    _ = win32.AddVectoredExceptionHandler(1, firstChanceExceptionHandler);
    _ = win32.SetUnhandledExceptionFilter(unhandledExceptionFilter);
}

/// For main.zig's root `panic`: Zig's default handler only writes to stderr, which this GUI build doesn't show outside logLevel=debug.
pub fn handlePanic(message: []const u8, return_address: ?usize) noreturn {
    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    // The base turns the trace's addresses into RVAs for llvm-symbolizer when the trace itself can't name them.
    log.writeCrashLine("PANIC: {s} (module base 0x{x})", .{ message, base });
    logStackTrace(return_address orelse @returnAddress());
    std.debug.defaultPanic(message, return_address);
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
    if (file == win32.INVALID_HANDLE_VALUE) {
        log.writeCrashLine("Failed to create the minidump file, GetLastError=0x{x}", .{win32.GetLastError()});
        return;
    }
    defer _ = win32.CloseHandle(file);

    var exception_info = win32.MINIDUMP_EXCEPTION_INFORMATION{
        .ThreadId = win32.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = win32.FALSE,
    };
    if (!win32.toBool(win32.MiniDumpWriteDump(win32.GetCurrentProcess(), win32.GetCurrentProcessId(), file, win32.MiniDumpNormal, &exception_info, null, null))) {
        log.writeCrashLine("Failed to write the minidump, GetLastError=0x{x}", .{win32.GetLastError()});
    }
}

/// Runs before Zig's segfault handler, which rewrites these faults into an indistinguishable @breakpoint().
fn firstChanceExceptionHandler(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const record = info.ExceptionRecord orelse return win32.EXCEPTION_CONTINUE_SEARCH;
    switch (record.ExceptionCode) {
        win32.EXCEPTION_ACCESS_VIOLATION, win32.EXCEPTION_ILLEGAL_INSTRUCTION, win32.EXCEPTION_DATATYPE_MISALIGNMENT, win32.EXCEPTION_STACK_OVERFLOW => {},
        else => return win32.EXCEPTION_CONTINUE_SEARCH,
    }

    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    const address: usize = if (record.ExceptionAddress) |a| @intFromPtr(a) else 0;
    if (record.ExceptionCode == win32.EXCEPTION_ACCESS_VIOLATION and record.NumberParameters >= 2) {
        const is_write = record.ExceptionInformation[0] == 1;
        const fault_address = record.ExceptionInformation[1];
        log.writeCrashLine("First-chance access violation ({s}) at address 0x{x}, code address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ if (is_write) "write" else "read", fault_address, address, base, address -% base });
    } else {
        log.writeCrashLine("First-chance exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ record.ExceptionCode, address, base, address -% base });
    }
    logFaultLocation(info, address);
    logReturnRvas(base);
    return win32.EXCEPTION_CONTINUE_SEARCH;
}

/// Names the modules holding the faulting code and the word on top of its stack, which after a call through a null pointer is the caller's return address.
fn logFaultLocation(info: *win32.EXCEPTION_POINTERS, code_address: usize) void {
    var code_buf: [LOCATION_LEN]u8 = undefined;
    const code = describeAddress(&code_buf, code_address);
    const context = info.ContextRecord orelse {
        log.writeCrashLine("  Thread {d}, code {s}, no context record", .{ win32.GetCurrentThreadId(), code });
        return;
    };
    const stack_top: ?*align(1) const usize = @ptrFromInt(context.getRegs().sp);
    const top_word = if (stack_top) |word| word.* else 0;
    var top_buf: [LOCATION_LEN]u8 = undefined;
    log.writeCrashLine("  Thread {d}, code {s}; top of stack 0x{x} {s}", .{ win32.GetCurrentThreadId(), code, top_word, describeAddress(&top_buf, top_word) });
}

/// The module's path and the offset into it, so code in another DLL, e.g. a Vulkan layer, is named.
fn describeAddress(buf: *[LOCATION_LEN]u8, address: usize) []const u8 {
    var module: ?win32.HMODULE = null;
    const flags = win32.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win32.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    if (address == 0 or !win32.toBool(win32.GetModuleHandleExA(flags, @ptrFromInt(address), &module))) return "in no module";
    const handle = module orelse return "in no module";
    var path_buf: [win32.MAX_PATH:0]u8 = undefined;
    const path_length = win32.GetModuleFileNameA(handle, &path_buf, path_buf.len);
    return std.fmt.bufPrint(buf, "in '{s}' +0x{x}", .{ path_buf[0..path_length], address -% @intFromPtr(handle) }) catch unreachable;
}

/// Unsymbolized, since loading the .pdb mid-fault can fault again; the RVAs are resolved offline against the release build's .pdb.
fn logReturnRvas(base: usize) void {
    var addresses: [24]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{}, &addresses);
    var buf: [400]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    // Mid-crash there's nothing to do about a failed write but log what fit.
    for (trace.return_addresses) |address| writer.print(" 0x{x}", .{address -% base}) catch {};
    log.writeCrashLine("  Return RVAs:{s}", .{writer.buffered()});
}

/// Runs after Zig's own panic and segfault handling; continues the search so Windows' crash handling still runs.
fn unhandledExceptionFilter(info: *win32.EXCEPTION_POINTERS) callconv(.c) win32.LONG {
    const base: usize = if (win32.GetModuleHandleA(null)) |h| @intFromPtr(h) else 0;
    if (info.ExceptionRecord) |record| {
        const address: usize = if (record.ExceptionAddress) |a| @intFromPtr(a) else 0;
        // Wrapping, since a wild jump can fault below the module base.
        log.writeCrashLine("Unhandled exception 0x{x} at address 0x{x} (module base 0x{x}, RVA 0x{x})", .{ record.ExceptionCode, address, base, address -% base });
    } else {
        log.writeCrashLine("Unhandled exception (no exception record), module base 0x{x}", .{base});
    }
    writeMinidump(info);
    return win32.EXCEPTION_CONTINUE_SEARCH;
}
