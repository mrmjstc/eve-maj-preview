// The Characters list, portraits and saved game-window positions.
import { app } from './state.js';
import { applyDocToForm, applySchemaToInputs, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { escapeHtml, logError, rpc } from './core.js';
import { renderHotkeyInputHtml, updateHotkeyConflictHighlights, vkHexToFriendly } from './hotkeys.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { flushEdits } from './session.js';
import { alignDetailPanelNameLabel, confirmRemove, makeRosterSearchFilter, moveArrayItem, selectMasterDetailRow, setupDragReorder, syncAccordionHeaderName } from './widgets.js';

export function addCharacterIfMissing(name) {
    if (!app.currentConfig.characters) app.currentConfig.characters = [];
    saveCharacters();

    const exists = app.currentConfig.characters.some(c => (c.name || '').trim().toLowerCase() === name.trim().toLowerCase());
    if (exists) return;

    app.currentConfig.characters.push({
        name: name,
        position: null, // Unset -> backend auto-arranges via layoutMode instead of pinning to (0,0)
        borderColors: null,
        thumbnailSize: null,
        displayName: null,
        hotkey: null,
        excludeFromMinimize: true
    });
    populateCharacters();
}

// Which character's detail panel is showing in the master-detail characters view.
let selectedCharacterIndex = 0;

// Applied after every populateCharacters() rebuild so the filter survives add/remove/reorder.
const characterSearchFilter = makeRosterSearchFilter('charactersList');
export function onCharacterSearchInput(query) { characterSearchFilter.onInput(query); }
export function clearCharacterSearch() { characterSearchFilter.clear('characterSearchFilter'); }
function applyCharacterFilter() { characterSearchFilter.apply(); }

// Character IDs are learned at runtime from chatlog filenames and cached in global settings, so a freshly added or renamed character has no portrait until the app has seen a chatlog for it.
function characterPortraitUrl(name) {
    const id = app.characterIds[(name || '').trim()];
    return id ? `https://images.evetech.net/characters/${id}/portrait?size=128` : null;
}

function applyCharacterPortrait(img, name) {
    if (!img) return;
    const url = characterPortraitUrl(name);
    if (url) {
        img.src = url;
        img.style.display = '';
    } else {
        img.removeAttribute('src');
        img.style.display = 'none';
    }
}

export function refreshCharacterPortraits() {
    (app.currentConfig?.characters || []).forEach((char, index) => {
        applyCharacterPortrait(document.getElementById(`char_${index}_portrait`), char.name);
    });
}

function updateCharacterHeaderPortrait(index) {
    applyCharacterPortrait(document.getElementById(`char_${index}_portrait`), document.getElementById(`char_${index}_name`)?.value);
}

// So a freshly loaded profile opens straight into an editable row instead of an empty-roster placeholder.
export function ensureBlankRosterEntries() {
    if (!app.currentConfig) return;

    if (!app.currentConfig.characters || app.currentConfig.characters.length === 0) {
        app.currentConfig.characters = [{
            name: '',
            position: null,
            borderColors: null,
            thumbnailSize: null,
            displayName: null,
            hotkey: null
        }];
    }

    if (!app.currentConfig.hotkeyGroups || app.currentConfig.hotkeyGroups.length === 0) {
        app.currentConfig.hotkeyGroups = [{
            name: '',
            forwardKey: '',
            backwardKey: null,
            assignKey: null,
            temporaryMembership: false,
            showBadge: false,
            includeNotLoggedIn: false,
            characters: []
        }];
    }
}

export function populateCharacters() {
    const container = document.getElementById('charactersList');
    if (!container) return;

    const chars = app.currentConfig.characters || [];

    if (chars.length === 0) {
        container.innerHTML = `
            <div class="master-detail">
                <div class="roster">
                    <div class="roster-row roster-row-empty">
                        <span class="hint">${t('tab.characters.section.per-character-configuration.empty-roster')}</span>
                    </div>
                </div>
                <div class="detail-stack">
                    <p class="hint">${t('tab.characters.section.per-character-configuration.empty-detail')}</p>
                </div>
            </div>
        `;
        return;
    }

    if (selectedCharacterIndex >= chars.length) selectedCharacterIndex = chars.length - 1;
    if (selectedCharacterIndex < 0) selectedCharacterIndex = 0;

    const rosterRows = chars.map((char, index) => {
        // Portraits hidden for now - see .character-portrait usage below.
        const portraitUrl = characterPortraitUrl(char.name);
        const hotkeyDisplay = char.hotkey ? vkHexToFriendly(char.hotkey) : '';
        return `
            <div class="roster-row ${index === selectedCharacterIndex ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${index === selectedCharacterIndex}" data-index="${index}" onclick="selectCharacter(${index})">
                <span class="drag-index-chip character-drag-handle" draggable="true" title="${t('common.dragToReorder')}" onclick="event.stopPropagation()">${String(index + 1).padStart(2, '0')}</span>
                <!-- <img class="character-portrait" id="char_${index}_portrait" src="${portraitUrl || ''}" alt="" draggable="false" style="${portraitUrl ? '' : 'display:none'}" onerror="this.style.display='none'"> -->
                <span class="roster-name" id="char_${index}_header_name">${escapeHtml(char.name || t('dynamic.character.defaultNamePrefix') + ' ' + (index + 1))}</span>
                <span class="roster-hotkey-badge" id="char_${index}_hotkeyBadge" style="${hotkeyDisplay ? '' : 'display:none'}">[${hotkeyDisplay}]</span>
            </div>
        `;
    }).join('');

    const detailPanels = chars.map((char, index) => `
        <div class="detail-panel ${index === selectedCharacterIndex ? 'active' : ''}" data-index="${index}">
            <div class="detail-panel-header">
                <label class="detail-panel-name-label" for="char_${index}_name">${t('common.characterName')}</label>
                <input type="text" class="detail-panel-name-input" id="char_${index}_name" data-path="characters.${index}.name" placeholder="${t('common.characterName')}" autocomplete="off" data-suggest-siblings="#charactersList .detail-panel-name-input" onfocus="suggestOpenClients(this)" oninput="updateCharacterHeaderName(${index})">
                <button type="button" id="char_${index}_removeBtn" onclick="confirmRemoveCharacter(${index})">${t('common.remove')}</button>
            </div>
            <div class="detail-form">
                <div class="detail-field">
                    <label for="char_${index}_displayName">${t('dynamic.character.displayNameLabel')}</label>
                    <input type="text" id="char_${index}_displayName" data-path="characters.${index}.displayName" placeholder="${t('dynamic.character.displayNamePlaceholder')}">
                    <p class="hint hint-extra">${t('dynamic.character.displayNameHint')}</p>
                </div>
                <div class="detail-field">
                    <label for="char_${index}_hotkey">${t('common.hotkeyLabel')}</label>
                    <div class="field-row">${renderHotkeyInputHtml(`char_${index}_hotkey`, '', t('dynamic.character.hotkeyPlaceholder'), ` data-path="characters.${index}.hotkey"`)}</div>
                </div>
                <div class="detail-field">
                    <label for="char_${index}_width">${t('dynamic.character.thumbnailSizeHeading')}</label>
                    <div class="field-row detail-size">
                        <input type="number" id="char_${index}_width" data-path="characters.${index}.thumbnailSize.width" placeholder="${t('dynamic.character.widthPlaceholder')}">
                        <span class="detail-size-x">&times;</span>
                        <input type="number" id="char_${index}_height" data-path="characters.${index}.thumbnailSize.height" placeholder="${t('dynamic.character.heightPlaceholder')}">
                    </div>
                    <p class="hint hint-extra">${t('dynamic.character.thumbnailSizeHint')}</p>
                </div>
                <div class="detail-field">
                    <label for="char_${index}_opacity">${t('dynamic.character.opacityLabel')}</label>
                    <div class="field-row">
                        <input type="range" id="char_${index}_opacity" data-path="characters.${index}.opacity" data-unit="%" data-inherit="thumbnail.thumbnailOpacity" data-value-target="char_${index}_opacityValue">
                        <span id="char_${index}_opacityValue"></span>%
                    </div>
                    <p class="hint hint-extra">${t('dynamic.character.opacityHint')}</p>
                </div>
                <div class="detail-field">
                    <label>${t('dynamic.character.borderColorsHeading')}</label>
                    <div class="detail-checks detail-color-rows">
                        <div class="color-row">
                            <span class="label-body">${t('dynamic.character.activeBorderColorLabel')}</span>
                            <div class="swatch-wrap">
                                <input type="color" id="char_${index}_activeColor" data-path="characters.${index}.borderColors.activeBorderColor" data-optional-color="true" data-default-color="#FFFF00">
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks detail-color-rows">
                        <div class="color-row">
                            <span class="label-body">${t('dynamic.character.inactiveBorderColorLabel')}</span>
                            <div class="swatch-wrap">
                                <input type="color" id="char_${index}_inactiveColor" data-path="characters.${index}.borderColors.inactiveBorderColor" data-optional-color="true" data-default-color="#606060">
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks detail-color-rows">
                        <div class="color-row">
                            <span class="label-body">${t('field.characterNameColor.label')}</span>
                            <div class="swatch-wrap">
                                <input type="color" id="char_${index}_nameColor" data-path="characters.${index}.nameColor" data-optional-color="true">
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label>${t('dynamic.character.behaviorHeading')}</label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="char_${index}_excludeMinimize" data-path="characters.${index}.excludeFromMinimize">
                            <span class="label-body">${t('dynamic.character.excludeMinimizeLabel')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="char_${index}_excludeCloseAll" data-path="characters.${index}.excludeFromCloseAll">
                            <span class="label-body">${t('dynamic.character.excludeCloseAllLabel')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="char_${index}_excludeAutoMove" data-path="characters.${index}.excludeFromAutoMove">
                            <span class="label-body">${t('dynamic.character.excludeAutoMoveLabel')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="char_${index}_hideThumbnail" data-path="characters.${index}.hideThumbnail">
                            <span class="label-body">${t('dynamic.character.hideThumbnailLabel')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="char_${index}_notificationsMuted" data-path="characters.${index}.notificationsMuted">
                            <span class="label-body">${t('dynamic.character.muteNotificationsLabel')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label>${t('dynamic.character.windowPositionHeading')}</label>
                    <div class="field-row detail-actions">
                        <span class="detail-value" id="char_${index}_windowPositionDisplay">${char.windowPosition ? `${char.windowPosition.x}, ${char.windowPosition.y}` : t('dynamic.character.windowPositionNotSet')}</span>
                        <button type="button" class="button-icon button-icon-danger" id="char_${index}_clearWindowPositionBtn" onclick="confirmClearCharacterWindowPosition(${index})" title="${t('dynamic.character.clearWindowPositionButton')}" aria-label="${t('dynamic.character.clearWindowPositionButton')}">&times;</button>
                        <button type="button" onclick="setCharacterWindowPosition(${index})">${t('dynamic.character.setWindowPositionButton')}</button>
                    </div>
                    <p class="hint hint-extra">${t('dynamic.character.windowPositionHint')}</p>
                </div>
            </div>
        </div>
    `).join('');

    container.innerHTML = `
        <div class="master-detail">
            <div class="roster" role="tablist" aria-orientation="vertical">${rosterRows}</div>
            <div class="detail-stack">${detailPanels}</div>
        </div>
    `;

    applySchemaToInputs(container);
    applyDocToForm(path => path.startsWith('characters.'), container);
    setupCharacterDragAndDrop();
    updateHotkeyConflictHighlights();
    applyCharacterFilter();
    // innerHTML above replaced the elements the last measuring pass sized.
    alignDetailPanelNameLabel('charactersList');
}

// Saved at once for the running profile, like a drag; another profile's draft keeps it until Save.
// Edits are flushed first, so the app already knows a character added here and doesn't create a second one.
export async function setCharacterWindowPosition(index) {
    const char = app.currentConfig.characters?.[index];
    if (!char) return;

    try {
        await flushEdits();
        const pos = await rpc('setCharacterWindowPosition', { name: char.name || '' });
        char.windowPosition = pos;
        refreshCharacterWindowPosition(index);
        showStatus(t('status.windowPositionSet'), 'success');
    } catch (error) {
        logError('Failed to set character window position:', error);
        showStatus(t('status.saveFailedPrefix') + error.message, 'error');
    }
}

export function refreshCharacterWindowPosition(index) {
    const pos = app.currentConfig.characters?.[index]?.windowPosition;
    const display = document.getElementById(`char_${index}_windowPositionDisplay`);
    if (display) display.textContent = pos ? `${pos.x}, ${pos.y}` : t('dynamic.character.windowPositionNotSet');
}

export function confirmClearCharacterWindowPosition(index) {
    confirmRemove(`char_${index}_clearWindowPositionBtn`, () => clearCharacterWindowPosition(index), '✓');
}

async function clearCharacterWindowPosition(index) {
    const char = app.currentConfig.characters?.[index];
    if (!char) return;

    try {
        await flushEdits();
        await rpc('clearCharacterWindowPosition', { name: char.name || '' });
        char.windowPosition = null;
        refreshCharacterWindowPosition(index);
        showStatus(t('status.windowPositionCleared'), 'success');
    } catch (error) {
        logError('Failed to clear character window position:', error);
        showStatus(t('status.saveFailedPrefix') + error.message, 'error');
    }
}

// Populates the "Copy Position From" dropdown with currently-open clients.
export async function refreshWindowPositionSourceOptions() {
    const select = document.getElementById('windowPositionSourceSelect');
    if (!select || typeof webui === 'undefined') return;

    const previousValue = select.value;
    try {
        const names = await rpc('getOpenClients');
        if (names.length === 0) {
            select.innerHTML = `<option value="">${escapeHtml(t('status.noOpenClients'))}</option>`;
            select.disabled = true;
            return;
        }
        select.disabled = false;
        select.innerHTML = names.map(name => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join('');
        if (names.includes(previousValue)) select.value = previousValue;
    } catch (error) {
        logError('Failed to refresh window position source options:', error);
    }
}

// Overwrites every character's saved position with the selected source window's current position.
export async function setAllCharacterWindowPositions() {
    const select = document.getElementById('windowPositionSourceSelect');
    const sourceName = select ? select.value : '';
    if (!sourceName) {
        showStatus(t('status.noOpenClients'), 'error');
        return;
    }

    try {
        await flushEdits();
        const pos = await rpc('setAllCharacterWindowPositions', { name: sourceName });
        (app.currentConfig.characters || []).forEach(char => {
            char.windowPosition = { x: pos.x, y: pos.y };
        });
        populateCharacters();
        showStatus(t('status.windowPositionSet'), 'success');
    } catch (error) {
        logError('Failed to set all character window positions:', error);
        showStatus(t('status.saveFailedPrefix') + error.message, 'error');
    }
}

export function confirmClearAllCharacterWindowPositions() {
    confirmRemove('clearAllWindowPositionsBtn', clearAllCharacterWindowPositions);
}

async function clearAllCharacterWindowPositions() {
    try {
        await flushEdits();
        await rpc('clearAllCharacterWindowPositions');
        (app.currentConfig.characters || []).forEach(char => {
            char.windowPosition = null;
        });
        populateCharacters();
        showStatus(t('status.windowPositionCleared'), 'success');
    } catch (error) {
        logError('Failed to clear all character window positions:', error);
        showStatus(t('status.saveFailedPrefix') + error.message, 'error');
    }
}

// Listeners are re-attached each time populateCharacters() rebuilds the list, since innerHTML replacement discards the previous elements' listeners.
function setupCharacterDragAndDrop() {
    const container = document.getElementById('charactersList');
    setupDragReorder(
        container,
        '.roster-row',
        '.character-drag-handle',
        (item) => parseInt(item.dataset.index, 10),
        reorderCharacters,
        { wholeRow: true }
    );
}

// Tracks the selected character by identity so the open detail panel follows it, rather than whatever character the raw index now happens to point at.
function reorderCharacters(fromIndex, insertBeforeIndex) {
    if (!app.currentConfig.characters) return;

    // Persist any in-progress edits in the form before the indices shift
    saveCharacters();

    const chars = app.currentConfig.characters;
    const selectedChar = chars[selectedCharacterIndex];
    moveArrayItem(chars, fromIndex, insertBeforeIndex);

    if (selectedChar) selectedCharacterIndex = chars.indexOf(selectedChar);
    populateCharacters();
}

export function updateCharacterHeaderName(index) {
    syncAccordionHeaderName(`char_${index}_name`, `char_${index}_header_name`, t('dynamic.character.defaultNamePrefix'), index);
    updateCharacterHeaderPortrait(index);
}

export function selectCharacter(index) {
    selectedCharacterIndex = index;
    selectMasterDetailRow('charactersList', index);
}

export function addCharacter() {
    if (!app.currentConfig) return;
    if (!app.currentConfig.characters) app.currentConfig.characters = [];
    saveCharacters();

    const newChar = {
        name: '',
        position: null, // Unset -> backend auto-arranges via layoutMode instead of pinning to (0,0)
        borderColors: null,
        thumbnailSize: null,
        displayName: null,
        hotkey: null
    };
    
    app.currentConfig.characters.push(newChar);
    markAsChanged();
    populateCharacters();

    const newIndex = app.currentConfig.characters.length - 1;
    selectCharacter(newIndex);

    const roster = document.querySelector('#charactersList .roster');
    if (roster) {
        setTimeout(() => {
            roster.scrollTop = roster.scrollHeight;
        }, 50);
    }
}

export async function populateCharactersFromClients() {
    const btn = document.getElementById('populateCharactersBtn');
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let names = [];
        if (typeof webui !== 'undefined') {
            names = await rpc('getOpenClients');
        }

        if (names.length === 0) {
            showStatus(t('status.noOpenClients'), 'error');
            return;
        }

        saveCharacters();
        if (!app.currentConfig.characters) app.currentConfig.characters = [];

        const existing = new Set(app.currentConfig.characters.map(c => (c.name || '').trim().toLowerCase()));
        let added = 0;
        for (const name of names) {
            if (!existing.has(name.trim().toLowerCase())) {
                app.currentConfig.characters.push({
                    name: name,
                    position: null, // Unset -> backend auto-arranges via layoutMode instead of pinning to (0,0)
                    borderColors: null,
                    thumbnailSize: null,
                    displayName: null,
                    hotkey: null
                });
                existing.add(name.trim().toLowerCase());
                added++;
            }
        }

        populateCharacters();
        if (added > 0) {
            markAsChanged();
            showStatus(t('status.addedCharactersFromClients').replace('{n}', added), 'success');
        } else {
            showStatus(t('status.allClientsInList'), 'info');
        }
    } catch (error) {
        logError('Failed to populate characters from open clients:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('common.populateFromClients'); }
    }
}

export function confirmRemoveCharacter(index) {
    confirmRemove(`char_${index}_removeBtn`, () => removeCharacter(index));
}

// If the removed item was the selected one, falls back to whichever item now sits at the removed slot (or the last one). Returns the index the caller should select.
export function reselectAfterRemoval(arr, selectedItem, removedIndex) {
    const stillPresent = selectedItem ? arr.indexOf(selectedItem) : -1;
    return stillPresent !== -1 ? stillPresent : Math.min(removedIndex, arr.length - 1);
}

export function removeCharacterByName(name) {
    if (!app.currentConfig.characters || !name.trim()) return;
    saveCharacters();
    const target = name.trim().toLowerCase();
    const index = app.currentConfig.characters.findIndex(c => (c.name || '').trim().toLowerCase() === target);
    if (index === -1) return;
    const selectedChar = app.currentConfig.characters[selectedCharacterIndex];
    app.currentConfig.characters.splice(index, 1);
    selectedCharacterIndex = reselectAfterRemoval(app.currentConfig.characters, selectedChar, index);
    populateCharacters();
}

function removeCharacter(index) {
    if (app.currentConfig.characters && app.currentConfig.characters[index]) {
        saveCharacters();
        const selectedChar = app.currentConfig.characters[selectedCharacterIndex];
        app.currentConfig.characters.splice(index, 1);
        selectedCharacterIndex = reselectAfterRemoval(app.currentConfig.characters, selectedChar, index);
        markAsChanged();
        populateCharacters();
    }
}

export function saveCharacters() {
    readFormToDoc(path => path.startsWith('characters.'));
}
