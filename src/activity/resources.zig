//! CPU, RAM and VRAM use of each EVE client's process.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout = @import("../clients/scout.zig");
const log = @import("../log.zig");

const slog = log.Scoped("activity_resources");

/// Instance names look like "pid_1234_luid_0x0_0xABCD_phys_0", one per process per physical adapter.
const VRAM_COUNTER_PATH = "\\GPU Process Memory(*)\\Dedicated Usage";
const PID_TOKEN = "pid_";
const BYTES_PER_MB = 1024.0 * 1024.0;
/// FILETIME counts 100 ns intervals.
const FILETIME_TICKS_PER_MS = 10_000;

pub const ProcessResourceStats = struct {
    cpu_percent: f32 = 0,
    ram_mb: f32 = 0,
    vram_mb: f32 = 0,
    has_vram: bool = false,
};

const CpuSample = struct {
    cpu_time_ms: u64,
    wall_time_ms: i64,
};

/// Main-thread only - no locking, unlike tracker.zig's trackers which are fed cross-thread.
pub const ResourceTracker = struct {
    allocator: std.mem.Allocator,
    cpu_samples: std.AutoHashMap(win32.DWORD, CpuSample),
    stats: std.AutoHashMap(win32.DWORD, ProcessResourceStats),
    logical_processor_count: f32,
    pdh_query: win32.PDH_HQUERY = null,
    pdh_counter: win32.PDH_HCOUNTER = null,
    is_vram_available: bool = false,
    pdh_buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ResourceTracker {
        var self = ResourceTracker{
            .allocator = allocator,
            .cpu_samples = .init(allocator),
            .stats = .init(allocator),
            .logical_processor_count = @floatFromInt(@max(win32.GetActiveProcessorCount(win32.ALL_PROCESSOR_GROUPS), 1)),
        };
        self.initVram();
        return self;
    }

    fn initVram(self: *ResourceTracker) void {
        var query: win32.PDH_HQUERY = null;
        const open_status = win32.PdhOpenQueryA(null, 0, &query);
        if (open_status != 0) {
            slog.warn("Failed to open a PDH query, so VRAM use won't show: 0x{X}", .{@as(u32, @bitCast(open_status))});
            return;
        }
        var counter: win32.PDH_HCOUNTER = null;
        const add_status = win32.PdhAddEnglishCounterA(query, VRAM_COUNTER_PATH, 0, &counter);
        if (add_status != 0) {
            slog.warn("Failed to add PDH counter '{s}', so VRAM use won't show: 0x{X}", .{ VRAM_COUNTER_PATH, @as(u32, @bitCast(add_status)) });
            _ = win32.PdhCloseQuery(query);
            return;
        }
        self.pdh_query = query;
        self.pdh_counter = counter;
        self.is_vram_available = true;
    }

    pub fn deinit(self: *ResourceTracker) void {
        if (self.pdh_query) |q| _ = win32.PdhCloseQuery(q);
        self.pdh_buffer.deinit(self.allocator);
        self.cpu_samples.deinit();
        self.stats.deinit();
    }

    pub fn getStats(self: *const ResourceTracker, process_id: win32.DWORD) ProcessResourceStats {
        return self.stats.get(process_id) orelse .{};
    }

    /// Cheap enough to call on a throttled interval (caller decides cadence) rather than every timer tick.
    pub fn sampleAll(self: *ResourceTracker, windows: []const scout.EveWindow, now_ms: i64) void {
        for (windows) |eve_window| {
            if (eve_window.process_id == 0) continue;
            self.sampleCpuAndRam(eve_window.process_id, now_ms);
        }
        if (self.is_vram_available) {
            self.pollVram(windows) catch |err| {
                slog.warn("Failed to poll VRAM use: {}", .{err});
            };
        }
        self.pruneStale(windows);
    }

    fn sampleCpuAndRam(self: *ResourceTracker, process_id: win32.DWORD, now_ms: i64) void {
        // Not logged: this runs every sample, and fails only for a client that has just closed.
        const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, process_id) orelse return;
        defer _ = win32.CloseHandle(handle);

        const entry = self.stats.getOrPut(process_id) catch |err| {
            slog.warn("Failed to track stats for pid {}: {}", .{ process_id, err });
            return;
        };
        if (!entry.found_existing) entry.value_ptr.* = .{};

        var creation_time: win32.FILETIME = undefined;
        var exit_time: win32.FILETIME = undefined;
        var kernel_time: win32.FILETIME = undefined;
        var user_time: win32.FILETIME = undefined;
        if (win32.toBool(win32.GetProcessTimes(handle, &creation_time, &exit_time, &kernel_time, &user_time))) {
            const cpu_time_ms = (kernel_time.toU64() + user_time.toU64()) / FILETIME_TICKS_PER_MS;
            if (self.cpu_samples.get(process_id)) |previous| {
                const wall_delta_ms = now_ms - previous.wall_time_ms;
                if (wall_delta_ms > 0 and cpu_time_ms >= previous.cpu_time_ms) {
                    const cpu_delta_ms = cpu_time_ms - previous.cpu_time_ms;
                    const raw_percent = (@as(f64, @floatFromInt(cpu_delta_ms)) / @as(f64, @floatFromInt(wall_delta_ms))) / self.logical_processor_count * 100.0;
                    entry.value_ptr.cpu_percent = @floatCast(std.math.clamp(raw_percent, 0.0, 100.0));
                }
            }
            self.cpu_samples.put(process_id, .{ .cpu_time_ms = cpu_time_ms, .wall_time_ms = now_ms }) catch |err| {
                slog.warn("Failed to record CPU sample for pid {}: {}", .{ process_id, err });
            };
        }

        var memory_counters: win32.PROCESS_MEMORY_COUNTERS = undefined;
        memory_counters.cb = @sizeOf(win32.PROCESS_MEMORY_COUNTERS);
        if (win32.toBool(win32.GetProcessMemoryInfo(handle, &memory_counters, memory_counters.cb))) {
            entry.value_ptr.ram_mb = @as(f32, @floatFromInt(memory_counters.WorkingSetSize)) / BYTES_PER_MB;
        }
    }

    /// One wildcard-instance PDH query covers every process; per-pid filtering happens client-side via the "pid_<N>_" prefix.
    fn pollVram(self: *ResourceTracker, windows: []const scout.EveWindow) !void {
        for (windows) |eve_window| {
            if (self.stats.getPtr(eve_window.process_id)) |process_stats| {
                process_stats.vram_mb = 0;
                process_stats.has_vram = false;
            }
        }

        if (win32.PdhCollectQueryData(self.pdh_query) != 0) return error.CollectQueryDataFailed;

        var buffer_size: win32.DWORD = 0;
        var item_count: win32.DWORD = 0;
        const size_status = win32.PdhGetFormattedCounterArrayA(self.pdh_counter, win32.PDH_FMT_LARGE, &buffer_size, &item_count, null);
        if (size_status != win32.PDH_MORE_DATA or buffer_size == 0) return;

        try self.pdh_buffer.resize(self.allocator, buffer_size);
        var out_size = buffer_size;
        var out_count: win32.DWORD = 0;
        if (win32.PdhGetFormattedCounterArrayA(self.pdh_counter, win32.PDH_FMT_LARGE, &out_size, &out_count, self.pdh_buffer.items.ptr) != 0) return error.GetCounterArrayFailed;

        const items: [*]win32.PDH_FMT_COUNTERVALUE_ITEM_A = @ptrCast(@alignCast(self.pdh_buffer.items.ptr));
        for (items[0..out_count]) |item| {
            if (item.FmtValue.CStatus != 0) continue;
            const name = std.mem.sliceTo(item.szName, 0);
            const process_id = parsePidFromInstanceName(name) orelse continue;
            if (self.stats.getPtr(process_id)) |process_stats| {
                process_stats.vram_mb += @as(f32, @floatFromInt(item.FmtValue.value.largeValue)) / BYTES_PER_MB;
                process_stats.has_vram = true;
            }
        }
    }

    fn pruneStale(self: *ResourceTracker, windows: []const scout.EveWindow) void {
        var stale: std.ArrayList(win32.DWORD) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.stats.keyIterator();
        outer: while (it.next()) |process_id_ptr| {
            for (windows) |eve_window| {
                if (eve_window.process_id == process_id_ptr.*) continue :outer;
            }
            stale.append(self.allocator, process_id_ptr.*) catch |err| {
                slog.warn("Failed to queue pid {} for pruning: {}", .{ process_id_ptr.*, err });
                continue;
            };
        }
        for (stale.items) |process_id| {
            _ = self.stats.remove(process_id);
            _ = self.cpu_samples.remove(process_id);
        }
    }
};

/// Null when there's no "pid_<N>", or N overflows a DWORD.
fn parsePidFromInstanceName(name: []const u8) ?win32.DWORD {
    const pid_index = std.mem.find(u8, name, PID_TOKEN) orelse return null;
    const digits_start = pid_index + PID_TOKEN.len;
    var end = digits_start;
    while (end < name.len and std.ascii.isDigit(name[end])) : (end += 1) {}
    if (end == digits_start) return null;
    return std.fmt.parseInt(win32.DWORD, name[digits_start..end], 10) catch null;
}

const testing = std.testing;

test "parsePidFromInstanceName reads the pid and rejects names without one" {
    try testing.expectEqual(@as(?win32.DWORD, 1234), parsePidFromInstanceName("pid_1234_luid_0x0_0xABCD_phys_0"));
    try testing.expectEqual(@as(?win32.DWORD, null), parsePidFromInstanceName("luid_0x0_0xABCD_phys_0"));
    try testing.expectEqual(@as(?win32.DWORD, null), parsePidFromInstanceName("pid__luid_0x0"));
    try testing.expectEqual(@as(?win32.DWORD, null), parsePidFromInstanceName("pid_99999999999_luid_0x0"));
}
