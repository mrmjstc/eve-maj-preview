// The Window Filters list and its running-window picker.
import { app } from './state.js';
import { applyDocToForm, defaultFor, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { populateCharacters, removeCharacterByName, saveCharacters } from './characters.js';
import { escapeHtml, logError, rpc } from './core.js';
import { populateHotkeyGroups, saveHotkeyGroups } from './hotkey_groups.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { alignDetailPanelNameLabel, selectMasterDetailRow, syncAccordionHeaderName } from './widgets.js';

// Which filter's detail panel is showing in the master-detail window filters view.
let selectedWindowFilterIndex = 0;
// The filter name as its field took focus, for carryWindowFilterRename.
let nameBeforeEdit = '';

export function populateWindowFilters() {
    const container = document.getElementById('windowFiltersList');
    if (!container) return;

    const filters = app.currentConfig.windowFilters || [];
    // The built-in EVE filter (the list's default) isn't user-editable.
    const builtInName = defaultFor('windowFilters')?.[0]?.name;
    const editableIndexes = filters.reduce((acc, f, i) => { if (f.name !== builtInName) acc.push(i); return acc; }, []);

    if (editableIndexes.length === 0) {
        container.innerHTML = `
            <div class="master-detail">
                <div class="roster">
                    <div class="roster-row roster-row-empty">
                        <span class="hint">${t('tab.general.section.window-filters.empty-roster')}</span>
                    </div>
                </div>
                <div class="detail-stack">
                    <p class="hint">${t('tab.general.section.window-filters.empty-detail')}</p>
                </div>
            </div>
        `;
        return;
    }

    if (!editableIndexes.includes(selectedWindowFilterIndex)) selectedWindowFilterIndex = editableIndexes[0];

    const rosterRows = editableIndexes.map(index => {
        const filter = filters[index];
        const displayName = filter.name || `${t('dynamic.windowFilter.defaultNewName')} ${index + 1}`;
        return `
            <div class="roster-row ${index === selectedWindowFilterIndex ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${index === selectedWindowFilterIndex}" data-index="${index}" onclick="selectWindowFilter(${index})">
                <span class="roster-name" id="filter_${index}_header_name">${escapeHtml(displayName)}</span>
                ${filter.enabled === false ? `<span class="roster-hotkey-badge">${t('dynamic.windowFilter.disabledBadge')}</span>` : ''}
            </div>
        `;
    }).join('');

    const detailPanels = editableIndexes.map(index => {
        const filter = filters[index];
        return `
            <div class="detail-panel ${index === selectedWindowFilterIndex ? 'active' : ''}" data-index="${index}">
                <div class="detail-panel-header">
                    <label class="detail-panel-name-label" for="filter_${index}_name">${t('dynamic.windowFilter.nameLabel')}</label>
                    <input type="text" class="detail-panel-name-input" id="filter_${index}_name" data-path="windowFilters.${index}.name" placeholder="${t('dynamic.windowFilter.namePlaceholder')}" oninput="updateWindowFilterHeaderName(${index})" onfocus="rememberWindowFilterName(${index})" onchange="carryWindowFilterRename(${index})">
                    <button type="button" id="filter_${index}_removeBtn" onclick="confirmRemove('filter_${index}_removeBtn', () => removeWindowFilter(${index}))">${t('common.remove')}</button>
                </div>
                <label>
                    <input type="checkbox" id="filter_${index}_enabled" data-path="windowFilters.${index}.enabled">
                    <span class="label-body">${t('common.enabledLabel')}</span>
                </label>
                <div class="detail-form">
                    <div class="detail-field">
                        <label for="filter_${index}_classes">${t('dynamic.windowFilter.classesLabel')}</label>
                        <input type="text" id="filter_${index}_classes" data-path="windowFilters.${index}.class_names" data-format="csv" placeholder="${t('dynamic.windowFilter.classesPlaceholder')}">
                        <p class="hint hint-extra">${t('dynamic.windowFilter.classesHint')}</p>
                    </div>
                    <div class="detail-field">
                        <label for="filter_${index}_exes">${t('dynamic.windowFilter.exesLabel')}</label>
                        <input type="text" id="filter_${index}_exes" data-path="windowFilters.${index}.executable_names" data-format="csv" placeholder="${t('dynamic.windowFilter.exesPlaceholder')}">
                    </div>
                    <div class="detail-field">
                        <label>${t('dynamic.windowFilter.detectLabel')}</label>
                        <button type="button" id="filter_${index}_pickBtn" onclick="pickRunningWindowForFilter(${index})" class="full-width-btn">${t('button.pick-running-window.label')}</button>
                    </div>
                </div>
                <select id="filter_${index}_picker" class="picker-select" onchange="applyPickedWindowForFilter(${index})"></select>
            </div>
        `;
    }).join('');

    container.innerHTML = `
        <div class="master-detail">
            <div class="roster" role="tablist" aria-orientation="vertical">${rosterRows}</div>
            <div class="detail-stack">${detailPanels}</div>
        </div>
    `;

    applyDocToForm(path => path.startsWith('windowFilters.'), container);
    // innerHTML above replaced the elements the last measuring pass sized.
    alignDetailPanelNameLabel('windowFiltersList');
}

export function updateWindowFilterHeaderName(index) {
    syncAccordionHeaderName(`filter_${index}_name`, `filter_${index}_header_name`, t('dynamic.windowFilter.defaultNewName'), index);
}

function filterNameInputValue(index) {
    return (document.getElementById(`filter_${index}_name`)?.value || '').trim();
}

export function rememberWindowFilterName(index) {
    nameBeforeEdit = filterNameInputValue(index);
}

// A filter's windows are named after it, so its character entry and hotkey group places follow a rename.
export function carryWindowFilterRename(index) {
    const oldName = nameBeforeEdit;
    nameBeforeEdit = '';
    const newName = filterNameInputValue(index);
    if (!oldName || !newName || oldName === newName) return;

    saveCharacters();
    saveHotkeyGroups();
    const characters = app.currentConfig.characters || [];
    const findCharacter = name => characters.find(c => (c.name || '').trim().toLowerCase() === name.toLowerCase());
    const entry = findCharacter(oldName);
    const clash = findCharacter(newName);
    if (entry && (!clash || clash === entry)) entry.name = newName;

    for (const group of app.currentConfig.hotkeyGroups || []) {
        if (!group.characters?.includes(oldName)) continue;
        group.characters = [...new Set(group.characters.map(name => name === oldName ? newName : name))];
    }

    if (app.pendingCharacterNames.delete(oldName.toLowerCase())) app.pendingCharacterNames.set(newName.toLowerCase(), newName);
    markAsChanged();
    populateCharacters();
    populateHotkeyGroups();
}

export function selectWindowFilter(index) {
    selectedWindowFilterIndex = index;
    selectMasterDetailRow('windowFiltersList', index);
}

export function addWindowFilter() {
    if (!app.currentConfig) return;
    if (!app.currentConfig.windowFilters) app.currentConfig.windowFilters = [];
    saveWindowFilters();
    app.currentConfig.windowFilters.push({
        name: t('dynamic.windowFilter.defaultNewName'),
        enabled: true,
        class_names: [],
        executable_names: []
    });
    markAsChanged();

    selectedWindowFilterIndex = app.currentConfig.windowFilters.length - 1;
    populateWindowFilters();
}

export function removeWindowFilter(index) {
    if (app.currentConfig.windowFilters && app.currentConfig.windowFilters[index]) {
        saveWindowFilters();
        const removedName = app.currentConfig.windowFilters[index].name || '';
        app.currentConfig.windowFilters.splice(index, 1);
        app.pendingCharacterNames.delete(removedName.trim().toLowerCase());
        removeCharacterByName(removedName);
        if (selectedWindowFilterIndex >= index) selectedWindowFilterIndex = Math.max(0, selectedWindowFilterIndex - 1);
        markAsChanged();
        populateWindowFilters();
    }
}

export function saveWindowFilters() {
    readFormToDoc(path => path.startsWith('windowFilters.'));
}

export async function pickRunningWindowFor(idPrefix, index) {
    const btn = document.getElementById(`${idPrefix}_${index}_pickBtn`);
    const select = document.getElementById(`${idPrefix}_${index}_picker`);
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let windows = [];
        if (typeof eveRpc !== 'undefined') {
            windows = await rpc('getRunningWindows');
        }

        if (windows.length === 0) {
            showStatus(t('status.noRunningWindows'), 'error');
            return;
        }

        select.innerHTML = `<option value="">${escapeHtml(t('dynamic.windowFilter.pickerDefaultOption'))}</option>` +
            windows.map((w, i) => `<option value="${i}">${escapeHtml(w.title)} — ${escapeHtml(w.exe)}</option>`).join('');
        select.dataset.windows = JSON.stringify(windows);
        select.style.display = 'block';
    } catch (error) {
        logError('Failed to scan running windows:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('button.pick-running-window.label'); }
    }
}

export function pickRunningWindowForFilter(index) {
    return pickRunningWindowFor('filter', index);
}

export function resolvePickedWindow(idPrefix, index) {
    const select = document.getElementById(`${idPrefix}_${index}_picker`);
    if (!select || select.value === '') return null;
    const windows = JSON.parse(select.dataset.windows || '[]');
    const chosen = windows[parseInt(select.value, 10)];
    return chosen ? { select, chosen } : null;
}

export function applyPickedWindowForFilter(index) {
    const picked = resolvePickedWindow('filter', index);
    if (!picked) return;
    const { chosen } = picked;

    const classesInput = document.getElementById(`filter_${index}_classes`);
    const exesInput = document.getElementById(`filter_${index}_exes`);
    if (classesInput) classesInput.value = chosen.class;
    if (exesInput) exesInput.value = chosen.exe;

    const nameInput = document.getElementById(`filter_${index}_name`);
    const friendlyName = chosen.exe.replace(/\.exe$/i, '');
    if (nameInput) nameInput.value = friendlyName;
    updateWindowFilterHeaderName(index);

    app.pendingCharacterNames.set(friendlyName.trim().toLowerCase(), friendlyName);
}
