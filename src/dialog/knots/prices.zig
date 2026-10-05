//! Fetching Jita ore prices on a thread of its own, since the requests would stall the window; the result comes back to the main thread as a command.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const files = @import("../../config/files.zig");
const esi_prices = @import("../tools/esi_prices.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

/// Every ore the catalogue lists, which the fetch asks for.
pub const NAMES = blk: {
    var names: [config.DEFAULT_ORE_TABLE.len][]const u8 = undefined;
    for (config.DEFAULT_ORE_TABLE, &names) |entry, *name| name.* = entry.name;
    break :blk names;
};

/// Sent to the main thread as WM_KNOTS_COMMAND's lParam.
pub const Fetched = struct {
    arena: std.heap.ArenaAllocator,
    /// Borrows from `arena`; empty when the fetch failed.
    prices: []const esi_prices.Price,
    failed: bool,

    pub fn deinit(self: *Fetched) void {
        var arena = self.arena;
        g_allocator.destroy(self);
        arena.deinit();
    }
};

var g_allocator: std.mem.Allocator = undefined;
/// Set while a fetch runs, so a second click doesn't start another. Main thread sets it; the fetch's thread clears it.
var g_busy: std.atomic.Value(bool) = .init(false);

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

pub fn isFetching() bool {
    return g_busy.load(.acquire);
}

/// `timer` receives `command` with the result; returns false if a fetch is already running or couldn't start.
pub fn fetch(timer: win32.HWND, command: usize) bool {
    if (g_busy.swap(true, .acq_rel)) return false;
    const thread = std.Thread.spawn(.{}, fetchThread, .{ timer, command }) catch |err| {
        slog.err("Failed to fetch ore prices: {}", .{err});
        g_busy.store(false, .release);
        return false;
    };
    thread.detach();
    return true;
}

/// The fetch's thread; touches nothing of the main thread's but the allocator and the posted message.
fn fetchThread(timer: win32.HWND, command: usize) void {
    defer g_busy.store(false, .release);
    const fetched = g_allocator.create(Fetched) catch |err| {
        slog.err("Failed to fetch ore prices: {}", .{err});
        return;
    };
    fetched.* = .{ .arena = .init(g_allocator), .prices = &.{}, .failed = false };
    if (esi_prices.fetchOrePrices(g_allocator, fetched.arena.allocator(), files.g_io, &NAMES)) |prices| {
        fetched.prices = prices.items;
    } else |err| {
        slog.err("Failed to fetch ore prices: {}", .{err});
        fetched.failed = true;
    }
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_KNOTS_COMMAND, command, @bitCast(@intFromPtr(fetched))))) {
        slog.err("Failed to pass on the fetched ore prices: error {d}", .{win32.GetLastError()});
        fetched.deinit();
    }
}
