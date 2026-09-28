// Shared mutable dialog state; every module that reassigns one of these goes through this object.
export const app = {
    // The documents the form edits, in the app's shape (see session.js).
    currentConfig: null,
    currentGlobalSettings: null,
    // The built-in ore list the ore table shows; currentGlobalSettings.oreTable only holds price overrides.
    oreCatalog: [],
    // Whether the window edits a profile other than the running one, so its edits don't preview.
    editsDraft: false,
    // Whether each document differs from what's saved, as the app last reported.
    dirty: { profile: false, global: false },
    // Character names staged by pickRunningWindowForFilter(), keyed lowercased; added to currentConfig.characters only at Save time.
    pendingCharacterNames: new Map(),
    webuiReady: false,
    // Every setting's kind, default, bounds and options, from the app (see binding.js).
    schema: null,
    // The profile the window edits, every profile there is, and each character's EVE ID for portraits, as of the last session snapshot.
    dialogEditingProfile: null,
    profiles: [],
    characterIds: {},
};
