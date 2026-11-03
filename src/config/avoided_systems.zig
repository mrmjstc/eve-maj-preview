//! A system the Map Panel's sent routes keep out of.
const wire = @import("wire.zig");

pub const AvoidedSystemConfig = struct {
    /// CCP's system ID, which outlasts a map update.
    systemId: u32 = 0,

    pub const Wire = wire.Wire(AvoidedSystemConfig);
};
