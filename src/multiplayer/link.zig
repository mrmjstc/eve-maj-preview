//! The connection to the game relay: a thread of its own receives and posts what arrives to the main thread, which sends.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const websocket = @import("../util/websocket.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const WebSocket = websocket.WebSocket;
const slog = log.Scoped("multiplayer");

/// The deployed tools/game-relay Worker, named for Pong, its first game.
const RELAY_HOST = "eve-maj-pong.eve-maj-preview.workers.dev";
const MAX_PATH_LENGTH = 64;
/// Text notices are a few dozen bytes; anything near this is refused as malformed.
const RECEIVE_BUFFER_BYTES = 1024;
const LOCK_NOTICE = "{\"type\":\"lock\"}";

pub const Target = union(enum) {
    host,
    join: wire.Code,
};

/// What the link's thread posts to the main thread, as WM_KNOTS_COMMAND's lParam.
pub const Arrival = struct {
    /// Which open() it belongs to, so one from a link already closed is dropped.
    generation: u32,
    event: union(enum) {
        notice: wire.Notice,
        message: wire.Message,
        /// The connection failed or ended without the relay saying why.
        lost,
    },
};

const Link = struct {
    io: std.Io,
    timer_hwnd: win32.HWND,
    command: usize,
    generation: u32,
    target: Target,
    mutex: std.Io.Mutex = .init,
    /// Guarded by mutex; set by the link's thread once connected and cleared before it closes the socket.
    socket: ?*const WebSocket = null,
    /// Guarded by mutex; set by the main thread to end the link.
    is_cancelled: bool = false,
    /// One for the main thread and one for the link's thread; whichever lets go last frees it.
    refs: std.atomic.Value(u8) = .init(2),

    fn release(self: *Link) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) g_allocator.destroy(self);
    }
};

var g_allocator: std.mem.Allocator = undefined;
/// Main thread only.
var g_link: ?*Link = null;
/// Main thread only.
var g_generation: u32 = 0;

/// Once at startup, since a link's thread can outlive the window that opened it.
pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Closes any link already open; arrivals reach `timer_hwnd` as `command`. Main thread only.
pub fn open(io: std.Io, timer_hwnd: win32.HWND, command: usize, target: Target) !void {
    close();
    g_generation +%= 1;
    const link = try g_allocator.create(Link);
    link.* = .{ .io = io, .timer_hwnd = timer_hwnd, .command = command, .generation = g_generation, .target = target };
    detached.spawn(run, .{link}) catch |err| {
        g_allocator.destroy(link);
        return err;
    };
    g_link = link;
}

/// Main thread only; a no-op once closed.
pub fn close() void {
    const link = g_link orelse return;
    g_link = null;
    link.mutex.lockUncancelable(link.io);
    link.is_cancelled = true;
    if (link.socket) |socket| socket.shutdown();
    link.mutex.unlock(link.io);
    link.release();
}

/// Sends one encoded game message to every other player; dropped while the link is still connecting. Main thread only.
pub fn send(bytes: []const u8) void {
    if (bytes.len > wire.MAX_MESSAGE_BYTES) {
        slog.err("Failed to send a game message of {d} bytes, more than the relay passes on", .{bytes.len});
        return;
    }
    const link = g_link orelse return;
    link.mutex.lockUncancelable(link.io);
    defer link.mutex.unlock(link.io);
    const socket = link.socket orelse return;
    // A failed send also fails the receive, which reports the link as lost.
    socket.send(.binary, bytes) catch return;
}

/// Host only: tells the relay the match has started, so it turns later joiners away. Main thread only.
pub fn lock() void {
    const link = g_link orelse return;
    link.mutex.lockUncancelable(link.io);
    defer link.mutex.unlock(link.io);
    const socket = link.socket orelse return;
    // A failed send also fails the receive, which reports the link as lost.
    socket.send(.text, LOCK_NOTICE) catch return;
}

/// Takes ownership of the posted arrival; null if it belongs to a link since closed. Main thread only.
pub fn take(lParam: win32.LPARAM) ?Arrival {
    if (lParam == 0) return null;
    const posted = win32.lparamToPtr(Arrival, lParam);
    const arrival = posted.*;
    g_allocator.destroy(posted);
    if (g_link == null or arrival.generation != g_generation) return null;
    return arrival;
}

/// The link's thread.
fn run(link: *Link) void {
    defer link.release();
    var path_buf: [MAX_PATH_LENGTH]u8 = undefined;
    // MAX_PATH_LENGTH fits "/join/" and a code with the version query.
    const path = switch (link.target) {
        .host => std.fmt.bufPrint(&path_buf, "/host?v={d}", .{wire.PROTOCOL_VERSION}) catch unreachable,
        .join => |code| std.fmt.bufPrint(&path_buf, "/join/{s}?v={d}", .{ &code, wire.PROTOCOL_VERSION }) catch unreachable,
    };
    var socket = WebSocket.connect(g_allocator, RELAY_HOST, path) catch {
        post(link, .lost);
        return;
    };
    defer socket.deinit();

    link.mutex.lockUncancelable(link.io);
    const is_cancelled = link.is_cancelled;
    if (!is_cancelled) link.socket = &socket;
    link.mutex.unlock(link.io);
    if (is_cancelled) return;
    defer {
        link.mutex.lockUncancelable(link.io);
        link.socket = null;
        link.mutex.unlock(link.io);
    }

    var buf: [RECEIVE_BUFFER_BYTES]u8 = undefined;
    while (true) {
        const received = socket.receive(&buf) catch {
            post(link, .lost);
            return;
        };
        switch (received) {
            .closed => {
                post(link, .lost);
                return;
            },
            .text => |text| {
                const notice = wire.parseNotice(g_allocator, text) catch |err| {
                    slog.warn("Failed to read a notice from the game relay '{s}': {}", .{ text, err });
                    continue;
                };
                post(link, .{ .notice = notice });
            },
            .binary => |bytes| {
                const message = wire.Message.fromFrame(bytes) catch |err| {
                    slog.warn("Failed to read a message from another player: {}", .{err});
                    continue;
                };
                post(link, .{ .message = message });
            },
        }
    }
}

/// The link's thread; a link closed since doesn't post.
fn post(link: *Link, event: @FieldType(Arrival, "event")) void {
    link.mutex.lockUncancelable(link.io);
    const is_cancelled = link.is_cancelled;
    link.mutex.unlock(link.io);
    if (is_cancelled) return;
    const arrival = g_allocator.create(Arrival) catch |err| {
        slog.err("Failed to pass on what the game relay sent: {}", .{err});
        return;
    };
    arrival.* = .{ .generation = link.generation, .event = event };
    if (!win32.toBool(win32.PostMessageA(link.timer_hwnd, win32.WM_KNOTS_COMMAND, link.command, @bitCast(@intFromPtr(arrival))))) {
        slog.err("Failed to pass on what the game relay sent: error {d}", .{win32.GetLastError()});
        g_allocator.destroy(arrival);
    }
}
