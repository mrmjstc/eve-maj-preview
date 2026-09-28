const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const types = @import("../types.zig");
const scout_mod = @import("../clients/scout.zig");
const log = @import("../log.zig");
const slog = log.scoped("layout");
const monitors = @import("monitors.zig");

const ThumbnailWindow = @import("../thumbnail/window.zig").ThumbnailWindow;
const scalePixels = win32.scalePixels;
const dpiToScale = win32.dpiToScale;

/// Clamps *value into [min, max], warning with axis_label/low_word/high_word/context worked into the message on either bound.
fn clampAxisWithWarn(value: *i32, min: i32, max: i32, axis_label: []const u8, low_word: []const u8, high_word: []const u8, context: []const u8) void {
    if (value.* < min) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, low_word, context, min });
        value.* = min;
    } else if (value.* > max) {
        slog.warn("Thumbnail {s} position {} too far {s}{s}, clamping to {}", .{ axis_label, value.*, high_word, context, max });
        value.* = max;
    }
}

pub fn notLoggedInSpaceRectFromConfig(cfg: *const config_mod.DisplayConfig) ?win32.RECT {
    if (!cfg.notLoggedInSpaceEnabled) return null;
    const x = cfg.notLoggedInSpaceX orelse return null;
    const y = cfg.notLoggedInSpaceY orelse return null;
    const width = cfg.notLoggedInSpaceWidth orelse return null;
    const height = cfg.notLoggedInSpaceHeight orelse return null;
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + height };
}

/// True when notLoggedInSpace pulls this placeholder out of the RegionFit grid entirely, even while RegionFit is active.
pub fn isCarvedOutOfRegionFit(cfg: *const config_mod.DisplayConfig, character_name: []const u8) bool {
    return scout_mod.isGenericCharacterName(character_name) and notLoggedInSpaceRectFromConfig(cfg) != null;
}

/// box_width/box_height is the per-column/row share of the region, used only to pick the column count; cell_width/cell_height is the actual aspect-corrected thumbnail size used for positioning.
pub const RegionFitGrid = struct { columns: u32, rows: u32, box_width: i32, box_height: i32, cell_width: i32, cell_height: i32 };

pub fn regionRectFromConfig(cfg: *const config_mod.DisplayConfig) ?win32.RECT {
    const x = cfg.regionX orelse return null;
    const y = cfg.regionY orelse return null;
    const width = cfg.regionWidth orelse return null;
    const height = cfg.regionHeight orelse return null;
    return .{ .left = x, .top = y, .right = x + width, .bottom = y + height };
}

pub fn isRegionFitActive(cfg: *const config_mod.DisplayConfig) bool {
    return cfg.layoutMode == .RegionFit and regionRectFromConfig(cfg) != null;
}

pub const RegionFitCap = struct { width: i32, height: i32 };

/// Floors at 1px (a Win32 API-validity floor, not a usability minimum).
fn fitAspect(box_width: i32, box_height: i32, aspect_ratio: f32) struct { width: i32, height: i32 } {
    if (box_width <= 0 or box_height <= 0) return .{ .width = 1, .height = 1 };

    var width = box_width;
    var height: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(width)) / aspect_ratio));
    if (height > box_height) {
        height = box_height;
        width = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * aspect_ratio));
    }
    return .{ .width = @max(width, 1), .height = @max(height, 1) };
}

fn regionFitGridForDims(region_width: i32, region_height: i32, columns: u32, rows: u32, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
    const box_width = @max(@divTrunc(region_width - spacing_x * (@as(i32, @intCast(columns)) - 1), @as(i32, @intCast(columns))), 1);
    const box_height = @max(@divTrunc(region_height - spacing_y * (@as(i32, @intCast(rows)) - 1), @as(i32, @intCast(rows))), 1);
    const fit_width = if (max_cell) |cap| @min(box_width, cap.width) else box_width;
    const fit_height = if (max_cell) |cap| @min(box_height, cap.height) else box_height;
    const cell = fitAspect(fit_width, fit_height, aspect_ratio);
    return .{ .columns = columns, .rows = rows, .box_width = box_width, .box_height = box_height, .cell_width = cell.width, .cell_height = cell.height };
}

fn regionFitCellArea(grid: RegionFitGrid) i64 {
    return @as(i64, grid.cell_width) * @as(i64, grid.cell_height);
}

/// How many cap-sized cells fit along one axis; used only to break area ties under a size cap (see calculateRegionFitGrid).
fn regionFitAxisCapacity(dimension: i32, spacing: i32, cell_dimension: i32) u32 {
    return @intCast(@max(@divTrunc(dimension + spacing, cell_dimension + spacing), 1));
}

/// Grows one column or row at a time from a single full-region cell, whichever yields the bigger cell, so the grid grows incrementally instead of re-optimizing from scratch per count.
pub fn calculateRegionFitGrid(region: win32.RECT, count: usize, spacing_x: i32, spacing_y: i32, aspect_ratio: f32, max_cell: ?RegionFitCap) RegionFitGrid {
    const n: u32 = @intCast(@max(count, 1));
    const region_width = region.right - region.left;
    const region_height = region.bottom - region.top;

    // Under a size cap, growing either axis often yields the same capped cell size; break that tie toward whichever axis has more natural room, so one column/row fills up before a second one starts.
    const prefer_rows_on_tie = if (max_cell) |cap|
        regionFitAxisCapacity(region_height, spacing_y, cap.height) >= regionFitAxisCapacity(region_width, spacing_x, cap.width)
    else
        false;

    var columns: u32 = 1;
    var rows: u32 = 1;
    var grid = regionFitGridForDims(region_width, region_height, columns, rows, spacing_x, spacing_y, aspect_ratio, max_cell);

    while (columns * rows < n) {
        const grow_columns = regionFitGridForDims(region_width, region_height, columns + 1, rows, spacing_x, spacing_y, aspect_ratio, max_cell);
        const grow_rows = regionFitGridForDims(region_width, region_height, columns, rows + 1, spacing_x, spacing_y, aspect_ratio, max_cell);
        const area_columns = regionFitCellArea(grow_columns);
        const area_rows = regionFitCellArea(grow_rows);
        const take_columns = if (area_columns != area_rows) area_columns > area_rows else !prefer_rows_on_tie;
        if (take_columns) {
            columns += 1;
            grid = grow_columns;
        } else {
            rows += 1;
            grid = grow_rows;
        }
    }

    return grid;
}

/// BTT/RTL directions stay within [0, rows/columns) since the region is fixed-size.
fn regionFitColRow(direction: types.RegionFitDirection, index: usize, columns: u32, rows: u32) struct { col: i32, row: i32 } {
    return switch (direction) {
        .RowFirst_RTL_TTB => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @intCast(index / columns) },
        .RowFirst_LTR_BTT => .{ .col = @intCast(index % columns), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .RowFirst_RTL_BTT => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index % columns)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index / columns)) },
        .ColumnFirst_TTB_LTR => .{ .col = @intCast(index / rows), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_LTR => .{ .col = @intCast(index / rows), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .ColumnFirst_TTB_RTL => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @intCast(index % rows) },
        .ColumnFirst_BTT_RTL => .{ .col = @as(i32, @intCast(columns - 1)) - @as(i32, @intCast(index / rows)), .row = @as(i32, @intCast(rows - 1)) - @as(i32, @intCast(index % rows)) },
        .RowFirst_LTR_TTB => .{ .col = @intCast(index % columns), .row = @intCast(index / columns) },
    };
}

/// index/total_count here are display-order ranks (see computeRegionFitDisplayOrder), not raw thumbnails-array positions.
fn calculateRegionFitPosition(cfg: *const config_mod.DisplayConfig, region: win32.RECT, index: usize, total_count: usize, aspect_ratio: f32, max_cell: ?RegionFitCap) config_mod.Position {
    const grid = calculateRegionFitGrid(region, total_count, cfg.spacing, cfg.spacing, aspect_ratio, max_cell);
    return regionFitPositionForGrid(region, grid, index, cfg.regionFitDirection, cfg.spacing);
}

/// Split out of calculateRegionFitPosition so callers that already computed the grid don't redo it per thumbnail. Takes direction/spacing explicitly so notLoggedInSpace can reuse it with its own spacing.
pub fn regionFitPositionForGrid(region: win32.RECT, grid: RegionFitGrid, index: usize, direction: types.RegionFitDirection, spacing: i32) config_mod.Position {
    const cr = regionFitColRow(direction, index, grid.columns, grid.rows);
    // Stride by cell size, not the wider box, so slack collects at the region's far edge instead of as gaps between thumbnails.
    return .{
        .x = region.left + cr.col * (grid.cell_width + spacing),
        .y = region.top + cr.row * (grid.cell_height + spacing),
    };
}

pub const RegionFitDisplayOrder = struct { ranks: []usize, count: usize };

/// Read-only view over what thumbnail placement depends on: config plus the current thumbnail list (for counts and ranks).
pub const Layout = struct {
    config: *const config_mod.Config,
    thumbnails: []const ThumbnailWindow,

    /// Always false for the generic "not logged in" name, which never has a saved position of its own.
    fn hasSavedPosition(self: Layout, character_name: []const u8) bool {
        const cfg = &self.config.display;
        return !scout_mod.isGenericCharacterName(character_name) and
            cfg.honorSavedPositions and
            self.config.getCharacterPosition(character_name) != null;
    }

    /// Ranks this thumbnail's slot in the left-to-right unpositioned spawn row.
    fn unpositionedIndex(self: Layout, up_to: usize) usize {
        var count: usize = 0;
        for (self.thumbnails[0..@min(up_to, self.thumbnails.len)]) |thumbnail| {
            if (!self.hasSavedPosition(thumbnail.character_name)) count += 1;
        }
        return count;
    }

    /// Ranks this thumbnail among not-logged-in "EVE" placeholders only, for notLoggedInSpace's own grid.
    pub fn notLoggedInIndex(self: Layout, up_to: usize) usize {
        var count: usize = 0;
        for (self.thumbnails[0..@min(up_to, self.thumbnails.len)]) |thumbnail| {
            if (scout_mod.isGenericCharacterName(thumbnail.character_name)) count += 1;
        }
        return count;
    }

    /// How many tracked thumbnails actually belong in the RegionFit grid, excluding notLoggedInSpace placeholders when that space is configured.
    pub fn regionFitGridCount(self: Layout) usize {
        const cfg = &self.config.display;
        if (notLoggedInSpaceRectFromConfig(cfg) == null) return self.thumbnails.len;
        var count: usize = 0;
        for (self.thumbnails) |thumbnail| {
            if (!scout_mod.isGenericCharacterName(thumbnail.character_name)) count += 1;
        }
        return count;
    }

    /// How many not-logged-in "EVE" placeholders currently exist, for notLoggedInSpace's own grid-fit sizing.
    pub fn notLoggedInSpaceCount(self: Layout) usize {
        var count: usize = 0;
        for (self.thumbnails) |thumbnail| {
            if (scout_mod.isGenericCharacterName(thumbnail.character_name)) count += 1;
        }
        return count;
    }

    /// notLoggedInSpace's own auto-fit grid - same aspect-preserving column/row search as RegionFit's Thumbnail Space, but with its own spacing and size cap.
    pub fn notLoggedInSpaceGrid(self: Layout, space: win32.RECT, count: usize) RegionFitGrid {
        const cfg = &self.config.display;
        return calculateRegionFitGrid(space, count, cfg.notLoggedInSpaceSpacing, cfg.notLoggedInSpaceSpacing, self.regionFitAspectRatio(), self.thumbnailSizeCap(space, cfg.notLoggedInSpaceLimitToThumbnailSize));
    }

    /// Auto-fits not-logged-in placeholders into `space`: same grid-fit as RegionFit's Thumbnail Space, just with its own item count, spacing, and region.
    fn calculateNotLoggedInSpacePosition(self: Layout, cfg: *const config_mod.DisplayConfig, space: win32.RECT, index: usize) config_mod.Position {
        const grid = self.notLoggedInSpaceGrid(space, self.notLoggedInSpaceCount());
        const rank = self.notLoggedInIndex(index);
        return regionFitPositionForGrid(space, grid, rank, cfg.regionFitDirection, cfg.notLoggedInSpaceSpacing);
    }

    pub fn calculateThumbnailPosition(
        self: Layout,
        character_name: []const u8,
        thumb_width: i32,
        thumb_height: i32,
        index: usize,
        total_count: usize,
        monitor_bounds: ?win32.RECT,
        scale: f32,
    ) config_mod.Position {
        const cfg = &self.config.display;

        // Checked first: notLoggedInSpace takes priority over RegionFit for these placeholders.
        if (scout_mod.isGenericCharacterName(character_name)) {
            if (notLoggedInSpaceRectFromConfig(cfg)) |space| {
                return self.calculateNotLoggedInSpacePosition(cfg, space, index);
            }
        }

        // Checked before saved positions, which it replaces entirely while active.
        if (cfg.layoutMode == .RegionFit) {
            if (regionRectFromConfig(cfg)) |region| {
                return calculateRegionFitPosition(cfg, region, index, total_count, self.regionFitAspectRatio(), self.regionFitMaxCellSize(region));
            }
        }

        if (self.hasSavedPosition(character_name)) {
            // Saved positions are absolute physical pixels (see saveThumbnailPosition), so scaling doesn't apply.
            const saved_pos = self.config.getCharacterPosition(character_name).?;
            slog.debug("Using saved position for {s}: ({}, {})", .{ character_name, saved_pos.x, saved_pos.y });
            return .{ .x = saved_pos.x, .y = saved_pos.y };
        }

        // No saved position: flow left-to-right from startX/startY, wrapping to a new row instead of overlapping once a row runs out of width.
        const slot = @as(i32, @intCast(self.unpositionedIndex(index)));
        const step_x = thumb_width + scalePixels(cfg.newThumbnailSpacing, scale);
        const step_y = thumb_height + scalePixels(cfg.newThumbnailSpacing, scale);

        // Monitor bounds if one's configured, otherwise the real current virtual screen (not a guessed multi-monitor range - see manager.zig's clampToVirtualScreen).
        const bounds = monitor_bounds orelse win32.RECT{
            .left = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN),
            .top = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN),
            .right = win32.GetSystemMetrics(win32.SM_XVIRTUALSCREEN) + win32.GetSystemMetrics(win32.SM_CXVIRTUALSCREEN),
            .bottom = win32.GetSystemMetrics(win32.SM_YVIRTUALSCREEN) + win32.GetSystemMetrics(win32.SM_CYVIRTUALSCREEN),
        };

        // startX/startY are monitor-relative when a monitor is configured, absolute otherwise.
        const start_x = scalePixels(cfg.startX, scale) + (if (monitor_bounds != null) bounds.left else 0);
        const start_y = scalePixels(cfg.startY, scale) + (if (monitor_bounds != null) bounds.top else 0);

        const columns_per_row = @max(@divTrunc(bounds.right - start_x, @max(step_x, 1)), 1);
        const row = @divTrunc(slot, columns_per_row);
        const col = @mod(slot, columns_per_row);
        slog.debug("Thumbnail #{} has no saved position, spawning at unpositioned slot {} (row {}, col {})", .{ index, slot, row, col });

        var pos = config_mod.Position{ .x = start_x + col * step_x, .y = start_y + row * step_y };

        // Clamp to keep thumbnails from spawning fully off-screen, while still allowing edge placement; only bites once rows also overflow the screen's height.
        const clamp_margin = 50;
        const monitor_suffix = if (monitor_bounds != null) " for monitor" else "";
        clampAxisWithWarn(&pos.x, bounds.left - clamp_margin, bounds.right - thumb_width + clamp_margin, "X", "left", "right", monitor_suffix);
        clampAxisWithWarn(&pos.y, bounds.top - clamp_margin, bounds.bottom - thumb_height + clamp_margin, "Y", "up", "down", monitor_suffix);

        return pos;
    }

    /// RegionFit always keeps the configured thumbnail's shape; regionFitLimitToThumbnailSize additionally caps its absolute size (see regionFitMaxCellSize).
    pub fn regionFitAspectRatio(self: Layout) f32 {
        return @as(f32, @floatFromInt(self.config.thumbnail.width)) / @as(f32, @floatFromInt(self.config.thumbnail.height));
    }

    pub fn regionFitMaxCellSize(self: Layout, region: win32.RECT) ?RegionFitCap {
        return self.thumbnailSizeCap(region, self.config.display.regionFitLimitToThumbnailSize);
    }

    /// Physical-pixel cap on a space's cell size, DPI-scaled for the space's own monitor (which may differ from the app's configured monitor); null when `limit_enabled` is off.
    fn thumbnailSizeCap(self: Layout, region: win32.RECT, limit_enabled: bool) ?RegionFitCap {
        if (!limit_enabled) return null;
        const center = win32.POINT{ .x = @divTrunc(region.left + region.right, 2), .y = @divTrunc(region.top + region.bottom, 2) };
        const dpi = if (win32.nearestMonitor(center)) |monitor| monitors.getMonitorDpi(monitor) else monitors.defaultDpi();
        const scale = dpiToScale(dpi);
        return .{ .width = scalePixels(self.config.thumbnail.width, scale), .height = scalePixels(self.config.thumbnail.height, scale) };
    }

    /// Ranks each tracked thumbnail per display.regionFitOrder; unranked characters sort last. Returns a thumbnails-array-index -> display-rank mapping (caller owns .ranks) and how many were ranked.
    /// carve_out excludes notLoggedInSpace placeholders entirely, so `count`/ranks reflect only what belongs in the RegionFit grid.
    pub fn computeRegionFitDisplayOrder(self: Layout, allocator: std.mem.Allocator, carve_out: bool) !RegionFitDisplayOrder {
        var order_map = std.StringHashMap(usize).init(allocator);
        defer order_map.deinit();
        switch (self.config.display.regionFitOrder) {
            .Characters => {
                order_map.deinit();
                order_map = try config_mod.buildCharacterOrderMap(self.config.characters.items, allocator);
            },
            .HotkeyGroups => {
                var rank: usize = 0;
                for (self.config.hotkeyGroups.items) |group| {
                    for (group.characters.items) |name| {
                        const gop = try order_map.getOrPut(name);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = rank;
                            rank += 1;
                        }
                    }
                }
            },
        }

        const n = self.thumbnails.len;
        const sort_indices = try allocator.alloc(usize, n);
        defer allocator.free(sort_indices);
        var count: usize = 0;
        for (self.thumbnails, 0..) |thumbnail, i| {
            if (carve_out and scout_mod.isGenericCharacterName(thumbnail.character_name)) continue;
            sort_indices[count] = i;
            count += 1;
        }
        const used = sort_indices[0..count];

        const Ctx = struct {
            thumbnails: []const ThumbnailWindow,
            order_map: *const std.StringHashMap(usize),

            // Checked before order_map, or an unranked logged-in character (not in the Characters list) would tie with a placeholder and sort by array order instead.
            fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                const a_name = ctx.thumbnails[a_index].character_name;
                const b_name = ctx.thumbnails[b_index].character_name;
                const a_generic = scout_mod.isGenericCharacterName(a_name);
                const b_generic = scout_mod.isGenericCharacterName(b_name);
                if (a_generic != b_generic) return !a_generic;
                return config_mod.orderMapLessThan(ctx.order_map, a_name, b_name, a_index, b_index);
            }
        };
        std.sort.pdq(usize, used, Ctx{ .thumbnails = self.thumbnails, .order_map = &order_map }, Ctx.lessThan);

        // Carved-out entries keep their zero-initialized rank; it's never read since they route to notLoggedInSpace instead.
        const display_index_by_thumb_index = try allocator.alloc(usize, n);
        @memset(display_index_by_thumb_index, 0);
        for (used, 0..) |thumb_index, display_index| {
            display_index_by_thumb_index[thumb_index] = display_index;
        }
        return .{ .ranks = display_index_by_thumb_index, .count = count };
    }

    /// total_count only matters for RegionFit; other modes ignore it. precomputed_grid is always RegionFit's own grid, never notLoggedInSpace's - that one's cheap enough to recompute fresh each call.
    pub fn getThumbnailSize(self: Layout, character_name: []const u8, total_count: usize, precomputed_grid: ?RegionFitGrid) struct { width: i32, height: i32 } {
        const cfg = &self.config.display;
        if (isCarvedOutOfRegionFit(cfg, character_name)) {
            const space = notLoggedInSpaceRectFromConfig(cfg).?;
            const grid = self.notLoggedInSpaceGrid(space, self.notLoggedInSpaceCount());
            return .{ .width = grid.cell_width, .height = grid.cell_height };
        }
        if (cfg.layoutMode == .RegionFit) {
            if (precomputed_grid) |grid| {
                return .{ .width = grid.cell_width, .height = grid.cell_height };
            }
            if (regionRectFromConfig(cfg)) |region| {
                const grid = calculateRegionFitGrid(region, total_count, cfg.spacing, cfg.spacing, self.regionFitAspectRatio(), self.regionFitMaxCellSize(region));
                return .{ .width = grid.cell_width, .height = grid.cell_height };
            }
        }
        if (self.config.getCharacterSize(character_name)) |char_size| {
            return .{
                .width = char_size.width orelse self.config.thumbnail.width,
                .height = char_size.height orelse self.config.thumbnail.height,
            };
        }
        return .{
            .width = self.config.thumbnail.width,
            .height = self.config.thumbnail.height,
        };
    }
};
