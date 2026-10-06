// Translation lookup and live language switching.
import { catalogs } from './catalogs.js';
import { app } from './state.js';
import { populateCharacters, saveCharacters } from './characters.js';
import { populateAppHotkeys, populateProfileSwitchHotkeys, populateUrlHotkeys, saveAppHotkeys, saveProfileSwitchHotkeys, saveUrlHotkeys } from './global_hotkeys.js';
import { populateHotkeyGroups, saveHotkeyGroups } from './hotkey_groups.js';
import { renderHotkeyBindings } from './hotkeys.js';
import { buildSectionNav } from './layout.js';
import { populateNotificationTypes, saveNotificationTypes } from './notifications.js';
import { populateOreTable, saveOreTable } from './ore_table.js';
import { populateSystemColors, saveSystemColors } from './system_colors.js';
import { populateWindowFilters, saveWindowFilters } from './window_filters.js';

// The page's lang attribute carries the saved language (see dialog/resources.zig).
let catalog = catalogs[document.documentElement.lang] || catalogs.en;

export function t(key) {
    if (key in catalog) return catalog[key];
    // A string not translated yet shows in English.
    if (key in catalogs.en) return catalogs.en[key];
    console.warn('Missing i18n key: ' + key);
    return key;
}

export function applyTranslations() {
    document.querySelectorAll('[data-i18n]').forEach(el => {
        el.textContent = t(el.getAttribute('data-i18n'));
    });
    document.querySelectorAll('[data-i18n-title]').forEach(el => {
        el.title = t(el.getAttribute('data-i18n-title'));
    });
    document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
        el.placeholder = t(el.getAttribute('data-i18n-placeholder'));
    });
    document.querySelectorAll('[data-i18n-aria-label]').forEach(el => {
        el.setAttribute('aria-label', t(el.getAttribute('data-i18n-aria-label')));
    });
}

// Every catalog is loaded up front, so switching languages needs no reload or backend round trip.
export function switchLanguage(code) {
    if (!(code in catalogs)) return;
    catalog = catalogs[code];
    document.documentElement.lang = code;
    applyTranslations();
    refreshDynamicSections();
    buildSectionNav();
}

// List sections render via one-time innerHTML templates, so translations need re-render, not a DOM re-scan; save*() flushes pending edits first so nothing is lost.
function refreshDynamicSections() {
    if (!app.currentConfig) return;
    saveWindowFilters();
    saveSystemColors();
    saveCharacters();
    saveHotkeyGroups();
    saveNotificationTypes();
    saveProfileSwitchHotkeys();
    saveAppHotkeys();
    saveUrlHotkeys();
    saveOreTable();

    populateWindowFilters();
    populateSystemColors();
    populateCharacters();
    populateHotkeyGroups();
    populateNotificationTypes();
    populateProfileSwitchHotkeys();
    populateAppHotkeys();
    populateUrlHotkeys();
    populateOreTable();
    renderHotkeyBindings();
}
