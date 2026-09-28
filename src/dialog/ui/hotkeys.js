// Hotkey display, recording and conflict detection.
import { markAsChanged } from './changes.js';
import { escapeHtml, listenForAppEvent, logWarn, rpc } from './core.js';
import { t } from './i18n.js';

// Mirrors the Zig-side writeVirtualKey() in virtual_keys.zig - keep these two in sync.
function friendlyBaseKeyName(vkCode) {
    if (vkCode >= 0x70 && vkCode <= 0x87) return 'F' + (vkCode - 0x70 + 1);
    if (vkCode >= 0x41 && vkCode <= 0x5A) return String.fromCharCode(vkCode);
    if (vkCode >= 0x30 && vkCode <= 0x39) return String.fromCharCode(vkCode);
    if (vkCode >= 0x60 && vkCode <= 0x69) return 'Numpad' + (vkCode - 0x60);
    // Spellings must match parseBaseKey() exactly since this text round-trips back through it on save.
    const named = {
        // A bare modifier used as the trigger key itself (e.g. plain "Shift", or "Ctrl+Shift" with Shift as the trigger).
        0x10: 'Shift',
        0x11: 'Ctrl',
        0x12: 'Alt',
        0x5B: 'Win',
        0x09: 'Tab',
        0x13: 'Pause',
        0x14: 'CapsLock',
        0x90: 'NumLock',
        0x91: 'ScrollLock',
        0x20: 'Space',
        0x21: 'PageUp',
        0x22: 'PageDown',
        0x23: 'End',
        0x24: 'Home',
        0x25: 'Left',
        0x26: 'Up',
        0x27: 'Right',
        0x28: 'Down',
        0x2D: 'Insert',
        0x2E: 'Delete',
        0x6A: 'NumpadMultiply',
        0x6B: 'NumpadAdd',
        0x6D: 'NumpadSubtract',
        0x6E: 'NumpadDecimal',
        0x6F: 'NumpadDivide',
        0x05: 'XButton1',
        0x06: 'XButton2',
        0x0A: 'WheelUp',
        0x0B: 'WheelDown',
        0xBA: ';',
        0xBB: '=',
        0xBC: ',',
        0xBD: '-',
        0xBE: '.',
        0xBF: '/',
        0xC0: '`',
        0xDB: '[',
        0xDC: '\\',
        0xDD: ']',
        0xDE: "'",
    };
    if (named[vkCode]) return named[vkCode];
    return '0x' + vkCode.toString(16).toUpperCase().padStart(2, '0');
}

// Tokens that aren't hex VK codes are returned unchanged; a hex token can pack modifier flags in bits 8-11 (see virtual_keys.zig), expanded into a "Ctrl+Alt+..." prefix here.
export function vkHexToFriendly(str) {
    if (!str) return str;
    const tokens = str.split('+');
    const converted = tokens.map(token => {
        const t = token.trim();
        if (!/^0[xX][0-9a-fA-F]+$/.test(t)) return t;
        const combined = parseInt(t, 16);
        const vkCode = combined & 0xFF;
        const mods = (combined >> 8) & 0x0F;

        const parts = [];
        if (mods & 0x02) parts.push('Ctrl');
        if (mods & 0x01) parts.push('Alt');
        if (mods & 0x04) parts.push('Shift');
        if (mods & 0x08) parts.push('LWin');
        parts.push(friendlyBaseKeyName(vkCode));

        return parts.join('+');
    });
    return converted.join('+');
}

// The .keycap-render span draws the bound combo as key caps over the input, which keeps its own text transparent;
// refreshHotkeyKeycaps() fills it, and CSS uncovers the raw input again while it's recording or being typed into.
export function renderHotkeyInputHtml(fieldId, value, placeholder, extraAttributes = '') {
    return `<span class="keycap-field"><input type="text" id="${fieldId}" class="hotkey-input" value="${value}" placeholder="${t('common.hotkeyClickToBind')}" title="${placeholder}"${extraAttributes} onclick="if (!this.classList.contains('manual-editing')) recordHotkey('${fieldId}')" readonly><span class="keycap-render" aria-hidden="true"></span></span>
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

        const value = input.value.trim();
        const bound = value.length > 0 && value !== t('common.hotkeyRecordingPrompt') && value !== t('common.hotkeyWaitingForInput');

        render.innerHTML = bound
            ? splitHotkeyCombo(value)
                .map(part => `<kbd class="keycap${HOTKEY_MODIFIERS.has(part.toUpperCase()) ? ' keycap-modifier' : ''}">${escapeHtml(part)}</kbd>`)
                .join('<span class="keycap-plus">+</span>')
            : '';
    });
}


// Every fixed binding on the Hotkeys tab, in the order it appears, rendered by renderHotkeyBindings() into the
// containers the panel declares. A row's markup lives in one place, and a new binding is one entry rather than
// eight lines of hand-copied HTML. `pair` puts a backward/forward set on one row instead of two near-identical ones.
const HOTKEY_BINDINGS = [
    {
        containerId: 'windowActionBindings',
        rows: [
            { id: 'hotkeyCloseAll', labelKey: 'field.hotkeyCloseAll.label', exampleKey: 'field.hotkeyCloseAll.placeholder' },
            { id: 'hotkeyMinimizeAll', labelKey: 'field.hotkeyMinimizeAll.label', exampleKey: 'field.hotkeyMinimizeAll.placeholder' },
            { id: 'hotkeyToggleVisibility', labelKey: 'field.hotkeyToggleVisibility.label', exampleKey: 'field.hotkeyToggleVisibility.placeholder' },
            { id: 'hotkeyToggleAutoMinimize', labelKey: 'field.hotkeyToggleAutoMinimize.label', exampleKey: 'field.hotkeyToggleAutoMinimize.placeholder', hintKey: 'field.hotkeyToggleAutoMinimize.hint' },
            { id: 'hotkeyMoveToSavedPositions', labelKey: 'field.hotkeyMoveToSavedPositions.label', exampleKey: 'field.hotkeyMoveToSavedPositions.placeholder' },
        ],
    },
    {
        containerId: 'cyclingBindings',
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
        rows: [
            { id: 'hotkeySuspend', labelKey: 'field.hotkeySuspend.label', exampleKey: 'field.hotkeySuspend.placeholder' },
        ],
    },
    {
        containerId: 'profileBindings',
        rows: [
            { labelKey: 'field.pair.profile.label', pair: [
                { id: 'hotkeyPreviousProfile', exampleKey: 'field.hotkeyPreviousProfile.placeholder' },
                { id: 'hotkeyNextProfile', exampleKey: 'field.hotkeyNextProfile.placeholder' },
            ] },
        ],
    },
    {
        containerId: 'clientBindings',
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
        rows: [
            { id: 'hotkeyReturnToLastApp', labelKey: 'field.hotkeyReturnToLastApp.label', exampleKey: 'field.hotkeyReturnToLastApp.placeholder' },
        ],
    },
];

function renderHotkeyBindingField(field, row, directionKey) {
    const glyph = directionKey ? `<span class="binding-dir" aria-hidden="true">${directionKey === 'common.previous' ? '←' : '→'}</span>` : '';
    // The pair shares one visible label, so each half names itself for screen readers and for the conflict messages.
    const ariaLabel = directionKey ? ` aria-label="${escapeHtml(`${t(row.labelKey)} (${t(directionKey)})`)}"` : '';
    return `<div class="field-row">${glyph}${renderHotkeyInputHtml(field.id, '', t(field.exampleKey), ariaLabel)}</div>`;
}

function renderHotkeyBindingRow(row) {
    const fields = row.pair
        ? renderHotkeyBindingField(row.pair[0], row, 'common.previous') + renderHotkeyBindingField(row.pair[1], row, 'common.next')
        : renderHotkeyBindingField(row, row);
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
        container.innerHTML = section.rows.map(renderHotkeyBindingRow).join('');
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

function normalizeHotkeyValue(value) {
    if (!value) return null;
    const v = value.trim();
    if (!v || v === t('common.hotkeyRecordingPrompt') || v === t('common.hotkeyWaitingForInput')) return null;
    // Some fields display raw "0xNN" hex while others display friendly names - run everything through vkHexToFriendly so the same physical key compares equal.
    const friendly = vkHexToFriendly(v).toLowerCase();

    // Modifier order is irrelevant to the OS ("Ctrl+Alt+F9" == "Alt+Ctrl+F9") but not to a string compare - canonicalize order before comparing.
    const tokens = friendly.split('+').map(t => t.trim()).filter(Boolean);
    if (tokens.length <= 1) return friendly;
    const mainKey = tokens[tokens.length - 1];
    const modifierOrder = ['ctrl', 'control', 'alt', 'shift', 'win', 'lwin', 'rwin'];
    const modifiers = tokens.slice(0, -1).sort((a, b) => modifierOrder.indexOf(a) - modifierOrder.indexOf(b));
    return [...modifiers, mainKey].join('+');
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

function findHotkeyConflicts() {
    const byKey = new Map();
    getAllHotkeyInputs().forEach(input => {
        const norm = normalizeHotkeyValue(input.value);
        if (!norm) return;
        if (!byKey.has(norm)) byKey.set(norm, []);
        byKey.get(norm).push(input);
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

        const value = input.value.trim();
        const display = value && value !== t('common.hotkeyRecordingPrompt') && value !== t('common.hotkeyWaitingForInput') ? value : '';
        badge.textContent = display ? `[${display}]` : '';
        badge.style.display = display ? '' : 'none';
    });
}

export function describeHotkeyConflicts(conflicts) {
    return conflicts
        .map(inputs => `"${vkHexToFriendly(inputs[0].value.trim())}" is bound to: ${inputs.map(hotkeyFieldLabel).join(', ')}`)
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
    const combo = [];
    if (result.ctrl) combo.push('Ctrl');
    if (result.alt) combo.push('Alt');
    if (result.shift) combo.push('Shift');
    combo.push('LWin');
    finalizeCapture(combo);
});

// Fire-and-forget, since recordHotkey()/stopRecording() must stay synchronous.
async function suspendMainAppHotkeysForRecording() {
    if (typeof webui === 'undefined') return;
    try {
        await rpc('suspendHotkeysForRecording');
    } catch (error) {
        logWarn('Failed to suspend main app hotkeys for recording:', error);
    }
}

async function resumeMainAppHotkeysAfterRecording() {
    if (typeof webui === 'undefined') return;
    try {
        await rpc('resumeHotkeysAfterRecording');
    } catch (error) {
        logWarn('Failed to resume main app hotkeys after recording:', error);
    }
}

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

function buildModifierCombo(e) {
    let combo = [];
    if (e.ctrlKey) combo.push('Ctrl');
    if (e.altKey) combo.push('Alt');
    if (e.shiftKey) combo.push('Shift');
    if (e.metaKey) combo.push('LWin');
    return combo;
}

// Modifier state at keyup only reflects modifiers still held, so main keys are captured here on keydown instead, while modifiers are still reliably reflected.
function captureKeyDown(e) {
    if (!recordingField || recordingComboCaptured) return;

    const key = e.key;
    if (key === 'Escape') return;

    e.preventDefault();
    e.stopPropagation();

    if (key === 'Control' || key === 'Alt' || key === 'Shift' || key === 'Meta') return;

    let combo = buildModifierCombo(e);
    combo.push(mapMainKey(key, e.code));

    finalizeCapture(combo);
}

function mapMainKey(key, code) {
    const codeMap = {
        'Digit0': '0',
        'Digit1': '1',
        'Digit2': '2',
        'Digit3': '3',
        'Digit4': '4',
        'Digit5': '5',
        'Digit6': '6',
        'Digit7': '7',
        'Digit8': '8',
        'Digit9': '9',
        'Numpad0': 'Numpad0',
        'Numpad1': 'Numpad1',
        'Numpad2': 'Numpad2',
        'Numpad3': 'Numpad3',
        'Numpad4': 'Numpad4',
        'Numpad5': 'Numpad5',
        'Numpad6': 'Numpad6',
        'Numpad7': 'Numpad7',
        'Numpad8': 'Numpad8',
        'Numpad9': 'Numpad9',
        'NumpadDivide': 'NumpadDivide',
        'NumpadMultiply': 'NumpadMultiply',
        'NumpadSubtract': 'NumpadSubtract',
        'NumpadAdd': 'NumpadAdd',
        'NumpadEnter': 'NumpadEnter',
        'NumpadDecimal': 'NumpadDecimal',
    };

    if (code && codeMap[code]) {
        return codeMap[code];
    } else {
        const keyMap = {
                ' ': 'Space',
                'Enter': 'Enter',
                'Escape': 'Esc',
                'Tab': 'Tab',
                'Backspace': 'Backspace',
                'Delete': 'Delete',
                'Insert': 'Insert',
                'Home': 'Home',
                'End': 'End',
                'PageUp': 'PageUp',
                'PageDown': 'PageDown',
                'ArrowUp': 'Up',
                'ArrowDown': 'Down',
                'ArrowLeft': 'Left',
                'ArrowRight': 'Right',
                'F1': 'F1', 'F2': 'F2', 'F3': 'F3', 'F4': 'F4',
                'F5': 'F5', 'F6': 'F6', 'F7': 'F7', 'F8': 'F8',
                'F9': 'F9', 'F10': 'F10', 'F11': 'F11', 'F12': 'F12',
                'F13': 'F13', 'F14': 'F14', 'F15': 'F15', 'F16': 'F16',
                'F17': 'F17', 'F18': 'F18', 'F19': 'F19', 'F20': 'F20',
                'F21': 'F21', 'F22': 'F22', 'F23': 'F23', 'F24': 'F24',
                'CapsLock': 'CapsLock',
                'NumLock': 'NumLock',
                'ScrollLock': 'ScrollLock',
                'PrintScreen': 'PrintScreen',
                'Pause': 'Pause',
                'ContextMenu': 'AppsKey',
                'AudioVolumeUp': 'Volume_Up',
                'AudioVolumeDown': 'Volume_Down',
                'AudioVolumeMute': 'Volume_Mute',
                'MediaPlayPause': 'Media_Play_Pause',
                'MediaStop': 'Media_Stop',
                'MediaTrackNext': 'Media_Next',
                'MediaTrackPrevious': 'Media_Prev',
                'BrowserBack': 'Browser_Back',
                'BrowserForward': 'Browser_Forward',
                'BrowserRefresh': 'Browser_Refresh',
                'BrowserStop': 'Browser_Stop',
                'BrowserSearch': 'Browser_Search',
                'BrowserFavorites': 'Browser_Favorites',
                'BrowserHome': 'Browser_Home',
                
                // One OEM key can produce two chars via Shift (e.g. ';'/':'); both normalize to the unshifted spelling since Shift is captured separately above. '+' maps to '=' since a trailing '+' would be ambiguous with the modifier-combo delimiter.
                ';': ';',
                '=': '=',
                '+': '=',
                ',': ',',
                '-': '-',
                '.': '.',
                '/': '/',
                '?': '/',
                '`': '`',
                '[': '[',
                '\\': '\\',
                ']': ']',
                "'": "'",
        };

        return keyMap[key] || key.toUpperCase();
    }
}

function finalizeCapture(combo) {
    if (combo.length === 0) return;

    recordingComboCaptured = true;
    const hotkeyString = combo.join('+');
    const input = document.getElementById(recordingField);
    input.value = hotkeyString;
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
    if (key !== 'Control' && key !== 'Alt' && key !== 'Shift' && key !== 'Meta') return;

    let combo = buildModifierCombo(e);
    if (key === 'Control' && !combo.includes('Ctrl')) combo.push('Ctrl');
    else if (key === 'Alt' && !combo.includes('Alt')) combo.push('Alt');
    else if (key === 'Shift' && !combo.includes('Shift')) combo.push('Shift');
    else if (key === 'Meta' && !combo.includes('LWin')) combo.push('LWin');

    finalizeCapture(combo);
}

function stopRecording() {
    if (!recordingField) return;

    const input = document.getElementById(recordingField);
    input.classList.remove('recording');

    // Reset value and placeholder if no binding was set
    if (input.value === t('common.hotkeyRecordingPrompt')) {
        input.value = '';
    }

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

// Lets a hotkey be typed directly (e.g. "Ctrl+F9") instead of captured via Record, for keys the recorder can't pick up cleanly.
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

    input.value = input.value.trim();
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

    const button = e.button;
    let combo = buildModifierCombo(e);

    // Only XButton1/XButton2 are wired up as working hotkeys (see mouse_hook.zig) - LButton/RButton are already used locally for thumbnail drag/click, and MButton has no hook support.
    const mouseMap = {
        3: 'XButton1',
        4: 'XButton2'
    };

    const mouseButton = mouseMap[button];
    if (mouseButton) {
        combo.push(mouseButton);
        finalizeCapture(combo);
    }
}

// Also wired up as a working hotkey via the same low-level mouse hook as XButton1/XButton2 (see mouse_hook.zig).
function captureWheel(e) {
    if (!recordingField || recordingComboCaptured) return;

    e.preventDefault();
    e.stopPropagation();

    let combo = buildModifierCombo(e);

    // deltaY < 0 is scrolled up/away from the user, > 0 is scrolled down/toward the user
    combo.push(e.deltaY < 0 ? 'WheelUp' : 'WheelDown');

    finalizeCapture(combo);
}

function preventContextMenu(e) {
    if (recordingField) {
        e.preventDefault();
        e.stopPropagation();
    }
}
