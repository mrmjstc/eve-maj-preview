// Hotkey groups and their members.
import { app } from './state.js';
import { applyDocToForm, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { reselectAfterRemoval } from './characters.js';
import { escapeHtml, logError, rpc } from './core.js';
import { renderHotkeyInputHtml, updateHotkeyConflictHighlights } from './hotkeys.js';
import { t } from './i18n.js';
import { scrollBehavior, showStatus } from './layout.js';
import { carryHotkeyGroupRenameToSpaces, refreshThumbnailSpaces } from './thumbnail_spaces.js';
import { alignDetailPanelNameLabel, moveArrayItem, selectMasterDetailRow, setupDragReorder, syncAccordionHeaderName } from './widgets.js';

// Which group's detail panel is showing in the master-detail hotkey groups view.
export let selectedHotkeyGroupIndex = 0;
// The group name as its field took focus, for carryHotkeyGroupRename.
let nameBeforeEdit = '';

export function populateHotkeyGroups() {
    const container = document.getElementById('hotkeyGroupsList');
    if (!container) return;

    const groups = app.currentConfig.hotkeyGroups || [];

    if (groups.length === 0) {
        container.innerHTML = `
            <div class="master-detail">
                <div class="roster">
                    <div class="roster-row roster-row-empty">
                        <span class="hint">${t('tab.hotkey-groups.section.groups.empty-roster')}</span>
                    </div>
                </div>
                <div class="detail-stack">
                    <p class="hint">${t('tab.hotkey-groups.section.groups.empty-detail')}</p>
                </div>
            </div>
        `;
        return;
    }

    if (selectedHotkeyGroupIndex >= groups.length) selectedHotkeyGroupIndex = groups.length - 1;
    if (selectedHotkeyGroupIndex < 0) selectedHotkeyGroupIndex = 0;

    const rosterRows = groups.map((group, index) => {
        const groupName = group.name || t('dynamic.hotkeyGroup.defaultNamePrefix') + ' ' + (index + 1);
        return `
            <div class="roster-row ${index === selectedHotkeyGroupIndex ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${index === selectedHotkeyGroupIndex}" data-index="${index}" onclick="selectHotkeyGroup(${index})">
                <span class="drag-index-chip character-drag-handle" draggable="true" title="${t('common.dragToReorder')}" onclick="event.stopPropagation()">${String(index + 1).padStart(2, '0')}</span>
                <span class="roster-name" id="hkgroup_${index}_header_name">${escapeHtml(groupName)}</span>
            </div>
        `;
    }).join('');

    const detailPanels = groups.map((group, index) => `
        <div class="detail-panel ${index === selectedHotkeyGroupIndex ? 'active' : ''}" data-index="${index}">
            <div class="detail-panel-header">
                <label class="detail-panel-name-label" for="hkgroup_${index}_name">${t('dynamic.hotkeyGroup.nameLabel')}</label>
                <input type="text" class="detail-panel-name-input" id="hkgroup_${index}_name" data-path="hotkeyGroups.${index}.name" placeholder="${t('dynamic.hotkeyGroup.defaultNamePrefix') + ' ' + (index + 1)}" oninput="updateHotkeyGroupHeaderName(${index})" onfocus="rememberHotkeyGroupName(${index})" onchange="carryHotkeyGroupRename(${index})">
                <button type="button" id="hkgroup_${index}_removeBtn" onclick="confirmRemove('hkgroup_${index}_removeBtn', () => removeHotkeyGroup(${index}))">${t('common.remove')}</button>
            </div>
            <div class="detail-form">
                <div class="detail-field binding-paired">
                    <label for="hkgroup_${index}_backward">${t('dynamic.hotkeyGroup.cycleKeysLabel')}</label>
                    <div class="binding-control">
                        <div class="field-row"><span class="binding-dir" aria-hidden="true">←</span>${renderHotkeyInputHtml(`hkgroup_${index}_backward`, t('dynamic.hotkeyGroup.backwardPlaceholder'), { path: `hotkeyGroups.${index}.backwardKey`, ariaLabel: t('dynamic.hotkeyGroup.backwardKeyLabel') })}</div>
                        <div class="field-row"><span class="binding-dir" aria-hidden="true">→</span>${renderHotkeyInputHtml(`hkgroup_${index}_forward`, t('dynamic.hotkeyGroup.forwardPlaceholder'), { path: `hotkeyGroups.${index}.forwardKey`, ariaLabel: t('dynamic.hotkeyGroup.forwardKeyLabel') })}</div>
                    </div>
                </div>
                <div class="detail-field">
                    <label for="hkgroup_${index}_assign">${t('dynamic.hotkeyGroup.assignKeyLabel')}</label>
                    <div class="field-row">${renderHotkeyInputHtml(`hkgroup_${index}_assign`, t('dynamic.hotkeyGroup.assignPlaceholder'), { path: `hotkeyGroups.${index}.assignKey` })}</div>
                    <p class="hint hint-extra">${t('dynamic.hotkeyGroup.assignKeyHint')}</p>
                </div>
                <div class="detail-field detail-field-top">
                    <label>${t('dynamic.hotkeyGroup.behaviorHeading')}</label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="hkgroup_${index}_includeNotLoggedIn" data-path="hotkeyGroups.${index}.includeNotLoggedIn">
                            <span class="label-body">${t('dynamic.hotkeyGroup.includeNotLoggedInLabel')}</span>
                        </label>
                        <label>
                            <input type="checkbox" id="hkgroup_${index}_stopAtEnds" data-path="hotkeyGroups.${index}.stopAtEnds">
                            <span class="label-body">${t('dynamic.hotkeyGroup.stopAtEndsLabel')}</span>
                        </label>
                        <label>
                            <input type="checkbox" id="hkgroup_${index}_temporaryMembership" data-path="hotkeyGroups.${index}.temporaryMembership" onchange="toggleHotkeyGroupMembershipEditor(${index})">
                            <span class="label-body">${t('dynamic.hotkeyGroup.temporaryMembershipLabel')}</span>
                        </label>
                        <label>
                            <input type="checkbox" id="hkgroup_${index}_showBadge" data-path="hotkeyGroups.${index}.showBadge">
                            <span class="label-body">${t('dynamic.hotkeyGroup.showBadgeLabel')}</span>
                        </label>
                    </div>
                </div>
            </div>
            <p class="hint" id="hkgroup_${index}_tempHint" style="${group.temporaryMembership ? '' : 'display:none'}">${t('dynamic.hotkeyGroup.temporaryMembershipHint')}</p>
            <div class="detail-members" id="hkgroup_${index}_charsField" style="${group.temporaryMembership ? 'display:none' : ''}">
                <label for="hkgroup_${index}_addChar">${t('dynamic.hotkeyGroup.charactersLabel')}</label>
                <div class="hkgroup-chars-list" id="hkgroup_${index}_charsList" data-group-index="${index}" data-path="hotkeyGroups.${index}.characters" data-format="items">${renderHotkeyGroupCharRows(index, group.characters)}</div>
                <div class="field-row" style="margin-top: 0.25rem;">
                    <input type="text" id="hkgroup_${index}_addChar" autocomplete="off" data-suggest-siblings="#hkgroup_${index}_charsList .hkgroup-char-input" onfocus="suggestOpenClients(this)" placeholder="${t('dynamic.hotkeyGroup.addCharPlaceholder')}" onkeydown="if (event.key === 'Enter') { event.preventDefault(); addHotkeyGroupCharacter(${index}); }">
                    <button type="button" onclick="addHotkeyGroupCharacter(${index})" class="btn-nowrap">${t('dynamic.hotkeyGroup.addBtnLabel')}</button>
                    <button type="button" id="hkgroup_${index}_fillBtn" onclick="fillHotkeyGroupFromClients(${index})" class="btn-nowrap">${t('status.fillFromClientsLabel')}</button>
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

    applyDocToForm(path => path.startsWith('hotkeyGroups.'), container);
    setupHotkeyGroupDragAndDrop();
    setupHotkeyGroupCharDragAndDrop();
    updateHotkeyConflictHighlights();
    // innerHTML above replaced the elements the last measuring pass sized.
    alignDetailPanelNameLabel('hotkeyGroupsList');
    fitHotkeyGroupCharsList(selectedHotkeyGroupIndex);
}

// Every group's fields stay mounted (just hidden) so hotkey-conflict detection, which scans all input.hotkey-input elements at once, keeps seeing every group.
export function selectHotkeyGroup(index) {
    selectedHotkeyGroupIndex = index;
    selectMasterDetailRow('hotkeyGroupsList', index);
    // This group's list could only be measured once its panel became the visible one.
    fitHotkeyGroupCharsList(index);
}

// A list that runs a row or two past the fold packs its cards tighter instead of scrolling; past what that buys, the scrollbar comes back.
export function fitHotkeyGroupCharsList(groupIndex) {
    const list = document.getElementById(`hkgroup_${groupIndex}_charsList`);
    if (!list) return;

    list.classList.remove('chars-compact');
    // Zero while the panel or tab is hidden, when nothing can be measured; the next populate or tab switch re-runs this.
    if (!list.clientHeight) return;

    if (list.scrollHeight > list.clientHeight) list.classList.add('chars-compact');
}

// Temporary membership is hover-assigned at runtime, so its character list isn't editable here.
export function toggleHotkeyGroupMembershipEditor(index) {
    const isTemporary = document.getElementById(`hkgroup_${index}_temporaryMembership`)?.checked;
    const charsField = document.getElementById(`hkgroup_${index}_charsField`);
    const hint = document.getElementById(`hkgroup_${index}_tempHint`);
    if (charsField) charsField.style.display = isTemporary ? 'none' : 'flex';
    if (hint) hint.style.display = isTemporary ? '' : 'none';
    markAsChanged();
}

function setupHotkeyGroupDragAndDrop() {
    setupDragReorder(
        document.querySelector('#hotkeyGroupsList .roster'),
        '.roster-row',
        '.character-drag-handle',
        (item) => parseInt(item.dataset.index, 10),
        reorderHotkeyGroups,
        { wholeRow: true }
    );
}

// Tracks the selected group by identity so the open detail panel follows it, rather than whatever group the raw index now happens to point at.
function reorderHotkeyGroups(fromIndex, insertBeforeIndex) {
    if (!app.currentConfig.hotkeyGroups) return;

    saveHotkeyGroups();

    const groups = app.currentConfig.hotkeyGroups;
    const selectedGroup = groups[selectedHotkeyGroupIndex];
    moveArrayItem(groups, fromIndex, insertBeforeIndex);

    if (selectedGroup) selectedHotkeyGroupIndex = groups.indexOf(selectedGroup);
    markAsChanged();
    populateHotkeyGroups();
}

function renderHotkeyGroupCharRows(groupIndex, characters) {
    if (!characters || characters.length === 0) {
        return `<p class="hint hkgroup-chars-empty">${t('tab.hotkey-groups.section.groups.empty-members')}</p>`;
    }

    return characters.map((name, charIndex) => `
        <div class="hkgroup-char-row" data-char-index="${charIndex}">
            <span class="drag-index-chip character-drag-handle" draggable="true" title="${t('common.dragToReorder')}" onclick="event.stopPropagation()">${String(charIndex + 1).padStart(2, '0')}</span>
            <input type="text" class="hkgroup-char-input" data-item value="${escapeHtml(name)}" placeholder="${t('common.characterName')}" autocomplete="off" data-suggest-siblings="#hkgroup_${groupIndex}_charsList .hkgroup-char-input" onfocus="suggestOpenClients(this)">
            <button type="button" class="button-icon button-icon-danger" onclick="removeHotkeyGroupCharacter(${groupIndex}, ${charIndex})" title="${t('common.remove')}">×</button>
        </div>
    `).join('');
}

// Re-renders only the character rows for one group, so adding/removing/reordering doesn't collapse the accordion or disturb other groups' in-progress edits.
export function refreshHotkeyGroupCharsList(groupIndex) {
    const group = app.currentConfig.hotkeyGroups && app.currentConfig.hotkeyGroups[groupIndex];
    const list = document.getElementById(`hkgroup_${groupIndex}_charsList`);
    if (!group || !list) return;

    list.innerHTML = renderHotkeyGroupCharRows(groupIndex, group.characters);
    setupHotkeyGroupCharDragAndDrop(list, groupIndex);
    fitHotkeyGroupCharsList(groupIndex);
}

// Called with no arguments to wire up every group's list, or with a specific list/groupIndex to wire up just that one. Each list gets its own independent setupDragReorder closure, so there's no cross-group drag state to guard against.
function setupHotkeyGroupCharDragAndDrop(onlyList, onlyGroupIndex) {
    const lists = onlyList ? [onlyList] : Array.from(document.querySelectorAll('.hkgroup-chars-list'));

    lists.forEach(list => {
        const groupIndex = onlyList ? onlyGroupIndex : parseInt(list.dataset.groupIndex, 10);
        setupDragReorder(
            list,
            '.hkgroup-char-row',
            '.character-drag-handle',
            (item) => parseInt(item.dataset.charIndex, 10),
            (fromIndex, insertBeforeIndex) => reorderHotkeyGroupChars(groupIndex, fromIndex, insertBeforeIndex),
            { grid: true }
        );
    });
}

function reorderHotkeyGroupChars(groupIndex, fromIndex, insertBeforeIndex) {
    saveHotkeyGroups();

    const group = app.currentConfig.hotkeyGroups && app.currentConfig.hotkeyGroups[groupIndex];
    if (!group) return;

    moveArrayItem(group.characters, fromIndex, insertBeforeIndex);

    refreshHotkeyGroupCharsList(groupIndex);
}

export function removeHotkeyGroupCharacter(groupIndex, charIndex) {
    saveHotkeyGroups();

    const group = app.currentConfig.hotkeyGroups && app.currentConfig.hotkeyGroups[groupIndex];
    if (!group || !group.characters) return;

    group.characters.splice(charIndex, 1);
    markAsChanged();
    refreshHotkeyGroupCharsList(groupIndex);
}

export function addHotkeyGroupCharacter(groupIndex) {
    const input = document.getElementById(`hkgroup_${groupIndex}_addChar`);
    if (!input) return;

    const name = input.value.trim();
    if (!name) return;

    saveHotkeyGroups();

    const group = app.currentConfig.hotkeyGroups && app.currentConfig.hotkeyGroups[groupIndex];
    if (!group) return;

    if (!group.characters) group.characters = [];
    group.characters.push(name);
    markAsChanged();
    refreshHotkeyGroupCharsList(groupIndex);
    scrollHotkeyGroupCharsToEnd(groupIndex);

    input.value = '';
    input.focus();
    suggestOpenClients(input);
}

// Themed stand-in for <datalist>, whose native popup can't be styled. Names already used by the input's data-suggest-siblings are hidden.
export const suggestOpenClients = (() => {
    let panel = null;
    let activeInput = null;
    let names = [];
    let matches = [];
    let highlighted = -1;

    function ensurePanel() {
        if (panel) return;
        panel = document.createElement('div');
        panel.id = 'client-suggest';
        panel.setAttribute('role', 'listbox');
        // Keeps focus in the input, so its blur doesn't close the panel before the click lands.
        panel.addEventListener('mousedown', e => e.preventDefault());
        panel.addEventListener('click', e => {
            const row = e.target.closest('.client-suggest-row');
            if (row) pick(parseInt(row.dataset.index, 10));
        });
        document.body.appendChild(panel);
    }

    function renderRow(name, i, query) {
        const at = name.toLowerCase().indexOf(query);
        const label = query
            ? escapeHtml(name.slice(0, at)) + `<span class="client-suggest-match">${escapeHtml(name.slice(at, at + query.length))}</span>` + escapeHtml(name.slice(at + query.length))
            : escapeHtml(name);
        return `<div class="client-suggest-row${i === highlighted ? ' active' : ''}" role="option" data-index="${i}">${label}</div>`;
    }

    function render() {
        const query = activeInput.value.trim().toLowerCase();
        matches = names.filter(name => name.toLowerCase().includes(query) && name.toLowerCase() !== query);
        highlighted = Math.min(highlighted, matches.length - 1);

        if (matches.length === 0) {
            panel.classList.remove('open');
            return;
        }
        panel.innerHTML = matches.map((name, i) => renderRow(name, i, query)).join('');
        panel.classList.add('open');
        position();
    }

    function position() {
        const rect = activeInput.getBoundingClientRect();
        panel.style.left = rect.left + 'px';
        panel.style.width = rect.width + 'px';
        const below = rect.bottom + 2;
        const fitsBelow = below + panel.offsetHeight <= window.innerHeight;
        panel.style.top = (fitsBelow || rect.top < panel.offsetHeight ? below : rect.top - panel.offsetHeight - 2) + 'px';
    }

    function pick(i) {
        const input = activeInput;
        input.value = matches[i];
        close();
        input.dispatchEvent(new Event('input', { bubbles: true }));
    }

    // Capture phase, so Enter fills the input before inline handlers (e.g. the group Add box) read its value.
    function onKeyDown(e) {
        if (e.target !== activeInput) return;
        const shown = panel.classList.contains('open');

        if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && shown) {
            e.preventDefault();
            const step = e.key === 'ArrowDown' ? 1 : -1;
            highlighted = (highlighted + step + matches.length) % matches.length;
            render();
            panel.children[highlighted]?.scrollIntoView({ block: 'nearest' });
        } else if (e.key === 'Enter' && shown && highlighted >= 0) {
            pick(highlighted);
        } else if (e.key === 'Escape' && shown) {
            e.stopPropagation();
            panel.classList.remove('open');
        } else if (e.key === 'Tab') {
            close();
        }
    }

    function onInput() {
        highlighted = -1;
        render();
    }

    function onScroll(e) {
        if (!panel.contains(e.target)) close();
    }

    function close() {
        if (!activeInput) return;
        activeInput.removeEventListener('input', onInput);
        activeInput.removeEventListener('blur', close);
        document.removeEventListener('keydown', onKeyDown, true);
        document.removeEventListener('scroll', onScroll, true);
        window.removeEventListener('resize', close);
        panel.classList.remove('open');
        activeInput = null;
    }

    return async function open(input) {
        if (typeof eveRpc === 'undefined') return;

        try {
            const clientNames = await rpc('getOpenClients');
            if (document.activeElement !== input) return;

            const siblings = input.dataset.suggestSiblings ? document.querySelectorAll(input.dataset.suggestSiblings) : [];
            const taken = new Set(Array.from(siblings)
                .filter(el => el !== input)
                .map(el => el.value.trim().toLowerCase()));

            ensurePanel();
            close();
            names = clientNames.filter(name => !taken.has(name.trim().toLowerCase()));
            highlighted = -1;
            activeInput = input;
            input.addEventListener('input', onInput);
            input.addEventListener('blur', close);
            document.addEventListener('keydown', onKeyDown, true);
            document.addEventListener('scroll', onScroll, true);
            window.addEventListener('resize', close);
            render();
        } catch (error) {
            logError('Failed to load open client suggestions:', error);
        }
    };
})();

// New members are appended, which since the list scrolls on its own can be below the fold.
function scrollHotkeyGroupCharsToEnd(groupIndex) {
    const list = document.getElementById(`hkgroup_${groupIndex}_charsList`);
    if (!list) return;
    list.scrollTo({ top: list.scrollHeight, behavior: scrollBehavior() });
}

function scrollHotkeyGroupRosterToEnd() {
    const rows = document.querySelectorAll('#hotkeyGroupsList .roster-row');
    const last = rows[rows.length - 1];
    if (last) last.scrollIntoView({ behavior: scrollBehavior(), block: 'nearest' });
}

export function addHotkeyGroup() {
    if (!app.currentConfig) return;
    if (!app.currentConfig.hotkeyGroups) app.currentConfig.hotkeyGroups = [];
    saveHotkeyGroups();
    app.currentConfig.hotkeyGroups.push({
        name: '',
        forwardKey: '',
        backwardKey: null,
        assignKey: null,
        temporaryMembership: false,
        showBadge: false,
        includeNotLoggedIn: false,
        stopAtEnds: false,
        characters: []
    });
    markAsChanged();
    populateHotkeyGroups();
    selectHotkeyGroup(app.currentConfig.hotkeyGroups.length - 1);
    scrollHotkeyGroupRosterToEnd();
    refreshThumbnailSpaces();
}

export async function fillHotkeyGroupFromClients(index) {
    const btn = document.getElementById(`hkgroup_${index}_fillBtn`);
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let names = [];
        if (typeof eveRpc !== 'undefined') {
            names = await rpc('getOpenClients');
        }

        if (names.length === 0) {
            showStatus(t('status.noOpenClients'), 'error');
            return;
        }

        saveHotkeyGroups();
        const group = app.currentConfig.hotkeyGroups && app.currentConfig.hotkeyGroups[index];
        if (!group) return;

        const existingSet = new Set((group.characters || []).map(s => s.toLowerCase()));
        const toAdd = names.filter(n => !existingSet.has(n.toLowerCase()));

        if (toAdd.length === 0) {
            showStatus(t('status.allClientsInGroup'), 'info');
        } else {
            if (!group.characters) group.characters = [];
            group.characters.push(...toAdd);
            refreshHotkeyGroupCharsList(index);
            scrollHotkeyGroupCharsToEnd(index);
            showStatus(t('status.addedCharactersToGroup').replace('{n}', toAdd.length), 'success');
        }
    } catch (error) {
        logError('Failed to fill hotkey group from open clients:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('status.fillFromClientsLabel'); }
    }
}

export function removeHotkeyGroup(index) {
    const groups = app.currentConfig.hotkeyGroups;
    if (!groups || !groups[index]) return;

    saveHotkeyGroups();
    const selectedGroup = groups[selectedHotkeyGroupIndex];
    const [removed] = groups.splice(index, 1);
    selectedHotkeyGroupIndex = reselectAfterRemoval(groups, selectedGroup, index);

    markAsChanged();
    populateHotkeyGroups();
    carryHotkeyGroupRenameToSpaces(removed.name, null);
    refreshThumbnailSpaces();
}

export function rememberHotkeyGroupName(index) {
    nameBeforeEdit = document.getElementById(`hkgroup_${index}_name`)?.value.trim() || '';
}

// Thumbnail spaces hold groups by name, so they follow a rename.
export function carryHotkeyGroupRename(index) {
    const oldName = nameBeforeEdit;
    nameBeforeEdit = document.getElementById(`hkgroup_${index}_name`)?.value.trim() || '';
    saveHotkeyGroups();
    if (oldName && nameBeforeEdit && oldName !== nameBeforeEdit) carryHotkeyGroupRenameToSpaces(oldName, nameBeforeEdit);
    // A group named for the first time becomes a chip a space can hold.
    refreshThumbnailSpaces();
}

export function updateHotkeyGroupHeaderName(index) {
    syncAccordionHeaderName(`hkgroup_${index}_name`, `hkgroup_${index}_header_name`, t('dynamic.hotkeyGroup.defaultNamePrefix'), index);
}

export function saveHotkeyGroups() {
    readFormToDoc(path => path.startsWith('hotkeyGroups.'));
}
