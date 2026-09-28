// Importing settings from EVE-X, EVE-APM, EVE-O and other EVE-Maj profiles.
import { app } from './state.js';
import { markAsChanged } from './changes.js';
import { DEFAULT_ACCENT_COLOR_HTML, applyAccentColorTheme, htmlColorToZig, zigColorWithAlpha } from './colors.js';
import { escapeHtml, logError, logWarn, rpc } from './core.js';
import { populateFormFields } from './form.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { sendThumbnailPreview } from './preview.js';
import { MAX_PROFILE_NAME_LENGTH, loadImportBackupsList, loadProfileList, switchProfile } from './profiles.js';
import { saveConfiguration } from './session.js';

// Live-previews the import modal's accent color pick the same way showProfileNameModal does.
export function initImportAccentColorPreview() {
    const input = document.getElementById('importAccentColor');
    if (input) input.addEventListener('input', () => applyAccentColorTheme(htmlColorToZig(input.value)));
}

let importParsedData = null;
let importFormat = null;

// Must match config.zig's PROFILE_FORMAT_IDENTIFIER, stamped onto every profile this app saves so it can be recognized outright instead of guessed at like the legacy formats below.
const MAJ_FORMAT_IDENTIFIER = 'eve-maj-preview';

// Mirrors combineKey()/extractVk()/extractModifiers() in virtual_keys.zig: low byte = base VK code, bits 8-11 = MOD_ALT/MOD_CONTROL/MOD_SHIFT/MOD_WIN.
const LEGACY_MOD_SYMBOLS = { '^': 0x02, '!': 0x01, '+': 0x04, '#': 0x08 };
// AHK v1 prefix symbols that affect hook behavior, not the modifier set; none have an OS-level equivalent, but aren't reasons to fail the conversion (e.g. "*F22" just becomes plain F22).
const LEGACY_PREFIX_SYMBOLS = new Set(['*', '~', '$']);
const LEGACY_MOD_WORDS = { ctrl: 0x02, control: 0x02, alt: 0x01, shift: 0x04, win: 0x08, lwin: 0x08, rwin: 0x08 };
const LEGACY_MOUSE_BUTTONS = new Set(['lbutton', 'rbutton', 'mbutton', 'xbutton1', 'xbutton2']);
// XButton1/XButton2 are real Win32 VK codes representable as OS-level hotkeys via this app's mouse hook - other legacy mouse buttons stay unsupported (already used locally for drag/click).
const LEGACY_MOUSE_BUTTON_VK = { xbutton1: 0x05, xbutton2: 0x06 };
// WheelUp/WheelDown go through the same low-level mouse hook via pseudo VK codes 0x0A/0x0B.
const LEGACY_WHEEL_VK = { wheelup: 0x0A, wheeldown: 0x0B };
const LEGACY_NAMED_KEYS = {
    space: 0x20, pageup: 0x21, pgup: 0x21, pagedown: 0x22, pgdn: 0x22,
    end: 0x23, home: 0x24, left: 0x25, up: 0x26, right: 0x27, down: 0x28,
    insert: 0x2D, ins: 0x2D, delete: 0x2E, del: 0x2E,
    numpadmult: 0x6A, numpadmultiply: 0x6A, numpadadd: 0x6B, numpadsub: 0x6D,
    numpadsubtract: 0x6D, numpaddot: 0x6E, numpaddecimal: 0x6E, numpaddiv: 0x6F, numpaddivide: 0x6F,
};

// Resolve a single (non-modifier) legacy key token to its base VK code, or null if unrecognized.
function legacyBaseKeyToVk(token) {
    const t = token.trim();
    if (t.length === 0) return null;
    if (t.length === 1) {
        const ch = t.toUpperCase().charCodeAt(0);
        if (ch >= 0x41 && ch <= 0x5A) return ch;
        if (ch >= 0x30 && ch <= 0x39) return ch;
    }
    const lower = t.toLowerCase();
    if (/^f([1-9]|1[0-9]|2[0-4])$/.test(lower)) {
        return 0x70 + (parseInt(lower.slice(1), 10) - 1);
    }
    if (/^numpad[0-9]$/.test(lower)) {
        return 0x60 + parseInt(lower.slice(6), 10);
    }
    if (Object.prototype.hasOwnProperty.call(LEGACY_NAMED_KEYS, lower)) {
        return LEGACY_NAMED_KEYS[lower];
    }
    return null;
}

// Returns null if the hotkey can't be represented as an OS-level modifier+key hotkey (mouse buttons, unrecognized combinations) - callers must report this, never silently drop it.
function legacyHotkeyToVkHex(rawStr) {
    if (!rawStr || typeof rawStr !== 'string') return null;
    let str = rawStr.trim();
    if (str.length === 0) return null;

    let mods = 0;
    while (str.length > 0 && (LEGACY_MOD_SYMBOLS[str[0]] !== undefined || LEGACY_PREFIX_SYMBOLS.has(str[0]))) {
        mods |= LEGACY_MOD_SYMBOLS[str[0]] || 0;
        str = str.slice(1);
    }

    // AHK v1 "A & B" syntax is only representable if the left side is a real modifier word - a held mouse button isn't an OS modifier, but the right side can still be one.
    const ampIdx = str.indexOf(' & ');
    if (ampIdx !== -1) {
        const left = str.slice(0, ampIdx).trim().toLowerCase();
        const right = str.slice(ampIdx + 3).trim();
        if (LEGACY_MOUSE_BUTTONS.has(left)) return null;
        if (!Object.prototype.hasOwnProperty.call(LEGACY_MOD_WORDS, left)) return null;
        mods |= LEGACY_MOD_WORDS[left];
        str = right;
    }

    const mouseVk = LEGACY_MOUSE_BUTTON_VK[str.trim().toLowerCase()];
    if (mouseVk !== undefined) {
        const combined = (mouseVk & 0xFF) | ((mods & 0x0F) << 8);
        return '0x' + combined.toString(16).toUpperCase();
    }
    if (LEGACY_MOUSE_BUTTONS.has(str.trim().toLowerCase())) return null;

    const wheelVk = LEGACY_WHEEL_VK[str.trim().toLowerCase()];
    if (wheelVk !== undefined) {
        const combined = (wheelVk & 0xFF) | ((mods & 0x0F) << 8);
        return '0x' + combined.toString(16).toUpperCase();
    }

    const vk = legacyBaseKeyToVk(str);
    if (vk === null) return null;

    const combined = (vk & 0xFF) | ((mods & 0x0F) << 8);
    return '0x' + combined.toString(16).toUpperCase();
}

// Converts "#RRGGBB"/"RRGGBB" (no alpha) to the "0xAARRGGBB" format used throughout currentConfig; null if unparseable.
function legacyColorToZig(str) {
    if (!str) return null;
    const hex = String(str).replace(/^#/, '').replace(/^0x/i, '').trim();
    if (!/^[0-9a-fA-F]{6}$/.test(hex)) return null;
    return '0xFF' + hex.toUpperCase();
}

// EVE-X Preview's JSON serializes some numeric fields as quoted strings inconsistently across versions - coerce and validate rather than trusting typeof.
function legacyNum(v) {
    return (v === undefined || v === null || v === '' || isNaN(Number(v))) ? null : Number(v);
}

function computeImportSections(oldProfile, oldGlobal) {
    oldProfile = oldProfile || {};
    oldGlobal = oldGlobal || {};

    const ts = oldProfile['Thumbnail Settings'] || {};
    const tsl = oldGlobal.ThumbnailStartLocation || {};
    const hasThumbAppearance = Object.keys(ts).length > 0 || Object.keys(tsl).length > 0 ||
        ('ShowSystemName' in oldGlobal) || ('HideActiveThumbnail' in oldGlobal);

    const positions = oldProfile['Thumbnail Positions'] || {};
    const hasPositions = Object.keys(positions).length > 0;

    const cc = oldProfile['Custom Colors'];
    const colorsActive = !!(cc && (cc.cColorActive === 1 || cc.cColorActive === '1' || cc.cColorActive === true));
    const charNames = (colorsActive && cc.cColors && Array.isArray(cc.cColors.CharNames)) ? cc.cColors.CharNames : [];
    const hotkeysArr = Array.isArray(oldProfile['Hotkeys']) ? oldProfile['Hotkeys'] : [];
    const hasColorsOrHotkeys = charNames.length > 0 || hotkeysArr.length > 0;

    const groups = oldProfile['Hotkey Groups'] || {};
    const hasGroups = Object.keys(groups).length > 0;

    const cs = oldProfile['Client Settings'] || {};
    const dontMinimize = Array.isArray(cs.Dont_Minimize_Clients) ? cs.Dont_Minimize_Clients : [];
    const hasAutoMinimize = ('MinimizeInactiveClients' in cs) || dontMinimize.length > 0 || (typeof oldGlobal.Minimize_Delay === 'number');

    const hasSnapping = ('ThumbnailSnap' in oldGlobal) || ('ThumbnailSnap_Distance' in oldGlobal) ||
        (typeof oldGlobal.Suspend_Hotkeys_Hotkey === 'string' && oldGlobal.Suspend_Hotkeys_Hotkey.trim() !== '');

    const hasGlobalHotkeys = ['HideShowThumbnailsHotkey', 'CycleWhileHeld', 'LockPositions'].some(k => k in oldGlobal);
    const hasChatlog = ['EnableChatLogMonitoring', 'EnableGameLogMonitoring', 'ChatLogDirectory', 'GameLogDirectory'].some(k => k in oldGlobal);

    return [
        { id: 'thumbnailAppearance', title: t('dynamic.import.evex.thumbnailAppearance.title'), hint: t('dynamic.import.evex.thumbnailAppearance.hint'), available: hasThumbAppearance },
        { id: 'characterPositions', title: t('dynamic.import.evex.characterPositions.title'), hint: t('dynamic.import.characterPositionsHint').replace('{n}', Object.keys(positions).length), available: hasPositions },
        { id: 'characterColorsHotkeys', title: t('dynamic.import.evex.characterColorsHotkeys.title'), hint: t('dynamic.import.characterColorsHotkeysHint').replace('{colors}', charNames.length).replace('{hotkeys}', hotkeysArr.length), available: hasColorsOrHotkeys },
        { id: 'hotkeyGroups', title: t('dynamic.import.evex.hotkeyGroups.title'), hint: t('dynamic.import.hotkeyGroupsCountHint').replace('{n}', Object.keys(groups).length), available: hasGroups },
        { id: 'autoMinimize', title: t('dynamic.import.evex.autoMinimize.title'), hint: t('dynamic.import.evex.autoMinimize.hint'), available: hasAutoMinimize },
        { id: 'snapping', title: t('dynamic.import.evex.snapping.title'), hint: t('dynamic.import.evex.snapping.hint'), available: hasSnapping },
        { id: 'globalHotkeys', title: t('dynamic.import.apm.globalHotkeys.title'), hint: t('dynamic.import.evex.globalHotkeys.hint'), available: hasGlobalHotkeys },
        { id: 'chatlog', title: t('dynamic.import.apm.chatlog.title'), hint: t('dynamic.import.apm.chatlog.hint'), available: hasChatlog },
    ];
}

function renderImportSections() {
    const container = document.getElementById('importSectionsList');
    if (!container) return;

    let sections;
    if (importFormat === 'evex' && importParsedData) {
        const select = document.getElementById('importSourceProfile');
        const oldProfile = importParsedData._Profiles[select.value] || {};
        const oldGlobal = importParsedData.global_Settings || {};
        sections = computeImportSections(oldProfile, oldGlobal);
    } else if (importFormat === 'apm' && importParsedData) {
        sections = computeApmImportSections(importParsedData);
    } else if (importFormat === 'eveo' && importParsedData) {
        sections = computeEveoImportSections(importParsedData);
    } else if (importFormat === 'maj' && importParsedData) {
        sections = computeMajImportSections(importParsedData);
    } else {
        container.innerHTML = '';
        return;
    }

    container.innerHTML = sections.map(s => `
        <label class="import-section-item" title="${escapeHtml(s.available ? s.hint : t('dynamic.import.nothingToImportHint'))}">
            <input type="checkbox" id="import_${s.id}" ${s.available ? 'checked' : 'disabled'}>
            <span class="label-body">${escapeHtml(s.title)}</span>
        </label>
    `).join('');
}

// Legacy formats only ever had one overlay font, applied everywhere by this app's old shared font.
// Combat/Mining/Bounty are skipped - no legacy source value exists for them.
function applyImportedFontToOtherOverlayElements(patch, fontName, fontSize) {
    if (fontName) {
        patch.systemNameFontName = fontName;
        patch.quickGroupBadgeFontName = fontName;
    }
    if (fontSize !== null) {
        patch.systemNameFontSize = fontSize;
        patch.quickGroupBadgeFontSize = fontSize;
    }
    if (fontName || fontSize !== null) {
        const existing = app.currentConfig.thumbnail?.notifications || {};
        patch.notifications = Object.assign({}, existing, {
            font_name: fontName || existing.font_name,
            font_size: fontSize !== null ? fontSize : existing.font_size,
        });
    }
}

function extractThumbnailAppearance(oldProfile, oldGlobal) {
    const ts = oldProfile['Thumbnail Settings'] || {};
    const tsl = oldGlobal.ThumbnailStartLocation || {};
    const patch = {};
    const num = legacyNum;

    if (num(ts.ClientHighligtBorderthickness) !== null) patch.borderWidth = num(ts.ClientHighligtBorderthickness);
    const borderColor = legacyColorToZig(ts.ClientHighligtColor);
    if (borderColor) patch.borderColor = borderColor;
    if (typeof ts.ShowClientHighlightBorder !== 'undefined') patch.showBorderWhenFocused = !!ts.ShowClientHighlightBorder;

    if (num(ts.InactiveClientBorderthickness) !== null) patch.inactiveBorderWidth = num(ts.InactiveClientBorderthickness);
    const inactiveColor = legacyColorToZig(ts.InactiveClientBorderColor);
    if (inactiveColor) patch.inactiveBorderColor = inactiveColor;
    if (typeof ts.ShowAllColoredBorders !== 'undefined') patch.showBorderWhenInactive = !!ts.ShowAllColoredBorders;

    if (typeof ts.ShowThumbnailTextOverlay !== 'undefined') patch.showText = !!ts.ShowThumbnailTextOverlay;
    const textColor = legacyColorToZig(ts.ThumbnailTextColor);
    if (textColor) patch.characterNameColor = textColor;
    if (ts.ThumbnailTextFont) patch.characterNameFontName = String(ts.ThumbnailTextFont);
    if (num(ts.ThumbnailTextSize) !== null) patch.characterNameFontSize = num(ts.ThumbnailTextSize);
    applyImportedFontToOtherOverlayElements(patch, ts.ThumbnailTextFont ? String(ts.ThumbnailTextFont) : null, num(ts.ThumbnailTextSize));

    if (ts.ThumbnailTextMargins) {
        if (num(ts.ThumbnailTextMargins.x) !== null) patch.characterNameOffsetX = num(ts.ThumbnailTextMargins.x);
        if (num(ts.ThumbnailTextMargins.y) !== null) patch.characterNameOffsetY = num(ts.ThumbnailTextMargins.y);
    }

    if (num(ts.ThumbnailOpacity) !== null) {
        patch.thumbnailOpacity = Math.max(0, Math.min(255, Math.round(num(ts.ThumbnailOpacity) * 2.55)));
    }

    if (typeof ts.HideThumbnailsOnLostFocus !== 'undefined') patch.hideWhenNoEveFocus = !!ts.HideThumbnailsOnLostFocus;

    if (num(tsl.width) !== null) patch.width = num(tsl.width);
    if (num(tsl.height) !== null) patch.height = num(tsl.height);

    const showSystemName = legacyFlag(oldGlobal.ShowSystemName);
    if (showSystemName !== null) patch.showSystemName = showSystemName;
    const hideActive = legacyFlag(oldGlobal.HideActiveThumbnail);
    if (hideActive !== null) patch.activeThumbnailHidden = hideActive;

    return { patch, notes: [t('dynamic.import.thumbnailAppearanceImportedNote')] };
}

function legacyFlag(v) {
    const n = legacyNum(v);
    return n === null ? null : n !== 0;
}

function extractEvexGlobalHotkeys(oldGlobal) {
    const hotkeysPatch = {};
    const interactionPatch = {};
    const notes = [];

    const toggleRaw = oldGlobal.HideShowThumbnailsHotkey;
    if (typeof toggleRaw === 'string' && toggleRaw.trim() !== '') {
        const hex = legacyHotkeyToVkHex(toggleRaw);
        if (hex) {
            hotkeysPatch.hotkeyToggleVisibility = hex;
        } else {
            notes.push(t('dynamic.import.apm.globalHotkeyUnsupportedNote').replace('{label}', t('dynamic.import.apm.actionLabel.toggleVisibility')));
        }
    }

    const cycleWhileHeld = legacyFlag(oldGlobal.CycleWhileHeld);
    if (cycleWhileHeld !== null) hotkeysPatch.allowHotkeyAutoRepeat = cycleWhileHeld;

    const lockPositions = legacyFlag(oldGlobal.LockPositions);
    if (lockPositions !== null) interactionPatch.enableDragging = !lockPositions;

    notes.push(t('dynamic.import.apm.globalHotkeysImportedNote'));
    return { hotkeysPatch, interactionPatch, notes };
}

function extractEvexChatlog(oldGlobal) {
    const patch = {};
    const chatEnabled = legacyFlag(oldGlobal.EnableChatLogMonitoring);
    const gameEnabled = legacyFlag(oldGlobal.EnableGameLogMonitoring);
    if (chatEnabled !== null || gameEnabled !== null) patch.enabled = !!(chatEnabled || gameEnabled);
    if (typeof oldGlobal.ChatLogDirectory === 'string' && oldGlobal.ChatLogDirectory.trim() !== '') patch.chatlogDir = oldGlobal.ChatLogDirectory.trim();
    if (typeof oldGlobal.GameLogDirectory === 'string' && oldGlobal.GameLogDirectory.trim() !== '') patch.gamelogDir = oldGlobal.GameLogDirectory.trim();
    return { patch, notes: [t('dynamic.import.apm.chatlogImportedNote')] };
}

function extractCharacterPositions(oldProfile) {
    const positions = oldProfile['Thumbnail Positions'] || {};
    const characterPatches = [];
    Object.keys(positions).forEach(name => {
        const p = positions[name] || {};
        const cp = { name };
        if (typeof p.x === 'number' && typeof p.y === 'number') cp.position = { x: p.x, y: p.y };
        if (typeof p.width === 'number' || typeof p.height === 'number') {
            cp.thumbnailSize = {};
            if (typeof p.width === 'number') cp.thumbnailSize.width = p.width;
            if (typeof p.height === 'number') cp.thumbnailSize.height = p.height;
        }
        characterPatches.push(cp);
    });
    return { characterPatches, notes: [t('dynamic.import.importedPositionsWithSizeNote').replace('{n}', characterPatches.length)] };
}

function extractCharacterColorsAndHotkeys(oldProfile) {
    const notes = [];
    const byName = new Map();

    const cc = oldProfile['Custom Colors'];
    const colorsActive = !!(cc && (cc.cColorActive === 1 || cc.cColorActive === '1' || cc.cColorActive === true));
    if (colorsActive && cc.cColors) {
        const names = Array.isArray(cc.cColors.CharNames) ? cc.cColors.CharNames : [];
        const active = Array.isArray(cc.cColors.Bordercolor) ? cc.cColors.Bordercolor : [];
        const inactive = Array.isArray(cc.cColors.IABordercolor) ? cc.cColors.IABordercolor : [];
        names.forEach((name, i) => {
            const entry = byName.get(name) || { name };
            const activeColor = legacyColorToZig(active[i]);
            const inactiveColor = legacyColorToZig(inactive[i]);
            if (activeColor || inactiveColor) {
                entry.borderColors = entry.borderColors || {};
                if (activeColor) entry.borderColors.activeBorderColor = activeColor;
                if (inactiveColor) entry.borderColors.inactiveBorderColor = inactiveColor;
            }
            byName.set(name, entry);
        });
        if (names.length > 0) notes.push(t('dynamic.import.evex.importedBorderColorsForCharsNote').replace('{n}', names.length));
        if (Array.isArray(cc.cColors.TextColor) && cc.cColors.TextColor.length > 0) {
            notes.push(t('dynamic.import.evex.textColorNotSupportedNote'));
        }
    }

    const hotkeysArr = Array.isArray(oldProfile['Hotkeys']) ? oldProfile['Hotkeys'] : [];
    let convertedCount = 0;
    hotkeysArr.forEach(entry => {
        if (!entry || typeof entry !== 'object') return;
        Object.keys(entry).forEach(name => {
            const raw = entry[name];
            const hex = legacyHotkeyToVkHex(raw);
            const patchEntry = byName.get(name) || { name };
            if (hex) {
                patchEntry.hotkey = hex;
                convertedCount++;
            } else {
                notes.push(t('dynamic.import.evex.hotkeySkippedNote').replace('{name}', name).replace('{raw}', raw));
            }
            byName.set(name, patchEntry);
        });
    });
    if (hotkeysArr.length > 0) notes.push(t('dynamic.import.convertedHotkeysNote').replace('{converted}', convertedCount).replace('{total}', hotkeysArr.length));

    return { characterPatches: Array.from(byName.values()), notes };
}

function extractHotkeyGroups(oldProfile) {
    const groups = oldProfile['Hotkey Groups'] || {};
    const notes = [];
    const hotkeyGroups = [];
    Object.keys(groups).forEach(name => {
        const g = groups[name] || {};
        const characters = Array.isArray(g.Characters) ? g.Characters.slice() : [];
        const forwardKey = g.ForwardsHotkey ? legacyHotkeyToVkHex(g.ForwardsHotkey) : null;
        const backwardKey = g.BackwardsHotkey ? legacyHotkeyToVkHex(g.BackwardsHotkey) : null;
        if (g.ForwardsHotkey && !forwardKey) {
            notes.push(t('dynamic.import.hotkeyGroupForwardKeyFailedNote').replace('{name}', name).replace('{key}', g.ForwardsHotkey));
        }
        if (g.BackwardsHotkey && !backwardKey) {
            notes.push(t('dynamic.import.hotkeyGroupBackwardKeyFailedNote').replace('{name}', name).replace('{key}', g.BackwardsHotkey));
        }
        hotkeyGroups.push({ name, characters, forwardKey: forwardKey || null, backwardKey: backwardKey || null });
    });
    notes.unshift(t('dynamic.import.hotkeyGroupsImportedNote').replace('{n}', hotkeyGroups.length));
    return { hotkeyGroups, notes };
}

function extractAutoMinimize(oldProfile, oldGlobal) {
    const cs = oldProfile['Client Settings'] || {};
    const patch = {};
    if (typeof cs.MinimizeInactiveClients !== 'undefined') patch.enabled = !!cs.MinimizeInactiveClients;
    const delayMs = legacyNum(oldGlobal.Minimize_Delay);
    if (delayMs !== null) patch.delayMs = delayMs;
    const characterPatches = Array.isArray(cs.Dont_Minimize_Clients)
        ? cs.Dont_Minimize_Clients.map(name => ({ name, excludeFromMinimize: true }))
        : [];
    return { patch, characterPatches, notes: [t('dynamic.import.autoMinimizeImportedNote')] };
}

function extractSnapping(oldProfile, oldGlobal) {
    const snappingPatch = {};
    const hotkeysPatch = {};
    const notes = [];
    if (typeof oldGlobal.ThumbnailSnap !== 'undefined') snappingPatch.enabled = !!oldGlobal.ThumbnailSnap;
    const snapDistance = legacyNum(oldGlobal.ThumbnailSnap_Distance);
    if (snapDistance !== null) snappingPatch.threshold = snapDistance;

    const suspendRaw = oldGlobal.Suspend_Hotkeys_Hotkey;
    if (typeof suspendRaw === 'string' && suspendRaw.trim() !== '') {
        const hex = legacyHotkeyToVkHex(suspendRaw);
        if (hex) {
            hotkeysPatch.hotkeySuspend = hex;
        } else {
            notes.push(t('dynamic.import.evex.suspendHotkeyFailedNote').replace('{key}', suspendRaw));
        }
    }
    notes.push(t('dynamic.import.snappingImportedNote'));
    return { snappingPatch, hotkeysPatch, notes };
}

// The dialog seeds an empty-named entry so blank lists have a row to edit; imports would otherwise leave it as "Character 1"/"Hotkey Group 1".
function removeUnnamedPlaceholders(list, imported, keyField) {
    if (!imported.some(item => (item[keyField] || '').trim())) return;
    const isEmptyValue = v => v == null || v === '' || v === false || (Array.isArray(v) && v.length === 0);
    for (let i = list.length - 1; i >= 0; i--) {
        const entry = list[i];
        const pristine = !(entry[keyField] || '').trim()
            && Object.entries(entry).every(([k, v]) => k === keyField || isEmptyValue(v));
        if (pristine) list.splice(i, 1);
    }
}

// Matches by name so patches from different sections don't clobber each other's fields; creates a new entry if the name isn't already present.
function mergeCharacterPatch(cfg, characterPatches) {
    if (!cfg.characters) cfg.characters = [];
    removeUnnamedPlaceholders(cfg.characters, characterPatches, 'name');
    characterPatches.forEach(cp => {
        const name = (cp.name || '').trim();
        if (!name) return;
        let existing = cfg.characters.find(c => (c.name || '').trim().toLowerCase() === name.toLowerCase());
        if (!existing) {
            existing = { name, position: null, borderColors: null, thumbnailSize: null, displayName: null, hotkey: null };
            cfg.characters.push(existing);
        }
        if (cp.position) existing.position = cp.position;
        if (cp.thumbnailSize) existing.thumbnailSize = Object.assign({}, existing.thumbnailSize, cp.thumbnailSize);
        if (cp.borderColors) existing.borderColors = Object.assign({}, existing.borderColors, cp.borderColors);
        if (cp.hotkey) existing.hotkey = cp.hotkey;
        if (cp.excludeFromMinimize) existing.excludeFromMinimize = true;
        if (cp.excludeFromCloseAll) existing.excludeFromCloseAll = true;
        if (cp.hideThumbnail) existing.hideThumbnail = true;
    });
}

// Minimal INI parser for EVE-APM Preview's QSettings-style file; values are left raw, callers use iniUnquote/parseQtPoint/etc. as needed.
function parseIniText(text) {
    const sections = {};
    let current = null;
    text.split(/\r?\n/).forEach(lineRaw => {
        const line = lineRaw.trim();
        if (!line || line.startsWith(';') || line.startsWith('#')) return;
        const sectionMatch = line.match(/^\[(.+)\]$/);
        if (sectionMatch) {
            current = sectionMatch[1];
            if (!sections[current]) sections[current] = {};
            return;
        }
        if (current === null) return;
        const eq = line.indexOf('=');
        if (eq === -1) return;
        const key = line.slice(0, eq).trim();
        const value = line.slice(eq + 1).trim();
        sections[current][key] = value;
    });
    return sections;
}

// QSettings percent-encoding isn't standard URI encoding (raw Latin-1/UTF-16 code units, plus a "%U"+4-hex form outside Latin-1), so decodeURIComponent mis-decodes or throws on it.
function iniDecodeKey(key) {
    let out = '';
    for (let i = 0; i < key.length; i++) {
        if (key[i] === '%' && key[i + 1] === 'U' && /^[0-9a-fA-F]{4}$/.test(key.slice(i + 2, i + 6))) {
            out += String.fromCharCode(parseInt(key.slice(i + 2, i + 6), 16));
            i += 5;
        } else if (key[i] === '%' && /^[0-9a-fA-F]{2}$/.test(key.slice(i + 1, i + 3))) {
            out += String.fromCharCode(parseInt(key.slice(i + 1, i + 3), 16));
            i += 2;
        } else {
            out += key[i];
        }
    }
    return out;
}

function iniUnquote(v) {
    if (v == null) return v;
    const t = String(v).trim();
    if (t.length >= 2 && t[0] === '"' && t[t.length - 1] === '"') return t.slice(1, -1);
    return t;
}

// Qt's QPoint serializes as "@Point(x y)" in QSettings' text format.
function parseQtPoint(v) {
    if (!v) return null;
    const m = /@Point\(\s*(-?\d+)\s+(-?\d+)\s*\)/.exec(v);
    if (!m) return null;
    return { x: parseInt(m[1], 10), y: parseInt(m[2], 10) };
}

function parseQtBool(v) {
    return String(v).trim().toLowerCase() === 'true';
}

// Qt's QVariant serializes an unset/invalid value as the literal "@Invalid()".
function isQtInvalid(v) {
    return v === undefined || v === null || v.trim() === '' || v.trim() === '@Invalid()';
}

// "Family,Size,...". Only the family and point size are usable in EVE-Maj Preview.
function parseQtFont(v) {
    const unq = iniUnquote(v);
    if (!unq) return null;
    const parts = unq.split(',');
    const family = (parts[0] || '').trim();
    const size = parseInt(parts[1], 10);
    return { family: family || null, size: Number.isFinite(size) ? size : null };
}

// Packed as raw integer tuples "enabled,keyCode,ctrl,alt,shift" (verified against EVE-APM Preview's HotkeyBinding::toString/fromString); keyCode is already a raw VK code.
function decodeApmHotkeyTuple(csv) {
    if (!csv) return null;
    const parts = String(csv).split(',').map(s => parseInt(s.trim(), 10));
    if (parts.length < 2 || !parts[0]) return null;
    const vk = parts[1];
    if (!Number.isFinite(vk) || vk <= 0) return null;
    // VK_LBUTTON/RBUTTON/MBUTTON can't be registered as OS-level hotkeys - they're already used locally for thumbnail drag/click.
    if (vk === 0x01 || vk === 0x02 || vk === 0x04) return null;

    let mods = 0;
    if (parts[2]) mods |= 0x02;
    if (parts[3]) mods |= 0x01;
    if (parts[4]) mods |= 0x04;

    const combined = (vk & 0xFF) | ((mods & 0x0F) << 8);
    return '0x' + combined.toString(16).toUpperCase();
}

function computeApmImportSections(sections) {
    const hasThumbAppearance = !!(sections['ui'] || sections['overlay'] || sections['thumbnail']);

    const positions = sections['thumbnailPositions'] || {};
    const hasPositions = Object.keys(positions).length > 0;

    const colors = sections['characterBorderColors'] || {};
    const hotkeys = sections['characterHotkeys'] || {};
    const hasColors = Object.keys(colors).length > 0 || Object.keys(hotkeys).length > 0;

    const groups = sections['cycleGroups'] || {};
    const hasGroups = Object.keys(groups).length > 0;

    const win = sections['window'] || {};
    const hasAutoMinimize = ('minimizeInactiveClients' in win) || ('minimizeDelay' in win) || !isQtInvalid(win.neverMinimizeCharacters);

    const pos = sections['position'] || {};
    const hasSnapping = ('enableSnapping' in pos) || ('snapDistance' in pos);

    const hasGlobalHotkeys = !!(sections['closeAllHotkeys'] || sections['minimizeAllHotkeys'] ||
        sections['toggleThumbnailsVisibilityHotkeys'] || sections['hotkeys'] || sections['hotkey']);

    const hasChatlog = !!(sections['chatlog'] || sections['gamelog']);

    const cm = sections['combatMessages'] || {};
    const hasNotifications = !!(cm.enabledEventTypes && cm.enabledEventTypes.trim() !== '');

    return [
        { id: 'thumbnailAppearance', title: t('dynamic.import.apm.thumbnailAppearance.title'), hint: t('dynamic.import.apm.thumbnailAppearance.hint'), available: hasThumbAppearance },
        { id: 'characterPositions', title: t('dynamic.import.apm.characterPositions.title'), hint: t('dynamic.import.characterPositionsHint').replace('{n}', Object.keys(positions).length), available: hasPositions },
        { id: 'characterColors', title: t('dynamic.import.apm.characterColors.title'), hint: t('dynamic.import.characterColorsHotkeysHint').replace('{colors}', Object.keys(colors).length).replace('{hotkeys}', Object.keys(hotkeys).length), available: hasColors },
        { id: 'hotkeyGroups', title: t('dynamic.import.apm.hotkeyGroups.title'), hint: t('dynamic.import.hotkeyGroupsCountHint').replace('{n}', Object.keys(groups).length), available: hasGroups },
        { id: 'globalHotkeys', title: t('dynamic.import.apm.globalHotkeys.title'), hint: t('dynamic.import.apm.globalHotkeys.hint'), available: hasGlobalHotkeys },
        { id: 'autoMinimize', title: t('dynamic.import.apm.autoMinimize.title'), hint: t('dynamic.import.apm.autoMinimize.hint'), available: hasAutoMinimize },
        { id: 'snapping', title: t('dynamic.import.apm.snapping.title'), hint: t('dynamic.import.apm.snapping.hint'), available: hasSnapping },
        { id: 'chatlog', title: t('dynamic.import.apm.chatlog.title'), hint: t('dynamic.import.apm.chatlog.hint'), available: hasChatlog },
        { id: 'notifications', title: t('dynamic.import.apm.notifications.title'), hint: t('dynamic.import.apm.notifications.hint'), available: hasNotifications },
    ];
}

// EVE-APM Preview's OverlayPosition enum is ordinally identical to this app's TextPosition, except two names have their words swapped.
const APM_POSITION_MAP = ['TopLeft', 'TopCenter', 'TopRight', 'LeftCenter', 'Center', 'RightCenter', 'BottomLeft', 'BottomCenter', 'BottomRight'];

function apmPositionToZig(raw) {
    const n = parseInt(raw, 10);
    return Number.isFinite(n) ? (APM_POSITION_MAP[n] || null) : null;
}

// Only the first four values of EVE-APM Preview's BorderStyle enum share a visual meaning here - the rest are glow/animated effects, intentionally left unmapped and reported.
const APM_BORDER_STYLE_NAMES = ['Solid', 'Dashed', 'Dotted', 'DashDot', 'FadedEdges', 'CornerAccents', 'RoundedCorners', 'Neon', 'Shimmer', 'ThickThin', 'ElectricArc', 'Rainbow', 'BreathingGlow', 'DoubleGlow', 'Zigzag'];
const APM_BORDER_STYLE_SUPPORTED = new Set(['Solid', 'Dashed', 'Dotted', 'DashDot']);

function apmBorderStyleToZig(raw, notes, label) {
    const n = parseInt(raw, 10);
    if (!Number.isFinite(n)) return null;
    const name = APM_BORDER_STYLE_NAMES[n] || `#${n}`;
    if (APM_BORDER_STYLE_SUPPORTED.has(name)) return name;
    notes.push(t('dynamic.import.apm.borderStyleUnsupportedNote').replace('{label}', label).replace('{name}', name));
    return null;
}

function apmExtractThumbnailAppearance(sections) {
    const ui = sections['ui'] || {};
    const overlay = sections['overlay'] || {};
    const thumb = sections['thumbnail'] || {};
    const patch = {};
    const notes = [t('dynamic.import.thumbnailAppearanceImportedNote')];
    const num = (v) => (v === undefined || v === null || v === '' || isNaN(Number(v))) ? null : Number(v);

    const borderColor = legacyColorToZig(ui.highlightColor);
    if (borderColor) patch.borderColor = borderColor;
    if (num(ui.highlightBorderWidth) !== null) patch.borderWidth = num(ui.highlightBorderWidth);
    if ('highlightActiveWindow' in ui) patch.showBorderWhenFocused = parseQtBool(ui.highlightActiveWindow);
    if ('hideThumbnailsWhenEVENotFocused' in ui) patch.hideWhenNoEveFocus = parseQtBool(ui.hideThumbnailsWhenEVENotFocused);
    if ('hideActiveClientThumbnail' in ui) patch.activeThumbnailHidden = parseQtBool(ui.hideActiveClientThumbnail);
    if ('activeBorderStyle' in ui) {
        const style = apmBorderStyleToZig(ui.activeBorderStyle, notes, t('dynamic.import.apm.activeLabel'));
        if (style) patch.borderStyle = style;
    }

    const inactiveColor = legacyColorToZig(ui.inactiveBorderColor);
    if (inactiveColor) patch.inactiveBorderColor = inactiveColor;
    if (num(ui.inactiveBorderWidth) !== null) patch.inactiveBorderWidth = num(ui.inactiveBorderWidth);
    if ('showInactiveBorders' in ui) patch.showBorderWhenInactive = parseQtBool(ui.showInactiveBorders);
    if ('inactiveBorderStyle' in ui) {
        const style = apmBorderStyleToZig(ui.inactiveBorderStyle, notes, t('dynamic.import.apm.inactiveLabel'));
        if (style) patch.inactiveBorderStyle = style;
    }

    if ('showCharacterName' in overlay) patch.showCharacterName = parseQtBool(overlay.showCharacterName);
    if ('showSystemName' in overlay) patch.showSystemName = parseQtBool(overlay.showSystemName);
    if ('showCharacterName' in overlay || 'showSystemName' in overlay) {
        patch.showText = !!(patch.showCharacterName || patch.showSystemName);
    }

    const charColor = legacyColorToZig(overlay.characterNameColor);
    if (charColor) patch.characterNameColor = charColor;
    const sysColor = legacyColorToZig(overlay.systemNameColor);
    if (sysColor) patch.systemNameColor = sysColor;
    if ('uniqueSystemNameColors' in overlay) patch.useUniqueSystemColors = parseQtBool(overlay.uniqueSystemNameColors);

    if ('characterNamePosition' in overlay) {
        const pos = apmPositionToZig(overlay.characterNamePosition);
        if (pos) patch.characterNamePosition = pos;
    }
    if ('systemNamePosition' in overlay) {
        const pos = apmPositionToZig(overlay.systemNamePosition);
        if (pos) patch.systemNamePosition = pos;
    }
    if (num(overlay.characterNameOffsetX) !== null) patch.characterNameOffsetX = num(overlay.characterNameOffsetX);
    if (num(overlay.characterNameOffsetY) !== null) patch.characterNameOffsetY = num(overlay.characterNameOffsetY);
    if (num(overlay.systemNameOffsetX) !== null) patch.systemNameOffsetX = num(overlay.systemNameOffsetX);
    if (num(overlay.systemNameOffsetY) !== null) patch.systemNameOffsetY = num(overlay.systemNameOffsetY);

    const bgColor = legacyColorToZig(overlay.backgroundColor);
    if (bgColor) {
        const showBg = 'showBackground' in overlay ? parseQtBool(overlay.showBackground) : true;
        const bgOpacity = num(overlay.backgroundOpacity);
        const alpha255 = showBg ? (bgOpacity !== null ? bgOpacity * 2.55 : 255) : 0;
        // Legacy format has one shared background - seed it onto every element that still exists here today (see applyImportedFontToOtherOverlayElements for the same pattern with fonts).
        const resolvedBgColor = zigColorWithAlpha(bgColor, alpha255);
        patch.characterNameBgColor = resolvedBgColor;
        patch.systemNameBgColor = resolvedBgColor;
        patch.quickGroupBadgeBgColor = resolvedBgColor;
        patch.notifications = Object.assign({}, app.currentConfig.thumbnail?.notifications, { bg_color: resolvedBgColor });
    }

    const font = parseQtFont(overlay.font);
    if (font) {
        if (font.family) patch.characterNameFontName = font.family;
        if (font.size) patch.characterNameFontSize = font.size;
        applyImportedFontToOtherOverlayElements(patch, font.family || null, font.size || null);
    }

    if (num(thumb.width) !== null) patch.width = num(thumb.width);
    if (num(thumb.height) !== null) patch.height = num(thumb.height);
    if (num(thumb.opacity) !== null) patch.thumbnailOpacity = Math.max(0, Math.min(255, Math.round(num(thumb.opacity) * 2.55)));

    return { patch, notes };
}

// EVE-APM Preview's "show non-EVE windows" overlay stores arbitrary window titles in the same sections under a "<processName>.exe::<title>" key - these aren't characters and must not be imported as ones.
function isApmNonEveWindowEntry(decodedName) {
    return /\.[a-z0-9]+::/i.test(decodedName);
}

function apmExtractCharacterPositions(sections) {
    const positions = sections['thumbnailPositions'] || {};
    const characterPatches = [];
    let skipped = 0;
    Object.keys(positions).forEach(rawKey => {
        const pt = parseQtPoint(positions[rawKey]);
        if (!pt) return;
        const name = iniDecodeKey(rawKey);
        if (isApmNonEveWindowEntry(name)) { skipped++; return; }
        characterPatches.push({ name, position: pt });
    });
    const notes = [t('dynamic.import.apm.importedPositionsNote').replace('{n}', characterPatches.length)];
    if (skipped > 0) notes.push(t('dynamic.import.apm.skippedNonEveWindowNote').replace('{n}', skipped));
    return { characterPatches, notes };
}

function apmExtractCharacterColors(sections) {
    const colors = sections['characterBorderColors'] || {};
    const hotkeys = sections['characterHotkeys'] || {};
    const byName = new Map();
    let skipped = 0;

    Object.keys(colors).forEach(rawKey => {
        const color = legacyColorToZig(colors[rawKey]);
        if (!color) return;
        const name = iniDecodeKey(rawKey);
        if (isApmNonEveWindowEntry(name)) { skipped++; return; }
        const entry = byName.get(name) || { name };
        entry.borderColors = { activeBorderColor: color };
        byName.set(name, entry);
    });

    let convertedHotkeys = 0;
    const hotkeyKeys = Object.keys(hotkeys);
    hotkeyKeys.forEach(rawKey => {
        const name = iniDecodeKey(rawKey);
        if (isApmNonEveWindowEntry(name)) { skipped++; return; }
        const hex = decodeApmHotkeyTuple(iniUnquote(hotkeys[rawKey]));
        if (!hex) return;
        const entry = byName.get(name) || { name };
        entry.hotkey = hex;
        byName.set(name, entry);
        convertedHotkeys++;
    });

    const characterPatches = Array.from(byName.values());
    const notes = [t('dynamic.import.importedBorderColorsCountNote').replace('{n}', characterPatches.filter(c => c.borderColors).length)];
    if (hotkeyKeys.length > 0) {
        notes.push(t('dynamic.import.apm.convertedHotkeysDecodedNote').replace('{converted}', convertedHotkeys).replace('{total}', hotkeyKeys.length));
    }
    if (skipped > 0) notes.push(t('dynamic.import.apm.skippedNonEveWindowNote').replace('{n}', skipped));
    return { characterPatches, notes };
}

// Distinguishes "nothing was bound" from "something was bound but couldn't be converted" so the latter is never silently dropped, regardless of whether decodeApmHotkeyTuple can represent it.
function isApmHotkeyTupleEnabled(csv) {
    if (!csv) return false;
    const parts = String(csv).split(',').map(s => parseInt(s.trim(), 10));
    return parts.length >= 2 && !!parts[0] && Number.isFinite(parts[1]) && parts[1] > 0;
}

function apmExtractHotkeyGroups(sections) {
    const groups = sections['cycleGroups'] || {};
    const notes = [];
    const hotkeyGroups = [];
    Object.keys(groups).forEach(rawKey => {
        const name = iniDecodeKey(rawKey);
        const raw = iniUnquote(groups[rawKey]);
        const parts = raw.split('|');
        const characters = (parts[0] || '').split(',').map(s => s.trim()).filter(Boolean);
        const forwardRaw = parts[1];
        const backwardRaw = parts[2];
        const forwardKey = decodeApmHotkeyTuple(forwardRaw);
        const backwardKey = decodeApmHotkeyTuple(backwardRaw);
        hotkeyGroups.push({ name, characters, forwardKey, backwardKey });
        if (forwardKey || backwardKey) {
            notes.push(t('dynamic.import.apm.hotkeyGroupDecodedNote').replace('{name}', name));
        }
        if (!forwardKey && isApmHotkeyTupleEnabled(forwardRaw)) {
            notes.push(t('dynamic.import.apm.hotkeyGroupForwardUnsupportedNote').replace('{name}', name));
        }
        if (!backwardKey && isApmHotkeyTupleEnabled(backwardRaw)) {
            notes.push(t('dynamic.import.apm.hotkeyGroupBackwardUnsupportedNote').replace('{name}', name));
        }
    });
    notes.unshift(t('dynamic.import.hotkeyGroupsImportedNote').replace('{n}', hotkeyGroups.length));
    return { hotkeyGroups, notes };
}

function apmExtractGlobalHotkeys(sections) {
    const patch = {};
    const notes = [];

    // Saved as pipe-joined "enabled,keyCode,ctrl,alt,shift" tuples, same as [cycleGroups]; EVE-APM allows multiple bound keys per action, EVE-Maj Preview only stores one.
    const tryKey = (sectionName, keyName, targetField, label) => {
        const raw = (sections[sectionName] || {})[keyName];
        if (!raw || raw.trim() === '') return;
        const enabledTuples = raw.split('|').map(s => s.trim()).filter(isApmHotkeyTupleEnabled);
        if (enabledTuples.length === 0) return;
        const hex = decodeApmHotkeyTuple(enabledTuples[0]);
        if (hex) {
            patch[targetField] = hex;
        } else {
            notes.push(t('dynamic.import.apm.globalHotkeyUnsupportedNote').replace('{label}', label));
        }
        if (enabledTuples.length > 1) {
            notes.push(t('dynamic.import.apm.globalHotkeyMultipleBoundNote').replace('{label}', label).replace('{n}', enabledTuples.length));
        }
    };
    tryKey('closeAllHotkeys', 'closeAllClients', 'hotkeyCloseAll', t('dynamic.import.apm.actionLabel.closeAll'));
    tryKey('minimizeAllHotkeys', 'minimizeAllClients', 'hotkeyMinimizeAll', t('dynamic.import.apm.actionLabel.minimizeAll'));
    tryKey('toggleThumbnailsVisibilityHotkeys', 'toggleThumbnailsVisibility', 'hotkeyToggleVisibility', t('dynamic.import.apm.actionLabel.toggleVisibility'));
    tryKey('hotkeys', 'suspendHotkey', 'hotkeySuspend', t('dynamic.import.apm.actionLabel.suspend'));

    const hk = sections['hotkey'] || {};
    if ('onlyWhenEVEFocused' in hk) patch.requireEveFocus = parseQtBool(hk.onlyWhenEVEFocused);
    if ('resetGroupIndexOnNonGroupFocus' in hk) patch.resetGroupIndexOnNonGroupFocus = parseQtBool(hk.resetGroupIndexOnNonGroupFocus);

    notes.push(t('dynamic.import.apm.globalHotkeysImportedNote'));
    return { patch, notes };
}

function apmExtractAutoMinimize(sections) {
    const win = sections['window'] || {};
    const patch = {};
    if ('minimizeInactiveClients' in win) patch.enabled = parseQtBool(win.minimizeInactiveClients);
    const delay = parseInt(win.minimizeDelay, 10);
    if (Number.isFinite(delay)) patch.delayMs = delay;
    let characterPatches = [];
    if (!isQtInvalid(win.neverMinimizeCharacters)) {
        const list = iniUnquote(win.neverMinimizeCharacters).split(',').map(s => s.trim()).filter(Boolean);
        characterPatches = list.map(name => ({ name, excludeFromMinimize: true }));
    }
    return { patch, characterPatches, notes: [t('dynamic.import.autoMinimizeImportedNote')] };
}

function apmExtractSnapping(sections) {
    const pos = sections['position'] || {};
    const patch = {};
    if ('enableSnapping' in pos) patch.enabled = parseQtBool(pos.enableSnapping);
    const dist = parseInt(pos.snapDistance, 10);
    if (Number.isFinite(dist)) patch.threshold = dist;
    return { patch, notes: [t('dynamic.import.snappingImportedNote')] };
}

function apmExtractChatlog(sections) {
    const chat = sections['chatlog'] || {};
    const game = sections['gamelog'] || {};
    const patch = {};
    if ('enableMonitoring' in chat) patch.enabled = parseQtBool(chat.enableMonitoring);
    if (chat.directory) patch.chatlogDir = chat.directory.trim();
    if (game.directory) patch.gamelogDir = game.directory.trim();
    return { patch, notes: [t('dynamic.import.apm.chatlogImportedNote')] };
}

// "mining_started" has no equivalent notification type here and is intentionally unmapped.
const APM_EVENT_TYPE_MAP = {
    fleet_invite: 'FleetInvite',
    follow_warp: 'FleetFollow',
    regroup: 'FleetRegroup',
    compression: 'MiningCompression',
    decloak: 'Decloak',
    mining_stopped: 'MiningStopped',
};

function apmExtractNotifications(sections) {
    const cm = sections['combatMessages'] || {};
    const notificationsPatch = {};
    const typePatches = {};
    const notes = [];

    if ('enabled' in cm) notificationsPatch.enabled = parseQtBool(cm.enabled);

    const enabledList = (cm.enabledEventTypes || '').split(',').map(s => s.trim()).filter(Boolean);
    const defaultDuration = parseInt(cm.duration, 10);
    const color = legacyColorToZig(cm.color);
    let mapped = 0;

    enabledList.forEach(evt => {
        const target = APM_EVENT_TYPE_MAP[evt];
        if (!target) {
            notes.push(t('dynamic.import.apm.eventTypeUnsupportedNote').replace('{evt}', evt));
            return;
        }
        const dur = parseInt(cm[`eventDurations\\${evt}`], 10);
        const typePatch = { enabled: true };
        typePatch.duration_ms = Number.isFinite(dur) ? dur : (Number.isFinite(defaultDuration) ? defaultDuration : undefined);
        if (color) typePatch.border_color = color;
        typePatches[target] = typePatch;
        mapped++;
    });

    if (enabledList.length > 0) notes.push(t('dynamic.import.apm.notificationTypesImportedNote').replace('{mapped}', mapped).replace('{total}', enabledList.length));
    return { notificationsPatch, typePatches, notes };
}

// EVE-O Preview writes a single flat settings object - no distinguishing wrapper key, so sniff a couple of its always-present field names as a signature.
function isEveoConfigData(data) {
    if (!data || typeof data !== 'object') return false;
    return Array.isArray(data.CycleGroup1ForwardHotkeys) ||
        typeof data.FlatLayout === 'object' ||
        typeof data.DisableThumbnail === 'object';
}

// Keyed by the EVE client window title ("EVE - CharName"), not the bare name - strip the prefix to match this app's character names.
function eveoExtractCharacterName(title) {
    const prefix = 'EVE - ';
    const t = String(title || '');
    return t.startsWith(prefix) ? t.slice(prefix.length).trim() : t.trim();
}

// EVE-O Preview's default config ships placeholder client entries mixed into the same maps as real data (no separate wrapper to skip), so they must be filtered out by name.
function isEveoPlaceholderClient(name) {
    const n = (name || '').trim();
    if (n === '' || n.toLowerCase() === 'eve') return true;
    if (/example/i.test(n)) return true;
    if (/^cycle group \d+$/i.test(n)) return true;
    return false;
}

function eveoNonPlaceholderKeys(map) {
    return Object.keys(map || {}).filter(k => !isEveoPlaceholderClient(eveoExtractCharacterName(k)));
}

// .NET's named-color set is the standard CSS3/X11 extended color-keyword table.
const EVEO_NAMED_COLORS = {
    aliceblue: 'F0F8FF', antiquewhite: 'FAEBD7', aqua: '00FFFF', aquamarine: '7FFFD4', azure: 'F0FFFF',
    beige: 'F5F5DC', bisque: 'FFE4C4', black: '000000', blanchedalmond: 'FFEBCD', blue: '0000FF',
    blueviolet: '8A2BE2', brown: 'A52A2A', burlywood: 'DEB887', cadetblue: '5F9EA0', chartreuse: '7FFF00',
    chocolate: 'D2691E', coral: 'FF7F50', cornflowerblue: '6495ED', cornsilk: 'FFF8DC', crimson: 'DC143C',
    cyan: '00FFFF', darkblue: '00008B', darkcyan: '008B8B', darkgoldenrod: 'B8860B', darkgray: 'A9A9A9',
    darkgreen: '006400', darkgrey: 'A9A9A9', darkkhaki: 'BDB76B', darkmagenta: '8B008B', darkolivegreen: '556B2F',
    darkorange: 'FF8C00', darkorchid: '9932CC', darkred: '8B0000', darksalmon: 'E9967A', darkseagreen: '8FBC8F',
    darkslateblue: '483D8B', darkslategray: '2F4F4F', darkslategrey: '2F4F4F', darkturquoise: '00CED1', darkviolet: '9400D3',
    deeppink: 'FF1493', deepskyblue: '00BFFF', dimgray: '696969', dimgrey: '696969', dodgerblue: '1E90FF',
    firebrick: 'B22222', floralwhite: 'FFFAF0', forestgreen: '228B22', fuchsia: 'FF00FF', gainsboro: 'DCDCDC',
    ghostwhite: 'F8F8FF', gold: 'FFD700', goldenrod: 'DAA520', gray: '808080', grey: '808080',
    green: '008000', greenyellow: 'ADFF2F', honeydew: 'F0FFF0', hotpink: 'FF69B4', indianred: 'CD5C5C',
    indigo: '4B0082', ivory: 'FFFFF0', khaki: 'F0E68C', lavender: 'E6E6FA', lavenderblush: 'FFF0F5',
    lawngreen: '7CFC00', lemonchiffon: 'FFFACD', lightblue: 'ADD8E6', lightcoral: 'F08080', lightcyan: 'E0FFFF',
    lightgoldenrodyellow: 'FAFAD2', lightgray: 'D3D3D3', lightgreen: '90EE90', lightgrey: 'D3D3D3', lightpink: 'FFB6C1',
    lightsalmon: 'FFA07A', lightseagreen: '20B2AA', lightskyblue: '87CEFA', lightslategray: '778899', lightslategrey: '778899',
    lightsteelblue: 'B0C4DE', lightyellow: 'FFFFE0', lime: '00FF00', limegreen: '32CD32', linen: 'FAF0E6',
    magenta: 'FF00FF', maroon: '800000', mediumaquamarine: '66CDAA', mediumblue: '0000CD', mediumorchid: 'BA55D3',
    mediumpurple: '9370DB', mediumseagreen: '3CB371', mediumslateblue: '7B68EE', mediumspringgreen: '00FA9A', mediumturquoise: '48D1CC',
    mediumvioletred: 'C71585', midnightblue: '191970', mintcream: 'F5FFFA', mistyrose: 'FFE4E1', moccasin: 'FFE4B5',
    navajowhite: 'FFDEAD', navy: '000080', oldlace: 'FDF5E6', olive: '808000', olivedrab: '6B8E23',
    orange: 'FFA500', orangered: 'FF4500', orchid: 'DA70D6', palegoldenrod: 'EEE8AA', palegreen: '98FB98',
    paleturquoise: 'AFEEEE', palevioletred: 'DB7093', papayawhip: 'FFEFD5', peachpuff: 'FFDAB9', peru: 'CD853F',
    pink: 'FFC0CB', plum: 'DDA0DD', powderblue: 'B0E0E6', purple: '800080', rebeccapurple: '663399',
    red: 'FF0000', rosybrown: 'BC8F8F', royalblue: '4169E1', saddlebrown: '8B4513', salmon: 'FA8072',
    sandybrown: 'F4A460', seagreen: '2E8B57', seashell: 'FFF5EE', sienna: 'A0522D', silver: 'C0C0C0',
    skyblue: '87CEEB', slateblue: '6A5ACD', slategray: '708090', slategrey: '708090', snow: 'FFFAFA',
    springgreen: '00FF7F', steelblue: '4682B4', tan: 'D2B48C', teal: '008080', thistle: 'D8BFD8',
    tomato: 'FF6347', turquoise: '40E0D0', violet: 'EE82EE', wheat: 'F5DEB3', white: 'FFFFFF',
    whitesmoke: 'F5F5F5', yellow: 'FFFF00', yellowgreen: '9ACD32',
};

// EVE-O Preview colors are either a "#RRGGBB"/"#AARRGGBB" hex string or a .NET named color.
function eveoColorToZig(str) {
    if (!str || typeof str !== 'string') return null;
    const s = str.trim();
    if (s.startsWith('#')) return legacyColorToZig(s);
    const hex = EVEO_NAMED_COLORS[s.toLowerCase()];
    return hex ? '0xFF' + hex : null;
}

// WinForms' Size/Point TypeConverters serialize as "W, H" / "X, Y".
function eveoParsePair(str) {
    if (!str || typeof str !== 'string') return null;
    const parts = str.split(/[,\s]+/).map(s => s.trim()).filter(Boolean);
    if (parts.length < 2) return null;
    const a = parseInt(parts[0], 10);
    const b = parseInt(parts[1], 10);
    if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
    return { a, b };
}

// WinForms' Keys enum names the digit row "D0".."D9" and has dedicated "LWin"/"RWin" members - extend legacyBaseKeyToVk for those before falling back to it.
function eveoBaseKeyToVk(token) {
    const t = token.trim();
    const d = /^D([0-9])$/i.exec(t);
    if (d) return 0x30 + parseInt(d[1], 10);
    const lower = t.toLowerCase();
    if (lower === 'lwin') return 0x5B;
    if (lower === 'rwin') return 0x5C;
    return legacyBaseKeyToVk(t);
}

// Serialized via KeysConverter.ConvertToInvariantString(), joining modifier names and the base key with '+' (e.g. "Control+F14"); no Windows-key modifier exists in WinForms' Keys flags.
const EVEO_MOD_WORDS = { control: 0x02, alt: 0x01, shift: 0x04 };

function eveoHotkeyToVkHex(rawStr) {
    if (!rawStr || typeof rawStr !== 'string') return null;
    const str = rawStr.trim();
    if (str.length === 0) return null;

    const tokens = str.split('+').map(t => t.trim()).filter(Boolean);
    if (tokens.length === 0) return null;

    let mods = 0;
    for (let i = 0; i < tokens.length - 1; i++) {
        const word = tokens[i].toLowerCase();
        if (!Object.prototype.hasOwnProperty.call(EVEO_MOD_WORDS, word)) return null;
        mods |= EVEO_MOD_WORDS[word];
    }

    const vk = eveoBaseKeyToVk(tokens[tokens.length - 1]);
    if (vk === null) return null;

    const combined = (vk & 0xFF) | ((mods & 0x0F) << 8);
    return '0x' + combined.toString(16).toUpperCase();
}

// EVE-O Preview allows multiple bound keys per action; EVE-Maj Preview only stores one.
function eveoFirstConvertibleHotkey(list) {
    for (const raw of (list || [])) {
        if (!raw || raw.trim() === '') continue;
        const hex = eveoHotkeyToVkHex(raw);
        if (hex) return hex;
    }
    return null;
}

// Ordered the same way EVE-O Preview cycles through them (by their ClientsOrder index).
function eveoCycleGroupCharacters(data, n) {
    const order = data[`CycleGroup${n}ClientsOrder`] || {};
    return Object.keys(order)
        .map(k => ({ name: eveoExtractCharacterName(k), order: order[k] }))
        .filter(e => !isEveoPlaceholderClient(e.name))
        .sort((a, b) => a.order - b.order)
        .map(e => e.name);
}

function computeEveoImportSections(data) {
    const hasThumbAppearance = ('ThumbnailsOpacity' in data) || ('ActiveClientHighlightColor' in data) ||
        ('OverlayLabelColor' in data) || ('ThumbnailSize' in data);

    const flatLayout = data.FlatLayout || {};
    const sizes = data.PerClientThumbnailSize || {};
    const disabled = data.DisableThumbnail || {};
    const positionKeys = new Set([...eveoNonPlaceholderKeys(flatLayout), ...eveoNonPlaceholderKeys(sizes), ...eveoNonPlaceholderKeys(disabled)]);
    const hasPositions = positionKeys.size > 0;

    const colors = data.PerClientActiveClientHighlightColor || {};
    const clientHotkeys = data.ClientHotkey || {};
    const colorKeys = eveoNonPlaceholderKeys(colors);
    const hotkeyKeys = eveoNonPlaceholderKeys(clientHotkeys);
    const hasColors = colorKeys.length > 0 || hotkeyKeys.length > 0;

    const groupCount = [1, 2, 3, 4, 5].filter(n => eveoCycleGroupCharacters(data, n).length > 0).length;
    const hasGroups = groupCount > 0;

    const hasAutoMinimize = 'MinimizeInactiveClients' in data;
    const hasSnapping = 'EnableThumbnailSnap' in data;

    return [
        { id: 'thumbnailAppearance', title: t('dynamic.import.eveo.thumbnailAppearance.title'), hint: t('dynamic.import.eveo.thumbnailAppearance.hint'), available: hasThumbAppearance },
        { id: 'characterPositions', title: t('dynamic.import.eveo.characterPositions.title'), hint: t('dynamic.import.characterPositionsHint').replace('{n}', positionKeys.size), available: hasPositions },
        { id: 'characterColors', title: t('dynamic.import.eveo.characterColors.title'), hint: t('dynamic.import.characterColorsHotkeysHint').replace('{colors}', colorKeys.length).replace('{hotkeys}', hotkeyKeys.length), available: hasColors },
        { id: 'hotkeyGroups', title: t('dynamic.import.eveo.hotkeyGroups.title'), hint: t('dynamic.import.hotkeyGroupsCountHint').replace('{n}', groupCount), available: hasGroups },
        { id: 'autoMinimize', title: t('dynamic.import.eveo.autoMinimize.title'), hint: t('dynamic.import.eveo.autoMinimize.hint'), available: hasAutoMinimize },
        { id: 'snapping', title: t('dynamic.import.eveo.snapping.title'), hint: t('dynamic.import.eveo.snapping.hint'), available: hasSnapping },
    ];
}

function eveoExtractThumbnailAppearance(data) {
    const patch = {};
    const notes = [t('dynamic.import.thumbnailAppearanceImportedNote')];

    if (typeof data.ThumbnailsOpacity === 'number') {
        patch.thumbnailOpacity = Math.max(0, Math.min(255, Math.round(data.ThumbnailsOpacity * 255)));
    }
    if ('EnableActiveClientHighlight' in data) patch.showBorderWhenFocused = !!data.EnableActiveClientHighlight;
    if (data.ActiveClientHighlightColor) {
        const borderColor = eveoColorToZig(data.ActiveClientHighlightColor);
        if (borderColor) patch.borderColor = borderColor;
        else notes.push(t('dynamic.import.eveo.activeColorUnrecognizedNote').replace('{color}', data.ActiveClientHighlightColor));
    }
    if (typeof data.ActiveClientHighlightThickness === 'number') patch.borderWidth = data.ActiveClientHighlightThickness;

    // EVE-O Preview has one "show borders on all thumbnails" toggle rather than separate active/inactive settings - maps to showBorderWhenInactive.
    if ('ShowThumbnailFrames' in data) patch.showBorderWhenInactive = !!data.ShowThumbnailFrames;
    if ('ShowThumbnailOverlays' in data) patch.showText = !!data.ShowThumbnailOverlays;

    if (data.OverlayLabelColor) {
        const textColor = eveoColorToZig(data.OverlayLabelColor);
        if (textColor) patch.characterNameColor = textColor;
        else notes.push(t('dynamic.import.eveo.labelColorUnrecognizedNote').replace('{color}', data.OverlayLabelColor));
    }
    if (typeof data.OverlayLabelSize === 'number') {
        patch.characterNameFontSize = data.OverlayLabelSize;
        applyImportedFontToOtherOverlayElements(patch, null, data.OverlayLabelSize);
    }
    if (typeof data.OverlayLabelAnchor === 'number') {
        // EVE-O Preview's ZoomAnchor enum is the same 3x3 grid/order as TextPosition, so APM_POSITION_MAP is reused here.
        const pos = APM_POSITION_MAP[data.OverlayLabelAnchor];
        if (pos) patch.characterNamePosition = pos;
    }

    if ('HideThumbnailsOnLostFocus' in data) patch.hideWhenNoEveFocus = !!data.HideThumbnailsOnLostFocus;
    if ('HideActiveClientThumbnail' in data) patch.activeThumbnailHidden = !!data.HideActiveClientThumbnail;

    const size = eveoParsePair(data.ThumbnailSize);
    if (size) {
        patch.width = size.a;
        patch.height = size.b;
    }

    return { patch, notes };
}

function eveoExtractCharacterPositions(data) {
    const flatLayout = data.FlatLayout || {};
    const sizes = data.PerClientThumbnailSize || {};
    const disabled = data.DisableThumbnail || {};
    const byName = new Map();
    const skippedNames = new Set();

    Object.keys(flatLayout).forEach(rawKey => {
        const name = eveoExtractCharacterName(rawKey);
        if (isEveoPlaceholderClient(name)) { skippedNames.add(name); return; }
        const pt = eveoParsePair(flatLayout[rawKey]);
        if (!pt) return;
        byName.set(name, { name, position: { x: pt.a, y: pt.b } });
    });

    Object.keys(sizes).forEach(rawKey => {
        const name = eveoExtractCharacterName(rawKey);
        if (isEveoPlaceholderClient(name)) { skippedNames.add(name); return; }
        const sz = eveoParsePair(sizes[rawKey]);
        if (!sz) return;
        const entry = byName.get(name) || { name };
        entry.thumbnailSize = { width: sz.a, height: sz.b };
        byName.set(name, entry);
    });

    Object.keys(disabled).forEach(rawKey => {
        const name = eveoExtractCharacterName(rawKey);
        if (isEveoPlaceholderClient(name)) { skippedNames.add(name); return; }
        if (!disabled[rawKey]) return;
        const entry = byName.get(name) || { name };
        entry.hideThumbnail = true;
        byName.set(name, entry);
    });

    const characterPatches = Array.from(byName.values());
    const notes = [t('dynamic.import.importedPositionsWithSizeNote').replace('{n}', characterPatches.length)];
    if (skippedNames.size > 0) notes.push(t('dynamic.import.eveo.skippedPlaceholderNote').replace('{n}', skippedNames.size));
    return { characterPatches, notes };
}

function eveoExtractCharacterColors(data) {
    const colors = data.PerClientActiveClientHighlightColor || {};
    const hotkeys = data.ClientHotkey || {};
    const byName = new Map();
    const skippedNames = new Set();
    let colorCount = 0;
    let convertedHotkeys = 0;

    Object.keys(colors).forEach(rawKey => {
        const name = eveoExtractCharacterName(rawKey);
        if (isEveoPlaceholderClient(name)) { skippedNames.add(name); return; }
        const color = eveoColorToZig(colors[rawKey]);
        if (!color) return;
        const entry = byName.get(name) || { name };
        entry.borderColors = { activeBorderColor: color };
        byName.set(name, entry);
        colorCount++;
    });

    const hotkeyKeys = Object.keys(hotkeys);
    hotkeyKeys.forEach(rawKey => {
        const name = eveoExtractCharacterName(rawKey);
        if (isEveoPlaceholderClient(name)) { skippedNames.add(name); return; }
        const hex = eveoHotkeyToVkHex(hotkeys[rawKey]);
        if (!hex) return;
        const entry = byName.get(name) || { name };
        entry.hotkey = hex;
        byName.set(name, entry);
        convertedHotkeys++;
    });

    const characterPatches = Array.from(byName.values());
    const notes = [t('dynamic.import.importedBorderColorsCountNote').replace('{n}', colorCount)];
    if (hotkeyKeys.length > 0) notes.push(t('dynamic.import.convertedHotkeysNote').replace('{converted}', convertedHotkeys).replace('{total}', hotkeyKeys.length));
    if (skippedNames.size > 0) notes.push(t('dynamic.import.eveo.skippedPlaceholderNote').replace('{n}', skippedNames.size));
    return { characterPatches, notes };
}

function eveoExtractHotkeyGroups(data) {
    const notes = [];
    const hotkeyGroups = [];

    [1, 2, 3, 4, 5].forEach(n => {
        const characters = eveoCycleGroupCharacters(data, n);
        if (characters.length === 0) return;

        const forwardList = Array.isArray(data[`CycleGroup${n}ForwardHotkeys`]) ? data[`CycleGroup${n}ForwardHotkeys`] : [];
        const backwardList = Array.isArray(data[`CycleGroup${n}BackwardHotkeys`]) ? data[`CycleGroup${n}BackwardHotkeys`] : [];
        const forwardBound = forwardList.filter(s => s && s.trim() !== '');
        const backwardBound = backwardList.filter(s => s && s.trim() !== '');

        const forwardKey = eveoFirstConvertibleHotkey(forwardBound);
        const backwardKey = eveoFirstConvertibleHotkey(backwardBound);
        const name = t('dynamic.import.eveo.cycleGroupName').replace('{n}', n);
        hotkeyGroups.push({ name, characters, forwardKey, backwardKey });

        if (forwardBound.length > 0 && !forwardKey) notes.push(t('dynamic.import.hotkeyGroupForwardKeyFailedNote').replace('{name}', name).replace('{key}', forwardBound[0]));
        if (backwardBound.length > 0 && !backwardKey) notes.push(t('dynamic.import.hotkeyGroupBackwardKeyFailedNote').replace('{name}', name).replace('{key}', backwardBound[0]));
        if (forwardBound.length > 1 || backwardBound.length > 1) {
            notes.push(t('dynamic.import.eveo.hotkeyGroupMultipleBoundNote').replace('{name}', name));
        }
    });

    notes.unshift(t('dynamic.import.hotkeyGroupsImportedNote').replace('{n}', hotkeyGroups.length));
    return { hotkeyGroups, notes };
}

function eveoExtractAutoMinimize(data) {
    const patch = {};
    if ('MinimizeInactiveClients' in data) patch.enabled = !!data.MinimizeInactiveClients;
    return { patch, notes: [t('dynamic.import.autoMinimizeImportedNote')] };
}

function eveoExtractSnapping(data) {
    const snappingPatch = {};
    if ('EnableThumbnailSnap' in data) snappingPatch.enabled = !!data.EnableThumbnailSnap;
    return { snappingPatch, notes: [t('dynamic.import.snappingImportedNote')] };
}

// Unlike the legacy formats above, a maj-format file already has exactly currentConfig's shape, so no field-by-field translation is needed, just a per-section merge.
// Stores i18n key names rather than t()-resolved text, so the section list follows a language switch.
const MAJ_SECTIONS = [
    { id: 'thumbnail', titleKey: 'dynamic.import.maj.thumbnail.title', hintKey: 'dynamic.import.maj.thumbnail.hint', kind: 'object' },
    { id: 'display', titleKey: 'dynamic.import.maj.display.title', hintKey: 'dynamic.import.maj.display.hint', kind: 'object' },
    { id: 'timer', titleKey: 'dynamic.import.maj.timer.title', hintKey: 'dynamic.import.maj.timer.hint', kind: 'object' },
    { id: 'interaction', titleKey: 'dynamic.import.maj.interaction.title', hintKey: 'dynamic.import.maj.interaction.hint', kind: 'object' },
    { id: 'snapping', titleKey: 'dynamic.import.maj.snapping.title', hintKey: 'dynamic.import.maj.snapping.hint', kind: 'object' },
    { id: 'autoMinimize', titleKey: 'dynamic.import.maj.autoMinimize.title', hintKey: 'dynamic.import.maj.autoMinimize.hint', kind: 'object' },
    { id: 'closeAll', titleKey: 'dynamic.import.maj.closeAll.title', hintKey: 'dynamic.import.maj.closeAll.hint', kind: 'object' },
    { id: 'chatlog', titleKey: 'dynamic.import.maj.chatlog.title', hintKey: 'dynamic.import.maj.chatlog.hint', kind: 'object' },
    { id: 'combat', titleKey: 'dynamic.import.maj.combat.title', hintKey: 'dynamic.import.maj.combat.hint', kind: 'object' },
    { id: 'mining', titleKey: 'dynamic.import.maj.mining.title', hintKey: 'dynamic.import.maj.mining.hint', kind: 'object' },
    { id: 'bounty', titleKey: 'dynamic.import.maj.bounty.title', hintKey: 'dynamic.import.maj.bounty.hint', kind: 'object' },
    { id: 'resources', titleKey: 'dynamic.import.maj.resources.title', hintKey: 'dynamic.import.maj.resources.hint', kind: 'object' },
    { id: 'hotkeys', titleKey: 'dynamic.import.maj.hotkeys.title', hintKey: 'dynamic.import.maj.hotkeys.hint', kind: 'object' },
    { id: 'characters', titleKey: 'dynamic.import.maj.characters.title', hintKey: 'dynamic.import.maj.characters.hint', kind: 'array' },
    { id: 'systemColors', titleKey: 'dynamic.import.maj.systemColors.title', hintKey: 'dynamic.import.maj.systemColors.hint', kind: 'array' },
    { id: 'hotkeyGroups', titleKey: 'dynamic.import.maj.hotkeyGroups.title', hintKey: 'dynamic.import.maj.hotkeyGroups.hint', kind: 'array' },
    { id: 'windowFilters', titleKey: 'dynamic.import.maj.windowFilters.title', hintKey: 'dynamic.import.maj.windowFilters.hint', kind: 'array' },
];

function computeMajImportSections(data) {
    return MAJ_SECTIONS.map(s => {
        const title = t(s.titleKey);
        const hint = t(s.hintKey);
        if (s.kind === 'array') {
            const arr = Array.isArray(data[s.id]) ? data[s.id] : [];
            return { id: s.id, title, hint: `${hint} (${arr.length})`, available: arr.length > 0 };
        }
        return { id: s.id, title, hint, available: data[s.id] !== undefined && data[s.id] !== null };
    });
}

// Legacy tools (EVE-O/EVE-X/EVE-APM, and this app before its DPI-awareness change) captured positions while DPI-unaware, in a virtualized 96-DPI space Windows silently rescaled - scaleLegacyPositions (dialog/api/background.zig) converts them to real physical pixels via the current monitor's DPI.
async function scaleCharacterPatchPositions(characterPatches) {
    if (typeof webui === 'undefined') return;
    const withPos = characterPatches.filter(cp => cp.position);
    if (withPos.length === 0) return;
    try {
        const scaled = await rpc('scaleLegacyPositions', { positions: withPos.map(cp => cp.position) });
        withPos.forEach((cp, i) => { if (scaled[i]) cp.position = scaled[i]; });
    } catch (error) {
        logWarn('Failed to scale legacy positions:', error);
    }
}

// Merges by name/systemName so re-running an import updates matching entries in place instead of duplicating them; unlike mergeCharacterPatch, imported items are already full entries so this overwrites wholesale.
function mergeMajByKey(list, imported, keyField) {
    removeUnnamedPlaceholders(list, imported, keyField);
    imported.forEach(item => {
        const key = (item[keyField] || '').trim();
        if (!key) return;
        const idx = list.findIndex(x => (x[keyField] || '').trim().toLowerCase() === key.toLowerCase());
        if (idx === -1) list.push(item);
        else list[idx] = Object.assign({}, list[idx], item);
    });
}

async function applyMajImport(checked, allNotes) {
    const data = importParsedData;

    MAJ_SECTIONS.filter(s => s.kind === 'object').forEach(s => {
        if (!checked(s.id) || !data[s.id]) return;
        app.currentConfig[s.id] = Object.assign({}, app.currentConfig[s.id], data[s.id]);
        allNotes.push(t('dynamic.import.maj.sectionImportedNote').replace('{title}', t(s.titleKey)));
    });

    if (checked('characters') && Array.isArray(data.characters)) {
        if (!app.currentConfig.characters) app.currentConfig.characters = [];
        // formatVersion < 2 predates this app's DPI-awareness change - those saved positions need the same physical-pixel conversion as EVE-O/EVE-X/EVE-APM imports.
        if ((data.formatVersion || 1) < 2) await scaleCharacterPatchPositions(data.characters);
        mergeMajByKey(app.currentConfig.characters, data.characters, 'name');
        allNotes.push(t('dynamic.import.maj.charactersImportedNote').replace('{n}', data.characters.length));
    }
    if (checked('systemColors') && Array.isArray(data.systemColors)) {
        if (!app.currentConfig.systemColors) app.currentConfig.systemColors = [];
        mergeMajByKey(app.currentConfig.systemColors, data.systemColors, 'systemName');
        allNotes.push(t('dynamic.import.maj.systemColorsImportedNote').replace('{n}', data.systemColors.length));
    }
    if (checked('hotkeyGroups') && Array.isArray(data.hotkeyGroups)) {
        if (!app.currentConfig.hotkeyGroups) app.currentConfig.hotkeyGroups = [];
        mergeMajByKey(app.currentConfig.hotkeyGroups, data.hotkeyGroups, 'name');
        allNotes.push(t('dynamic.import.hotkeyGroupsImportedNote').replace('{n}', data.hotkeyGroups.length));
    }
    if (checked('windowFilters') && Array.isArray(data.windowFilters)) {
        if (!app.currentConfig.windowFilters) app.currentConfig.windowFilters = [];
        mergeMajByKey(app.currentConfig.windowFilters, data.windowFilters, 'name');
        allNotes.push(t('dynamic.import.maj.windowFiltersImportedNote').replace('{n}', data.windowFilters.length));
    }
}

export function openImportModal() {
    importParsedData = null;
    importFormat = null;

    const fileInput = document.getElementById('importFileInput');
    if (fileInput) fileInput.value = '';
    document.getElementById('importFileStatus').textContent = '';
    document.getElementById('import-step-file').style.display = '';
    document.getElementById('import-step-options').style.display = 'none';
    document.getElementById('importSummary').style.display = 'none';
    document.getElementById('importSummary').innerHTML = '';

    const runBtn = document.getElementById('import-modal-run');
    runBtn.style.display = '';
    runBtn.disabled = true;
    document.getElementById('import-modal-cancel').textContent = t('common.cancel');

    document.getElementById('import-dest-current').checked = true;
    onImportDestChanged();

    loadImportBackupsList();

    const modal = document.getElementById('import-settings-modal');
    modal.classList.add('show');
}

export function closeImportModal() {
    const modal = document.getElementById('import-settings-modal');
    modal.classList.remove('show');
    applyAccentColorTheme();
}

export async function handleImportFileSelected(event) {
    const file = event.target.files && event.target.files[0];
    const statusEl = document.getElementById('importFileStatus');
    const optionsStep = document.getElementById('import-step-options');
    const runBtn = document.getElementById('import-modal-run');

    optionsStep.style.display = 'none';
    runBtn.disabled = true;
    importParsedData = null;
    importFormat = null;

    if (!file) {
        statusEl.textContent = '';
        return;
    }

    statusEl.textContent = t('status.readingFile');

    try {
        const text = await file.text();

        let data = null;
        try { data = JSON.parse(text); } catch (_) { data = null; }

        if (data && data.app === MAJ_FORMAT_IDENTIFIER) {
            importFormat = 'maj';
            importParsedData = data;

            document.getElementById('importSourceProfileRow').style.display = 'none';
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);
            document.getElementById('importNewProfileName').value = defaultName || 'Imported';

            statusEl.textContent = t('status.detectedMajFile');
        } else if (data && typeof data._Profiles === 'object' && data._Profiles !== null) {
            importFormat = 'evex';
            importParsedData = data;

            const profileNames = Object.keys(data._Profiles);
            const select = document.getElementById('importSourceProfile');
            select.innerHTML = '';
            profileNames.forEach(name => {
                const opt = document.createElement('option');
                opt.value = name;
                opt.textContent = name;
                select.appendChild(opt);
            });

            const lastUsed = data.global_Settings && data.global_Settings.LastUsedProfile;
            if (lastUsed && profileNames.includes(lastUsed)) select.value = lastUsed;

            document.getElementById('importSourceProfileRow').style.display = profileNames.length > 1 ? '' : 'none';
            document.getElementById('importNewProfileName').value = (profileNames[0] || 'Imported').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);

            statusEl.textContent = t('status.detectedEvexFile').replace('{n}', profileNames.length);
        } else if (data && isEveoConfigData(data)) {
            importFormat = 'eveo';
            importParsedData = data;

            document.getElementById('importSourceProfileRow').style.display = 'none';
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);
            document.getElementById('importNewProfileName').value = defaultName || 'Imported';

            statusEl.textContent = t('status.detectedEveoFile');
        } else {
            const sections = parseIniText(text);
            if (Object.keys(sections).length === 0) {
                statusEl.textContent = t('status.unrecognizedSettingsFile');
                return;
            }

            importFormat = 'apm';
            importParsedData = sections;

            document.getElementById('importSourceProfileRow').style.display = 'none';
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);
            document.getElementById('importNewProfileName').value = defaultName || 'Imported';

            statusEl.textContent = t('status.detectedApmFile');
        }

        renderImportSections();
        optionsStep.style.display = '';
        runBtn.disabled = false;
        onImportDestChanged();
    } catch (err) {
        logError('Failed to parse legacy settings file:', err);
        importParsedData = null;
        importFormat = null;
        statusEl.textContent = t('status.readParseFailedPrefix') + err.message;
    }
}

export function onImportSourceProfileChanged() {
    if (importFormat !== 'evex' || !importParsedData) return;
    const select = document.getElementById('importSourceProfile');
    const profileName = select.value;

    const nameInput = document.getElementById('importNewProfileName');
    nameInput.value = profileName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);

    renderImportSections();
}

export function onImportDestChanged() {
    const isNew = document.getElementById('import-dest-new').checked;
    document.getElementById('importNewProfileRow').style.display = isNew ? '' : 'none';
    if (isNew) {
        document.getElementById('importAccentColor').value = DEFAULT_ACCENT_COLOR_HTML;
        applyAccentColorTheme(htmlColorToZig(DEFAULT_ACCENT_COLOR_HTML));
    } else {
        applyAccentColorTheme();
    }

    const profileSelect = document.getElementById('profile-select');
    const currentLabel = document.getElementById('importDestCurrentLabel');
    if (currentLabel && profileSelect && profileSelect.value) {
        currentLabel.textContent = t('status.currentProfilePrefix') + profileSelect.value.replace(/\.json$/, '') + ')';
    }
}

async function applyEvexImport(checked, allNotes) {
    const select = document.getElementById('importSourceProfile');
    const oldProfile = importParsedData._Profiles[select.value] || {};
    const oldGlobal = importParsedData.global_Settings || {};

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = extractThumbnailAppearance(oldProfile, oldGlobal);
        app.currentConfig.thumbnail = Object.assign({}, app.currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = extractCharacterPositions(oldProfile);
        await scaleCharacterPatchPositions(characterPatches);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColorsHotkeys')) {
        const { characterPatches, notes } = extractCharacterColorsAndHotkeys(oldProfile);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = extractHotkeyGroups(oldProfile);
        if (!app.currentConfig.hotkeyGroups) app.currentConfig.hotkeyGroups = [];
        mergeMajByKey(app.currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, characterPatches, notes } = extractAutoMinimize(oldProfile, oldGlobal);
        app.currentConfig.autoMinimize = Object.assign({}, app.currentConfig.autoMinimize, patch);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { snappingPatch, hotkeysPatch, notes } = extractSnapping(oldProfile, oldGlobal);
        app.currentConfig.snapping = Object.assign({}, app.currentConfig.snapping, snappingPatch);
        app.currentConfig.hotkeys = Object.assign({}, app.currentConfig.hotkeys, hotkeysPatch);
        allNotes.push(...notes);
    }
    if (checked('globalHotkeys')) {
        const { hotkeysPatch, interactionPatch, notes } = extractEvexGlobalHotkeys(oldGlobal);
        app.currentConfig.hotkeys = Object.assign({}, app.currentConfig.hotkeys, hotkeysPatch);
        app.currentConfig.interaction = Object.assign({}, app.currentConfig.interaction, interactionPatch);
        allNotes.push(...notes);
    }
    if (checked('chatlog')) {
        const { patch, notes } = extractEvexChatlog(oldGlobal);
        app.currentConfig.chatlog = Object.assign({}, app.currentConfig.chatlog, patch);
        allNotes.push(...notes);
    }
}

async function applyApmImport(checked, allNotes) {
    const sections = importParsedData;

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = apmExtractThumbnailAppearance(sections);
        app.currentConfig.thumbnail = Object.assign({}, app.currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = apmExtractCharacterPositions(sections);
        await scaleCharacterPatchPositions(characterPatches);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColors')) {
        const { characterPatches, notes } = apmExtractCharacterColors(sections);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = apmExtractHotkeyGroups(sections);
        if (!app.currentConfig.hotkeyGroups) app.currentConfig.hotkeyGroups = [];
        mergeMajByKey(app.currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('globalHotkeys')) {
        const { patch, notes } = apmExtractGlobalHotkeys(sections);
        app.currentConfig.hotkeys = Object.assign({}, app.currentConfig.hotkeys, patch);
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, characterPatches, notes } = apmExtractAutoMinimize(sections);
        app.currentConfig.autoMinimize = Object.assign({}, app.currentConfig.autoMinimize, patch);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { patch, notes } = apmExtractSnapping(sections);
        app.currentConfig.snapping = Object.assign({}, app.currentConfig.snapping, patch);
        allNotes.push(...notes);
    }
    if (checked('chatlog')) {
        const { patch, notes } = apmExtractChatlog(sections);
        app.currentConfig.chatlog = Object.assign({}, app.currentConfig.chatlog, patch);
        allNotes.push(...notes);
    }
    if (checked('notifications')) {
        const { notificationsPatch, typePatches, notes } = apmExtractNotifications(sections);
        if (!app.currentConfig.thumbnail.notifications) app.currentConfig.thumbnail.notifications = {};
        if (!app.currentConfig.thumbnail.notifications.type_configs) app.currentConfig.thumbnail.notifications.type_configs = {};
        Object.assign(app.currentConfig.thumbnail.notifications, notificationsPatch);
        Object.keys(typePatches).forEach(type => {
            app.currentConfig.thumbnail.notifications.type_configs[type] = Object.assign(
                {}, app.currentConfig.thumbnail.notifications.type_configs[type], typePatches[type]
            );
        });
        allNotes.push(...notes);
    }
}

async function applyEveoImport(checked, allNotes) {
    const data = importParsedData;

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = eveoExtractThumbnailAppearance(data);
        app.currentConfig.thumbnail = Object.assign({}, app.currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = eveoExtractCharacterPositions(data);
        await scaleCharacterPatchPositions(characterPatches);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColors')) {
        const { characterPatches, notes } = eveoExtractCharacterColors(data);
        mergeCharacterPatch(app.currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = eveoExtractHotkeyGroups(data);
        if (!app.currentConfig.hotkeyGroups) app.currentConfig.hotkeyGroups = [];
        mergeMajByKey(app.currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, notes } = eveoExtractAutoMinimize(data);
        app.currentConfig.autoMinimize = Object.assign({}, app.currentConfig.autoMinimize, patch);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { snappingPatch, notes } = eveoExtractSnapping(data);
        app.currentConfig.snapping = Object.assign({}, app.currentConfig.snapping, snappingPatch);
        allNotes.push(...notes);
    }
}

export async function runImport() {
    if (!importParsedData || !importFormat) return;

    const runBtn = document.getElementById('import-modal-run');
    runBtn.disabled = true;

    const allNotes = [];
    const checked = (id) => {
        const el = document.getElementById(`import_${id}`);
        return !!(el && el.checked && !el.disabled);
    };

    // A brand-new profile only auto-saves if "Live" was picked, since previewThumbnailConfig can't retarget the main app to a different profile.
    let autoSaveAfterImport = false;
    let previewAfterImport = false;

    try {
        const destNew = document.getElementById('import-dest-new').checked;
        if (destNew) {
            const rawName = document.getElementById('importNewProfileName').value;
            const sanitized = rawName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, MAX_PROFILE_NAME_LENGTH);
            if (sanitized === '') {
                showStatus(t('status.invalidNewProfileName'), 'error');
                runBtn.disabled = false;
                return;
            }

            const accentColorInput = document.getElementById('importAccentColor');
            const accentColor = accentColorInput ? htmlColorToZig(accentColorInput.value) : '';
            try {
                await rpc('createProfile', { name: sanitized, accentColor });
            } catch (error) {
                showStatus(t('status.createProfileFailedPrefix') + error.message, 'error');
                runBtn.disabled = false;
                return;
            }

            await loadProfileList();
            const profileSelect = document.getElementById('profile-select');
            profileSelect.value = sanitized + '.json';
            const switchChoice = await switchProfile(true);
            if (switchChoice === 'cancel') {
                // dialogEditingProfile is still the old profile - importing now would write into it instead of the newly-created one.
                runBtn.disabled = false;
                return;
            }
            autoSaveAfterImport = switchChoice === 'live';
        } else {
            previewAfterImport = true;
        }

        if (importFormat === 'evex') {
            await applyEvexImport(checked, allNotes);
        } else if (importFormat === 'eveo') {
            await applyEveoImport(checked, allNotes);
        } else if (importFormat === 'maj') {
            await applyMajImport(checked, allNotes);
        } else {
            await applyApmImport(checked, allNotes);
        }

        // Imported positions belong to a different setup, so the ghost overlay would just clutter drags with irrelevant saved positions.
        if (app.currentConfig.snapping) app.currentConfig.snapping.showGhostPositionBorders = false;

        populateFormFields();
        markAsChanged();

        if (autoSaveAfterImport) {
            await saveConfiguration();
        } else if (previewAfterImport) {
            await sendThumbnailPreview(true);
        }

        const hint = autoSaveAfterImport && !app.hasUnsavedChanges
            ? t('dynamic.import.liveNowHint')
            : t('dynamic.import.reviewAndSaveHint');
        const summaryEl = document.getElementById('importSummary');
        summaryEl.innerHTML = `<p class="hint" style="margin: 0 0 0.5rem 0;">${escapeHtml(t('dynamic.import.completeHeading'))}</p>` +
            '<ul style="margin: 0; padding-left: 1.125rem;">' +
            allNotes.map(n => `<li>${escapeHtml(n)}</li>`).join('') +
            '</ul>' +
            `<p class="hint" style="margin-top: 0.5rem;">${hint}</p>`;
        summaryEl.style.display = '';

        document.getElementById('import-step-file').style.display = 'none';
        document.getElementById('import-step-options').style.display = 'none';
        runBtn.style.display = 'none';
        document.getElementById('import-modal-cancel').textContent = t('status.importDoneLabel');
    } catch (err) {
        logError('Import failed:', err);
        showStatus(t('status.importFailedPrefix') + err.message, 'error');
        runBtn.disabled = false;
    }
}
