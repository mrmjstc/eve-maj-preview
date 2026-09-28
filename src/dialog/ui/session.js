// The profile and global settings the window edits are held by the app (see dialog/session.zig); this keeps the form in step with them.
// Edits are read back from the form, diffed against what the app last confirmed, and sent as edit ops (see config/patch.zig).
import { app } from './state.js';
import { setDirty } from './changes.js';
import { addCharacterIfMissing, populateCharacters, refreshCharacterWindowPosition } from './characters.js';
import { listenForAppEvent, logError, logWarn, rpc } from './core.js';
import { applyPathsToForm, populateFormFields, readFormIntoConfig } from './form.js';
import { saveProfileSwitchHotkeys } from './global_hotkeys.js';
import { applyGlobalSettingsToForm } from './global_settings.js';
import { populateHotkeyGroups, refreshHotkeyGroupCharsList } from './hotkey_groups.js';
import { describeHotkeyConflicts, showHotkeyConflictModal, updateHotkeyConflictHighlights } from './hotkeys.js';
import { t } from './i18n.js';
import { showStatus, switchTab } from './layout.js';
import { populateNotificationTypes } from './notifications.js';
import { saveOreTable } from './ore_table.js';
import { populateSystemColors } from './system_colors.js';
import { populateWindowFilters } from './window_filters.js';

const FLUSH_DELAY_MS = 120;
// Lists whose items carry an `id`, so they're edited item by item rather than replaced whole.
const KEYED_LISTS = new Set(['characters', 'hotkeyGroups']);
const LIST_VIEWS = {
    characters: populateCharacters,
    hotkeyGroups: populateHotkeyGroups,
    windowFilters: populateWindowFilters,
    systemColors: populateSystemColors,
};

// What the app holds for each document, as of its last reply.
const confirmed = { profile: null, global: null };
let flushTimer = null;
// Flushes, app changes and reloads run one at a time, so each diff starts from what the previous step confirmed.
let queue = Promise.resolve();

function enqueue(step) {
    queue = queue.then(step).catch((error) => logError('Configuration session step failed:', error));
    return queue;
}

function docOf(name) {
    return name === 'profile' ? app.currentConfig : app.currentGlobalSettings;
}

function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function isObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// Compares only the keys `ours` (the app's shape) has; the app drops any others the form adds.
function sameValue(ours, theirs) {
    if (Array.isArray(ours) || Array.isArray(theirs)) {
        return Array.isArray(ours) && Array.isArray(theirs) && ours.length === theirs.length && ours.every((item, i) => sameValue(item, theirs[i]));
    }
    if (isObject(ours) || isObject(theirs)) {
        return isObject(ours) && isObject(theirs) && Object.keys(ours).every(key => key === 'id' || sameValue(ours[key], theirs[key]));
    }
    return ours === theirs;
}

function diffObject(before, after, path, ops) {
    for (const key of Object.keys(before)) {
        if (key === 'id' || !(key in after)) continue;
        const was = before[key];
        const now = after[key];
        const at = [...path, key];
        if (path.length === 0 && KEYED_LISTS.has(key) && Array.isArray(was) && Array.isArray(now)) diffKeyedList(was, now, at, ops);
        else if (isObject(was) && isObject(now)) diffObject(was, now, at, ops);
        else if (!sameValue(was, now)) ops.push({ op: 'set', path: at, value: now });
    }
}

// Removes, then inserts and moves in order, so the app's list ends up in the form's order; `item` stays local to learn its new id.
function diffKeyedList(before, after, path, ops) {
    const kept = new Set(after.map(item => item.id).filter(Boolean));
    const order = [];
    for (const item of before) {
        if (kept.has(item.id)) order.push(item.id);
        else ops.push({ op: 'remove', path: [...path, item.id] });
    }
    const byId = new Map(before.map(item => [item.id, item]));
    after.forEach((item, index) => {
        if (!byId.has(item.id)) {
            ops.push({ op: 'insert', path, index, value: item, item });
            order.splice(index, 0, null);
            return;
        }
        const at = order.indexOf(item.id);
        if (at !== index) {
            ops.push({ op: 'move', path: [...path, item.id], index });
            order.splice(at, 1);
            order.splice(index, 0, item.id);
        }
        diffObject(byId.get(item.id), item, [...path, item.id], ops);
    });
}

function childOf(node, key) {
    if (Array.isArray(node)) return node.find(item => item.id === key);
    return node == null ? undefined : node[key];
}

function nodeAt(root, path) {
    return path.reduce(childOf, root);
}

function setAt(root, path, value) {
    const parent = nodeAt(root, path.slice(0, -1));
    const key = path[path.length - 1];
    if (Array.isArray(parent)) {
        const index = parent.findIndex(item => item.id === key);
        if (index !== -1) parent[index] = value;
    } else if (parent != null) {
        parent[key] = value;
    }
}

function applyOp(root, op) {
    if (op.op === 'set') {
        setAt(root, op.path, clone(op.value));
        return;
    }
    if (op.op === 'insert') {
        const list = nodeAt(root, op.path);
        if (Array.isArray(list)) list.splice(Math.min(op.index ?? list.length, list.length), 0, clone(op.value));
        return;
    }
    const list = nodeAt(root, op.path.slice(0, -1));
    const index = Array.isArray(list) ? list.findIndex(item => item.id === op.path[op.path.length - 1]) : -1;
    if (index === -1) return;
    const [item] = list.splice(index, 1);
    if (op.op === 'move') list.splice(Math.min(op.index, list.length), 0, item);
}

function readFormIntoDocs() {
    readFormIntoConfig();
    // Keyed by profile and by ore rather than bound by path, so they read themselves back.
    saveProfileSwitchHotkeys();
    saveOreTable();
}

// Redraws what shows `paths` after the app changed or clamped them; a whole list redraws, so an item's open editor may close.
function refreshForm(name, paths) {
    if (name === 'global') {
        applyGlobalSettingsToForm();
        return;
    }
    const lists = new Set();
    const fields = [];
    for (const path of paths) {
        if (path[0] === 'hotkeyGroups' && path.length === 3 && path[2] === 'characters') {
            const index = app.currentConfig.hotkeyGroups.findIndex(group => group.id === path[1]);
            if (index !== -1) refreshHotkeyGroupCharsList(index);
        } else if (path[0] === 'characters' && path.length === 3 && path[2] === 'windowPosition') {
            refreshCharacterWindowPosition(app.currentConfig.characters.findIndex(char => char.id === path[1]));
        } else if (path[0] === 'characters' && path.length === 3 && path[2] === 'position') {
            // Not shown in the form.
        } else if (LIST_VIEWS[path[0]]) {
            lists.add(path[0]);
        } else if (path[0] === 'thumbnail' && path[1] === 'notifications' && path[2] === 'type_configs') {
            lists.add('notifications');
        } else {
            fields.push(path.join('.'));
        }
    }
    for (const list of lists) (list === 'notifications' ? populateNotificationTypes : LIST_VIEWS[list])();
    if (fields.length > 0) applyPathsToForm(fields);
}

async function sendEdits(name) {
    const current = docOf(name);
    const ops = [];
    diffObject(confirmed[name], current, [], ops);
    if (ops.length === 0) return;

    let reply;
    try {
        reply = await rpc('applyOps', { doc: name, ops: ops.map(({ item, ...op }) => op) });
    } catch (error) {
        logError('The app rejected an edit, reloading its copy:', error);
        showStatus(t('status.failedPrefix') + error.message, 'error');
        await adoptSnapshot(await rpc('getSession'));
        return;
    }

    const changed = [];
    ops.forEach((op, i) => {
        const result = reply.results[i];
        if (op.op === 'insert') {
            op.item.id = result.id;
            // Filled in quietly: redrawing the list would take focus from the new item being typed into.
            for (const [key, value] of Object.entries(result)) {
                if (!(key in op.item)) op.item[key] = clone(value);
            }
            applyOp(confirmed[name], { ...op, value: result });
        } else if (op.op === 'set') {
            setAt(confirmed[name], op.path, clone(result));
            if (!sameValue(result, op.value)) {
                setAt(current, op.path, clone(result));
                changed.push(op.path);
            }
        } else {
            applyOp(confirmed[name], op);
        }
    });
    setDirty(reply.dirty);
    if (changed.length > 0) refreshForm(name, changed);
}

async function flushNow() {
    if (!confirmed.profile || typeof webui === 'undefined') return;
    readFormIntoDocs();
    await sendEdits('profile');
    await sendEdits('global');
}

export function scheduleFlush() {
    if (!confirmed.profile) return;
    clearTimeout(flushTimer);
    flushTimer = setTimeout(flushEdits, FLUSH_DELAY_MS);
}

export function hasPendingEdits() {
    return flushTimer !== null;
}

// Sends every edit the form holds; resolves once the app has them.
export function flushEdits() {
    clearTimeout(flushTimer);
    flushTimer = null;
    return enqueue(flushNow);
}

async function adoptSnapshot(snapshot) {
    app.currentConfig = snapshot.profile;
    app.currentGlobalSettings = snapshot.global;
    app.oreCatalog = snapshot.oreCatalog;
    app.editsDraft = snapshot.editsDraft;
    confirmed.profile = clone(snapshot.profile);
    confirmed.global = clone(snapshot.global);
    populateFormFields();
    await applyGlobalSettingsToForm();
    setDirty(snapshot.dirty);
}

// A drag, the tray or an assign key changed the running profile the window edits.
listenForAppEvent('liveProfileChanged', (ops) => enqueue(async () => {
    if (!confirmed.profile) return;
    // Sent first, so reading the form back afterwards can't undo the app's change.
    await flushNow();
    for (const op of ops) {
        applyOp(confirmed.profile, op);
        applyOp(app.currentConfig, op);
    }
    const paths = ops.map(op => op.path);
    if (ops.some(op => op.op === 'insert' && op.path[0] === 'characters')) paths.push(['characters']);
    refreshForm('profile', paths);
}));

// The documents the app held belong to the profile it ran before, so start over from what's saved.
listenForAppEvent('profileSwitched', () => enqueue(async () => {
    if (!confirmed.profile) return;
    await adoptSnapshot(await rpc('openSession'));
}));

export async function loadAppVersion() {
    try {
        const version = await rpc('getAppVersion');
        const versionEl = document.getElementById('app-version');
        if (versionEl) versionEl.textContent = version;
    } catch (error) {
        logWarn('Failed to load app version:', error);
    }
}

// Takes up edits the app made to the documents itself, such as an import.
export function reloadSession() {
    return enqueue(async () => adoptSnapshot(await rpc('getSession')));
}

// Starts over from what's saved, dropping unsaved edits.
export function openSession() {
    clearTimeout(flushTimer);
    flushTimer = null;
    return enqueue(async () => {
        if (typeof webui === 'undefined') {
            logWarn('WebUI not available');
            return;
        }
        showStatus(t('status.loadingConfig'), 'info');
        try {
            await adoptSnapshot(await rpc('openSession'));
            showStatus(t('status.loaded'), 'success');
        } catch (error) {
            logError('Failed to load configuration:', error);
            showStatus(t('status.failedPrefix') + error.message, 'error');
        }
    });
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
    if (!confirmed.profile) return;
    showStatus(t('status.savingConfig'), 'info');

    for (const name of app.pendingCharacterNames.values()) addCharacterIfMissing(name);
    app.pendingCharacterNames.clear();

    const hotkeyConflicts = updateHotkeyConflictHighlights();
    if (hotkeyConflicts.length > 0) {
        // A conflicting key can live on the characters or hotkey-groups tab as easily as the hotkeys one, so the first one decides where to land.
        switchTab(hotkeyConflicts[0][0]?.closest('.panel-content')?.dataset.panel || 'hotkeys');
        showHotkeyConflictModal(describeHotkeyConflicts(hotkeyConflicts));
        return;
    }

    await flushEdits();
    await enqueue(async () => {
        try {
            const wasDraft = app.editsDraft;
            const snapshot = await rpc('saveSession');
            if (wasDraft) {
                // Saving a draft switched the app to it, whose documents carry new ids.
                await adoptSnapshot(snapshot);
            } else {
                confirmed.profile = clone(snapshot.profile);
                confirmed.global = clone(snapshot.global);
                setDirty(snapshot.dirty);
            }
            showStatus(t('status.configSavedSuccess'), 'success');
        } catch (error) {
            logError('Save failed:', error);
            showStatus(t('status.saveConfigFailedPrefix') + error.message, 'error');
        }
    });
}
