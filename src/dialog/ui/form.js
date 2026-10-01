// Fills the form from the documents and reads it back: the bound fields (see binding.js), shared option lists, and the few fields stored differently from how they show.
import { app } from './state.js';
import { applyDocToForm, readFormToDoc } from './binding.js';
import { languageNames } from './catalogs.js';
import { markAsChanged } from './changes.js';
import { ensureBlankRosterEntries, populateCharacters } from './characters.js';
import { syncSwatchHexInput } from './color_picker.js';
import { applyAccentColorTheme, htmlColorToZig, zigColorToHtml } from './colors.js';
import { populateHotkeyGroups } from './hotkey_groups.js';
import { updateHotkeyConflictHighlights } from './hotkeys.js';
import { populateNotificationTypes } from './notifications.js';
import { toggleAutoMinimizeOptions, toggleBorderOptions, toggleBountyOptions, toggleCharacterNameOptions, toggleChatlogOptions, toggleClickThroughOptions, toggleClientListOptions, toggleCombatOptions, toggleFocusedBorderOptions, toggleInactiveBorderOptions, toggleMiningOptions, toggleNotificationOptions, toggleNotifInfoPanelMergeOptions, toggleNotifInfoPanelOptions, toggleNotLoggedInSpaceOptions, toggleQuickGroupBadgeOptions, toggleRegionFitOptions, toggleResourcesOptions, toggleShiftClickExcludeOptions, toggleSnappingOptions, toggleSystemNameOptions, toggleTextDisplayOptions, toggleTravelOptions, toggleTtsDisplayNameOption, toggleUniqueCharacterNameColors, toggleUniqueSystemColors, toggleWindowFilters } from './options.js';
import { refreshOverlayLayoutPreview, syncOverlayStyleFromCharacterName } from './overlay_layout.js';
import { refreshRegionButtons } from './region.js';
import { populateSystemColors } from './system_colors.js';
import { detectThumbnailClientSize, refreshThumbnailSize } from './thumbnail_size.js';
import { populateWindowFilters } from './window_filters.js';

// The font <select>s offer these; any other installed font can still be saved by hand.
const FONT_OPTIONS = [
    'Cascadia Code', 'Cascadia Mono', 'Consolas', 'Courier New', 'Lucida Console', 'Monaco', 'Menlo', 'Arial', 'Verdana',
    'Tahoma', 'Trebuchet MS', 'Segoe UI', 'Calibri', 'Georgia', 'Times New Roman', 'Impact', 'Comic Sans MS',
];

// Must run before any setFieldValue() targets these selects, or there are no <option> elements yet to match.
export function populateLanguageSelect() {
    const select = document.getElementById('languageSelect');
    if (!select) return;
    Object.entries(languageNames).forEach(([code, name]) => select.add(new Option(name, code)));
}

export function populateSharedSelectOptions() {
    document.querySelectorAll('select.font-options').forEach(select => {
        FONT_OPTIONS.forEach(name => select.add(new Option(name, name)));
    });
}

// Shows values the app set or clamped at these dotted paths, leaving the rest of the form as the user has it.
export function applyPathsToForm(paths) {
    applyDocToForm(path => paths.includes(path));
    applySpecialFieldsToForm();
    refreshDependentOptions();
    updateHotkeyConflictHighlights();
}

// Native min/max only affects spinner UI, not typed values, so clamp visually on 'change' (not 'input', which would fight mid-keystroke) once the user commits a value.
document.addEventListener('change', (e) => {
    const field = e.target;
    if (field.type !== 'number' && field.type !== 'range') return;
    if (field.min === '' || field.max === '' || field.value === '') return;
    const value = parseFloat(field.value);
    if (isNaN(value)) return;
    const clamped = Math.min(parseFloat(field.max), Math.max(parseFloat(field.min), value));
    if (clamped !== value) {
        field.value = clamped;
        flashClampedField(field);
        // The out-of-range value was held back while it was typed (see binding.js), so the clamped one is what gets sent.
        markAsChanged();
    }
});

// Timer is stashed on the element itself so re-clamping quickly restarts the fade instead of stacking timeouts.
function flashClampedField(field) {
    field.classList.add('field-clamped');
    clearTimeout(field._clampFlashTimer);
    field._clampFlashTimer = setTimeout(() => field.classList.remove('field-clamped'), 1500);
}

// The border checkboxes only count while borders are enabled, which is itself stored as either being on.
function applySpecialFieldsToForm() {
    setCheckboxValue('showBorderWhenFocused', app.currentConfig.thumbnail.showBorderWhenFocused);
    setCheckboxValue('showBorderWhenInactive', app.currentConfig.thumbnail.showBorderWhenInactive);
    setCheckboxValue('borderEnabled', app.currentConfig.thumbnail.showBorderWhenFocused || app.currentConfig.thumbnail.showBorderWhenInactive);
    setCheckboxValue('regionFitEnabled', app.currentConfig.display.layoutMode === 'RegionFit');
}

export function readFormIntoConfig() {
    readFormToDoc();
    const borderEnabled = getFieldValue('borderEnabled');
    app.currentConfig.thumbnail.showBorderWhenFocused = borderEnabled && getFieldValue('showBorderWhenFocused');
    app.currentConfig.thumbnail.showBorderWhenInactive = borderEnabled && getFieldValue('showBorderWhenInactive');
}

// Mirrors any range slider's value into its data-value-target span, covering all offset/opacity sliders without a per-slider handler.
document.addEventListener('input', (e) => {
    if (e.target.matches('input[type="range"][data-value-target]')) {
        const span = document.getElementById(e.target.dataset.valueTarget);
        if (span) span.textContent = e.target.value;
    }
});

export function populateFormFields() {
    if (!app.currentConfig) return;

    applyAccentColorTheme();
    applyDocToForm(path => !path.startsWith('global.'));
    applySpecialFieldsToForm();

    if (document.getElementById('syncOverlayStyling')?.checked) syncOverlayStyleFromCharacterName();

    refreshDependentOptions();

    populateWindowFilters();

    const hasFilters = app.currentConfig.windowFilters && app.currentConfig.windowFilters.length > 0;
    setCheckboxValue('windowFiltersEnabled', hasFilters);
    toggleWindowFilters();

    populateSystemColors();
    ensureBlankRosterEntries();
    populateCharacters();
    populateHotkeyGroups();
    populateNotificationTypes();
    detectThumbnailClientSize();

    refreshOverlayLayoutPreview();
}

// Order-independent: each just reads fields already populated and adjusts unrelated elements' disabled state.
function refreshDependentOptions() {
    refreshThumbnailSize();
    toggleSnappingOptions();
    toggleRegionFitOptions();
    toggleNotLoggedInSpaceOptions();
    refreshRegionButtons();
    toggleNotifInfoPanelOptions();
    toggleNotifInfoPanelMergeOptions();
    toggleShiftClickExcludeOptions();
    toggleBorderOptions();
    toggleFocusedBorderOptions();
    toggleInactiveBorderOptions();
    toggleTextDisplayOptions();
    toggleCharacterNameOptions();
    toggleSystemNameOptions();
    toggleQuickGroupBadgeOptions();
    toggleUniqueSystemColors();
    toggleUniqueCharacterNameColors();
    toggleClickThroughOptions();
    toggleClientListOptions();
    toggleAutoMinimizeOptions();
    toggleTtsDisplayNameOption();
    toggleNotificationOptions();
    toggleChatlogOptions();
    toggleCombatOptions();
    toggleMiningOptions();
    toggleBountyOptions();
    toggleResourcesOptions();
    toggleTravelOptions();
}

export function setFieldValue(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;

    // A missing/null value means nothing is set for this field - clear it rather than leaving the previous profile's value.
    if (value === undefined || value === null) {
        field.value = field.type === 'color' ? zigColorToHtml(null) : '';
        if (field.type === 'color') syncSwatchHexInput(field);
        return;
    }

    if (field.type === 'color') {
        field.value = zigColorToHtml(value);
        syncSwatchHexInput(field);
    } else {
        field.value = value;
    }

    // The browser only fires 'input' for user interaction, not this programmatic assignment, so update the mirrored span manually.
    if (field.dataset.valueTarget) {
        const span = document.getElementById(field.dataset.valueTarget);
        if (span) span.textContent = field.value;
    }
}

function setCheckboxValue(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;
    field.checked = !!value;
}

export function getFieldValue(fieldId) {
    const field = document.getElementById(fieldId);
    if (!field) return null;

    if (field.type === 'number' || field.type === 'range') {
        const value = parseInt(field.value) || 0;
        if (field.min === '' || field.max === '') return value;
        return Math.min(parseFloat(field.max), Math.max(parseFloat(field.min), value));
    }
    if (field.type === 'checkbox') {
        return field.checked;
    }
    if (field.type === 'color') {
        return htmlColorToZig(field.value);
    }
    return field.value;
}
