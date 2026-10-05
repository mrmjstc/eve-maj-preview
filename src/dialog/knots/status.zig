//! The configuration window's status line: the outcome of the last action, shown in the footer until the next one; main thread only.
const std = @import("std");

pub const Kind = enum { info, success, failure };

const MAX_LEN = 160;

var g_buf: [MAX_LEN]u8 = undefined;
var g_len: usize = 0;
var g_kind: Kind = .info;

/// Truncated to MAX_LEN.
pub fn show(message_kind: Kind, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.bufPrint(&g_buf, fmt, args) catch g_buf[0..];
    g_len = message.len;
    g_kind = message_kind;
}

pub fn clear() void {
    g_len = 0;
}

/// Borrows from this module until the next show or clear.
pub fn text() []const u8 {
    return g_buf[0..g_len];
}

pub fn kind() Kind {
    return g_kind;
}
