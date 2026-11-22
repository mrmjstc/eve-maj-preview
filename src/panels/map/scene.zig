//! What the Map Panel shows besides its own settings, and which of its layers the settings let through.
const win32 = @import("../../platform/win32.zig");
const config_mod = @import("../../config.zig");
const destinations_mod = @import("destinations.zig");
const traffic_mod = @import("traffic.zig");
const stats_mod = @import("../../map/stats.zig");
const holder_colors = @import("../../map/holder_colors.zig");
const storms = @import("../../map/storms.zig");
const incursions = @import("../../map/incursions.zig");
const campaigns = @import("../../map/campaigns.zig");
const wormholes = @import("../../map/wormholes.zig");
const evestars = @import("../../map/evestars.zig");
const zkill = @import("../../map/zkill.zig");
const intel_pins = @import("../../map/intel_pins.zig");
const roster = @import("../../clients/roster.zig");

const Bridges = evestars.Bridges;
const Campaigns = campaigns.Campaigns;
const Client = roster.Client;
const Config = config_mod.Config;
const Connections = wormholes.Connections;
const Destinations = destinations_mod.Destinations;
const Incursions = incursions.Incursions;
const KillNames = zkill.Names;
const Kills = zkill.Kills;
const LogoColors = holder_colors.LogoColors;
const Snapshot = stats_mod.Snapshot;
const Storms = storms.Storms;
const Traffic = traffic_mod.Traffic;

pub const Scene = struct {
    /// Borrowed for one render.
    clients: []const Client = &.{},
    active_source_hwnd: ?win32.HWND = null,
    /// Borrowed for one render.
    stats: ?*const Snapshot,
    /// Borrowed for one render; null until the first arrive.
    logo_colors: ?*const LogoColors = null,
    /// Changes with each new logo_colors, for the redraw check.
    logo_revision: u64 = 0,
    /// Borrowed for one render.
    pins: *const intel_pins.IntelPins,
    /// Borrowed for one render.
    destinations: *const Destinations,
    /// Borrowed for one render.
    traffic: *const Traffic,
    /// Seconds since 1970, UTC, for the sov timers' countdowns and the kills' ages.
    now_seconds: i64 = 0,
    /// Borrowed for one render; null while kills are hidden.
    kills: ?*const Kills = null,
    /// Borrowed for one render; null while kills are hidden.
    kill_names: ?*const KillNames = null,

    /// Null while they're hidden, or the last fetch didn't get them.
    pub fn shownCampaigns(self: *const Scene, config: *const Config) ?*const Campaigns {
        const stats = self.stats orelse return null;
        return if (config.mapPanel.showSovTimers and stats.has_campaigns) &stats.campaigns else null;
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    pub fn shownWormholes(self: *const Scene, config: *const Config) ?*const Connections {
        const stats = self.stats orelse return null;
        return if (config.mapPanel.showWormholes and stats.has_wormholes) &stats.wormholes else null;
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    pub fn shownStorms(self: *const Scene, config: *const Config) ?*const Storms {
        const stats = self.stats orelse return null;
        return if (config.mapPanel.showStorms and stats.has_storms) &stats.storms else null;
    }

    /// Null while they're hidden, or the last fetch didn't get them.
    pub fn shownIncursions(self: *const Scene, config: *const Config) ?*const Incursions {
        const stats = self.stats orelse return null;
        return if (config.mapPanel.showIncursions and stats.has_incursions) &stats.incursions else null;
    }

    /// Null while they're hidden, without Eve Stars, or before any arrive.
    pub fn shownBridges(self: *const Scene, config: *const Config, has_eve_stars: bool) ?*const Bridges {
        if (!config.mapPanel.showAnsiblex or !has_eve_stars) return null;
        const bridges = &self.destinations.bridges;
        return if (bridges.count > 0) bridges else null;
    }
};
