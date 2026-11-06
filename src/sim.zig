//! Entry point of the client simulator, which stands in for EVE clients so the app can be tested without the game.
const std = @import("std");
const win32 = @import("platform/win32.zig");
const fleet_mod = @import("sim/fleet.zig");
const client_window = @import("sim/client_window.zig");
const window = @import("sim/window.zig");
const log = @import("log.zig");

const Fleet = fleet_mod.Fleet;
const slog = log.Scoped("sim");

/// Under %TEMP%: the client copies, saved systems and this tool's log.
const WORK_DIR_NAME = "EveMajSimulator";
const CLIENT_FLAG = "--client";

pub fn main(init: std.process.Init) void {
    // Before any window, or Windows bitmap-stretches them on scaled monitors.
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    log.setIo(init.io);
    log.setLevel(.info);
    defer log.deinitFile();
    mainImpl(init) catch |err| {
        slog.err("Failed to run the client simulator: {}", .{err});
        _ = win32.MessageBoxA(null, "The client simulator stopped with an error. Its log, under %TEMP%\\" ++ WORK_DIR_NAME ++ "\\logs, has the details.", "EVE-Maj Client Simulator", win32.MB_OK | win32.MB_ICONERROR);
        std.process.exit(1);
    };
}

fn mainImpl(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_arena: std.heap.ArenaAllocator = .init(allocator);
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    const temp_dir = init.environ_map.get("TEMP") orelse return error.MissingTempDir;
    const work_dir = try std.Io.Dir.path.join(allocator, &.{ temp_dir, WORK_DIR_NAME });
    defer allocator.free(work_dir);
    // First, so even a client's log lands in the work folder rather than beside the exe.
    try useWorkDir(init.io, work_dir);

    if (args.len >= 3 and std.mem.eql(u8, args[1], CLIENT_FLAG)) return client_window.run(args[2]);

    const documents_dir = win32.getKnownFolderPath(allocator, win32.FOLDERID_Documents) catch |err| blk: {
        slog.warn("Failed to resolve the Documents folder, using USERPROFILE\\Documents: {}", .{err});
        const user_profile = init.environ_map.get("USERPROFILE") orelse return error.MissingUserProfile;
        break :blk try std.Io.Dir.path.join(allocator, &.{ user_profile, "Documents" });
    };
    defer allocator.free(documents_dir);

    var fleet: Fleet = try .init(allocator, init.io, work_dir, documents_dir);
    defer fleet.deinit();
    try window.run(allocator, init.io, &fleet);
}

fn useWorkDir(io: std.Io, work_dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    var terminated_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const terminated = try std.mem.printSentinel(&terminated_buf, "{s}", .{work_dir}, 0);
    if (!win32.toBool(win32.SetCurrentDirectoryA(terminated))) {
        slog.err("Failed to work in '{s}': error {d}", .{ work_dir, win32.GetLastError() });
        return error.SetCurrentDirectoryFailed;
    }
}
