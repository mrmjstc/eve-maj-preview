// Settings shared by every profile, and the window's own scale and always-on-top.
import { app } from './state.js';
import { refreshCharacterPortraits } from './characters.js';
import { logError, logWarn, rpc } from './core.js';
import { applyDocToForm } from './binding.js';
import { setFieldValue } from './form.js';
import { populateAppHotkeys, populateProfileSwitchHotkeys, populateUrlHotkeys } from './global_hotkeys.js';
import { buildSectionNav, switchTab } from './layout.js';
import { populateOreTable } from './ore_table.js';

export async function applyGlobalSettingsToForm() {
    const settings = app.currentGlobalSettings;
    await populateProfileSwitchHotkeys();
    populateAppHotkeys();
    populateUrlHotkeys();
    populateOreTable();

    applyDocToForm(path => path.startsWith('global.'));
    // Not bound: the app saves the window's scale as soon as it changes, outside Save.
    setFieldValue('dialogScaleSelect', String(settings.dialogScale || 0));

    document.body.classList.toggle('advanced-mode', !!settings.advancedMode);
    buildSectionNav();

    refreshCharacterPortraits();
}

// Preference lives in global.settings.json so it applies across all profiles.
export function toggleAdvancedMode() {
    const enabled = document.getElementById('advancedModeToggle').checked;
    document.body.classList.toggle('advanced-mode', enabled);
    buildSectionNav();

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

    app.currentGlobalSettings.alwaysOnTop = enabled;

    rpc('setAlwaysOnTop', { enabled }).catch((error) => logWarn('Failed to set always on top:', error));
}
