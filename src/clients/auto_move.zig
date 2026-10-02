//! Moving clients to their saved window positions, then correcting them if EVE moves its window while it loads.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const actions = @import("actions.zig");
const log = @import("../log.zig");

const slog = log.scoped("auto_move");

const PendingAutoMove = struct {
    hwnd: win32.HWND,
    target: config_mod.Position,
    last_move: win32.Ticks,
    checks_left: u8,
    last_seen: ?win32.POINT = null,
};

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
        actions.moveClientToPosition(config, hwnd, pos);
        self.queue(config, hwnd, pos);
        slog.info("Moved {s} client window to saved position: ({}, {})", .{ character_name, pos.x, pos.y });
    }

    pub fn queue(self: *AutoMoveVerifier, config: *const config_mod.Config, hwnd: win32.HWND, pos: config_mod.Position) void {
        if (config.autoMovePosition.verifyCount == 0) return;
        const entry = PendingAutoMove{
            .hwnd = hwnd,
            .target = actions.clampOntoScreen(pos),
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

    /// Corrects a window once it stops moving between two polls; correcting mid-move would re-grab focus each time and make clients jump.
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

            if (win32.isWindowIconic(entry.hwnd) or win32.isWindowZoomed(entry.hwnd)) {
                _ = self.pending.swapRemove(i);
                continue;
            }

            var rect: win32.RECT = undefined;
            if (!win32.toBool(win32.GetWindowRect(entry.hwnd, &rect))) {
                slog.warn("Failed to read the position of window {*} to verify its auto-move", .{entry.hwnd});
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
                actions.moveClientToPosition(config, entry.hwnd, entry.target);
                _ = self.pending.swapRemove(i);
                continue;
            }

            entry.last_seen = .{ .x = rect.left, .y = rect.top };
            i += 1;
        }
    }
};
