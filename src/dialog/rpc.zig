//! The window's one binding, `eveRpc(method, argsJson)`: every `pub fn` in the api modules is a method, taking an arena and optionally an args struct parsed from `argsJson`.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const webview = @import("../platform/webview.zig");
const main = @import("../main.zig");
const host = @import("host.zig");
const log = @import("../log.zig");

const slog = log.scoped("dialog");

const API_MODULES = .{
    @import("api/session.zig"),
    @import("api/profiles.zig"),
    @import("api/import.zig"),
    @import("api/app.zig"),
    @import("api/background.zig"),
};

const BINDING_NAME = "eveRpc";

const NO_RESPONSE = "{\"ok\":false,\"error\":{\"code\":\"NoResponse\",\"message\":\"No response\"}}";

/// Already-serialized JSON, embedded in a reply as-is; borrowed.
pub const RawJson = struct {
    text: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.print("{s}", .{self.text});
    }
};

/// Created on the window's thread and handed to whichever thread runs it, which replies and destroys it.
const Call = struct {
    /// The window it came from, so a reply to a closed window is dropped (see host.reply).
    generation: u32,
    id: [:0]u8,
    method: []u8,
    args: []u8,
    response: ?[:0]u8 = null,

    fn create(generation: u32, id: []const u8, method: []const u8, args: []const u8) !*Call {
        const allocator = host.allocator();
        const call = try allocator.create(Call);
        errdefer allocator.destroy(call);
        const owned_id = try allocator.dupeSentinel(u8, id, 0);
        errdefer allocator.free(owned_id);
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        call.* = .{ .generation = generation, .id = owned_id, .method = owned_method, .args = try allocator.dupe(u8, args) };
        return call;
    }

    fn destroy(self: *Call) void {
        const allocator = host.allocator();
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.args);
        if (self.response) |response| allocator.free(response);
        allocator.destroy(self);
    }

    fn finish(self: *Call) void {
        host.reply(self.generation, self.id, self.response orelse NO_RESPONSE);
        self.destroy();
    }
};

/// Window thread only.
pub fn bind(w: webview.Webview) !void {
    if (webview.webview_bind(w, BINDING_NAME, onCall, null) < 0) return error.BindFailed;
}

/// WM_DIALOG_RPC's handler.
pub fn runOnMainThread(lParam: win32.LPARAM) void {
    const call = win32.lparamToPtr(Call, lParam);
    execute(call);
    call.finish();
}

/// On the window's thread; req is the JSON array `[method, argsJson]`.
fn onCall(id: [*:0]const u8, req: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const generation = host.generation();
    const call = parseCall(generation, std.mem.span(id), std.mem.span(req)) catch |err| {
        slog.err("Failed to read an rpc call: {}", .{err});
        host.reply(generation, id, NO_RESPONSE);
        return;
    };
    if (runsOnCaller(call.method)) {
        const thread = std.Thread.spawn(.{}, runOnWorker, .{call}) catch |err| {
            slog.warn("Failed to start a thread for rpc {s}, running it on the window's: {}", .{ call.method, err });
            runOnWorker(call);
            return;
        };
        thread.detach();
    } else {
        postToMainThread(call);
    }
}

fn parseCall(generation: u32, id: []const u8, req: []const u8) !*Call {
    var arena_state = std.heap.ArenaAllocator.init(host.allocator());
    defer arena_state.deinit();
    const params = try std.json.parseFromSliceLeaky([]const []const u8, arena_state.allocator(), req, .{});
    if (params.len != 2) return error.InvalidArguments;
    return Call.create(generation, id, params[0], params[1]);
}

fn runOnWorker(call: *Call) void {
    execute(call);
    call.finish();
}

fn postToMainThread(call: *Call) void {
    const timer = main.g_timer_hwnd orelse {
        slog.err("Failed to run rpc {s}: the main window isn't available", .{call.method});
        call.finish();
        return;
    };
    if (!win32.toBool(win32.PostMessageA(timer, win32.WM_DIALOG_RPC, 0, @bitCast(@intFromPtr(call))))) {
        slog.err("Failed to run rpc {s}: couldn't post it to the main thread", .{call.method});
        call.finish();
    }
}

/// Replies `{"ok":true,"data":...}` or `{"ok":false,"error":{"code","message"}}`, a failure logged once here.
fn execute(call: *Call) void {
    var arena_state = std.heap.ArenaAllocator.init(host.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = dispatch(arena, call.method, call.args) catch |err| errorResponse(arena, call.method, err);
    call.response = host.allocator().dupeSentinel(u8, json, 0) catch |err| {
        slog.err("Failed to copy the response to rpc {s}: {}", .{ call.method, err });
        return;
    };
}

/// A method runs on the main thread unless its module declares `runs_on_caller = true`, which runs it on a thread of its own.
fn runsOnCaller(method: []const u8) bool {
    inline for (API_MODULES) |M| {
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
        for (@typeInfo(M).@"struct".decl_names) |decl_name| {
            const info = @typeInfo(@TypeOf(@field(M, decl_name)));
            if (info != .@"fn") continue;
            const param_types = info.@"fn".param_types;
            if (param_types.len == 0 or param_types.len > 2 or param_types[0] != std.mem.Allocator) {
                @compileError(@typeName(M) ++ "." ++ decl_name ++ " must take an arena and optionally an args struct to be an rpc method");
            }
            names = names ++ &[_][]const u8{decl_name};
        }
        return names;
    }
}

fn dispatch(arena: std.mem.Allocator, method: []const u8, args_json: []const u8) ![]const u8 {
    const args: std.json.Value = if (args_json.len == 0)
        .null
    else
        std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return error.InvalidArguments;

    inline for (API_MODULES) |M| {
        inline for (comptime methodNames(M)) |name| {
            if (std.mem.eql(u8, name, method)) return invoke(arena, @field(M, name), args);
        }
    }
    return error.UnknownMethod;
}

fn invoke(arena: std.mem.Allocator, comptime func: anytype, args: std.json.Value) ![]const u8 {
    const param_types = @typeInfo(@TypeOf(func)).@"fn".param_types;
    const result = if (param_types.len == 1) try func(arena) else blk: {
        const Args = param_types[1].?;
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

/// Errors that reach the window are named as their message (see humanize), so they don't follow the usual XxxFailed shape.
fn errorResponse(arena: std.mem.Allocator, method: []const u8, err: anyerror) []const u8 {
    slog.err("Failed to run rpc {s}: {}", .{ method, err });
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
