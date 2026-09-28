//! The window's one binding, `rpc(method, argsJson)`: every `pub fn` in the api modules is a method, taking an arena and optionally an args struct parsed from `argsJson`.
//! Replies are `{"ok":true,"data":...}` or `{"ok":false,"error":{"code","message"}}`, logged once here.
//! webui calls this on its own threads; a module's calls run on the main thread unless it declares `runs_on_caller = true`.
const std = @import("std");
const webui = @import("webui");
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");
const main_mod = @import("../main.zig");
const host = @import("host.zig");

const slog = log.scoped("dialog");

const api_modules = .{
    @import("api/session.zig"),
    @import("api/profiles.zig"),
    @import("api/app.zig"),
    @import("api/background.zig"),
};

/// Already-serialized JSON, embedded in a reply as-is.
pub const RawJson = struct {
    text: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.print("{s}", .{self.text});
    }
};

/// Long enough for a Save, which reloads the whole profile before replying.
const MAIN_THREAD_TIMEOUT_MS = 60_000;

pub fn bind(win: webui) !void {
    _ = try win.bind("rpc", onCall);
}

const Call = struct {
    method: []const u8,
    args: []const u8,
    response: ?[:0]u8 = null,
};

fn onCall(e: *webui.Event) void {
    var call = Call{ .method = e.getStringAt(0), .args = e.getStringAt(1) };
    if (runsOnCaller(call.method)) {
        execute(&call);
    } else {
        sendToMainThread(&call);
    }
    const response = call.response orelse {
        e.returnString("{\"ok\":false,\"error\":{\"code\":\"NoResponse\",\"message\":\"No response\"}}");
        return;
    };
    defer host.allocator().free(response);
    e.returnString(response);
}

fn sendToMainThread(call: *Call) void {
    const timer = main_mod.g_timer_hwnd orelse {
        slog.err("rpc {s}: the main window isn't available", .{call.method});
        return;
    };
    var result: usize = 0;
    if (win32.SendMessageTimeoutA(timer, win32.WM_DIALOG_RPC, 0, @bitCast(@intFromPtr(call)), win32.SMTO_ABORTIFHUNG, MAIN_THREAD_TIMEOUT_MS, &result) == 0) {
        slog.err("rpc {s}: the main thread didn't answer", .{call.method});
    }
}

/// WM_DIALOG_RPC's handler.
pub fn runOnMainThread(lParam: win32.LPARAM) void {
    execute(win32.lparamToPtr(Call, lParam));
}

fn execute(call: *Call) void {
    var arena_state = std.heap.ArenaAllocator.init(host.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = dispatch(arena, call.method, call.args) catch |err| errorResponse(arena, call.method, err);
    call.response = host.allocator().dupeZ(u8, json) catch |err| {
        slog.err("rpc {s}: failed to copy the response: {}", .{ call.method, err });
        return;
    };
}

fn runsOnCaller(method: []const u8) bool {
    inline for (api_modules) |M| {
        if (comptime @hasDecl(M, "runs_on_caller")) {
            inline for (comptime methodNames(M)) |name| {
                if (std.mem.eql(u8, name, method)) return true;
            }
        }
    }
    return false;
}

fn methodNames(comptime M: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(M).@"struct".decls) |d| {
            const info = @typeInfo(@TypeOf(@field(M, d.name)));
            if (info != .@"fn") continue;
            const params = info.@"fn".params;
            if (params.len == 0 or params.len > 2 or params[0].type != std.mem.Allocator) {
                @compileError(@typeName(M) ++ "." ++ d.name ++ " must take an arena and optionally an args struct to be an rpc method");
            }
            names = names ++ &[_][]const u8{d.name};
        }
        return names;
    }
}

fn dispatch(arena: std.mem.Allocator, method: []const u8, args_json: []const u8) ![]const u8 {
    const args: std.json.Value = if (args_json.len == 0)
        .null
    else
        std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return error.InvalidArguments;

    inline for (api_modules) |M| {
        inline for (comptime methodNames(M)) |name| {
            if (std.mem.eql(u8, name, method)) return invoke(arena, @field(M, name), args);
        }
    }
    return error.UnknownMethod;
}

fn invoke(arena: std.mem.Allocator, comptime func: anytype, args: std.json.Value) ![]const u8 {
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    const result = if (params.len == 1) try func(arena) else blk: {
        const Args = params[1].type.?;
        const source: std.json.Value = if (args == .null) .{ .object = .empty } else args;
        const parsed = std.json.parseFromValueLeaky(Args, arena, source, .{ .ignore_unknown_fields = true }) catch return error.InvalidArguments;
        break :blk try func(arena, parsed);
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("ok");
    try jw.write(true);
    try jw.objectField("data");
    if (@TypeOf(result) == void) try jw.write(null) else try jw.write(result);
    try jw.endObject();
    return out.written();
}

fn errorResponse(arena: std.mem.Allocator, method: []const u8, err: anyerror) []const u8 {
    slog.err("rpc {s} failed: {}", .{ method, err });
    const message = humanize(arena, @errorName(err)) catch @errorName(err);
    return std.json.Stringify.valueAlloc(arena, .{ .ok = false, .@"error" = .{ .code = @errorName(err), .message = message } }, .{}) catch
        "{\"ok\":false,\"error\":{\"code\":\"OutOfMemory\",\"message\":\"Out of memory\"}}";
}

/// "ProfileAlreadyExists" -> "Profile already exists", the message shown in the window.
fn humanize(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (i > 0 and std.ascii.isUpper(c)) {
            try out.append(arena, ' ');
            try out.append(arena, std.ascii.toLower(c));
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}
