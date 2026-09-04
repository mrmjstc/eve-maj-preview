const std = @import("std");
const win32 = @import("win32.zig");
const http_client = @import("http_client.zig");
const log = @import("log.zig");
const build_options = @import("build_options");
const slog = log.scoped("update");

var g_io: std.Io = undefined;

/// Must be called once before any update-checking function is used.
pub fn setIo(io: std.Io) void {
    g_io = io;
}

/// Mutex-guarded holder for the latest known update result, written by the background check thread and read by the tray menu on the main thread.
pub const UpdateStatus = struct {
    mutex: std.Io.Mutex = .init,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    /// Release notes body from the GitHub API; null if the release had none.
    notes: ?[]const u8 = null,
    allocator: ?std.mem.Allocator = null,

    /// Stores a fresh update result, freeing any previous one first; copies `version`/`url`/`notes` rather than taking ownership of the passed-in slices.
    pub fn set(self: *UpdateStatus, allocator: std.mem.Allocator, version: []const u8, url: []const u8, notes: ?[]const u8) !void {
        const version_copy = try allocator.dupe(u8, version);
        errdefer allocator.free(version_copy);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        const notes_copy = if (notes) |n| try allocator.dupe(u8, n) else null;
        errdefer if (notes_copy) |n| allocator.free(n);

        try self.mutex.lock(g_io);
        defer self.mutex.unlock(g_io);
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

    pub fn deinit(self: *UpdateStatus) void {
        self.mutex.lock(g_io) catch return;
        defer self.mutex.unlock(g_io);
        self.freeLocked();
        self.version = null;
        self.url = null;
        self.notes = null;
    }

    pub fn isAvailable(self: *UpdateStatus) bool {
        self.mutex.lock(g_io) catch return false;
        defer self.mutex.unlock(g_io);
        return self.version != null;
    }

    /// Copies the stored release URL, null-terminated, into `buf`; returns null if no update is available or the URL doesn't fit.
    pub fn copyUrlZ(self: *UpdateStatus, buf: []u8) ?[:0]const u8 {
        self.mutex.lock(g_io) catch return null;
        defer self.mutex.unlock(g_io);
        const url = self.url orelse return null;
        if (url.len >= buf.len) return null;
        @memcpy(buf[0..url.len], url);
        buf[url.len] = 0;
        return buf[0..url.len :0];
    }

    /// Copies the stored latest version, null-terminated, into `buf`; returns null if no update is available or the version doesn't fit.
    pub fn copyVersionZ(self: *UpdateStatus, buf: []u8) ?[:0]const u8 {
        self.mutex.lock(g_io) catch return null;
        defer self.mutex.unlock(g_io);
        const version = self.version orelse return null;
        if (version.len >= buf.len) return null;
        @memcpy(buf[0..version.len], version);
        buf[version.len] = 0;
        return buf[0..version.len :0];
    }

    /// Returns an allocator-owned copy of the stored release notes (caller frees); null if unavailable, since notes are unbounded unlike the other fixed-buffer fields.
    pub fn dupeNotes(self: *UpdateStatus, allocator: std.mem.Allocator) ?[]const u8 {
        self.mutex.lock(g_io) catch return null;
        defer self.mutex.unlock(g_io);
        const notes = self.notes orelse return null;
        return allocator.dupe(u8, notes) catch null;
    }
};

/// Global update state (see UpdateStatus doc comment).
pub var g_update_status: UpdateStatus = .{};

pub const UpdateChecker = struct {
    allocator: std.mem.Allocator,
    current_version: []const u8,

    pub fn init(allocator: std.mem.Allocator) UpdateChecker {
        return UpdateChecker{
            .allocator = allocator,
            .current_version = build_options.version,
        };
    }

    pub fn deinit(self: *UpdateChecker) void {
        _ = self;
        g_update_status.deinit();
    }

    pub fn checkForUpdates(self: *UpdateChecker) !?UpdateInfo {
        slog.info("Checking for updates (current: {s})", .{self.current_version});

        var client: std.http.Client = .{ .allocator = self.allocator, .io = g_io };
        defer client.deinit();

        const body = http_client.fetch(self.allocator, &client, "https://api.github.com/repos/mrmjstc/eve-maj-preview/releases/latest", .{
            .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
        }) orelse return null;
        defer self.allocator.free(body);

        slog.debug("GitHub API response: {s}", .{body});

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        );
        defer parsed.deinit();

        if (parsed.value != .object) {
            slog.debug("GitHub API response is not a JSON object", .{});
            return null;
        }
        const root = parsed.value.object;

        // Check for GitHub API errors (e.g., private repo, rate limit, 404)
        if (root.get("message")) |message| {
            if (message == .string) {
                slog.debug("GitHub API returned error: {s} (this is normal for private repos)", .{message.string});
                return null;
            }
        }

        const tag_name = root.get("tag_name") orelse {
            slog.debug("No tag_name in GitHub API response", .{});
            return null;
        };
        const html_url = root.get("html_url") orelse {
            slog.debug("No html_url in GitHub API response", .{});
            return null;
        };
        if (tag_name != .string or html_url != .string) {
            slog.debug("tag_name/html_url in GitHub API response are not strings", .{});
            return null;
        }

        const latest_version = tag_name.string;
        const release_url = html_url.string;
        const release_notes = if (root.get("body")) |body_value|
            (if (body_value == .string) body_value.string else null)
        else
            null;

        const normalized_current = if (std.mem.startsWith(u8, self.current_version, "v"))
            self.current_version[1..]
        else
            self.current_version;

        const normalized_latest = if (std.mem.startsWith(u8, latest_version, "v"))
            latest_version[1..]
        else
            latest_version;

        if (std.mem.eql(u8, normalized_current, normalized_latest)) {
            slog.info("Already on latest version: {s}", .{self.current_version});
            return null;
        }

        const current_semver = std.SemanticVersion.parse(normalized_current) catch {
            slog.warn("Failed to parse current version: {s}", .{normalized_current});
            return null;
        };

        const latest_semver = std.SemanticVersion.parse(normalized_latest) catch {
            slog.warn("Failed to parse latest version: {s}", .{normalized_latest});
            return null;
        };

        const order = current_semver.order(latest_semver);
        if (order == .lt) {
            slog.info("Update available: {s} -> {s}", .{ self.current_version, latest_version });
            return UpdateInfo{
                .version = try self.allocator.dupe(u8, latest_version),
                .url = try self.allocator.dupe(u8, release_url),
                .notes = if (release_notes) |n| try self.allocator.dupe(u8, n) else null,
            };
        }

        slog.info("Current version is up to date or newer", .{});
        return null;
    }

    pub fn checkForUpdatesBackground(allocator: std.mem.Allocator) void {
        var checker = UpdateChecker.init(allocator);

        const update_info = checker.checkForUpdates() catch |err| {
            slog.warn("Update check failed: {}", .{err});
            return;
        };

        if (update_info) |info| {
            defer allocator.free(info.version);
            defer allocator.free(info.url);
            defer if (info.notes) |n| allocator.free(n);

            g_update_status.set(allocator, info.version, info.url, info.notes) catch |err| {
                slog.warn("Failed to store update status: {}", .{err});
                return;
            };
            slog.info("Update available stored: {s}", .{info.version});
        }
    }
};

pub const UpdateInfo = struct {
    version: []const u8,
    url: []const u8,
    notes: ?[]const u8,
};

pub fn openReleasesPage() void {
    var url_buffer: [512]u8 = undefined;
    const url = g_update_status.copyUrlZ(&url_buffer) orelse "https://github.com/mrmjstc/eve-maj-preview/releases";

    slog.info("Opening releases page: {s}", .{url});

    if (!win32.shellOpen(url.ptr, null)) {
        slog.err("Failed to open URL in browser", .{});
    }
}
