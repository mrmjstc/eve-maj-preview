// Settings shared by every profile, and the window's own scale and always-on-top.
import { app } from './state.js';
import { markAsSaved } from './changes.js';
import { refreshCharacterPortraits } from './characters.js';
import { logError, logWarn, rpc } from './core.js';
import { setCheckboxValue, setFieldValue } from './form.js';
import { populateAppHotkeys, populateProfileSwitchHotkeys, populateUrlHotkeys } from './global_hotkeys.js';
import { vkHexToFriendly } from './hotkeys.js';
import { buildSectionNav, switchTab } from './layout.js';
import { populateOreTable } from './ore_table.js';

export async function loadGlobalSettingsFromBackend() {
    try {
        if (typeof webui !== 'undefined') {
            app.currentGlobalSettings = await rpc('loadGlobalSettings');
        } else {
            app.currentGlobalSettings = {};
        }
    } catch (error) {
        logError('Failed to load global settings:', error);
        app.currentGlobalSettings = {};
    }

    if (!app.currentGlobalSettings.profileSwitchHotkeys) app.currentGlobalSettings.profileSwitchHotkeys = [];
    await populateProfileSwitchHotkeys();

    if (!app.currentGlobalSettings.appHotkeys) app.currentGlobalSettings.appHotkeys = [];
    populateAppHotkeys();

    if (!app.currentGlobalSettings.urlHotkeys) app.currentGlobalSettings.urlHotkeys = [];
    populateUrlHotkeys();

    if (!app.currentGlobalSettings.oreTable) app.currentGlobalSettings.oreTable = [];
    populateOreTable();

    setFieldValue('logLevel', app.currentGlobalSettings.logLevel || 'err');
    setFieldValue('languageSelect', app.currentGlobalSettings.language || 'en');
    setFieldValue('dialogScaleSelect', String(app.currentGlobalSettings.dialogScale || 0));
    setFieldValue('hotkeyNextProfile', vkHexToFriendly(app.currentGlobalSettings.hotkeyNextProfile));
    setFieldValue('hotkeyPreviousProfile', vkHexToFriendly(app.currentGlobalSettings.hotkeyPreviousProfile));
    setFieldValue('hotkeyCycleAllClientsForward', vkHexToFriendly(app.currentGlobalSettings.hotkeyCycleAllClientsForward));
    setFieldValue('hotkeyCycleAllClientsBackward', vkHexToFriendly(app.currentGlobalSettings.hotkeyCycleAllClientsBackward));
    setCheckboxValue('cycleAllClientsRespectExclusions', app.currentGlobalSettings.cycleAllClientsRespectExclusions);
    setCheckboxValue('runOnStartup', app.currentGlobalSettings.runOnStartup);
    setCheckboxValue('autoRegisterProtocol', app.currentGlobalSettings.autoRegisterProtocol);
    setCheckboxValue('disableUpdateChecksToggle', app.currentGlobalSettings.disableUpdateChecks);
    setFieldValue('hotkeyCycleNotLoggedInForward', vkHexToFriendly(app.currentGlobalSettings.hotkeyCycleNotLoggedInForward));
    setFieldValue('hotkeyCycleNotLoggedInBackward', vkHexToFriendly(app.currentGlobalSettings.hotkeyCycleNotLoggedInBackward));
    setFieldValue('hotkeyReturnToLastApp', vkHexToFriendly(app.currentGlobalSettings.hotkeyReturnToLastApp));

    setCheckboxValue('alwaysOnTopToggle', app.currentGlobalSettings.alwaysOnTop);

    const advancedModeEnabled = !!app.currentGlobalSettings.advancedMode;
    setCheckboxValue('advancedModeToggle', advancedModeEnabled);
    document.body.classList.toggle('advanced-mode', advancedModeEnabled);
    buildSectionNav();

    refreshCharacterPortraits();

    // loadConfigurationFromBackend() and this function fire concurrently at startup (see the comment
    // near refreshCharacterPortraits), so whichever finishes last must be the one to set the saved
    // baseline - otherwise a fingerprint taken before this function's fields were populated would
    // make the close-guard think they're an unsaved edit.
    markAsSaved();
}

// Preference lives in global.settings.json so it applies across all profiles.
export function toggleAdvancedMode() {
    const enabled = document.getElementById('advancedModeToggle').checked;
    document.body.classList.toggle('advanced-mode', enabled);
    buildSectionNav();

    if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
    app.currentGlobalSettings.advancedMode = enabled;

    // If an advanced-only tab was open when Advanced Mode got turned off, its sidebar entry just vanished - move to the always-visible About tab.
    if (!enabled) {
        const activePanel = document.querySelector('.panel-content.active');
        if (activePanel && activePanel.classList.contains('advanced-tab-panel')) {
            switchTab('about');
        }
    }
}

export function toggleSectionHint(btn) {
    const visible = btn.closest('.section').classList.toggle('hints-visible');
    btn.classList.toggle('hint-toggle-active', visible);
}

// Saved by the backend immediately, so it stays outside the save/unsaved-changes flow.
export async function changeDialogScale() {
    const percent = parseInt(document.getElementById('dialogScaleSelect').value, 10) || 0;
    if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
    app.currentGlobalSettings.dialogScale = percent;

    try {
        const result = await rpc('setDialogScale', { percent });
        document.documentElement.style.setProperty('--ui-scale', result.scale);
        // Resize listeners already ran before the new scale applied.
        window.dispatchEvent(new Event('resize'));
    } catch (error) {
        logError('Failed to apply UI scale:', error);
    }
}

// Preference lives in global.settings.json so it applies across all profiles.
export function toggleAlwaysOnTop() {
    const enabled = document.getElementById('alwaysOnTopToggle').checked;

    if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
    app.currentGlobalSettings.alwaysOnTop = enabled;

    rpc('setAlwaysOnTop', { enabled }).catch((error) => logWarn('Failed to set always on top:', error));
}
