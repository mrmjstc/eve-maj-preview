//! Calls that touch no app state - pickers, network and file scans - so they run on a thread of their own instead of stalling thumbnails on the main one.
const std = @import("std");
const build_options = @import("build_options");
const win32 = @import("../../platform/win32.zig");
const config = @import("../../config.zig");
const files = @import("../../config/files.zig");
const update = @import("../../update.zig");
const esi_prices = @import("../tools/esi_prices.zig");
const ultra_potato = @import("../tools/ultra_potato.zig");
const host = @import("../host.zig");
const log = @import("../../log.zig");

const slog = log.scoped("dialog");

pub const runs_on_caller = true;

const RunningWindow = struct { class: []const u8, exe: []const u8, title: []const u8 };

const ApplyResult = struct { path: []const u8, ok: bool, changed: bool, @"error": ?[]const u8 };

const WindowScan = struct {
    arena: std.mem.Allocator,
    windows: std.ArrayList(RunningWindow) = .empty,
    failed: ?anyerror = null,
};

pub fn getAppVersion(_: std.mem.Allocator) ![]const u8 {
    return build_options.version;
}

/// null when cancelled.
pub fn browseChatlogDir(arena: std.mem.Allocator) !?[]const u8 {
    return win32.showFolderPicker(arena, "Select Chatlog Directory", host.hwnd());
}

pub fn browseGamelogDir(arena: std.mem.Allocator) !?[]const u8 {
    return win32.showFolderPicker(arena, "Select Gamelog Directory", host.hwnd());
}

pub fn browseSoundFile(arena: std.mem.Allocator) !?[]const u8 {
    return win32.showFilePicker(arena, "Select Sound File", "Audio Files (*.wav, *.mp3)", "*.wav;*.mp3", host.hwnd());
}

/// Opens in the OS default browser rather than a WebView2 popup, which a plain `<a target="_blank">` would spawn instead.
pub fn openUrlInBrowser(_: std.mem.Allocator, args: struct { url: []const u8 }) !void {
    if (!win32.shellOpenUrl(args.url)) return error.FailedToOpenUrl;
}

/// JS warnings and errors, so they land in eve-maj.log instead of only the hidden devtools console.
pub fn logClientMessage(_: std.mem.Allocator, args: struct { level: []const u8, message: []const u8 }) !void {
    if (std.mem.eql(u8, args.level, "warn")) {
        slog.warn("[js] {s}", .{args.message});
    } else {
        slog.err("[js] {s}", .{args.message});
    }
}

pub fn getUpdateStatus(arena: std.mem.Allocator) !struct { available: bool, version: []const u8 = "", url: []const u8 = "", notes: []const u8 = "" } {
    var version_buf: [128]u8 = undefined;
    var url_buf: [512]u8 = undefined;
    const version = update.g_update_status.copyVersionZ(&version_buf) orelse return .{ .available = false };
    const url = update.g_update_status.copyUrlZ(&url_buf) orelse return .{ .available = false };
    return .{
        .available = true,
        .version = try arena.dupe(u8, version),
        .url = try arena.dupe(u8, url),
        .notes = update.g_update_status.dupeNotes(arena) orelse "",
    };
}

/// One entry per distinct (class, executable) among visible windows, for picking a Window Filter instead of typing names.
pub fn getRunningWindows(arena: std.mem.Allocator) ![]const RunningWindow {
    var scan = WindowScan{ .arena = arena };
    _ = win32.EnumWindows(collectWindow, win32.ptrToLparam(&scan));
    if (scan.failed) |err| return err;
    std.sort.pdq(RunningWindow, scan.windows.items, {}, struct {
        fn lessThan(_: void, a: RunningWindow, b: RunningWindow) bool {
            return std.mem.lessThan(u8, a.exe, b.exe);
        }
    }.lessThan);
    return scan.windows.items;
}

/// Each ore name's Jita buy price, omitting names with no market match.
pub fn fetchOrePrices(arena: std.mem.Allocator, args: struct { names: []const []const u8 }) !esi_prices.Prices {
    return esi_prices.fetchOrePrices(host.allocator(), arena, files.g_io, args.names);
}

/// EVE's core_public__.yaml settings files, one per client install or settings profile.
pub fn scanUltraPotatoProfiles(arena: std.mem.Allocator) ![]const ultra_potato.Profile {
    return ultra_potato.scanProfiles(arena, files.g_io, config.environMap());
}

pub fn applyUltraPotatoMode(arena: std.mem.Allocator, args: struct { paths: []const []const u8 }) !struct { results: []const ApplyResult } {
    if (args.paths.len == 0) return error.NoProfilesSelected;
    const results = try ultra_potato.applyToFiles(arena, files.g_io, args.paths);
    const out = try arena.alloc(ApplyResult, results.len);
    for (results, out) |r, *o| o.* = .{ .path = r.path, .ok = r.success, .changed = r.changed, .@"error" = r.error_message };
    return .{ .results = out };
}

fn collectWindow(window: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const scan: *WindowScan = win32.lparamToPtr(WindowScan, lParam);
    if (!win32.toBool(win32.IsWindowVisible(window))) return win32.TRUE;

    var title_buf: [512:0]u8 = undefined;
    const title_len = win32.GetWindowTextA(window, &title_buf, title_buf.len);
    if (title_len <= 0) return win32.TRUE;
    var class_buf: [64:0]u8 = undefined;
    const class = win32.getClassNameBuf(window, &class_buf) orelse return win32.TRUE;
    var exe_buf: [260:0]u8 = undefined;
    const exe = win32.windowExeName(window, &exe_buf) orelse return win32.TRUE;
    if (exe.len == 0) return win32.TRUE;

    for (scan.windows.items) |existing| {
        if (std.mem.eql(u8, existing.class, class) and std.ascii.eqlIgnoreCase(existing.exe, exe)) return win32.TRUE;
    }
    const entry = RunningWindow{
        .class = scan.arena.dupe(u8, class) catch |err| return stopScan(scan, err),
        .exe = scan.arena.dupe(u8, exe) catch |err| return stopScan(scan, err),
        .title = scan.arena.dupe(u8, title_buf[0..@intCast(title_len)]) catch |err| return stopScan(scan, err),
    };
    scan.windows.append(scan.arena, entry) catch |err| return stopScan(scan, err);
    return win32.TRUE;
}

fn stopScan(scan: *WindowScan, err: anyerror) win32.BOOL {
    scan.failed = err;
    return win32.FALSE;
}
