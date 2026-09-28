// Loading and saving the profile, and keeping runtime changes (positions, group members) in step.
import { app } from './state.js';
import { hasRealUnsavedChanges, markAsSaved } from './changes.js';
import { addCharacterIfMissing, saveCharacters } from './characters.js';
import { listenForAppEvent, logError, logWarn, rpc } from './core.js';
import { applyConfigSchemaFromForm, applyConfigSchemaToForm, applySpecialFieldsFromForm, applySpecialFieldsToForm, getFieldValue, populateFormFields } from './form.js';
import { saveAppHotkeys, saveProfileSwitchHotkeys, saveUrlHotkeys } from './global_hotkeys.js';
import { refreshHotkeyGroupCharsList, saveHotkeyGroups } from './hotkey_groups.js';
import { describeHotkeyConflicts, showHotkeyConflictModal, updateHotkeyConflictHighlights } from './hotkeys.js';
import { t } from './i18n.js';
import { showStatus, switchTab } from './layout.js';
import { saveNotificationTypes } from './notifications.js';
import { saveOreTable } from './ore_table.js';
import { saveSystemColors } from './system_colors.js';
import { saveWindowFilters } from './window_filters.js';

// Last-known on-disk members per group index, so a sync skips groups the app didn't change.
let diskGroupMembers = [];
// Keyed by group object so it survives unsaved renames/reorders and stays out of saveConfig's JSON.
let diskGroupIndex = new WeakMap();

listenForAppEvent('groupMembersChanged', () => {
    syncHotkeyGroupMembersFromDisk().catch((error) => logWarn('Failed to reload hotkey group members:', error));
});

// Only call when the dialog's groups match disk (load or successful save).
function snapshotDiskGroupMembers(groups) {
    diskGroupMembers = (groups || []).map(g => JSON.stringify(g.characters || []));
    diskGroupIndex = new WeakMap((groups || []).map((g, i) => [g, i]));
}

// Keeps a later Save here from reverting assign-key edits the main app already saved.
async function syncHotkeyGroupMembersFromDisk() {
    if (!app.currentConfig || !app.currentConfig.hotkeyGroups) return;

    const diskConfig = await rpc('loadConfig');

    const wasClean = !hasRealUnsavedChanges();
    saveHotkeyGroups();
    diskConfig.hotkeyGroups.forEach((diskGroup, diskIndex) => {
        if (diskGroup.temporaryMembership) return;
        const diskChars = JSON.stringify(diskGroup.characters || []);
        if (diskGroupMembers[diskIndex] === diskChars) return;
        diskGroupMembers[diskIndex] = diskChars;

        const index = app.currentConfig.hotkeyGroups.findIndex(g => diskGroupIndex.get(g) === diskIndex);
        if (index === -1 || app.currentConfig.hotkeyGroups[index].temporaryMembership) return;
        app.currentConfig.hotkeyGroups[index].characters = [...(diskGroup.characters || [])];
        refreshHotkeyGroupCharsList(index);
    });
    if (wasClean) markAsSaved();
}

export async function loadAppVersion() {
    try {
        const version = await rpc('getAppVersion');
        const versionEl = document.getElementById('app-version');
        if (versionEl) versionEl.textContent = version;
    } catch (error) {
        logWarn('Failed to load app version:', error);
    }
}

export async function loadConfigurationFromBackend() {
    showStatus(t('status.loadingConfig'), 'info');

    try {
        if (typeof webui !== 'undefined') {
            app.currentConfig = await rpc('loadConfig');
            snapshotDiskGroupMembers(app.currentConfig.hotkeyGroups);
            populateFormFields();
            markAsSaved();
            showStatus(t('status.loaded'), 'success');
        } else {
            logWarn('WebUI not available');
        }
    } catch (error) {
        logError('Failed to load configuration:', error);
        showStatus(t('status.failedPrefix') + error.message, 'error');
    }
}

let isSavingConfig = false;

// Prevents a rapid double-click from firing two overlapping saves.
export async function saveConfiguration() {
    if (isSavingConfig) return;
    isSavingConfig = true;
    const saveBtn = document.getElementById('save-config-btn');
    if (saveBtn) saveBtn.disabled = true;

    try {
        await saveConfigurationImpl();
    } finally {
        isSavingConfig = false;
        if (saveBtn) saveBtn.disabled = false;
    }
}

async function saveConfigurationImpl() {
    showStatus(t('status.savingConfig'), 'info');

    if (app.currentConfig) {
        applyConfigSchemaFromForm();
        applySpecialFieldsFromForm();

        // The From-form pass just clamped/defaulted raw values into currentConfig - run the schema back the other way so the DOM reflects that outcome immediately, not after a reload.
        applyConfigSchemaToForm();
        applySpecialFieldsToForm();

        // Avoids overwriting positions changed by dragging thumbnails/the list view after the dialog was opened.
        await reloadLivePositions();

        for (const name of app.pendingCharacterNames.values()) addCharacterIfMissing(name);
        app.pendingCharacterNames.clear();

        saveWindowFilters();
        saveSystemColors();
        saveCharacters();
        saveHotkeyGroups();
        saveNotificationTypes();
        saveProfileSwitchHotkeys();
        saveAppHotkeys();
        saveUrlHotkeys();
        saveOreTable();

        if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
        app.currentGlobalSettings.logLevel = getFieldValue('logLevel');
        app.currentGlobalSettings.language = getFieldValue('languageSelect') || 'en';
        app.currentGlobalSettings.hotkeyNextProfile = getFieldValue('hotkeyNextProfile') || null;
        app.currentGlobalSettings.hotkeyPreviousProfile = getFieldValue('hotkeyPreviousProfile') || null;
        app.currentGlobalSettings.hotkeyCycleAllClientsForward = getFieldValue('hotkeyCycleAllClientsForward') || null;
        app.currentGlobalSettings.hotkeyCycleAllClientsBackward = getFieldValue('hotkeyCycleAllClientsBackward') || null;
        app.currentGlobalSettings.cycleAllClientsRespectExclusions = getFieldValue('cycleAllClientsRespectExclusions');
        app.currentGlobalSettings.runOnStartup = getFieldValue('runOnStartup');
        app.currentGlobalSettings.autoRegisterProtocol = getFieldValue('autoRegisterProtocol');
        app.currentGlobalSettings.disableUpdateChecks = getFieldValue('disableUpdateChecksToggle');
        app.currentGlobalSettings.hotkeyCycleNotLoggedInForward = getFieldValue('hotkeyCycleNotLoggedInForward') || null;
        app.currentGlobalSettings.hotkeyCycleNotLoggedInBackward = getFieldValue('hotkeyCycleNotLoggedInBackward') || null;
        app.currentGlobalSettings.hotkeyReturnToLastApp = getFieldValue('hotkeyReturnToLastApp') || null;
    }

    const hotkeyConflicts = updateHotkeyConflictHighlights();
    if (hotkeyConflicts.length > 0) {
        // A conflicting key can live on the characters or hotkey-groups tab as easily as the hotkeys one, so the first one decides where to land.
        switchTab(hotkeyConflicts[0][0]?.closest('.panel-content')?.dataset.panel || 'hotkeys');
        showHotkeyConflictModal(describeHotkeyConflicts(hotkeyConflicts));
        return;
    }

    try {
        if (typeof webui !== 'undefined') {
            // Before saveConfig, whose profile reload is what picks up the new global settings.
            if (app.currentGlobalSettings) {
                await rpc('saveGlobalSettings', { json: JSON.stringify(app.currentGlobalSettings) });
            }

            await rpc('saveConfig', { json: JSON.stringify(app.currentConfig) });
            showStatus(t('status.configSavedSuccess'), 'success');
            // Saving always makes this profile the running one (see saveConfig in dialog/api/session.zig), so live preview can resume for it.
            app.liveConfirmedProfile = app.dialogEditingProfile;
            app.deletedCharacterNames.clear();
            snapshotDiskGroupMembers(app.currentConfig.hotkeyGroups);
            markAsSaved();
        } else {
            showStatus(t('status.configSavedMock'), 'success');
            markAsSaved();
        }
    } catch (error) {
        logError('Save failed:', error);
        showStatus(t('status.saveConfigFailedPrefix') + error.message, 'error');
    }
}

// Avoids overwriting positions that were changed by dragging after the dialog was opened.
async function reloadLivePositions() {
    try {
        if (typeof webui !== 'undefined') {
            const savedConfig = await rpc('loadConfig');

            if (savedConfig.characters && Array.isArray(savedConfig.characters)) {
                if (!app.currentConfig.characters) app.currentConfig.characters = [];
                savedConfig.characters.forEach(savedChar => {
                    if (!savedChar.position) return;
                    if (app.deletedCharacterNames.has((savedChar.name || '').trim().toLowerCase())) return;
                    const char = app.currentConfig.characters.find(c => c.name === savedChar.name);
                    if (char) {
                        char.position = savedChar.position;
                    } else {
                        // Character was dragged (creating its first saved position) after the dialog snapshot - without this it would be dropped entirely.
                        app.currentConfig.characters.push(savedChar);
                    }
                });
            }

            if (savedConfig.display) {
                if (!app.currentConfig.display) app.currentConfig.display = {};
                app.currentConfig.display.startX = savedConfig.display.startX;
                app.currentConfig.display.startY = savedConfig.display.startY;
                app.currentConfig.display.notifInfoPanelX = savedConfig.display.notifInfoPanelX;
                app.currentConfig.display.notifInfoPanelY = savedConfig.display.notifInfoPanelY;
            }
        }
    } catch (error) {
        logError('Failed to reload live positions:', error);
        // Continue with save even if reload fails - better than blocking the save
    }
}
