const std = @import("std");
const win32 = @import("win32.zig");
const scout = @import("scout.zig");
const log = @import("log.zig");
const slog = log.scoped("resource_tracker");

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

/// Instance names look like "pid_1234_luid_0x0_0xABCD_phys_0", one per process per physical adapter.
const VRAM_COUNTER_PATH = "\\GPU Process Memory(*)\\Dedicated Usage";
const PID_TOKEN = "pid_";

/// Main-thread only - no locking, unlike activity_tracker.zig's trackers which are fed cross-thread.
pub const ResourceTracker = struct {
    allocator: std.mem.Allocator,
    cpu_samples: std.AutoHashMap(win32.DWORD, CpuSample),
    stats: std.AutoHashMap(win32.DWORD, ProcessResourceStats),
    logical_processors: f32,
    pdh_query: win32.PDH_HQUERY = null,
    pdh_counter: win32.PDH_HCOUNTER = null,
    vram_available: bool = false,
    pdh_buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ResourceTracker {
        var self = ResourceTracker{
            .allocator = allocator,
            .cpu_samples = std.AutoHashMap(win32.DWORD, CpuSample).init(allocator),
            .stats = std.AutoHashMap(win32.DWORD, ProcessResourceStats).init(allocator),
            .logical_processors = @floatFromInt(@max(win32.GetActiveProcessorCount(win32.ALL_PROCESSOR_GROUPS), 1)),
        };
        self.initVram();
        return self;
    }

    fn initVram(self: *ResourceTracker) void {
        var query: win32.PDH_HQUERY = null;
        if (win32.PdhOpenQueryA(null, 0, &query) != 0) {
            slog.warn("PdhOpenQueryA failed; VRAM overlay disabled", .{});
            return;
        }
        var counter: win32.PDH_HCOUNTER = null;
        if (win32.PdhAddEnglishCounterA(query, VRAM_COUNTER_PATH, 0, &counter) != 0) {
            slog.warn("PdhAddEnglishCounterA failed for '{s}'; VRAM overlay disabled", .{VRAM_COUNTER_PATH});
            _ = win32.PdhCloseQuery(query);
            return;
        }
        self.pdh_query = query;
        self.pdh_counter = counter;
        self.vram_available = true;
    }

    pub fn deinit(self: *ResourceTracker) void {
        if (self.pdh_query) |q| _ = win32.PdhCloseQuery(q);
        self.pdh_buffer.deinit(self.allocator);
        self.cpu_samples.deinit();
        self.stats.deinit();
    }

    pub fn getStats(self: *ResourceTracker, process_id: win32.DWORD) ProcessResourceStats {
        return self.stats.get(process_id) orelse .{};
    }

    /// Cheap enough to call on a throttled interval (caller decides cadence) rather than every timer tick.
    pub fn sampleAll(self: *ResourceTracker, windows: []const scout.EveWindow, now_ms: i64) void {
        for (windows) |w| {
            if (w.process_id == 0) continue;
            self.sampleCpuAndRam(w.process_id, now_ms);
        }
        if (self.vram_available) {
            self.pollVram(windows) catch |err| {
                slog.warn("VRAM poll failed: {}", .{err});
            };
        }
        self.pruneStale(windows);
    }

    fn sampleCpuAndRam(self: *ResourceTracker, pid: win32.DWORD, now_ms: i64) void {
        const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION | win32.PROCESS_VM_READ, win32.FALSE, pid) orelse return;
        defer _ = win32.CloseHandle(handle);

        const entry = self.stats.getOrPut(pid) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{};

        var creation: win32.FILETIME = undefined;
        var exit_time: win32.FILETIME = undefined;
        var kernel: win32.FILETIME = undefined;
        var user: win32.FILETIME = undefined;
        if (win32.GetProcessTimes(handle, &creation, &exit_time, &kernel, &user) != 0) {
            const cpu_time_ms = (kernel.toU64() + user.toU64()) / 10_000;
            if (self.cpu_samples.get(pid)) |prev| {
                const wall_delta_ms = now_ms - prev.wall_time_ms;
                if (wall_delta_ms > 0 and cpu_time_ms >= prev.cpu_time_ms) {
                    const cpu_delta_ms = cpu_time_ms - prev.cpu_time_ms;
                    const raw = (@as(f64, @floatFromInt(cpu_delta_ms)) / @as(f64, @floatFromInt(wall_delta_ms))) / self.logical_processors * 100.0;
                    entry.value_ptr.cpu_percent = @floatCast(std.math.clamp(raw, 0.0, 100.0));
                }
            }
            self.cpu_samples.put(pid, .{ .cpu_time_ms = cpu_time_ms, .wall_time_ms = now_ms }) catch {};
        }

        var mem_counters: win32.PROCESS_MEMORY_COUNTERS = undefined;
        mem_counters.cb = @sizeOf(win32.PROCESS_MEMORY_COUNTERS);
        if (win32.GetProcessMemoryInfo(handle, &mem_counters, mem_counters.cb) != 0) {
            entry.value_ptr.ram_mb = @as(f32, @floatFromInt(mem_counters.WorkingSetSize)) / (1024.0 * 1024.0);
        }
    }

    /// One wildcard-instance PDH query covers every process; per-pid filtering happens client-side via the "pid_<N>_" prefix.
    fn pollVram(self: *ResourceTracker, windows: []const scout.EveWindow) !void {
        for (windows) |w| {
            if (self.stats.getPtr(w.process_id)) |s| {
                s.vram_mb = 0;
                s.has_vram = false;
            }
        }

        if (win32.PdhCollectQueryData(self.pdh_query) != 0) return;

        var buffer_size: win32.DWORD = 0;
        var item_count: win32.DWORD = 0;
        const size_status = win32.PdhGetFormattedCounterArrayA(self.pdh_counter, win32.PDH_FMT_LARGE, &buffer_size, &item_count, null);
        if (size_status != win32.PDH_MORE_DATA or buffer_size == 0) return;

        try self.pdh_buffer.resize(self.allocator, buffer_size);
        var out_size = buffer_size;
        var out_count: win32.DWORD = 0;
        if (win32.PdhGetFormattedCounterArrayA(self.pdh_counter, win32.PDH_FMT_LARGE, &out_size, &out_count, self.pdh_buffer.items.ptr) != 0) return;

        const items: [*]win32.PDH_FMT_COUNTERVALUE_ITEM_A = @ptrCast(@alignCast(self.pdh_buffer.items.ptr));
        var i: usize = 0;
        while (i < out_count) : (i += 1) {
            const item = items[i];
            if (item.FmtValue.CStatus != 0) continue;
            const name = std.mem.sliceTo(item.szName, 0);
            const pid = parsePidFromInstanceName(name) orelse continue;
            if (self.stats.getPtr(pid)) |s| {
                s.vram_mb += @as(f32, @floatFromInt(item.FmtValue.value.largeValue)) / (1024.0 * 1024.0);
                s.has_vram = true;
            }
        }
    }

    fn pruneStale(self: *ResourceTracker, windows: []const scout.EveWindow) void {
        var stale: std.ArrayList(win32.DWORD) = .empty;
        defer stale.deinit(self.allocator);

        var it = self.stats.keyIterator();
        outer: while (it.next()) |pid_ptr| {
            for (windows) |w| {
                if (w.process_id == pid_ptr.*) continue :outer;
            }
            stale.append(self.allocator, pid_ptr.*) catch continue;
        }
        for (stale.items) |pid| {
            _ = self.stats.remove(pid);
            _ = self.cpu_samples.remove(pid);
        }
    }
};

fn parsePidFromInstanceName(name: []const u8) ?win32.DWORD {
    const pid_pos = std.mem.indexOf(u8, name, PID_TOKEN) orelse return null;
    const digits_start = pid_pos + PID_TOKEN.len;
    var end = digits_start;
    while (end < name.len and name[end] >= '0' and name[end] <= '9') : (end += 1) {}
    if (end == digits_start) return null;
    return std.fmt.parseInt(win32.DWORD, name[digits_start..end], 10) catch null;
}
