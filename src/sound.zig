const std = @import("std");
const windows = std.os.windows;
const log = @import("log.zig");
const slog = log.scoped("sound");

const HRESULT = c_long;
const WCHAR = u16;
const BOOL = c_int;
const HANDLE = *anyopaque;
const DWORD = u32;

// Vtables below are transcribed from mingw-w64's mfobjects.h/mfreadwrite.h - Microsoft's own Learn
// docs list interface methods alphabetically, not in ABI order, and would silently break these calls.

const MF_MT_MAJOR_TYPE = windows.GUID{
    .Data1 = 0x48eba18e,
    .Data2 = 0xf8c9,
    .Data3 = 0x4687,
    .Data4 = [8]u8{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f },
};
const MF_MT_SUBTYPE = windows.GUID{
    .Data1 = 0xf7e34c9a,
    .Data2 = 0x42e8,
    .Data3 = 0x4714,
    .Data4 = [8]u8{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 },
};
const MFMediaType_Audio = windows.GUID{
    .Data1 = 0x73647561,
    .Data2 = 0x0000,
    .Data3 = 0x0010,
    .Data4 = [8]u8{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
};
const MFAudioFormat_PCM = windows.GUID{
    .Data1 = 0x00000001,
    .Data2 = 0x0000,
    .Data3 = 0x0010,
    .Data4 = [8]u8{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
};
const MF_MT_AUDIO_NUM_CHANNELS = windows.GUID{
    .Data1 = 0x37e48bf5,
    .Data2 = 0x645e,
    .Data3 = 0x4c5b,
    .Data4 = [8]u8{ 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a },
};
const MF_MT_AUDIO_SAMPLES_PER_SECOND = windows.GUID{
    .Data1 = 0x5faeeae7,
    .Data2 = 0x0290,
    .Data3 = 0x4c31,
    .Data4 = [8]u8{ 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba },
};
const MF_MT_AUDIO_BITS_PER_SAMPLE = windows.GUID{
    .Data1 = 0xf2deb57f,
    .Data2 = 0x40fa,
    .Data3 = 0x4764,
    .Data4 = [8]u8{ 0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69 },
};

const MF_VERSION: u32 = (0x0002 << 16) | 0x0070;
const MFSTARTUP_LITE: u32 = 0x1;
const MF_SOURCE_READER_FIRST_AUDIO_STREAM: u32 = 0xfffffffd;
const MF_SOURCE_READERF_ENDOFSTREAM: u32 = 0x2;

extern "mfplat" fn MFStartup(version: u32, flags: u32) callconv(.c) HRESULT;
extern "mfplat" fn MFShutdown() callconv(.c) HRESULT;
extern "mfplat" fn MFCreateMediaType(pp_type: *?*IMFMediaType) callconv(.c) HRESULT;
extern "mfreadwrite" fn MFCreateSourceReaderFromURL(url: [*:0]const WCHAR, attributes: ?*anyopaque, reader: *?*IMFSourceReader) callconv(.c) HRESULT;

const IMFMediaType = extern struct {
    vtable: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFMediaType) callconv(.c) u32,
        GetItem: *const anyopaque,
        GetItemType: *const anyopaque,
        CompareItem: *const anyopaque,
        Compare: *const anyopaque,
        GetUINT32: *const fn (*IMFMediaType, *const windows.GUID, *u32) callconv(.c) HRESULT,
        GetUINT64: *const anyopaque,
        GetDouble: *const anyopaque,
        GetGUID: *const anyopaque,
        GetStringLength: *const anyopaque,
        GetString: *const anyopaque,
        GetAllocatedString: *const anyopaque,
        GetBlobSize: *const anyopaque,
        GetBlob: *const anyopaque,
        GetAllocatedBlob: *const anyopaque,
        GetUnknown: *const anyopaque,
        SetItem: *const anyopaque,
        DeleteItem: *const anyopaque,
        DeleteAllItems: *const anyopaque,
        SetUINT32: *const anyopaque,
        SetUINT64: *const anyopaque,
        SetDouble: *const anyopaque,
        SetGUID: *const fn (*IMFMediaType, *const windows.GUID, *const windows.GUID) callconv(.c) HRESULT,
    };

    fn release(self: *IMFMediaType) void {
        _ = self.vtable.Release(self);
    }
};

const IMFMediaBuffer = extern struct {
    vtable: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFMediaBuffer) callconv(.c) u32,
        Lock: *const fn (*IMFMediaBuffer, *?[*]u8, ?*u32, *u32) callconv(.c) HRESULT,
        Unlock: *const fn (*IMFMediaBuffer) callconv(.c) HRESULT,
    };

    fn release(self: *IMFMediaBuffer) void {
        _ = self.vtable.Release(self);
    }
};

const IMFSample = extern struct {
    vtable: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFSample) callconv(.c) u32,
        // IMFAttributes base (30 slots); none are called here, only ConvertToContiguousBuffer below is.
        GetItem: *const anyopaque,
        GetItemType: *const anyopaque,
        CompareItem: *const anyopaque,
        Compare: *const anyopaque,
        GetUINT32: *const anyopaque,
        GetUINT64: *const anyopaque,
        GetDouble: *const anyopaque,
        GetGUID: *const anyopaque,
        GetStringLength: *const anyopaque,
        GetString: *const anyopaque,
        GetAllocatedString: *const anyopaque,
        GetBlobSize: *const anyopaque,
        GetBlob: *const anyopaque,
        GetAllocatedBlob: *const anyopaque,
        GetUnknown: *const anyopaque,
        SetItem: *const anyopaque,
        DeleteItem: *const anyopaque,
        DeleteAllItems: *const anyopaque,
        SetUINT32: *const anyopaque,
        SetUINT64: *const anyopaque,
        SetDouble: *const anyopaque,
        SetGUID: *const anyopaque,
        SetString: *const anyopaque,
        SetBlob: *const anyopaque,
        SetUnknown: *const anyopaque,
        LockStore: *const anyopaque,
        UnlockStore: *const anyopaque,
        GetCount: *const anyopaque,
        GetItemByIndex: *const anyopaque,
        CopyAllItems: *const anyopaque,
        GetSampleFlags: *const anyopaque,
        SetSampleFlags: *const anyopaque,
        GetSampleTime: *const anyopaque,
        SetSampleTime: *const anyopaque,
        GetSampleDuration: *const anyopaque,
        SetSampleDuration: *const anyopaque,
        GetBufferCount: *const anyopaque,
        GetBufferByIndex: *const anyopaque,
        ConvertToContiguousBuffer: *const fn (*IMFSample, *?*IMFMediaBuffer) callconv(.c) HRESULT,
    };

    fn release(self: *IMFSample) void {
        _ = self.vtable.Release(self);
    }
};

const IMFSourceReader = extern struct {
    vtable: *const Vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IMFSourceReader) callconv(.c) u32,
        GetStreamSelection: *const anyopaque,
        SetStreamSelection: *const anyopaque,
        GetNativeMediaType: *const anyopaque,
        GetCurrentMediaType: *const fn (*IMFSourceReader, u32, *?*IMFMediaType) callconv(.c) HRESULT,
        SetCurrentMediaType: *const fn (*IMFSourceReader, u32, ?*u32, *IMFMediaType) callconv(.c) HRESULT,
        SetCurrentPosition: *const anyopaque,
        ReadSample: *const fn (*IMFSourceReader, u32, u32, ?*u32, ?*u32, ?*i64, *?*IMFSample) callconv(.c) HRESULT,
    };

    fn release(self: *IMFSourceReader) void {
        _ = self.vtable.Release(self);
    }
};

const DecodedPcm = struct {
    data: []u8,
    channels: u16,
    samples_per_sec: u32,
    bits_per_sample: u16,

    fn deinit(self: *const DecodedPcm, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

fn decodeToPcm(allocator: std.mem.Allocator, path_w: [*:0]const WCHAR) !DecodedPcm {
    var reader_opt: ?*IMFSourceReader = null;
    if (MFCreateSourceReaderFromURL(path_w, null, &reader_opt) < 0 or reader_opt == null) {
        return error.CreateSourceReaderFailed;
    }
    const reader = reader_opt.?;
    defer reader.release();

    var pcm_type_opt: ?*IMFMediaType = null;
    if (MFCreateMediaType(&pcm_type_opt) < 0 or pcm_type_opt == null) return error.CreateMediaTypeFailed;
    const pcm_type = pcm_type_opt.?;
    defer pcm_type.release();

    if (pcm_type.vtable.SetGUID(pcm_type, &MF_MT_MAJOR_TYPE, &MFMediaType_Audio) < 0) return error.SetMediaTypeFailed;
    if (pcm_type.vtable.SetGUID(pcm_type, &MF_MT_SUBTYPE, &MFAudioFormat_PCM) < 0) return error.SetMediaTypeFailed;

    // Triggers Media Foundation's built-in MP3 decoder transform automatically.
    if (reader.vtable.SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, null, pcm_type) < 0) {
        return error.SetCurrentMediaTypeFailed;
    }

    var actual_type_opt: ?*IMFMediaType = null;
    if (reader.vtable.GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, &actual_type_opt) < 0 or actual_type_opt == null) {
        return error.GetCurrentMediaTypeFailed;
    }
    const actual_type = actual_type_opt.?;
    defer actual_type.release();

    var channels: u32 = 0;
    var samples_per_sec: u32 = 0;
    var bits_per_sample: u32 = 0;
    _ = actual_type.vtable.GetUINT32(actual_type, &MF_MT_AUDIO_NUM_CHANNELS, &channels);
    _ = actual_type.vtable.GetUINT32(actual_type, &MF_MT_AUDIO_SAMPLES_PER_SECOND, &samples_per_sec);
    _ = actual_type.vtable.GetUINT32(actual_type, &MF_MT_AUDIO_BITS_PER_SAMPLE, &bits_per_sample);
    if (channels == 0 or samples_per_sec == 0 or bits_per_sample == 0) return error.UnknownAudioFormat;

    var pcm_data: std.ArrayList(u8) = .empty;
    errdefer pcm_data.deinit(allocator);

    while (true) {
        var sample_flags: u32 = 0;
        var sample_opt: ?*IMFSample = null;
        const hr = reader.vtable.ReadSample(reader, MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, null, &sample_flags, null, &sample_opt);
        if (hr < 0) return error.ReadSampleFailed;
        if (sample_flags & MF_SOURCE_READERF_ENDOFSTREAM != 0) break;
        const sample = sample_opt orelse continue;
        defer sample.release();

        var buffer_opt: ?*IMFMediaBuffer = null;
        if (sample.vtable.ConvertToContiguousBuffer(sample, &buffer_opt) < 0 or buffer_opt == null) {
            return error.ConvertBufferFailed;
        }
        const buffer = buffer_opt.?;
        defer buffer.release();

        var data_ptr: ?[*]u8 = null;
        var current_len: u32 = 0;
        if (buffer.vtable.Lock(buffer, &data_ptr, null, &current_len) < 0 or data_ptr == null) {
            return error.LockBufferFailed;
        }
        try pcm_data.appendSlice(allocator, data_ptr.?[0..current_len]);
        _ = buffer.vtable.Unlock(buffer);
    }

    return .{
        .data = try pcm_data.toOwnedSlice(allocator),
        .channels = @intCast(channels),
        .samples_per_sec = samples_per_sec,
        .bits_per_sample = @intCast(bits_per_sample),
    };
}

const WAVEFORMATEX = extern struct {
    wFormatTag: u16 = 1, // WAVE_FORMAT_PCM
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16 = 0,
};

const WAVEHDR = extern struct {
    lpData: [*]u8,
    dwBufferLength: u32,
    dwBytesRecorded: u32 = 0,
    dwUser: usize = 0,
    dwFlags: u32 = 0,
    dwLoops: u32 = 0,
    lpNext: ?*WAVEHDR = null,
    reserved: usize = 0,
};

const WAVE_MAPPER: u32 = 0xFFFFFFFF;
const CALLBACK_EVENT: u32 = 0x00050000;

extern "winmm" fn waveOutOpen(phwo: *?HANDLE, device_id: u32, format: *const WAVEFORMATEX, callback: usize, instance: usize, flags: u32) callconv(.c) u32;
extern "winmm" fn waveOutPrepareHeader(hwo: HANDLE, header: *WAVEHDR, size: u32) callconv(.c) u32;
extern "winmm" fn waveOutUnprepareHeader(hwo: HANDLE, header: *WAVEHDR, size: u32) callconv(.c) u32;
extern "winmm" fn waveOutWrite(hwo: HANDLE, header: *WAVEHDR, size: u32) callconv(.c) u32;
extern "winmm" fn waveOutClose(hwo: HANDLE) callconv(.c) u32;
extern "winmm" fn waveOutSetVolume(hwo: ?HANDLE, volume: u32) callconv(.c) u32;

extern "kernel32" fn CreateEventA(attrs: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u8) callconv(.c) ?HANDLE;
extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.c) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, timeout_ms: DWORD) callconv(.c) DWORD;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.c) BOOL;

const INFINITE: u32 = 0xFFFFFFFF;

fn packVolume(volume_percent: u8) u32 {
    const clamped = @min(volume_percent, 100);
    const level: u32 = @as(u32, clamped) * 0xFFFF / 100;
    return (level << 16) | level;
}

/// Decodes and plays `path` (WAV/MP3), blocking until done; public so config.exe's "Test Sound" button can call it directly, bypassing the worker queue below.
pub fn playBlocking(allocator: std.mem.Allocator, path: []const u8, volume_percent: u8) !void {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(path_w);

    // MF state is per-process, not shared with the main app's process - config.exe's direct callers need this too.
    if (MFStartup(MF_VERSION, MFSTARTUP_LITE) < 0) return error.MFStartupFailed;
    defer _ = MFShutdown();

    const pcm = try decodeToPcm(allocator, path_w);
    defer pcm.deinit(allocator);

    const format = WAVEFORMATEX{
        .nChannels = pcm.channels,
        .nSamplesPerSec = pcm.samples_per_sec,
        .nBlockAlign = pcm.channels * (pcm.bits_per_sample / 8),
        .nAvgBytesPerSec = pcm.samples_per_sec * @as(u32, pcm.channels) * (pcm.bits_per_sample / 8),
        .wBitsPerSample = pcm.bits_per_sample,
    };

    const event = CreateEventA(null, 1, 0, null) orelse return error.CreateEventFailed;
    defer _ = CloseHandle(event);

    var hwo_opt: ?HANDLE = null;
    if (waveOutOpen(&hwo_opt, WAVE_MAPPER, &format, @intFromPtr(event), 0, CALLBACK_EVENT) != 0 or hwo_opt == null) {
        return error.WaveOutOpenFailed;
    }
    const hwo = hwo_opt.?;
    defer _ = waveOutClose(hwo);

    // waveOutOpen signals `event` once on its own (WOM_OPEN); clear that before waiting on WOM_DONE.
    _ = ResetEvent(event);
    _ = waveOutSetVolume(hwo, packVolume(volume_percent));

    var header = WAVEHDR{ .lpData = pcm.data.ptr, .dwBufferLength = @intCast(pcm.data.len) };
    if (waveOutPrepareHeader(hwo, &header, @sizeOf(WAVEHDR)) != 0) return error.WaveOutPrepareFailed;
    defer _ = waveOutUnprepareHeader(hwo, &header, @sizeOf(WAVEHDR));

    if (waveOutWrite(hwo, &header, @sizeOf(WAVEHDR)) != 0) return error.WaveOutWriteFailed;
    _ = WaitForSingleObject(event, INFINITE);
}

// Mirrors tts.zig's lazy worker/queue skeleton, so overlapping alerts play in full instead of cutting each other off.
const Command = struct {
    // page_allocator-owned; the worker frees it after playing (or shutdown() frees it if still queued).
    path: []const u8,
    volume_percent: u8,
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
        self.mutex.lock(g_io) catch |err| {
            slog.warn("Failed to lock command queue mutex: {}", .{err});
            return null;
        };
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

/// Must be called once before any sound function is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

const WORKER_POLL_MS: u64 = 50;

fn workerMain() void {
    if (MFStartup(MF_VERSION, MFSTARTUP_LITE) < 0) {
        slog.warn("Sound worker unavailable (MFStartup failed)", .{});
        g_worker_dead.store(true, .release);
        return;
    }
    defer _ = MFShutdown();
    slog.info("Sound worker initialized", .{});

    while (!g_should_exit.load(.acquire)) {
        const cmd = g_queue.pop() orelse {
            std.Io.sleep(g_io, .fromMilliseconds(@intCast(WORKER_POLL_MS)), .awake) catch |err| {
                slog.debug("Worker sleep failed: {}", .{err});
            };
            continue;
        };
        defer std.heap.page_allocator.free(cmd.path);
        playBlocking(std.heap.page_allocator, cmd.path, cmd.volume_percent) catch |err| {
            slog.warn("Failed to play sound alert '{s}': {}", .{ cmd.path, err });
        };
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
        slog.warn("Failed to start sound worker thread: {}", .{err});
        g_thread_failed = true;
        return false;
    };
    return true;
}

/// Queue a sound alert; returns immediately and plays in full FIFO order on the lazily-started worker thread.
pub fn playAlert(path: []const u8, volume_percent: u8) void {
    if (!ensureWorker()) return;
    const copy = std.heap.page_allocator.dupe(u8, path) catch |err| {
        slog.warn("Failed to queue sound alert: {}", .{err});
        return;
    };
    g_queue.push(.{ .path = copy, .volume_percent = volume_percent }) catch |err| {
        slog.warn("Failed to queue sound alert: {}", .{err});
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
        std.heap.page_allocator.free(cmd.path);
    }
}
