//! The Import Settings dialog: reading another preview tool's file or an EVE-Maj profile, choosing its sections and where they go, and restoring a profile backup; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../config.zig");
const files = @import("../../config/files.zig");
const importer = @import("../../config/import/importer.zig");
const session = @import("session.zig");
const host = @import("host.zig");
const header = @import("header.zig");
const lang = @import("lang.zig");
const profiles = @import("profiles.zig");
const status = @import("status.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Dialog = ui.component.Dialog;
const TextInput = ui.component.TextInput;
const SelectInput = ui.component.SelectInput;
const ColorPicker = ui.component.ColorPicker;
const slog = log.scoped("dialog_knots");

const FILE_HINT = "Select an old EVE-X Preview (.json), EVE-O Preview (.json), or EVE-APM Preview (.ini) file, or an EVE-Maj Preview profile (.json) \u{2014} format is detected automatically. Nothing is saved until you review and click Save.";
const MAX_FILE_SIZE = 4 * 1024 * 1024;

const Section = struct {
    id: []const u8,
    title: []const u8,
    hint: []const u8,
    available: bool,
    is_chosen: bool,
};

/// What the app found in the file; everything borrows from g_arena.
const Analysis = struct {
    format: []const u8,
    profiles: []const []const u8,
    source_index: u32,
    sections: []Section,
};

const Summary = struct {
    notes: []const []const u8,
    skipped: []const []const u8,
};

var g_allocator: std.mem.Allocator = undefined;
var g_is_open: bool = false;
/// Holds the file, the analysis, the backups and the summary; reset each time the dialog opens.
var g_arena: std.heap.ArenaAllocator = undefined;
var g_file_text: ?[]const u8 = null;
var g_file_name: []const u8 = "";
/// Under the Browse button: reading, what was detected, or why it failed.
var g_file_status: []const u8 = "";
var g_analysis: ?Analysis = null;
var g_into_new: bool = false;
/// Owned; freed in reset.
var g_new_name: std.ArrayList(u8) = .empty;
var g_new_accent: ui.Color = undefined;
var g_summary: ?Summary = null;
var g_backups: []const []const u8 = &.{};
var g_backup_index: u32 = 0;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_arena = .init(allocator);
}

/// Once the window has closed.
pub fn reset() void {
    g_is_open = false;
    clearArena();
    g_arena.deinit();
    g_new_name.deinit(g_allocator);
    g_new_name = .empty;
}

pub fn open() void {
    clearArena();
    g_into_new = false;
    g_new_name.clearRetainingCapacity();
    g_new_accent = widgets.colorFromArgb(header.DEFAULT_ACCENT);
    g_backup_index = 0;
    const names = config.listProfileBackups(arena()) catch |err| blk: {
        slog.warn("Failed to list profile backups: {}", .{err});
        break :blk std.ArrayList([]const u8).empty;
    };
    g_backups = names.items;
    g_is_open = true;
}

/// From the file picker, between frames.
pub fn loadFile(path: []const u8) void {
    if (!g_is_open) return;
    g_analysis = null;
    g_summary = null;
    readFile(path) catch |err| {
        slog.err("Failed to read settings file '{s}': {}", .{ path, err });
        g_file_status = "Failed to read or parse the file.";
        return;
    };
    analyze(null);
}

fn readFile(path: []const u8) !void {
    g_file_text = try std.Io.Dir.cwd().readFileAlloc(files.g_io, path, arena(), .limited(MAX_FILE_SIZE));
    g_file_name = try arena().dupe(u8, std.fs.path.basename(path));
}

pub fn show(context: *ui.Frame) !void {
    // Cleared a frame after closing, not on the frame that closes it: that frame's text still borrows from the arena until it's drawn.
    if (!g_is_open) return clearArena();
    const dialog = Dialog{ .is_open = &g_is_open, .key = .src(@src()), .style = &style.modal_wide };
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Import Settings", .style = &style.heading });
    if (g_summary) |summary| {
        try summaryView(context, summary);
    } else {
        try fileStep(context);
        if (g_analysis) |*analysis| try optionsStep(context, analysis);
    }
    try buttons(context);
    try dialog.close(context);
}

fn fileStep(context: *ui.Frame) !void {
    try widgets.paragraph(context, .src(@src()), FILE_HINT);
    const row = Rect{ .key = .src(@src()), .style = &style.inline_row };
    _ = try row.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Choose File...", .style = &style.plain_button })).clicked) host.browseImportFile();
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = g_file_name, .style = &style.detail_value });
    try row.close(context);
    if (g_file_status.len > 0) try widgets.paragraph(context, .src(@src()), g_file_status);

    if (g_backups.len == 0) return;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Restore from backup", .style = &style.inline_label });
    const backup_row = Rect{ .key = .src(@src()), .style = &style.inline_row };
    _ = try backup_row.open(context);
    const labels = try context.arena().alloc([]const u8, g_backups.len);
    const values = try context.arena().alloc(u32, g_backups.len);
    for (g_backups, labels, values, 0..) |name, *label, *value, index| {
        label.* = try backupLabel(context.arena(), name);
        value.* = @intCast(index);
    }
    const response = try context.interact(SelectInput(u32){ .key = .src(@src()), .labels = labels, .values = values, .initial_selected = g_backup_index, .style = &style.select_fill, .parts = .{ .popup = &style.select_popup } });
    if (response.selected) |selected| g_backup_index = selected.value;
    if ((try context.interact(Button{ .key = .src(@src()), .label = "Restore", .style = &style.primary_button })).clicked) {
        const backup = g_backups[g_backup_index];
        g_is_open = false;
        host.restoreBackup(backup, backupDisplayName(backup));
    }
    try backup_row.close(context);
}

/// "Main" from "1717171717_Main.json", a backup's timestamp and name.
fn backupDisplayName(file_name: []const u8) []const u8 {
    const stem = profiles.displayName(file_name);
    const underscore = std.mem.findScalar(u8, stem, '_') orelse return stem;
    for (stem[0..underscore]) |char| {
        if (!std.ascii.isDigit(char)) return stem;
    }
    return stem[underscore + 1 ..];
}

/// The name and, where the file name has one, when the backup was made.
fn backupLabel(arena_allocator: std.mem.Allocator, file_name: []const u8) ![]const u8 {
    const stem = profiles.displayName(file_name);
    const name = backupDisplayName(file_name);
    if (name.len == stem.len) return name;
    // A prefix too long for a timestamp gets no date rather than a wrong one.
    const seconds = std.fmt.parseInt(u64, stem[0 .. stem.len - name.len - 1], 10) catch return name;
    const day = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = day.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = day.getDaySeconds();
    return std.fmt.allocPrint(arena_allocator, "{s} \u{2014} {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        name,
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
    });
}

fn optionsStep(context: *ui.Frame, analysis: *Analysis) !void {
    if (analysis.profiles.len > 1) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = "Old profile to import from", .style = &style.inline_label });
        const values = try context.arena().alloc(u32, analysis.profiles.len);
        for (values, 0..) |*value, index| value.* = @intCast(index);
        const response = try context.interact(SelectInput(u32){ .key = .src(@src()), .labels = analysis.profiles, .values = values, .initial_selected = analysis.source_index, .style = &style.select_fill, .parts = .{ .popup = &style.select_popup } });
        if (response.selected) |selected| {
            if (selected.value != analysis.source_index) {
                // An EVE-X file's profiles each have their own sections.
                analyze(analysis.profiles[selected.value]);
                context.requestRedraw();
                return;
            }
        }
    }

    try widgets.subheading(context, .src(@src()), "Import into");
    const editing = profiles.displayName(session.profile().ptr.profile_name);
    var into_current = !g_into_new;
    if (try widgets.checkbox(context, .src(@src()), try std.fmt.allocPrint(context.arena(), "Current profile ({s})", .{editing}), &into_current)) g_into_new = false;
    var into_new = g_into_new;
    if (try widgets.checkbox(context, .src(@src()), "New profile", &into_new)) g_into_new = true;
    if (g_into_new) {
        const row = Rect{ .key = .src(@src()), .style = &style.inline_row };
        _ = try row.open(context);
        try context.e(TextInput{ .key = .str("knots.import.new_name"), .buf = &g_new_name, .style = &style.text_input, .placeholder = "New profile name" });
        _ = try context.interact(ColorPicker{ .key = .src(@src()), .value = &g_new_accent, .style = &style.color_picker_swatch, .parts = .{ .swatch = &style.color_swatch_fill, .popup = &style.color_popup }, .show_hex = false, .show_alpha = false });
        try row.close(context);
    }

    try widgets.subheading(context, .src(@src()), "Sections to import");
    for (analysis.sections, 0..) |*section, index| {
        // knots has no tooltips, so the hint sits beside the title.
        const item = try widgets.openGroup(context, ui.Key.str("knots.import.section").indexed(index), section.available);
        const row = Rect{ .key = ui.Key.str("knots.import.section.row").indexed(index), .style = &style.inline_row };
        _ = try row.open(context);
        _ = try widgets.checkbox(context, ui.Key.str("knots.import.section.check").indexed(index), section.title, &section.is_chosen);
        const hint = if (section.available) section.hint else "Nothing to import for this section";
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.import.section.hint").indexed(index), .content = hint, .style = &style.hint_inline });
        try row.close(context);
        try item.close(context);
    }
}

fn summaryView(context: *ui.Frame, summary: Summary) !void {
    try widgets.paragraph(context, .src(@src()), "Import complete");
    const arena_allocator = context.arena();
    if (summary.skipped.len > 0) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try std.fmt.allocPrint(arena_allocator, "{d} setting(s) couldn't be read and were left unchanged:", .{summary.skipped.len}), .style = &style.status_failure });
        for (summary.skipped, 0..) |path, index| {
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.import.skipped").indexed(index), .content = try std.fmt.allocPrint(arena_allocator, "\u{2022} {s}", .{path}), .style = &style.muted_text });
        }
    }
    for (summary.notes, 0..) |note, index| {
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.import.note").indexed(index), .content = try std.fmt.allocPrint(arena_allocator, "\u{2022} {s}", .{note}), .style = &style.modal_text });
    }
    try widgets.paragraph(context, .src(@src()), "Review the affected tabs, then click Save to keep these changes.");
}

fn buttons(context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try row.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = if (g_summary == null) "Cancel" else "Done", .style = &style.outline_button })).clicked) {
        g_is_open = false;
        context.requestRedraw();
    }
    if (g_summary == null) {
        const can_import = g_analysis != null;
        if ((try context.interact(Button{ .key = .src(@src()), .label = "Import", .disabled = !can_import, .style = if (can_import) &style.primary_button else &style.disabled_button })).clicked and can_import) runImport();
    }
    try row.close(context);
}

/// Into the profile being edited now, or into a new one once the header's profile action has created it and switched the window to it.
fn runImport() void {
    if (!g_into_new) {
        applyImport();
        return;
    }
    const name = std.mem.trim(u8, g_new_name.items, " ");
    if (name.len == 0) {
        status.show(.failure, "Enter a valid name for the new profile", .{});
        return;
    }
    host.importIntoNewProfile(name, widgets.argbFromColor(g_new_accent));
}

/// Applies the chosen sections to the profile the window edits; called again by the header's action once a new profile exists.
pub fn applyImport() void {
    applyChosen() catch |err| {
        slog.err("Failed to import settings: {}", .{err});
        status.show(.failure, "Import failed: {t}", .{err});
    };
}

fn applyChosen() !void {
    const text = g_file_text orelse return;
    const analysis = g_analysis orelse return;
    var chosen: std.ArrayList([]const u8) = .empty;
    for (analysis.sections) |section| {
        if (section.available and section.is_chosen) try chosen.append(arena(), section.id);
    }
    const source: ?[]const u8 = if (analysis.profiles.len > 0) analysis.profiles[analysis.source_index] else null;
    const built = try importer.build(arena(), text, source, chosen.items, "Cycle Group {n}", session.profile().ptr);
    try session.applyOps(arena(), built.ops);
    const notes = try arena().alloc([]const u8, built.notes.len);
    for (built.notes, notes) |note, *out| out.* = try translate(arena(), note);
    g_summary = .{ .notes = notes, .skipped = built.skipped };
}

/// Reads the file with the app's importer, which replies in JSON.
fn analyze(source_profile: ?[]const u8) void {
    analyzeFile(source_profile) catch |err| {
        slog.err("Failed to read settings file '{s}': {}", .{ g_file_name, err });
        g_analysis = null;
        g_file_status = "Failed to read or parse the file.";
    };
}

fn analyzeFile(source_profile: ?[]const u8) !void {
    const text = g_file_text orelse return;
    const allocator = arena();
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try importer.analyze(&jw, allocator, text, g_file_name, source_profile);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, allocator, out.written(), .{});
    const format = stringAt(root, "format") orelse {
        g_file_status = "Unrecognized settings file.";
        return;
    };
    var profile_names: std.ArrayList([]const u8) = .empty;
    var source_index: u32 = 0;
    if (root.object.get("profiles")) |list| {
        if (list == .array) for (list.array.items) |item| {
            if (item != .string) continue;
            if (stringAt(root, "sourceProfile")) |chosen| {
                if (std.mem.eql(u8, chosen, item.string)) source_index = @intCast(profile_names.items.len);
            }
            try profile_names.append(allocator, item.string);
        };
    }
    var sections: std.ArrayList(Section) = .empty;
    if (root.object.get("sections")) |list| {
        if (list == .array) for (list.array.items) |item| {
            const available = if (item.object.get("available")) |flag| flag == .bool and flag.bool else false;
            const title = stringAt(item, "title") orelse "";
            try sections.append(allocator, .{
                .id = stringAt(item, "id") orelse continue,
                .title = lang.text(title, title),
                .hint = if (item.object.get("hint")) |hint| try translateValue(allocator, hint) else "",
                .available = available,
                .is_chosen = available,
            });
        };
    }
    if (g_new_name.items.len == 0 or source_profile != null) {
        g_new_name.clearRetainingCapacity();
        try g_new_name.appendSlice(g_allocator, stringAt(root, "defaultName") orelse "Imported");
    }
    g_analysis = .{ .format = format, .profiles = profile_names.items, .source_index = source_index, .sections = sections.items };
    g_file_status = if (std.mem.eql(u8, format, "maj"))
        "Detected EVE-Maj Preview profile file."
    else if (std.mem.eql(u8, format, "evex"))
        try std.fmt.allocPrint(allocator, "Detected EVE-X Preview settings file - loaded {d} profile(s).", .{profile_names.items.len})
    else if (std.mem.eql(u8, format, "eveo"))
        "Detected EVE-O Preview settings file."
    else
        "Detected EVE-APM Preview settings file.";
}

fn stringAt(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// A note in words: its key's English text with each {param} filled in, translating the ones that are keys themselves.
fn translate(allocator: std.mem.Allocator, note: importer.Text) ![]const u8 {
    var out: []const u8 = try allocator.dupe(u8, lang.text(note.key, note.key));
    for (note.params) |param| {
        const value = if (param.translate) lang.text(param.value, param.value) else param.value;
        out = try replace(allocator, out, param.name, value);
    }
    return out;
}

/// The same for a section hint, which arrives as the analysis JSON's `{key, params}`.
fn translateValue(allocator: std.mem.Allocator, hint: std.json.Value) ![]const u8 {
    const key = stringAt(hint, "key") orelse return "";
    var out: []const u8 = try allocator.dupe(u8, lang.text(key, key));
    if (hint.object.get("params")) |params| {
        if (params == .object) {
            var it = params.object.iterator();
            while (it.next()) |entry| {
                const value = switch (entry.value_ptr.*) {
                    .string => |text| text,
                    .object => if (stringAt(entry.value_ptr.*, "t")) |nested| lang.text(nested, nested) else "",
                    else => "",
                };
                out = try replace(allocator, out, entry.key_ptr.*, value);
            }
        }
    }
    return out;
}

fn replace(allocator: std.mem.Allocator, text: []const u8, name: []const u8, value: []const u8) ![]const u8 {
    const token = try std.fmt.allocPrint(allocator, "{{{s}}}", .{name});
    return std.mem.replaceOwned(u8, allocator, text, token, value);
}

fn arena() std.mem.Allocator {
    return g_arena.allocator();
}

fn clearArena() void {
    _ = g_arena.reset(.free_all);
    g_file_text = null;
    g_file_name = "";
    g_file_status = "";
    g_analysis = null;
    g_summary = null;
    g_backups = &.{};
}
