// Hotkey display, recording and conflict detection.
import { app } from './state.js';
import { markAsChanged } from './changes.js';
import { escapeHtml, listenForAppEvent, logWarn, rpc } from './core.js';
import { t } from './i18n.js';

// A key and its modifier flags packed into one value, as combineKey in virtual_keys.zig does.
const VK_MASK = 0xFF;
const MOD_SHIFT_AMOUNT = 8;
// Aliases the app also accepts for a modifier (see parseModifierToken in virtual_keys.zig).
const MODIFIER_ALIASES = { control: 'ctrl', lwin: 'win', rwin: 'win' };

function keyNames() {
    return app.schema?.keys || [];
}

function modifierNames() {
    return app.schema?.modifiers || [];
}

function keyNameFor(vk) {
    return keyNames().find(key => key.vk === vk)?.name;
}

// The app's own spelling (see writeVirtualKey in virtual_keys.zig), e.g. "Ctrl+F9".
function formatHotkey(combined) {
    const modifiers = combined >> MOD_SHIFT_AMOUNT;
    const vk = combined & VK_MASK;
    const parts = modifierNames().filter(modifier => modifiers & modifier.flag).map(modifier => modifier.name);
    parts.push(keyNameFor(vk) ?? 'VK' + vk.toString(16).toUpperCase());
    return parts.join('+');
}

// "0x0278" as saved or "Ctrl+F9" as shown, packed; null if it doesn't name a key the app knows.
function parseHotkey(text) {
    const value = (text || '').trim();
    if (!value) return null;
    if (/^0x[0-9a-f]+$/i.test(value)) return parseInt(value, 16);
    const tokens = value.split('+').map(token => token.trim().toLowerCase()).filter(Boolean);
    const keyToken = tokens.pop();
    let modifiers = 0;
    for (const token of tokens) {
        const name = MODIFIER_ALIASES[token] || token;
        const modifier = modifierNames().find(m => m.name.toLowerCase() === name);
        if (!modifier) return null;
        modifiers |= modifier.flag;
    }
    const key = keyNames().find(k => k.name.toLowerCase() === keyToken);
    return key ? key.vk | (modifiers << MOD_SHIFT_AMOUNT) : null;
}

export function vkHexToFriendly(text) {
    const combined = parseHotkey(text);
    return combined == null ? text : formatHotkey(combined);
}

// The field's value in the spelling the app saves ("0x0278"), so it compares equal to what the app sends back.
function hotkeyToSaved(text) {
    const combined = parseHotkey(text);
    if (combined == null) return text ? text.trim() || null : null;
    return '0x' + combined.toString(16).toUpperCase().padStart(2, '0');
}

// A binding's combos as the app sends them (null, one key string, or an array) as an array.
export function toKeyArray(value) {
    if (value == null || value === '') return [];
    return Array.isArray(value) ? value : [value];
}

// The combos in the shape the app saves them (see KeyListWire in key_list.zig): null, one string, or an array.
export function keysToSaved(texts) {
    const saved = [...new Set(texts.map(hotkeyToSaved).filter(Boolean))];
    return saved.length === 0 ? null : saved.length === 1 ? saved[0] : saved;
}

function isBoundText(value) {
    return value.length > 0 && value !== t('common.hotkeyRecordingPrompt') && value !== t('common.hotkeyWaitingForInput');
}

function maxKeys() {
    return app.schema?.maxKeys ?? 1;
}

// No combo contains a space, so ", " can't be confused with the "," key itself (e.g. "Ctrl+,, F1").
const KEY_SEPARATOR = ', ';

// A field's combos, e.g. "Ctrl+1, 1" -> ["Ctrl+1", "1"]; none while it's empty or recording.
export function keyListValues(input) {
    const text = (input?.value || '').trim();
    if (!isBoundText(text)) return [];
    return text.split(/,\s+/).map(combo => combo.trim()).filter(Boolean);
}

export function keysToText(values) {
    return values.join(KEY_SEPARATOR);
}

// A binding's combos as the app sends them, in the text a field shows, e.g. "Ctrl+1, 1".
export function savedKeysToText(value) {
    return keysToText(toKeyArray(value).map(vkHexToFriendly));
}

// The .keycap-render span draws the bound combos as key caps over the input, which keeps its own text transparent;
// refreshHotkeyKeycaps() fills it, and CSS uncovers the raw input again while it's recording or being typed into.
// With a path, binding.js reads and writes the field's combos as one setting.
export function renderHotkeyInputHtml(fieldId, placeholder, { path = '', ariaLabel = '', value = '' } = {}) {
    const pathAttributes = path ? ` data-path="${path}" data-format="keys"` : '';
    const aria = ariaLabel ? ` aria-label="${escapeHtml(ariaLabel)}"` : '';
    return `<span class="keycap-field"><input type="text" id="${fieldId}" class="hotkey-input" value="${escapeHtml(value)}" placeholder="${t('common.hotkeyClickToBind')}" title="${escapeHtml(placeholder)}"${aria}${pathAttributes} onclick="if (!this.classList.contains('manual-editing')) recordHotkey('${fieldId}')" readonly><span class="keycap-render" aria-hidden="true"></span></span>
<button type="button" class="button-icon button-icon-danger" onclick="clearHotkey('${fieldId}')" title="${t('common.hotkeyClear')}">×</button>
<button type="button" class="hotkey-edit-btn" onclick="toggleManualHotkeyEdit('${fieldId}')" title="${t('common.hotkeyTypeDirectly')}">✎</button>`;
}

// "Ctrl+Shift+N" reads as three caps rather than one run of text. A trailing "+" is the plus key itself, not a separator.
function splitHotkeyCombo(value) {
    const trailingPlus = value.endsWith('+') && value.length > 1;
    const parts = (trailingPlus ? value.slice(0, -1) : value).split('+').filter(part => part.length > 0);
    if (trailingPlus) parts.push('+');
    return parts;
}

const HOTKEY_MODIFIERS = new Set(['CTRL', 'ALT', 'SHIFT', 'WIN', 'LWIN', 'RWIN']);

// Piggybacks on updateHotkeyConflictHighlights() the way refreshCharacterHotkeyBadges() does - it already runs after
// every finalized hotkey change, so there's no separate set of call sites to keep in step.
function refreshHotkeyKeycaps() {
    getAllHotkeyInputs().forEach(input => {
        const render = input.parentElement?.querySelector('.keycap-render');
        if (!render) return;

        render.innerHTML = keyListValues(input)
            .map(combo => splitHotkeyCombo(combo)
                .map(part => `<kbd class="keycap${HOTKEY_MODIFIERS.has(part.toUpperCase()) ? ' keycap-modifier' : ''}">${escapeHtml(part)}</kbd>`)
                .join('<span class="keycap-plus">+</span>'))
            .join('<span class="keycap-sep" aria-hidden="true">,</span>');
    });
}


// Every fixed binding on the Hotkeys tab, in the order it appears, rendered by renderHotkeyBindings() into the
// containers the panel declares. A row's markup lives in one place, and a new binding is one entry rather than
// eight lines of hand-copied HTML. `pair` puts a backward/forward set on one row instead of two near-identical ones.
const HOTKEY_BINDINGS = [
    {
        containerId: 'windowActionBindings',
        pathPrefix: 'hotkeys.',
        rows: [
            { id: 'hotkeyCloseAll', labelKey: 'field.hotkeyCloseAll.label', exampleKey: 'field.hotkeyCloseAll.placeholder' },
            { id: 'hotkeyCloseActive', labelKey: 'field.hotkeyCloseActive.label', exampleKey: 'field.hotkeyCloseActive.placeholder' },
            { id: 'hotkeyMinimizeAll', labelKey: 'field.hotkeyMinimizeAll.label', exampleKey: 'field.hotkeyMinimizeAll.placeholder' },
            { id: 'hotkeyToggleVisibility', labelKey: 'field.hotkeyToggleVisibility.label', exampleKey: 'field.hotkeyToggleVisibility.placeholder' },
            { id: 'hotkeyToggleAutoMinimize', labelKey: 'field.hotkeyToggleAutoMinimize.label', exampleKey: 'field.hotkeyToggleAutoMinimize.placeholder', hintKey: 'field.hotkeyToggleAutoMinimize.hint' },
            { id: 'hotkeyMoveToSavedPositions', labelKey: 'field.hotkeyMoveToSavedPositions.label', exampleKey: 'field.hotkeyMoveToSavedPositions.placeholder' },
        ],
    },
    {
        containerId: 'cyclingBindings',
        pathPrefix: 'hotkeys.',
        rows: [
            { labelKey: 'field.pair.excludedCharacters.label', pair: [
                { id: 'hotkeyPreviousExcluded', exampleKey: 'common.hotkeyExampleOpenBracket' },
                { id: 'hotkeyNextExcluded', exampleKey: 'common.hotkeyExampleCloseBracket' },
            ] },
            { labelKey: 'field.pair.notifiedCharacters.label', hintKey: 'tab.hotkeys.section.cycling.notified-hint', pair: [
                { id: 'hotkeyPreviousNotified', exampleKey: 'field.hotkeyPreviousNotified.placeholder' },
                { id: 'hotkeyCycleNotified', exampleKey: 'field.hotkeyCycleNotified.placeholder' },
            ] },
            { id: 'hotkeyToggleExclusion', labelKey: 'field.hotkeyToggleExclusion.label', exampleKey: 'field.hotkeyToggleExclusion.placeholder', hintKey: 'field.hotkeyToggleExclusion.hint' },
        ],
    },
    {
        containerId: 'suspendBindings',
        pathPrefix: 'hotkeys.',
        rows: [
            { id: 'hotkeySuspend', labelKey: 'field.hotkeySuspend.label', exampleKey: 'field.hotkeySuspend.placeholder' },
            { id: 'hotkeyToggleAlertMute', labelKey: 'field.hotkeyToggleAlertMute.label', exampleKey: 'field.hotkeyToggleAlertMute.placeholder', hintKey: 'field.hotkeyToggleAlertMute.hint' },
            { id: 'hotkeyExitApp', labelKey: 'field.hotkeyExitApp.label', exampleKey: 'field.hotkeyExitApp.placeholder' },
        ],
    },
    {
        containerId: 'profileBindings',
        pathPrefix: 'global.',
        rows: [
            { labelKey: 'field.pair.profile.label', pair: [
                { id: 'hotkeyPreviousProfile', exampleKey: 'field.hotkeyPreviousProfile.placeholder' },
                { id: 'hotkeyNextProfile', exampleKey: 'field.hotkeyNextProfile.placeholder' },
            ] },
        ],
    },
    {
        containerId: 'clientBindings',
        pathPrefix: 'global.',
        rows: [
            { labelKey: 'field.pair.loggedInClients.label', pair: [
                { id: 'hotkeyCycleAllClientsBackward', exampleKey: 'common.hotkeyExampleOpenBracket' },
                { id: 'hotkeyCycleAllClientsForward', exampleKey: 'common.hotkeyExampleCloseBracket' },
            ] },
            { labelKey: 'field.pair.notLoggedInClients.label', hintKey: 'field.pair.notLoggedInClients.hint', pair: [
                { id: 'hotkeyCycleNotLoggedInBackward', exampleKey: 'field.hotkeyCycleNotLoggedInBackward.placeholder' },
                { id: 'hotkeyCycleNotLoggedInForward', exampleKey: 'field.hotkeyCycleNotLoggedInForward.placeholder' },
            ] },
        ],
    },
    {
        containerId: 'windowFocusBindings',
        pathPrefix: 'global.',
        rows: [
            { id: 'hotkeyReturnToLastApp', labelKey: 'field.hotkeyReturnToLastApp.label', exampleKey: 'field.hotkeyReturnToLastApp.placeholder' },
        ],
    },
];

function renderHotkeyBindingField(field, row, directionKey, pathPrefix) {
    const glyph = directionKey ? `<span class="binding-dir" aria-hidden="true">${directionKey === 'common.previous' ? '←' : '→'}</span>` : '';
    // The pair shares one visible label, so each half names itself for screen readers and for the conflict messages.
    const ariaLabel = directionKey ? `${t(row.labelKey)} (${t(directionKey)})` : '';
    return `<div class="field-row">${glyph}${renderHotkeyInputHtml(field.id, t(field.exampleKey), { path: `${pathPrefix}${field.id}`, ariaLabel })}</div>`;
}

function renderHotkeyBindingRow(row, pathPrefix) {
    const fields = row.pair
        ? renderHotkeyBindingField(row.pair[0], row, 'common.previous', pathPrefix) + renderHotkeyBindingField(row.pair[1], row, 'common.next', pathPrefix)
        : renderHotkeyBindingField(row, row, null, pathPrefix);
    const firstId = row.pair ? row.pair[0].id : row.id;

    const hint = row.hintKey ? `<p class="hint hint-extra">${t(row.hintKey)}</p>` : '';

    return `
        <div class="binding${row.pair ? ' binding-paired' : ''}">
            <label for="${firstId}">${t(row.labelKey)}</label>
            <div class="binding-control">${fields}</div>
        </div>
        ${hint}
    `;
}

// Keyed by scope/containerId so re-registering is a no-op; replayed on resize (see initOverlayLayoutPreview) so a width measured before a post-load DPI correction doesn't stay stuck.
export const labelColumnRealignJobs = new Map();

// Each section is its own grid, so their label columns would each settle on that section's longest label and the
// fields would step in and out down the tab. Measuring the widest label across all of them (within one tab) gives
// one shared gutter - scoped per panel so an unrelated tab's longer label can't shift this one's alignment.
export function alignBindingLabelColumns(scope = '.panel-content[data-panel="hotkeys"]') {
    const lists = Array.from(document.querySelectorAll(`${scope} .binding-list`));
    if (lists.length === 0) return;
    labelColumnRealignJobs.set(`binding:${scope}`, () => alignBindingLabelColumns(scope));

    // Skip silently while hidden instead of resetting - a late async populate landing after a tab switch shouldn't clobber a good width with an unmeasurable one.
    if (lists.every(list => list.getClientRects().length === 0)) return;

    // max-content first, so each label reports the width of its own text rather than of the column it was stretched to.
    lists.forEach(list => { list.style.gridTemplateColumns = 'max-content minmax(8.75rem, 1fr)'; });

    // A paired row's control hangs back into the gutter by this much, so its label needs that much less of the column.
    const dirOffset = remVarToPx('--binding-dir-offset');
    const widest = Math.max(0, ...Array.from(document.querySelectorAll(`${scope} .binding > label`))
        .map(label => label.getBoundingClientRect().width + (label.parentElement.classList.contains('binding-paired') ? dirOffset : 0)));
    if (!widest) return;

    lists.forEach(list => { list.style.gridTemplateColumns = `${Math.ceil(widest)}px minmax(8.75rem, 1fr)`; });
}

// Called once at startup and again when the language changes, since the rows are built from t() rather than
// data-i18n attributes. Bindings live only in the DOM until Save, so their values are carried across the rebuild.
export function renderHotkeyBindings() {
    HOTKEY_BINDINGS.forEach(section => {
        const container = document.getElementById(section.containerId);
        if (!container) return;

        const bound = new Map(Array.from(container.querySelectorAll('input.hotkey-input')).map(input => [input.id, input.value]));
        container.innerHTML = section.rows.map(row => renderHotkeyBindingRow(row, section.pathPrefix)).join('');
        bound.forEach((value, id) => {
            const input = document.getElementById(id);
            if (input) input.value = value;
        });
    });

    alignBindingLabelColumns();
    updateHotkeyConflictHighlights();
}

// Every hotkey <input> carries the shared "hotkey-input" class so conflicts can be found across all of them without hardcoding each field's id.
function getAllHotkeyInputs() {
    return Array.from(document.querySelectorAll('input.hotkey-input'));
}

let hotkeyPlaceholderMeasureCtx = null;

// Custom properties compute to their literal token ("1.375rem"), not px.
export function remVarToPx(name) {
    const rootStyle = getComputedStyle(document.documentElement);
    return (parseFloat(rootStyle.getPropertyValue(name)) || 0) * parseFloat(rootStyle.fontSize);
}

function hotkeyTextWidth(input, text) {
    if (!hotkeyPlaceholderMeasureCtx) hotkeyPlaceholderMeasureCtx = document.createElement('canvas').getContext('2d');
    const style = getComputedStyle(input);
    hotkeyPlaceholderMeasureCtx.font = `${style.fontSize} ${style.fontFamily}`;
    return hotkeyPlaceholderMeasureCtx.measureText(text).width;
}

// Narrow fields (e.g. the compact App Hotkeys column) can't fit "Click to bind" - fall back to "Bind..." rather than
// letting it clip. Skips 'recording', which is managing its own placeholder ("Waiting for input...") right now.
export function updateHotkeyPlaceholders() {
    const full = t('common.hotkeyClickToBind');
    const short = t('common.hotkeyBindShort');
    getAllHotkeyInputs().forEach(input => {
        if (input.classList.contains('recording')) return;
        const style = getComputedStyle(input);
        const available = input.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
        input.placeholder = hotkeyTextWidth(input, full) <= available ? full : short;
    });
}

function normalizeHotkeyCombo(combo) {
    const combined = parseHotkey(combo);
    return combined == null ? combo.toLowerCase() : String(combined);
}

// Uses the field's <label for="..."> text if one exists, otherwise the name in its enclosing accordion/detail panel, disambiguating forward/backward.
function hotkeyFieldLabel(input) {
    // Set on each half of a paired binding, which has no <label for> of its own. Inside a detail panel the
    // group or character it belongs to names it better, so that branch below keeps precedence.
    const ariaLabel = input.getAttribute('aria-label');
    if (ariaLabel && !input.closest('.detail-panel')) return ariaLabel;

    if (input.id) {
        const label = document.querySelector(`label[for="${input.id}"]`);
        if (label) return label.textContent.trim();
    }

    const detailPanel = input.closest('.detail-panel');
    if (detailPanel) {
        const nameEl = detailPanel.querySelector('.detail-panel-name');
        const base = (nameEl && nameEl.textContent.trim()) || 'Character';

        // Groups can be renamed to anything, so the base name alone wouldn't tell the user this is a cycling key rather than a character/profile switch hotkey.
        if (input.id.startsWith('hkgroup_')) {
            const direction = input.id.endsWith('_forward') ? 'Forward' : input.id.endsWith('_backward') ? 'Backward' : input.id.endsWith('_assign') ? 'Assign' : null;
            return direction ? `Hotkey Group "${base}" (${direction})` : `Hotkey Group "${base}"`;
        }

        return base;
    }

    const accordion = input.closest('.accordion');
    if (accordion) {
        const nameEl = accordion.querySelector('.accordion-name');
        const base = (nameEl && nameEl.textContent.trim()) || 'Item';

        return base;
    }

    return input.id || 'Hotkey';
}

function isCharacterHotkeyInput(input) {
    return /^char_\d+_hotkey$/.test(input.id);
}

// Each group is the inputs sharing one combo, with that combo as its `combo`.
function findHotkeyConflicts() {
    const byKey = new Map();
    getAllHotkeyInputs().forEach(input => {
        for (const combo of keyListValues(input)) {
            const norm = normalizeHotkeyCombo(combo);
            if (!byKey.has(norm)) byKey.set(norm, Object.assign([], { combo }));
            const inputs = byKey.get(norm);
            if (!inputs.includes(input)) inputs.push(input);
        }
    });

    // Characters sharing a hotkey cycle instead of conflicting - only flag groups reaching outside the character roster.
    return Array.from(byKey.values()).filter(inputs => inputs.length > 1 && inputs.some(input => !isCharacterHotkeyInput(input)));
}

// Returns the conflict groups so callers can report them.
export function updateHotkeyConflictHighlights() {
    getAllHotkeyInputs().forEach(input => input.classList.remove('hotkey-conflict'));
    const conflicts = findHotkeyConflicts();
    conflicts.forEach(inputs => inputs.forEach(input => input.classList.add('hotkey-conflict')));
    refreshCharacterHotkeyBadges();
    refreshHotkeyKeycaps();
    updateHotkeyPlaceholders();
    return conflicts;
}

// Piggybacks on updateHotkeyConflictHighlights() since that already runs after every finalized hotkey change and after populateCharacters() rebuilds the list.
function refreshCharacterHotkeyBadges() {
    document.querySelectorAll('#charactersList .roster-row').forEach(row => {
        const index = row.dataset.index;
        const input = document.getElementById(`char_${index}_hotkey`);
        const badge = document.getElementById(`char_${index}_hotkeyBadge`);
        if (!input || !badge) return;

        const display = keysToText(keyListValues(input));
        badge.textContent = display ? `[${display}]` : '';
        badge.style.display = display ? '' : 'none';
    });
}

export function describeHotkeyConflicts(conflicts) {
    return conflicts
        .map(inputs => `"${inputs.combo}" is bound to: ${inputs.map(hotkeyFieldLabel).join(', ')}`)
        .join('\n');
}

export function showHotkeyConflictModal(message) {
    const modal = document.getElementById('hotkey-conflict-modal');
    const messageEl = document.getElementById('hotkey-conflict-message');
    const okBtn = document.getElementById('hotkey-conflict-modal-ok');

    messageEl.textContent = message;
    modal.classList.add('show');

    const handleClose = () => {
        modal.classList.remove('show');
        okBtn.removeEventListener('click', handleClose);
    };

    okBtn.addEventListener('click', handleClose);
}

let recordingField = null;
// Once a combo is captured, ignore further capture events until stopRecording() runs, or releasing a modifier after the main key would overwrite it with just the modifier.
let recordingComboCaptured = false;

// A bare Win press can't reach our DOM listeners (Windows steals focus for the Start Menu first), so the app's keyboard hook reports it instead - see keyboard_hook.zig's armWinKeyCapture.
listenForAppEvent('winKeyCaptured', (result) => {
    if (!recordingField || recordingComboCaptured) return;
    finalizeCapture(VK_LWIN, modifierFlags({ ctrlKey: result.ctrl, altKey: result.alt, shiftKey: result.shift, metaKey: false }));
});

// Fire-and-forget, since recordHotkey()/stopRecording() must stay synchronous.
async function suspendMainAppHotkeysForRecording() {
    if (typeof eveRpc === 'undefined') return;
    try {
        await rpc('suspendHotkeysForRecording');
    } catch (error) {
        logWarn('Failed to suspend main app hotkeys for recording:', error);
    }
}

async function resumeMainAppHotkeysAfterRecording() {
    if (typeof eveRpc === 'undefined') return;
    try {
        await rpc('resumeHotkeysAfterRecording');
    } catch (error) {
        logWarn('Failed to resume main app hotkeys after recording:', error);
    }
}

// Clears every combo on the field.
export function clearHotkey(fieldId) {
    const input = document.getElementById(fieldId);
    if (!input) return;

    // Cancel any in-progress recording or manual typing on this field before clearing it
    if (recordingField === fieldId) {
        stopRecording();
    }
    if (input.classList.contains('manual-editing')) {
        commitManualHotkeyEdit(fieldId);
    }

    if (input.value !== '') markAsChanged();
    input.value = '';
    updateHotkeyConflictHighlights();
}

// A capture adds a combo to the field's others; once it holds the most a binding takes, a capture starts it over.
export function recordHotkey(fieldId) {
    const input = document.getElementById(fieldId);
    if (!input) return;

    if (recordingField === fieldId) {
        stopRecording();
        return;
    }

    if (recordingField) {
        stopRecording();
    }

    // Manual typing and recording are mutually exclusive on a field
    if (input.classList.contains('manual-editing')) {
        commitManualHotkeyEdit(fieldId);
    }

    recordingField = fieldId;
    recordingComboCaptured = false;
    suspendMainAppHotkeysForRecording();
    input.dataset.beforeRecording = input.value;
    input.classList.add('recording');
    input.value = t('common.hotkeyRecordingPrompt');
    input.dataset.originalPlaceholder = input.placeholder;
    input.placeholder = t('common.hotkeyWaitingForInput');
    input.blur();

    // `wheel` listeners are passive by default, which would block captureWheel's preventDefault() (needed to stop the page scrolling under the modal).
    document.addEventListener('keydown', captureKeyDown, true);
    document.addEventListener('keyup', captureKey, true);
    document.addEventListener('mouseup', captureMouseButton, true);
    document.addEventListener('wheel', captureWheel, { capture: true, passive: false });
    document.addEventListener('contextmenu', preventContextMenu, true);
}

const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_LWIN = 0x5B;
const VK_RWIN = 0x5C;
const VK_MBUTTON = 0x04;
const VK_XBUTTON1 = 0x05;
const VK_XBUTTON2 = 0x06;
const VK_WHEELUP = 0x0A;
const VK_WHEELDOWN = 0x0B;
const MODIFIER_KEYS = { [VK_CONTROL]: 'Ctrl', [VK_MENU]: 'Alt', [VK_SHIFT]: 'Shift', [VK_LWIN]: 'Win', [VK_RWIN]: 'Win' };

function modifierFlags(e) {
    const held = { Ctrl: e.ctrlKey, Alt: e.altKey, Shift: e.shiftKey, Win: e.metaKey };
    return modifierNames().reduce((flags, modifier) => (held[modifier.name] ? flags | modifier.flag : flags), 0);
}

// Modifier state at keyup only reflects modifiers still held, so main keys are captured here on keydown instead, while modifiers are still reliably reflected.
// keyCode is the Windows virtual-key code in WebView2, so it's right for any keyboard layout; keys the app can't bind are ignored.
function captureKeyDown(e) {
    if (!recordingField || recordingComboCaptured) return;
    if (e.key === 'Escape') return;

    e.preventDefault();
    e.stopPropagation();

    if (MODIFIER_KEYS[e.keyCode] || !keyNameFor(e.keyCode)) return;
    finalizeCapture(e.keyCode, modifierFlags(e));
}

function finalizeCapture(vk, modifiers) {
    recordingComboCaptured = true;
    const input = document.getElementById(recordingField);
    const combo = formatHotkey(vk | (modifiers << MOD_SHIFT_AMOUNT));
    const before = keyListValues({ value: input.dataset.beforeRecording });
    const kept = before.length >= maxKeys() ? [] : before;
    input.value = keysToText(kept.includes(combo) ? kept : [...kept, combo]);
    markAsChanged();

    setTimeout(() => stopRecording(), 300);
}

// Handles Escape-to-cancel and binding a bare modifier released alone; non-modifier keys are captured on keydown instead (see captureKeyDown).
function captureKey(e) {
    if (!recordingField) return;

    e.preventDefault();
    e.stopPropagation();

    const key = e.key;

    if (key === 'Escape') {
        stopRecording();
        return;
    }

    if (recordingComboCaptured) return;
    const name = MODIFIER_KEYS[e.keyCode];
    if (!name) return;

    // The released modifier is the trigger; the others still held are its modifiers.
    const own = modifierNames().find(modifier => modifier.name === name)?.flag || 0;
    finalizeCapture(e.keyCode === VK_RWIN ? VK_LWIN : e.keyCode, modifierFlags(e) & ~own);
}

function stopRecording() {
    if (!recordingField) return;

    const input = document.getElementById(recordingField);
    input.classList.remove('recording');

    // Nothing captured (Escape, or clicking the field again) keeps the combos it had.
    if (input.value === t('common.hotkeyRecordingPrompt')) {
        input.value = input.dataset.beforeRecording || '';
    }
    delete input.dataset.beforeRecording;

    input.placeholder = input.dataset.originalPlaceholder || '';
    delete input.dataset.originalPlaceholder;

    document.removeEventListener('keydown', captureKeyDown, true);
    document.removeEventListener('keyup', captureKey, true);
    document.removeEventListener('mouseup', captureMouseButton, true);
    document.removeEventListener('wheel', captureWheel, { capture: true, passive: false });
    document.removeEventListener('contextmenu', preventContextMenu, true);

    recordingField = null;
    recordingComboCaptured = false;
    resumeMainAppHotkeysAfterRecording();

    updateHotkeyConflictHighlights();
}

// Lets a hotkey be typed directly (e.g. "Ctrl+F9", or "Ctrl+1, 1" for several) instead of captured via Record, for keys the recorder can't pick up cleanly.
export function toggleManualHotkeyEdit(fieldId) {
    const input = document.getElementById(fieldId);
    if (!input) return;

    const button = input.closest('.field-row')?.querySelector('.hotkey-edit-btn');

    if (input.classList.contains('manual-editing')) {
        commitManualHotkeyEdit(fieldId);
        return;
    }

    // Recording and manual typing are mutually exclusive on a field
    if (recordingField === fieldId) {
        stopRecording();
    }

    input.dataset.beforeManualEdit = input.value;
    input.readOnly = false;
    input.classList.add('manual-editing');
    input.focus();
    input.select();
    if (button) {
        button.classList.add('active');
        button.title = t('common.hotkeyDoneEditing');
    }

    // Enter/Escape commit the typed value without requiring another click on the pencil
    const onKeydown = (e) => {
        if (e.key === 'Enter' || e.key === 'Escape') {
            e.preventDefault();
            input.removeEventListener('keydown', onKeydown);
            commitManualHotkeyEdit(fieldId);
        }
    };
    input.addEventListener('keydown', onKeydown);
}

function commitManualHotkeyEdit(fieldId) {
    const input = document.getElementById(fieldId);
    if (!input) return;

    const button = input.closest('.field-row')?.querySelector('.hotkey-edit-btn');

    // Only names the app knows are kept, shown in its own spelling; anything else goes back to what was there.
    const typed = keyListValues(input);
    const combined = typed.map(parseHotkey);
    const unknown = typed.filter((_, i) => combined[i] == null);
    if (unknown.length > 0) logWarn('Not a key the app can bind: ' + unknown.join(', '));
    const tooMany = new Set(combined).size > maxKeys();
    if (tooMany) logWarn(`A hotkey holds at most ${maxKeys()} keys`);
    input.value = unknown.length > 0 || tooMany
        ? input.dataset.beforeManualEdit || ''
        : keysToText([...new Set(combined.map(formatHotkey))]);
    delete input.dataset.beforeManualEdit;
    input.readOnly = true;
    input.classList.remove('manual-editing');
    markAsChanged();
    if (button) {
        button.classList.remove('active');
        button.title = t('common.hotkeyTypeDirectly');
    }

    updateHotkeyConflictHighlights();
}

function captureMouseButton(e) {
    if (!recordingField || recordingComboCaptured) return;

    e.preventDefault();
    e.stopPropagation();

    // LButton/RButton are left out: thumbnails use them for drag/click.
    const vk = { 1: VK_MBUTTON, 3: VK_XBUTTON1, 4: VK_XBUTTON2 }[e.button];
    if (vk) finalizeCapture(vk, modifierFlags(e));
}

// Also wired up as a working hotkey via the same low-level mouse hook as the mouse buttons (see mouse_hook.zig).
function captureWheel(e) {
    if (!recordingField || recordingComboCaptured) return;

    e.preventDefault();
    e.stopPropagation();

    // deltaY < 0 is scrolled up/away from the user, > 0 is scrolled down/toward the user
    finalizeCapture(e.deltaY < 0 ? VK_WHEELUP : VK_WHEELDOWN, modifierFlags(e));
}

function preventContextMenu(e) {
    if (recordingField) {
        e.preventDefault();
        e.stopPropagation();
    }
}
