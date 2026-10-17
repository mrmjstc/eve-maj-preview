//! The thread the low-level keyboard and mouse hooks run on, so a busy main thread never delays system-wide input or gets the hooks removed by Windows.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("hotkeys");

/// What `call` posts: `run(context)`, on the hook thread.
const Request = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
};

/// Main thread only.
var g_thread: ?std.Thread = null;
/// Written by the hook thread before it first signals g_done_event, which the main thread waits for before reading it.
var g_thread_id: win32.DWORD = 0;
/// Main thread only; set while the hook thread runs, and signalled by it once ready and after each request.
var g_done_event: ?win32.HANDLE = null;

/// Waits until the thread takes requests; if it can't start, `call` runs everything on the main thread, as before the hook thread existed.
pub fn start() void {
    if (g_thread != null) return;
    const done_event = win32.CreateEventA(null, win32.FALSE, win32.FALSE, null) orelse {
        slog.err("Failed to create the hotkey hook thread's event, running hooks on the main thread: error {d}", .{win32.GetLastError()});
        return;
    };
    const thread = std.Thread.spawn(.{}, threadMain, .{done_event}) catch |err| {
        slog.err("Failed to start the hotkey hook thread, running hooks on the main thread: {}", .{err});
        _ = win32.CloseHandle(done_event);
        return;
    };
    _ = win32.WaitForSingleObject(done_event, win32.INFINITE);
    g_thread = thread;
    g_done_event = done_event;
}

/// Once every hook is uninstalled through `call`; later calls run on the main thread.
pub fn stop() void {
    const thread = g_thread orelse return;
    g_thread = null;
    if (win32.toBool(win32.PostThreadMessageA(g_thread_id, win32.WM_QUIT, 0, 0))) {
        thread.join();
    } else {
        slog.err("Failed to stop the hotkey hook thread, leaving it to exit with the app: error {d}", .{win32.GetLastError()});
        thread.detach();
    }
    if (g_done_event) |done_event| _ = win32.CloseHandle(done_event);
    g_done_event = null;
}

/// Runs `func(context)` on the hook thread and waits for it, so only that thread touches the hooks' state; main thread only, and false if the thread couldn't be reached, which it logs.
pub fn call(context: anytype, comptime func: fn (@TypeOf(context)) void) bool {
    const Erased = struct {
        fn run(erased: *anyopaque) void {
            func(@ptrCast(@alignCast(erased)));
        }
    };
    const done_event = g_done_event orelse {
        func(context);
        return true;
    };
    var request: Request = .{ .context = context, .run = Erased.run };
    if (!win32.toBool(win32.PostThreadMessageA(g_thread_id, win32.WM_HOOK_REQUEST, 0, win32.ptrToLparam(&request)))) {
        slog.err("Failed to reach the hotkey hook thread: error {d}", .{win32.GetLastError()});
        return false;
    }
    _ = win32.WaitForSingleObject(done_event, win32.INFINITE);
    return true;
}

fn threadMain(done_event: win32.HANDLE) void {
    var msg: win32.MSG = undefined;
    // Creates this thread's message queue, so a request posted as soon as start returns isn't lost.
    _ = win32.PeekMessageA(&msg, null, 0, 0, win32.PM_NOREMOVE);
    // Every input event on the desktop waits on these hooks, and each takes microseconds, so the top priority can't starve anything.
    if (!win32.toBool(win32.SetThreadPriority(win32.GetCurrentThread(), win32.THREAD_PRIORITY_TIME_CRITICAL))) {
        slog.warn("Failed to raise the hotkey hook thread's priority: error {d}", .{win32.GetLastError()});
    }
    g_thread_id = win32.GetCurrentThreadId();
    slog.info("Hotkey hook thread started (TID: {})", .{g_thread_id});
    _ = win32.SetEvent(done_event);

    while (true) {
        const result = win32.GetMessageA(&msg, null, 0, 0);
        if (result == 0) break;
        if (result < 0) {
            slog.err("Failed to read the hotkey hook thread's messages, stopping it: error {d}", .{win32.GetLastError()});
            break;
        }
        if (msg.message != win32.WM_HOOK_REQUEST) continue;
        const request = win32.lparamToPtr(Request, msg.lParam);
        request.run(request.context);
        _ = win32.SetEvent(done_event);
    }
    slog.info("Hotkey hook thread exiting", .{});
}
