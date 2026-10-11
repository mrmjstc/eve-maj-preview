//! A thumbnail's visibility, and the state that picks its look.
pub const VisibilityState = enum {
    visible,
    /// Auto-hidden via hideWhenNoEveFocus; can be auto-shown again.
    hidden_automatic,
    /// Persists until the user manually toggles it again.
    hidden_manual,

    pub fn isVisible(self: VisibilityState) bool {
        return self == .visible;
    }
};

/// Used purely as a style-lookup key (config.zig's getStateConfig) - never persisted per-thumbnail; see ThumbnailWindow.effectiveRenderState.
pub const ThumbnailState = enum {
    inactive,
    active,
    alert,
    minimized,
    dragging,
};
