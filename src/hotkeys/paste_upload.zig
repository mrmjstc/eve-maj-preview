//! A URL hotkey that uploads the clipboard's text to a paste site and opens the resulting page.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const http_client = @import("../util/http_client.zig");
const detached = @import("../util/detached.zig");
const log = @import("../log.zig");

const slog = log.Scoped("paste_upload");

/// Most uploads running at once, so a held hotkey can't start a thread per repeat.
const MAX_UPLOADS = 4;

/// Hash of the text each running upload sends, or 0 for a free slot; claimed on the main thread, released by the upload's own thread.
var g_upload_hashes: [MAX_UPLOADS]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

/// Reads the clipboard now, so each press sends what was copied at that moment, then uploads and opens it on a background thread; the same text pressed again while it's still uploading is ignored. Main thread only; `allocator` must be thread-safe.
pub fn uploadClipboardAndOpenAsync(allocator: std.mem.Allocator, url: []const u8) void {
    const text = win32.getClipboardText(allocator) orelse {
        slog.info("Clipboard has no text; opening '{s}' without uploading", .{url});
        openFallback(url);
        return;
    };
    const slot_index = claimSlot(textHash(text)) orelse {
        allocator.free(text);
        return;
    };
    startUpload(allocator, url, text, slot_index) catch |err| {
        slog.err("Failed to start the clipboard upload to '{s}': {}", .{ url, err });
        allocator.free(text);
        releaseSlot(slot_index);
    };
}

/// Never 0, which marks a free slot.
fn textHash(text: []const u8) u64 {
    return @max(std.hash.Wyhash.hash(0, text), 1);
}

/// The slot now holding `hash`, or null (logged) if that text is already uploading or every slot is busy.
fn claimSlot(hash: u64) ?usize {
    for (&g_upload_hashes) |*slot| {
        if (slot.load(.acquire) == hash) {
            slog.info("This clipboard text is already uploading; ignoring", .{});
            return null;
        }
    }
    for (&g_upload_hashes, 0..) |*slot, i| {
        if (slot.cmpxchgStrong(0, hash, .acq_rel, .monotonic) == null) return i;
    }
    slog.warn("Failed to start a clipboard upload: {d} are already running", .{MAX_UPLOADS});
    return null;
}

fn releaseSlot(slot_index: usize) void {
    g_upload_hashes[slot_index].store(0, .release);
}

/// Takes ownership of `text` only on success.
fn startUpload(allocator: std.mem.Allocator, url: []const u8, text: []const u8, slot_index: usize) !void {
    const url_copy = try allocator.dupe(u8, url);
    errdefer allocator.free(url_copy);
    try detached.spawn(uploadThread, .{ allocator, url_copy, text, slot_index });
}

fn uploadThread(allocator: std.mem.Allocator, url: []const u8, text: []const u8, slot_index: usize) void {
    defer releaseSlot(slot_index);
    defer allocator.free(url);
    defer allocator.free(text);
    uploadAndOpen(allocator, url, text);
}

/// Posts `text` in aDashboard's paste-intake form shape and opens the page the site redirects to, falling back to the plain url if the upload fails.
fn uploadAndOpen(allocator: std.mem.Allocator, url: []const u8, text: []const u8) void {
    const encoded = formUrlEncode(allocator, text) catch |err| {
        slog.err("Failed to encode clipboard content for upload: {}", .{err});
        openFallback(url);
        return;
    };
    defer allocator.free(encoded);

    const body = allocator.print("Paste+anything={s}&submit=new", .{encoded}) catch |err| {
        slog.err("Failed to build upload body: {}", .{err});
        openFallback(url);
        return;
    };
    defer allocator.free(body);

    var session = http_client.Session.init() catch {
        openFallback(url);
        return;
    };
    defer session.deinit();

    // Paste sites answer with Post/Redirect/Get, which WinHTTP follows to the new paste's page.
    const response = session.send(allocator, url, .{ .content_type = "application/x-www-form-urlencoded", .payload = body }) catch {
        openFallback(url);
        return;
    };
    defer response.deinit(allocator);
    if (response.status / 100 != 2) {
        slog.warn("Failed to upload to '{s}': status {d}", .{ url, response.status });
        openFallback(url);
        return;
    }

    slog.info("Uploaded clipboard, opening {s}", .{response.url});
    if (!win32.setClipboardText(response.url)) {
        slog.warn("Failed to copy paste URL '{s}' to the clipboard", .{response.url});
    }
    if (!win32.shellOpen(response.url.ptr, null)) {
        slog.err("Failed to open uploaded paste URL '{s}'", .{response.url});
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
                _ = std.mem.print(&hex_buf, "%{X:0>2}", .{c}) catch unreachable;
                try out.appendSlice(allocator, &hex_buf);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn openFallback(url: []const u8) void {
    if (!win32.shellOpenUrl(url)) {
        slog.err("Failed to open URL '{s}'", .{url});
    }
}

test "formUrlEncode keeps unreserved characters and turns spaces into plus" {
    const encoded = try formUrlEncode(std.testing.allocator, "Az09-_.~ x");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("Az09-_.~+x", encoded);
}

test "formUrlEncode percent-encodes reserved characters, newlines and non-ASCII bytes" {
    const encoded = try formUrlEncode(std.testing.allocator, "a&b=c+d\r\n\xe9");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%26b%3Dc%2Bd%0D%0A%E9", encoded);
}

test "formUrlEncode of empty text is empty" {
    const encoded = try formUrlEncode(std.testing.allocator, "");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("", encoded);
}
