//! A URL hotkey that uploads the clipboard's text to a paste site and opens the resulting page.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.scoped("paste_upload");

var g_io: std.Io = undefined;

/// Guards against a double-press spawning two overlapping uploads (and two browser tabs); cleared once the background thread finishes.
var g_upload_in_flight: std.atomic.Value(bool) = .init(false);

/// Must be called once before uploadClipboardAndOpenAsync is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Runs the upload+open on a background thread so the HTTP round-trip doesn't block the main message loop (hotkey handling, thumbnail rendering); a no-op if one is already running.
pub fn uploadClipboardAndOpenAsync(allocator: std.mem.Allocator, url: []const u8) void {
    if (g_upload_in_flight.swap(true, .acq_rel)) {
        slog.info("Clipboard upload already in progress; ignoring", .{});
        return;
    }

    const url_copy = allocator.dupe(u8, url) catch |err| {
        slog.err("Failed to copy URL for clipboard upload: {}", .{err});
        g_upload_in_flight.store(false, .release);
        return;
    };

    if (std.Thread.spawn(.{}, uploadClipboardAndOpenThread, .{ allocator, url_copy })) |thread| {
        thread.detach();
    } else |err| {
        slog.warn("Failed to start clipboard upload thread: {}", .{err});
        allocator.free(url_copy);
        g_upload_in_flight.store(false, .release);
    }
}

/// Percent-encodes `text` as an application/x-www-form-urlencoded value (space becomes '+', per that format's convention rather than plain URI escaping).
fn formUrlEncode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (text) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
            ' ' => try out.append(allocator, '+'),
            else => {
                var hex_buf: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c}) catch unreachable;
                try out.appendSlice(allocator, &hex_buf);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

/// POSTs `body` to `url`; the client's default redirect_behavior already follows the Post/Redirect/Get response paste sites use, so this returns the final landing page's URL (null-terminated for shellOpen; caller frees).
fn postAndFollowRedirect(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![:0]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = g_io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "EVE-Maj-Preview" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch |err| {
        slog.debug("Failed to discard remaining response body: {}", .{err});
    };

    if (response.head.status.class() != .success) {
        slog.warn("Upload to '{s}' returned status {}", .{ url, response.head.status });
    }

    return std.fmt.allocPrintSentinel(allocator, "{f}", .{req.uri}, 0);
}

fn openFallback(url: []const u8) void {
    if (!win32.shellOpenUrl(url)) {
        slog.err("Failed to open URL '{s}'", .{url});
    }
}

/// Uploads clipboard text to url via aDashboard's paste-intake form shape and opens the resulting page, falling back to opening the plain url if there's no clipboard text or the upload fails.
fn uploadClipboardAndOpen(allocator: std.mem.Allocator, url: []const u8) void {
    const clipboard_text = win32.getClipboardText(allocator) orelse {
        slog.warn("Clipboard has no text; opening {s} without uploading", .{url});
        openFallback(url);
        return;
    };
    defer allocator.free(clipboard_text);

    const encoded = formUrlEncode(allocator, clipboard_text) catch |err| {
        slog.err("Failed to encode clipboard content for upload: {}", .{err});
        openFallback(url);
        return;
    };
    defer allocator.free(encoded);

    const body = std.fmt.allocPrint(allocator, "Paste+anything={s}&submit=new", .{encoded}) catch |err| {
        slog.err("Failed to build upload body: {}", .{err});
        openFallback(url);
        return;
    };
    defer allocator.free(body);

    const final_url = postAndFollowRedirect(allocator, url, body) catch |err| {
        slog.err("Failed to upload the clipboard to '{s}': {}", .{ url, err });
        openFallback(url);
        return;
    };
    defer allocator.free(final_url);

    slog.info("Uploaded clipboard, opening {s}", .{final_url});
    if (!win32.setClipboardText(final_url)) {
        slog.warn("Failed to copy paste URL '{s}' to the clipboard", .{final_url});
    }
    if (!win32.shellOpen(final_url.ptr, null)) {
        slog.err("Failed to open uploaded paste URL '{s}'", .{final_url});
    }
}

fn uploadClipboardAndOpenThread(allocator: std.mem.Allocator, url: []const u8) void {
    defer allocator.free(url);
    defer g_upload_in_flight.store(false, .release);
    uploadClipboardAndOpen(allocator, url);
}
