//! Where each thumbnail goes: its thumbnail space's grid, its saved position, or the new-thumbnail row.
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../config/types.zig");
const scout = @import("../clients/scout.zig");
const window = @import("../thumbnail/window.zig");
const monitors = @import("monitors.zig");
const region_grid = @import("region_grid.zig");
const spaces = @import("spaces.zig");
const log = @import("../log.zig");

const ThumbnailWindow = window.ThumbnailWindow;
const RegionFitGrid = region_grid.RegionFitGrid;
const RegionFitCap = region_grid.RegionFitCap;
const scalePixels = win32.scalePixels;
const dpiToScale = win32.dpiToScale;
const slog = log.Scoped("layout");

/// One active space's grid for a layout pass; sizes are physical pixels.
pub const SpaceCell = struct {
    region: win32.RECT,
    grid: RegionFitGrid,
    direction: types.RegionFitDirection,
    spacing: i32,

    pub fn position(self: SpaceCell, rank: usize) config_mod.Position {
        return region_grid.regionFitPositionForGrid(self.region, self.grid, rank, self.direction, self.spacing);
    }
};

/// Indexed like thumbnailSpaces; null for an inactive space.
pub const SpaceCells = [spaces.MAX_SPACES]?SpaceCell;

/// Read-only view over what thumbnail placement depends on: config plus the current thumbnail list (for counts and ranks).
pub const Layout = struct {
    config: *const config_mod.Config,
    thumbnails: []const ThumbnailWindow,

    /// Always false for the generic "not logged in" name, which never has a saved position of its own.
    fn hasSavedPosition(self: Layout, character_name: []const u8) bool {
        const display = &self.config.display;
        return !scout.isGenericCharacterName(character_name) and
            display.honorSavedPositions and
            self.config.getCharacterPosition(character_name) != null;
    }

    /// Ranks this thumbnail's slot in the left-to-right spawn row, which only hand-placed thumbnails with no saved position join.
    fn unpositionedIndex(self: Layout, up_to: usize) usize {
        var count: usize = 0;
        for (self.thumbnails[0..@min(up_to, self.thumbnails.len)]) |thumbnail| {
            if (self.hasSavedPosition(thumbnail.character_name)) continue;
            if (spaces.spaceFor(self.config, thumbnail.character_name) != null) continue;
            count += 1;
        }
        return count;
    }

    /// How many current thumbnails each space holds.
    pub fn spaceCounts(self: Layout) spaces.SpaceCounts {
        var counts: spaces.SpaceCounts = @splat(0);
        for (self.thumbnails) |thumbnail| {
            if (spaces.spaceFor(self.config, thumbnail.character_name)) |space_index| counts[space_index] += 1;
        }
        return counts;
    }

    /// Every active space's grid, sized for `counts` cells; the same for every thumbnail in a pass, so compute it once.
    pub fn spaceCells(self: Layout, counts: *const spaces.SpaceCounts) SpaceCells {
        var cells: SpaceCells = @splat(null);
        for (spaces.listed(self.config), 0..) |*space, i| {
            const region = spaces.activeRect(space) orelse continue;
            const grid = region_grid.calculateRegionFitGrid(region, counts[i], space.spacing, space.spacing, self.regionFitAspectRatio(), self.thumbnailSizeCap(region, space.limitToThumbnailSize));
            cells[i] = .{ .region = region, .grid = grid, .direction = space.direction, .spacing = space.spacing };
        }
        return cells;
    }

    /// A hand-placed thumbnail's spot: its saved position, else the next slot in the spawn row.
    pub fn calculateThumbnailPosition(
        self: Layout,
        character_name: []const u8,
        thumbnail_width: i32,
        thumbnail_height: i32,
        index: usize,
        monitor_bounds: ?win32.RECT,
        scale: f32,
    ) config_mod.Position {
        const display = &self.config.display;

        if (self.hasSavedPosition(character_name)) {
            // Saved positions are absolute physical pixels (see saveThumbnailPosition), so scaling doesn't apply.
            const saved_position = self.config.getCharacterPosition(character_name).?;
            slog.debug("Using saved position for {s}: ({}, {})", .{ character_name, saved_position.x, saved_position.y });
            return .{ .x = saved_position.x, .y = saved_position.y };
        }

        // No saved position: flow left-to-right from startX/startY, wrapping to a new row instead of overlapping once a row runs out of width.
        const slot = @as(i32, @intCast(self.unpositionedIndex(index)));
        const step_x = thumbnail_width + scalePixels(display.newThumbnailSpacing, scale);
        const step_y = thumbnail_height + scalePixels(display.newThumbnailSpacing, scale);

        // Monitor bounds if one's configured, otherwise the real current virtual screen, not a guessed multi-monitor range.
        const bounds = monitor_bounds orelse win32.virtualScreenRect();

        // startX/startY are monitor-relative when a monitor is configured, absolute otherwise.
        const start_x = scalePixels(display.startX, scale) + (if (monitor_bounds != null) bounds.left else 0);
        const start_y = scalePixels(display.startY, scale) + (if (monitor_bounds != null) bounds.top else 0);

        const columns_per_row = @max(@divTrunc(bounds.right - start_x, @max(step_x, 1)), 1);
        const row = @divTrunc(slot, columns_per_row);
        const column = @mod(slot, columns_per_row);
        slog.debug("Thumbnail #{} has no saved position, spawning at unpositioned slot {} (row {}, col {})", .{ index, slot, row, column });

        var position = config_mod.Position{ .x = start_x + column * step_x, .y = start_y + row * step_y };

        // Clamp to keep thumbnails from spawning fully off-screen, while still allowing edge placement; only bites once rows also overflow the screen's height.
        const clamp_margin = 50;
        const monitor_suffix = if (monitor_bounds != null) " for monitor" else "";
        clampAxisWithWarn(&position.x, bounds.left - clamp_margin, bounds.right - thumbnail_width + clamp_margin, "X", "left", "right", monitor_suffix);
        clampAxisWithWarn(&position.y, bounds.top - clamp_margin, bounds.bottom - thumbnail_height + clamp_margin, "Y", "up", "down", monitor_suffix);

        return position;
    }

    /// Spaces always keep the configured thumbnail's shape; limitToThumbnailSize additionally caps its absolute size.
    fn regionFitAspectRatio(self: Layout) f32 {
        return @as(f32, @floatFromInt(self.config.thumbnail.width)) / @as(f32, @floatFromInt(self.config.thumbnail.height));
    }

    /// Physical-pixel cap on a space's cell size, DPI-scaled for the space's own monitor (which may differ from the app's configured monitor); null unless `should_limit`.
    fn thumbnailSizeCap(self: Layout, region: win32.RECT, should_limit: bool) ?RegionFitCap {
        if (!should_limit) return null;
        const center = win32.POINT{ .x = @divTrunc(region.left + region.right, 2), .y = @divTrunc(region.top + region.bottom, 2) };
        const scale = dpiToScale(monitors.dpiForMonitor(win32.nearestMonitor(center)));
        return .{ .width = scalePixels(self.config.thumbnail.width, scale), .height = scalePixels(self.config.thumbnail.height, scale) };
    }
};

/// The cell grid this character's space uses, or null when it's placed by hand.
pub fn cellFor(config: *const config_mod.Config, cells: *const SpaceCells, character_name: []const u8) ?SpaceCell {
    const space_index = spaces.spaceFor(config, character_name) orelse return null;
    return cells[space_index];
}

fn clampAxisWithWarn(value: *i32, min: i32, max: i32, axis_label: []const u8, low_word: []const u8, high_word: []const u8, context: []const u8) void {
    if (value.* < min) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, low_word, context, min });
        value.* = min;
    } else if (value.* > max) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, high_word, context, max });
        value.* = max;
    }
}
