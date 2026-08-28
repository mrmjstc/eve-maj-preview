const std = @import("std");
const log = @import("log.zig");
const slog = log.scoped("http_client");

pub const FetchOptions = struct {
    content_type: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

/// Issues a GET (or, with a payload, POST) request and returns the response body (caller frees) if it got a 200, else null.
pub fn fetch(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, options: FetchOptions) ?[]u8 {
    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{
            .user_agent = .{ .override = "EVE-Maj-Preview" },
            .content_type = if (options.content_type) |ct| .{ .override = ct } else .default,
        },
        .extra_headers = options.extra_headers,
        .payload = options.payload,
        .response_writer = &response_buf.writer,
    }) catch |err| {
        slog.warn("HTTP request to {s} failed: {}", .{ url, err });
        response_buf.deinit();
        return null;
    };

    if (result.status != .ok) {
        slog.warn("HTTP request to {s} returned status {}: {s}", .{ url, result.status, response_buf.written() });
        response_buf.deinit();
        return null;
    }

    return response_buf.toOwnedSlice() catch {
        response_buf.deinit();
        return null;
    };
}
