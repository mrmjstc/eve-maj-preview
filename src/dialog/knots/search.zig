//! The header's settings search: an index of each tab's section text, built by drawing every tab once out of sight, and which sections match; main thread only.
const std = @import("std");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

/// One section's searchable text: its heading, hint, labels and hints, lowercased.
const Entry = struct {
    tab: usize,
    id: u64,
    /// Owned; freed in clearIndex.
    text: std.ArrayList(u8) = .empty,
};

pub const Search = struct {
    allocator: std.mem.Allocator,
    /// The search box's text; owned, freed in deinit.
    query_text: std.ArrayList(u8) = .empty,
    /// Owned; freed in clearIndex.
    entries: std.ArrayList(Entry) = .empty,
    is_indexed: bool = false,
    /// The tab being drawn for the index, while it's being built.
    capture_tab: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Search {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Search) void {
        self.clearIndex();
        self.query_text.deinit(self.allocator);
    }

    /// The trimmed query, empty while there's no search.
    pub fn query(self: *const Search) []const u8 {
        return std.mem.trim(u8, self.query_text.items, " ");
    }

    pub fn isActive(self: *const Search) bool {
        return self.query().len > 0;
    }

    /// Each search starts from a fresh index, so names and sections added since show up.
    pub fn beginFrame(self: *Search) void {
        if (!self.isActive() and self.is_indexed) self.clearIndex();
    }

    pub fn needsIndex(self: *const Search) bool {
        return self.isActive() and !self.is_indexed;
    }

    pub fn beginCapture(self: *Search, tab: usize) void {
        self.capture_tab = tab;
    }

    pub fn endIndex(self: *Search) void {
        self.capture_tab = null;
        self.is_indexed = true;
    }

    /// From widgets.openSection while the index is built: what's captured next belongs to this section.
    pub fn captureSection(self: *Search, id: u64) void {
        const tab = self.capture_tab orelse return;
        self.entries.append(self.allocator, .{ .tab = tab, .id = id }) catch |err| {
            slog.warn("Failed to index a section for search: {}", .{err});
        };
    }

    /// From the widgets that draw a section's text while the index is built.
    pub fn captureText(self: *Search, text: []const u8) void {
        if (self.capture_tab == null or self.entries.items.len == 0) return;
        const entry = &self.entries.items[self.entries.items.len - 1];
        entry.text.ensureUnusedCapacity(self.allocator, text.len + 1) catch |err| {
            slog.warn("Failed to index a section for search: {}", .{err});
            return;
        };
        for (text) |byte| entry.text.appendAssumeCapacity(std.ascii.toLower(byte));
        entry.text.appendAssumeCapacity('\n');
    }

    /// Shown while there's no search, or it matches; a section the index never saw stays shown.
    pub fn sectionMatches(self: *const Search, id: u64) bool {
        if (!self.isActive() or !self.is_indexed) return true;
        for (self.entries.items) |*entry| {
            if (entry.id == id) return self.matches(entry);
        }
        return true;
    }

    pub fn tabHasMatches(self: *const Search, tab: usize) bool {
        if (!self.isActive() or !self.is_indexed) return true;
        for (self.entries.items) |*entry| {
            if (entry.tab == tab and self.matches(entry)) return true;
        }
        return false;
    }

    /// The first tab, in sidebar order, with a matching section.
    pub fn firstMatchingTab(self: *const Search) ?usize {
        var first: ?usize = null;
        for (self.entries.items) |*entry| {
            if (!self.matches(entry)) continue;
            first = if (first) |current| @min(current, entry.tab) else entry.tab;
        }
        return first;
    }

    pub fn matchCount(self: *const Search) usize {
        var count: usize = 0;
        for (self.entries.items) |*entry| {
            if (self.matches(entry)) count += 1;
        }
        return count;
    }

    fn matches(self: *const Search, entry: *const Entry) bool {
        return std.ascii.findIgnoreCase(entry.text.items, self.query()) != null;
    }

    fn clearIndex(self: *Search) void {
        for (self.entries.items) |*entry| entry.text.deinit(self.allocator);
        self.entries.clearAndFree(self.allocator);
        self.is_indexed = false;
    }
};
