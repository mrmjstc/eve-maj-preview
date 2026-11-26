//! Fetching Jita ore prices on a thread of its own, since the requests would stall the window; the result comes back to the main thread as a command.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const ores = @import("../../activity/ores.zig");
const esi_prices = @import("../tools/esi_prices.zig");
const detached = @import("../../util/detached.zig");
const handoff = @import("../../util/handoff.zig");
const messages = @import("../../messages.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

/// Every ore the catalogue lists, which the fetch asks for.
pub const NAMES = blk: {
    var names: [ores.CATALOG.len][]const u8 = undefined;
    for (ores.CATALOG, &names) |entry, *name| name.* = entry.name;
    break :blk names;
};

/// Waits in `takeAll` until the main thread takes it.
pub const Fetched = struct {
    /// The Prices' allocator, which the Fetched itself came from.
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Borrows from `arena`; empty when the fetch failed.
    prices: []const esi_prices.Price,
    has_failed: bool,
    /// The next result, linked by handoff.Stack.
    next: ?*Fetched = null,

    pub fn deinit(self: *Fetched) void {
        var arena = self.arena;
        self.allocator.destroy(self);
        arena.deinit();
    }
};

pub const Prices = struct {
    /// Read by the fetch's thread too.
    allocator: std.mem.Allocator,
    /// Set while a fetch runs, so a second click doesn't start another; the main thread sets it and the fetch's thread clears it.
    is_busy: std.atomic.Value(bool) = .init(false),
    /// Pushed by the fetch's thread, taken by the main thread.
    results: handoff.Stack(Fetched) = .{},

    pub fn init(allocator: std.mem.Allocator) Prices {
        return .{ .allocator = allocator };
    }

    /// Main thread: the fetches finished since the last call, oldest first through `next`; the caller deinits each.
    pub fn takeAll(self: *Prices) ?*Fetched {
        return self.results.takeAll();
    }

    pub fn isFetching(self: *const Prices) bool {
        return self.is_busy.load(.acquire);
    }

    /// `timer_hwnd` receives `command` with the result; returns false if a fetch is already running or couldn't start.
    pub fn fetch(self: *Prices, io: std.Io, timer_hwnd: win32.HWND, command: usize) bool {
        if (self.is_busy.swap(true, .acq_rel)) return false;
        detached.spawn(fetchThread, .{ self, io, timer_hwnd, command }) catch |err| {
            slog.err("Failed to fetch ore prices: {}", .{err});
            self.is_busy.store(false, .release);
            return false;
        };
        return true;
    }

    /// The fetch's thread; touches nothing of the main thread's but the allocator, the results and the posted message.
    fn fetchThread(self: *Prices, io: std.Io, timer_hwnd: win32.HWND, command: usize) void {
        defer self.is_busy.store(false, .release);
        const fetched = self.allocator.create(Fetched) catch |err| {
            slog.err("Failed to fetch ore prices: {}", .{err});
            return;
        };
        fetched.* = .{ .allocator = self.allocator, .arena = .init(self.allocator), .prices = &.{}, .has_failed = false };
        if (esi_prices.fetchOrePrices(self.allocator, fetched.arena.allocator(), io, &NAMES)) |prices| {
            fetched.prices = prices.items;
        } else |err| {
            slog.err("Failed to fetch ore prices: {}", .{err});
            fetched.has_failed = true;
        }
        self.results.push(fetched);
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, command, 0))) {
            slog.err("Failed to pass on the fetched ore prices, they wait for the next fetch: error {d}", .{win32.GetLastError()});
        }
    }
};
