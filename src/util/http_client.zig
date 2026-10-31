//! One-shot HTTP requests over WinHTTP, each bounded by timeouts so none can hang its thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const DWORD = win32.DWORD;
const HINTERNET = win32.HINTERNET;
const slog = log.Scoped("http_client");

const WCHAR = u16;
const USER_AGENT = std.unicode.utf8ToUtf16LeStringLiteral("EVE-Maj-Preview");
/// Applies to each phase (resolve, connect, send, receive) separately.
const TIMEOUT_MS: c_int = 10_000;
const READ_CHUNK_BYTES = 16 * 1024;
const MAX_URL_LENGTH = 2048;
/// A nonzero length with a null pointer makes WinHttpCrackUrl point the component into the input instead of copying it.
const POINT_INTO_INPUT: DWORD = std.math.maxInt(DWORD);

pub const Header = struct {
    /// Borrows from the caller.
    name: []const u8,
    /// Borrows from the caller.
    value: []const u8,
};

pub const FetchOptions = struct {
    /// Borrows from the caller.
    content_type: ?[]const u8 = null,
    /// Sent as a POST body, or a GET without one; borrows from the caller.
    payload: ?[]const u8 = null,
    /// Borrows from the caller.
    extra_headers: []const Header = &.{},
    /// How long the response may take, for a server that works before it answers; null for TIMEOUT_MS.
    receive_timeout_ms: ?c_int = null,
};

pub const Response = struct {
    status: u32,
    /// Owned; freed in deinit.
    body: []u8,
    /// Where the response came from, after any redirects; owned, freed in deinit.
    url: [:0]u8,
    /// From a Retry-After header given in seconds.
    retry_after_seconds: ?u32 = null,

    pub fn deinit(self: *const Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.url);
    }
};

const RequestError = error{
    InvalidUrl,
    ConnectFailed,
    OpenRequestFailed,
    SetTimeoutsFailed,
    SendRequestFailed,
    ReceiveResponseFailed,
    QueryStatusFailed,
    QueryUrlFailed,
    ReadDataFailed,
    TimedOut,
};

/// Safe to share between threads: each request opens its own handles.
pub const Session = struct {
    handle: HINTERNET,

    /// Logs its own failure.
    pub fn init() !Session {
        const handle = win32.WinHttpOpen(USER_AGENT, win32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse {
            slog.warn("Failed to open a WinHTTP session: error {d}", .{win32.GetLastError()});
            return error.OpenSessionFailed;
        };
        errdefer _ = win32.WinHttpCloseHandle(handle);
        if (!win32.toBool(win32.WinHttpSetTimeouts(handle, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS))) {
            slog.warn("Failed to set WinHTTP timeouts: error {d}", .{win32.GetLastError()});
            return error.SetTimeoutsFailed;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Session) void {
        _ = win32.WinHttpCloseHandle(self.handle);
    }

    /// The body of a 200 response, which the caller frees; logs every failure itself.
    pub fn fetch(self: *const Session, allocator: std.mem.Allocator, url: []const u8, options: FetchOptions) ![]u8 {
        const response = try self.send(allocator, url, options);
        allocator.free(response.url);
        if (response.status != 200) {
            slog.warn("Failed to fetch '{s}': status {d}: {s}", .{ url, response.status, response.body });
            allocator.free(response.body);
            return error.RequestFailed;
        }
        return response.body;
    }

    /// Follows redirects and returns whatever status the final response has; logs every failure itself.
    pub fn send(self: *const Session, allocator: std.mem.Allocator, url: []const u8, options: FetchOptions) !Response {
        var win32_error: DWORD = 0;
        return self.sendUnlogged(allocator, url, options, &win32_error) catch |err| {
            if (win32_error != 0) {
                slog.warn("Failed to fetch '{s}' (error {d}): {}", .{ url, win32_error, err });
            } else {
                slog.warn("Failed to fetch '{s}': {}", .{ url, err });
            }
            return err;
        };
    }

    /// Sets `win32_error` when a WinHTTP call fails, since the handle cleanup that follows would overwrite GetLastError.
    fn sendUnlogged(self: *const Session, allocator: std.mem.Allocator, url: []const u8, options: FetchOptions, win32_error: *DWORD) !Response {
        const url_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, url);
        defer allocator.free(url_w);

        var parts: win32.URL_COMPONENTS = .{
            .dwHostNameLength = POINT_INTO_INPUT,
            .dwUrlPathLength = POINT_INTO_INPUT,
            .dwExtraInfoLength = POINT_INTO_INPUT,
        };
        if (!win32.toBool(win32.WinHttpCrackUrl(url_w.ptr, @intCast(url_w.len), 0, &parts))) return winHttpFailure(win32_error, error.InvalidUrl);
        const host_ptr = parts.lpszHostName orelse return error.InvalidUrl;
        const host = try allocator.dupeSentinel(WCHAR, host_ptr[0..parts.dwHostNameLength], 0);
        defer allocator.free(host);

        // The path and query sit next to each other in the URL, so one copy covers both.
        const path: []const WCHAR = if (parts.lpszUrlPath) |path_ptr| path_ptr[0 .. parts.dwUrlPathLength + parts.dwExtraInfoLength] else &.{};
        const object = try allocator.dupeSentinel(WCHAR, if (path.len > 0) path else std.unicode.utf8ToUtf16LeStringLiteral("/"), 0);
        defer allocator.free(object);

        const connection = win32.WinHttpConnect(self.handle, host, parts.nPort, 0) orelse return winHttpFailure(win32_error, error.ConnectFailed);
        defer _ = win32.WinHttpCloseHandle(connection);

        const verb: [*:0]const WCHAR = if (options.payload != null) std.unicode.utf8ToUtf16LeStringLiteral("POST") else std.unicode.utf8ToUtf16LeStringLiteral("GET");
        const flags: DWORD = if (parts.nScheme == win32.INTERNET_SCHEME_HTTPS) win32.WINHTTP_FLAG_SECURE else 0;
        const request = win32.WinHttpOpenRequest(connection, verb, object, null, null, null, flags) orelse return winHttpFailure(win32_error, error.OpenRequestFailed);
        defer _ = win32.WinHttpCloseHandle(request);

        if (options.receive_timeout_ms) |timeout_ms| {
            if (!win32.toBool(win32.WinHttpSetTimeouts(request, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, timeout_ms))) return winHttpFailure(win32_error, error.SetTimeoutsFailed);
        }

        const headers = try headerBlock(allocator, options);
        defer allocator.free(headers);
        const payload = options.payload orelse "";
        const payload_length: DWORD = @intCast(payload.len);
        const headers_ptr: ?[*]const WCHAR = if (headers.len > 0) headers.ptr else null;
        const payload_ptr: ?*const anyopaque = if (payload.len > 0) payload.ptr else null;
        if (!win32.toBool(win32.WinHttpSendRequest(request, headers_ptr, @intCast(headers.len), payload_ptr, payload_length, payload_length, 0))) {
            return winHttpFailure(win32_error, error.SendRequestFailed);
        }
        if (!win32.toBool(win32.WinHttpReceiveResponse(request, null))) return winHttpFailure(win32_error, error.ReceiveResponseFailed);

        var status: DWORD = 0;
        var status_size: DWORD = @sizeOf(DWORD);
        if (!win32.toBool(win32.WinHttpQueryHeaders(request, win32.WINHTTP_QUERY_STATUS_CODE | win32.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null))) {
            return winHttpFailure(win32_error, error.QueryStatusFailed);
        }

        const body = try readBody(allocator, request, win32_error);
        errdefer allocator.free(body);
        const final_url = try finalUrl(allocator, request, win32_error);
        return .{ .status = status, .body = body, .url = final_url, .retry_after_seconds = retryAfterSeconds(request) };
    }
};

/// Records GetLastError before cleanup can overwrite it, and reports a timeout as error.TimedOut.
fn winHttpFailure(win32_error: *DWORD, err: RequestError) RequestError {
    win32_error.* = win32.GetLastError();
    return if (win32_error.* == win32.ERROR_WINHTTP_TIMEOUT) error.TimedOut else err;
}

/// Null when the header is absent or holds a date, which is most replies, so it isn't a failure.
fn retryAfterSeconds(request: HINTERNET) ?u32 {
    var seconds: DWORD = 0;
    var size: DWORD = @sizeOf(DWORD);
    const has_seconds = win32.toBool(win32.WinHttpQueryHeaders(request, win32.WINHTTP_QUERY_RETRY_AFTER | win32.WINHTTP_QUERY_FLAG_NUMBER, null, &seconds, &size, null));
    return if (has_seconds) seconds else null;
}

/// "Name: value\r\n" lines for WinHttpSendRequest; caller frees.
fn headerBlock(allocator: std.mem.Allocator, options: FetchOptions) ![:0]u16 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    if (options.content_type) |content_type| try text.writer.print("Content-Type: {s}\r\n", .{content_type});
    for (options.extra_headers) |header| try text.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text.written());
}

/// Caller frees.
fn readBody(allocator: std.mem.Allocator, request: HINTERNET, win32_error: *DWORD) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var chunk: [READ_CHUNK_BYTES]u8 = undefined;
    while (true) {
        var bytes_read: DWORD = 0;
        if (!win32.toBool(win32.WinHttpReadData(request, &chunk, chunk.len, &bytes_read))) return winHttpFailure(win32_error, error.ReadDataFailed);
        if (bytes_read == 0) break;
        try body.appendSlice(allocator, chunk[0..bytes_read]);
    }
    return body.toOwnedSlice(allocator);
}

/// Caller frees.
fn finalUrl(allocator: std.mem.Allocator, request: HINTERNET, win32_error: *DWORD) ![:0]u8 {
    var buf: [MAX_URL_LENGTH]WCHAR = undefined;
    var size_bytes: DWORD = @sizeOf(@TypeOf(buf));
    if (!win32.toBool(win32.WinHttpQueryOption(request, win32.WINHTTP_OPTION_URL, &buf, &size_bytes))) return winHttpFailure(win32_error, error.QueryUrlFailed);
    const url_w = std.mem.sliceTo(buf[0 .. size_bytes / @sizeOf(WCHAR)], 0);
    return std.unicode.utf16LeToUtf8AllocZ(allocator, url_w);
}
