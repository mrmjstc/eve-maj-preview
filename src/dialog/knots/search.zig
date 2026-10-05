//! The footer's settings search: an index of each tab's section text, built by drawing every tab once out of sight, and which sections match; main thread only.
const std = @import("std");
const log = @import("../../log.zig");

const slog = log.scoped("dialog_knots");

/// One section's searchable text: its heading, hint, labels and hints, lowercased.
const Entry = struct {
    tab: usize,
    id: u64,
    /// Owned; freed in clearIndex.
    text: std.ArrayList(u8) = .empty,
};

var g_allocator: std.mem.Allocator = undefined;
/// The search box's text. Owned; freed in reset.
pub var g_query: std.ArrayList(u8) = .empty;
var g_entries: std.ArrayList(Entry) = .empty;
var g_is_indexed: bool = false;
/// The tab being drawn for the index, while it's being built.
var g_capture_tab: ?usize = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    clearIndex();
    g_query.deinit(g_allocator);
    g_query = .empty;
}

/// The trimmed query, empty while there's no search.
pub fn query() []const u8 {
    return std.mem.trim(u8, g_query.items, " ");
}

pub fn isActive() bool {
    return query().len > 0;
}

/// Each search starts from a fresh index, so names and sections added since show up.
pub fn beginFrame() void {
    if (!isActive() and g_is_indexed) clearIndex();
}

pub fn needsIndex() bool {
    return isActive() and !g_is_indexed;
}

pub fn clear() void {
    g_query.clearRetainingCapacity();
}

pub fn beginCapture(tab: usize) void {
    g_capture_tab = tab;
}

pub fn endIndex() void {
    g_capture_tab = null;
    g_is_indexed = true;
}

pub fn isCapturing() bool {
    return g_capture_tab != null;
}

/// From widgets.openSection while the index is built: what's captured next belongs to this section.
pub fn captureSection(id: u64) void {
    const tab = g_capture_tab orelse return;
    g_entries.append(g_allocator, .{ .tab = tab, .id = id }) catch |err| {
        slog.warn("Failed to index a section for search: {}", .{err});
    };
}

/// From the widgets that draw a section's text while the index is built.
pub fn captureText(text: []const u8) void {
    if (g_capture_tab == null or g_entries.items.len == 0) return;
    const entry = &g_entries.items[g_entries.items.len - 1];
    entry.text.ensureUnusedCapacity(g_allocator, text.len + 1) catch |err| {
        slog.warn("Failed to index a section for search: {}", .{err});
        return;
    };
    for (text) |byte| entry.text.appendAssumeCapacity(std.ascii.toLower(byte));
    entry.text.appendAssumeCapacity('\n');
}

/// Shown while there's no search, or it matches; a section the index never saw stays shown.
pub fn sectionMatches(id: u64) bool {
    if (!isActive() or !g_is_indexed) return true;
    for (g_entries.items) |*entry| {
        if (entry.id == id) return matches(entry);
    }
    return true;
}

pub fn tabHasMatches(tab: usize) bool {
    if (!isActive() or !g_is_indexed) return true;
    for (g_entries.items) |*entry| {
        if (entry.tab == tab and matches(entry)) return true;
    }
    return false;
}

/// The first tab, in sidebar order, with a matching section.
pub fn firstMatchingTab() ?usize {
    var first: ?usize = null;
    for (g_entries.items) |*entry| {
        if (!matches(entry)) continue;
        first = if (first) |current| @min(current, entry.tab) else entry.tab;
    }
    return first;
}

pub fn matchCount() usize {
    var count: usize = 0;
    for (g_entries.items) |*entry| {
        if (matches(entry)) count += 1;
    }
    return count;
}

fn matches(entry: *const Entry) bool {
    return std.ascii.findIgnoreCase(entry.text.items, query()) != null;
}

fn clearIndex() void {
    for (g_entries.items) |*entry| entry.text.deinit(g_allocator);
    g_entries.clearAndFree(g_allocator);
    g_is_indexed = false;
}
