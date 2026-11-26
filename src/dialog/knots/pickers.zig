//! Folder and file pickers, run on a thread of their own since a picker's modal loop on the main thread would stall the input hooks.
const std = @import("std");
const win32 = @import("../../platform/win32.zig");
const lang = @import("../../lang/lang.zig");
const detached = @import("../../util/detached.zig");
const handoff = @import("../../util/handoff.zig");
const messages = @import("../../messages.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

/// Next to the exe; the release scripts, installer and build.zig ship the bundled alert sounds there.
const SOUNDS_FOLDER = "sounds";

pub const Target = enum {
    chatlog_dir,
    gamelog_dir,
    /// A notification type's sound; Picked.index is the type.
    sound_file,
    /// A chat alert rule's sound; Picked.index is the rule.
    rule_sound_file,
    /// A settings file for the Import dialog.
    import_file,
};

/// Waits in `takeAll` until the main thread takes it.
pub const Picked = struct {
    /// The Pickers' allocator, which `path` and the Picked itself came from.
    allocator: std.mem.Allocator,
    target: Target,
    /// Which item the path is for, e.g. the notification type of a sound.
    index: usize,
    /// Owned; freed by the main thread with `deinit`.
    path: []const u8,
    /// The next result, linked by handoff.Stack.
    next: ?*Picked = null,

    pub fn deinit(self: *Picked) void {
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

pub const Pickers = struct {
    /// Read by picker threads too.
    allocator: std.mem.Allocator,
    /// Set while a picker is open, so a second click doesn't stack another; the main thread sets it and the picker's thread clears it.
    is_busy: std.atomic.Value(bool) = .init(false),
    /// Pushed by picker threads, taken by the main thread.
    results: handoff.Stack(Picked) = .{},

    pub fn init(allocator: std.mem.Allocator) Pickers {
        return .{ .allocator = allocator };
    }

    /// Main thread: the paths picked since the last call, oldest first through `next`; the caller deinits each.
    pub fn takeAll(self: *Pickers) ?*Picked {
        return self.results.takeAll();
    }

    /// `timer_hwnd` receives `command` with the result, unless the user cancels; `title` is in English, and shown translated.
    pub fn browse(self: *Pickers, target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) void {
        if (self.is_busy.swap(true, .acq_rel)) return;
        self.startPicker(target, index, title, owner, timer_hwnd, command) catch |err| {
            slog.err("Failed to open the picker: {}", .{err});
            self.is_busy.store(false, .release);
        };
    }

    /// Copies the wording, since the language module is the main thread's.
    fn startPicker(self: *Pickers, target: Target, index: usize, title: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) !void {
        const shown_title = try self.allocator.dupe(u8, lang.text(title));
        errdefer self.allocator.free(shown_title);
        const file_type_name = try self.allocator.dupe(u8, lang.text(fileTypeName(target)));
        errdefer self.allocator.free(file_type_name);
        try detached.spawn(pickerThread, .{ self, target, index, shown_title, file_type_name, owner, timer_hwnd, command });
    }

    /// Owns `title` and `file_type_name`; shares only the allocator, the results and the posted message with the main thread.
    fn pickerThread(self: *Pickers, target: Target, index: usize, title: []const u8, file_type_name: []const u8, owner: ?win32.HWND, timer_hwnd: win32.HWND, command: usize) void {
        defer self.is_busy.store(false, .release);
        defer self.allocator.free(title);
        defer self.allocator.free(file_type_name);
        const shown = switch (target) {
            .chatlog_dir, .gamelog_dir => win32.showFolderPicker(self.allocator, title, owner),
            .sound_file, .rule_sound_file => sound: {
                var sounds_folder_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                break :sound win32.showFilePicker(self.allocator, title, file_type_name, "*.wav;*.mp3", soundsFolderPath(&sounds_folder_buf), owner);
            },
            .import_file => win32.showFilePicker(self.allocator, title, file_type_name, "*.json;*.ini", null, owner),
        };
        const path = shown catch |err| {
            slog.err("Failed to open the picker: {}", .{err});
            return;
        } orelse return;
        const picked = self.allocator.create(Picked) catch |err| {
            slog.err("Failed to pass on the picked path: {}", .{err});
            self.allocator.free(path);
            return;
        };
        picked.* = .{ .allocator = self.allocator, .target = target, .index = index, .path = path };
        self.results.push(picked);
        if (!win32.toBool(win32.PostMessageA(timer_hwnd, messages.WM_KNOTS_COMMAND, command, 0))) {
            slog.err("Failed to pass on the picked path, it waits for the next pick: error {d}", .{win32.GetLastError()});
        }
    }
};

/// Null if the exe's folder can't be found, so the picker opens wherever Windows last left it.
fn soundsFolderPath(buf: []u8) ?[]const u8 {
    var executable_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_dir = win32.selfExecutableDirPath(&executable_dir_buf) catch |err| {
        slog.warn("Failed to resolve the executable directory for the sounds folder: {}", .{err});
        return null;
    };
    return std.mem.print(buf, "{s}\\" ++ SOUNDS_FOLDER, .{executable_dir}) catch |err| {
        slog.warn("Failed to build the sounds folder path under '{s}': {}", .{ executable_dir, err });
        return null;
    };
}

fn fileTypeName(target: Target) []const u8 {
    return switch (target) {
        .chatlog_dir, .gamelog_dir => "",
        .sound_file, .rule_sound_file => "Audio Files (*.wav, *.mp3)",
        .import_file => "Settings Files (*.json, *.ini)",
    };
}
