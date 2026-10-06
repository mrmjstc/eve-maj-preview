//! Enums used by settings; their tag names are saved in profiles, so renaming a tag breaks existing profiles.

/// Kept with the other setting types, though defined where platform/ can use it.
pub const FontWeight = @import("../platform/fonts.zig").FontWeight;

pub const BorderStyle = enum {
    Solid,
    Dashed,
    Dotted,
    Double,
    DiagonalHatch,
    DashDot,
    CornerBrackets,
};

/// Visual style for the thumbnail overlay shown on characters excluded from hotkey cycling
pub const ExclusionOverlayStyle = enum {
    X,
    DiagonalSlash,
    DiagonalHatch,
    Checkerboard,
    SolidTint,
    CircleSlash,
    None,
};

/// Animation style for window operations (restore, minimize)
pub const AnimationStyle = enum {
    NoAnimation,
    OriginalAnimation,
};

pub const ClickTrigger = enum {
    MouseDown,
    MouseUp,
};

/// System cursor shown while hovering a thumbnail; `Default` leaves the window class's arrow in place.
pub const HoverCursor = enum {
    Default,
    Hand,
    Crosshair,
    Move,
    Help,
};

pub const TextPosition = enum {
    TopLeft,
    TopCenter,
    TopRight,
    LeftCenter,
    Center,
    RightCenter,
    BottomLeft,
    BottomCenter,
    BottomRight,
};

/// Primary display mode: how EVE clients are presented
pub const ViewMode = enum {
    Thumbnails,
    ClientList,
    Nothing,
};

/// Ordering mode for rows in the compact client list view
pub const ListViewOrder = enum {
    Tracked,
    Alphabetical,
    ConfiguredCharacters,
};

/// How thumbnails get their position: dragged by hand, or filled into thumbnail spaces.
pub const PlacementMode = enum {
    Manual,
    ThumbnailSpaces,
};

/// Fill order for RegionFit's grid: configured character list, or grouped by hotkey group membership.
pub const RegionFitOrder = enum {
    Characters,
    HotkeyGroups,
};

/// Fill direction for RegionFit's grid
pub const RegionFitDirection = enum {
    RowFirst_LTR_TTB,
    RowFirst_RTL_TTB,
    RowFirst_LTR_BTT,
    RowFirst_RTL_BTT,
    ColumnFirst_TTB_LTR,
    ColumnFirst_TTB_RTL,
    ColumnFirst_BTT_LTR,
    ColumnFirst_BTT_RTL,
};
