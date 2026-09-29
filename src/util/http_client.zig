//! One-shot HTTP requests over std.http.Client.
const std = @import("std");
const log = @import("../log.zig");

const slog = log.scoped("http_client");

pub const FetchOptions = struct {
    content_type: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

/// Issues a GET (or, with a payload, POST) request and returns the body of a 200 response; caller frees. Logs every failure itself.
pub fn fetch(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, options: FetchOptions) ![]u8 {
    var response_buf: std.Io.Writer.Allocating = .init(allocator);
    // Still safe after toOwnedSlice, which leaves the buffer empty.
    defer response_buf.deinit();

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
        slog.warn("Failed to fetch '{s}': {}", .{ url, err });
        return err;
    };

    if (result.status != .ok) {
        slog.warn("Failed to fetch '{s}': status {}: {s}", .{ url, result.status, response_buf.written() });
        return error.RequestFailed;
    }

    return response_buf.toOwnedSlice() catch |err| {
        slog.warn("Failed to copy the response body from '{s}': {}", .{ url, err });
        return err;
    };
}
