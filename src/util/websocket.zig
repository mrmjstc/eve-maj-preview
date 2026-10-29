//! A blocking WebSocket client over WinHTTP, where one thread receives while another may send.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const DWORD = win32.DWORD;
const HINTERNET = win32.HINTERNET;
const slog = log.Scoped("websocket");

const USER_AGENT = std.unicode.utf8ToUtf16LeStringLiteral("EVE-Maj-Preview");
const CONNECT_TIMEOUT_MS: c_int = 10_000;
/// Longer than the gap between messages the peer promises, so a dead connection ends rather than blocking receive forever.
const RECEIVE_TIMEOUT_MS: c_int = 15_000;
const SWITCHING_PROTOCOLS = 101;

pub const Kind = enum { binary, text };

pub const Received = union(enum) {
    /// Borrows from the buffer given to receive.
    binary: []const u8,
    /// Borrows from the buffer given to receive.
    text: []const u8,
    /// The server closed the connection.
    closed,
};

pub const WebSocket = struct {
    session: HINTERNET,
    connection: HINTERNET,
    socket: HINTERNET,

    /// Over HTTPS, with any query in `path`, e.g. "/join/ABCDEF?v=1"; logs its own failures.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, path: []const u8) !WebSocket {
        const session = win32.WinHttpOpen(USER_AGENT, win32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse {
            slog.warn("Failed to open a WinHTTP session: error {d}", .{win32.GetLastError()});
            return error.OpenSessionFailed;
        };
        errdefer _ = win32.WinHttpCloseHandle(session);
        if (!win32.toBool(win32.WinHttpSetTimeouts(session, CONNECT_TIMEOUT_MS, CONNECT_TIMEOUT_MS, CONNECT_TIMEOUT_MS, RECEIVE_TIMEOUT_MS))) {
            slog.warn("Failed to set WebSocket timeouts: error {d}", .{win32.GetLastError()});
            return error.SetTimeoutsFailed;
        }

        const host_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, host);
        defer allocator.free(host_w);
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);

        const connection = win32.WinHttpConnect(session, host_w, win32.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse {
            slog.warn("Failed to connect to '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.ConnectFailed;
        };
        errdefer _ = win32.WinHttpCloseHandle(connection);
        const request = win32.WinHttpOpenRequest(connection, std.unicode.utf8ToUtf16LeStringLiteral("GET"), path_w, null, null, null, win32.WINHTTP_FLAG_SECURE) orelse {
            slog.warn("Failed to open a WebSocket request to '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.OpenRequestFailed;
        };
        defer _ = win32.WinHttpCloseHandle(request);
        if (!win32.toBool(win32.WinHttpSetOption(request, win32.WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, null, 0))) {
            slog.warn("Failed to ask '{s}' for a WebSocket: error {d}", .{ host, win32.GetLastError() });
            return error.SetOptionFailed;
        }
        if (!win32.toBool(win32.WinHttpSendRequest(request, null, 0, null, 0, 0, 0))) {
            slog.warn("Failed to send a WebSocket request to '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.SendRequestFailed;
        }
        if (!win32.toBool(win32.WinHttpReceiveResponse(request, null))) {
            slog.warn("Failed to receive the WebSocket response from '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.ReceiveResponseFailed;
        }
        var status: DWORD = 0;
        var status_size: DWORD = @sizeOf(DWORD);
        if (!win32.toBool(win32.WinHttpQueryHeaders(request, win32.WINHTTP_QUERY_STATUS_CODE | win32.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null))) {
            slog.warn("Failed to read the WebSocket response status from '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.QueryStatusFailed;
        }
        if (status != SWITCHING_PROTOCOLS) {
            slog.warn("Failed to open a WebSocket to '{s}': status {d}", .{ host, status });
            return error.UpgradeRefused;
        }
        const socket = win32.WinHttpWebSocketCompleteUpgrade(request, 0) orelse {
            slog.warn("Failed to complete the WebSocket upgrade with '{s}': error {d}", .{ host, win32.GetLastError() });
            return error.UpgradeFailed;
        };
        return .{ .session = session, .connection = connection, .socket = socket };
    }

    /// Only once no other thread is sending or receiving.
    pub fn deinit(self: *WebSocket) void {
        _ = win32.WinHttpCloseHandle(self.socket);
        _ = win32.WinHttpCloseHandle(self.connection);
        _ = win32.WinHttpCloseHandle(self.session);
    }

    /// One send at a time, which may overlap a receive on another thread; logs its own failure.
    pub fn send(self: *const WebSocket, kind: Kind, bytes: []const u8) !void {
        const buffer_type = switch (kind) {
            .binary => win32.WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
            .text => win32.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
        };
        const result = win32.WinHttpWebSocketSend(self.socket, buffer_type, bytes.ptr, @intCast(bytes.len));
        if (result != 0) {
            slog.warn("Failed to send a WebSocket message: error {d}", .{result});
            return error.SendFailed;
        }
    }

    /// Blocks until a whole message arrives, failing on one too big for `buf`; logs its own failure.
    pub fn receive(self: *const WebSocket, buf: []u8) !Received {
        var bytes_read: DWORD = 0;
        var buffer_type: c_int = 0;
        const result = win32.WinHttpWebSocketReceive(self.socket, buf.ptr, @intCast(buf.len), &bytes_read, &buffer_type);
        if (result != 0) {
            slog.info("WebSocket receive ended: error {d}", .{result});
            return error.ReceiveFailed;
        }
        return switch (buffer_type) {
            win32.WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE => .{ .binary = buf[0..bytes_read] },
            win32.WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE => .{ .text = buf[0..bytes_read] },
            win32.WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE => .closed,
            else => {
                slog.warn("Failed to receive a WebSocket message: it was larger than {d} bytes", .{buf.len});
                return error.MessageTooLarge;
            },
        };
    }

    /// Starts a clean close; a receive on another thread then returns .closed once the server agrees.
    pub fn shutdown(self: *const WebSocket) void {
        const result = win32.WinHttpWebSocketShutdown(self.socket, win32.WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, null, 0);
        if (result != 0) slog.info("Failed to start closing a WebSocket: error {d}", .{result});
    }
};
