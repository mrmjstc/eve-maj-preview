const std = @import("std");
const webui = @import("webui");
const protocol = @import("protocol.zig");
const win32 = @import("win32.zig");
const build_options = @import("build_options");
const config_mod = @import("config.zig");
const log = @import("log.zig");

const slog = log.scoped("config_dialog");

const config_html = @embedFile("config_dialog.html");
const config_css = @embedFile("config_dialog.css");
const config_js = @embedFile("config_dialog.js");

const catalog_en = @embedFile("lang/en.json");
const catalog_de = @embedFile("lang/de.json");
const catalog_es = @embedFile("lang/es.json");
const catalog_ru = @embedFile("lang/ru.json");

/// Add a language by dropping src/lang/xx.json, embedding it above, and adding one variant here plus one arm each in `catalog()` and `displayName()`.
const SupportedLang = enum {
    en,
    de,
    es,
    ru,

    fn catalog(self: SupportedLang) []const u8 {
        return switch (self) {
            .en => catalog_en,
            .de => catalog_de,
            .es => catalog_es,
            .ru => catalog_ru,
        };
    }

    fn displayName(self: SupportedLang) []const u8 {
        return switch (self) {
            .en => "English",
            .de => "Deutsch",
            .es => "Español",
            .ru => "Русский",
        };
    }
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var config_path: []const u8 = "profiles/default.json";
// Non-null when config_path was heap-allocated and must be freed before reassignment.
var config_path_allocated: ?[]const u8 = null;

/// Window title used to find an already-open dialog instance and as the browser app-window's title (set via config_dialog.html's <title>).
const DIALOG_WINDOW_TITLE = "EVE-Maj Preview Configuration";

/// Extract the profile filename (e.g. "default.json") from config_path, which is always "profiles/<name>.json".
fn currentProfileFilename() []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, config_path, '/')) |idx|
        config_path[idx + 1 ..]
    else if (std.mem.lastIndexOfScalar(u8, config_path, '\\')) |idx|
        config_path[idx + 1 ..]
    else
        config_path;
}

pub fn main() !void {
    // Single-instance enforcement: if another instance already holds the mutex, focus its window and exit.
    const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\EVE-Maj-Preview-ConfigDialog-SingleInstance");
    const instance_mutex = win32.CreateMutexW(null, win32.TRUE, mutex_name);
    if (instance_mutex == null) {
        slog.err("Failed to create config dialog instance mutex", .{});
        return error.MutexCreationFailed;
    }
    defer _ = win32.CloseHandle(instance_mutex.?);

    if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
        slog.info("Configuration dialog is already open, focusing existing window", .{});
        focusExistingDialog();
        return;
    }

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    if (args.next()) |path| {
        config_path = path;
    } else {
        if (loadLastUsedProfile(allocator)) |profile_path| {
            config_path = profile_path;
            config_path_allocated = profile_path;
        } else |_| {}
    }

    // Match the app's configured log level (same as main.zig) before logging anything else, or everything below defaults to err-only.
    var active_lang: SupportedLang = .en;
    if (config_mod.GlobalSettings.load(allocator)) |loaded| {
        var startup_settings = loaded;
        log.setLevel(startup_settings.logLevel);
        active_lang = std.meta.stringToEnum(SupportedLang, startup_settings.language) orelse .en;
        startup_settings.deinit();
    } else |_| {}

    if (config_path_allocated) |profile_path| {
        slog.debug("Loaded last used profile from global.settings.json: {s}", .{profile_path});
    }

    slog.info("EVE-Maj Preview Configuration Dialog", .{});
    slog.debug("Loading config from: {s}", .{config_path});

    var win = webui.newWindow();

    win.setSize(1000, 950);
    win.setPosition(200, 100);
    win.setKiosk(false);
    win.setResizable(false);

    _ = try win.bind("closeDialog", closeDialog);
    _ = try win.bind("minimizeDialog", minimizeDialog);
    _ = try win.bind("loadConfig", loadConfig);
    _ = try win.bind("getDefaultConfig", getDefaultConfig);
    _ = try win.bind("saveConfig", saveConfig);
    _ = try win.bind("getConfigData", getConfigData);
    _ = try win.bind("listProfiles", listProfiles);
    _ = try win.bind("switchProfile", switchProfile);
    _ = try win.bind("createProfile", createProfile);
    _ = try win.bind("copyProfile", copyProfile);
    _ = try win.bind("deleteProfile", deleteProfile);
    _ = try win.bind("resetProfile", resetProfile);
    _ = try win.bind("browseChatlogDir", browseChatlogDir);
    _ = try win.bind("browseGamelogDir", browseGamelogDir);
    _ = try win.bind("setCharacterWindowPosition", setCharacterWindowPosition);
    _ = try win.bind("clearCharacterWindowPosition", clearCharacterWindowPosition);
    _ = try win.bind("setAllCharacterWindowPositions", setAllCharacterWindowPositions);
    _ = try win.bind("clearAllCharacterWindowPositions", clearAllCharacterWindowPositions);
    _ = try win.bind("getOpenClients", getOpenClients);
    _ = try win.bind("getRunningWindows", getRunningWindows);
    _ = try win.bind("loadGlobalSettings", loadGlobalSettings);
    _ = try win.bind("saveGlobalSettings", saveGlobalSettings);
    _ = try win.bind("fetchOrePrices", fetchOrePrices);
    _ = try win.bind("previewThumbnailConfig", previewThumbnailConfig);
    _ = try win.bind("togglePreviewThumbnail", togglePreviewThumbnail);
    _ = try win.bind("suspendHotkeysForRecording", suspendHotkeysForRecording);
    _ = try win.bind("resumeHotkeysAfterRecording", resumeHotkeysAfterRecording);
    _ = try win.bind("switchProfileLive", switchProfileLive);
    _ = try win.bind("logClientMessage", logClientMessage);
    _ = try win.bind("getMainAppStatus", getMainAppStatus);
    _ = try win.bind("getValidationRanges", getValidationRanges);

    const html_with_resources = try injectResources(allocator, active_lang);
    defer allocator.free(html_with_resources);

    slog.debug("Opening configuration dialog in browser mode", .{});
    _ = try win.show(html_with_resources);

    const move_thread = try std.Thread.spawn(.{}, moveWindowWorkaround, .{win});
    move_thread.detach();

    webui.wait();

    slog.info("Configuration dialog closed", .{});
}

/// Bring an already-open configuration dialog window to the foreground.
/// Called when this process loses the single-instance mutex race.
fn focusExistingDialog() void {
    const hwnd = win32.FindWindowA(null, DIALOG_WINDOW_TITLE) orelse {
        slog.warn("Could not find existing configuration dialog window", .{});
        return;
    };
    if (win32.IsIconic(hwnd) != 0) {
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    }
    _ = win32.SetForegroundWindow(hwnd);
}

/// Moves the window slightly after a brief delay to trigger layout recalculation
fn moveWindowWorkaround(win: anytype) void {
    std.Thread.sleep(10 * std.time.ns_per_ms);

    win.setPosition(201, 100);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    win.setPosition(200, 100);

    // Make window visible now that layout is fixed
    win.run("document.documentElement.classList.remove('pre-init');");

    slog.debug("Window position workaround applied and window visible", .{});

    // Keep the dialog reachable above the main app / EVE clients.
    if (win.win32GetHwnd()) |hwnd| {
        _ = win32.SetWindowPos(@ptrCast(hwnd), win32.HWND_TOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE);
        slog.debug("Configuration dialog set to always-on-top", .{});
    } else |err| {
        slog.warn("Failed to get window handle for always-on-top: {}", .{err});
    }
}

fn loadLastUsedProfile(allocator: std.mem.Allocator) ![]const u8 {
    const settings_path = "profiles/global.settings.json";

    const file = std.fs.cwd().openFile(settings_path, .{}) catch |err| {
        slog.debug("Could not open {s}: {}", .{ settings_path, err });
        return error.SettingsNotFound;
    };
    defer file.close();

    const content = file.readToEndAllocOptions(allocator, 1024 * 1024, null, .@"1", 0) catch |err| {
        slog.warn("Failed to read {s}: {}", .{ settings_path, err });
        return error.ReadFailed;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        slog.warn("Failed to parse {s}: {}", .{ settings_path, err });
        return error.ParseFailed;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return error.InvalidFormat;
    }

    const last_used = root.object.get("lastUsedProfile") orelse {
        slog.debug("'lastUsedProfile' field not found in {s}", .{settings_path});
        return error.FieldNotFound;
    };

    if (last_used != .string) {
        return error.InvalidFieldType;
    }

    const profile_name = last_used.string;
    const profile_path = try std.fmt.allocPrint(allocator, "profiles/{s}", .{profile_name});

    return profile_path;
}

fn closeDialog(e: *webui.Event) void {
    slog.debug("Close dialog requested", .{});
    revertThumbnailPreviewInMainApp();
    destroySimulatedPreviewIfActive();
    // Safety net: ensure hotkeys aren't left suspended if the dialog closes mid-recording.
    if (findMainAppWindow()) |hwnd| {
        protocol.sendCommandToInstance(hwnd, protocol.Command{ .DialogResumeHotkeys = {} });
    }
    const win = e.getWindow();
    win.close();
}

fn minimizeDialog(e: *webui.Event) void {
    slog.debug("Minimize dialog requested", .{});
    const win = e.getWindow();
    win.minimize();
}

fn loadConfig(e: *webui.Event) void {
    const allocator = gpa.allocator();

    slog.debug("Loading config from: {s}", .{config_path});

    // Route through Config.loadProfile (not a raw file read) so fields missing from the on-disk JSON get the same Zig-side defaults as the main app, instead of showing up blank in the dialog.
    const profile_name = currentProfileFilename();
    var cfg = config_mod.Config.loadProfile(allocator, profile_name) catch |err| {
        slog.err("Failed to load config profile '{s}': {}", .{ profile_name, err });
        e.returnString("{\"error\": \"Failed to open config file\"}");
        return;
    };
    defer cfg.deinit();

    const json = cfg.toJsonString(allocator) catch |err| {
        slog.err("Failed to serialize config: {}", .{err});
        e.returnString("{\"error\": \"Failed to read config file\"}");
        return;
    };
    defer allocator.free(json);

    const json_z = allocator.dupeZ(u8, json) catch |err| {
        slog.err("Failed to allocate config response: {}", .{err});
        e.returnString("{\"error\": \"Failed to read config file\"}");
        return;
    };
    defer allocator.free(json_z);

    slog.debug("Config content length: {}, first chars: {s}", .{ json_z.len, if (json_z.len > 0) json_z[0..@min(50, json_z.len)] else "" });

    e.returnString(json_z);
}

// Returns the app's built-in factory defaults as JSON (not tied to a saved profile), used by the "Clear to Default" button so reset values live in one place instead of being duplicated in config_dialog.js/html.
fn getDefaultConfig(e: *webui.Event) void {
    const allocator = gpa.allocator();

    var defaults = config_mod.Config.getDefaultsWithProfile(allocator, currentProfileFilename()) catch |err| {
        slog.err("Failed to build default config: {}", .{err});
        e.returnString("{\"error\": \"Failed to build defaults\"}");
        return;
    };
    defer defaults.deinit();

    const json = defaults.toJsonString(allocator) catch |err| {
        slog.err("Failed to serialize default config: {}", .{err});
        e.returnString("{\"error\": \"Failed to build defaults\"}");
        return;
    };
    defer allocator.free(json);

    const json_z = allocator.dupeZ(u8, json) catch |err| {
        slog.err("Failed to allocate default config response: {}", .{err});
        e.returnString("{\"error\": \"Failed to build defaults\"}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

// Routes the save through Config.buildConfigFromJson + validate() + toJsonString rather than writing JS-sent JSON straight to disk, so out-of-range values get clamped on save (not just on next load) and malformed payloads are rejected instead of corrupting the file.
fn saveConfig(e: *webui.Event) void {
    const json_data = e.getString();
    const allocator = gpa.allocator();
    const profile_name = currentProfileFilename();

    var cfg = config_mod.Config.buildConfigFromJson(allocator, json_data, profile_name) catch |err| {
        slog.warn("Rejected invalid config from dialog: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Invalid configuration\"}");
        return;
    };
    defer cfg.deinit();

    cfg.saveToJsonFile(allocator, config_path) catch |err| {
        slog.err("Failed to write config file: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Failed to write file\"}");
        return;
    };

    slog.info("Config saved successfully", .{});

    reloadProfileInMainApp();

    e.returnString("{\"success\": true}");
}

/// Window class of the main app's hidden timer window, used to find its instance for WM_COPYDATA IPC (profile reload, live thumbnail preview, preview revert).
const MAIN_APP_TIMER_CLASS_NAME = "EVE_TIMER_CLASS";

fn findMainAppWindow() ?win32.HWND {
    return protocol.findExistingInstance(MAIN_APP_TIMER_CLASS_NAME);
}

/// Polled by the dialog's status indicator to reflect whether the main app is running, using the same window lookup the IPC commands already rely on.
fn getMainAppStatus(e: *webui.Event) void {
    const running = findMainAppWindow() != null;
    e.returnString(if (running) "{\"running\": true}" else "{\"running\": false}");
}

/// Hands the dialog the same min/max bounds Config.validate() enforces (keyed by the dotted config path config_dialog.js's CONFIG_SCHEMA uses) so bounds aren't hand-copied into JS; called once on dialog init.
fn getValidationRanges(e: *webui.Event) void {
    const allocator = gpa.allocator();

    const json = config_mod.Config.buildValidationRangesJson(allocator) catch |err| {
        slog.err("Failed to build validation ranges: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer allocator.free(json);

    const json_z = allocator.dupeZ(u8, json) catch |err| {
        slog.err("Failed to allocate validation ranges response: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

/// Tell the running main app to fully reload onto `profile_name` (the same heavy teardown/rebuild used by Save); shared by the post-Save reload and the "Make It Live" action.
fn sendProfileSwitchToMainApp(profile_name: []const u8) void {
    const allocator = gpa.allocator();

    slog.debug("Attempting to switch profile in main app: {s}", .{profile_name});

    if (findMainAppWindow()) |hwnd| {
        const profile_name_copy = allocator.dupe(u8, profile_name) catch {
            slog.err("Failed to allocate memory for profile name", .{});
            return;
        };
        defer allocator.free(profile_name_copy);

        const cmd = protocol.Command{ .Profile = profile_name_copy };
        protocol.sendCommandToInstance(hwnd, cmd);

        slog.debug("Successfully sent profile switch command to main application", .{});
    } else {
        slog.debug("Main application window not found - profile will be loaded on next startup", .{});
    }
}

fn reloadProfileInMainApp() void {
    sendProfileSwitchToMainApp(currentProfileFilename());
}

/// Bound to the dialog's "Make It Live" choice (see showLiveSwitchModal() in config_dialog.js); switches the running main app onto a profile that may differ from the one open for editing.
fn switchProfileLive(e: *webui.Event) void {
    const profile_name = e.getString();
    sendProfileSwitchToMainApp(profile_name);
    e.returnString("{\"success\": true}");
}

/// Pushes an unsaved patch of thumbnail-appearance and grid/stack/list layout fields to the running main app so it repaints/repositions immediately without writing to disk; called on every relevant form edit in the Thumbnails/Overlay Text tabs (see previewThumbnailConfig() in config_dialog.js).
fn previewThumbnailConfig(e: *webui.Event) void {
    const json_data = e.getString();

    if (findMainAppWindow()) |hwnd| {
        protocol.sendCommandToInstance(hwnd, protocol.Command{ .PreviewThumbnail = json_data });
    }

    e.returnString("{\"success\": true}");
}

/// Tell the running main app to discard any live preview and reload thumbnail appearance from disk; called on dialog close, a no-op if the profile was saved first.
fn revertThumbnailPreviewInMainApp() void {
    if (findMainAppWindow()) |hwnd| {
        protocol.sendCommandToInstance(hwnd, protocol.Command{ .RevertPreview = {} });
    }
}

// A real, draggable thumbnail against fake "Preview Pilot" data, rendered by the running main app
// using its own real Painter (real window classes, real WndProcs, real message loop) - not a
// second rendering path inside config.exe. Requires eve-maj-preview.exe to be running, same as
// previewThumbnailConfig()/PreviewThumbnail above; SendMessageA's WM_COPYDATA is synchronous, so
// the LRESULT painter_ptr.toggleSimulatedThumbnail() returns comes straight back as the reply.
fn sendSimulatedThumbnailCommand(dwData: usize) ?win32.LRESULT {
    const hwnd = findMainAppWindow() orelse return null;
    const cds = win32.COPYDATASTRUCT{
        .dwData = dwData,
        .cbData = 0,
        .lpData = null,
    };
    return win32.SendMessageA(hwnd, win32.WM_COPYDATA, 0, @intCast(@intFromPtr(&cds)));
}

/// Bound to the Thumbnails tab's "Live Preview" button.
fn togglePreviewThumbnail(e: *webui.Event) void {
    const result = sendSimulatedThumbnailCommand(win32.PROTOCOL_TOGGLE_SIMULATED_THUMBNAIL) orelse {
        e.returnString("{\"active\": false, \"error\": \"Main app is not running\"}");
        return;
    };
    e.returnString(if (result != 0) "{\"active\": true}" else "{\"active\": false}");
}

/// Force-removes the simulated preview thumbnail if the main app has one; called on dialog close so toggling it on doesn't leave it stuck until the app restarts. A no-op (not an error) if the main app isn't running.
fn destroySimulatedPreviewIfActive() void {
    _ = sendSimulatedThumbnailCommand(win32.PROTOCOL_DESTROY_SIMULATED_THUMBNAIL);
}

/// Suspend the main app's global hotkeys during a Record capture so a bound key (e.g. cycle-client) doesn't fire while just being captured; called by config_dialog.js's recordHotkey().
fn suspendHotkeysForRecording(e: *webui.Event) void {
    if (findMainAppWindow()) |hwnd| {
        protocol.sendCommandToInstance(hwnd, protocol.Command{ .DialogSuspendHotkeys = {} });
    }
    e.returnString("{\"success\": true}");
}

/// Resume hotkeys suspended by suspendHotkeysForRecording(); called by config_dialog.js's stopRecording() and unconditionally on dialog close as a safety net.
fn resumeHotkeysAfterRecording(e: *webui.Event) void {
    if (findMainAppWindow()) |hwnd| {
        protocol.sendCommandToInstance(hwnd, protocol.Command{ .DialogResumeHotkeys = {} });
    }
    e.returnString("{\"success\": true}");
}

const STARTUP_RUN_KEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const STARTUP_RUN_VALUE_NAME = "EVE-Maj Preview";

/// Points the Run entry at eve-maj-preview.exe, which always ships alongside config.exe (see tray.zig's openConfigDialog for the reverse lookup).
fn applyRunOnStartup(enabled: bool) bool {
    if (!enabled) {
        var hKey: win32.HKEY = undefined;
        const open_result = win32.RegOpenKeyExA(win32.HKEY_CURRENT_USER, STARTUP_RUN_KEY, 0, win32.KEY_WRITE, &hKey);
        if (open_result != win32.ERROR_SUCCESS) return true;
        defer _ = win32.RegCloseKey(hKey);
        _ = win32.RegDeleteValueA(hKey, STARTUP_RUN_VALUE_NAME);
        return true;
    }

    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch {
        slog.err("Failed to determine executable directory for startup registration", .{});
        return false;
    };

    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const exe_path = std.fmt.bufPrintZ(&path_buf, "\"{s}\\eve-maj-preview.exe\"", .{exe_dir}) catch {
        slog.err("Failed to build eve-maj-preview.exe path", .{});
        return false;
    };

    var hKey: win32.HKEY = undefined;
    var disposition: win32.DWORD = undefined;
    const create_result = win32.RegCreateKeyExA(
        win32.HKEY_CURRENT_USER,
        STARTUP_RUN_KEY,
        0,
        null,
        win32.REG_OPTION_NON_VOLATILE,
        win32.KEY_WRITE,
        null,
        &hKey,
        &disposition,
    );
    if (create_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to open startup registry key: error {}", .{create_result});
        return false;
    }
    defer _ = win32.RegCloseKey(hKey);

    const set_result = win32.RegSetValueExA(hKey, STARTUP_RUN_VALUE_NAME, 0, win32.REG_SZ, exe_path.ptr, @intCast(exe_path.len + 1));
    if (set_result != win32.ERROR_SUCCESS) {
        slog.err("Failed to set startup registry value: error {}", .{set_result});
        return false;
    }

    return true;
}

const GLOBAL_SETTINGS_PATH = "profiles/global.settings.json";

/// GlobalSettings only persists a price per ore (see OrePriceEntry); this rebuilds the full name/category/volumeM3/price view the dialog renders,
/// filling each row's price from the persisted override if present or DEFAULT_ORE_TABLE's snapshot otherwise.
fn loadGlobalSettings(e: *webui.Event) void {
    const allocator = gpa.allocator();

    slog.debug("Loading global settings from: {s}", .{GLOBAL_SETTINGS_PATH});

    var settings = config_mod.GlobalSettings.load(allocator) catch |err| {
        slog.warn("Failed to load global settings ({}), returning empty defaults", .{err});
        e.returnString("{}");
        return;
    };
    defer settings.deinit();

    const base_json = settings.toJsonString(allocator) catch |err| {
        slog.warn("Failed to serialize global settings: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer allocator.free(base_json);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, base_json, .{}) catch |err| {
        slog.warn("Failed to re-parse global settings for oreTable merge: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        // Allocated from parsed's own arena, not the outer allocator, so parsed.deinit() below frees this too.
        const arena_allocator = parsed.arena.allocator();
        var display_ore = std.json.Array.init(arena_allocator);
        for (config_mod.DEFAULT_ORE_TABLE) |default_entry| {
            const price = settings.orePrice(default_entry.name) orelse default_entry.price;
            var obj = std.json.ObjectMap.init(arena_allocator);
            obj.put("name", .{ .string = default_entry.name }) catch continue;
            obj.put("category", .{ .string = default_entry.category }) catch continue;
            obj.put("volumeM3", .{ .float = default_entry.volumeM3 }) catch continue;
            obj.put("price", .{ .float = price }) catch continue;
            display_ore.append(.{ .object = obj }) catch continue;
        }
        parsed.value.object.put("oreTable", .{ .array = display_ore }) catch {};
    }

    const merged_json = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch |err| {
        slog.warn("Failed to serialize merged global settings: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer allocator.free(merged_json);

    const json_z = allocator.dupeZ(u8, merged_json) catch |err| {
        slog.warn("Failed to serialize merged global settings: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

/// Parses the dialog's full-view payload (see loadGlobalSettings) back through GlobalSettings.Wire, which only keeps name/price from each oreTable
/// entry (ignore_unknown_fields drops category/volumeM3) - so only prices ever reach disk, not the fixed defaults sent along for display.
fn saveGlobalSettings(e: *webui.Event) void {
    const json_data = e.getString();
    const allocator = gpa.allocator();

    const parsed_value = std.json.parseFromSlice(std.json.Value, allocator, json_data, .{}) catch |err| {
        slog.err("Failed to parse global settings JSON: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Invalid JSON\"}");
        return;
    };
    defer parsed_value.deinit();

    const parsed_wire = std.json.parseFromValue(config_mod.GlobalSettings.Wire, allocator, parsed_value.value, .{ .ignore_unknown_fields = true }) catch |err| {
        slog.err("Failed to parse global settings into Wire: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Invalid settings format\"}");
        return;
    };
    defer parsed_wire.deinit();

    var settings = config_mod.GlobalSettings.fromWire(parsed_wire.value, allocator) catch |err| {
        slog.err("Failed to build global settings from wire: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Failed to process settings\"}");
        return;
    };
    defer settings.deinit();

    settings.save() catch |err| {
        slog.err("Failed to save global settings: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Failed to write file\"}");
        return;
    };

    if (!applyRunOnStartup(settings.runOnStartup)) {
        slog.warn("Failed to apply run-on-startup registry setting", .{});
    }

    slog.info("Global settings saved successfully", .{});
    e.returnString("{\"success\": true}");
}

const ESI_BASE = "https://esi.evetech.net/latest";
const ESI_JITA_REGION_ID = 10000002;
const ESI_JITA_STATION_ID: i64 = 60003760;

/// Spawns curl with the given args and returns captured stdout (caller frees) if it exits 0, else null.
fn curlRun(allocator: std.mem.Allocator, args: []const []const u8) ?[]u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    child.spawn() catch |err| {
        slog.warn("Failed to spawn curl: {}", .{err});
        return null;
    };
    child.collectOutput(allocator, &stdout, &stderr, 4 * 1024 * 1024) catch |err| {
        slog.warn("Failed to read curl output: {}", .{err});
        _ = child.kill() catch {};
        stdout.deinit(allocator);
        return null;
    };
    const term = child.wait() catch |err| {
        slog.warn("Failed to wait for curl: {}", .{err});
        stdout.deinit(allocator);
        return null;
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            slog.warn("curl exited with code {d}: {s}", .{ code, stderr.items });
            stdout.deinit(allocator);
            return null;
        },
        else => {
            slog.warn("curl terminated abnormally", .{});
            stdout.deinit(allocator);
            return null;
        },
    }

    return stdout.toOwnedSlice(allocator) catch {
        stdout.deinit(allocator);
        return null;
    };
}

/// Resolves "Compressed <name>" -> ESI type_id for each ore name via the public (no-auth) ESI name resolver.
/// Names with no market match are simply absent from the result. Caller frees both the keys and the map.
fn resolveOreTypeIds(allocator: std.mem.Allocator, names: []const []const u8) !std.StringHashMap(i64) {
    var result = std.StringHashMap(i64).init(allocator);
    errdefer result.deinit();
    if (names.len == 0) return result;

    const prefixed = try allocator.alloc([]const u8, names.len);
    defer {
        for (prefixed) |p| allocator.free(p);
        allocator.free(prefixed);
    }
    for (names, 0..) |name, i| {
        prefixed[i] = try std.fmt.allocPrint(allocator, "Compressed {s}", .{name});
    }

    const body = try std.json.Stringify.valueAlloc(allocator, prefixed, .{});
    defer allocator.free(body);

    const stdout = curlRun(allocator, &.{
        "curl",          "-s",                          "-X",                                                "POST",
        "-H",            "User-Agent: EVE-Maj-Preview", "-H",                                                "Content-Type: application/json",
        "--data-binary", body,                          ESI_BASE ++ "/universe/ids/?datasource=tranquility",
    }) orelse return result;
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch |err| {
        slog.warn("Failed to parse ESI universe/ids response: {}", .{err});
        return result;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return result;
    const inventory_types = parsed.value.object.get("inventory_types") orelse return result;
    if (inventory_types != .array) return result;

    for (inventory_types.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        const name_val = item.object.get("name") orelse continue;
        if (id_val != .integer or name_val != .string) continue;

        const prefix = "Compressed ";
        if (!std.mem.startsWith(u8, name_val.string, prefix)) continue;
        const base_name = name_val.string[prefix.len..];

        const key = try allocator.dupe(u8, base_name);
        errdefer allocator.free(key);
        try result.put(key, id_val.integer);
    }

    return result;
}

/// Highest current Jita 4-4 buy order price for type_id (what a seller would instantly receive), or null if unavailable/illiquid.
/// Only reads page 1 of the region's buy orders - fine for these commodity ore types, whose buy-order counts stay well under the 1000-order page size in practice.
fn fetchJitaBuyPrice(allocator: std.mem.Allocator, type_id: i64) ?f64 {
    const url = std.fmt.allocPrint(allocator, ESI_BASE ++ "/markets/{d}/orders/?datasource=tranquility&order_type=buy&type_id={d}", .{ ESI_JITA_REGION_ID, type_id }) catch return null;
    defer allocator.free(url);

    const stdout = curlRun(allocator, &.{ "curl", "-s", "-H", "User-Agent: EVE-Maj-Preview", url }) orelse return null;
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;

    var best: ?f64 = null;
    for (parsed.value.array.items) |order| {
        if (order != .object) continue;
        const location_val = order.object.get("location_id") orelse continue;
        if (location_val != .integer or location_val.integer != ESI_JITA_STATION_ID) continue;

        const price_val = order.object.get("price") orelse continue;
        const price: f64 = switch (price_val) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => continue,
        };
        if (best == null or price > best.?) best = price;
    }
    return best;
}

/// Caps how many curl requests run at once for a price fetch - bounded so this stays polite to ESI rather than opening dozens of connections at once.
const MAX_CONCURRENT_PRICE_REQUESTS = 8;

const PriceLookup = struct {
    name: []const u8,
    type_id: i64,
};

const PriceFetchContext = struct {
    allocator: std.mem.Allocator,
    lookups: []const PriceLookup,
    next_index: std.atomic.Value(usize),
    results_mutex: std.Thread.Mutex = .{},
    results: *std.json.ObjectMap,
};

/// Pulls lookups off ctx's shared index until exhausted; safe to run on several threads (including the caller's) at once.
fn priceFetchWorker(ctx: *PriceFetchContext) void {
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.lookups.len) return;

        const lookup = ctx.lookups[i];
        const price = fetchJitaBuyPrice(ctx.allocator, lookup.type_id) orelse continue;

        ctx.results_mutex.lock();
        defer ctx.results_mutex.unlock();
        ctx.results.put(lookup.name, .{ .float = price }) catch {};
    }
}

/// Looks up each ore name's Jita buy price via its compressed variant (readily liquid there) using the public ESI API - no key required.
/// Request body: JSON array of ore names. Response: JSON object of {name: price}, omitting names with no market match.
fn fetchOrePrices(e: *webui.Event) void {
    const allocator = gpa.allocator();
    const json_data = e.getString();

    const parsed_names = std.json.parseFromSlice([]const []const u8, allocator, json_data, .{}) catch |err| {
        slog.warn("Failed to parse fetchOrePrices request: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer parsed_names.deinit();

    var type_ids = resolveOreTypeIds(allocator, parsed_names.value) catch |err| {
        slog.warn("Failed to resolve ore type ids via ESI: {}", .{err});
        e.returnString("{}");
        return;
    };
    defer {
        var key_it = type_ids.keyIterator();
        while (key_it.next()) |k| allocator.free(k.*);
        type_ids.deinit();
    }

    var results = std.json.ObjectMap.init(allocator);
    defer results.deinit();

    const lookups = allocator.alloc(PriceLookup, type_ids.count()) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(lookups);
    {
        var idx: usize = 0;
        var it = type_ids.iterator();
        while (it.next()) |entry| : (idx += 1) {
            lookups[idx] = .{ .name = entry.key_ptr.*, .type_id = entry.value_ptr.* };
        }
    }

    if (lookups.len > 0) {
        var ctx = PriceFetchContext{
            .allocator = allocator,
            .lookups = lookups,
            .next_index = std.atomic.Value(usize).init(0),
            .results = &results,
        };

        // Spawn up to MAX_CONCURRENT_PRICE_REQUESTS - 1 background workers; the calling thread pulls from the same queue as the last one, so a failed spawn just means less parallelism, not less work done.
        const worker_count = @min(MAX_CONCURRENT_PRICE_REQUESTS, lookups.len);
        var threads = [_]?std.Thread{null} ** (MAX_CONCURRENT_PRICE_REQUESTS - 1);
        const background_workers = worker_count - 1;
        for (threads[0..background_workers]) |*slot| {
            slot.* = std.Thread.spawn(.{}, priceFetchWorker, .{&ctx}) catch |err| blk: {
                slog.warn("Failed to spawn price-fetch worker: {}", .{err});
                break :blk null;
            };
        }
        priceFetchWorker(&ctx);
        for (threads[0..background_workers]) |maybe_t| {
            if (maybe_t) |t| t.join();
        }
    }

    const json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = results }, .{}) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(json);
    const json_z = allocator.dupeZ(u8, json) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(json_z);

    e.returnString(json_z);
}

/// Single discovered EVE client, paired with its process creation time for sorting.
const ClientEntry = struct {
    name: []const u8,
    /// FILETIME as u64 (100-ns intervals since 1601-01-01). 0 means unknown.
    creation_time: u64,
};

/// Scanner context used by the EnumWindows callback to collect EVE client entries.
const ClientScanContext = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ClientEntry),
};

/// Returns the character name from an EVE client window's title ("EVE - CharacterName"), or null
/// if hwnd isn't a visible window of the "trinityWindow" class or has no " - " separator.
fn matchEveClientTitle(hwnd: win32.HWND, title_buf: *[512:0]u8) ?[]const u8 {
    if (win32.IsWindowVisible(hwnd) == 0) return null;

    var class_name: [64:0]u8 = undefined;
    const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
    if (class_len <= 0) return null;
    const class_slice = class_name[0..@intCast(class_len)];
    if (!std.mem.eql(u8, class_slice, "trinityWindow")) return null;

    const title_len = win32.GetWindowTextA(hwnd, title_buf, title_buf.len);
    if (title_len <= 0) return null;
    const title_slice = title_buf[0..@intCast(title_len)];

    const dash_pos = std.mem.indexOf(u8, title_slice, " - ") orelse return null;
    const char_name = title_slice[dash_pos + 3 ..];
    if (char_name.len == 0) return null;
    return char_name;
}

/// EnumWindows callback that collects character names + process creation times.
fn enumClientsCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *ClientScanContext = win32.lparamToPtr(ClientScanContext, lParam);

    var title_buf: [512:0]u8 = undefined;
    const char_name = matchEveClientTitle(hwnd, &title_buf) orelse return win32.TRUE;

    // Query process creation time so results can be sorted oldest-first.
    var creation_time: u64 = 0;
    var pid: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != 0) {
        const proc = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid);
        if (proc) |handle| {
            defer _ = win32.CloseHandle(handle);
            var ct: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
            var dummy: win32.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
            if (win32.GetProcessTimes(handle, &ct, &dummy, &dummy, &dummy) != win32.FALSE) {
                creation_time = ct.toU64();
            }
        }
    }

    const name_copy = ctx.allocator.dupe(u8, char_name) catch return win32.TRUE;
    ctx.entries.append(ctx.allocator, .{ .name = name_copy, .creation_time = creation_time }) catch {
        ctx.allocator.free(name_copy);
    };
    return win32.TRUE;
}

/// Scanner context used by findWindowRectCallback to locate one specific character's window.
const WindowRectScanContext = struct {
    target_name: []const u8,
    rect: ?win32.RECT = null,
};

/// EnumWindows callback that captures the rect of the window matching ctx.target_name.
fn findWindowRectCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *WindowRectScanContext = win32.lparamToPtr(WindowRectScanContext, lParam);

    var title_buf: [512:0]u8 = undefined;
    const char_name = matchEveClientTitle(hwnd, &title_buf) orelse return win32.TRUE;
    if (!std.mem.eql(u8, char_name, ctx.target_name)) return win32.TRUE;

    var rect: win32.RECT = undefined;
    if (win32.GetWindowRect(hwnd, &rect) == 0) return win32.TRUE;

    ctx.rect = rect;
    return win32.FALSE;
}

/// Returns `character_name`'s live window's current screen rect, or null if it's not open.
fn findWindowRectByCharacterName(character_name: []const u8) ?win32.RECT {
    var ctx = WindowRectScanContext{ .target_name = character_name };
    _ = win32.EnumWindows(findWindowRectCallback, win32.ptrToLparam(&ctx));
    return ctx.rect;
}

/// Loads the current profile's config, or writes a load-failure JSON response and returns null.
fn loadCurrentProfileOrRespond(e: *webui.Event, allocator: std.mem.Allocator) ?config_mod.Config {
    const profile_name = currentProfileFilename();
    return config_mod.Config.loadProfile(allocator, profile_name) catch |err| {
        slog.err("Failed to load config profile '{s}': {}", .{ profile_name, err });
        e.returnString("{\"success\": false, \"error\": \"Failed to load profile\"}");
        return null;
    };
}

/// Saves `character_name`'s live window's current position as its saved game-window position.
fn setCharacterWindowPosition(e: *webui.Event) void {
    const character_name = e.getString();
    const allocator = gpa.allocator();

    slog.debug("setCharacterWindowPosition requested for '{s}'", .{character_name});

    const rect = findWindowRectByCharacterName(character_name) orelse {
        e.returnString("{\"success\": false, \"error\": \"Character is not currently open\"}");
        return;
    };
    const pos = config_mod.Position{ .x = @intCast(rect.left), .y = @intCast(rect.top) };

    var cfg = loadCurrentProfileOrRespond(e, allocator) orelse return;
    defer cfg.deinit();

    cfg.saveCharacterWindowPosition(allocator, character_name, pos) catch |err| {
        slog.err("Failed to save window position for '{s}': {}", .{ character_name, err });
        e.returnString("{\"success\": false, \"error\": \"Failed to save\"}");
        return;
    };

    var buf: [128]u8 = undefined;
    const response = std.fmt.bufPrintZ(&buf, "{{\"success\": true, \"x\": {}, \"y\": {}}}", .{ pos.x, pos.y }) catch {
        e.returnString("{\"success\": true}");
        return;
    };
    e.returnString(response);
}

/// Clears `character_name`'s saved game-window position.
fn clearCharacterWindowPosition(e: *webui.Event) void {
    const character_name = e.getString();
    const allocator = gpa.allocator();

    slog.debug("clearCharacterWindowPosition requested for '{s}'", .{character_name});

    var cfg = loadCurrentProfileOrRespond(e, allocator) orelse return;
    defer cfg.deinit();

    cfg.clearCharacterWindowPosition(allocator, character_name) catch |err| {
        slog.err("Failed to clear window position for '{s}': {}", .{ character_name, err });
        e.returnString("{\"success\": false, \"error\": \"Failed to save\"}");
        return;
    };

    e.returnString("{\"success\": true}");
}

/// Overwrites every character's saved game-window position with `source_character_name`'s live window's current position.
fn setAllCharacterWindowPositions(e: *webui.Event) void {
    const source_character_name = e.getString();
    const allocator = gpa.allocator();

    slog.debug("setAllCharacterWindowPositions requested, source '{s}'", .{source_character_name});

    const rect = findWindowRectByCharacterName(source_character_name) orelse {
        e.returnString("{\"success\": false, \"error\": \"Selected character is not currently open\"}");
        return;
    };
    const pos = config_mod.Position{ .x = @intCast(rect.left), .y = @intCast(rect.top) };

    var cfg = loadCurrentProfileOrRespond(e, allocator) orelse return;
    defer cfg.deinit();

    cfg.saveAllCharacterWindowPositions(allocator, pos) catch |err| {
        slog.err("Failed to save window positions for all characters: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Failed to save\"}");
        return;
    };

    var buf: [128]u8 = undefined;
    const response = std.fmt.bufPrintZ(&buf, "{{\"success\": true, \"x\": {}, \"y\": {}}}", .{ pos.x, pos.y }) catch {
        e.returnString("{\"success\": true}");
        return;
    };
    e.returnString(response);
}

/// Clears every character's saved game-window position.
fn clearAllCharacterWindowPositions(e: *webui.Event) void {
    const allocator = gpa.allocator();

    slog.debug("clearAllCharacterWindowPositions requested", .{});

    var cfg = loadCurrentProfileOrRespond(e, allocator) orelse return;
    defer cfg.deinit();

    cfg.clearAllCharacterWindowPositions(allocator) catch |err| {
        slog.err("Failed to clear window positions for all characters: {}", .{err});
        e.returnString("{\"success\": false, \"error\": \"Failed to save\"}");
        return;
    };

    e.returnString("{\"success\": true}");
}

/// Return a JSON array of character names from open EVE clients, used by the dialog JS to populate character/hotkey-group fields.
fn getOpenClients(e: *webui.Event) void {
    const allocator = gpa.allocator();

    var ctx = ClientScanContext{
        .allocator = allocator,
        .entries = std.ArrayList(ClientEntry).empty,
    };
    defer {
        for (ctx.entries.items) |entry| allocator.free(entry.name);
        ctx.entries.deinit(allocator);
    }

    _ = win32.EnumWindows(enumClientsCallback, win32.ptrToLparam(&ctx));

    // Sort entries by process creation time ascending (oldest first); entries with unknown time (0) fall to the end.
    std.sort.pdq(ClientEntry, ctx.entries.items, {}, struct {
        fn lessThan(_: void, a: ClientEntry, b: ClientEntry) bool {
            if (a.creation_time == 0 and b.creation_time == 0) return false;
            if (a.creation_time == 0) return false;
            if (b.creation_time == 0) return true;
            return a.creation_time < b.creation_time;
        }
    }.lessThan);

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);

    response.append(allocator, '[') catch {
        e.returnString("[]");
        return;
    };

    for (ctx.entries.items, 0..) |entry, i| {
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

/// A distinct (window class, executable) pair found while scanning for the Window Filter picker.
const RunningWindowEntry = struct {
    class_name: []const u8,
    executable_name: []const u8,
    title: []const u8,
};

const RunningWindowScanContext = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(RunningWindowEntry),
};

/// EnumWindows callback that collects one entry per distinct (class, exe) pair from visible top-level windows.
fn enumRunningWindowsCallback(hwnd: win32.HWND, lParam: win32.LPARAM) callconv(.c) win32.BOOL {
    const ctx: *RunningWindowScanContext = win32.lparamToPtr(RunningWindowScanContext, lParam);

    if (win32.IsWindowVisible(hwnd) == 0) return win32.TRUE;

    var title_buf: [512:0]u8 = undefined;
    const title_len = win32.GetWindowTextA(hwnd, &title_buf, title_buf.len);
    if (title_len <= 0) return win32.TRUE;
    const title_slice = title_buf[0..@intCast(title_len)];

    var class_name: [64:0]u8 = undefined;
    const class_len = win32.GetClassNameA(hwnd, &class_name, class_name.len);
    if (class_len <= 0) return win32.TRUE;
    const class_slice = class_name[0..@intCast(class_len)];

    var process_id: win32.DWORD = 0;
    _ = win32.GetWindowThreadProcessId(hwnd, &process_id);
    if (process_id == 0) return win32.TRUE;

    var exe_path: [260:0]u8 = undefined;
    const exe_path_slice = win32.queryProcessExePath(process_id, &exe_path) orelse return win32.TRUE;
    const exe_name = std.fs.path.basename(exe_path_slice);
    if (exe_name.len == 0) return win32.TRUE;

    for (ctx.entries.items) |existing| {
        if (std.mem.eql(u8, existing.class_name, class_slice) and std.ascii.eqlIgnoreCase(existing.executable_name, exe_name)) {
            return win32.TRUE;
        }
    }

    const class_copy = ctx.allocator.dupe(u8, class_slice) catch return win32.TRUE;
    const exe_copy = ctx.allocator.dupe(u8, exe_name) catch {
        ctx.allocator.free(class_copy);
        return win32.TRUE;
    };
    const title_copy = ctx.allocator.dupe(u8, title_slice) catch {
        ctx.allocator.free(class_copy);
        ctx.allocator.free(exe_copy);
        return win32.TRUE;
    };

    ctx.entries.append(ctx.allocator, .{ .class_name = class_copy, .executable_name = exe_copy, .title = title_copy }) catch {
        ctx.allocator.free(class_copy);
        ctx.allocator.free(exe_copy);
        ctx.allocator.free(title_copy);
    };
    return win32.TRUE;
}

fn appendJsonEscaped(allocator: std.mem.Allocator, response: *std.ArrayList(u8), s: []const u8) void {
    const hex_digits = "0123456789abcdef";
    for (s) |c| {
        switch (c) {
            '"' => response.appendSlice(allocator, "\\\"") catch return,
            '\\' => response.appendSlice(allocator, "\\\\") catch return,
            '\n' => response.appendSlice(allocator, "\\n") catch return,
            '\r' => response.appendSlice(allocator, "\\r") catch return,
            '\t' => response.appendSlice(allocator, "\\t") catch return,
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                response.appendSlice(allocator, "\\u00") catch return;
                response.append(allocator, hex_digits[c >> 4]) catch return;
                response.append(allocator, hex_digits[c & 0xF]) catch return;
            },
            else => response.append(allocator, c) catch return,
        }
    }
}

/// Return a JSON array of {class, exe, title} for visible top-level windows, used by the dialog JS to let the user pick a running program for a Window Filter instead of typing class/executable names by hand.
fn getRunningWindows(e: *webui.Event) void {
    const allocator = gpa.allocator();

    var ctx = RunningWindowScanContext{
        .allocator = allocator,
        .entries = std.ArrayList(RunningWindowEntry).empty,
    };
    defer {
        for (ctx.entries.items) |entry| {
            allocator.free(entry.class_name);
            allocator.free(entry.executable_name);
            allocator.free(entry.title);
        }
        ctx.entries.deinit(allocator);
    }

    _ = win32.EnumWindows(enumRunningWindowsCallback, win32.ptrToLparam(&ctx));

    std.sort.pdq(RunningWindowEntry, ctx.entries.items, {}, struct {
        fn lessThan(_: void, a: RunningWindowEntry, b: RunningWindowEntry) bool {
            return std.mem.lessThan(u8, a.executable_name, b.executable_name);
        }
    }.lessThan);

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);

    response.append(allocator, '[') catch {
        e.returnString("[]");
        return;
    };

    for (ctx.entries.items, 0..) |entry, i| {
        if (i > 0) response.append(allocator, ',') catch break;
        response.appendSlice(allocator, "{\"class\":\"") catch break;
        appendJsonEscaped(allocator, &response, entry.class_name);
        response.appendSlice(allocator, "\",\"exe\":\"") catch break;
        appendJsonEscaped(allocator, &response, entry.executable_name);
        response.appendSlice(allocator, "\",\"title\":\"") catch break;
        appendJsonEscaped(allocator, &response, entry.title);
        response.appendSlice(allocator, "\"}") catch break;
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

fn getConfigData(e: *webui.Event) void {
    const allocator = gpa.allocator();
    const response = std.fmt.allocPrintSentinel(allocator,
        \\{{
        \\  "configPath": "{s}",
        \\  "version": "{s}",
        \\  "categories": [
        \\    {{"id": "general", "name": "General"}},
        \\    {{"id": "thumbnails", "name": "Thumbnails"}},
        \\    {{"id": "display", "name": "Display"}},
        \\    {{"id": "hotkeys", "name": "Hotkeys"}},
        \\    {{"id": "colors", "name": "Colors"}},
        \\    {{"id": "states", "name": "Visual States"}},
        \\    {{"id": "notifications", "name": "Notifications"}},
        \\    {{"id": "chatlog", "name": "Chatlog"}},
        \\    {{"id": "characters", "name": "Characters"}}
        \\  ]
        \\}}
    , .{ config_path, build_options.version }, 0) catch {
        e.returnString("{}");
        return;
    };
    defer allocator.free(response);

    e.returnString(response);
}

fn listProfiles(e: *webui.Event) void {
    const allocator = gpa.allocator();

    var profiles = std.ArrayList([]const u8).empty;
    defer {
        for (profiles.items) |profile| {
            allocator.free(profile);
        }
        profiles.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir("profiles", .{ .iterate = true }) catch |err| {
        slog.err("Failed to open profiles directory: {}", .{err});
        e.returnString("{\"profiles\": [], \"current\": \"default.json\"}");
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            if (std.mem.eql(u8, entry.name, "global.settings.json")) {
                continue;
            }
            const profile_name = allocator.dupe(u8, entry.name) catch continue;
            profiles.append(allocator, profile_name) catch continue;
        }
    }

    const current_profile = currentProfileFilename();

    var response = std.ArrayList(u8).empty;
    defer response.deinit(allocator);

    response.appendSlice(allocator, "{\"profiles\": [") catch {
        e.returnString("{\"error\": \"Failed to build response\"}");
        return;
    };

    for (profiles.items, 0..) |profile, i| {
        if (i > 0) {
            response.append(allocator, ',') catch break;
        }
        response.append(allocator, '\"') catch break;
        appendJsonEscaped(allocator, &response, profile);
        response.append(allocator, '\"') catch break;
    }

    response.appendSlice(allocator, "], \"current\": \"") catch {
        e.returnString("{\"error\": \"Failed to build response\"}");
        return;
    };
    appendJsonEscaped(allocator, &response, current_profile);
    response.appendSlice(allocator, "\"}") catch {
        e.returnString("{\"error\": \"Failed to build response\"}");
        return;
    };

    response.append(allocator, 0) catch {
        e.returnString("{\"error\": \"Failed to build response\"}");
        return;
    };
    e.returnString(response.items[0 .. response.items.len - 1 :0]);
}

fn switchProfile(e: *webui.Event) void {
    const profile_name = e.getString();
    slog.debug("Switching to profile: {s}", .{profile_name});

    const allocator = gpa.allocator();
    const new_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{profile_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Failed to allocate path\"}");
        return;
    };

    if (config_path_allocated) |old_path| {
        allocator.free(old_path);
    }

    config_path = new_path;
    config_path_allocated = new_path;

    // Persist as the last used profile so the main app (and this dialog, next
    // time it's opened without a --profile arg) picks it up on restart.
    if (config_mod.GlobalSettings.load(allocator)) |loaded| {
        var settings = loaded;
        defer settings.deinit();
        settings.updateLastUsed(profile_name) catch |err| {
            slog.warn("Failed to persist last used profile: {}", .{err});
        };
    } else |err| {
        slog.warn("Failed to load global settings for last-used update: {}", .{err});
    }

    slog.debug("Profile switched to: {s}", .{config_path});
    e.returnString("{\"success\": true}");
}

fn createProfile(e: *webui.Event) void {
    const profile_name = e.getString();
    const allocator = gpa.allocator();

    const profile_filename = std.fmt.allocPrint(allocator, "{s}.json", .{profile_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(profile_filename);

    const profile_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{profile_filename}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(profile_path);

    const file = std.fs.cwd().openFile(profile_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            var defaults = config_mod.Config.getDefaultsWithProfile(allocator, profile_filename) catch {
                e.returnString("{\"success\": false, \"error\": \"Failed to create defaults\"}");
                return;
            };
            defer defaults.deinit();

            config_mod.Config.saveToJsonFile(&defaults, allocator, profile_path) catch {
                e.returnString("{\"success\": false, \"error\": \"Failed to save profile\"}");
                return;
            };

            e.returnString("{\"success\": true}");
            return;
        }
        e.returnString("{\"success\": false, \"error\": \"Failed to check file\"}");
        return;
    };
    file.close();

    e.returnString("{\"success\": false, \"error\": \"Profile already exists\"}");
}

fn copyProfile(e: *webui.Event) void {
    const json_str = e.getString();
    const allocator = gpa.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        e.returnString("{\"success\": false, \"error\": \"Invalid JSON\"}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        e.returnString("{\"success\": false, \"error\": \"Expected JSON object\"}");
        return;
    }

    const source_val = root.object.get("source") orelse {
        e.returnString("{\"success\": false, \"error\": \"Missing source\"}");
        return;
    };
    if (source_val != .string) {
        e.returnString("{\"success\": false, \"error\": \"Missing source\"}");
        return;
    }
    const source_name = source_val.string;

    const target_val = root.object.get("target") orelse {
        e.returnString("{\"success\": false, \"error\": \"Missing target\"}");
        return;
    };
    if (target_val != .string) {
        e.returnString("{\"success\": false, \"error\": \"Missing target\"}");
        return;
    }
    const target_name = target_val.string;

    const source_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{source_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(source_path);

    const target_filename = std.fmt.allocPrint(allocator, "{s}.json", .{target_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(target_filename);

    const target_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{target_filename}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(target_path);

    const check_file = std.fs.cwd().openFile(target_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.fs.cwd().copyFile(source_path, std.fs.cwd(), target_path, .{}) catch {
                e.returnString("{\"success\": false, \"error\": \"Failed to copy file\"}");
                return;
            };

            e.returnString("{\"success\": true}");
            return;
        }
        e.returnString("{\"success\": false, \"error\": \"Failed to check target file\"}");
        return;
    };
    check_file.close();

    e.returnString("{\"success\": false, \"error\": \"Target profile already exists\"}");
}

fn deleteProfile(e: *webui.Event) void {
    const profile_name = e.getString();
    const allocator = gpa.allocator();

    if (std.mem.eql(u8, profile_name, "default.json")) {
        e.returnString("{\"success\": false, \"error\": \"Cannot delete default profile\"}");
        return;
    }

    const profile_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{profile_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(profile_path);

    std.fs.cwd().deleteFile(profile_path) catch |err| {
        const error_msg = std.fmt.allocPrint(allocator, "{{\"success\": false, \"error\": \"Failed to delete: {}\"}}", .{err}) catch {
            e.returnString("{\"success\": false, \"error\": \"Failed to delete profile\"}");
            return;
        };
        defer allocator.free(error_msg);
        const error_msg_z = allocator.dupeZ(u8, error_msg) catch {
            e.returnString("{\"success\": false, \"error\": \"Failed to delete profile\"}");
            return;
        };
        defer allocator.free(error_msg_z);
        e.returnString(error_msg_z);
        return;
    };

    e.returnString("{\"success\": true}");
}

fn resetProfile(e: *webui.Event) void {
    const profile_name = e.getString();
    const allocator = gpa.allocator();

    const profile_path = std.fmt.allocPrint(allocator, "profiles/{s}", .{profile_name}) catch {
        e.returnString("{\"success\": false, \"error\": \"Memory allocation failed\"}");
        return;
    };
    defer allocator.free(profile_path);

    var defaults = config_mod.Config.getDefaultsWithProfile(allocator, profile_name) catch {
        e.returnString("{\"success\": false, \"error\": \"Failed to create defaults\"}");
        return;
    };
    defer defaults.deinit();

    config_mod.Config.saveToJsonFile(&defaults, allocator, profile_path) catch {
        e.returnString("{\"success\": false, \"error\": \"Failed to save profile\"}");
        return;
    };

    e.returnString("{\"success\": true}");
}

fn browseDirAndReturn(e: *webui.Event, title: []const u8) void {
    const allocator = gpa.allocator();

    const selected_path = showFolderPicker(allocator, title) catch {
        e.returnString("");
        return;
    };

    if (selected_path) |path| {
        defer allocator.free(path);
        const path_z = allocator.dupeZ(u8, path) catch {
            e.returnString("");
            return;
        };
        defer allocator.free(path_z);
        e.returnString(path_z);
    } else {
        e.returnString("");
    }
}

fn browseChatlogDir(e: *webui.Event) void {
    browseDirAndReturn(e, "Select Chatlog Directory");
}

fn browseGamelogDir(e: *webui.Event) void {
    browseDirAndReturn(e, "Select Gamelog Directory");
}

/// Bound to config_dialog.js's window.onerror/unhandledrejection handlers and its
/// logError()/logWarn() wrappers around console.error/console.warn, so JS-side
/// failures land in eve-maj.log next to everything else instead of only being
/// visible in the (normally hidden) webview devtools console.
fn logClientMessage(e: *webui.Event) void {
    const level = e.getStringAt(0);
    const message = e.getStringAt(1);

    if (std.mem.eql(u8, level, "warn")) {
        slog.warn("[js] {s}", .{message});
    } else {
        slog.err("[js] {s}", .{message});
    }
}

const windows = std.os.windows;

const CLSID_FileOpenDialog = windows.GUID{
    .Data1 = 0xDC1C5A9C,
    .Data2 = 0xE88A,
    .Data3 = 0x4dde,
    .Data4 = [8]u8{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
};

const IID_IFileOpenDialog = windows.GUID{
    .Data1 = 0xD57C7288,
    .Data2 = 0xD4AD,
    .Data3 = 0x4768,
    .Data4 = [8]u8{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
};

const FOS_PICKFOLDERS: u32 = 0x00000020;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) c_long;
extern "ole32" fn CoUninitialize() callconv(.c) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const windows.GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const windows.GUID,
    ppv: *?*anyopaque,
) callconv(.c) c_long;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.c) void;

const IFileOpenDialog = extern struct {
    vtable: *const IFileOpenDialogVtbl,

    const IFileOpenDialogVtbl = extern struct {
        QueryInterface: *const fn (*IFileOpenDialog, *const windows.GUID, *?*anyopaque) callconv(.c) c_long,
        AddRef: *const fn (*IFileOpenDialog) callconv(.c) u32,
        Release: *const fn (*IFileOpenDialog) callconv(.c) u32,
        Show: *const fn (*IFileOpenDialog, ?windows.HWND) callconv(.c) c_long,
        SetFileTypes: *const fn (*IFileOpenDialog, u32, ?*const anyopaque) callconv(.c) c_long,
        SetFileTypeIndex: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        GetFileTypeIndex: *const fn (*IFileOpenDialog, *u32) callconv(.c) c_long,
        Advise: *const fn (*IFileOpenDialog, ?*anyopaque, *u32) callconv(.c) c_long,
        Unadvise: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        SetOptions: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        GetOptions: *const fn (*IFileOpenDialog, *u32) callconv(.c) c_long,
        SetDefaultFolder: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
        SetFolder: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
        GetFolder: *const fn (*IFileOpenDialog, *?*anyopaque) callconv(.c) c_long,
        GetCurrentSelection: *const fn (*IFileOpenDialog, *?*anyopaque) callconv(.c) c_long,
        SetFileName: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        GetFileName: *const fn (*IFileOpenDialog, *[*:0]u16) callconv(.c) c_long,
        SetTitle: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        SetOkButtonLabel: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        SetFileNameLabel: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.c) c_long,
        AddPlace: *const fn (*IFileOpenDialog, ?*anyopaque, u32) callconv(.c) c_long,
        SetDefaultExtension: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        Close: *const fn (*IFileOpenDialog, c_long) callconv(.c) c_long,
        SetClientGuid: *const fn (*IFileOpenDialog, *const windows.GUID) callconv(.c) c_long,
        ClearClientData: *const fn (*IFileOpenDialog) callconv(.c) c_long,
        SetFilter: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
    };

    fn release(self: *IFileOpenDialog) void {
        _ = self.vtable.Release(self);
    }

    fn setOptions(self: *IFileOpenDialog, options: u32) c_long {
        return self.vtable.SetOptions(self, options);
    }

    fn setTitle(self: *IFileOpenDialog, title: [*:0]const u16) c_long {
        return self.vtable.SetTitle(self, title);
    }

    fn show(self: *IFileOpenDialog, hwnd: ?windows.HWND) c_long {
        return self.vtable.Show(self, hwnd);
    }

    fn getResult(self: *IFileOpenDialog) ?*IShellItem {
        var result: ?*IShellItem = null;
        const hr = self.vtable.GetResult(self, &result);
        if (hr < 0) return null;
        return result;
    }
};

const IShellItem = extern struct {
    vtable: *const IShellItemVtbl,

    const IShellItemVtbl = extern struct {
        QueryInterface: *const fn (*IShellItem, *const windows.GUID, *?*anyopaque) callconv(.c) c_long,
        AddRef: *const fn (*IShellItem) callconv(.c) u32,
        Release: *const fn (*IShellItem) callconv(.c) u32,
        BindToHandler: *const fn (*IShellItem, ?*anyopaque, *const windows.GUID, *const windows.GUID, *?*anyopaque) callconv(.c) c_long,
        GetParent: *const fn (*IShellItem, *?*IShellItem) callconv(.c) c_long,
        GetDisplayName: *const fn (*IShellItem, u32, *[*:0]u16) callconv(.c) c_long,
        GetAttributes: *const fn (*IShellItem, u32, *u32) callconv(.c) c_long,
        Compare: *const fn (*IShellItem, *IShellItem, u32, *i32) callconv(.c) c_long,
    };

    fn release(self: *IShellItem) void {
        _ = self.vtable.Release(self);
    }

    fn getDisplayName(self: *IShellItem, sigdnName: u32) ?[*:0]u16 {
        var name: [*:0]u16 = undefined;
        const hr = self.vtable.GetDisplayName(self, sigdnName, &name);
        if (hr < 0) return null;
        return name;
    }
};

fn showFolderPicker(allocator: std.mem.Allocator, title: []const u8) !?[]const u8 {
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    // 0x00000001 is S_FALSE (already initialized), which is OK.
    if (hr < 0 and hr != 0x00000001) {
        return error.ComInitFailed;
    }
    defer CoUninitialize();

    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    var dialog_ptr: ?*anyopaque = null;
    const create_hr = CoCreateInstance(
        &CLSID_FileOpenDialog,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IFileOpenDialog,
        &dialog_ptr,
    );

    if (create_hr < 0 or dialog_ptr == null) {
        return error.CreateDialogFailed;
    }

    const dialog: *IFileOpenDialog = @ptrCast(@alignCast(dialog_ptr.?));
    defer dialog.release();

    _ = dialog.setOptions(FOS_PICKFOLDERS);

    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, title);
    defer allocator.free(title_w);
    _ = dialog.setTitle(title_w.ptr);

    const show_hr = dialog.show(null);
    if (show_hr < 0) {
        return null;
    }

    const result_item = dialog.getResult() orelse return null;
    defer result_item.release();

    const path_w = result_item.getDisplayName(SIGDN_FILESYSPATH) orelse return null;
    defer CoTaskMemFree(path_w);

    const path_len = std.mem.indexOfSentinel(u16, 0, path_w);
    const path_slice = path_w[0..path_len :0];
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_slice);

    return path;
}

/// Read icon.ico from disk and build a base64 data-URI <link> favicon tag.
fn loadFaviconTag(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile("icon.ico", .{});
    defer file.close();

    const icon_data = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(icon_data);

    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(icon_data.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, icon_data);

    return std.fmt.allocPrint(
        allocator,
        "<link rel=\"icon\" type=\"image/x-icon\" href=\"data:image/x-icon;base64,{s}\">",
        .{encoded},
    );
}

/// Caller owns the returned slice. Builds `{"en":"English",...}` from every SupportedLang variant so the language dropdown never drifts from `catalogFor`.
fn buildLangListJson(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');
    inline for (std.meta.fields(SupportedLang), 0..) |field, i| {
        if (i != 0) try buf.append(allocator, ',');
        const lang: SupportedLang = @enumFromInt(field.value);
        const entry = try std.fmt.allocPrint(allocator, "\"{s}\":\"{s}\"", .{ field.name, lang.displayName() });
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Caller owns the returned slice. Builds `{"en":{...catalog...},...}` so the browser can switch languages instantly client-side without a reload.
fn buildAllCatalogsJson(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '{');
    inline for (std.meta.fields(SupportedLang), 0..) |field, i| {
        if (i != 0) try buf.append(allocator, ',');
        const lang: SupportedLang = @enumFromInt(field.value);
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, field.name);
        try buf.appendSlice(allocator, "\":");
        try buf.appendSlice(allocator, lang.catalog());
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

fn injectResources(allocator: std.mem.Allocator, lang: SupportedLang) ![:0]u8 {
    var html = try allocator.dupe(u8, config_html);

    const css_placeholder = "/* Styles will be injected here by WebUI */";
    if (std.mem.indexOf(u8, html, css_placeholder)) |_| {
        allocator.free(html);
        html = try std.mem.replaceOwned(u8, allocator, config_html, css_placeholder, config_css);
    }

    const js_placeholder = "// Script will be injected here by WebUI";
    if (std.mem.indexOf(u8, html, js_placeholder)) |_| {
        const temp = html;
        html = try std.mem.replaceOwned(u8, allocator, temp, js_placeholder, config_js);
        allocator.free(temp);
    }

    const favicon_placeholder = "<!-- Favicon will be injected here by WebUI -->";
    if (std.mem.indexOf(u8, html, favicon_placeholder)) |_| {
        if (loadFaviconTag(allocator)) |favicon_tag| {
            defer allocator.free(favicon_tag);
            const temp = html;
            html = try std.mem.replaceOwned(u8, allocator, temp, favicon_placeholder, favicon_tag);
            allocator.free(temp);
        } else |err| {
            slog.warn("Failed to load icon.ico for favicon: {}", .{err});
        }
    }

    const catalog_placeholder = "window.__I18N__ = {}; /* Translations will be injected here by WebUI */";
    if (std.mem.indexOf(u8, html, catalog_placeholder)) |_| {
        const replacement = try std.fmt.allocPrint(allocator, "window.__I18N__ = {s};", .{lang.catalog()});
        defer allocator.free(replacement);
        const temp = html;
        html = try std.mem.replaceOwned(u8, allocator, temp, catalog_placeholder, replacement);
        allocator.free(temp);
    }

    const langs_placeholder = "window.__I18N_LANGS__ = {}; /* Language list will be injected here by WebUI */";
    if (std.mem.indexOf(u8, html, langs_placeholder)) |_| {
        const langs_json = try buildLangListJson(allocator);
        defer allocator.free(langs_json);
        const replacement = try std.fmt.allocPrint(allocator, "window.__I18N_LANGS__ = {s};", .{langs_json});
        defer allocator.free(replacement);
        const temp = html;
        html = try std.mem.replaceOwned(u8, allocator, temp, langs_placeholder, replacement);
        allocator.free(temp);
    }

    const all_catalogs_placeholder = "window.__I18N_ALL__ = {}; /* All translations will be injected here by WebUI */";
    if (std.mem.indexOf(u8, html, all_catalogs_placeholder)) |_| {
        const all_catalogs_json = try buildAllCatalogsJson(allocator);
        defer allocator.free(all_catalogs_json);
        const replacement = try std.fmt.allocPrint(allocator, "window.__I18N_ALL__ = {s};", .{all_catalogs_json});
        defer allocator.free(replacement);
        const temp = html;
        html = try std.mem.replaceOwned(u8, allocator, temp, all_catalogs_placeholder, replacement);
        allocator.free(temp);
    }

    const html_lang_placeholder = "<html lang=\"en\" class=\"pre-init\">";
    if (std.mem.indexOf(u8, html, html_lang_placeholder)) |_| {
        const replacement = try std.fmt.allocPrint(allocator, "<html lang=\"{s}\" class=\"pre-init\">", .{@tagName(lang)});
        defer allocator.free(replacement);
        const temp = html;
        html = try std.mem.replaceOwned(u8, allocator, temp, html_lang_placeholder, replacement);
        allocator.free(temp);
    }

    const result = try allocator.dupeZ(u8, html);
    allocator.free(html);
    return result;
}
