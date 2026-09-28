// Profile-switch, app and URL hotkeys.
import { app } from './state.js';
import { applyDocToForm, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { escapeHtml } from './core.js';
import { alignBindingLabelColumns, hotkeyToSaved, renderHotkeyInputHtml, updateHotkeyConflictHighlights, vkHexToFriendly } from './hotkeys.js';
import { t } from './i18n.js';
import { getAvailableProfileNames } from './profiles.js';
import { scrollContentPanelToBottom } from './widgets.js';
import { pickRunningWindowFor, resolvePickedWindow } from './window_filters.js';

// Ids can't contain the profile filename's dots/spaces verbatim, so rows and saveProfileSwitchHotkeys() both derive the field id from this.
function profileHotkeyFieldId(profile) {
    return profile.replace(/[^a-zA-Z0-9_-]/g, '_');
}

// One row per existing profile rather than a user-managed list - adding/deleting a profile just changes which rows populate() draws next.
// Uses the same .binding/.binding-control markup as the fixed HOTKEY_BINDINGS rows so labels and fields share their column widths via alignBindingLabelColumns().
export async function populateProfileSwitchHotkeys() {
    const container = document.getElementById('profileSwitchHotkeysList');
    if (!container) return;

    const profiles = await getAvailableProfileNames();
    const entries = app.currentGlobalSettings?.profileSwitchHotkeys || [];

    container.innerHTML = profiles.map(profile => {
        const entry = entries.find(e => e.targetProfile === profile);
        const displayName = profile.replace(/\.json$/, '');
        const fieldId = `pshotkey_${profileHotkeyFieldId(profile)}_hotkey`;
        const label = `${t('dynamic.profileSwitchHotkey.switchToLabel')} ${escapeHtml(displayName)}`;

        return `
            <div class="binding" data-profile="${escapeHtml(profile)}">
                <label for="${fieldId}">${label}</label>
                <div class="binding-control">
                    <div class="field-row">${renderHotkeyInputHtml(fieldId, vkHexToFriendly(entry?.hotkey) || '', t('dynamic.profileSwitchHotkey.hotkeyPlaceholder'))}</div>
                </div>
            </div>
        `;
    }).join('');

    alignBindingLabelColumns();
    updateHotkeyConflictHighlights();
}

// Keeps the saved order and entries without a row, so reading back an untouched form changes nothing.
export function saveProfileSwitchHotkeys() {
    if (!app.currentGlobalSettings) return;
    const container = document.getElementById('profileSwitchHotkeysList');
    if (!container) return;

    const shown = new Map();
    container.querySelectorAll('[data-profile]').forEach(row => {
        const profile = row.dataset.profile;
        shown.set(profile, hotkeyToSaved(document.getElementById(`pshotkey_${profileHotkeyFieldId(profile)}_hotkey`)?.value));
    });
    const entries = app.currentGlobalSettings.profileSwitchHotkeys || [];
    const result = entries
        .filter(entry => !shown.has(entry.targetProfile) || shown.get(entry.targetProfile))
        .map(entry => shown.has(entry.targetProfile) ? { ...entry, hotkey: shown.get(entry.targetProfile) } : entry);
    for (const [profile, hotkey] of shown) {
        if (hotkey && !entries.some(entry => entry.targetProfile === profile)) result.push({ hotkey, targetProfile: profile });
    }
    app.currentGlobalSettings.profileSwitchHotkeys = result;
}

export function populateAppHotkeys() {
    const container = document.getElementById('appHotkeysList');
    if (!container) return;

    const entries = app.currentGlobalSettings?.appHotkeys || [];

    container.innerHTML = '';
    entries.forEach((entry, index) => {
        const row = document.createElement('div');
        // The picker rides under its row, so each entry keeps its two parts together.
        row.innerHTML = `
            <div class="field-row list-container">
                <input type="text" id="apphotkey_${index}_exe" data-path="global.appHotkeys.${index}.executableName" placeholder="${t('dynamic.appHotkey.exePlaceholder')}" aria-label="${escapeHtml(t('dynamic.appHotkey.targetLabel'))}">
                ${renderHotkeyInputHtml(`apphotkey_${index}_hotkey`, '', t('dynamic.appHotkey.hotkeyPlaceholder'), ` aria-label="${escapeHtml(t('common.hotkeyLabel'))}" data-path="global.appHotkeys.${index}.hotkey"`)}
                <button type="button" id="apphotkey_${index}_pickBtn" onclick="pickRunningWindowForAppHotkey(${index})" class="btn-nowrap">${t('button.pick-running-window.label')}</button>
                <button type="button" class="button-remove" id="apphotkey_${index}_removeBtn" onclick="confirmRemove('apphotkey_${index}_removeBtn', () => removeAppHotkey(${index}))">${t('common.remove')}</button>
            </div>
            <select id="apphotkey_${index}_picker" class="picker-select" onchange="applyPickedWindowForAppHotkey(${index})"></select>
        `;
        container.appendChild(row);
    });

    applyDocToForm(path => path.startsWith('global.appHotkeys.'), container);
    updateHotkeyConflictHighlights();
}

export function addAppHotkey() {
    if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
    if (!app.currentGlobalSettings.appHotkeys) app.currentGlobalSettings.appHotkeys = [];
    saveAppHotkeys();

    app.currentGlobalSettings.appHotkeys.push({
        hotkey: null,
        executableName: ''
    });
    markAsChanged();

    populateAppHotkeys();
    scrollContentPanelToBottom();
}

export function removeAppHotkey(index) {
    if (app.currentGlobalSettings?.appHotkeys && app.currentGlobalSettings.appHotkeys[index]) {
        saveAppHotkeys();
        app.currentGlobalSettings.appHotkeys.splice(index, 1);
        markAsChanged();
        populateAppHotkeys();
    }
}

export function saveAppHotkeys() {
    readFormToDoc(path => path.startsWith('global.appHotkeys.'));
}

export function pickRunningWindowForAppHotkey(index) {
    return pickRunningWindowFor('apphotkey', index);
}

export function applyPickedWindowForAppHotkey(index) {
    const picked = resolvePickedWindow('apphotkey', index);
    if (!picked) return;
    const { select, chosen } = picked;

    const exeInput = document.getElementById(`apphotkey_${index}_exe`);
    if (exeInput) exeInput.value = chosen.exe;

    select.style.display = 'none';
    select.value = '';
}

function isAdashboardUrl(url) {
    try {
        return new URL(url).hostname.toLowerCase() === 'adashboard.info';
    } catch {
        return false;
    }
}

export function populateUrlHotkeys() {
    const container = document.getElementById('urlHotkeysList');
    if (!container) return;

    const entries = app.currentGlobalSettings?.urlHotkeys || [];

    container.innerHTML = '';
    entries.forEach((entry, index) => {
        const row = document.createElement('div');
        // The clipboard option only applies to aDashboard URLs, so it hangs under the row it belongs to.
        row.innerHTML = `
            <div class="field-row list-container">
                <input type="text" id="urlhotkey_${index}_url" data-path="global.urlHotkeys.${index}.url" placeholder="${t('dynamic.urlHotkey.urlPlaceholder')}" aria-label="${escapeHtml(t('dynamic.urlHotkey.targetLabel'))}" oninput="updateUrlHotkeyUploadClipboardVisibility(${index})">
                ${renderHotkeyInputHtml(`urlhotkey_${index}_hotkey`, '', t('dynamic.urlHotkey.hotkeyPlaceholder'), ` aria-label="${escapeHtml(t('common.hotkeyLabel'))}" data-path="global.urlHotkeys.${index}.hotkey"`)}
                <button type="button" class="button-remove" id="urlhotkey_${index}_removeBtn" onclick="confirmRemove('urlhotkey_${index}_removeBtn', () => removeUrlHotkey(${index}))">${t('common.remove')}</button>
            </div>
            <label id="urlhotkey_${index}_uploadClipboardRow" class="list-container" style="display: ${isAdashboardUrl(entry.url) ? 'block' : 'none'};">
                <input type="checkbox" id="urlhotkey_${index}_uploadClipboard" data-path="global.urlHotkeys.${index}.uploadClipboard">
                <span class="label-body">${t('dynamic.urlHotkey.uploadClipboardLabel')}</span>
            </label>
        `;
        container.appendChild(row);
    });

    applyDocToForm(path => path.startsWith('global.urlHotkeys.'), container);
    updateHotkeyConflictHighlights();
}

export function addUrlHotkey(presetUrl) {
    if (!app.currentGlobalSettings) app.currentGlobalSettings = {};
    if (!app.currentGlobalSettings.urlHotkeys) app.currentGlobalSettings.urlHotkeys = [];
    saveUrlHotkeys();

    app.currentGlobalSettings.urlHotkeys.push({
        hotkey: null,
        url: presetUrl || '',
        uploadClipboard: false
    });
    markAsChanged();

    populateUrlHotkeys();
    scrollContentPanelToBottom();
}

export function removeUrlHotkey(index) {
    if (app.currentGlobalSettings?.urlHotkeys && app.currentGlobalSettings.urlHotkeys[index]) {
        saveUrlHotkeys();
        app.currentGlobalSettings.urlHotkeys.splice(index, 1);
        markAsChanged();
        populateUrlHotkeys();
    }
}

export function updateUrlHotkeyUploadClipboardVisibility(index) {
    const urlInput = document.getElementById(`urlhotkey_${index}_url`);
    const row = document.getElementById(`urlhotkey_${index}_uploadClipboardRow`);
    const checkbox = document.getElementById(`urlhotkey_${index}_uploadClipboard`);
    if (!urlInput || !row || !checkbox) return;

    const eligible = isAdashboardUrl(urlInput.value);
    row.style.display = eligible ? 'block' : 'none';
    if (!eligible) checkbox.checked = false;
}

export function saveUrlHotkeys() {
    readFormToDoc(path => path.startsWith('global.urlHotkeys.'));
}
