//! Chat and game log monitoring settings.
const std = @import("std");
const log = @import("../log.zig");
const wire = @import("wire.zig");
const ranges_mod = @import("ranges.zig");
const files = @import("files.zig");

const slog = log.scoped("config");

pub const ChatlogConfig = struct {
    enabled: bool = false,
    chatlogDir: []const u8 = "",
    gamelogDir: []const u8 = "",
    pollIntervalMs: u32 = 500,
    idlePollThreshold: u32 = 600,
    maxPollMultiplier: u8 = 2,
    useThreading: bool = true,

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
                    slog.warn("Chatlog directory '{s}' does not exist or is not accessible: {}", .{ self.chatlogDir, err });
                };
            }

            if (self.gamelogDir.len == 0) {
                slog.warn("Chatlog monitoring enabled but gamelogDir is empty", .{});
            } else {
                std.Io.Dir.cwd().access(files.g_io, self.gamelogDir, .{}) catch |err| {
                    slog.warn("Gamelog directory '{s}' does not exist or is not accessible: {}", .{ self.gamelogDir, err });
                };
            }
        }
    }

    pub const Wire = wire.Wire(ChatlogConfig);

    /// Expands %VAR% references in the log directories.
    pub fn fromWire(w: Wire, allocator: std.mem.Allocator) !ChatlogConfig {
        var cfg = try wire.fromWire(ChatlogConfig, w, allocator);
        errdefer wire.deinit(ChatlogConfig, &cfg, allocator);
        try expandDirInPlace(allocator, &cfg.chatlogDir);
        try expandDirInPlace(allocator, &cfg.gamelogDir);
        return cfg;
    }

    fn expandDirInPlace(allocator: std.mem.Allocator, dir: *[]const u8) !void {
        const expanded = try files.expandEnvironmentVariables(allocator, dir.*);
        allocator.free(dir.*);
        dir.* = expanded;
    }
};
