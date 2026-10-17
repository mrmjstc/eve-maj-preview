//! One-shot HTTP requests over WinHTTP, each bounded by timeouts so none can hang its thread.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const DWORD = win32.DWORD;
const BOOL = win32.BOOL;
const slog = log.Scoped("http_client");

const WCHAR = u16;
const HINTERNET = *anyopaque;

const USER_AGENT = std.unicode.utf8ToUtf16LeStringLiteral("EVE-Maj-Preview");
/// Applies to each phase (resolve, connect, send, receive) separately.
const TIMEOUT_MS: c_int = 10_000;
const READ_CHUNK_BYTES = 16 * 1024;
const MAX_URL_LENGTH = 2048;

const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: DWORD = 4;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x20000000;
const WINHTTP_OPTION_URL: DWORD = 34;
const INTERNET_SCHEME_HTTPS: c_int = 2;
const ERROR_WINHTTP_TIMEOUT: DWORD = 12002;
/// A nonzero length with a null pointer makes WinHttpCrackUrl point the component into the input instead of copying it.
const POINT_INTO_INPUT: DWORD = std.math.maxInt(DWORD);

extern "winhttp" fn WinHttpOpen(agent: ?[*:0]const WCHAR, access_type: DWORD, proxy: ?[*:0]const WCHAR, proxy_bypass: ?[*:0]const WCHAR, flags: DWORD) callconv(.c) ?HINTERNET;
extern "winhttp" fn WinHttpSetTimeouts(handle: HINTERNET, resolve_ms: c_int, connect_ms: c_int, send_ms: c_int, receive_ms: c_int) callconv(.c) BOOL;
extern "winhttp" fn WinHttpCrackUrl(url: [*]const WCHAR, url_length: DWORD, flags: DWORD, components: *URL_COMPONENTS) callconv(.c) BOOL;
extern "winhttp" fn WinHttpConnect(session: HINTERNET, server_name: [*:0]const WCHAR, server_port: u16, reserved: DWORD) callconv(.c) ?HINTERNET;
extern "winhttp" fn WinHttpOpenRequest(connection: HINTERNET, verb: [*:0]const WCHAR, object_name: [*:0]const WCHAR, version: ?[*:0]const WCHAR, referrer: ?[*:0]const WCHAR, accept_types: ?*const ?[*:0]const WCHAR, flags: DWORD) callconv(.c) ?HINTERNET;
extern "winhttp" fn WinHttpSendRequest(request: HINTERNET, headers: ?[*]const WCHAR, headers_length: DWORD, optional: ?*const anyopaque, optional_length: DWORD, total_length: DWORD, context: usize) callconv(.c) BOOL;
extern "winhttp" fn WinHttpReceiveResponse(request: HINTERNET, reserved: ?*anyopaque) callconv(.c) BOOL;
extern "winhttp" fn WinHttpQueryHeaders(request: HINTERNET, info_level: DWORD, name: ?[*:0]const WCHAR, buffer: ?*anyopaque, buffer_length: *DWORD, index: ?*DWORD) callconv(.c) BOOL;
extern "winhttp" fn WinHttpQueryOption(handle: HINTERNET, option: DWORD, buffer: ?*anyopaque, buffer_length: *DWORD) callconv(.c) BOOL;
extern "winhttp" fn WinHttpReadData(request: HINTERNET, buffer: [*]u8, bytes_to_read: DWORD, bytes_read: *DWORD) callconv(.c) BOOL;
extern "winhttp" fn WinHttpCloseHandle(handle: HINTERNET) callconv(.c) BOOL;

const URL_COMPONENTS = extern struct {
    dwStructSize: DWORD = @sizeOf(URL_COMPONENTS),
    lpszScheme: ?[*]WCHAR = null,
    dwSchemeLength: DWORD = 0,
    nScheme: c_int = 0,
    lpszHostName: ?[*]WCHAR = null,
    dwHostNameLength: DWORD = 0,
    nPort: u16 = 0,
    lpszUserName: ?[*]WCHAR = null,
    dwUserNameLength: DWORD = 0,
    lpszPassword: ?[*]WCHAR = null,
    dwPasswordLength: DWORD = 0,
    lpszUrlPath: ?[*]WCHAR = null,
    dwUrlPathLength: DWORD = 0,
    lpszExtraInfo: ?[*]WCHAR = null,
    dwExtraInfoLength: DWORD = 0,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const FetchOptions = struct {
    content_type: ?[]const u8 = null,
    /// Sent as a POST body; without one the request is a GET.
    payload: ?[]const u8 = null,
    extra_headers: []const Header = &.{},
};

pub const Response = struct {
    status: u32,
    /// Owned; freed in deinit.
    body: []u8,
    /// Where the response came from, after any redirects. Owned; freed in deinit.
    url: [:0]u8,

    pub fn deinit(self: *const Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.url);
    }
};

const RequestError = error{
    InvalidUrl,
    ConnectFailed,
    OpenRequestFailed,
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
        const handle = WinHttpOpen(USER_AGENT, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse {
            slog.warn("Failed to open a WinHTTP session: error {d}", .{win32.GetLastError()});
            return error.OpenSessionFailed;
        };
        errdefer _ = WinHttpCloseHandle(handle);
        if (!win32.toBool(WinHttpSetTimeouts(handle, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS, TIMEOUT_MS))) {
            slog.warn("Failed to set WinHTTP timeouts: error {d}", .{win32.GetLastError()});
            return error.SetTimeoutsFailed;
        }
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Session) void {
        _ = WinHttpCloseHandle(self.handle);
    }

    /// The body of a 200 response; caller frees. Logs every failure itself.
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

    /// Follows redirects and returns whatever status the final response has. Logs every failure itself.
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

        var parts: URL_COMPONENTS = .{
            .dwHostNameLength = POINT_INTO_INPUT,
            .dwUrlPathLength = POINT_INTO_INPUT,
            .dwExtraInfoLength = POINT_INTO_INPUT,
        };
        if (!win32.toBool(WinHttpCrackUrl(url_w.ptr, @intCast(url_w.len), 0, &parts))) return winHttpFailure(win32_error, error.InvalidUrl);
        const host_ptr = parts.lpszHostName orelse return error.InvalidUrl;
        const host = try allocator.dupeSentinel(WCHAR, host_ptr[0..parts.dwHostNameLength], 0);
        defer allocator.free(host);

        // The path and query sit next to each other in the URL, so one copy covers both.
        const path: []const WCHAR = if (parts.lpszUrlPath) |path_ptr| path_ptr[0 .. parts.dwUrlPathLength + parts.dwExtraInfoLength] else &.{};
        const object = try allocator.dupeSentinel(WCHAR, if (path.len > 0) path else std.unicode.utf8ToUtf16LeStringLiteral("/"), 0);
        defer allocator.free(object);

        const connection = WinHttpConnect(self.handle, host, parts.nPort, 0) orelse return winHttpFailure(win32_error, error.ConnectFailed);
        defer _ = WinHttpCloseHandle(connection);

        const verb: [*:0]const WCHAR = if (options.payload != null) std.unicode.utf8ToUtf16LeStringLiteral("POST") else std.unicode.utf8ToUtf16LeStringLiteral("GET");
        const flags: DWORD = if (parts.nScheme == INTERNET_SCHEME_HTTPS) WINHTTP_FLAG_SECURE else 0;
        const request = WinHttpOpenRequest(connection, verb, object, null, null, null, flags) orelse return winHttpFailure(win32_error, error.OpenRequestFailed);
        defer _ = WinHttpCloseHandle(request);

        const headers = try headerBlock(allocator, options);
        defer allocator.free(headers);
        const payload = options.payload orelse "";
        const payload_length: DWORD = @intCast(payload.len);
        const headers_ptr: ?[*]const WCHAR = if (headers.len > 0) headers.ptr else null;
        const payload_ptr: ?*const anyopaque = if (payload.len > 0) payload.ptr else null;
        if (!win32.toBool(WinHttpSendRequest(request, headers_ptr, @intCast(headers.len), payload_ptr, payload_length, payload_length, 0))) {
            return winHttpFailure(win32_error, error.SendRequestFailed);
        }
        if (!win32.toBool(WinHttpReceiveResponse(request, null))) return winHttpFailure(win32_error, error.ReceiveResponseFailed);

        var status: DWORD = 0;
        var status_size: DWORD = @sizeOf(DWORD);
        if (!win32.toBool(WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null))) {
            return winHttpFailure(win32_error, error.QueryStatusFailed);
        }

        const body = try readBody(allocator, request, win32_error);
        errdefer allocator.free(body);
        const final_url = try finalUrl(allocator, request, win32_error);
        return .{ .status = status, .body = body, .url = final_url };
    }
};

/// Records GetLastError before cleanup can overwrite it, and reports a timeout as error.TimedOut.
fn winHttpFailure(win32_error: *DWORD, err: RequestError) RequestError {
    win32_error.* = win32.GetLastError();
    return if (win32_error.* == ERROR_WINHTTP_TIMEOUT) error.TimedOut else err;
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
        if (!win32.toBool(WinHttpReadData(request, &chunk, chunk.len, &bytes_read))) return winHttpFailure(win32_error, error.ReadDataFailed);
        if (bytes_read == 0) break;
        try body.appendSlice(allocator, chunk[0..bytes_read]);
    }
    return body.toOwnedSlice(allocator);
}

/// Caller frees.
fn finalUrl(allocator: std.mem.Allocator, request: HINTERNET, win32_error: *DWORD) ![:0]u8 {
    var buf: [MAX_URL_LENGTH]WCHAR = undefined;
    var size_bytes: DWORD = @sizeOf(@TypeOf(buf));
    if (!win32.toBool(WinHttpQueryOption(request, WINHTTP_OPTION_URL, &buf, &size_bytes))) return winHttpFailure(win32_error, error.QueryUrlFailed);
    const url_w = std.mem.sliceTo(buf[0 .. size_bytes / @sizeOf(WCHAR)], 0);
    return std.unicode.utf16LeToUtf8AllocZ(allocator, url_w);
}
