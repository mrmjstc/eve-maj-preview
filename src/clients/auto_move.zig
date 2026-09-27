const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const log = @import("../log.zig");
const slog = log.scoped("auto_move");
const actions = @import("actions.zig");

/// Re-checked after login because EVE can reposition its own window while still loading.
const PendingAutoMove = struct {
    hwnd: win32.HWND,
    target: config_mod.Position,
    last_move: win32.Ticks,
    checks_left: u8,
    last_seen: ?win32.POINT = null,
};

/// Moves clients to their saved window positions, then re-checks them for a while since EVE can reposition its own window while still loading.
pub const AutoMoveVerifier = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(PendingAutoMove) = .empty,

    pub fn init(allocator: std.mem.Allocator) AutoMoveVerifier {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AutoMoveVerifier) void {
        self.pending.deinit(self.allocator);
    }

    /// Callers gate on their own setting; only the per-character exclusion is checked here.
    pub fn moveToSavedPosition(self: *AutoMoveVerifier, config: *const config_mod.Config, hwnd: win32.HWND, character_name: []const u8) void {
        if (config.isExcludedFromAutoMove(character_name)) return;
        const pos = config.getCharacterWindowPosition(character_name) orelse return;
        actions.moveClientToPosition(hwnd, pos);
        self.queue(config, hwnd, pos);
        slog.info("Moved {s} client window to saved position: ({}, {})", .{ character_name, pos.x, pos.y });
    }

    pub fn queue(self: *AutoMoveVerifier, config: *const config_mod.Config, hwnd: win32.HWND, pos: config_mod.Position) void {
        if (config.autoMovePosition.verifyCount == 0) return;
        const entry = PendingAutoMove{
            .hwnd = hwnd,
            .target = actions.clampToVirtualScreen(pos),
            .last_move = win32.Ticks.now(),
            .checks_left = config.autoMovePosition.verifyCount,
        };
        for (self.pending.items) |*existing| {
            if (existing.hwnd == hwnd) {
                existing.* = entry;
                return;
            }
        }
        self.pending.append(self.allocator, entry) catch |err| {
            slog.warn("Failed to queue auto-move verification: {}", .{err});
        };
    }

    /// Polls without touching the window until its position stops changing between two consecutive polls (i.e. EVE is done repositioning it), then corrects it exactly once. Re-applying on every poll while EVE is still mid-move would re-grab focus each time, making clients visibly jump.
    pub fn verify(self: *AutoMoveVerifier, config: *const config_mod.Config) void {
        const now = win32.Ticks.now();
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const entry = &self.pending.items[i];
            if (!win32.isWindow(entry.hwnd)) {
                _ = self.pending.swapRemove(i);
                continue;
            }
            if (now.elapsedSince(entry.last_move) < config.autoMovePosition.verifyIntervalMs) {
                i += 1;
                continue;
            }
            entry.last_move = now;

            var rect: win32.RECT = undefined;
            if (!win32.toBool(win32.GetWindowRect(entry.hwnd, &rect))) {
                slog.warn("Auto-move verification: GetWindowRect failed", .{});
                _ = self.pending.swapRemove(i);
                continue;
            }

            if (rect.left == entry.target.x and rect.top == entry.target.y) {
                _ = self.pending.swapRemove(i);
                continue;
            }

            entry.checks_left -= 1;
            const settled = entry.last_seen != null and entry.last_seen.?.x == rect.left and entry.last_seen.?.y == rect.top;
            if (settled or entry.checks_left == 0) {
                slog.info("Client drifted to ({}, {}) after auto-move, re-applying ({}, {})", .{ rect.left, rect.top, entry.target.x, entry.target.y });
                actions.moveClientToPosition(entry.hwnd, entry.target);
                _ = self.pending.swapRemove(i);
                continue;
            }

            entry.last_seen = .{ .x = rect.left, .y = rect.top };
            i += 1;
        }
    }
};
