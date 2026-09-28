// Shared mutable dialog state; every module that reassigns one of these goes through this object.
export const app = {
    currentConfig: null,
    currentGlobalSettings: null,
    // Tracks names removed this session so reloadLivePositions() won't resurrect them from disk.
    deletedCharacterNames: new Set(),
    // Character names staged by pickRunningWindowForFilter(), keyed lowercased; added to currentConfig.characters only at Save time.
    pendingCharacterNames: new Map(),
    // Factory-default config fetched once at startup (loadDefaultConfig); feeds "Clear to Default" buttons. May stay null on fetch failure - callers must tolerate that.
    defaultConfig: null,
    webuiReady: false,
    hasUnsavedChanges: false,
    // Value-based snapshot from the last markAsSaved() call; null until the initial load finishes. See hasRealUnsavedChanges().
    savedFormFingerprint: null,
    // Server-truth min/max bounds keyed by CONFIG_SCHEMA's dotted path, in Config.zig's validate() units.
    VALIDATION_RANGES: {},
    // VALIDATION_RANGES re-keyed by field id and converted to display units (e.g. ms -> seconds) - see buildFieldRanges().
    FIELD_RANGES: {},
    dialogEditingProfile: null,
    // Profile the dialog believes is driving the running app's live thumbnails; live-preview patches only send while this equals dialogEditingProfile.
    liveConfirmedProfile: null,
};
