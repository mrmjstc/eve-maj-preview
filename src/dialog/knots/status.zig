//! The configuration window's status line: the outcome of the last action, shown in the footer for a few seconds; main thread only.
const std = @import("std");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

const MAX_LENGTH = 160;
const SHOW_MS = 5000;
/// Longer, so an error can be read in full.
const FAILURE_SHOW_MS = 10000;

pub const Kind = enum { info, success, failure };

pub const Status = struct {
    /// Only the first `length` bytes are written.
    buf: [MAX_LENGTH]u8 = undefined,
    length: usize = 0,
    shown_kind: Kind = .info,
    /// Set by show until takeShownMs reports it.
    is_new: bool = false,

    /// `english` translated, with its {placeholders} filled from `args` (see wording.fill); truncated to MAX_LENGTH.
    pub fn show(self: *Status, message_kind: Kind, english: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.buf);
        lang.write(&writer, english, args) catch |err| {
            slog.warn("Failed to fit a status message, showing what fit: {}", .{err});
        };
        self.length = writer.end;
        self.shown_kind = message_kind;
        self.is_new = true;
    }

    /// How long to show the message shown since the last call, if any, before clearing it.
    pub fn takeShownMs(self: *Status) ?u32 {
        if (!self.is_new) return null;
        self.is_new = false;
        if (self.length == 0) return null;
        return switch (self.shown_kind) {
            .info, .success => SHOW_MS,
            .failure => FAILURE_SHOW_MS,
        };
    }

    pub fn clear(self: *Status) void {
        self.length = 0;
    }

    /// Borrows from `self` until the next show or clear.
    pub fn text(self: *const Status) []const u8 {
        return self.buf[0..self.length];
    }

    pub fn kind(self: *const Status) Kind {
        return self.shown_kind;
    }
};
