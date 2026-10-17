//! Checking GitHub for a newer release, and the result the tray menu and config dialog show.
const std = @import("std");
const build_options = @import("build_options");
const win32 = @import("platform/win32.zig");
const http_client = @import("util/http_client.zig");
const log = @import("log.zig");

const slog = log.Scoped("update");

/// Written by the background check thread, read on the main thread.
pub const UpdateStatus = struct {
    mutex: std.Io.Mutex = .init,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    /// Combined release notes for every release newer than the installed version (each prefixed with its tag name); null if none had notes.
    notes: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,

    /// Copies its arguments rather than taking ownership of them.
    pub fn set(self: *UpdateStatus, io: std.Io, allocator: std.mem.Allocator, version: []const u8, url: []const u8, notes: ?[]const u8) !void {
        const version_copy = try allocator.dupe(u8, version);
        errdefer allocator.free(version_copy);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        const notes_copy = if (notes) |n| try allocator.dupe(u8, n) else null;
        errdefer if (notes_copy) |n| allocator.free(n);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.freeLocked();
        self.version = version_copy;
        self.url = url_copy;
        self.notes = notes_copy;
        self.allocator = allocator;
    }

    fn freeLocked(self: *UpdateStatus) void {
        const allocator = self.allocator orelse return;
        if (self.version) |v| allocator.free(v);
        if (self.url) |u| allocator.free(u);
        if (self.notes) |n| allocator.free(n);
    }

    pub fn deinit(self: *UpdateStatus, io: std.Io) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        self.freeLocked();
        self.version = null;
        self.url = null;
        self.notes = null;
    }

    pub fn isAvailable(self: *UpdateStatus, io: std.Io) bool {
        self.mutex.lock(io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return false;
        };
        defer self.mutex.unlock(io);
        return self.version != null;
    }

    /// Null if no update is available or the URL doesn't fit in `buf`.
    pub fn copyUrlZ(self: *UpdateStatus, io: std.Io, buf: []u8) ?[:0]const u8 {
        return self.copyFieldZ(io, "url", buf);
    }

    /// Null if no update is available or the version doesn't fit in `buf`.
    pub fn copyVersionZ(self: *UpdateStatus, io: std.Io, buf: []u8) ?[:0]const u8 {
        return self.copyFieldZ(io, "version", buf);
    }

    fn copyFieldZ(self: *UpdateStatus, io: std.Io, comptime field: []const u8, buf: []u8) ?[:0]const u8 {
        self.mutex.lock(io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(io);
        const value = @field(self, field) orelse return null;
        if (value.len >= buf.len) return null;
        @memcpy(buf[0..value.len], value);
        buf[value.len] = 0;
        return buf[0..value.len :0];
    }

    /// Caller frees; allocated rather than copied into a buffer, since notes are unbounded.
    pub fn dupeNotes(self: *UpdateStatus, io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
        self.mutex.lock(io) catch |err| {
            slog.warn("Failed to lock update status mutex: {}", .{err});
            return null;
        };
        defer self.mutex.unlock(io);
        const notes = self.notes orelse return null;
        return allocator.dupe(u8, notes) catch |err| {
            slog.warn("Failed to copy the release notes: {}", .{err});
            return null;
        };
    }
};

/// Strings come from checkForUpdates' allocator; the caller frees each one.
const UpdateInfo = struct {
    version: []const u8,
    url: []const u8,
    notes: ?[]const u8,
};

pub var g_update_status: UpdateStatus = .{};

/// The update check thread's entry point; stores what it finds in g_update_status.
pub fn checkForUpdatesBackground(allocator: std.mem.Allocator, io: std.Io) void {
    const update_info = checkForUpdates(allocator) catch |err| {
        slog.warn("Failed to check for updates: {}", .{err});
        return;
    };

    if (update_info) |info| {
        defer allocator.free(info.version);
        defer allocator.free(info.url);
        defer if (info.notes) |n| allocator.free(n);

        g_update_status.set(io, allocator, info.version, info.url, info.notes) catch |err| {
            slog.warn("Failed to store update status: {}", .{err});
            return;
        };
        slog.info("Update available stored: {s}", .{info.version});
    }
}

pub fn openReleasesPage(io: std.Io) void {
    var url_buffer: [512]u8 = undefined;
    const url = g_update_status.copyUrlZ(io, &url_buffer) orelse "https://github.com/mrmjstc/eve-maj-preview/releases";

    slog.info("Opening releases page: {s}", .{url});

    if (!win32.shellOpen(url.ptr, null)) {
        slog.err("Failed to open '{s}' in the browser", .{url});
    }
}

fn checkForUpdates(allocator: std.mem.Allocator) !?UpdateInfo {
    const current_version = build_options.version;
    slog.info("Checking for updates (current: {s})", .{current_version});

    var session = try http_client.Session.init();
    defer session.deinit();

    // per_page=100 covers skipping many releases at once; unauthenticated requests only ever see published (non-draft) releases anyway.
    const body = try session.fetch(allocator, "https://api.github.com/repos/mrmjstc/eve-maj-preview/releases?per_page=100", .{
        .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
    });
    defer allocator.free(body);

    slog.debug("GitHub API response: {s}", .{body});

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{},
    );
    defer parsed.deinit();

    if (parsed.value != .array) {
        slog.warn("Failed to check for updates: the response isn't a JSON array", .{});
        return null;
    }
    const releases = parsed.value.array.items;

    const current_semver = parseTagVersion(current_version) catch |err| {
        slog.warn("Failed to parse current version '{s}': {}", .{ current_version, err });
        return null;
    };

    var latest: ?struct { version: []const u8, url: []const u8 } = null;

    var notes_buf: std.ArrayList(u8) = .empty;
    defer notes_buf.deinit(allocator);

    // GitHub lists releases newest-first, so this walks down from latest until it reaches (or passes) the installed version.
    for (releases) |release_value| {
        if (release_value != .object) continue;
        const release = release_value.object;

        if (release.get("draft")) |d| if (d == .bool and d.bool) continue;
        if (release.get("prerelease")) |p| if (p == .bool and p.bool) continue;

        const tag_name = release.get("tag_name") orelse continue;
        const html_url = release.get("html_url") orelse continue;
        if (tag_name != .string or html_url != .string) continue;

        const release_semver = parseTagVersion(tag_name.string) catch |err| {
            slog.warn("Failed to parse release tag '{s}', skipping it: {}", .{ tag_name.string, err });
            continue;
        };

        if (release_semver.order(current_semver) != .gt) continue;

        if (latest == null) latest = .{ .version = tag_name.string, .url = html_url.string };

        const release_notes = if (release.get("body")) |body_value|
            (if (body_value == .string) body_value.string else null)
        else
            null;

        if (release_notes) |n| {
            const entry = try allocator.print("{s}\n\n{s}", .{ tag_name.string, n });
            defer allocator.free(entry);
            if (notes_buf.items.len > 0) try notes_buf.appendSlice(allocator, "\n\n");
            try notes_buf.appendSlice(allocator, entry);
        }
    }

    const found = latest orelse {
        slog.info("Already on latest version: {s}", .{current_version});
        return null;
    };

    slog.info("Update available: {s} -> {s}", .{ current_version, found.version });
    const version = try allocator.dupe(u8, found.version);
    errdefer allocator.free(version);
    const url = try allocator.dupe(u8, found.url);
    errdefer allocator.free(url);
    const notes = if (notes_buf.items.len > 0) try allocator.dupe(u8, notes_buf.items) else null;
    return .{ .version = version, .url = url, .notes = notes };
}

/// Strips a leading "v" (GitHub tag convention) and parses the rest as semver.
fn parseTagVersion(tag: []const u8) !std.SemanticVersion {
    const normalized = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    return std.SemanticVersion.parse(normalized);
}
