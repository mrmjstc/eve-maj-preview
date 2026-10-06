// Thumbnail spaces: the list beside the selected space's details, its hotkey group chips and a map of every space's region.
import { app } from './state.js';
import { applyDocToForm, applySchemaToInputs, defaultFor, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { escapeHtml } from './core.js';
import { t } from './i18n.js';
import { scrollBehavior } from './layout.js';
import { alignDetailPanelNameLabel, moveArrayItem, selectMasterDetailRow, setupDragReorder } from './widgets.js';

const LIST_ID = 'thumbnailSpacesList';
// Cycled by position, so neighbouring spaces stay told apart.
const DOT_COLORS = ['var(--color-accent)', '#7fb3d9', '#a988d1', '#5ec98f'];

// The selected space, by object while this document holds it and by id once a reload replaces the objects.
let selectedSpace = null;
let selectedSpaceId = null;

function spaces() {
    return app.currentConfig?.thumbnailSpaces || [];
}

// [x, y, width, height], or null until a region is drawn.
export function spaceRect(space) {
    const values = [space.x, space.y, space.width, space.height];
    return values.every(Number.isInteger) && space.width > 0 && space.height > 0 ? values : null;
}

// The space the app sends these characters to (see app.spacePlacement), when it isn't `space` itself.
function otherWinner(list, space, winnerId) {
    if (winnerId == null || winnerId === space.id) return null;
    return list.find(other => other.id === winnerId) || null;
}

function isSpecial(space) {
    return space.holdsLoginScreen || space.holdsUnassigned;
}

export function spaceName(space) {
    if (space.holdsLoginScreen) return t('dynamic.space.loginScreenName');
    if (space.holdsUnassigned) return t('dynamic.space.unassignedName');
    return space.name || t('dynamic.space.unnamed');
}

function dotColor(index) {
    return DOT_COLORS[index % DOT_COLORS.length];
}

function selectedIndex(list) {
    let index = list.indexOf(selectedSpace);
    if (index === -1 && selectedSpaceId != null) index = list.findIndex(space => space.id === selectedSpaceId);
    if (index === -1) index = 0;
    rememberSelection(list[index]);
    return list.length === 0 ? -1 : index;
}

function rememberSelection(space) {
    selectedSpace = space || null;
    selectedSpaceId = space?.id ?? null;
}

export function populateThumbnailSpaces() {
    const container = document.getElementById(LIST_ID);
    if (!container || !app.currentConfig) return;

    const list = spaces();
    const selected = selectedIndex(list);
    const rosterRows = list.map((space, index) => rosterRowHtml(space, index, index === selected)).join('');
    const panels = list.map((space, index) => detailPanelHtml(list, space, index, index === selected)).join('');
    container.innerHTML = `
        <div class="master-detail">
            <div class="roster" role="tablist">${rosterRows}<button type="button" class="space-add" onclick="addThumbnailSpace()">${t('dynamic.space.addButton')}</button></div>
            <div class="detail-stack">${panels}</div>
        </div>
    `;

    applySchemaToInputs(container);
    applyDocToForm(path => path.startsWith('thumbnailSpaces.'), container);
    setupDragReorder(
        container.querySelector('.roster'),
        '.roster-row',
        null,
        (item) => parseInt(item.dataset.index, 10),
        reorderThumbnailSpaces,
        { wholeRow: true }
    );
    alignDetailPanelNameLabel(LIST_ID);
}

function rosterRowHtml(space, index, isSelected) {
    const rect = spaceRect(space);
    const state = !space.enabled ? t('dynamic.space.stateOff') : rect ? `${rect[2]}×${rect[3]}` : t('dynamic.space.stateNoRegion');
    const isWarning = space.enabled && !rect;
    return `
        <div class="roster-row ${isSelected ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${isSelected}" data-index="${index}" onclick="selectThumbnailSpace(${index})" title="${t('common.dragToReorder')}">
            <span class="space-dot${space.enabled ? '' : ' off'}" style="--dot: ${dotColor(index)}"></span>
            <span class="roster-name" id="space_${index}_header_name">${escapeHtml(spaceName(space))}</span>
            <span class="space-state${isWarning ? ' warn' : ''}">${escapeHtml(state)}</span>
        </div>
    `;
}

function detailPanelHtml(list, space, index, isSelected) {
    const path = `thumbnailSpaces.${index}`;
    const special = isSpecial(space);
    const name = special
        ? `<span class="detail-panel-name-label">${t('dynamic.space.nameLabel')}</span><span class="space-fixed-name">${escapeHtml(spaceName(space))}</span>`
        : `<label class="detail-panel-name-label" for="space_${index}_name">${t('dynamic.space.nameLabel')}</label>
           <input type="text" class="detail-panel-name-input" id="space_${index}_name" data-path="${path}.name" placeholder="${t('dynamic.space.namePlaceholder')}" oninput="updateThumbnailSpaceHeaderName(${index})">`;
    const remove = special ? '' : `<button type="button" id="space_${index}_removeBtn" onclick="confirmRemove('space_${index}_removeBtn', () => removeThumbnailSpace(${index}))">${t('common.remove')}</button>`;

    return `
        <div class="detail-panel ${isSelected ? 'active' : ''}" data-index="${index}">
            <div class="detail-panel-header">
                ${name}
                <label class="space-enabled">
                    <input type="checkbox" id="space_${index}_enabled" data-path="${path}.enabled" onchange="onThumbnailSpaceChanged()">
                    <span class="label-body">${t('common.enabledLabel')}</span>
                </label>
                ${remove}
            </div>
            <div class="detail-form${space.enabled ? '' : ' is-disabled'}">
                ${holdsFieldHtml(list, space, index)}
                ${takesFieldHtml(list, space, index)}
                ${regionFieldHtml(list, space, index)}
                <div class="detail-field">
                    <label for="space_${index}_direction">${t('field.regionFitDirection.label')}</label>
                    <select id="space_${index}_direction" data-path="${path}.direction"></select>
                    <p class="hint hint-extra">${t('field.regionFitDirection.hint')}</p>
                </div>
                ${space.holdsLoginScreen ? '' : `
                <div class="detail-field">
                    <label for="space_${index}_order">${t('field.regionFitOrder.label')}</label>
                    <select id="space_${index}_order" data-path="${path}.order"></select>
                    <p class="hint hint-extra">${t('field.regionFitOrder.hint')}</p>
                </div>`}
                <div class="detail-field">
                    <label for="space_${index}_spacing">${t('dynamic.space.spacingLabel')}</label>
                    <input type="number" id="space_${index}_spacing" data-path="${path}.spacing">
                </div>
                <div class="detail-field detail-field-top">
                    <label>${t('dynamic.space.sizeLabel')}</label>
                    <div class="detail-checks">
                        <label>
                            <input type="checkbox" id="space_${index}_cap" data-path="${path}.limitToThumbnailSize">
                            <span class="label-body">${t('field.regionFitLimitToThumbnailSize.label')}</span>
                        </label>
                        <p class="hint hint-extra">${t('field.regionFitLimitToThumbnailSize.hint')}</p>
                    </div>
                </div>
            </div>
        </div>
    `;
}

function holdsFieldHtml(list, space, index) {
    let body;
    if (space.holdsLoginScreen) {
        body = `<p class="hint">${t('dynamic.space.loginScreenHolds')}</p>`;
    } else if (space.holdsUnassigned) {
        body = `<p class="hint">${t('dynamic.space.unassignedHolds')}</p>`;
    } else {
        body = `<div class="space-chips" role="group">${chipsHtml(space, index)}</div>
                <p class="hint hint-extra">${t('dynamic.space.groupsHint')}</p>
                ${overlapsHtml(list, index)}`;
    }
    return `
        <div class="detail-field detail-field-top">
            <label>${t('dynamic.space.holdsLabel')}</label>
            <div class="space-holds">${body}</div>
        </div>
    `;
}

function chipsHtml(space, index) {
    const groups = app.currentConfig.hotkeyGroups || [];
    const held = space.groups || [];
    const chips = groups.map((group, groupIndex) => {
        if (!group.name) {
            return `<button type="button" class="space-chip" disabled title="${t('dynamic.space.unnamedGroupTitle')}">${escapeHtml(t('dynamic.hotkeyGroup.defaultNamePrefix') + ' ' + (groupIndex + 1))}</button>`;
        }
        return chipHtml(index, group.name, held.includes(group.name), group.name);
    });
    for (const name of held) {
        if (!groups.some(group => group.name === name)) chips.push(chipHtml(index, name, true, t('dynamic.space.missingGroup').replace('{name}', name)));
    }
    if (chips.length === 0) return `<p class="hint">${t('dynamic.space.noGroups')}</p>`;
    return chips.join('');
}

function chipHtml(index, name, isHeld, label) {
    return `<button type="button" class="space-chip${isHeld ? ' held' : ''}" aria-pressed="${isHeld}" data-group="${escapeHtml(name)}" onclick="toggleThumbnailSpaceGroup(${index}, this.dataset.group)">${escapeHtml(label)}</button>`;
}

// A group another space comes first for goes there, not here.
function overlapsHtml(list, index) {
    const space = list[index];
    return (space.groups || []).map(name => {
        const winner = otherWinner(list, space, app.spacePlacement.groupSpaceIds[name]);
        if (!winner) return '';
        const text = t('dynamic.space.overlap').replace('{group}', name).replace('{space}', spaceName(winner));
        return `<p class="hint hint-warning">${escapeHtml(text)}</p>`;
    }).join('');
}

function takesFieldHtml(list, space, index) {
    const path = `thumbnailSpaces.${index}`;
    const checks = [];
    if (!space.holdsUnassigned) {
        checks.push(takeCheckHtml(index, `${path}.takesUnassigned`, 'takesUnassigned', space.takesUnassigned, otherWinner(list, space, app.spacePlacement.unassignedSpaceId), 'dynamic.space.takenUnassigned'));
    }
    if (!space.holdsLoginScreen) {
        checks.push(takeCheckHtml(index, `${path}.takesLoginScreen`, 'takesLoginScreen', space.takesLoginScreen, otherWinner(list, space, app.spacePlacement.loginScreenSpaceId), 'dynamic.space.takenLoginScreen'));
    }
    return `
        <div class="detail-field detail-field-top">
            <label>${t('dynamic.space.alsoTakesLabel')}</label>
            <div class="detail-checks">${checks.join('')}</div>
        </div>
    `;
}

function takeCheckHtml(index, path, field, isOn, winner, takenKey) {
    const takenElsewhere = isOn && winner
        ? `<p class="hint hint-warning">${escapeHtml(t(takenKey).replace('{space}', spaceName(winner)))}</p>`
        : '';
    return `
        <label>
            <input type="checkbox" id="space_${index}_${field}" data-path="${path}" onchange="onThumbnailSpaceChanged()">
            <span class="label-body">${t(`dynamic.space.${field}.label`)}</span>
        </label>
        <p class="hint hint-extra">${t(`dynamic.space.${field}.hint`)}</p>
        ${takenElsewhere}
    `;
}

function regionFieldHtml(list, space, index) {
    const rect = spaceRect(space);
    const text = rect
        ? t('dynamic.space.regionText').replace('{w}', rect[2]).replace('{h}', rect[3]).replace('{x}', rect[0]).replace('{y}', rect[1])
        : t('dynamic.space.regionNone');
    const disabled = rect ? '' : 'disabled';
    return `
        <div class="detail-field detail-field-top">
            <label>${t('dynamic.space.regionLabel')}</label>
            <div class="space-region">
                ${mapHtml(list, index)}
                <div class="space-region-side">
                    <span class="space-region-text${rect ? '' : ' warn'}">${escapeHtml(text)}</span>
                    <div class="button-row-flex">
                        <button type="button" onclick="startSpaceRegionSelect(${index})">${t('field.newRegion.button')}</button>
                        <button type="button" onclick="startSpaceRegionSelect(${index}, true)" ${disabled}>${t('field.editRegion.button')}</button>
                        <button type="button" id="space_${index}_clearRegion" class="button-icon button-icon-danger" onclick="confirmRemove('space_${index}_clearRegion', () => clearSpaceRegion(${index}), '✓')" title="${t('field.clearRegion.title')}" ${disabled}>&times;</button>
                    </div>
                </div>
            </div>
        </div>
    `;
}

// The whole desktop as the app reported it, grown to fit any region drawn off it.
function mapBounds(list) {
    const desktop = app.desktop || { x: 0, y: 0, width: 1, height: 1 };
    let [left, top, right, bottom] = [desktop.x, desktop.y, desktop.x + desktop.width, desktop.y + desktop.height];
    for (const space of list) {
        const rect = spaceRect(space);
        if (!rect) continue;
        left = Math.min(left, rect[0]);
        top = Math.min(top, rect[1]);
        right = Math.max(right, rect[0] + rect[2]);
        bottom = Math.max(bottom, rect[1] + rect[3]);
    }
    return { left, top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
}

function mapHtml(list, selected) {
    const bounds = mapBounds(list);
    const boxes = list.map((space, index) => {
        const rect = spaceRect(space);
        if (!rect) return '';
        const style = [
            `left: ${(rect[0] - bounds.left) / bounds.width * 100}%`,
            `top: ${(rect[1] - bounds.top) / bounds.height * 100}%`,
            `width: ${rect[2] / bounds.width * 100}%`,
            `height: ${rect[3] / bounds.height * 100}%`,
            `--dot: ${dotColor(index)}`,
        ].join('; ');
        const classes = ['space-map-box', index === selected ? 'selected' : '', space.enabled ? '' : 'off'].filter(Boolean).join(' ');
        return `<span class="${classes}" style="${style}" title="${escapeHtml(spaceName(space))}"></span>`;
    });
    // The selected space is drawn last, over the others.
    const ordered = boxes.filter((_, index) => index !== selected).concat(boxes[selected] || '');
    return `<div class="space-map" style="aspect-ratio: ${bounds.width} / ${bounds.height}" aria-hidden="true">${ordered.join('')}</div>`;
}

export function selectThumbnailSpace(index) {
    rememberSelection(spaces()[index]);
    selectMasterDetailRow(LIST_ID, index);
    alignDetailPanelNameLabel(LIST_ID);
}

export function updateThumbnailSpaceHeaderName(index) {
    const input = document.getElementById(`space_${index}_name`);
    const header = document.getElementById(`space_${index}_header_name`);
    if (input && header) header.textContent = input.value.trim() || t('dynamic.space.unnamed');
}

// Enabling a space or a take setting changes which space wins, so the badges and warnings are redrawn.
export function onThumbnailSpaceChanged() {
    saveThumbnailSpaces();
    markAsChanged();
    populateThumbnailSpaces();
}

export function toggleThumbnailSpaceGroup(index, name) {
    saveThumbnailSpaces();
    const space = spaces()[index];
    if (!space || !name) return;
    const groups = space.groups || [];
    space.groups = groups.includes(name) ? groups.filter(held => held !== name) : [...groups, name];
    markAsChanged();
    populateThumbnailSpaces();
}

function reorderThumbnailSpaces(fromIndex, insertBeforeIndex) {
    saveThumbnailSpaces();
    moveArrayItem(spaces(), fromIndex, insertBeforeIndex);
    markAsChanged();
    populateThumbnailSpaces();
}

export function addThumbnailSpace() {
    if (!app.currentConfig) return;
    saveThumbnailSpaces();
    if (!app.currentConfig.thumbnailSpaces) app.currentConfig.thumbnailSpaces = [];
    const space = newSpace();
    app.currentConfig.thumbnailSpaces.push(space);
    rememberSelection(space);
    markAsChanged();
    populateThumbnailSpaces();
    document.querySelector(`#${LIST_ID} .roster-row.selected`)?.scrollIntoView({ behavior: scrollBehavior(), block: 'nearest' });
}

// Every field starts at the app's default (see config/schema.zig); any it doesn't list the app fills in on insert.
function newSpace() {
    const prefix = 'thumbnailSpaces.*.';
    const space = {};
    for (const key of Object.keys(app.schema?.fields || {})) {
        const field = key.slice(prefix.length);
        if (!key.startsWith(prefix) || field.includes('.')) continue;
        space[field] = JSON.parse(JSON.stringify(defaultFor(key) ?? null));
    }
    space.name = t('dynamic.space.newName');
    return space;
}

// The Login Screen and Unassigned Characters spaces are always in the list.
export function removeThumbnailSpace(index) {
    const list = spaces();
    const space = list[index];
    if (!space || isSpecial(space)) return;
    saveThumbnailSpaces();
    list.splice(index, 1);
    rememberSelection(list[Math.min(index, list.length - 1)]);
    markAsChanged();
    populateThumbnailSpaces();
}

// Spaces hold hotkey groups by name, so they follow a group's rename, or drop it once it's removed (`newName` null); a name another group still has stays.
export function carryHotkeyGroupRenameToSpaces(oldName, newName) {
    if (!oldName || (app.currentConfig.hotkeyGroups || []).some(group => group.name === oldName)) return;
    saveThumbnailSpaces();
    for (const space of spaces()) {
        const groups = space.groups || [];
        if (!groups.includes(oldName)) continue;
        space.groups = newName && !groups.includes(newName)
            ? groups.map(name => (name === oldName ? newName : name))
            : groups.filter(name => name !== oldName);
    }
    populateThumbnailSpaces();
}

// Redraws the list after a hotkey group change, keeping what the spaces' fields hold.
export function refreshThumbnailSpaces() {
    saveThumbnailSpaces();
    populateThumbnailSpaces();
}

export function saveThumbnailSpaces() {
    readFormToDoc(path => path.startsWith('thumbnailSpaces.'));
}
