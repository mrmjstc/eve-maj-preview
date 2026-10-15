//! The Import Settings dialog: reading another preview tool's file or an EVE-Maj profile, and choosing its sections and where they go; main thread only.
const std = @import("std");
const ui = @import("ui");
const importer = @import("../../config/import/importer.zig");
const session = @import("session.zig");
const host = @import("host.zig");
const lang = @import("../../lang/lang.zig");
const profiles = @import("profiles.zig");
const style = @import("style.zig");
const widgets = @import("widgets.zig");
const color_convert = @import("color_convert.zig");
const log = @import("../../log.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Tooltip = ui.component.Tooltip;
const TextInput = ui.component.TextInput;
const SelectInput = ui.component.SelectInput;
const slog = log.Scoped("dialog_knots");

const FILE_HINT = "Select an old EVE-X Preview (.json), EVE-O Preview (.json), or EVE-APM Preview (.ini) file, or an EVE-Maj Preview profile (.json) \u{2014} format is detected automatically.";
const MAX_FILE_BYTES = 4 * 1024 * 1024;
const NEW_NAME_KEY: ui.Key = .str("knots.import.new_name");

/// An EVE-Maj profile's sections under one of the sidebar's headings.
const Group = struct { label: []const u8, ids: []const []const u8 };

/// EVE-Maj profile sections grouped like the sidebar's tabs, by Config field name; a section left out lands in "Other".
const MAJ_GROUPS = [_]Group{
    .{ .label = "Clients", .ids = &.{ "characters", "hotkeyGroups", "windowFilters", "exclusion" } },
    .{ .label = "Display", .ids = &.{ "display", "thumbnail", "thumbnailSpaces", "snapping", "autoMovePosition" } },
    .{ .label = "Input", .ids = &.{ "hotkeys", "interaction", "autoMinimize", "closeAll" } },
    .{ .label = "Alerts", .ids = &.{ "chatlog", "travel", "systemColors" } },
    .{ .label = "Overlays", .ids = &.{ "mining", "combat", "bounty", "resources" } },
    .{ .label = "App", .ids = &.{ "timer", "accentColor" } },
};

const Section = struct {
    id: []const u8,
    title: []const u8,
    hint: []const u8,
    is_available: bool,
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
    section_count: usize,
    /// Warnings about settings that were skipped or need checking.
    notes: []const []const u8,
    skipped: []const []const u8,
    /// The running profile was imported over, so a backup of it was kept.
    has_backup: bool,
};

/// Which sections, available ones only, a list shows: all, one of MAJ_GROUPS, or those no group lists.
const Filter = union(enum) { all, ids: []const []const u8, ungrouped };

var g_allocator: std.mem.Allocator = undefined;
var g_is_open: bool = false;
/// Holds the file, the analysis and the summary; reset each time the dialog opens.
var g_arena: std.heap.ArenaAllocator = undefined;
/// Borrows from g_arena.
var g_file_text: ?[]const u8 = null;
/// Borrows from g_arena.
var g_file_name: []const u8 = "";
/// Under the file row: what was detected, or why it failed; a literal, or borrowed from g_arena.
var g_file_status: []const u8 = "";
var g_analysis: ?Analysis = null;
var g_imports_into_new: bool = false;
/// Set as New Profile is chosen, so the next frame focuses the name field.
var g_should_focus_name: bool = false;
/// Owned; freed in reset.
var g_new_name: std.ArrayList(u8) = .empty;
var g_new_accent: ui.Color = undefined;
/// The rainbow picker chose g_new_accent; see widgets.accentChoices.
var g_is_new_accent_custom: bool = false;
var g_summary: ?Summary = null;

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
    g_imports_into_new = false;
    g_should_focus_name = false;
    g_new_name.clearRetainingCapacity();
    g_new_accent = color_convert.fromArgb(profiles.DEFAULT_ACCENT);
    g_is_new_accent_custom = false;
    g_is_open = true;
}

/// The accent picked for a new profile, previewed on the window while the dialog is open.
pub fn previewAccent() ?u32 {
    if (!g_is_open or !g_imports_into_new or g_summary != null) return null;
    return color_convert.toArgb(g_new_accent);
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

pub fn show(context: *ui.Frame) !void {
    // Cleared the frame after closing: the closing frame's text still borrows from the arena.
    if (!g_is_open) return clearArena();
    const dialog = widgets.modal(.src(@src()), &g_is_open, &style.modal_wide);
    _ = try dialog.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(if (g_summary == null) "Import Settings" else "Settings Imported"), .style = &style.heading });
    if (g_summary) |summary| {
        try summaryView(context, summary);
    } else {
        try fileStep(context);
        if (g_analysis) |*analysis| try optionsStep(context, analysis);
    }
    try buttons(context);
    try dialog.close(context);
}

/// Applies the chosen sections to the running profile, unsaved; called by the profile action once the backup or new profile exists.
pub fn applyImport() !void {
    const text = g_file_text orelse return error.MissingImportFile;
    const analysis = g_analysis orelse return error.MissingImportFile;
    var chosen: std.ArrayList([]const u8) = .empty;
    for (analysis.sections) |section| {
        if (section.is_available and section.is_chosen) try chosen.append(arena(), section.id);
    }
    const source: ?[]const u8 = if (analysis.profiles.len > 0) analysis.profiles[analysis.source_index] else null;
    const built = try importer.build(arena(), text, source, chosen.items, lang.text("Cycle Group {n}"), session.profile().ptr);
    try session.applyOps(arena(), built.ops);
    const notes = try arena().alloc([]const u8, built.notes.len);
    for (built.notes, notes) |note, *out| out.* = try translate(arena(), note);
    g_summary = .{ .section_count = chosen.items.len, .notes = notes, .skipped = built.skipped, .has_backup = !g_imports_into_new };
}

fn readFile(path: []const u8) !void {
    g_file_text = try std.Io.Dir.cwd().readFileAlloc(session.runningApp().io, path, arena(), .limited(MAX_FILE_BYTES));
    g_file_name = try arena().dupe(u8, std.fs.path.basename(path));
}

fn fileStep(context: *ui.Frame) !void {
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(FILE_HINT), .style = &style.modal_text });
    const row = try widgets.openModalFieldRow(context, .src(@src()));
    const has_file = g_file_name.len > 0;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = if (has_file) g_file_name else lang.text("No file chosen"), .style = if (has_file) &style.label_aligned else &style.import_file_none });
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Browse"), .style = &style.plain_button })).clicked) host.browseImportFile();
    try row.close(context);
    if (g_file_status.len > 0) try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text(g_file_status), .style = &style.hint });
}

fn optionsStep(context: *ui.Frame, analysis: *Analysis) !void {
    if (analysis.profiles.len > 1) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Old profile to import from"), .style = &style.inline_label });
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

    const target_row = try widgets.openModalRow(context, .src(@src()), "Import into");
    const running = try std.fmt.allocPrint(context.arena(), "'{s}'", .{profiles.displayName(session.profile().ptr.profile_name)});
    if (try widgets.segmented(context, .src(@src()), &.{ running, "New Profile" }, @intFromBool(g_imports_into_new))) |index| {
        g_imports_into_new = index == 1;
        g_should_focus_name = g_imports_into_new;
        context.requestRedraw();
    }
    try target_row.close(context);
    try widgets.hintText(context, .src(@src()), "New Profile leaves your current settings untouched.");
    if (g_imports_into_new) {
        const name_row = try widgets.openModalRow(context, .src(@src()), "Name");
        if (g_should_focus_name) {
            try widgets.focusTextInput(context, NEW_NAME_KEY, g_new_name.items.len);
            g_should_focus_name = false;
        }
        try context.e(TextInput{ .key = NEW_NAME_KEY, .buf = &g_new_name, .style = &style.text_input_aligned, .placeholder = lang.text("Profile name") });
        try name_row.close(context);
        try widgets.hintText(context, .src(@src()), "Use " ++ profiles.NAME_RULES ++ ".");
        if (profiles.nameProblem(context.arena(), newName())) |message| try widgets.boxedText(context, .src(@src()), message, &style.modal_hint_box, &style.field_error);
        const color_row = try widgets.openModalRow(context, .src(@src()), "Color");
        try widgets.accentChoices(context, .src(@src()), &g_new_accent, &g_is_new_accent_custom);
        try color_row.close(context);
        try widgets.hintText(context, .src(@src()), "Marks it in the profile menu and tints this window.");
    }

    try sectionsHeading(context, analysis.sections);
    const arena_allocator = context.arena();
    if (std.mem.eql(u8, analysis.format, "maj")) {
        for (MAJ_GROUPS, 0..) |group, index| {
            try sectionGroup(context, index, group.label, analysis.sections, try sectionIndices(arena_allocator, analysis.sections, .{ .ids = group.ids }));
        }
        try sectionGroup(context, MAJ_GROUPS.len, "Other", analysis.sections, try sectionIndices(arena_allocator, analysis.sections, .ungrouped));
    } else {
        try sectionGrid(context, .str("knots.import.sections"), &style.import_section_grid, analysis.sections, try sectionIndices(arena_allocator, analysis.sections, .all));
    }
}

fn sectionsHeading(context: *ui.Frame, sections: []Section) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.import_sections_heading };
    _ = try row.open(context);
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Sections to import"), .style = &style.subheading });
    try context.e(Rect{ .key = .src(@src()), .style = &style.spacer });
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("All"), .style = &style.link })).clicked) chooseAll(context, sections, true);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("None"), .style = &style.link })).clicked) chooseAll(context, sections, false);
    try row.close(context);
}

fn chooseAll(context: *ui.Frame, sections: []Section, is_chosen: bool) void {
    for (sections) |*section| {
        if (section.is_available) section.is_chosen = is_chosen;
    }
    context.requestRedraw();
}

/// Indices into `sections`, in their order.
fn sectionIndices(arena_allocator: std.mem.Allocator, sections: []const Section, filter: Filter) ![]const usize {
    var indices: std.ArrayList(usize) = .empty;
    for (sections, 0..) |section, index| {
        if (!section.is_available) continue;
        const is_shown = switch (filter) {
            .all => true,
            .ids => |ids| isListed(ids, section.id),
            .ungrouped => for (MAJ_GROUPS) |group| {
                if (isListed(group.ids, section.id)) break false;
            } else true,
        };
        if (is_shown) try indices.append(arena_allocator, index);
    }
    return indices.items;
}

fn isListed(ids: []const []const u8, id: []const u8) bool {
    for (ids) |listed| {
        if (std.mem.eql(u8, listed, id)) return true;
    }
    return false;
}

/// Ticked while all its sections are, above them; nothing when the file has none.
fn sectionGroup(context: *ui.Frame, group_index: usize, label: []const u8, sections: []Section, indices: []const usize) !void {
    if (indices.len == 0) return;
    const key = ui.Key.str("knots.import.group").indexed(group_index);
    const box = Rect{ .key = key, .style = &style.import_section_group };
    _ = try box.open(context);
    var is_all_chosen = true;
    for (indices) |index| is_all_chosen = is_all_chosen and sections[index].is_chosen;
    if (try widgets.checkbox(context, key.indexed(1), label, &is_all_chosen)) {
        for (indices) |index| sections[index].is_chosen = is_all_chosen;
        context.requestRedraw();
    }
    try sectionGrid(context, key.indexed(2), &style.import_section_grid_grouped, sections, indices);
    try box.close(context);
}

fn sectionGrid(context: *ui.Frame, key: ui.Key, grid_style: *const ui.Style, sections: []Section, indices: []const usize) !void {
    const grid = Rect{ .key = key, .style = grid_style };
    _ = try grid.open(context);
    var position: usize = 0;
    while (position < indices.len) : (position += 2) {
        const pair = Rect{ .key = ui.Key.str("knots.import.section.pair").indexed(indices[position]), .style = &style.import_section_pair };
        _ = try pair.open(context);
        try sectionCheckbox(context, sections, indices[position]);
        if (position + 1 < indices.len) {
            try sectionCheckbox(context, sections, indices[position + 1]);
        } else {
            try context.e(Rect{ .key = ui.Key.str("knots.import.section.filler").indexed(indices[position]), .style = &style.import_section_cell });
        }
        try pair.close(context);
    }
    try grid.close(context);
}

/// Its hint, e.g. how many characters it holds, shows on hover.
fn sectionCheckbox(context: *ui.Frame, sections: []Section, index: usize) !void {
    const section = &sections[index];
    const cell = Rect{ .key = ui.Key.str("knots.import.section.cell").indexed(index), .style = &style.import_section_cell };
    _ = try cell.open(context);
    const tip = Tooltip{ .key = ui.Key.str("knots.import.section.tip").indexed(index), .content = section.hint };
    if (section.hint.len > 0) _ = try tip.open(context);
    _ = try widgets.checkbox(context, ui.Key.str("knots.import.section.check").indexed(index), section.title, &section.is_chosen);
    if (section.hint.len > 0) try tip.close(context);
    try cell.close(context);
}

fn isAnyChosen(sections: []const Section) bool {
    for (sections) |section| {
        if (section.is_available and section.is_chosen) return true;
    }
    return false;
}

fn summaryView(context: *ui.Frame, summary: Summary) !void {
    const arena_allocator = context.arena();
    const saved = try lang.format(arena_allocator, "{n} section(s) imported into '{name}' and saved.", .{ .n = summary.section_count, .name = profiles.displayName(session.profile().ptr.profile_name) });
    const message = if (summary.has_backup)
        try std.fmt.allocPrint(arena_allocator, "{s} {s}", .{ saved, lang.text("Your previous settings were backed up; restore them from the Backups tab if needed.") })
    else
        saved;
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = message, .style = &style.modal_text });
    if (summary.skipped.len > 0) {
        try context.e(Text{ .selectable = false, .key = .src(@src()), .content = try lang.format(arena_allocator, "{n} setting(s) couldn't be read and were left unchanged:", .{ .n = summary.skipped.len }), .style = &style.status_failure });
        for (summary.skipped, 0..) |path, index| {
            try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.import.skipped").indexed(index), .content = try std.fmt.allocPrint(arena_allocator, "\u{2022} {s}", .{path}), .style = &style.muted_text });
        }
    }
    if (summary.notes.len > 0) try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Some settings need your attention:"), .style = &style.status_failure });
    for (summary.notes, 0..) |note, index| {
        try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.import.note").indexed(index), .content = try std.fmt.allocPrint(arena_allocator, "\u{2022} {s}", .{note}), .style = &style.modal_text });
    }
}

fn buttons(context: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &style.modal_actions };
    _ = try row.open(context);
    if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text(if (g_summary == null) "Cancel" else "Done"), .style = &style.outline_button })).clicked) {
        g_is_open = false;
        context.requestRedraw();
    }
    if (g_summary == null) {
        const has_sections = if (g_analysis) |analysis| isAnyChosen(analysis.sections) else false;
        const can_import = has_sections and (!g_imports_into_new or (newName().len > 0 and profiles.nameProblem(context.arena(), newName()) == null));
        if ((try context.interact(Button{ .key = .src(@src()), .label = lang.text("Import"), .disabled = !can_import, .style = if (can_import) &style.primary_button else &style.disabled_primary_button })).clicked and can_import) runImport();
    }
    try row.close(context);
}

/// Through a profile action, since saving can only happen between frames.
fn runImport() void {
    if (!g_imports_into_new) {
        profiles.request(.import_running, session.profile().ptr.profile_name, null);
        return;
    }
    host.importIntoNewProfile(newName(), color_convert.toArgb(g_new_accent));
}

/// Borrows from g_new_name.
fn newName() []const u8 {
    return std.mem.trim(u8, g_new_name.items, " ");
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
    var json_writer: std.json.Stringify = .{ .writer = &out.writer };
    try importer.analyze(&json_writer, allocator, text, g_file_name, source_profile);
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
            if (item != .object) continue;
            const is_available = if (item.object.get("available")) |flag| flag == .bool and flag.bool else false;
            const title = stringAt(item, "title") orelse "";
            try sections.append(allocator, .{
                .id = stringAt(item, "id") orelse continue,
                .title = lang.text(title),
                .hint = if (item.object.get("hint")) |hint| try translateValue(allocator, hint) else "",
                .is_available = is_available,
                .is_chosen = is_available,
            });
        };
    }
    if (g_new_name.items.len == 0 or source_profile != null) {
        g_new_name.clearRetainingCapacity();
        try g_new_name.appendSlice(g_allocator, stringAt(root, "defaultName") orelse lang.text("Imported"));
    }
    g_analysis = .{ .format = format, .profiles = profile_names.items, .source_index = source_index, .sections = sections.items };
    g_file_status = if (std.mem.eql(u8, format, "maj"))
        "Detected EVE-Maj Preview profile file."
    else if (std.mem.eql(u8, format, "evex"))
        try lang.format(allocator, "Detected an EVE-X Preview settings file with {n} profile(s).", .{ .n = profile_names.items.len })
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

/// Translates the English text, filling each {parameter} and translating the marked ones.
fn translate(allocator: std.mem.Allocator, note: importer.Text) ![]const u8 {
    var out: []const u8 = try allocator.dupe(u8, lang.text(note.key));
    for (note.parameters) |parameter| {
        const value = if (parameter.should_translate) lang.text(parameter.value) else parameter.value;
        out = try replace(allocator, out, parameter.name, value);
    }
    return out;
}

/// The same for a section hint, which arrives as the analysis JSON's `{key, params}`.
fn translateValue(allocator: std.mem.Allocator, hint: std.json.Value) ![]const u8 {
    const key = stringAt(hint, "key") orelse return "";
    var out: []const u8 = try allocator.dupe(u8, lang.text(key));
    if (hint.object.get("params")) |parameters| {
        if (parameters == .object) {
            var it = parameters.object.iterator();
            while (it.next()) |entry| {
                const value = switch (entry.value_ptr.*) {
                    .string => |text| text,
                    .object => if (stringAt(entry.value_ptr.*, "t")) |nested| lang.text(nested) else "",
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
}
