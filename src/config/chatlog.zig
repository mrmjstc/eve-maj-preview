//! Chat and game log monitoring settings.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const files = @import("files.zig");
const log = @import("../log.zig");

const slog = log.Scoped("config");

pub const ChatlogConfig = struct {
    enabled: bool = false,
    chatlogDir: []const u8 = "",
    gamelogDir: []const u8 = "",
    pollIntervalMs: u32 = 500,
    idlePollThreshold: u32 = 600,
    maxPollMultiplier: u8 = 2,

    pub const ranges = .{
        .pollIntervalMs = .{ 100, 5000 },
        .idlePollThreshold = .{ 1, 1000 },
        .maxPollMultiplier = .{ 1, 8 },
    };

    pub fn validate(self: *ChatlogConfig) void {
        ranges_mod.clamp(ChatlogConfig, self);

        if (self.enabled) {
            if (self.chatlogDir.len == 0) {
                slog.warn("Chatlog monitoring enabled but chatlogDir is empty", .{});
            } else {
                std.Io.Dir.cwd().access(files.g_io, self.chatlogDir, .{}) catch |err| {
                    slog.warn("Failed to access chatlog directory '{s}': {}", .{ self.chatlogDir, err });
                };
            }

            if (self.gamelogDir.len == 0) {
                slog.warn("Chatlog monitoring enabled but gamelogDir is empty", .{});
            } else {
                std.Io.Dir.cwd().access(files.g_io, self.gamelogDir, .{}) catch |err| {
                    slog.warn("Failed to access gamelog directory '{s}': {}", .{ self.gamelogDir, err });
                };
            }
        }
    }

    pub const Wire = wire.Wire(ChatlogConfig);

    /// Expands %VAR% references in the log directories; an empty one gets EVE's default, which depends on the machine so can't be a field default.
    pub fn fromWire(saved: Wire, allocator: std.mem.Allocator) !ChatlogConfig {
        var config = try wire.fromWire(ChatlogConfig, saved, allocator);
        errdefer wire.deinit(ChatlogConfig, &config, allocator);
        replaceDir(allocator, &config.chatlogDir, try files.expandEnvironmentVariables(allocator, config.chatlogDir));
        replaceDir(allocator, &config.gamelogDir, try files.expandEnvironmentVariables(allocator, config.gamelogDir));

        if (config.chatlogDir.len == 0 or config.gamelogDir.len == 0) {
            const documents_dir = try documentsDir(allocator);
            defer allocator.free(documents_dir);
            if (config.chatlogDir.len == 0) replaceDir(allocator, &config.chatlogDir, try allocator.print("{s}/EVE/logs/Chatlogs", .{documents_dir}));
            if (config.gamelogDir.len == 0) replaceDir(allocator, &config.gamelogDir, try allocator.print("{s}/EVE/logs/Gamelogs", .{documents_dir}));
        }
        return config;
    }

    fn replaceDir(allocator: std.mem.Allocator, dir: *[]const u8, new_dir: []const u8) void {
        allocator.free(dir.*);
        dir.* = new_dir;
    }
};

/// Asks the shell rather than assuming %USERPROFILE%/Documents, which OneDrive can redirect; EVE logs to wherever this resolves.
fn documentsDir(allocator: std.mem.Allocator) ![]u8 {
    const dir = win32.getKnownFolderPath(allocator, win32.FOLDERID_Documents) catch |err| blk: {
        slog.warn("Failed to resolve the Documents folder, falling back to USERPROFILE/Documents: {}", .{err});
        const user_profile = files.environmentVariable("USERPROFILE") orelse {
            slog.warn("Failed to read USERPROFILE", .{});
            return error.MissingEnvironmentVariable;
        };
        break :blk try allocator.print("{s}/Documents", .{user_profile});
    };
    std.mem.replaceScalar(u8, dir, '\\', '/');
    return dir;
}
