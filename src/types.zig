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
    OriginalAnimation,
    NoAnimation,
};

pub const ClickTrigger = enum {
    MouseDown,
    MouseUp,
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

pub const FontWeight = enum {
    Regular,
    Bold,
    Italic,
    BoldItalic,

    /// Convert to Windows font weight value (for CreateFontA weight parameter)
    pub fn toWin32Weight(self: FontWeight) i32 {
        // 400/700 are the raw FW_NORMAL/FW_BOLD values
        return switch (self) {
            .Regular, .Italic => 400,
            .Bold, .BoldItalic => 700,
        };
    }

    /// Check if font should be italicized (for CreateFontA italic parameter)
    pub fn isItalic(self: FontWeight) bool {
        return self == .Italic or self == .BoldItalic;
    }
};

/// Notification event types from EVE game logs
pub const NotificationType = enum {
    FleetInvite,
    FleetFollow,
    FleetRegroup,
    FleetDisband,
    ConversationInvite,
    JumpCloning,
    MiningCompression,
    AsteroidDepleted,
    MiningIdle,
    MiningStopped,
    CargoFull,
    TakingDamage,
    WarpScrambled,
    WarpDisrupted,
    Decloak,
    ObservatoryDecloak,
    CloakFailed,
    CrystalBroke,
    BombLauncherEmpty,
    SelfDestruct,
    Docking,
    AutopilotReached,
    AutopilotApproaching,
    JumpRange,
    AggressionCantJump,
    WarpBubble,
    ConduitJump,
    SystemChange,
    TravelLeftBehind,
    Generic,
};

/// Mirrors the 5 categories config_dialog.js's NOTIFICATION_TYPES groups these into, for the History Panel's category filter buttons.
pub const NotificationCategory = enum {
    Fleet,
    Mining,
    Combat,
    Navigation,
    General,
};

pub fn notificationCategory(t: NotificationType) NotificationCategory {
    return switch (t) {
        .FleetInvite, .FleetFollow, .FleetRegroup, .FleetDisband => .Fleet,
        .MiningCompression, .AsteroidDepleted, .MiningIdle, .MiningStopped, .CargoFull, .CrystalBroke => .Mining,
        .TakingDamage, .WarpScrambled, .WarpDisrupted, .Decloak, .ObservatoryDecloak, .CloakFailed, .BombLauncherEmpty, .SelfDestruct, .WarpBubble => .Combat,
        .Docking, .AutopilotReached, .AutopilotApproaching, .JumpRange, .AggressionCantJump, .ConduitJump, .JumpCloning, .SystemChange, .TravelLeftBehind => .Navigation,
        .ConversationInvite, .Generic => .General,
    };
}

pub const LayoutMode = enum {
    Grid,
    VerticalStack,
    HorizontalStack,
    VerticalList,
    HorizontalList,
    Overlay,
    Custom,
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

/// Direction for layout growth
pub const LayoutDirection = enum {
    LeftToRight,
    RightToLeft,
    TopToBottom,
    BottomToTop,
    RowFirst_LTR_TTB,
    RowFirst_RTL_TTB,
    RowFirst_LTR_BTT,
    RowFirst_RTL_BTT,
    ColumnFirst_TTB_LTR,
    ColumnFirst_BTT_LTR,
    ColumnFirst_TTB_RTL,
    ColumnFirst_BTT_RTL,
};
