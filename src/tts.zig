const std = @import("std");
const windows = std.os.windows;
const log = @import("log.zig");
const slog = log.scoped("tts");

const IID_IDispatch = windows.GUID{
    .Data1 = 0x00020400,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = [8]u8{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IID_NULL = windows.GUID{
    .Data1 = 0,
    .Data2 = 0,
    .Data3 = 0,
    .Data4 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

const COINIT_APARTMENTTHREADED: u32 = 0x2;
const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
const CLSCTX_INPROC_SERVER: u32 = 0x1;
// Not the real LOCALE_USER_DEFAULT (0x0400); SpVoice's member names aren't localized so any valid LCID works, and en-US is a safe choice.
const LCID_EN_US: u32 = 0x0409;

const DISPATCH_METHOD: u16 = 0x1;
const DISPATCH_PROPERTYGET: u16 = 0x2;
const DISPATCH_PROPERTYPUT: u16 = 0x4;
const DISPID_PROPERTYPUT: i32 = -3;

const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) c_long;
extern "ole32" fn CoUninitialize() callconv(.c) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const windows.GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const windows.GUID,
    ppv: *?*anyopaque,
) callconv(.c) c_long;
extern "ole32" fn CLSIDFromProgID(lpszProgID: [*:0]const u16, lpclsid: *windows.GUID) callconv(.c) c_long;

extern "oleaut32" fn SysAllocString(psz: [*:0]const u16) callconv(.c) ?[*:0]u16;
extern "oleaut32" fn SysFreeString(bstr: ?[*:0]u16) callconv(.c) void;

const VARIANT = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    payload: u64 = 0,

    fn fromI32(v: i32) VARIANT {
        return .{ .vt = VT_I4, .payload = @as(u64, @bitCast(@as(i64, v))) };
    }

    fn fromBstr(bstr: [*:0]u16) VARIANT {
        return .{ .vt = VT_BSTR, .payload = @intFromPtr(bstr) };
    }
};

const DISPPARAMS = extern struct {
    rgvarg: ?[*]VARIANT,
    rgdispidNamedArgs: ?[*]i32,
    cArgs: u32,
    cNamedArgs: u32,
};

// Driven via late-bound Invoke rather than a hand-rolled ISpVoice vtable, since IDispatch's layout is fixed while SAPI's real vtable order is easy to mis-transcribe.
const IDispatch = extern struct {
    vtable: *const IDispatchVtbl,

    const IDispatchVtbl = extern struct {
        QueryInterface: *const fn (*IDispatch, *const windows.GUID, *?*anyopaque) callconv(.c) c_long,
        AddRef: *const fn (*IDispatch) callconv(.c) u32,
        Release: *const fn (*IDispatch) callconv(.c) u32,
        GetTypeInfoCount: *const fn (*IDispatch, *u32) callconv(.c) c_long,
        GetTypeInfo: *const fn (*IDispatch, u32, u32, *?*anyopaque) callconv(.c) c_long,
        GetIDsOfNames: *const fn (*IDispatch, *const windows.GUID, [*]const [*:0]const u16, u32, u32, [*]i32) callconv(.c) c_long,
        Invoke: *const fn (*IDispatch, i32, *const windows.GUID, u32, u16, *DISPPARAMS, ?*VARIANT, ?*anyopaque, ?*u32) callconv(.c) c_long,
    };

    fn release(self: *IDispatch) void {
        _ = self.vtable.Release(self);
    }

    fn getDispId(self: *IDispatch, name: [*:0]const u16) !i32 {
        var names = [_][*:0]const u16{name};
        var dispids = [_]i32{0};
        const hr = self.vtable.GetIDsOfNames(self, &IID_NULL, &names, 1, LCID_EN_US, &dispids);
        if (hr < 0) return error.GetIDsOfNamesFailed;
        return dispids[0];
    }

    fn invokeMethod(self: *IDispatch, dispid: i32, args: []VARIANT) !void {
        var params = DISPPARAMS{
            .rgvarg = args.ptr,
            .rgdispidNamedArgs = null,
            .cArgs = @intCast(args.len),
            .cNamedArgs = 0,
        };
        // SAPI's SpVoice rejects a bare DISPATCH_METHOD flag; combine with DISPATCH_PROPERTYGET so Invoke can disambiguate a method call from an array-element get.
        const hr = self.vtable.Invoke(self, dispid, &IID_NULL, LCID_EN_US, DISPATCH_METHOD | DISPATCH_PROPERTYGET, &params, null, null, null);
        if (hr < 0) return error.InvokeFailed;
    }

    fn invokePropertyPut(self: *IDispatch, dispid: i32, value: i32) !void {
        var args = [_]VARIANT{VARIANT.fromI32(value)};
        var named_args = [_]i32{DISPID_PROPERTYPUT};
        var params = DISPPARAMS{
            .rgvarg = &args,
            .rgdispidNamedArgs = &named_args,
            .cArgs = 1,
            .cNamedArgs = 1,
        };
        const hr = self.vtable.Invoke(self, dispid, &IID_NULL, LCID_EN_US, DISPATCH_PROPERTYPUT, &params, null, null, null);
        if (hr < 0) return error.InvokeFailed;
    }
};

// COM objects are apartment-affine, so every method here (not just speak) must run on the same STA thread that created dispatch.
const TtsEngine = struct {
    dispatch: *IDispatch,
    speak_dispid: i32,
    rate_dispid: i32,
    volume_dispid: i32,

    fn init() !TtsEngine {
        const hr_init = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
        // 0x1 is S_FALSE (already initialized on this thread), which is fine.
        if (hr_init < 0 and hr_init != 0x1) {
            return error.ComInitFailed;
        }
        errdefer CoUninitialize();

        var clsid: windows.GUID = undefined;
        const progid = std.unicode.utf8ToUtf16LeStringLiteral("SAPI.SpVoice");
        if (CLSIDFromProgID(progid, &clsid) < 0) {
            return error.SapiNotAvailable;
        }

        var dispatch_ptr: ?*anyopaque = null;
        const create_hr = CoCreateInstance(&clsid, null, CLSCTX_INPROC_SERVER, &IID_IDispatch, &dispatch_ptr);
        if (create_hr < 0 or dispatch_ptr == null) {
            return error.CreateSpVoiceFailed;
        }

        const dispatch: *IDispatch = @ptrCast(@alignCast(dispatch_ptr.?));
        errdefer dispatch.release();

        const speak_dispid = try dispatch.getDispId(std.unicode.utf8ToUtf16LeStringLiteral("Speak"));
        const rate_dispid = try dispatch.getDispId(std.unicode.utf8ToUtf16LeStringLiteral("Rate"));
        const volume_dispid = try dispatch.getDispId(std.unicode.utf8ToUtf16LeStringLiteral("Volume"));

        return .{
            .dispatch = dispatch,
            .speak_dispid = speak_dispid,
            .rate_dispid = rate_dispid,
            .volume_dispid = volume_dispid,
        };
    }

    fn setVolume(self: *TtsEngine, volume: u8) void {
        self.dispatch.invokePropertyPut(self.volume_dispid, @intCast(volume)) catch |err| {
            slog.warn("Failed to set TTS volume: {}", .{err});
        };
    }

    fn setRate(self: *TtsEngine, rate: i8) void {
        self.dispatch.invokePropertyPut(self.rate_dispid, @intCast(rate)) catch |err| {
            slog.warn("Failed to set TTS rate: {}", .{err});
        };
    }

    // Blocks until finished: SpVoice's Invoke only accepts the reduced-arity Text-only call, not one with an explicit Flags arg, so this must never run on the main thread.
    fn speak(self: *TtsEngine, text: []const u8) void {
        const text_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, text) catch |err| {
            slog.warn("Failed to convert TTS text to UTF-16: {}", .{err});
            return;
        };
        defer std.heap.page_allocator.free(text_w);

        const bstr = SysAllocString(text_w) orelse {
            slog.warn("SysAllocString failed for TTS text", .{});
            return;
        };
        defer SysFreeString(bstr);

        var args = [_]VARIANT{VARIANT.fromBstr(bstr)};
        self.dispatch.invokeMethod(self.speak_dispid, &args) catch |err| {
            slog.warn("Failed to speak TTS alert: {}", .{err});
        };
    }

    fn deinit(self: *TtsEngine) void {
        self.dispatch.release();
        CoUninitialize();
    }
};

const Command = union(enum) {
    // Must be page_allocator-owned; the worker frees it after speaking (or shutdown() frees it if still queued).
    speak: []const u8,
    set_volume: u8,
    set_rate: i8,
};

const CommandQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Command) = .empty,

    fn push(self: *CommandQueue, cmd: Command) !void {
        try self.mutex.lock(g_io);
        defer self.mutex.unlock(g_io);
        try self.items.append(std.heap.page_allocator, cmd);
    }

    fn pop(self: *CommandQueue) ?Command {
        self.mutex.lock(g_io) catch return null;
        defer self.mutex.unlock(g_io);
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

var g_io: std.Io = undefined;
var g_queue: CommandQueue = .{};
var g_thread: ?std.Thread = null;
var g_thread_failed: bool = false;
var g_should_exit = std.atomic.Value(bool).init(false);
var g_worker_dead = std.atomic.Value(bool).init(false);

/// Must be called once before any TTS function is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

const WORKER_POLL_MS: u64 = 50;

fn workerMain() void {
    var engine = TtsEngine.init() catch |err| {
        slog.warn("TTS unavailable (SAPI init failed): {}", .{err});
        g_worker_dead.store(true, .release);
        return;
    };
    defer engine.deinit();
    slog.info("TTS engine initialized", .{});

    while (!g_should_exit.load(.acquire)) {
        const cmd = g_queue.pop() orelse {
            std.Io.sleep(g_io, .fromMilliseconds(@intCast(WORKER_POLL_MS)), .awake) catch {};
            continue;
        };
        switch (cmd) {
            .speak => |text| {
                defer std.heap.page_allocator.free(text);
                engine.speak(text);
            },
            .set_volume => |v| engine.setVolume(v),
            .set_rate => |r| engine.setRate(r),
        }
    }
}

fn ensureWorker() bool {
    if (g_thread != null) {
        if (!g_worker_dead.load(.acquire)) return true;
        g_thread.?.join();
        g_thread = null;
        g_thread_failed = true;
        return false;
    }
    if (g_thread_failed) return false;

    g_thread = std.Thread.spawn(.{}, workerMain, .{}) catch |err| {
        slog.warn("Failed to start TTS worker thread: {}", .{err});
        g_thread_failed = true;
        return false;
    };
    return true;
}

/// Queue a volume/rate change for the worker thread; safe even if TTS hasn't started yet, and silently no-ops if the worker fails to start.
pub fn setVoiceSettings(volume: u8, rate: i8) void {
    if (!ensureWorker()) return;
    g_queue.push(.{ .set_volume = volume }) catch |err| {
        slog.warn("Failed to queue TTS volume change: {}", .{err});
    };
    g_queue.push(.{ .set_rate = rate }) catch |err| {
        slog.warn("Failed to queue TTS rate change: {}", .{err});
    };
}

/// Queue a short alert phrase to be spoken; returns immediately and speaks in FIFO order on the lazily-started worker thread, no-op if SAPI is unavailable.
pub fn speakAlert(text: []const u8) void {
    if (!ensureWorker()) return;
    const copy = std.heap.page_allocator.dupe(u8, text) catch |err| {
        slog.warn("Failed to queue TTS alert: {}", .{err});
        return;
    };
    g_queue.push(.{ .speak = copy }) catch |err| {
        slog.warn("Failed to queue TTS alert: {}", .{err});
        std.heap.page_allocator.free(copy);
    };
}

/// Stop the worker thread, if one was ever started. Call once during app shutdown.
pub fn shutdown() void {
    const thread = g_thread orelse return;
    g_should_exit.store(true, .release);
    thread.join();
    g_thread = null;

    while (g_queue.pop()) |cmd| {
        if (cmd == .speak) std.heap.page_allocator.free(cmd.speak);
    }
}
