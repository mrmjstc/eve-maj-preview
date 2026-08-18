const std = @import("std");
const webui = @import("webui");
const win32 = @import("win32.zig");
const config_mod = @import("config.zig");
const log_filenames = @import("gamelog_viewer/log_filenames.zig");
const eve_clients = @import("gamelog_viewer/eve_clients.zig");
const log = @import("log.zig");

const slog = log.scoped("gamelog_viewer");

const viewer_html = @embedFile("gamelog_viewer/gamelog_viewer.html");
const viewer_css = @embedFile("gamelog_viewer/gamelog_viewer.css");
const viewer_js = @embedFile("gamelog_viewer/gamelog_viewer.js");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// Window title used to find an already-open viewer instance and as the browser app-window's title.
const WINDOW_TITLE = "EVE-Maj Preview Gamelog Viewer";

pub fn main() !void {
    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\EVE-Maj-Preview-GamelogViewer-SingleInstance");
    const instance_mutex = win32.CreateMutexW(null, win32.TRUE, mutex_name);
    if (instance_mutex == null) {
        slog.err("Failed to create gamelog viewer instance mutex", .{});
        return error.MutexCreationFailed;
    }
    defer _ = win32.CloseHandle(instance_mutex.?);

    if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
        slog.info("Gamelog viewer is already open, focusing existing window", .{});
        focusExistingWindow();
        return;
    }

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (config_mod.GlobalSettings.load(allocator)) |loaded| {
        var startup_settings = loaded;
        log.setLevel(startup_settings.logLevel);
        startup_settings.deinit();
    } else |_| {}

    slog.info("EVE-Maj Preview Gamelog Viewer", .{});

    var win = webui.newWindow();

    win.setSize(1350, 1050);
    win.setPosition(150, 60);
    win.setKiosk(false);
    win.setResizable(true);

    _ = try win.bind("listOpenCharacters", listOpenCharacters);
    _ = try win.bind("loadGamelogForCharacter", loadGamelogForCharacter);
    _ = try win.bind("logClientMessage", logClientMessage);

    const html_with_resources = try injectResources(allocator);
    defer allocator.free(html_with_resources);

    _ = try win.show(html_with_resources);

    const move_thread = try std.Thread.spawn(.{}, moveWindowWorkaround, .{win});
    move_thread.detach();

    webui.wait();

    slog.info("Gamelog viewer closed", .{});
}

fn focusExistingWindow() void {
    const hwnd = win32.FindWindowA(null, WINDOW_TITLE) orelse {
        slog.warn("Could not find existing gamelog viewer window", .{});
        return;
    };
    if (win32.IsIconic(hwnd) != 0) {
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    }
    _ = win32.SetForegroundWindow(hwnd);
}

/// Moves the window slightly after a brief delay to trigger layout recalculation
/// (same WebView2 initial-layout workaround config_dialog.zig uses), then reveals it.
fn moveWindowWorkaround(win: anytype) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);

    win.setPosition(151, 60);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    win.setPosition(150, 60);

    win.run("document.documentElement.classList.remove('pre-init');");
}

fn injectResources(allocator: std.mem.Allocator) ![:0]u8 {
    const css_placeholder = "/* Styles will be injected here by WebUI */";
    const with_css = try std.mem.replaceOwned(u8, allocator, viewer_html, css_placeholder, viewer_css);
    defer allocator.free(with_css);

    const js_placeholder = "// Script will be injected here by WebUI";
    const with_js = try std.mem.replaceOwned(u8, allocator, with_css, js_placeholder, viewer_js);
    defer allocator.free(with_js);

    return allocator.dupeZ(u8, with_js);
}

fn appendJsonEscaped(allocator: std.mem.Allocator, response: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| {
        if (c == '"' or c == '\\') response.append(allocator, '\\') catch return;
        response.append(allocator, c) catch return;
    }
}

/// Return a JSON array of character names from open EVE clients, used by the viewer's character picker.
fn listOpenCharacters(e: *webui.Event) void {
    const allocator = gpa.allocator();

    var entries = eve_clients.listOpenClients(allocator) catch {
        e.returnString("[]");
        return;
    };
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);

    response.append(allocator, '[') catch {
        e.returnString("[]");
        return;
    };

    for (entries.items, 0..) |entry, i| {
        if (i > 0) response.append(allocator, ',') catch break;
        response.append(allocator, '"') catch break;
        appendJsonEscaped(allocator, &response, entry.name);
        response.append(allocator, '"') catch break;
    }

    response.append(allocator, ']') catch {
        e.returnString("[]");
        return;
    };

    const result = allocator.dupeZ(u8, response.items) catch {
        e.returnString("[]");
        return;
    };
    defer allocator.free(result);
    e.returnString(result);
}

/// Returns the current profile's resolved gamelog directory (owned copy), falling back to
/// the default profile if global settings or the profile file can't be read.
fn currentGamelogDir(allocator: std.mem.Allocator) ![]u8 {
    var settings_opt = config_mod.GlobalSettings.load(allocator) catch null;
    defer if (settings_opt) |*s| s.deinit();

    const profile_name = if (settings_opt) |s| s.lastUsedProfile else config_mod.DEFAULT_PROFILE;

    var cfg = try config_mod.Config.loadProfile(allocator, profile_name);
    defer cfg.deinit();

    return try allocator.dupe(u8, cfg.chatlog.gamelogDir);
}

/// Read the "Listener:" header line from a gamelog file's first 512 bytes.
fn readGamelogListener(allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var buffer: [512]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const text = buffer[0..bytes_read];

    const needle = "Listener:";
    const pos = std.mem.indexOf(u8, text, needle) orelse return null;
    const after = text[pos + needle.len ..];
    const end = std.mem.indexOfAny(u8, after, "\r\n") orelse after.len;
    const name = std.mem.trim(u8, after[0..end], " \t");
    if (name.len == 0) return null;
    return try allocator.dupe(u8, name);
}

/// Finds the newest gamelog file belonging to `character_name` in `gamelog_dir` by scanning
/// every "*.txt" candidate newest-first and checking its "Listener:" header. This is the same
/// matching strategy as ChatlogMonitor.findLogFile's slow path, reimplemented standalone since
/// this viewer runs a single manual lookup rather than the always-on monitor's hot poll loop.
fn findNewestGamelogForCharacter(allocator: std.mem.Allocator, gamelog_dir: []const u8, character_name: []const u8) !?[]u8 {
    var dir = std.fs.cwd().openDir(gamelog_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var candidates = std.ArrayList([]const u8).empty;
    defer {
        for (candidates.items) |c| allocator.free(c);
        candidates.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        // "Local_*.txt" is the chatlog naming convention; excluded even if gamelogDir is misconfigured to the same folder.
        if (std.mem.startsWith(u8, entry.name, "Local_")) continue;
        if (log_filenames.parseLogTimestamp(entry.name, false) == 0) continue;

        const copy = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(copy);
        try candidates.append(allocator, copy);
    }

    std.mem.sort([]const u8, candidates.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return log_filenames.parseLogTimestamp(a, false) > log_filenames.parseLogTimestamp(b, false);
        }
    }.lessThan);

    for (candidates.items) |name| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ gamelog_dir, name });
        defer allocator.free(full_path);

        const listener = readGamelogListener(allocator, full_path) catch continue;
        defer if (listener) |l| allocator.free(l);

        if (listener == null or !std.mem.eql(u8, listener.?, character_name)) continue;

        return try allocator.dupe(u8, full_path);
    }

    return null;
}

const MAX_GAMELOG_FILE_SIZE = 64 * 1024 * 1024;

/// Read a gamelog file as UTF-8, stripping a leading BOM if present (gamelogs are UTF-8, unlike chatlogs' UTF-16 LE).
fn readGamelogFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, MAX_GAMELOG_FILE_SIZE);
    if (raw.len >= 3 and raw[0] == 0xEF and raw[1] == 0xBB and raw[2] == 0xBF) {
        defer allocator.free(raw);
        return try allocator.dupe(u8, raw[3..]);
    }
    return raw;
}

/// Bound to the viewer's character picker: finds and returns `character_name`'s newest gamelog
/// file's raw text, or an empty string if none is found. The client-side parser reads the
/// Listener/Session header directly out of the returned text, so no separate metadata is needed.
fn loadGamelogForCharacter(e: *webui.Event) void {
    const character_name = e.getString();
    const allocator = gpa.allocator();

    const gamelog_dir = currentGamelogDir(allocator) catch |err| {
        slog.err("Failed to resolve gamelog directory: {}", .{err});
        e.returnString("");
        return;
    };
    defer allocator.free(gamelog_dir);

    if (gamelog_dir.len == 0) {
        e.returnString("");
        return;
    }

    const path = (findNewestGamelogForCharacter(allocator, gamelog_dir, character_name) catch |err| {
        slog.warn("Gamelog scan failed for {s}: {}", .{ character_name, err });
        e.returnString("");
        return;
    }) orelse {
        slog.debug("No gamelog file found for {s}", .{character_name});
        e.returnString("");
        return;
    };
    defer allocator.free(path);

    const text = readGamelogFile(allocator, path) catch |err| {
        slog.warn("Failed to read gamelog {s}: {}", .{ path, err });
        e.returnString("");
        return;
    };
    defer allocator.free(text);

    const text_z = allocator.dupeZ(u8, text) catch {
        e.returnString("");
        return;
    };
    defer allocator.free(text_z);

    e.returnString(text_z);
}

/// Bound to the viewer JS's window.onerror/unhandledrejection handlers, so JS-side failures
/// land in eve-maj.log next to everything else (same pattern as config_dialog.zig).
fn logClientMessage(e: *webui.Event) void {
    const level = e.getStringAt(0);
    const message = e.getStringAt(1);

    if (std.mem.eql(u8, level, "warn")) {
        slog.warn("[js] {s}", .{message});
    } else {
        slog.err("[js] {s}", .{message});
    }
}
