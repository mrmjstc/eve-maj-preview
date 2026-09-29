//! Chat and game log monitoring settings.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const files = @import("files.zig");
const log = @import("../log.zig");

const slog = log.scoped("config");

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
        .maxPollMultiplier = .{ 1, 32 },
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
    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !ChatlogConfig {
        var cfg = try wire.fromWire(ChatlogConfig, w, allocator);
        errdefer wire.deinit(ChatlogConfig, &cfg, allocator);
        replaceDir(allocator, &cfg.chatlogDir, try files.expandEnvironmentVariables(allocator, cfg.chatlogDir));
        replaceDir(allocator, &cfg.gamelogDir, try files.expandEnvironmentVariables(allocator, cfg.gamelogDir));

        if (cfg.chatlogDir.len == 0 or cfg.gamelogDir.len == 0) {
            const documents_dir = try documentsDir(allocator);
            defer allocator.free(documents_dir);
            if (cfg.chatlogDir.len == 0) replaceDir(allocator, &cfg.chatlogDir, try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Chatlogs", .{documents_dir}));
            if (cfg.gamelogDir.len == 0) replaceDir(allocator, &cfg.gamelogDir, try std.fmt.allocPrint(allocator, "{s}/EVE/logs/Gamelogs", .{documents_dir}));
        }
        return cfg;
    }

    fn replaceDir(allocator: std.mem.Allocator, dir: *[]const u8, new_dir: []const u8) void {
        allocator.free(dir.*);
        dir.* = new_dir;
    }
};

const FOLDERID_Documents = win32.GUID{
    .Data1 = 0xFDD39AD0,
    .Data2 = 0x238F,
    .Data3 = 0x46AF,
    .Data4 = [8]u8{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 },
};

/// Asks the shell rather than assuming %USERPROFILE%/Documents, which OneDrive can redirect; EVE logs to wherever this resolves.
fn documentsDir(allocator: std.mem.Allocator) ![]u8 {
    const dir = win32.getKnownFolderPath(allocator, FOLDERID_Documents) catch |err| blk: {
        slog.warn("Failed to resolve the Documents folder, falling back to USERPROFILE/Documents: {}", .{err});
        const userprofile = files.g_environ_map.get("USERPROFILE") orelse {
            slog.warn("USERPROFILE environment variable not found", .{});
            return error.MissingEnvironmentVariable;
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}/Documents", .{userprofile});
    };
    std.mem.replaceScalar(u8, dir, '\\', '/');
    return dir;
}
