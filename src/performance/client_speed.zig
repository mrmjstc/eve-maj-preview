//! Sets each EVE client's CPU priority and efficiency mode as Client Speed asks, and puts them back on exit.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config = @import("../config.zig");
const scout = @import("../clients/scout.zig");
const plan = @import("plan.zig");
const log = @import("../log.zig");

const Speed = plan.Speed;
const slog = log.Scoped("client_speed");

/// Processes let go of in one tick; any more wait for the next.
const MAX_FORGOTTEN_PER_TICK = 64;

/// App owns it, so it outlives a Save or profile switch; main thread only.
pub const ClientSpeed = struct {
    allocator: std.mem.Allocator,
    /// Each client process opened, by ID; its handle stays open while it's a client, so the ID can't be reused meanwhile.
    processes: std.AutoHashMapUnmanaged(win32.DWORD, Process) = .empty,
    /// Processes Windows wouldn't let us change, so each is logged once and not tried again.
    refused: std.AutoHashMapUnmanaged(win32.DWORD, void) = .empty,
    /// Kept while focus is outside EVE, so the client you'll likely return to stays at full speed.
    focused_process_id: ?win32.DWORD = null,
    /// When focus last moved to another client; background clients are slowed only SETTLE_MS after it.
    focused_at: win32.Ticks = .{},

    const Process = struct {
        handle: win32.HANDLE,
        /// Null until first set.
        applied: ?Speed = null,
    };

    pub fn init(allocator: std.mem.Allocator) ClientSpeed {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ClientSpeed) void {
        self.restoreAll();
        var processes = self.processes.valueIterator();
        while (processes.next()) |process| _ = win32.CloseHandle(process.handle);
        self.processes.deinit(self.allocator);
        self.refused.deinit(self.allocator);
    }

    /// Every client changed back to Windows' default; also for an exit that skips deinit.
    pub fn restoreAll(self: *ClientSpeed) void {
        var processes = self.processes.valueIterator();
        while (processes.next()) |process| {
            const applied = process.applied orelse continue;
            if (std.meta.eql(applied, Speed{})) continue;
            // Teardown: a client that won't change back keeps its speed until it closes.
            apply(process.handle, .{}) catch continue;
            process.applied = .{};
        }
    }

    /// Before `hwnd` comes forward and when it takes focus, so a slowed client draws its first frame at full speed.
    pub fn focusClient(self: *ClientSpeed, settings: *const config.ClientSpeedConfig, windows: []const scout.EveWindow, hwnd: win32.HWND, now: win32.Ticks) void {
        const window = for (windows) |candidate| {
            if (candidate.hwnd == hwnd) break candidate;
        } else return;
        if (!window.is_eve_client) return;
        if (self.focused_process_id == window.process_id) return;
        self.focused_process_id = window.process_id;
        self.focused_at = now;
        const options = optionsOf(settings);
        self.setSpeed(options, window.process_id, plan.wantedSpeed(options, .focused), false);
    }

    /// Each tick, after the scan: every client to the speed its role wants, and processes no longer clients put back and let go.
    pub fn update(self: *ClientSpeed, settings: *const config.ClientSpeedConfig, profile: *const config.Config, windows: []const scout.EveWindow, now: win32.Ticks) void {
        const options = optionsOf(settings);
        if (!options.isAnyOn() and self.processes.count() == 0 and self.refused.count() == 0) return;
        self.forgetGone(windows);
        const is_settling = now.elapsedSince(self.focused_at) < plan.SETTLE_MS;
        for (windows) |window| {
            if (!window.is_eve_client) continue;
            const role: plan.Role = if (self.focused_process_id == window.process_id)
                .focused
            else if (profile.keepsFullSpeed(window.character_name))
                .kept_at_full_speed
            else
                .background;
            self.setSpeed(options, window.process_id, plan.wantedSpeed(options, role), is_settling);
        }
        if (options.isAnyOn()) self.reassertFocused();
    }

    /// Windows can put a slowed client back to Normal priority as it takes focus, undoing the raise.
    fn reassertFocused(self: *ClientSpeed) void {
        const process_id = self.focused_process_id orelse return;
        const process = self.processes.getPtr(process_id) orelse return;
        const applied = process.applied orelse return;
        if (win32.GetPriorityClass(process.handle) == priorityClass(applied.priority)) return;
        apply(process.handle, applied) catch |err| {
            self.refuse(process_id, err);
            return;
        };
        slog.debug("Client pid {d}'s priority was changed outside the app, so it's set to {s} again", .{ process_id, @tagName(applied.priority) });
    }

    fn setSpeed(self: *ClientSpeed, options: plan.Options, process_id: win32.DWORD, wanted: Speed, is_settling: bool) void {
        if (self.refused.contains(process_id)) return;
        const existing = self.processes.getPtr(process_id);
        const applied = if (existing) |process| process.applied else null;
        const next = plan.nextSpeed(options, applied, wanted, is_settling) orelse return;
        const process = existing orelse self.open(process_id) orelse return;
        apply(process.handle, next) catch |err| {
            self.refuse(process_id, err);
            return;
        };
        process.applied = next;
        slog.debug("Client pid {d} now at {s} priority, {s} throttling", .{ process_id, @tagName(next.priority), @tagName(next.throttle) });
    }

    fn open(self: *ClientSpeed, process_id: win32.DWORD) ?*Process {
        const handle = win32.OpenProcess(win32.PROCESS_SET_INFORMATION | win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, process_id) orelse {
            self.refuse(process_id, error.OpenProcessFailed);
            return null;
        };
        const entry = self.processes.getOrPut(self.allocator, process_id) catch |err| {
            _ = win32.CloseHandle(handle);
            slog.warn("Failed to track client pid {d} for Client Speed, leaving it as it is: {}", .{ process_id, err });
            return null;
        };
        entry.value_ptr.* = .{ .handle = handle };
        return entry.value_ptr;
    }

    /// Logs why and lets go of the process, which is left as it is and not tried again.
    fn refuse(self: *ClientSpeed, process_id: win32.DWORD, err: anyerror) void {
        const last_error = win32.GetLastError();
        slog.warn("Failed to change the speed of client pid {d} (Windows error {d}), leaving it as it is; if EVE runs as administrator, this app must too: {}", .{ process_id, last_error, err });
        if (self.processes.fetchRemove(process_id)) |removed| _ = win32.CloseHandle(removed.value.handle);
        self.refused.put(self.allocator, process_id, {}) catch |put_err| {
            slog.warn("Failed to remember that client pid {d} can't be changed, so it's tried again: {}", .{ process_id, put_err });
        };
    }

    /// Puts back a process that's still running but no longer a client, e.g. once a window filter stops matching it.
    fn forgetGone(self: *ClientSpeed, windows: []const scout.EveWindow) void {
        var gone: [MAX_FORGOTTEN_PER_TICK]win32.DWORD = undefined;
        var gone_count: usize = 0;
        var processes = self.processes.iterator();
        while (processes.next()) |entry| {
            if (gone_count == gone.len) break;
            if (isClientProcess(windows, entry.key_ptr.*)) continue;
            gone[gone_count] = entry.key_ptr.*;
            gone_count += 1;
        }
        for (gone[0..gone_count]) |process_id| {
            const removed = self.processes.fetchRemove(process_id) orelse continue;
            defer _ = win32.CloseHandle(removed.value.handle);
            const applied = removed.value.applied orelse continue;
            if (std.meta.eql(applied, Speed{})) continue;
            apply(removed.value.handle, .{}) catch |err| {
                slog.debug("Left pid {d} as it was, as it has likely closed: {}", .{ process_id, err });
            };
        }

        gone_count = 0;
        var refused = self.refused.keyIterator();
        while (refused.next()) |process_id| {
            if (gone_count == gone.len) break;
            if (isClientProcess(windows, process_id.*)) continue;
            gone[gone_count] = process_id.*;
            gone_count += 1;
        }
        for (gone[0..gone_count]) |process_id| _ = self.refused.remove(process_id);
    }
};

fn optionsOf(settings: *const config.ClientSpeedConfig) plan.Options {
    return .{
        .raises_focused = settings.raiseFocusedClient,
        .lowers_background = settings.lowerBackgroundClients,
        .throttles_background = settings.backgroundEfficiencyMode,
    };
}

fn isClientProcess(windows: []const scout.EveWindow, process_id: win32.DWORD) bool {
    for (windows) |window| {
        if (window.is_eve_client and window.process_id == process_id) return true;
    }
    return false;
}

fn apply(handle: win32.HANDLE, speed: Speed) !void {
    if (!win32.toBool(win32.SetPriorityClass(handle, priorityClass(speed.priority)))) return error.SetPriorityFailed;
    const state = throttlingState(speed.throttle);
    if (!win32.toBool(win32.SetProcessInformation(handle, win32.PROCESS_POWER_THROTTLING_CLASS, &state, @sizeOf(win32.PROCESS_POWER_THROTTLING_STATE)))) return error.SetThrottlingFailed;
}

fn priorityClass(priority: plan.Priority) win32.DWORD {
    return switch (priority) {
        .below_normal => win32.BELOW_NORMAL_PRIORITY_CLASS,
        .normal => win32.NORMAL_PRIORITY_CLASS,
        .above_normal => win32.ABOVE_NORMAL_PRIORITY_CLASS,
    };
}

fn throttlingState(throttle: plan.Throttle) win32.PROCESS_POWER_THROTTLING_STATE {
    const execution_speed = win32.PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    return switch (throttle) {
        .default => .{},
        .efficient => .{ .ControlMask = execution_speed, .StateMask = execution_speed },
        .never => .{ .ControlMask = execution_speed },
    };
}
