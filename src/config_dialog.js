// Forwards console.error/warn to Zig's log.zig since this webview's devtools console is normally hidden.
function formatLogArgs(args) {
    return args.map((a) => {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === 'object' && a !== null) {
            try { return JSON.stringify(a); } catch (_) { return String(a); }
        }
        return String(a);
    }).join(' ');
}

function sendClientLog(level, message) {
    if (typeof webui !== 'undefined') {
        webui.call('logClientMessage', level, message).catch(() => {});
    }
}

function logError(...args) {
    console.error(...args);
    sendClientLog('error', formatLogArgs(args));
}

function logWarn(...args) {
    console.warn(...args);
    sendClientLog('warn', formatLogArgs(args));
}

// window.__I18N__ is populated by Zig's injectResources() before this script runs.
function t(key) {
    const catalog = window.__I18N__ || {};
    if (!(key in catalog)) {
        console.warn('Missing i18n key: ' + key);
        return key;
    }
    return catalog[key];
}

function applyTranslations() {
    document.querySelectorAll('[data-i18n]').forEach(el => {
        el.textContent = t(el.getAttribute('data-i18n'));
    });
    document.querySelectorAll('[data-i18n-title]').forEach(el => {
        el.title = t(el.getAttribute('data-i18n-title'));
    });
    document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
        el.placeholder = t(el.getAttribute('data-i18n-placeholder'));
    });
}

// window.__I18N_ALL__ is populated by Zig's injectResources(), so switching languages needs no reload/backend round trip.
function switchLanguage(code) {
    const all = window.__I18N_ALL__ || {};
    if (!(code in all)) return;
    window.__I18N__ = all[code];
    document.documentElement.lang = code;
    applyTranslations();
    refreshDynamicSections();
    buildSectionNav();
}

// List sections render via one-time innerHTML templates, so translations need re-render, not a DOM re-scan; save*() flushes pending edits first so nothing is lost.
function refreshDynamicSections() {
    if (!currentConfig) return;
    saveWindowFilters();
    saveSystemColors();
    saveCharacters();
    saveHotkeyGroups();
    saveQuickGroups();
    saveNotificationTypes();
    saveProfileSwitchHotkeys();
    saveOreTable();

    populateWindowFilters();
    populateSystemColors();
    populateCharacters();
    populateHotkeyGroups();
    populateQuickGroups();
    populateNotificationTypes();
    populateProfileSwitchHotkeys();
    populateOreTable();
}

window.addEventListener('error', (event) => {
    const detail = event.error ? (event.error.stack || event.error.message) : event.message;
    logError('Uncaught error:', detail, `(${event.filename}:${event.lineno}:${event.colno})`);
});

window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason instanceof Error ? (event.reason.stack || event.reason.message) : event.reason;
    logError('Unhandled promise rejection:', reason);
});

let currentConfig = null;
let currentGlobalSettings = null;
// Tracks names removed this session so reloadLivePositions() won't resurrect them from disk.
let deletedCharacterNames = new Set();
// Character names staged by pickRunningWindowForFilter(), keyed lowercased; added to currentConfig.characters only at Save time.
let pendingCharacterNames = new Map();
// Factory-default config fetched once at startup (loadDefaultConfig); feeds "Clear to Default" buttons. May stay null on fetch failure - callers must tolerate that.
let defaultConfig = null;
let webuiReady = false;
let hasUnsavedChanges = false;

// Server-truth min/max bounds keyed by CONFIG_SCHEMA's dotted path, in Config.zig's validate() units.
let VALIDATION_RANGES = {};
// VALIDATION_RANGES re-keyed by field id and converted to display units (e.g. ms -> seconds) - see buildFieldRanges().
let FIELD_RANGES = {};

let dialogEditingProfile = null;
// Profile the dialog believes is driving the running app's live thumbnails; live-preview patches only send while this equals dialogEditingProfile.
let liveConfirmedProfile = null;

function zigColorToHtml(color) {
    if (!color) return '#000000';

    let hexStr;
    if (typeof color === 'string') {
        hexStr = color.replace(/^(0x|#)/i, '');
    } else if (typeof color === 'number') {
        hexStr = color.toString(16).padStart(8, '0');
    } else {
        return '#000000';
    }
    
    const rgb = hexStr.length === 8 ? hexStr.slice(2) : hexStr.slice(-6);
    return '#' + rgb.toUpperCase();
}

function htmlColorToZig(htmlColor) {
    if (!htmlColor) return '0xFF000000';

    const rgb = htmlColor.replace(/^#/, '').padStart(6, '0');
    return '0xFF' + rgb.toUpperCase();
}

// Shared <option> lists for the many identical position/font <select> elements across tabs.
const POSITION_OPTIONS = [
    ['TopLeft', 'Top Left'], ['TopCenter', 'Top Center'], ['TopRight', 'Top Right'],
    ['LeftCenter', 'Left Center'], ['Center', 'Center'], ['RightCenter', 'Right Center'],
    ['BottomLeft', 'Bottom Left'], ['BottomCenter', 'Bottom Center'], ['BottomRight', 'Bottom Right'],
];

const FONT_OPTIONS = [
    'Consolas', 'Courier New', 'Lucida Console', 'Monaco', 'Menlo', 'Arial', 'Verdana',
    'Tahoma', 'Trebuchet MS', 'Segoe UI', 'Calibri', 'Georgia', 'Times New Roman',
];

// Must run before any setFieldValue() targets these selects, or there are no <option> elements yet to match.
function populateLanguageSelect() {
    const select = document.getElementById('languageSelect');
    if (!select) return;
    const langs = window.__I18N_LANGS__ || {};
    Object.keys(langs).forEach(code => select.add(new Option(langs[code], code)));
}

function populateSharedSelectOptions() {
    document.querySelectorAll('select.position-options').forEach(select => {
        POSITION_OPTIONS.forEach(([value, label]) => select.add(new Option(label, value)));
    });
    document.querySelectorAll('select.font-options').forEach(select => {
        FONT_OPTIONS.forEach(name => select.add(new Option(name, name)));
    });
}

// One entry per scalar/enum/color field bound between currentConfig and a DOM element; composite/list fields are handled separately by applySpecialFields*() below.
const CONFIG_SCHEMA = [
    { id: 'scanInterval', path: 'timer.scanIntervalMs', transform: 'ms' },
    { id: 'enableDragging', path: 'interaction.enableDragging' },
    { id: 'animationStyle', path: 'interaction.animationStyle' },
    { id: 'clickTrigger', path: 'interaction.clickTrigger' },

    { id: 'snappingEnabled', path: 'snapping.enabled' },
    { id: 'snappingThreshold', path: 'snapping.threshold' },
    { id: 'snappingScreenEdges', path: 'snapping.screenEdges' },
    { id: 'snappingThumbnailEdges', path: 'snapping.thumbnailEdges' },

    { id: 'thumbWidth', path: 'thumbnail.width' },
    { id: 'thumbHeight', path: 'thumbnail.height' },
    { id: 'thumbOpacity', path: 'thumbnail.thumbnailOpacity', transform: 'opacity', default: 255 },
    { id: 'applyOpacityToOverlayTexts', path: 'thumbnail.applyOpacityToOverlayTexts' },
    { id: 'borderWidth', path: 'thumbnail.borderWidth' },
    { id: 'borderStyle', path: 'thumbnail.borderStyle' },
    { id: 'borderColor', path: 'thumbnail.borderColor' },
    { id: 'inactiveBorderWidth', path: 'thumbnail.inactiveBorderWidth' },
    { id: 'inactiveBorderStyle', path: 'thumbnail.inactiveBorderStyle' },
    { id: 'inactiveBorderColor', path: 'thumbnail.inactiveBorderColor' },
    { id: 'showText', path: 'thumbnail.showText' },
    { id: 'showCharacterName', path: 'thumbnail.showCharacterName' },
    { id: 'characterNamePosition', path: 'thumbnail.characterNamePosition' },
    { id: 'characterNameOffsetX', path: 'thumbnail.characterNameOffsetX' },
    { id: 'characterNameOffsetY', path: 'thumbnail.characterNameOffsetY' },
    { id: 'showSystemName', path: 'thumbnail.showSystemName' },
    { id: 'systemNamePosition', path: 'thumbnail.systemNamePosition' },
    { id: 'systemNameOffsetX', path: 'thumbnail.systemNameOffsetX' },
    { id: 'systemNameOffsetY', path: 'thumbnail.systemNameOffsetY' },
    { id: 'showQuickGroupBadge', path: 'thumbnail.showQuickGroupBadge' },
    { id: 'quickGroupBadgePosition', path: 'thumbnail.quickGroupBadgePosition' },
    { id: 'quickGroupBadgeOffsetX', path: 'thumbnail.quickGroupBadgeOffsetX' },
    { id: 'quickGroupBadgeOffsetY', path: 'thumbnail.quickGroupBadgeOffsetY' },
    { id: 'quickGroupBadgeColor', path: 'thumbnail.quickGroupBadgeColor' },
    { id: 'exclusionOverlayStyle', path: 'thumbnail.exclusionOverlayStyle' },
    // exclusionOverlayColor/exclusionOverlayOpacity are special-cased below.
    { id: 'useUniqueSystemColors', path: 'thumbnail.useUniqueSystemColors' },
    { id: 'useUniqueCharacterNameColors', path: 'thumbnail.useUniqueCharacterNameColors' },
    { id: 'textFontName', path: 'thumbnail.textFontName' },
    { id: 'textFontSize', path: 'thumbnail.textFontSize' },
    { id: 'textFontWeight', path: 'thumbnail.textFontWeight' },
    { id: 'activeThumbnailHidden', path: 'thumbnail.activeThumbnailHidden' },
    { id: 'hideWhenNoEveFocus', path: 'thumbnail.hideWhenNoEveFocus' },
    { id: 'hideDebounceMs', path: 'thumbnail.hideDebounceMs', transform: 'ms' },
    { id: 'textColor', path: 'thumbnail.textColor' },
    { id: 'systemNameColor', path: 'thumbnail.systemNameColor' },
    { id: 'textBgColorInheritBorderColor', path: 'thumbnail.textBgColorInheritBorderColor' },
    // showBorderWhenFocused/showBorderWhenInactive/borderEnabled and textBgColor/textBgOpacity are special-cased below.

    { id: 'spacing', path: 'display.spacing' },
    { id: 'spacingX', path: 'display.spacingX', transform: 'nullable' },
    { id: 'spacingY', path: 'display.spacingY', transform: 'nullable' },
    { id: 'layoutMode', path: 'display.layoutMode' },
    { id: 'viewMode', path: 'display.viewMode' },
    { id: 'listViewOrder', path: 'display.listViewOrder', default: 'Tracked' },
    { id: 'rememberListViewPosition', path: 'display.rememberListViewPosition' },
    { id: 'listViewOpacity', path: 'display.listViewOpacity', transform: 'opacity', default: 255 },
    { id: 'listViewColumns', path: 'display.listViewColumns', default: 1 },
    { id: 'listViewFontName', path: 'display.listViewFontName' },
    { id: 'listViewFontSize', path: 'display.listViewFontSize' },
    { id: 'listViewFontWeight', path: 'display.listViewFontWeight' },
    { id: 'layoutDirection', path: 'display.layoutDirection' },
    { id: 'gridColumns', path: 'display.gridColumns' },
    { id: 'gridRows', path: 'display.gridRows', transform: 'nullable' },
    { id: 'stackOffset', path: 'display.stackOffset' },
    { id: 'stackAlignment', path: 'display.stackAlignment' },
    { id: 'monitorIndex', path: 'display.monitorIndex', transform: 'nullable' },
    { id: 'useMonitorWorkArea', path: 'display.useMonitorWorkArea' },
    { id: 'honorSavedPositions', path: 'display.honorSavedPositions' },
    { id: 'showNotifInfoPanel', path: 'display.showNotifInfoPanel' },
    // startX/startY/notifInfoPanelX/notifInfoPanelY are populate-only - saveConfiguration reloads them from disk instead of the form (see reloadLivePositions).

    { id: 'autoMinimizeEnabled', path: 'autoMinimize.enabled' },
    { id: 'autoMinimizeDelay', path: 'autoMinimize.delayMs', transform: 'ms' },

    { id: 'autoMovePositionEnabled', path: 'autoMovePosition.enabled' },

    { id: 'enableShiftClickExclude', path: 'exclusion.enableShiftClickExclude' },
    { id: 'autoMinimizeExcludedCharacters', path: 'exclusion.autoMinimizeExcluded' },

    { id: 'requireEveFocus', path: 'hotkeys.requireEveFocus' },
    { id: 'resetGroupIndexOnNonGroupFocus', path: 'hotkeys.resetGroupIndexOnNonGroupFocus' },
    { id: 'autoRegisterProtocol', path: 'hotkeys.autoRegisterProtocol' },
    { id: 'hotkeyMinimizeAll', path: 'hotkeys.hotkeyMinimizeAll', transform: 'vkhex' },
    { id: 'hotkeyCloseAll', path: 'hotkeys.hotkeyCloseAll', transform: 'vkhex' },
    { id: 'hotkeyToggleVisibility', path: 'hotkeys.hotkeyToggleVisibility', transform: 'vkhex' },
    { id: 'hotkeyToggleAutoMinimize', path: 'hotkeys.hotkeyToggleAutoMinimize', transform: 'vkhex' },
    { id: 'hotkeyMoveToSavedPositions', path: 'hotkeys.hotkeyMoveToSavedPositions', transform: 'vkhex' },
    { id: 'hotkeyToggleExclusion', path: 'hotkeys.hotkeyToggleExclusion', transform: 'vkhex' },
    { id: 'hotkeyNextExcluded', path: 'hotkeys.hotkeyNextExcluded', transform: 'vkhex' },
    { id: 'hotkeyPreviousExcluded', path: 'hotkeys.hotkeyPreviousExcluded', transform: 'vkhex' },
    { id: 'hotkeyCycleNotified', path: 'hotkeys.hotkeyCycleNotified', transform: 'vkhex' },
    { id: 'hotkeyPreviousNotified', path: 'hotkeys.hotkeyPreviousNotified', transform: 'vkhex' },
    { id: 'hotkeySuspend', path: 'hotkeys.hotkeySuspend', transform: 'vkhex' },

    // "active" is intentionally not here - unchecking it must write null (defer to activeThumbnailHidden), not false; see applySpecialFields*.
    { id: 'stateInactiveShow', path: 'thumbnail.inactive.showThumbnail' },
    { id: 'stateHoverShow', path: 'thumbnail.hover.showThumbnail' },
    { id: 'stateAlertShow', path: 'thumbnail.alert.showThumbnail' },
    { id: 'stateMinimizedShow', path: 'thumbnail.minimized.showThumbnail' },
    { id: 'stateDraggingShow', path: 'thumbnail.dragging.showThumbnail' },
    { id: 'stateHiddenShow', path: 'thumbnail.hidden.showThumbnail' },

    { id: 'notificationsEnabled', path: 'thumbnail.notifications.enabled' },
    { id: 'notifPosition', path: 'thumbnail.notifications.position' },
    { id: 'notifOffsetX', path: 'thumbnail.notifications.offset_x' },
    { id: 'notifOffsetY', path: 'thumbnail.notifications.offset_y' },
    { id: 'notifSuppressClickDuration', path: 'thumbnail.notifications.suppress_click_duration_ms', transform: 'ms' },
    { id: 'ttsEnabled', path: 'thumbnail.notifications.tts_enabled' },
    { id: 'ttsVolume', path: 'thumbnail.notifications.tts_volume', default: 100 },
    { id: 'ttsRate', path: 'thumbnail.notifications.tts_rate', default: 0 },
    { id: 'ttsUseDisplayName', path: 'thumbnail.notifications.tts_use_display_name', default: false },
    // notifCycleRetention and ttsSpeakCharacterName are special-cased below.

    { id: 'chatlogEnabled', path: 'chatlog.enabled' },
    { id: 'chatlogDir', path: 'chatlog.chatlogDir' },
    { id: 'gamelogDir', path: 'chatlog.gamelogDir' },
    { id: 'chatlogPollInterval', path: 'chatlog.pollIntervalMs', transform: 'ms' },
    { id: 'chatlogIdleThreshold', path: 'chatlog.idlePollThreshold' },
    { id: 'chatlogMaxPollMultiplier', path: 'chatlog.maxPollMultiplier' },
    { id: 'chatlogUseThreading', path: 'chatlog.useThreading' },

    // combat.*/mining.* paths are snake_case, unlike the rest of this table - camelCase here would silently no-op (see getConfigPath).
    { id: 'combatEnabled', path: 'combat.enabled' },
    { id: 'combatWindowSeconds', path: 'combat.window_seconds' },
    { id: 'combatUpdateIntervalMs', path: 'combat.update_interval_ms', transform: 'ms' },
    { id: 'combatShowIncoming', path: 'combat.show_incoming' },
    { id: 'combatShowOutgoing', path: 'combat.show_outgoing' },
    { id: 'combatIncomingPosition', path: 'combat.incoming_position' },
    { id: 'combatOutgoingPosition', path: 'combat.outgoing_position' },
    { id: 'combatIncomingColor', path: 'combat.incoming_color' },
    { id: 'combatOutgoingColor', path: 'combat.outgoing_color' },
    { id: 'combatFontSize', path: 'combat.font_size' },
    { id: 'combatIncomingOffsetX', path: 'combat.incoming_offset_x' },
    { id: 'combatIncomingOffsetY', path: 'combat.incoming_offset_y' },
    { id: 'combatOutgoingOffsetX', path: 'combat.outgoing_offset_x' },
    { id: 'combatOutgoingOffsetY', path: 'combat.outgoing_offset_y' },
    { id: 'combatDamageAlertEnabled', path: 'combat.damage_alert_enabled' },
    { id: 'combatDamageAlertRepeatSeconds', path: 'combat.damage_alert_repeat_seconds', default: 10 },
    { id: 'combatDamageAlertExcludedWeapons', path: 'combat.damage_alert_excluded_weapons', default: '' },
    { id: 'combatIconEnabled', path: 'combat.icon_enabled' },
    { id: 'combatIconPosition', path: 'combat.icon_position' },
    { id: 'combatIconColor', path: 'combat.icon_color' },
    { id: 'combatIconFontSize', path: 'combat.icon_font_size' },
    { id: 'combatIconOffsetX', path: 'combat.icon_offset_x' },
    { id: 'combatIconOffsetY', path: 'combat.icon_offset_y' },

    { id: 'miningEnabled', path: 'mining.enabled' },
    { id: 'miningWindowSeconds', path: 'mining.window_seconds' },
    { id: 'miningUpdateIntervalMs', path: 'mining.update_interval_ms', transform: 'ms' },
    { id: 'miningPosition', path: 'mining.position' },
    { id: 'miningColor', path: 'mining.color' },
    { id: 'miningFontSize', path: 'mining.font_size' },
    { id: 'miningOffsetX', path: 'mining.offset_x' },
    { id: 'miningOffsetY', path: 'mining.offset_y' },
    { id: 'miningShowIskRate', path: 'mining.show_isk_rate' },
    { id: 'miningIskRateUnit', path: 'mining.isk_rate_unit' },
    { id: 'miningIdleAlertEnabled', path: 'mining.idle_alert_enabled' },
    { id: 'miningIdleAlertWindowSeconds', path: 'mining.idle_alert_window_seconds' },
    { id: 'miningIdleAlertThreshold', path: 'mining.idle_alert_threshold' },
    { id: 'miningStoppedAlertEnabled', path: 'mining.stopped_alert_enabled' },
    { id: 'miningStoppedAlertWindowSeconds', path: 'mining.stopped_alert_window_seconds' },

    { id: 'bountyEnabled', path: 'bounty.enabled' },
    { id: 'bountyWindowSeconds', path: 'bounty.window_seconds' },
    { id: 'bountyUpdateIntervalMs', path: 'bounty.update_interval_ms', transform: 'ms' },
    { id: 'bountyPosition', path: 'bounty.position' },
    { id: 'bountyColor', path: 'bounty.color' },
    { id: 'bountyFontSize', path: 'bounty.font_size' },
    { id: 'bountyOffsetX', path: 'bounty.offset_x' },
    { id: 'bountyOffsetY', path: 'bounty.offset_y' },
    { id: 'bountyIskRateUnit', path: 'bounty.isk_rate_unit' },
];

function getConfigPath(obj, path) {
    return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function setConfigPath(obj, path, value) {
    const keys = path.split('.');
    let target = obj;
    for (let i = 0; i < keys.length - 1; i++) {
        const k = keys[i];
        if (target[k] == null || typeof target[k] !== 'object') target[k] = {};
        target = target[k];
    }
    target[keys[keys.length - 1]] = value;
}

function applyConfigSchemaToForm() {
    for (const f of CONFIG_SCHEMA) {
        let value = getConfigPath(currentConfig, f.path);
        if (value == null && f.default !== undefined) value = f.default;
        if (f.transform === 'ms') value = value != null ? value / 1000 : null;
        else if (f.transform === 'opacity') value = opacityToPercent(value ?? 255);
        else if (f.transform === 'vkhex') value = vkHexToFriendly(value);

        const field = document.getElementById(f.id);
        if (field && field.type === 'checkbox') setCheckboxValue(f.id, value);
        else setFieldValue(f.id, value);
    }
}

function applyConfigSchemaFromForm() {
    for (const f of CONFIG_SCHEMA) {
        let value;
        if (f.transform === 'ms') {
            const raw = parseFloat(document.getElementById(f.id)?.value);
            value = Math.round((isNaN(raw) ? 0 : raw) * 1000);
            value = clampToValidationRange(f.path, value);
        } else if (f.transform === 'nullable') {
            value = getNullableFieldValue(f.id);
            if (value !== null) value = clampToValidationRange(f.path, value);
        } else {
            value = getFieldValue(f.id);
            if (f.transform === 'opacity') value = percentToOpacity(value);
            else if (f.transform === 'vkhex') value = value || null;
        }
        setConfigPath(currentConfig, f.path, value);
    }
}

// Fetched once from Zig (not hand-copied) so validate() bound changes never need a matching edit here.
function clampToValidationRange(path, value) {
    if (value == null || typeof value !== 'number' || isNaN(value)) return value;
    const range = VALIDATION_RANGES[path];
    if (!range) return value;
    return Math.min(range.max, Math.max(range.min, value));
}

// Re-keys VALIDATION_RANGES by field id in display units, so getFieldValue() can clamp a raw DOM read without knowing about CONFIG_SCHEMA/transforms.
function buildFieldRanges() {
    FIELD_RANGES = {};
    for (const f of CONFIG_SCHEMA) {
        const range = VALIDATION_RANGES[f.path];
        if (!range) continue;

        let min = range.min, max = range.max;
        if (f.transform === 'ms') { min /= 1000; max /= 1000; }
        else if (f.transform === 'opacity') { min = opacityToPercent(min); max = opacityToPercent(max); }

        FIELD_RANGES[f.id] = { min, max };
    }
}

// Sets native min/max on schema-mapped number/range inputs so the browser reflects real backend limits instead of hand-typed HTML values.
function applyValidationRangesToInputs() {
    for (const [id, range] of Object.entries(FIELD_RANGES)) {
        const field = document.getElementById(id);
        if (!field || (field.type !== 'number' && field.type !== 'range')) continue;
        field.min = range.min;
        field.max = range.max;
    }
}

async function loadValidationRanges() {
    try {
        const response = await webui.call('getValidationRanges');
        VALIDATION_RANGES = JSON.parse(response) || {};
    } catch (error) {
        logWarn('Failed to load validation ranges:', error);
        VALIDATION_RANGES = {};
    }
    buildFieldRanges();
    applyValidationRangesToInputs();
}

// Native min/max only affects spinner UI, not typed values, so clamp visually on 'change' (not 'input', which would fight mid-keystroke) once the user commits a value.
document.addEventListener('change', (e) => {
    const field = e.target;
    if (field.type !== 'number' && field.type !== 'range') return;
    const range = FIELD_RANGES[field.id];
    if (!range || field.value === '') return;
    const value = parseFloat(field.value);
    if (isNaN(value)) return;
    const clamped = Math.min(range.max, Math.max(range.min, value));
    if (clamped !== value) {
        field.value = clamped;
        flashClampedField(field);
    }
});

// Timer is stashed on the element itself so re-clamping quickly restarts the fade instead of stacking timeouts.
function flashClampedField(field) {
    field.classList.add('field-clamped');
    clearTimeout(field._clampFlashTimer);
    field._clampFlashTimer = setTimeout(() => field.classList.remove('field-clamped'), 1500);
}

// Fields that can't be expressed as a single {id, path} pair: composite values, asymmetric load/save, or non-trivial defaults.
function applySpecialFieldsToForm() {
    setFieldValue('startX', currentConfig.display?.startX);
    setFieldValue('startY', currentConfig.display?.startY);

    setCheckboxValue('showBorderWhenFocused', currentConfig.thumbnail?.showBorderWhenFocused);
    setCheckboxValue('showBorderWhenInactive', currentConfig.thumbnail?.showBorderWhenInactive);
    const hasBorder = currentConfig.thumbnail?.showBorderWhenFocused || currentConfig.thumbnail?.showBorderWhenInactive;
    setCheckboxValue('borderEnabled', hasBorder);

    setFieldValue('textBgColor', currentConfig.thumbnail?.textBgColor);
    const textBgOpacityPercent = opacityToPercent(zigColorAlpha(currentConfig.thumbnail?.textBgColor));
    setFieldValue('textBgOpacity', textBgOpacityPercent);

    setFieldValue('exclusionOverlayColor', currentConfig.thumbnail?.exclusionOverlayColor);
    const exclusionOverlayOpacityPercent = opacityToPercent(zigColorAlpha(currentConfig.thumbnail?.exclusionOverlayColor));
    setFieldValue('exclusionOverlayOpacity', exclusionOverlayOpacityPercent);

    setCheckboxValue('stateActiveShow', currentConfig.thumbnail?.active?.showThumbnail);

    setCheckboxValue('ttsSpeakCharacterName', currentConfig.thumbnail?.notifications?.tts_speak_character_name !== false);
    setFieldValue('notifCycleRetention', currentConfig.thumbnail?.notifications?.notified_cycle_retention_seconds ?? 30);
}

function applySpecialFieldsFromForm() {
    const borderEnabled = getFieldValue('borderEnabled');
    currentConfig.thumbnail.showBorderWhenFocused = borderEnabled && getFieldValue('showBorderWhenFocused');
    currentConfig.thumbnail.showBorderWhenInactive = borderEnabled && getFieldValue('showBorderWhenInactive');

    currentConfig.thumbnail.textBgColor = zigColorWithAlpha(getFieldValue('textBgColor'), percentToOpacity(getFieldValue('textBgOpacity')));

    currentConfig.thumbnail.exclusionOverlayColor = zigColorWithAlpha(getFieldValue('exclusionOverlayColor'), percentToOpacity(getFieldValue('exclusionOverlayOpacity')));

    if (!currentConfig.thumbnail.active) currentConfig.thumbnail.active = {};
    currentConfig.thumbnail.active.showThumbnail = getFieldValue('stateActiveShow') ? true : null;

    const rawRetention = parseInt(document.getElementById('notifCycleRetention').value, 10) || 30;
    currentConfig.thumbnail.notifications.notified_cycle_retention_seconds =
        clampToValidationRange('thumbnail.notifications.notified_cycle_retention_seconds', rawRetention);
}

// Mirrors any range slider's value into its data-value-target span, covering all offset/opacity sliders without a per-slider handler.
document.addEventListener('input', (e) => {
    if (e.target.matches('input[type="range"][data-value-target]')) {
        const span = document.getElementById(e.target.dataset.valueTarget);
        if (span) span.textContent = e.target.value;
    }
});

async function waitForWebUI() {
    let attempts = 0;
    const maxAttempts = 50;

    while (attempts < maxAttempts) {
        if (typeof webui !== 'undefined' && webui.call) {
            try {
                await webui.call('getConfigData');
                console.log('WebUI connection verified after', attempts * 100, 'ms');
                webuiReady = true;
                return true;
            } catch (error) {
                console.log('WebUI not ready yet, attempt', attempts + 1);
            }
        }
        await new Promise(resolve => setTimeout(resolve, 100));
        attempts++;
    }
    
    logError('WebUI failed to initialize after', maxAttempts * 100, 'ms');
    return false;
}

function markAsChanged() {
    if (!hasUnsavedChanges) {
        hasUnsavedChanges = true;
        const indicator = document.getElementById('changes-indicator');
        if (indicator) {
            indicator.style.display = 'flex';
        }
    }
}

function markAsSaved() {
    hasUnsavedChanges = false;
    const indicator = document.getElementById('changes-indicator');
    if (indicator) {
        indicator.style.display = 'none';
    }
}

// Delegated (not per-element) so rows added later at runtime are covered without needing to re-run this after every dynamic list rebuild.
function isTrackedFormElement(element) {
    if (!element.matches || !element.matches('input, select, textarea')) return false;
    return element.id !== 'search-filter' && element.id !== 'profile-select';
}

function isChangeEventType(element) {
    return element.type === 'checkbox' || element.type === 'radio' ||
        element.type === 'color' || element.tagName === 'SELECT';
}

function setupChangeDetection() {
    document.addEventListener('input', (e) => {
        if (isTrackedFormElement(e.target) && !isChangeEventType(e.target)) markAsChanged();
    });
    document.addEventListener('change', (e) => {
        if (isTrackedFormElement(e.target) && isChangeEventType(e.target)) markAsChanged();
    });
}

// Pushes an unsaved patch to the running main app so open thumbnails reflect edits immediately, without writing to disk. startX/startY are excluded since they can be live-dragged (see painter.zig's repositionAllThumbnails()).
const THUMBNAIL_PREVIEW_FIELD_IDS = [
    'borderEnabled', 'showBorderWhenFocused', 'borderWidth', 'borderStyle', 'borderColor',
    'showBorderWhenInactive', 'inactiveBorderWidth', 'inactiveBorderStyle', 'inactiveBorderColor',
    'textBgColorInheritBorderColor',
    'thumbOpacity', 'applyOpacityToOverlayTexts', 'activeThumbnailHidden',
    'showText', 'showCharacterName', 'showSystemName', 'useUniqueSystemColors',
    'textFontName', 'textFontSize', 'textFontWeight',
    'characterNamePosition', 'characterNameOffsetX', 'characterNameOffsetY', 'textColor',
    'useUniqueCharacterNameColors',
    'systemNamePosition', 'systemNameOffsetX', 'systemNameOffsetY', 'systemNameColor',
    'showQuickGroupBadge', 'quickGroupBadgePosition', 'quickGroupBadgeOffsetX', 'quickGroupBadgeOffsetY', 'quickGroupBadgeColor',
    'exclusionOverlayStyle', 'exclusionOverlayColor', 'exclusionOverlayOpacity',
    'textBgColor', 'textBgOpacity',
    'thumbWidth', 'thumbHeight', 'thumbSizeSlider', 'hideWhenNoEveFocus',
    'listViewOpacity', 'listViewFontName', 'listViewFontSize', 'listViewFontWeight',
    'spacing', 'spacingX', 'spacingY', 'layoutMode', 'layoutDirection',
    'gridColumns', 'gridRows', 'stackOffset', 'stackAlignment',
    'monitorIndex', 'useMonitorWorkArea', 'honorSavedPositions',
];

let thumbnailPreviewDebounceTimer = null;

function scheduleThumbnailPreview() {
    if (thumbnailPreviewDebounceTimer) clearTimeout(thumbnailPreviewDebounceTimer);
    thumbnailPreviewDebounceTimer = setTimeout(sendThumbnailPreview, 120);
}

function buildThumbnailPreviewPatch(includePositions = false) {
    const borderEnabled = getFieldValue('borderEnabled');
    return {
        showBorderWhenFocused: borderEnabled && getFieldValue('showBorderWhenFocused'),
        borderWidth: getFieldValue('borderWidth'),
        borderStyle: getFieldValue('borderStyle'),
        borderColor: getFieldValue('borderColor'),
        showBorderWhenInactive: borderEnabled && getFieldValue('showBorderWhenInactive'),
        inactiveBorderWidth: getFieldValue('inactiveBorderWidth'),
        inactiveBorderStyle: getFieldValue('inactiveBorderStyle'),
        inactiveBorderColor: getFieldValue('inactiveBorderColor'),
        textBgColorInheritBorderColor: getFieldValue('textBgColorInheritBorderColor'),
        thumbnailOpacity: percentToOpacity(getFieldValue('thumbOpacity')),
        applyOpacityToOverlayTexts: getFieldValue('applyOpacityToOverlayTexts'),
        activeThumbnailHidden: getFieldValue('activeThumbnailHidden'),
        showText: getFieldValue('showText'),
        showCharacterName: getFieldValue('showCharacterName'),
        showSystemName: getFieldValue('showSystemName'),
        useUniqueSystemColors: getFieldValue('useUniqueSystemColors'),
        textFontName: getFieldValue('textFontName'),
        textFontSize: getFieldValue('textFontSize'),
        textFontWeight: getFieldValue('textFontWeight'),
        characterNamePosition: getFieldValue('characterNamePosition'),
        characterNameOffsetX: getFieldValue('characterNameOffsetX'),
        characterNameOffsetY: getFieldValue('characterNameOffsetY'),
        textColor: getFieldValue('textColor'),
        useUniqueCharacterNameColors: getFieldValue('useUniqueCharacterNameColors'),
        systemNamePosition: getFieldValue('systemNamePosition'),
        systemNameOffsetX: getFieldValue('systemNameOffsetX'),
        systemNameOffsetY: getFieldValue('systemNameOffsetY'),
        systemNameColor: getFieldValue('systemNameColor'),
        showQuickGroupBadge: getFieldValue('showQuickGroupBadge'),
        quickGroupBadgePosition: getFieldValue('quickGroupBadgePosition'),
        quickGroupBadgeOffsetX: getFieldValue('quickGroupBadgeOffsetX'),
        quickGroupBadgeOffsetY: getFieldValue('quickGroupBadgeOffsetY'),
        quickGroupBadgeColor: getFieldValue('quickGroupBadgeColor'),
        exclusionOverlayStyle: getFieldValue('exclusionOverlayStyle'),
        exclusionOverlayColor: zigColorWithAlpha(getFieldValue('exclusionOverlayColor'), percentToOpacity(getFieldValue('exclusionOverlayOpacity'))),
        textBgColor: zigColorWithAlpha(getFieldValue('textBgColor'), percentToOpacity(getFieldValue('textBgOpacity'))),
        systemColors: buildSystemColorsPreviewPatch(),
        width: getFieldValue('thumbWidth'),
        height: getFieldValue('thumbHeight'),
        hideWhenNoEveFocus: getFieldValue('hideWhenNoEveFocus'),
        display: {
            listViewOpacity: percentToOpacity(getFieldValue('listViewOpacity')),
            listViewFontName: getFieldValue('listViewFontName'),
            listViewFontSize: getFieldValue('listViewFontSize'),
            listViewFontWeight: getFieldValue('listViewFontWeight'),
            // startX/startY are deliberately omitted - see repositionAllThumbnails() in painter.zig.
            spacing: getFieldValue('spacing'),
            spacingX: getNullableFieldValue('spacingX'),
            spacingY: getNullableFieldValue('spacingY'),
            layoutMode: getFieldValue('layoutMode'),
            layoutDirection: getFieldValue('layoutDirection'),
            gridColumns: getFieldValue('gridColumns'),
            gridRows: getNullableFieldValue('gridRows'),
            stackOffset: getFieldValue('stackOffset'),
            stackAlignment: getFieldValue('stackAlignment'),
            monitorIndex: getNullableFieldValue('monitorIndex'),
            useMonitorWorkArea: getFieldValue('useMonitorWorkArea'),
            honorSavedPositions: getFieldValue('honorSavedPositions'),
        },
        characterOverrides: buildCharacterOverridesPreviewPatch(includePositions),
    };
}

// Reads straight from the DOM, not currentConfig - saveSystemColors() writes a `.name` property while the field loaded from disk is `.systemName`, so that object can't be trusted as a live source.
function buildSystemColorsPreviewPatch() {
    const container = document.getElementById('systemColorsList');
    if (!container) return [];
    const result = [];
    container.querySelectorAll('input[id^="systemColor_"][id$="_name"]').forEach(nameField => {
        const match = nameField.id.match(/^systemColor_(\d+)_name$/);
        if (!match) return;
        const colorField = document.getElementById(`systemColor_${match[1]}_color`);
        const systemName = nameField.value.trim();
        if (!systemName || !colorField) return;
        result.push({ systemName, color: htmlColorToZig(colorField.value) });
    });
    return result;
}

// A color counts as "set" if it was already set on load, or the user changed it from the #000000 default; "Clear to Default" sets dataset.cleared to override this.
function resolveOptionalCharacterColor(input, hadValue) {
    if (!input || input.dataset.cleared === 'true') return null;
    const changed = input.value.toUpperCase() !== '#000000';
    return (hadValue || changed) ? htmlColorToZig(input.value) : null;
}

// Reads straight from the accordion DOM using the same "set OR changed from #000000 default" convention as saveCharacters(), so live preview and Save agree on what counts as "set".
function buildCharacterOverridesPreviewPatch(includePositions = false) {
    if (!currentConfig || !currentConfig.characters) return [];
    const result = [];
    currentConfig.characters.forEach((char, index) => {
        if (!char.name) return;

        const width = document.getElementById(`char_${index}_width`);
        const height = document.getElementById(`char_${index}_height`);
        const activeColor = document.getElementById(`char_${index}_activeColor`);
        const inactiveColor = document.getElementById(`char_${index}_inactiveColor`);
        const nameColor = document.getElementById(`char_${index}_nameColor`);
        const displayNameField = document.getElementById(`char_${index}_displayName`);
        const hideThumbnailField = document.getElementById(`char_${index}_hideThumbnail`);
        if (!width && !height && !activeColor && !inactiveColor && !nameColor && !displayNameField && !hideThumbnailField) return;

        const displayName = displayNameField ? (displayNameField.value.trim() || null) : null;
        const hideThumbnail = hideThumbnailField ? hideThumbnailField.checked : false;

        const w = width ? (parseInt(width.value) || null) : null;
        const h = height ? (parseInt(height.value) || null) : null;
        const thumbnailSize = (w || h) ? { width: w, height: h } : null;

        const activeOut = resolveOptionalCharacterColor(activeColor, !!(char.borderColors && char.borderColors.activeBorderColor));
        const inactiveOut = resolveOptionalCharacterColor(inactiveColor, !!(char.borderColors && char.borderColors.inactiveBorderColor));
        const borderColors = (activeOut || inactiveOut)
            ? { activeBorderColor: activeOut, inactiveBorderColor: inactiveOut }
            : null;

        const nameColorOut = resolveOptionalCharacterColor(nameColor, !!char.nameColor);

        const entry = { name: char.name, displayName, hideThumbnail, thumbnailSize, borderColors, nameColor: nameColorOut };
        if (includePositions && char.position) entry.position = char.position;
        result.push(entry);
    });
    return result;
}

async function sendThumbnailPreview(includePositions = false) {
    if (typeof webui === 'undefined' || !webuiReady || !currentConfig) return;
    // Never push a preview onto a profile the dialog hasn't confirmed is actually running - see switchProfile()'s live-switch modal.
    if (!dialogEditingProfile || dialogEditingProfile !== liveConfirmedProfile) return;
    try {
        await webui.call('previewThumbnailConfig', JSON.stringify(buildThumbnailPreviewPatch(includePositions)));
    } catch (error) {
        logWarn('Failed to send thumbnail preview:', error);
    }
}

function setupThumbnailPreview() {
    THUMBNAIL_PREVIEW_FIELD_IDS.forEach(id => {
        const field = document.getElementById(id);
        if (!field) return;
        const eventName = (field.type === 'checkbox' || field.type === 'color' || field.tagName === 'SELECT') ? 'change' : 'input';
        field.addEventListener(eventName, scheduleThumbnailPreview);
    });

    // System Color Overrides rows are added/removed at runtime, so listen on the container instead of individual fields.
    const systemColorsList = document.getElementById('systemColorsList');
    if (systemColorsList) {
        systemColorsList.addEventListener('input', (e) => {
            if (e.target.id.startsWith('systemColor_')) scheduleThumbnailPreview();
        });
        systemColorsList.addEventListener('change', (e) => {
            if (e.target.id.startsWith('systemColor_')) scheduleThumbnailPreview();
        });
    }

    // Per-character override fields are regenerated per accordion row by populateCharacters(), so listen on the container, same as above.
    const charactersList = document.getElementById('charactersList');
    if (charactersList) {
        const isPreviewableCharField = (id) => /^char_\d+_(width|height|activeColor|inactiveColor|nameColor|displayName|hideThumbnail)$/.test(id);
        charactersList.addEventListener('input', (e) => {
            if (isPreviewableCharField(e.target.id)) scheduleThumbnailPreview();
        });
        charactersList.addEventListener('change', (e) => {
            if (isPreviewableCharField(e.target.id)) scheduleThumbnailPreview();
        });
    }
}

document.addEventListener('DOMContentLoaded', async function() {
    console.log('Config dialog initialized');

    applyTranslations();
    populateLanguageSelect();
    populateSharedSelectOptions();
    setupChangeDetection();
    setupThumbnailPreview();
    
    // Mark initially hidden tabs for search filter
    document.querySelectorAll('.tab-item').forEach(tab => {
        if (tab.style.display === 'none') {
            const tabId = tab.getAttribute('data-tab');
            searchState.initiallyHiddenTabs.push(tabId);
        }
    });
    
    initializeTabs();
    buildSectionNav();
    setupSectionScrollSpy();

    const ready = await waitForWebUI();
    if (ready) {
        // Fire independent calls immediately instead of serializing a round trip each - only loadProfileList()'s completion is needed below.
        const profileListLoaded = loadProfileList();
        loadConfigurationFromBackend();
        loadGlobalSettingsFromBackend();
        loadAppVersion();
        loadDefaultConfig();
        loadValidationRanges();
        startMainAppStatusPolling();
        refreshWindowPositionSourceOptions();

        await profileListLoaded;
        // Best-effort assumption: whatever profile the app loaded with is live. Only "Make It Live" or a Save updates liveConfirmedProfile after this.
        const initialProfile = document.getElementById('profile-select').value;
        dialogEditingProfile = initialProfile;
        liveConfirmedProfile = initialProfile;
    } else {
        showStatus(t('status.webuiInitFailed'), 'error');
        logWarn('Using mock configuration');
        loadMockConfiguration();
    }
});

function initializeTabs() {
    const tabs = document.querySelectorAll('.tab-item');
    tabs.forEach(tab => {
        tab.addEventListener('click', function() {
            const targetPanel = this.getAttribute('data-tab');
            switchTab(targetPanel);
        });
    });
}

function switchTab(panelId) {
    document.querySelectorAll('.tab-item').forEach(tab => {
        tab.classList.remove('active');
        if (tab.getAttribute('data-tab') === panelId) {
            tab.classList.add('active');
        }
    });

    document.querySelectorAll('.panel-content').forEach(panel => {
        panel.classList.remove('active');
        if (panel.getAttribute('data-panel') === panelId) {
            panel.classList.add('active');
        }
    });

    const contentPanel = document.getElementById('content-panel');
    if (contentPanel) {
        contentPanel.scrollTop = 0;
    }

    updateActiveSectionHighlight();
}

// Tabs whose sections are too few/short to be worth a sidebar sub-list; shared with updateActiveSectionHighlight() so scrollspy doesn't glow a section with no subheader.
const TABS_WITHOUT_SUBHEADERS = ['about', 'characters', 'chatlog'];

// IDs/labels are derived from each section's h3[data-i18n] rather than hand-maintained, so they can't drift out of sync as sections are added/removed.
function buildSectionNav() {
    document.querySelectorAll('.subheader-list').forEach(el => el.remove());

    document.querySelectorAll('.tab-item').forEach(tabItem => {
        const tabName = tabItem.getAttribute('data-tab');
        if (TABS_WITHOUT_SUBHEADERS.includes(tabName)) return;
        const panel = document.querySelector(`.panel-content[data-panel="${tabName}"]`);
        if (!panel) return;

        const list = document.createElement('div');
        list.className = 'subheader-list';

        panel.querySelectorAll('.section').forEach((section, index) => {
            if (section.style.display === 'none') return;
            if (section.classList.contains('advanced-section') && !document.body.classList.contains('advanced-mode')) return;

            const heading = section.querySelector('h3');
            if (!heading) return;

            const i18nKey = heading.getAttribute('data-i18n') || '';
            const slugMatch = i18nKey.match(/^tab\.[a-z0-9-]+\.section\.([a-z0-9-]+)\.heading$/);
            section.id = `section-${tabName}-${slugMatch ? slugMatch[1] : index}`;

            const item = document.createElement('div');
            item.className = 'subheader-item';
            item.textContent = heading.textContent;
            item.addEventListener('click', () => jumpToSection(tabName, section.id));
            list.appendChild(item);

            section._navItem = item;
        });

        tabItem.insertAdjacentElement('afterend', list);
    });

    updateActiveSectionHighlight();
}

function jumpToSection(tabName, sectionId) {
    // Only switchTab() (resets scroll to top) when the tab isn't already showing, so a same-tab jump smooth-scrolls instead of snapping to top.
    const tabItem = document.querySelector(`.tab-item[data-tab="${tabName}"]`);
    if (!tabItem || !tabItem.classList.contains('active')) {
        switchTab(tabName);
    }
    requestAnimationFrame(() => {
        const section = document.getElementById(sectionId);
        if (!section) return;
        suppressSectionScrollSpy();
        section.scrollIntoView({ behavior: 'smooth', block: 'start' });
        setActiveSection(section);
    });
}

// No timer: the CSS transition on .section-active handles both the fade-in and fade-out.
function setActiveSection(section) {
    document.querySelectorAll('.section-active').forEach(el => el.classList.remove('section-active'));
    document.querySelectorAll('.subheader-item-active').forEach(el => el.classList.remove('subheader-item-active'));
    if (!section) return;
    section.classList.add('section-active');
    if (section._navItem) {
        section._navItem.classList.add('subheader-item-active');
    }
}

// Highlights whichever section's top has scrolled past #content-panel's top (plus a buffer), using the last section that qualifies so a short section can't out-rank a tall one.
const SECTION_SCROLL_SPY_OFFSET = 40;

function updateActiveSectionHighlight() {
    const contentPanel = document.getElementById('content-panel');
    const activePanel = document.querySelector('.panel-content.active');
    if (!contentPanel || !activePanel) return;

    if (TABS_WITHOUT_SUBHEADERS.includes(activePanel.getAttribute('data-panel'))) {
        setActiveSection(null);
        return;
    }

    const sections = Array.from(activePanel.querySelectorAll('.section')).filter(s => s.style.display !== 'none');
    if (!sections.length) return;

    // A short last section may never reach the threshold line if there's no room below it - once scrolled to the end, just assume it's selected.
    const atBottom = contentPanel.scrollTop + contentPanel.clientHeight >= contentPanel.scrollHeight - 1;
    if (atBottom) {
        setActiveSection(sections[sections.length - 1]);
        return;
    }

    const containerTop = contentPanel.getBoundingClientRect().top;
    const threshold = containerTop + SECTION_SCROLL_SPY_OFFSET;

    let current = null;
    sections.forEach(section => {
        if (section.getBoundingClientRect().top <= threshold) {
            current = section;
        }
    });

    setActiveSection(current);
}

// scrollIntoView's smooth-scroll fires 'scroll' on nearly every frame, which would fight the highlight jumpToSection() just set; suppress the spy until 'scrollend' (with a timeout fallback).
let sectionScrollSpySuppressed = false;
let sectionScrollSpySuppressTimer = null;

function suppressSectionScrollSpy() {
    sectionScrollSpySuppressed = true;
    clearTimeout(sectionScrollSpySuppressTimer);
    sectionScrollSpySuppressTimer = setTimeout(() => {
        sectionScrollSpySuppressed = false;
    }, 700);
}

function setupSectionScrollSpy() {
    const contentPanel = document.getElementById('content-panel');
    if (!contentPanel) return;

    let ticking = false;
    contentPanel.addEventListener('scroll', () => {
        if (sectionScrollSpySuppressed) return;
        if (ticking) return;
        ticking = true;
        requestAnimationFrame(() => {
            updateActiveSectionHighlight();
            ticking = false;
        });
    });

    contentPanel.addEventListener('scrollend', () => {
        sectionScrollSpySuppressed = false;
        clearTimeout(sectionScrollSpySuppressTimer);
    });
}

function closeDialog() {
    console.log('Closing configuration terminal');
    if (typeof webui !== 'undefined') {
        webui.call('closeDialog');
    }
}

function minimizeDialog() {
    console.log('Minimizing configuration terminal');
    if (typeof webui !== 'undefined') {
        webui.call('minimizeDialog');
    }
}

// Polls whether the main app process is running, so the status indicator reflects it being closed/reopened while this dialog stays open.
const MAIN_APP_STATUS_POLL_MS = 3000;

async function updateMainAppStatus() {
    const statusEl = document.getElementById('main-app-status');
    if (!statusEl || typeof webui === 'undefined') return;

    try {
        const response = await webui.call('getMainAppStatus');
        const { running } = JSON.parse(response);
        statusEl.classList.toggle('status-online', running);
        statusEl.classList.toggle('status-offline', !running);
        statusEl.innerHTML = `<span class="indicator-dot">●</span> ${running ? 'Connected' : 'Disconnected'}`;
    } catch (err) {
        logWarn('Failed to poll main app status:', err);
    }
}

function startMainAppStatusPolling() {
    updateMainAppStatus();
    setInterval(updateMainAppStatus, MAIN_APP_STATUS_POLL_MS);
}

async function loadAppVersion() {
    try {
        const data = JSON.parse(await webui.call('getConfigData'));
        const versionEl = document.getElementById('app-version');
        if (versionEl && data.version) {
            versionEl.textContent = data.version;
        }
    } catch (error) {
        logWarn('Failed to load app version:', error);
    }
}

async function loadConfigurationFromBackend() {
    console.log('Loading configuration from backend...');
    showStatus(t('status.loadingConfig'), 'info');

    try {
        if (typeof webui !== 'undefined') {
            const configJson = await webui.call('loadConfig');
            currentConfig = JSON.parse(configJson);
            populateFormFields();
            markAsSaved();
            showStatus(t('status.loaded'), 'success');
            setTimeout(() => hideStatus(), 3000);
        } else {
            logWarn('WebUI not available, using mock data');
            loadMockConfiguration();
        }
    } catch (error) {
        logError('Failed to load configuration:', error);
        showStatus(t('status.failedPrefix') + error.message, 'error');
    }
}

// Deliberately not awaited before the first render - consumers of defaultConfig fall back to their hardcoded literal until this resolves.
async function loadDefaultConfig() {
    try {
        if (typeof webui === 'undefined') return;
        const json = await webui.call('getDefaultConfig');
        defaultConfig = JSON.parse(json);
        applyBackendDefaultColors();
        refreshNotificationColorDefaults();
    } catch (error) {
        logError('Failed to load default config:', error);
    }
}

// Upgrades the swatches' static data-default-color (see initCustomColorPicker's "Clear to Default") to the real backend value once fetched.
function applyBackendDefaultColors() {
    if (!defaultConfig) return;
    const map = {
        borderColor: defaultConfig.thumbnail?.borderColor,
        inactiveBorderColor: defaultConfig.thumbnail?.inactiveBorderColor,
        textColor: defaultConfig.thumbnail?.textColor,
        systemNameColor: defaultConfig.thumbnail?.systemNameColor,
        textBgColor: defaultConfig.thumbnail?.textBgColor,
        exclusionOverlayColor: defaultConfig.thumbnail?.exclusionOverlayColor,
        combatIncomingColor: defaultConfig.combat?.incoming_color,
        combatOutgoingColor: defaultConfig.combat?.outgoing_color,
        combatIconColor: defaultConfig.combat?.icon_color,
        miningColor: defaultConfig.mining?.color,
        bountyColor: defaultConfig.bounty?.color,
    };
    for (const [id, value] of Object.entries(map)) {
        if (value == null) continue;
        const el = document.getElementById(id);
        if (el) el.dataset.defaultColor = zigColorToHtml(value);
    }
}

// Same idea as applyBackendDefaultColors(), for the notification table's per-type text/border swatches.
function refreshNotificationColorDefaults() {
    if (!defaultConfig) return;
    const textDefault = notifDefaultTextColorHtml();
    const borderDefault = notifDefaultBorderColorHtml();
    document.querySelectorAll('input[id$="_textColor"][data-optional-color]').forEach(el => {
        el.dataset.defaultColor = textDefault;
    });
    document.querySelectorAll('input[id$="_borderColor"][data-optional-color]').forEach(el => {
        el.dataset.defaultColor = borderDefault;
    });
}

function loadMockConfiguration() {
    currentConfig = {
        timer: { scanIntervalMs: 1000 },
        thumbnail: {
            width: 200,
            height: 112,
            thumbnailOpacity: 255,
            applyOpacityToOverlayTexts: false,
            borderWidth: 2,
            borderColor: 0xFF606060,
            textBgColorInheritBorderColor: false,
            textBgColor: 0x80000000,
            textColor: 0xFFFFFF
        },
        display: {
            startX: 10,
            startY: 10,
            spacing: 10,
            listViewOrder: 'Tracked',
            rememberListViewPosition: true,
            listViewOpacity: 255
        },
        notifications: {
            position: 'TopRight'
        }
    };
    populateFormFields();
    markAsSaved();
}

function populateFormFields() {
    if (!currentConfig) return;

    applyConfigSchemaToForm();
    applySpecialFieldsToForm();

    // Order-independent: each just reads fields already populated above and adjusts unrelated elements' disabled state.
    toggleSnappingOptions();
    toggleBorderOptions();
    toggleFocusedBorderOptions();
    toggleInactiveBorderOptions();
    toggleTextDisplayOptions();
    toggleCharacterNameOptions();
    toggleSystemNameOptions();
    toggleQuickGroupBadgeOptions();
    toggleUniqueSystemColors();
    toggleUniqueCharacterNameColors();
    toggleClientListOptions();
    toggleAutoMinimizeOptions();
    toggleTextBgColorOptions();
    toggleTtsOptions();
    toggleNotificationOptions();
    toggleChatlogOptions();
    toggleCombatOptions();
    toggleMiningOptions();
    toggleBountyOptions();

    populateWindowFilters();

    const hasFilters = currentConfig.windowFilters && currentConfig.windowFilters.length > 0;
    setCheckboxValue('windowFiltersEnabled', hasFilters);
    toggleWindowFilters();

    populateSystemColors();
    populateCharacters();
    populateHotkeyGroups();
    populateQuickGroups();
    populateNotificationTypes();

    console.log('Form fields populated');
}

function setFieldValue(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;

    // A missing/null value means nothing is set for this field - clear it rather than leaving the previous profile's value.
    if (value === undefined || value === null) {
        field.value = field.type === 'color' ? zigColorToHtml(null) : '';
        return;
    }

    if (field.type === 'color') {
        field.value = zigColorToHtml(value);
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

// Opacity is stored internally as 0-255 (matches the win32 alpha channel) but shown in the UI as a 0-100% slider
function opacityToPercent(value) {
    return Math.round(Math.max(0, Math.min(255, value)) / 255 * 100);
}

function percentToOpacity(percent) {
    return Math.round(Math.max(0, Math.min(100, percent)) / 100 * 255);
}

function getFieldValue(fieldId) {
    const field = document.getElementById(fieldId);
    if (!field) return null;

    if (field.type === 'number' || field.type === 'range') {
        const value = parseInt(field.value) || 0;
        const range = FIELD_RANGES[fieldId];
        return range ? Math.min(range.max, Math.max(range.min, value)) : value;
    }
    if (field.type === 'checkbox') {
        return field.checked;
    }
    if (field.type === 'color') {
        return htmlColorToZig(field.value);
    }
    return field.value;
}

// Empty means null; 0 is returned as a value, not treated as empty.
function getNullableFieldValue(fieldId) {
    const field = document.getElementById(fieldId);
    if (!field) return null;

    if (field.value === '' || field.value === null || field.value === undefined) {
        return null;
    }

    const parsed = parseInt(field.value);
    return isNaN(parsed) ? null : parsed;
}

async function loadProfileList() {
    try {
        if (typeof webui !== 'undefined') {
            const response = await webui.call('listProfiles');
            const data = JSON.parse(response);
            
            const profileSelect = document.getElementById('profile-select');
            profileSelect.innerHTML = '';
            
            if (data.profiles && data.profiles.length > 0) {
                data.profiles.forEach(profile => {
                    const option = document.createElement('option');
                    option.value = profile;
                    option.textContent = profile.replace(/\.json$/, '');
                    if (profile === data.current) {
                        option.selected = true;
                    }
                    profileSelect.appendChild(option);
                });
            } else {
                const option = document.createElement('option');
                option.value = 'default.json';
                option.textContent = t('common.defaultProfileLabel');
                profileSelect.appendChild(option);
            }
            
            console.log('Loaded', data.profiles.length, 'profiles');
        }
    } catch (error) {
        logError('Failed to load profile list:', error);
    }
}

// deferLivePush skips the immediate switchProfileLive call for a profile runImport() just created (still empty) - runImport() does the actual live push once it has real data to save.
async function switchProfile(deferLivePush = false) {
    const profileSelect = document.getElementById('profile-select');
    const selectedProfile = profileSelect.value;
    let liveChoice = null;

    // Ask before making it live, since that means an immediate thumbnail/hotkey/chatlog reload in the running app.
    if (dialogEditingProfile && selectedProfile !== dialogEditingProfile) {
        const choice = await showLiveSwitchModal(selectedProfile);
        liveChoice = choice;
        if (choice === 'cancel') {
            profileSelect.value = dialogEditingProfile;
            return choice;
        }
        if (choice === 'live') {
            if (deferLivePush) {
                liveConfirmedProfile = selectedProfile;
            } else {
                try {
                    if (typeof webui !== 'undefined') {
                        await webui.call('switchProfileLive', selectedProfile);
                    }
                    liveConfirmedProfile = selectedProfile;
                } catch (error) {
                    logError('Failed to make profile live:', error);
                    showStatus(t('status.makeProfileLiveFailedPrefix') + error.message, 'error');
                }
            }
        }
        // choice === 'edit' -> leave liveConfirmedProfile as-is, so preview stays suppressed until confirmed live or saved.
    }

    console.log('Switching to profile:', selectedProfile);
    showStatus(t('status.switchingToProfilePrefix') + selectedProfile.replace(/\.json$/, '') + '...', 'info');

    try {
        if (typeof webui !== 'undefined') {
            const response = await webui.call('switchProfile', selectedProfile);
            const result = JSON.parse(response);

            if (result.success) {
                // Keep the in-memory snapshot in sync so a later Save doesn't overwrite the backend's lastUsedProfile update with a stale value.
                if (!currentGlobalSettings) currentGlobalSettings = {};
                currentGlobalSettings.lastUsedProfile = selectedProfile;
                dialogEditingProfile = selectedProfile;

                showStatus(t('status.profileSwitchedSuccess'), 'success');
                await loadConfigurationFromBackend();
                setTimeout(() => hideStatus(), 3000);
            } else {
                showStatus(t('status.switchProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
            }
        } else {
            showStatus(t('status.mockSwitchPrefix') + selectedProfile, 'info');
            setTimeout(() => hideStatus(), 3000);
        }
    } catch (error) {
        logError('Failed to switch profile:', error);
        showStatus(t('status.switchProfileFailedPrefix') + error.message, 'error');
    }

    return liveChoice;
}

function showLiveSwitchModal(selectedProfile) {
    return new Promise((resolve) => {
        const modal = document.getElementById('live-switch-modal');
        const message = document.getElementById('live-switch-message');
        const liveBtn = document.getElementById('live-switch-modal-live');
        const editBtn = document.getElementById('live-switch-modal-edit');
        const cancelBtn = document.getElementById('live-switch-modal-cancel');

        message.textContent = t('status.liveSwitchConfirm').replace('{name}', selectedProfile.replace(/\.json$/, ''));

        // All .modal elements share the same z-index, so DOM order decides who paints on top; re-parent to the end of <body> to stay above other open modals.
        document.body.appendChild(modal);
        modal.classList.add('show');

        const handle = (choice) => {
            cleanup();
            resolve(choice);
        };
        const handleLive = () => handle('live');
        const handleEdit = () => handle('edit');
        const handleCancel = () => handle('cancel');
        const handleKeyDown = (e) => {
            if (e.key === 'Escape') {
                e.preventDefault();
                handleCancel();
            }
        };
        const handleClickOutside = (e) => {
            if (e.target === modal) handleCancel();
        };

        const cleanup = () => {
            modal.classList.remove('show');
            liveBtn.removeEventListener('click', handleLive);
            editBtn.removeEventListener('click', handleEdit);
            cancelBtn.removeEventListener('click', handleCancel);
            document.removeEventListener('keydown', handleKeyDown);
            modal.removeEventListener('click', handleClickOutside);
        };

        liveBtn.addEventListener('click', handleLive);
        editBtn.addEventListener('click', handleEdit);
        cancelBtn.addEventListener('click', handleCancel);
        document.addEventListener('keydown', handleKeyDown);
        modal.addEventListener('click', handleClickOutside);
    });
}

async function createNewProfile() {
    const profileName = await showProfileNameModal('Create New Profile', '');
    if (!profileName) return;
    
    const sanitizedName = profileName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
    if (sanitizedName === '') {
        showStatus(t('status.invalidProfileName'), 'error');
        return;
    }
    
    showStatus(t('status.creatingProfile'), 'info');
    
    try {
        if (typeof webui !== 'undefined') {
            const response = await webui.call('createProfile', sanitizedName);
            const result = JSON.parse(response);
            
            if (result.success) {
                showStatus(t('status.profileCreatedSuccess'), 'success');
                await loadProfileList();
                
                const profileSelect = document.getElementById('profile-select');
                profileSelect.value = sanitizedName + '.json';
                await switchProfile();
            } else {
                showStatus(t('status.createProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
            }
        } else {
            showStatus(t('status.mockCreateProfilePrefix') + sanitizedName, 'info');
            setTimeout(() => hideStatus(), 3000);
        }
    } catch (error) {
        logError('Failed to create profile:', error);
        showStatus(t('status.createProfileFailedPrefix') + error.message, 'error');
    }
}

async function copyCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    const currentDisplayName = currentProfile.replace(/\.json$/, '');
    
    const newName = await showProfileNameModal(`Copy Profile: ${currentDisplayName}`, currentDisplayName + ' - Copy');
    if (!newName) return;
    
    const sanitizedName = newName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
    if (sanitizedName === '') {
        showStatus(t('status.invalidProfileName'), 'error');
        return;
    }
    
    showStatus(t('status.copyingProfile'), 'info');
    
    try {
        if (typeof webui !== 'undefined') {
            const payload = JSON.stringify({
                source: currentProfile,
                target: sanitizedName
            });
            const response = await webui.call('copyProfile', payload);
            const result = JSON.parse(response);
            
            if (result.success) {
                showStatus(t('status.profileCopiedSuccess'), 'success');
                await loadProfileList();
                
                profileSelect.value = sanitizedName + '.json';
                await switchProfile();
            } else {
                showStatus(t('status.copyProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
            }
        } else {
            showStatus(t('status.mockCopyPrefix') + currentProfile + t('status.mockCopyMiddle') + sanitizedName, 'info');
            setTimeout(() => hideStatus(), 3000);
        }
    } catch (error) {
        logError('Failed to copy profile:', error);
        showStatus(t('status.copyProfileFailedPrefix') + error.message, 'error');
    }
}

let importParsedData = null;
let importFormat = null;

// Must match config.zig's PROFILE_FORMAT_IDENTIFIER, stamped onto every profile this app saves so it can be recognized outright instead of guessed at like the legacy formats below.
const MAJ_FORMAT_IDENTIFIER = 'eve-maj-preview';

function escapeHtml(str) {
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

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

function zigColorWithAlpha(zigColorHex, alpha0to255) {
    if (!zigColorHex) return null;
    const rgb = zigColorHex.replace(/^0x/i, '').slice(-6).toUpperCase();
    const a = Math.max(0, Math.min(255, Math.round(alpha0to255))).toString(16).toUpperCase().padStart(2, '0');
    return '0x' + a + rgb;
}

// Defaults to fully opaque if no alpha channel is present (e.g. "0xRRGGBB").
function zigColorAlpha(zigColorHex) {
    if (!zigColorHex) return 255;
    const hex = typeof zigColorHex === 'number' ? zigColorHex.toString(16).padStart(8, '0') : String(zigColorHex).replace(/^0x/i, '');
    if (hex.length < 8) return 255;
    return parseInt(hex.slice(0, 2), 16);
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
    const hasThumbAppearance = Object.keys(ts).length > 0 || Object.keys(tsl).length > 0;

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

    return [
        { id: 'thumbnailAppearance', title: 'Thumbnail Appearance', hint: 'Border colors/thickness, text overlay, opacity', available: hasThumbAppearance },
        { id: 'characterPositions', title: 'Character Positions & Sizes', hint: `${Object.keys(positions).length} character(s) with saved positions`, available: hasPositions },
        { id: 'characterColorsHotkeys', title: 'Character Colors & Hotkeys', hint: `${charNames.length} custom color(s), ${hotkeysArr.length} character hotkey(s)`, available: hasColorsOrHotkeys },
        { id: 'hotkeyGroups', title: 'Hotkey Groups', hint: `${Object.keys(groups).length} group(s)`, available: hasGroups },
        { id: 'autoMinimize', title: 'Auto-Minimize', hint: 'Minimize inactive clients + excluded characters', available: hasAutoMinimize },
        { id: 'snapping', title: 'Snapping & Suspend Hotkey', hint: 'Thumbnail snapping + global suspend-hotkeys key', available: hasSnapping },
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
        <label style="display: block; margin: 4px 0;">
            <input type="checkbox" id="import_${s.id}" ${s.available ? 'checked' : 'disabled'}>
            <span class="label-body">${escapeHtml(s.title)}</span>
        </label>
        <p class="hint" style="margin: 0 0 6px 22px;">${escapeHtml(s.available ? s.hint : 'Nothing to import for this section')}</p>
    `).join('');
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
    if (textColor) patch.textColor = textColor;
    if (ts.ThumbnailTextFont) patch.textFontName = String(ts.ThumbnailTextFont);
    if (num(ts.ThumbnailTextSize) !== null) patch.textFontSize = num(ts.ThumbnailTextSize);

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

    return { patch, notes: ['Thumbnail appearance settings imported.'] };
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
    return { characterPatches, notes: [`Imported saved position/size for ${characterPatches.length} character(s).`] };
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
        if (names.length > 0) notes.push(`Imported custom border colors for ${names.length} character(s).`);
        if (Array.isArray(cc.cColors.TextColor) && cc.cColors.TextColor.length > 0) {
            notes.push('Per-character text color is not supported in EVE-Maj Preview and was not imported.');
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
                notes.push(`Skipped hotkey for "${name}": "${raw}" can't be represented as a keyboard hotkey (mouse buttons/custom combinations aren't supported).`);
            }
            byName.set(name, patchEntry);
        });
    });
    if (hotkeysArr.length > 0) notes.push(`Converted ${convertedCount} of ${hotkeysArr.length} character hotkey(s).`);

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
            notes.push(`Hotkey group "${name}": forward key "${g.ForwardsHotkey}" can't be converted.`);
        }
        if (g.BackwardsHotkey && !backwardKey) {
            notes.push(`Hotkey group "${name}": backward key "${g.BackwardsHotkey}" can't be converted.`);
        }
        hotkeyGroups.push({ name, characters, forwardKey: forwardKey || null, backwardKey: backwardKey || null });
    });
    notes.unshift(`Imported ${hotkeyGroups.length} hotkey group(s).`);
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
    return { patch, characterPatches, notes: ['Auto-minimize settings imported.'] };
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
            notes.push(`Suspend-hotkeys key "${suspendRaw}" can't be converted and was skipped.`);
        }
    }
    notes.push('Snapping settings imported.');
    return { snappingPatch, hotkeysPatch, notes };
}

// Matches by name so patches from different sections don't clobber each other's fields; creates a new entry if the name isn't already present.
function mergeCharacterPatch(cfg, characterPatches) {
    if (!cfg.characters) cfg.characters = [];
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
        { id: 'thumbnailAppearance', title: 'Thumbnail Appearance', hint: 'Border/text colors, opacity, font', available: hasThumbAppearance },
        { id: 'characterPositions', title: 'Character Positions', hint: `${Object.keys(positions).length} character(s) with saved positions`, available: hasPositions },
        { id: 'characterColors', title: 'Character Colors & Hotkeys', hint: `${Object.keys(colors).length} custom color(s), ${Object.keys(hotkeys).length} character hotkey(s)`, available: hasColors },
        { id: 'hotkeyGroups', title: 'Hotkey Groups', hint: `${Object.keys(groups).length} group(s)`, available: hasGroups },
        { id: 'globalHotkeys', title: 'Global Hotkeys & Behavior', hint: 'Close/minimize-all, toggle visibility, suspend, EVE-focus requirement', available: hasGlobalHotkeys },
        { id: 'autoMinimize', title: 'Auto-Minimize', hint: 'Minimize inactive clients + excluded characters', available: hasAutoMinimize },
        { id: 'snapping', title: 'Snapping', hint: 'Thumbnail snapping', available: hasSnapping },
        { id: 'chatlog', title: 'Chatlog Monitoring', hint: 'Chatlog/gamelog folders', available: hasChatlog },
        { id: 'notifications', title: 'Fleet/Event Notifications', hint: 'Fleet invite, decloak, mining, etc.', available: hasNotifications },
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
    notes.push(`${label} border style "${name}" has no equivalent in EVE-Maj Preview and was not imported.`);
    return null;
}

function apmExtractThumbnailAppearance(sections) {
    const ui = sections['ui'] || {};
    const overlay = sections['overlay'] || {};
    const thumb = sections['thumbnail'] || {};
    const patch = {};
    const notes = ['Thumbnail appearance settings imported.'];
    const num = (v) => (v === undefined || v === null || v === '' || isNaN(Number(v))) ? null : Number(v);

    const borderColor = legacyColorToZig(ui.highlightColor);
    if (borderColor) patch.borderColor = borderColor;
    if (num(ui.highlightBorderWidth) !== null) patch.borderWidth = num(ui.highlightBorderWidth);
    if ('highlightActiveWindow' in ui) patch.showBorderWhenFocused = parseQtBool(ui.highlightActiveWindow);
    if ('hideThumbnailsWhenEVENotFocused' in ui) patch.hideWhenNoEveFocus = parseQtBool(ui.hideThumbnailsWhenEVENotFocused);
    if ('hideActiveClientThumbnail' in ui) patch.activeThumbnailHidden = parseQtBool(ui.hideActiveClientThumbnail);
    if ('activeBorderStyle' in ui) {
        const style = apmBorderStyleToZig(ui.activeBorderStyle, notes, 'Active');
        if (style) patch.borderStyle = style;
    }

    const inactiveColor = legacyColorToZig(ui.inactiveBorderColor);
    if (inactiveColor) patch.inactiveBorderColor = inactiveColor;
    if (num(ui.inactiveBorderWidth) !== null) patch.inactiveBorderWidth = num(ui.inactiveBorderWidth);
    if ('showInactiveBorders' in ui) patch.showBorderWhenInactive = parseQtBool(ui.showInactiveBorders);
    if ('inactiveBorderStyle' in ui) {
        const style = apmBorderStyleToZig(ui.inactiveBorderStyle, notes, 'Inactive');
        if (style) patch.inactiveBorderStyle = style;
    }

    if ('showCharacterName' in overlay) patch.showCharacterName = parseQtBool(overlay.showCharacterName);
    if ('showSystemName' in overlay) patch.showSystemName = parseQtBool(overlay.showSystemName);
    if ('showCharacterName' in overlay || 'showSystemName' in overlay) {
        patch.showText = !!(patch.showCharacterName || patch.showSystemName);
    }

    const charColor = legacyColorToZig(overlay.characterNameColor);
    if (charColor) patch.textColor = charColor;
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
        patch.textBgColor = zigColorWithAlpha(bgColor, alpha255);
    }

    const font = parseQtFont(overlay.font);
    if (font) {
        if (font.family) patch.textFontName = font.family;
        if (font.size) patch.textFontSize = font.size;
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
    const notes = [`Imported saved position for ${characterPatches.length} character(s).`];
    if (skipped > 0) notes.push(`Skipped ${skipped} non-EVE window item(s) (tracked via EVE-APM's non-EVE window overlay - not real characters).`);
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
    const notes = [`Imported ${characterPatches.filter(c => c.borderColors).length} custom border color(s).`];
    if (hotkeyKeys.length > 0) {
        notes.push(`Converted ${convertedHotkeys} of ${hotkeyKeys.length} character hotkey(s) (decoded from EVE-APM Preview's internal hotkey format).`);
    }
    if (skipped > 0) notes.push(`Skipped ${skipped} non-EVE window item(s) (tracked via EVE-APM's non-EVE window overlay - not real characters).`);
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
            notes.push(`Hotkey group "${name}": forward/backward key(s) were decoded from EVE-APM Preview's internal hotkey format - please confirm they're correct.`);
        }
        if (!forwardKey && isApmHotkeyTupleEnabled(forwardRaw)) {
            notes.push(`Hotkey group "${name}": forward key can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.`);
        }
        if (!backwardKey && isApmHotkeyTupleEnabled(backwardRaw)) {
            notes.push(`Hotkey group "${name}": backward key can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.`);
        }
    });
    notes.unshift(`Imported ${hotkeyGroups.length} hotkey group(s).`);
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
            notes.push(`${label} hotkey can't be represented as a keyboard hotkey (mouse button or unsupported) and was skipped.`);
        }
        if (enabledTuples.length > 1) {
            notes.push(`${label} had ${enabledTuples.length} bound keys in EVE-APM Preview - only the first is imported (EVE-Maj Preview supports one hotkey per action).`);
        }
    };
    tryKey('closeAllHotkeys', 'closeAllClients', 'hotkeyCloseAll', 'Close-all-clients');
    tryKey('minimizeAllHotkeys', 'minimizeAllClients', 'hotkeyMinimizeAll', 'Minimize-all-clients');
    tryKey('toggleThumbnailsVisibilityHotkeys', 'toggleThumbnailsVisibility', 'hotkeyToggleVisibility', 'Toggle-thumbnails-visibility');
    tryKey('hotkeys', 'suspendHotkey', 'hotkeySuspend', 'Suspend-hotkeys');

    const hk = sections['hotkey'] || {};
    if ('onlyWhenEVEFocused' in hk) patch.requireEveFocus = parseQtBool(hk.onlyWhenEVEFocused);
    if ('resetGroupIndexOnNonGroupFocus' in hk) patch.resetGroupIndexOnNonGroupFocus = parseQtBool(hk.resetGroupIndexOnNonGroupFocus);

    notes.push('Global action hotkeys imported.');
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
    return { patch, characterPatches, notes: ['Auto-minimize settings imported.'] };
}

function apmExtractSnapping(sections) {
    const pos = sections['position'] || {};
    const patch = {};
    if ('enableSnapping' in pos) patch.enabled = parseQtBool(pos.enableSnapping);
    const dist = parseInt(pos.snapDistance, 10);
    if (Number.isFinite(dist)) patch.threshold = dist;
    return { patch, notes: ['Snapping settings imported.'] };
}

function apmExtractChatlog(sections) {
    const chat = sections['chatlog'] || {};
    const game = sections['gamelog'] || {};
    const patch = {};
    if ('enableMonitoring' in chat) patch.enabled = parseQtBool(chat.enableMonitoring);
    if (chat.directory) patch.chatlogDir = chat.directory.trim();
    if (game.directory) patch.gamelogDir = game.directory.trim();
    return { patch, notes: ['Chatlog monitoring settings imported.'] };
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
            notes.push(`Event type "${evt}" has no equivalent notification in EVE-Maj Preview and was not imported.`);
            return;
        }
        const dur = parseInt(cm[`eventDurations\\${evt}`], 10);
        const typePatch = { enabled: true };
        typePatch.duration_ms = Number.isFinite(dur) ? dur : (Number.isFinite(defaultDuration) ? defaultDuration : undefined);
        if (color) typePatch.border_color = color;
        typePatches[target] = typePatch;
        mapped++;
    });

    if (enabledList.length > 0) notes.push(`Imported ${mapped} of ${enabledList.length} event notification type(s).`);
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
        { id: 'thumbnailAppearance', title: 'Thumbnail Appearance', hint: 'Border color/thickness, text overlay, opacity', available: hasThumbAppearance },
        { id: 'characterPositions', title: 'Character Positions & Sizes', hint: `${positionKeys.size} character(s) with saved positions`, available: hasPositions },
        { id: 'characterColors', title: 'Character Colors & Hotkeys', hint: `${colorKeys.length} custom color(s), ${hotkeyKeys.length} character hotkey(s)`, available: hasColors },
        { id: 'hotkeyGroups', title: 'Hotkey Groups', hint: `${groupCount} group(s)`, available: hasGroups },
        { id: 'autoMinimize', title: 'Auto-Minimize', hint: 'Minimize inactive clients', available: hasAutoMinimize },
        { id: 'snapping', title: 'Snapping', hint: 'Thumbnail snapping', available: hasSnapping },
    ];
}

function eveoExtractThumbnailAppearance(data) {
    const patch = {};
    const notes = ['Thumbnail appearance settings imported.'];

    if (typeof data.ThumbnailsOpacity === 'number') {
        patch.thumbnailOpacity = Math.max(0, Math.min(255, Math.round(data.ThumbnailsOpacity * 255)));
    }
    if ('EnableActiveClientHighlight' in data) patch.showBorderWhenFocused = !!data.EnableActiveClientHighlight;
    if (data.ActiveClientHighlightColor) {
        const borderColor = eveoColorToZig(data.ActiveClientHighlightColor);
        if (borderColor) patch.borderColor = borderColor;
        else notes.push(`Active client highlight color "${data.ActiveClientHighlightColor}" wasn't recognized and was skipped.`);
    }
    if (typeof data.ActiveClientHighlightThickness === 'number') patch.borderWidth = data.ActiveClientHighlightThickness;

    // EVE-O Preview has one "show borders on all thumbnails" toggle rather than separate active/inactive settings - maps to showBorderWhenInactive.
    if ('ShowThumbnailFrames' in data) patch.showBorderWhenInactive = !!data.ShowThumbnailFrames;
    if ('ShowThumbnailOverlays' in data) patch.showText = !!data.ShowThumbnailOverlays;

    if (data.OverlayLabelColor) {
        const textColor = eveoColorToZig(data.OverlayLabelColor);
        if (textColor) patch.textColor = textColor;
        else notes.push(`Overlay label color "${data.OverlayLabelColor}" wasn't recognized and was skipped.`);
    }
    if (typeof data.OverlayLabelSize === 'number') patch.textFontSize = data.OverlayLabelSize;
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
    const notes = [`Imported saved position/size for ${characterPatches.length} character(s).`];
    if (skippedNames.size > 0) notes.push(`Skipped ${skippedNames.size} placeholder item(s) from EVE-O Preview's default config - not real characters.`);
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
    const notes = [`Imported ${colorCount} custom border color(s).`];
    if (hotkeyKeys.length > 0) notes.push(`Converted ${convertedHotkeys} of ${hotkeyKeys.length} character hotkey(s).`);
    if (skippedNames.size > 0) notes.push(`Skipped ${skippedNames.size} placeholder item(s) from EVE-O Preview's default config - not real characters.`);
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
        const name = `Cycle Group ${n}`;
        hotkeyGroups.push({ name, characters, forwardKey, backwardKey });

        if (forwardBound.length > 0 && !forwardKey) notes.push(`Hotkey group "${name}": forward key "${forwardBound[0]}" can't be converted.`);
        if (backwardBound.length > 0 && !backwardKey) notes.push(`Hotkey group "${name}": backward key "${backwardBound[0]}" can't be converted.`);
        if (forwardBound.length > 1 || backwardBound.length > 1) {
            notes.push(`Hotkey group "${name}" had multiple bound keys in EVE-O Preview - only the first usable one is imported.`);
        }
    });

    notes.unshift(`Imported ${hotkeyGroups.length} hotkey group(s).`);
    return { hotkeyGroups, notes };
}

function eveoExtractAutoMinimize(data) {
    const patch = {};
    if ('MinimizeInactiveClients' in data) patch.enabled = !!data.MinimizeInactiveClients;
    return { patch, notes: ['Auto-minimize settings imported.'] };
}

function eveoExtractSnapping(data) {
    const snappingPatch = {};
    if ('EnableThumbnailSnap' in data) snappingPatch.enabled = !!data.EnableThumbnailSnap;
    return { snappingPatch, notes: ['Snapping settings imported.'] };
}

// Unlike the legacy formats above, a maj-format file already has exactly currentConfig's shape, so no field-by-field translation is needed, just a per-section merge.
const MAJ_SECTIONS = [
    { id: 'thumbnail', title: 'Thumbnail Appearance & Notifications', hint: 'Border/text styling, per-state visuals, alert notifications', kind: 'object' },
    { id: 'display', title: 'Display', hint: 'List view appearance', kind: 'object' },
    { id: 'timer', title: 'Scan Timer', hint: 'Window scan interval', kind: 'object' },
    { id: 'interaction', title: 'Interaction', hint: 'Click/drag behavior', kind: 'object' },
    { id: 'snapping', title: 'Snapping', hint: 'Thumbnail snapping', kind: 'object' },
    { id: 'autoMinimize', title: 'Auto-Minimize', hint: 'Minimize inactive clients', kind: 'object' },
    { id: 'closeAll', title: 'Close All', hint: 'Close-all behavior', kind: 'object' },
    { id: 'chatlog', title: 'Chatlog Monitoring', hint: 'Chat/game log directories and triggers', kind: 'object' },
    { id: 'combat', title: 'Combat Tracker', hint: 'Combat log parsing', kind: 'object' },
    { id: 'mining', title: 'Mining Tracker', hint: 'Mining log parsing', kind: 'object' },
    { id: 'bounty', title: 'Bounty Tracker', hint: 'Bounty log parsing', kind: 'object' },
    { id: 'hotkeys', title: 'Global Hotkeys', hint: 'App-wide hotkeys', kind: 'object' },
    { id: 'characters', title: 'Characters', hint: 'Positions, sizes, colors, hotkeys', kind: 'array' },
    { id: 'systemColors', title: 'System Colors', hint: 'Per-system border colors', kind: 'array' },
    { id: 'hotkeyGroups', title: 'Hotkey Groups', hint: 'Character cycling groups', kind: 'array' },
    { id: 'windowFilters', title: 'Window Filters', hint: 'Custom EVE window matching rules', kind: 'array' },
];

function computeMajImportSections(data) {
    return MAJ_SECTIONS.map(s => {
        if (s.kind === 'array') {
            const arr = Array.isArray(data[s.id]) ? data[s.id] : [];
            return { id: s.id, title: s.title, hint: `${s.hint} (${arr.length})`, available: arr.length > 0 };
        }
        return { id: s.id, title: s.title, hint: s.hint, available: data[s.id] !== undefined && data[s.id] !== null };
    });
}

// Merges by name/systemName so re-running an import updates matching entries in place instead of duplicating them; unlike mergeCharacterPatch, imported items are already full entries so this overwrites wholesale.
function mergeMajByKey(list, imported, keyField) {
    imported.forEach(item => {
        const key = (item[keyField] || '').trim();
        if (!key) return;
        const idx = list.findIndex(x => (x[keyField] || '').trim().toLowerCase() === key.toLowerCase());
        if (idx === -1) list.push(item);
        else list[idx] = Object.assign({}, list[idx], item);
    });
}

function applyMajImport(checked, allNotes) {
    const data = importParsedData;

    MAJ_SECTIONS.filter(s => s.kind === 'object').forEach(s => {
        if (!checked(s.id) || !data[s.id]) return;
        currentConfig[s.id] = Object.assign({}, currentConfig[s.id], data[s.id]);
        allNotes.push(`${s.title} imported.`);
    });

    if (checked('characters') && Array.isArray(data.characters)) {
        if (!currentConfig.characters) currentConfig.characters = [];
        mergeMajByKey(currentConfig.characters, data.characters, 'name');
        allNotes.push(`Imported ${data.characters.length} character(s).`);
    }
    if (checked('systemColors') && Array.isArray(data.systemColors)) {
        if (!currentConfig.systemColors) currentConfig.systemColors = [];
        mergeMajByKey(currentConfig.systemColors, data.systemColors, 'systemName');
        allNotes.push(`Imported ${data.systemColors.length} system color(s).`);
    }
    if (checked('hotkeyGroups') && Array.isArray(data.hotkeyGroups)) {
        if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
        mergeMajByKey(currentConfig.hotkeyGroups, data.hotkeyGroups, 'name');
        allNotes.push(`Imported ${data.hotkeyGroups.length} hotkey group(s).`);
    }
    if (checked('windowFilters') && Array.isArray(data.windowFilters)) {
        if (!currentConfig.windowFilters) currentConfig.windowFilters = [];
        mergeMajByKey(currentConfig.windowFilters, data.windowFilters, 'name');
        allNotes.push(`Imported ${data.windowFilters.length} window filter(s).`);
    }
}

function openImportModal() {
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

    const modal = document.getElementById('import-settings-modal');
    modal.classList.add('show');
}

function closeImportModal() {
    const modal = document.getElementById('import-settings-modal');
    modal.classList.remove('show');
}

async function handleImportFileSelected(event) {
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
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
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
            document.getElementById('importNewProfileName').value = (profileNames[0] || 'Imported').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');

            statusEl.textContent = t('status.detectedEvexFile').replace('{n}', profileNames.length);
        } else if (data && isEveoConfigData(data)) {
            importFormat = 'eveo';
            importParsedData = data;

            document.getElementById('importSourceProfileRow').style.display = 'none';
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
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
            const defaultName = file.name.replace(/\.(json|ini)$/i, '').trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
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

function onImportSourceProfileChanged() {
    if (importFormat !== 'evex' || !importParsedData) return;
    const select = document.getElementById('importSourceProfile');
    const profileName = select.value;

    const nameInput = document.getElementById('importNewProfileName');
    nameInput.value = profileName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');

    renderImportSections();
}

function onImportDestChanged() {
    const isNew = document.getElementById('import-dest-new').checked;
    document.getElementById('importNewProfileName').style.display = isNew ? '' : 'none';

    const profileSelect = document.getElementById('profile-select');
    const currentLabel = document.getElementById('importDestCurrentLabel');
    if (currentLabel && profileSelect && profileSelect.value) {
        currentLabel.textContent = t('status.currentProfilePrefix') + profileSelect.value.replace(/\.json$/, '') + ')';
    }
}

function applyEvexImport(checked, allNotes) {
    const select = document.getElementById('importSourceProfile');
    const oldProfile = importParsedData._Profiles[select.value] || {};
    const oldGlobal = importParsedData.global_Settings || {};

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = extractThumbnailAppearance(oldProfile, oldGlobal);
        currentConfig.thumbnail = Object.assign({}, currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = extractCharacterPositions(oldProfile);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColorsHotkeys')) {
        const { characterPatches, notes } = extractCharacterColorsAndHotkeys(oldProfile);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = extractHotkeyGroups(oldProfile);
        if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
        mergeMajByKey(currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, characterPatches, notes } = extractAutoMinimize(oldProfile, oldGlobal);
        currentConfig.autoMinimize = Object.assign({}, currentConfig.autoMinimize, patch);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { snappingPatch, hotkeysPatch, notes } = extractSnapping(oldProfile, oldGlobal);
        currentConfig.snapping = Object.assign({}, currentConfig.snapping, snappingPatch);
        currentConfig.hotkeys = Object.assign({}, currentConfig.hotkeys, hotkeysPatch);
        allNotes.push(...notes);
    }
}

function applyApmImport(checked, allNotes) {
    const sections = importParsedData;

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = apmExtractThumbnailAppearance(sections);
        currentConfig.thumbnail = Object.assign({}, currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = apmExtractCharacterPositions(sections);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColors')) {
        const { characterPatches, notes } = apmExtractCharacterColors(sections);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = apmExtractHotkeyGroups(sections);
        if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
        mergeMajByKey(currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('globalHotkeys')) {
        const { patch, notes } = apmExtractGlobalHotkeys(sections);
        currentConfig.hotkeys = Object.assign({}, currentConfig.hotkeys, patch);
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, characterPatches, notes } = apmExtractAutoMinimize(sections);
        currentConfig.autoMinimize = Object.assign({}, currentConfig.autoMinimize, patch);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { patch, notes } = apmExtractSnapping(sections);
        currentConfig.snapping = Object.assign({}, currentConfig.snapping, patch);
        allNotes.push(...notes);
    }
    if (checked('chatlog')) {
        const { patch, notes } = apmExtractChatlog(sections);
        currentConfig.chatlog = Object.assign({}, currentConfig.chatlog, patch);
        allNotes.push(...notes);
    }
    if (checked('notifications')) {
        const { notificationsPatch, typePatches, notes } = apmExtractNotifications(sections);
        if (!currentConfig.thumbnail.notifications) currentConfig.thumbnail.notifications = {};
        if (!currentConfig.thumbnail.notifications.type_configs) currentConfig.thumbnail.notifications.type_configs = {};
        Object.assign(currentConfig.thumbnail.notifications, notificationsPatch);
        Object.keys(typePatches).forEach(type => {
            currentConfig.thumbnail.notifications.type_configs[type] = Object.assign(
                {}, currentConfig.thumbnail.notifications.type_configs[type], typePatches[type]
            );
        });
        allNotes.push(...notes);
    }
}

function applyEveoImport(checked, allNotes) {
    const data = importParsedData;

    if (checked('thumbnailAppearance')) {
        const { patch, notes } = eveoExtractThumbnailAppearance(data);
        currentConfig.thumbnail = Object.assign({}, currentConfig.thumbnail, patch);
        allNotes.push(...notes);
    }
    if (checked('characterPositions')) {
        const { characterPatches, notes } = eveoExtractCharacterPositions(data);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('characterColors')) {
        const { characterPatches, notes } = eveoExtractCharacterColors(data);
        mergeCharacterPatch(currentConfig, characterPatches);
        allNotes.push(...notes);
    }
    if (checked('hotkeyGroups')) {
        const { hotkeyGroups, notes } = eveoExtractHotkeyGroups(data);
        if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
        mergeMajByKey(currentConfig.hotkeyGroups, hotkeyGroups, 'name');
        allNotes.push(...notes);
    }
    if (checked('autoMinimize')) {
        const { patch, notes } = eveoExtractAutoMinimize(data);
        currentConfig.autoMinimize = Object.assign({}, currentConfig.autoMinimize, patch);
        allNotes.push(...notes);
    }
    if (checked('snapping')) {
        const { snappingPatch, notes } = eveoExtractSnapping(data);
        currentConfig.snapping = Object.assign({}, currentConfig.snapping, snappingPatch);
        allNotes.push(...notes);
    }
}

async function runImport() {
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
            const sanitized = rawName.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '');
            if (sanitized === '') {
                showStatus(t('status.invalidNewProfileName'), 'error');
                runBtn.disabled = false;
                return;
            }

            const response = await webui.call('createProfile', sanitized);
            const result = JSON.parse(response);
            if (!result.success) {
                showStatus(t('status.createProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
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
            applyEvexImport(checked, allNotes);
        } else if (importFormat === 'eveo') {
            applyEveoImport(checked, allNotes);
        } else if (importFormat === 'maj') {
            applyMajImport(checked, allNotes);
        } else {
            applyApmImport(checked, allNotes);
        }

        populateFormFields();
        markAsChanged();

        if (autoSaveAfterImport) {
            await saveConfiguration();
        } else if (previewAfterImport) {
            await sendThumbnailPreview(true);
        }

        const hint = autoSaveAfterImport && !hasUnsavedChanges
            ? 'This profile is now live - the running app has been updated with these settings.'
            : 'Review the affected tabs, then click Save to keep these changes.';
        const summaryEl = document.getElementById('importSummary');
        summaryEl.innerHTML = '<h4 style="margin: 0 0 6px 0;">Import complete</h4>' +
            '<ul style="margin: 0; padding-left: 18px;">' +
            allNotes.map(n => `<li>${escapeHtml(n)}</li>`).join('') +
            '</ul>' +
            `<p class="hint" style="margin-top: 8px;">${hint}</p>`;
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

function showProfileNameModal(title, defaultValue = '') {
    return new Promise((resolve) => {
        const modal = document.getElementById('profile-name-modal');
        const titleEl = document.getElementById('profile-modal-title');
        const input = document.getElementById('profile-name-input');
        const okBtn = document.getElementById('profile-modal-ok');
        const cancelBtn = document.getElementById('profile-modal-cancel');
        
        titleEl.textContent = title;
        input.value = defaultValue;

        modal.classList.add('show');
        setTimeout(() => {
            input.focus();
            input.select();
        }, 100);

        const handleOk = () => {
            const value = input.value.trim();
            cleanup();
            resolve(value);
        };

        const handleCancel = () => {
            cleanup();
            resolve(null);
        };

        const handleKeyDown = (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                handleOk();
            } else if (e.key === 'Escape') {
                e.preventDefault();
                handleCancel();
            }
        };

        const handleClickOutside = (e) => {
            if (e.target === modal) {
                handleCancel();
            }
        };

        const cleanup = () => {
            modal.classList.remove('show');
            okBtn.removeEventListener('click', handleOk);
            cancelBtn.removeEventListener('click', handleCancel);
            input.removeEventListener('keydown', handleKeyDown);
            modal.removeEventListener('click', handleClickOutside);
        };

        okBtn.addEventListener('click', handleOk);
        cancelBtn.addEventListener('click', handleCancel);
        input.addEventListener('keydown', handleKeyDown);
        modal.addEventListener('click', handleClickOutside);
    });
}

function deleteCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    
    if (currentProfile === 'default.json') {
        showStatus(t('status.cannotDeleteDefaultProfile'), 'error');
        return;
    }
    
    confirmRemove('delete-profile-btn', async () => {
        showStatus(t('status.deletingProfile'), 'info');
        
        try {
            if (typeof webui !== 'undefined') {
                const response = await webui.call('deleteProfile', currentProfile);
                const result = JSON.parse(response);
                
                if (result.success) {
                    profileSelect.value = 'default.json';
                    await switchProfile();
                    await loadProfileList();

                    showStatus(t('status.profileDeletedSuccess'), 'success');
                    setTimeout(() => hideStatus(), 3000);
                } else {
                    showStatus(t('status.deleteProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
                }
            } else {
                showStatus(t('status.mockDeletePrefix') + currentProfile, 'info');
                setTimeout(() => hideStatus(), 3000);
            }
        } catch (error) {
            logError('Failed to delete profile:', error);
            showStatus(t('status.deleteProfileFailedPrefix') + error.message, 'error');
        }
    });
}

function resetCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    const currentDisplayName = currentProfile.replace(/\.json$/, '');

    confirmRemove('reset-profile-btn', async () => {
        showStatus(t('status.resettingProfile').replace('{name}', currentDisplayName), 'info');

        try {
            if (typeof webui !== 'undefined') {
                const response = await webui.call('resetProfile', currentProfile);
                const result = JSON.parse(response);

                if (result.success) {
                    await loadConfigurationFromBackend();
                    showStatus(t('status.profileResetDone').replace('{name}', currentDisplayName), 'success');
                    setTimeout(() => hideStatus(), 5000);
                } else {
                    showStatus(t('status.resetProfileFailedPrefix') + (result.error || t('status.unknownError')), 'error');
                }
            } else {
                showStatus(t('status.mockResetPrefix') + currentProfile, 'info');
                setTimeout(() => hideStatus(), 3000);
            }
        } catch (error) {
            logError('Failed to reset profile:', error);
            showStatus(t('status.resetProfileFailedPrefix') + error.message, 'error');
        }
    });
}

let isSavingConfig = false;

// Prevents a rapid double-click from firing two overlapping saves.
async function saveConfiguration() {
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
    console.log('Saving configuration...');
    showStatus(t('status.savingConfig'), 'info');

    if (currentConfig) {
        applyConfigSchemaFromForm();
        applySpecialFieldsFromForm();

        // The From-form pass just clamped/defaulted raw values into currentConfig - run the schema back the other way so the DOM reflects that outcome immediately, not after a reload.
        applyConfigSchemaToForm();
        applySpecialFieldsToForm();

        // Avoids overwriting positions changed by dragging thumbnails/the list view after the dialog was opened.
        await reloadLivePositions();

        for (const name of pendingCharacterNames.values()) addCharacterIfMissing(name);
        pendingCharacterNames.clear();

        saveWindowFilters();
        saveSystemColors();
        saveCharacters();
        saveHotkeyGroups();
        saveQuickGroups();
        saveNotificationTypes();
        saveProfileSwitchHotkeys();
        saveOreTable();

        if (!currentGlobalSettings) currentGlobalSettings = {};
        currentGlobalSettings.logLevel = getFieldValue('logLevel');
        currentGlobalSettings.language = getFieldValue('languageSelect') || 'en';
        currentGlobalSettings.hotkeyNextProfile = getFieldValue('hotkeyNextProfile') || null;
        currentGlobalSettings.hotkeyPreviousProfile = getFieldValue('hotkeyPreviousProfile') || null;
        currentGlobalSettings.hotkeyCycleAllClientsForward = getFieldValue('hotkeyCycleAllClientsForward') || null;
        currentGlobalSettings.hotkeyCycleAllClientsBackward = getFieldValue('hotkeyCycleAllClientsBackward') || null;
        currentGlobalSettings.cycleAllClientsRespectExclusions = getFieldValue('cycleAllClientsRespectExclusions');
        currentGlobalSettings.hotkeyCycleNotLoggedInForward = getFieldValue('hotkeyCycleNotLoggedInForward') || null;
        currentGlobalSettings.hotkeyCycleNotLoggedInBackward = getFieldValue('hotkeyCycleNotLoggedInBackward') || null;
    }

    const hotkeyConflicts = updateHotkeyConflictHighlights();
    if (hotkeyConflicts.length > 0) {
        switchTab('hotkeys');
        showHotkeyConflictModal(describeHotkeyConflicts(hotkeyConflicts));
        return;
    }

    try {
        if (typeof webui !== 'undefined') {
            // Must hit disk before saveConfig's reloadProfileInMainApp() blocks until the main app re-reads global.settings.json, or every reload picks up a stale generation.
            if (currentGlobalSettings) {
                await webui.call('saveGlobalSettings', JSON.stringify(currentGlobalSettings, null, 2));
            }

            const response = await webui.call('saveConfig', JSON.stringify(currentConfig, null, 2));
            const result = JSON.parse(response);

            if (result.success) {
                showStatus(t('status.configSavedSuccess'), 'success');
                setTimeout(() => hideStatus(), 3000);
                // Saving always pushes this profile live (see saveConfig's reloadProfileInMainApp()), so live preview can resume for it.
                liveConfirmedProfile = dialogEditingProfile;
                deletedCharacterNames.clear();
            } else {
                showStatus(t('status.saveFailedPrefix') + (result.error || t('status.unknownError')), 'error');
            }

            if (result && result.success) {
                markAsSaved();
            }
        } else {
            console.log('Would save:', currentConfig);
            showStatus(t('status.configSavedMock'), 'success');
            setTimeout(() => hideStatus(), 3000);
            markAsSaved();
        }
    } catch (error) {
        logError('Save failed:', error);
        showStatus(t('status.saveConfigFailedPrefix') + error.message, 'error');
    }
}

function showStatus(message, type) {
    const statusEl = document.getElementById('status-message');
    statusEl.textContent = message;
    statusEl.className = 'status-message ' + type;
    statusEl.style.display = 'block';
}

function hideStatus() {
    const statusEl = document.getElementById('status-message');
    statusEl.style.display = 'none';
}

// Mirrors the Zig-side writeVirtualKey() in virtual_keys.zig - keep these two in sync.
function friendlyBaseKeyName(vkCode) {
    if (vkCode >= 0x70 && vkCode <= 0x87) return 'F' + (vkCode - 0x70 + 1);
    if (vkCode >= 0x41 && vkCode <= 0x5A) return String.fromCharCode(vkCode);
    if (vkCode >= 0x30 && vkCode <= 0x39) return String.fromCharCode(vkCode);
    if (vkCode >= 0x60 && vkCode <= 0x69) return 'Numpad' + (vkCode - 0x60);
    // Spellings must match parseBaseKey() exactly since this text round-trips back through it on save.
    const named = {
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
function vkHexToFriendly(str) {
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

function renderHotkeyInputHtml(fieldId, value, placeholder) {
    return `<input type="text" id="${fieldId}" class="hotkey-input" value="${value}" placeholder="${placeholder}" readonly style="flex: 1; margin-bottom: 0;">
<button type="button" class="hotkey-clear-btn" onclick="clearHotkey('${fieldId}')" title="${t('common.hotkeyClear')}" style="margin-bottom: 0;">×</button>
<button type="button" class="hotkey-record-btn" onclick="recordHotkey('${fieldId}')" style="width: auto; margin-bottom: 0;">${t('common.hotkeyRecord')}</button>
<button type="button" class="hotkey-edit-btn" onclick="toggleManualHotkeyEdit('${fieldId}')" title="${t('common.hotkeyTypeDirectly')}" style="margin-bottom: 0;">✎</button>`;
}

// Every hotkey <input> carries the shared "hotkey-input" class so conflicts can be found across all of them without hardcoding each field's id.
function getAllHotkeyInputs() {
    return Array.from(document.querySelectorAll('input.hotkey-input'));
}

function normalizeHotkeyValue(value) {
    if (!value) return null;
    const v = value.trim();
    if (!v || v === 'Press keys...' || v === 'Waiting for input...') return null;
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

// Uses the field's <label for="..."> text if one exists, otherwise the name in its enclosing accordion/character panel, disambiguating forward/backward.
function hotkeyFieldLabel(input) {
    if (input.id) {
        const label = document.querySelector(`label[for="${input.id}"]`);
        if (label) return label.textContent.trim();
    }

    const charPanel = input.closest('.char-detail-panel');
    if (charPanel) {
        const nameEl = charPanel.querySelector('.char-detail-name');
        return (nameEl && nameEl.textContent.trim()) || 'Character';
    }

    const accordion = input.closest('.accordion');
    if (accordion) {
        const nameEl = accordion.querySelector('.accordion-name');
        const base = (nameEl && nameEl.textContent.trim()) || 'Item';

        // Groups can be renamed to anything, so the base name alone wouldn't tell the user this is a cycling key rather than a character/profile switch hotkey.
        if (input.id.startsWith('hkgroup_')) {
            const direction = input.id.endsWith('_forward') ? 'Forward' : input.id.endsWith('_backward') ? 'Backward' : null;
            return direction ? `Hotkey Group "${base}" (${direction})` : `Hotkey Group "${base}"`;
        }

        if (input.id.startsWith('qg_')) {
            const direction = input.id.endsWith('_forward') ? 'Forward' : input.id.endsWith('_backward') ? 'Backward' : input.id.endsWith('_assign') ? 'Assign' : null;
            return direction ? `Quick Group "${base}" (${direction})` : `Quick Group "${base}"`;
        }

        return base;
    }

    return input.id || 'Hotkey';
}

function findHotkeyConflicts() {
    const byKey = new Map();
    getAllHotkeyInputs().forEach(input => {
        const norm = normalizeHotkeyValue(input.value);
        if (!norm) return;
        if (!byKey.has(norm)) byKey.set(norm, []);
        byKey.get(norm).push(input);
    });

    return Array.from(byKey.values()).filter(inputs => inputs.length > 1);
}

// Returns the conflict groups so callers can report them.
function updateHotkeyConflictHighlights() {
    getAllHotkeyInputs().forEach(input => input.classList.remove('hotkey-conflict'));
    const conflicts = findHotkeyConflicts();
    conflicts.forEach(inputs => inputs.forEach(input => input.classList.add('hotkey-conflict')));
    refreshCharacterHotkeyBadges();
    refreshHotkeyGroupBadges();
    refreshQuickGroupBadges();
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
        const display = value && value !== 'Press keys...' && value !== 'Waiting for input...' ? value : '';
        badge.textContent = display ? `[${display}]` : '';
        badge.style.display = display ? '' : 'none';
    });
}

// Mirrors each hotkey group's forward/backward inputs into the badges shown on its (possibly collapsed) accordion header.
function refreshHotkeyGroupBadges() {
    document.querySelectorAll('#hotkeyGroupsList > .accordion').forEach(accordion => {
        const index = accordion.dataset.index;
        [['forward', '→'], ['backward', '←']].forEach(([direction, arrow]) => {
            const input = document.getElementById(`hkgroup_${index}_${direction}`);
            const badge = document.getElementById(`hkgroup_${index}_${direction}Badge`);
            if (!input || !badge) return;

            const value = input.value.trim();
            const display = value && value !== 'Press keys...' && value !== 'Waiting for input...' ? value : '';
            badge.textContent = display ? `${arrow}[${display}]` : '';
            badge.style.display = display ? '' : 'none';
        });
    });
}

function describeHotkeyConflicts(conflicts) {
    return conflicts
        .map(inputs => `"${vkHexToFriendly(inputs[0].value.trim())}" is bound to: ${inputs.map(hotkeyFieldLabel).join(', ')}`)
        .join('\n');
}

function showHotkeyConflictModal(message) {
    const modal = document.getElementById('hotkey-conflict-modal');
    const messageEl = document.getElementById('hotkey-conflict-message');
    const okBtn = document.getElementById('hotkey-conflict-modal-ok');

    messageEl.textContent = message;
    modal.classList.add('show');

    const handleClose = () => {
        modal.classList.remove('show');
        okBtn.removeEventListener('click', handleClose);
        modal.removeEventListener('click', handleClickOutside);
        document.removeEventListener('keydown', handleKeyDown);
    };

    const handleClickOutside = (e) => {
        if (e.target === modal) handleClose();
    };

    const handleKeyDown = (e) => {
        if (e.key === 'Enter' || e.key === 'Escape') {
            e.preventDefault();
            handleClose();
        }
    };

    okBtn.addEventListener('click', handleClose);
    modal.addEventListener('click', handleClickOutside);
    document.addEventListener('keydown', handleKeyDown);
}

let recordingField = null;
// Once a combo is captured, ignore further capture events until stopRecording() runs, or releasing a modifier after the main key would overwrite it with just the modifier.
let recordingComboCaptured = false;

// Fire-and-forget: recordHotkey()/stopRecording() must stay synchronous, and a missed round-trip (main app not running) is harmless.
async function suspendMainAppHotkeysForRecording() {
    if (typeof webui === 'undefined') return;
    try {
        await webui.call('suspendHotkeysForRecording');
    } catch (error) {
        logWarn('Failed to suspend main app hotkeys for recording:', error);
    }
}

async function resumeMainAppHotkeysAfterRecording() {
    if (typeof webui === 'undefined') return;
    try {
        await webui.call('resumeHotkeysAfterRecording');
    } catch (error) {
        logWarn('Failed to resume main app hotkeys after recording:', error);
    }
}

function clearHotkey(fieldId) {
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

function recordHotkey(fieldId) {
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
    input.value = 'Press keys...';
    input.dataset.originalPlaceholder = input.placeholder;
    input.placeholder = 'Waiting for input...';

    const button = input.parentElement.querySelector('.hotkey-record-btn');
    if (button) {
        button.textContent = t('status.hotkeyStopLabel');
    }

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

    const button = input.parentElement.querySelector('.hotkey-record-btn');
    if (button) {
        button.textContent = t('common.hotkeyRecord');
    }

    // Reset value and placeholder if no binding was set
    if (input.value === 'Press keys...') {
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
function toggleManualHotkeyEdit(fieldId) {
    const input = document.getElementById(fieldId);
    if (!input) return;

    const button = input.parentElement.querySelector('.hotkey-edit-btn');

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
        button.title = 'Done editing';
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

    const button = input.parentElement.querySelector('.hotkey-edit-btn');

    input.value = input.value.trim();
    input.readOnly = true;
    input.classList.remove('manual-editing');
    markAsChanged();
    if (button) {
        button.classList.remove('active');
        button.title = 'Type key name directly';
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

let asciiClickCount = 0;
let snakeGameActive = false;
let snakeGameLoop = null;

document.addEventListener('DOMContentLoaded', function() {
    const asciiLogo = document.getElementById('ascii-logo');
    if (asciiLogo) {
        asciiLogo.addEventListener('click', handleAsciiClick);
    }
});

function handleAsciiClick() {
    asciiClickCount++;

    if (asciiClickCount === 5) {
        showSnakeGame();
        asciiClickCount = 0;
    }
}

function showSnakeGame() {
    const container = document.getElementById('snake-game-container');
    const canvas = document.getElementById('snake-game');
    
    if (!container || !canvas) return;
    
    container.style.display = 'block';
    snakeGameActive = true;
    
    container.scrollIntoView({ behavior: 'smooth', block: 'center' });

    initSnakeGame(canvas);

    const escapeHandler = function(e) {
        if (e.key === 'Escape' && snakeGameActive) {
            hideSnakeGame();
            document.removeEventListener('keydown', escapeHandler);
        }
    };
    document.addEventListener('keydown', escapeHandler);
}

function hideSnakeGame() {
    const container = document.getElementById('snake-game-container');
    if (container) {
        container.style.display = 'none';
    }
    snakeGameActive = false;
    if (snakeGameLoop) {
        cancelAnimationFrame(snakeGameLoop);
        snakeGameLoop = null;
    }
}

function initSnakeGame(canvas) {
    const context = canvas.getContext('2d');
    const grid = 16;
    let count = 0;
    
    const snake = {
        x: 160,
        y: 160,
        dx: grid,
        dy: 0,
        cells: [],
        maxCells: 4
    };
    
    const apple = {
        x: 320,
        y: 320
    };
    
    function getRandomInt(min, max) {
        return Math.floor(Math.random() * (max - min)) + min;
    }
    
    function loop() {
        if (!snakeGameActive) return;
        
        snakeGameLoop = requestAnimationFrame(loop);
        
        // Slow game loop to 7.5 fps (60/7.5 = 8)
        if (++count < 8) {
            return;
        }
        
        count = 0;
        context.clearRect(0, 0, canvas.width, canvas.height);
        
        snake.x += snake.dx;
        snake.y += snake.dy;

        if (snake.x < 0) {
            snake.x = canvas.width - grid;
        } else if (snake.x >= canvas.width) {
            snake.x = 0;
        }
        
        if (snake.y < 0) {
            snake.y = canvas.height - grid;
        } else if (snake.y >= canvas.height) {
            snake.y = 0;
        }
        
        snake.cells.unshift({x: snake.x, y: snake.y});

        if (snake.cells.length > snake.maxCells) {
            snake.cells.pop();
        }

        context.fillStyle = 'white';
        context.fillRect(apple.x, apple.y, grid - 1, grid - 1);

        context.fillStyle = 'white';
        snake.cells.forEach(function(cell, index) {
            context.fillRect(cell.x, cell.y, grid - 1, grid - 1);

            if (cell.x === apple.x && cell.y === apple.y) {
                snake.maxCells++;
                apple.x = getRandomInt(0, 25) * grid;
                apple.y = getRandomInt(0, 25) * grid;
            }

            for (let i = index + 1; i < snake.cells.length; i++) {
                if (cell.x === snake.cells[i].x && cell.y === snake.cells[i].y) {
                    snake.x = 160;
                    snake.y = 160;
                    snake.cells = [];
                    snake.maxCells = 4;
                    snake.dx = grid;
                    snake.dy = 0;
                    apple.x = getRandomInt(0, 25) * grid;
                    apple.y = getRandomInt(0, 25) * grid;
                }
            }
        });
    }
    
    // Keyboard controls - prevent arrow key scrolling when game is active
    const snakeKeyHandler = function(e) {
        if (!snakeGameActive) return;

        if (e.which >= 37 && e.which <= 40) {
            e.preventDefault();
            e.stopPropagation();
        }
        
        if (e.which === 37 && snake.dx === 0) {
            snake.dx = -grid;
            snake.dy = 0;
        }
        else if (e.which === 38 && snake.dy === 0) {
            snake.dy = -grid;
            snake.dx = 0;
        }
        else if (e.which === 39 && snake.dx === 0) {
            snake.dx = grid;
            snake.dy = 0;
        }
        else if (e.which === 40 && snake.dy === 0) {
            snake.dy = grid;
            snake.dx = 0;
        }
    };
    
    document.addEventListener('keydown', snakeKeyHandler, true);

    snakeGameLoop = requestAnimationFrame(loop);
}
// Shared by setupCharacterDragAndDrop and setupHotkeyGroupCharDragAndDrop, which were previously near-identical ~60-line blocks differing only in selectors and the reorder callback.
function setupDragReorder(container, itemSelector, handleSelector, getIndex, onReorder) {
    if (!container) return;
    const items = Array.from(container.querySelectorAll(itemSelector));
    let draggedIndex = null;

    items.forEach(item => {
        const handle = handleSelector ? item.querySelector(handleSelector) : item;
        if (!handle) return;

        handle.addEventListener('dragstart', (e) => {
            draggedIndex = getIndex(item);
            item.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', String(draggedIndex));
            // Drag the whole item, not just the small handle glyph
            e.dataTransfer.setDragImage(item, 10, 10);
        });

        handle.addEventListener('dragend', () => {
            item.classList.remove('dragging');
            items.forEach(i => i.classList.remove('drag-over-top', 'drag-over-bottom'));
            draggedIndex = null;
        });

        item.addEventListener('dragover', (e) => {
            if (draggedIndex === null) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';

            const targetIndex = getIndex(item);
            if (targetIndex === draggedIndex) return;

            const rect = item.getBoundingClientRect();
            const isAfter = (e.clientY - rect.top) > rect.height / 2;
            item.classList.toggle('drag-over-bottom', isAfter);
            item.classList.toggle('drag-over-top', !isAfter);
        });

        item.addEventListener('dragleave', () => {
            item.classList.remove('drag-over-top', 'drag-over-bottom');
        });

        item.addEventListener('drop', (e) => {
            e.preventDefault();
            item.classList.remove('drag-over-top', 'drag-over-bottom');
            if (draggedIndex === null) return;

            const targetIndex = getIndex(item);
            if (targetIndex === draggedIndex) return;

            const rect = item.getBoundingClientRect();
            const isAfter = (e.clientY - rect.top) > rect.height / 2;
            onReorder(draggedIndex, isAfter ? targetIndex + 1 : targetIndex);
            markAsChanged();
        });
    });
}

// Used by window filters, characters, and hotkey groups (system colors isn't an accordion - it's a flat row list).
function toggleAccordion(containerSelector, index) {
    const accordions = document.querySelectorAll(`${containerSelector} .accordion`);
    if (accordions[index]) {
        accordions[index].classList.toggle('expanded');
    }
}

function syncAccordionHeaderName(nameFieldId, headerFieldId, fallbackPrefix, index) {
    const nameInput = document.getElementById(nameFieldId);
    const headerName = document.getElementById(headerFieldId);

    if (nameInput && headerName) {
        const newName = nameInput.value.trim();
        headerName.textContent = newName || `${fallbackPrefix} ${index + 1}`;
    }
}

function populateWindowFilters() {
    const container = document.getElementById('windowFiltersList');
    if (!container) return;
    
    container.innerHTML = '';
    const filters = currentConfig.windowFilters || [];
    
    let displayIndex = 0;
    filters.forEach((filter, index) => {
        // Skip the default "EVE Online" filter
        if (filter.name === 'EVE Online') {
            return;
        }
        const filterDisplayIndex = displayIndex++;

        const filterDiv = document.createElement('div');
        filterDiv.className = 'accordion';
        filterDiv.innerHTML = `
            <div class="accordion-header" onclick="toggleWindowFilterAccordion(${filterDisplayIndex})">
                <div class="accordion-title">
                    <span class="accordion-toggle"></span>
                    <span class="accordion-name" id="filter_${index}_header_name">${filter.name || t('dynamic.windowFilter.defaultNamePrefix') + ' ' + (index + 1)}</span>
                </div>
                <button type="button" id="filter_${index}_removeBtn" onclick="event.stopPropagation(); confirmRemove('filter_${index}_removeBtn', () => removeWindowFilter(${index}))" style="margin-bottom: 0;">${t('common.remove')}</button>
            </div>
            <div class="accordion-content">
                <label>
                    <input type="checkbox" id="filter_${index}_enabled" ${filter.enabled ? 'checked' : ''}>
                    <span class="label-body">${t('common.enabledLabel')}</span>
                </label>
                <label style="display: block; margin-top: 8px;">${t('dynamic.windowFilter.nameLabel')}</label>
                <input type="text" id="filter_${index}_name" value="${filter.name || ''}" placeholder="${t('dynamic.windowFilter.namePlaceholder')}" oninput="updateWindowFilterHeaderName(${index})">
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
                    <div>
                        <label>${t('dynamic.windowFilter.classesLabel')}</label>
                        <input type="text" id="filter_${index}_classes" value="${(filter.class_names || []).join(', ')}" placeholder="${t('dynamic.windowFilter.classesPlaceholder')}">
                    </div>
                    <div>
                        <label>${t('dynamic.windowFilter.exesLabel')}</label>
                        <input type="text" id="filter_${index}_exes" value="${(filter.executable_names || []).join(', ')}" placeholder="${t('dynamic.windowFilter.exesPlaceholder')}">
                    </div>
                </div>
                <button type="button" id="filter_${index}_pickBtn" onclick="pickRunningWindowForFilter(${index})" style="width: 100%; margin-top: 8px;">${t('button.pick-running-window.label')}</button>
                <select id="filter_${index}_picker" style="display: none; width: 100%; margin-top: 8px;" onchange="applyPickedWindowForFilter(${index})"></select>
            </div>
        `;
        container.appendChild(filterDiv);
    });
}

function updateWindowFilterHeaderName(index) {
    syncAccordionHeaderName(`filter_${index}_name`, `filter_${index}_header_name`, 'Filter', index);
}

function toggleWindowFilterAccordion(index) {
    toggleAccordion('#windowFiltersList', index);
}

function addWindowFilter() {
    if (!currentConfig.windowFilters) currentConfig.windowFilters = [];
    saveWindowFilters();
    currentConfig.windowFilters.push({
        name: 'New Filter',
        enabled: true,
        class_names: [],
        executable_names: []
    });
    markAsChanged();
    populateWindowFilters();

    // Automatically expand the newly added filter (always rendered last)
    const accordions = document.querySelectorAll('#windowFiltersList .accordion');
    const newAccordion = accordions[accordions.length - 1];
    if (newAccordion) newAccordion.classList.add('expanded');
}

function removeWindowFilter(index) {
    if (currentConfig.windowFilters && currentConfig.windowFilters[index]) {
        saveWindowFilters();
        const removedName = currentConfig.windowFilters[index].name || '';
        currentConfig.windowFilters.splice(index, 1);
        pendingCharacterNames.delete(removedName.trim().toLowerCase());
        removeCharacterByName(removedName);
        markAsChanged();
        populateWindowFilters();
    }
}

function saveWindowFilters() {
    if (!currentConfig.windowFilters) return;
    
    currentConfig.windowFilters.forEach((filter, index) => {
        const enabled = document.getElementById(`filter_${index}_enabled`);
        const name = document.getElementById(`filter_${index}_name`);
        const classes = document.getElementById(`filter_${index}_classes`);
        const exes = document.getElementById(`filter_${index}_exes`);
        
        if (enabled) filter.enabled = enabled.checked;
        if (name) filter.name = name.value;
        if (classes) filter.class_names = classes.value.split(',').map(s => s.trim()).filter(s => s);
        if (exes) filter.executable_names = exes.value.split(',').map(s => s.trim()).filter(s => s);
    });
}

async function pickRunningWindowForFilter(index) {
    const btn = document.getElementById(`filter_${index}_pickBtn`);
    const select = document.getElementById(`filter_${index}_picker`);
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let windows = [];
        if (typeof webui !== 'undefined') {
            const result = await webui.call('getRunningWindows');
            windows = JSON.parse(result);
        }

        if (windows.length === 0) {
            showStatus(t('status.noRunningWindows'), 'error');
            return;
        }

        select.innerHTML = `<option value="">${escapeHtml(t('dynamic.windowFilter.pickerDefaultOption'))}</option>` +
            windows.map((w, i) => `<option value="${i}">${escapeHtml(w.title)} — ${escapeHtml(w.exe)}</option>`).join('');
        select.dataset.windows = JSON.stringify(windows);
        select.style.display = '';
    } catch (error) {
        logError('Failed to scan running windows:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('button.pick-running-window.label'); }
    }
}

function applyPickedWindowForFilter(index) {
    const select = document.getElementById(`filter_${index}_picker`);
    if (!select || select.value === '') return;
    const windows = JSON.parse(select.dataset.windows || '[]');
    const chosen = windows[parseInt(select.value, 10)];
    if (!chosen) return;

    const classesInput = document.getElementById(`filter_${index}_classes`);
    const exesInput = document.getElementById(`filter_${index}_exes`);
    if (classesInput) classesInput.value = chosen.class;
    if (exesInput) exesInput.value = chosen.exe;

    const nameInput = document.getElementById(`filter_${index}_name`);
    const friendlyName = chosen.exe.replace(/\.exe$/i, '');
    if (nameInput) {
        nameInput.value = friendlyName;
        updateWindowFilterHeaderName(index);
    }

    pendingCharacterNames.set(friendlyName.trim().toLowerCase(), friendlyName);
}

function addCharacterIfMissing(name) {
    if (!currentConfig.characters) currentConfig.characters = [];
    saveCharacters();

    const exists = currentConfig.characters.some(c => (c.name || '').trim().toLowerCase() === name.trim().toLowerCase());
    if (exists) return;

    currentConfig.characters.push({
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

function populateSystemColors() {
    const container = document.getElementById('systemColorsList');
    if (!container) return;
    
    container.innerHTML = '';
    const colors = currentConfig.systemColors || [];
    
    colors.forEach((sc, index) => {
        const colorDiv = document.createElement('div');
        colorDiv.style.cssText = 'display: flex; gap: 8px; align-items: center; margin-bottom: 8px;';
        colorDiv.innerHTML = `
            <input type="text" id="systemColor_${index}_name" value="${sc.systemName || ''}" placeholder="${t('dynamic.systemColor.namePlaceholder')}" style="flex: 1; margin-bottom: 0;">
            <input type="color" id="systemColor_${index}_color" value="${zigColorToHtml(sc.color)}" style="width: 60px; margin-bottom: 0;">
            <button type="button" id="systemColor_${index}_removeBtn" onclick="confirmRemove('systemColor_${index}_removeBtn', () => removeSystemColor(${index}))" style="margin-bottom: 0; min-width: 80px;">${t('common.remove')}</button>
        `;
        container.appendChild(colorDiv);
    });
}

function addSystemColor() {
    if (!currentConfig.systemColors) currentConfig.systemColors = [];
    saveSystemColors();
    currentConfig.systemColors.push({ systemName: '', color: '0xFFFFFFFF' });
    markAsChanged();
    populateSystemColors();
    scheduleThumbnailPreview();
}

function removeSystemColor(index) {
    if (currentConfig.systemColors && currentConfig.systemColors[index] !== undefined) {
        saveSystemColors();
        currentConfig.systemColors.splice(index, 1);
        markAsChanged();
        populateSystemColors();
        scheduleThumbnailPreview();
    }
}

function saveSystemColors() {
    if (!currentConfig.systemColors) return;
    
    currentConfig.systemColors.forEach((sc, index) => {
        const name = document.getElementById(`systemColor_${index}_name`);
        const color = document.getElementById(`systemColor_${index}_color`);
        
        if (name) sc.systemName = name.value;
        if (color) sc.color = htmlColorToZig(color.value);
    });
}

// Avoids overwriting positions that were changed by dragging after the dialog was opened.
async function reloadLivePositions() {
    try {
        if (typeof webui !== 'undefined') {
            const configJson = await webui.call('loadConfig');
            const savedConfig = JSON.parse(configJson);

            if (savedConfig.characters && Array.isArray(savedConfig.characters)) {
                if (!currentConfig.characters) currentConfig.characters = [];
                savedConfig.characters.forEach(savedChar => {
                    if (!savedChar.position) return;
                    if (deletedCharacterNames.has((savedChar.name || '').trim().toLowerCase())) return;
                    const char = currentConfig.characters.find(c => c.name === savedChar.name);
                    if (char) {
                        char.position = savedChar.position;
                    } else {
                        // Character was dragged (creating its first saved position) after the dialog snapshot - without this it would be dropped entirely.
                        currentConfig.characters.push(savedChar);
                    }
                });
            }

            if (savedConfig.display) {
                if (!currentConfig.display) currentConfig.display = {};
                currentConfig.display.startX = savedConfig.display.startX;
                currentConfig.display.startY = savedConfig.display.startY;
                currentConfig.display.notifInfoPanelX = savedConfig.display.notifInfoPanelX;
                currentConfig.display.notifInfoPanelY = savedConfig.display.notifInfoPanelY;
            }
        }
    } catch (error) {
        logError('Failed to reload live positions:', error);
        // Continue with save even if reload fails - better than blocking the save
    }
}

// Applied by applyCharacterFilter() after every populateCharacters() rebuild so the filter survives add/remove/reorder.
let characterSearchQuery = '';

// Which character's detail panel is showing in the master-detail characters view.
let selectedCharacterIndex = 0;

function onCharacterSearchInput(query) {
    characterSearchQuery = query.toLowerCase().trim();
    applyCharacterFilter();
}

function clearCharacterSearch() {
    const input = document.getElementById('characterSearchFilter');
    if (input) input.value = '';
    characterSearchQuery = '';
    applyCharacterFilter();
}

function applyCharacterFilter() {
    const container = document.getElementById('charactersList');
    if (!container) return;

    container.querySelectorAll('.roster-row').forEach(row => {
        const name = (row.querySelector('.roster-name')?.textContent || '').toLowerCase();
        row.style.display = !characterSearchQuery || name.includes(characterSearchQuery) ? '' : 'none';
    });
}

// Character IDs are learned at runtime from chatlog filenames and cached in global settings, so a freshly added or renamed character has no portrait until the app has seen a chatlog for it.
function characterPortraitUrl(name) {
    const id = currentGlobalSettings?.characterIdMap?.[(name || '').trim()];
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

// loadConfigurationFromBackend() and loadGlobalSettingsFromBackend() (which owns characterIdMap) fire concurrently, so whichever resolves first must not leave portraits permanently blank.
function refreshCharacterPortraits() {
    (currentConfig?.characters || []).forEach((char, index) => {
        applyCharacterPortrait(document.getElementById(`char_${index}_portrait`), char.name);
    });
}

function updateCharacterHeaderPortrait(index) {
    applyCharacterPortrait(document.getElementById(`char_${index}_portrait`), document.getElementById(`char_${index}_name`)?.value);
}

function populateCharacters() {
    const container = document.getElementById('charactersList');
    if (!container) return;

    const chars = currentConfig.characters || [];

    if (chars.length === 0) {
        container.innerHTML = '';
        return;
    }

    if (selectedCharacterIndex >= chars.length) selectedCharacterIndex = chars.length - 1;
    if (selectedCharacterIndex < 0) selectedCharacterIndex = 0;

    const rosterRows = chars.map((char, index) => {
        const portraitUrl = characterPortraitUrl(char.name);
        const hotkeyDisplay = char.hotkey ? vkHexToFriendly(char.hotkey) : '';
        return `
            <div class="roster-row ${index === selectedCharacterIndex ? 'selected' : ''}" data-index="${index}" onclick="selectCharacter(${index})">
                <span class="drag-index-chip character-drag-handle" draggable="true" title="${t('common.dragToReorder')}" onclick="event.stopPropagation()">${String(index + 1).padStart(2, '0')}</span>
                <img class="character-portrait" id="char_${index}_portrait" src="${portraitUrl || ''}" alt="" style="${portraitUrl ? '' : 'display:none'}" onerror="this.style.display='none'">
                <span class="roster-name" id="char_${index}_header_name">${char.name || t('dynamic.character.defaultNamePrefix') + ' ' + (index + 1)}</span>
                <span class="roster-hotkey-badge" id="char_${index}_hotkeyBadge" style="${hotkeyDisplay ? '' : 'display:none'}">[${hotkeyDisplay}]</span>
            </div>
        `;
    }).join('');

    const detailPanels = chars.map((char, index) => `
        <div class="char-detail-panel ${index === selectedCharacterIndex ? 'active' : ''}" data-index="${index}">
            <div class="char-detail-header">
                <span class="char-detail-name" id="char_${index}_detail_name">${char.name || t('dynamic.character.defaultNamePrefix') + ' ' + (index + 1)}</span>
                <button type="button" id="char_${index}_removeBtn" onclick="confirmRemoveCharacter(${index})" style="margin-bottom: 0;">${t('common.remove')}</button>
            </div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div>
                    <label>${t('common.characterName')}</label>
                    <input type="text" id="char_${index}_name" value="${char.name || ''}" placeholder="${t('common.characterName')}" oninput="updateCharacterHeaderName(${index})">
                </div>
                <div>
                    <label>${t('dynamic.character.displayNameLabel')}</label>
                    <input type="text" id="char_${index}_displayName" value="${char.displayName || ''}" placeholder="${t('dynamic.character.displayNamePlaceholder')}">
                </div>
            </div>
            <h4 style="margin-top: 16px; margin-bottom: 8px;">${t('common.hotkeyLabel')}</h4>
            <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 0;">${renderHotkeyInputHtml(`char_${index}_hotkey`, vkHexToFriendly(char.hotkey) || '', t('dynamic.character.hotkeyPlaceholder'))}</div>
            <h4 style="margin-top: 16px; margin-bottom: 8px;">${t('dynamic.character.thumbnailSizeHeading')}</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div>
                    <label>${t('common.widthPxLabel')}</label>
                    <input type="number" id="char_${index}_width" value="${char.thumbnailSize?.width || ''}" placeholder="${t('dynamic.character.widthPlaceholder')}" min="50" max="3840">
                </div>
                <div>
                    <label>${t('common.heightPxLabel')}</label>
                    <input type="number" id="char_${index}_height" value="${char.thumbnailSize?.height || ''}" placeholder="${t('dynamic.character.heightPlaceholder')}" min="50" max="2160">
                </div>
            </div>
            <h4 style="margin-top: 16px; margin-bottom: 8px;">${t('dynamic.character.borderColorsHeading')}</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px;">
                <div>
                    <label>${t('dynamic.character.activeBorderColorLabel')}</label>
                    <div class="swatch-wrap">
                        <input type="color" id="char_${index}_activeColor" data-optional-color="true" ${!char.borderColors?.activeBorderColor ? `data-cleared="true" title="${t('common.notSetInheritingColor')}"` : ''} value="${zigColorToHtml(char.borderColors?.activeBorderColor) || '#FFFF00'}">
                    </div>
                </div>
                <div>
                    <label>${t('dynamic.character.inactiveBorderColorLabel')}</label>
                    <div class="swatch-wrap">
                        <input type="color" id="char_${index}_inactiveColor" data-optional-color="true" ${!char.borderColors?.inactiveBorderColor ? `data-cleared="true" title="${t('common.notSetInheritingColor')}"` : ''} value="${zigColorToHtml(char.borderColors?.inactiveBorderColor) || '#606060'}">
                    </div>
                </div>
                <div>
                    <label>${t('field.textColor.label')}</label>
                    <div class="swatch-wrap">
                        <input type="color" id="char_${index}_nameColor" data-optional-color="true" ${!char.nameColor ? `data-cleared="true" title="${t('common.notSetInheritingColor')}"` : ''} value="${zigColorToHtml(char.nameColor)}">
                    </div>
                </div>
            </div>
            <h4 style="margin-top: 16px; margin-bottom: 8px;">${t('dynamic.character.behaviorHeading')}</h4>
            <div style="display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px;">
                <label>
                    <input type="checkbox" id="char_${index}_excludeMinimize" ${char.excludeFromMinimize ? 'checked' : ''}>
                    <span class="label-body">${t('dynamic.character.excludeMinimizeLabel')}</span>
                </label>
                <label>
                    <input type="checkbox" id="char_${index}_excludeCloseAll" ${char.excludeFromCloseAll ? 'checked' : ''}>
                    <span class="label-body">${t('dynamic.character.excludeCloseAllLabel')}</span>
                </label>
                <label>
                    <input type="checkbox" id="char_${index}_hideThumbnail" ${char.hideThumbnail ? 'checked' : ''}>
                    <span class="label-body">${t('dynamic.character.hideThumbnailLabel')}</span>
                </label>
            </div>
            <h4 style="margin-top: 16px; margin-bottom: 8px;">${t('dynamic.character.windowPositionHeading')}</h4>
            <div style="display: flex; align-items: center; gap: 8px;">
                <span id="char_${index}_windowPositionDisplay">${char.windowPosition ? `${char.windowPosition.x}, ${char.windowPosition.y}` : t('dynamic.character.windowPositionNotSet')}</span>
                <button type="button" onclick="setCharacterWindowPosition(${index})">${t('dynamic.character.setWindowPositionButton')}</button>
                <button type="button" id="char_${index}_clearWindowPositionBtn" onclick="confirmClearCharacterWindowPosition(${index})">${t('dynamic.character.clearWindowPositionButton')}</button>
            </div>
            <p class="hint">${t('dynamic.character.setWindowPositionHint')}</p>
        </div>
    `).join('');

    container.innerHTML = `
        <div class="character-master-detail">
            <div class="character-roster">${rosterRows}</div>
            <div class="character-detail-stack">${detailPanels}</div>
        </div>
    `;

    setupCharacterDragAndDrop();
    updateHotkeyConflictHighlights();
    applyCharacterFilter();
}

// Saves this character's live window position, written straight to disk (not behind Save).
async function setCharacterWindowPosition(index) {
    const char = currentConfig.characters?.[index];
    if (!char) return;

    try {
        const result = await webui.call('setCharacterWindowPosition', char.name || '');
        const data = JSON.parse(result);
        if (!data.success) {
            showStatus(t('status.saveFailedPrefix') + (data.error || ''), 'error');
            return;
        }

        char.windowPosition = { x: data.x, y: data.y };
        const display = document.getElementById(`char_${index}_windowPositionDisplay`);
        if (display) display.textContent = `${data.x}, ${data.y}`;
        showStatus(t('status.windowPositionSet'), 'success');
    } catch (error) {
        logError('Failed to set character window position:', error);
    }
}

function confirmClearCharacterWindowPosition(index) {
    confirmRemove(`char_${index}_clearWindowPositionBtn`, () => clearCharacterWindowPosition(index));
}

// Clears this character's saved window position (written straight to disk, same as set).
async function clearCharacterWindowPosition(index) {
    const char = currentConfig.characters?.[index];
    if (!char) return;

    try {
        const result = await webui.call('clearCharacterWindowPosition', char.name || '');
        const data = JSON.parse(result);
        if (!data.success) {
            showStatus(t('status.saveFailedPrefix') + (data.error || ''), 'error');
            return;
        }

        char.windowPosition = null;
        const display = document.getElementById(`char_${index}_windowPositionDisplay`);
        if (display) display.textContent = t('dynamic.character.windowPositionNotSet');
        showStatus(t('status.windowPositionCleared'), 'success');
    } catch (error) {
        logError('Failed to clear character window position:', error);
    }
}

// Populates the "Copy Position From" dropdown with currently-open clients.
async function refreshWindowPositionSourceOptions() {
    const select = document.getElementById('windowPositionSourceSelect');
    if (!select || typeof webui === 'undefined') return;

    const previousValue = select.value;
    try {
        const result = await webui.call('getOpenClients');
        const names = JSON.parse(result);
        select.innerHTML = names.map(name => `<option value="${name}">${name}</option>`).join('');
        if (names.includes(previousValue)) select.value = previousValue;
    } catch (error) {
        logError('Failed to refresh window position source options:', error);
    }
}

// Overwrites every character's saved position with the selected source window's current position.
async function setAllCharacterWindowPositions() {
    const select = document.getElementById('windowPositionSourceSelect');
    const sourceName = select ? select.value : '';
    if (!sourceName) {
        showStatus(t('status.noOpenClients'), 'error');
        return;
    }

    try {
        const result = await webui.call('setAllCharacterWindowPositions', sourceName);
        const data = JSON.parse(result);
        if (!data.success) {
            showStatus(t('status.saveFailedPrefix') + (data.error || ''), 'error');
            return;
        }

        (currentConfig.characters || []).forEach(char => {
            char.windowPosition = { x: data.x, y: data.y };
        });
        populateCharacters();
        showStatus(t('status.windowPositionSet'), 'success');
    } catch (error) {
        logError('Failed to set all character window positions:', error);
    }
}

function confirmClearAllCharacterWindowPositions() {
    confirmRemove('clearAllWindowPositionsBtn', clearAllCharacterWindowPositions);
}

// Clears every character's saved window position (written straight to disk, same as set*WindowPosition).
async function clearAllCharacterWindowPositions() {
    try {
        const result = await webui.call('clearAllCharacterWindowPositions');
        const data = JSON.parse(result);
        if (!data.success) {
            showStatus(t('status.saveFailedPrefix') + (data.error || ''), 'error');
            return;
        }

        (currentConfig.characters || []).forEach(char => {
            char.windowPosition = null;
        });
        populateCharacters();
        showStatus(t('status.windowPositionCleared'), 'success');
    } catch (error) {
        logError('Failed to clear all character window positions:', error);
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
        reorderCharacters
    );
}

// Tracks the selected character by identity so the open detail panel follows it, rather than whatever character the raw index now happens to point at.
function reorderCharacters(fromIndex, insertBeforeIndex) {
    if (!currentConfig.characters) return;

    // Persist any in-progress edits in the form before the indices shift
    saveCharacters();

    const chars = currentConfig.characters;
    const selectedChar = chars[selectedCharacterIndex];
    const [moved] = chars.splice(fromIndex, 1);
    const insertAt = fromIndex < insertBeforeIndex ? insertBeforeIndex - 1 : insertBeforeIndex;
    chars.splice(insertAt, 0, moved);

    if (selectedChar) selectedCharacterIndex = chars.indexOf(selectedChar);
    populateCharacters();
}

function updateCharacterHeaderName(index) {
    syncAccordionHeaderName(`char_${index}_name`, `char_${index}_header_name`, 'Character', index);
    syncAccordionHeaderName(`char_${index}_name`, `char_${index}_detail_name`, 'Character', index);
    updateCharacterHeaderPortrait(index);
}

// Every character's fields stay mounted (just hidden) so hotkey-conflict detection, which scans all input.hotkey-input elements at once, keeps seeing every character.
function selectCharacter(index) {
    selectedCharacterIndex = index;
    document.querySelectorAll('#charactersList .roster-row').forEach(row => {
        row.classList.toggle('selected', parseInt(row.dataset.index, 10) === index);
    });
    document.querySelectorAll('#charactersList .char-detail-panel').forEach(panel => {
        panel.classList.toggle('active', parseInt(panel.dataset.index, 10) === index);
    });
}

function generateUniqueColor(index) {
    // Use golden ratio to distribute colors evenly around color wheel
    const goldenRatio = 0.618033988749895;
    const hue = (index * goldenRatio * 360) % 360;
    // Use high saturation and medium lightness for vibrant, visible colors
    const saturation = 75;
    const lightness = 55;

    const h = hue / 360;
    const s = saturation / 100;
    const l = lightness / 100;
    
    let r, g, b;
    if (s === 0) {
        r = g = b = l;
    } else {
        const hue2rgb = (p, q, t) => {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1/6) return p + (q - p) * 6 * t;
            if (t < 1/2) return q;
            if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
            return p;
        };
        const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        const p = 2 * l - q;
        r = hue2rgb(p, q, h + 1/3);
        g = hue2rgb(p, q, h);
        b = hue2rgb(p, q, h - 1/3);
    }

    const toHex = (x) => Math.round(x * 255).toString(16).padStart(2, '0').toUpperCase();
    return `0xFF${toHex(r)}${toHex(g)}${toHex(b)}`;
}

function addCharacter() {
    if (!currentConfig.characters) currentConfig.characters = [];
    saveCharacters();

    const assignUniqueColors = document.getElementById('assignUniqueCharacterColors')?.checked || false;
    
    const colorIndex = currentConfig.characters.length;
    const newChar = {
        name: '',
        position: null, // Unset -> backend auto-arranges via layoutMode instead of pinning to (0,0)
        borderColors: assignUniqueColors ? {
            activeBorderColor: generateUniqueColor(colorIndex),
            inactiveBorderColor: null
        } : null,
        thumbnailSize: null,
        displayName: null,
        hotkey: null
    };
    
    currentConfig.characters.push(newChar);
    markAsChanged();
    populateCharacters();

    const newIndex = currentConfig.characters.length - 1;
    selectCharacter(newIndex);

    const roster = document.querySelector('#charactersList .character-roster');
    if (roster) {
        setTimeout(() => {
            roster.scrollTop = roster.scrollHeight;
        }, 50);
    }
}

async function populateCharactersFromClients() {
    const btn = document.getElementById('populateCharactersBtn');
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let names = [];
        if (typeof webui !== 'undefined') {
            const result = await webui.call('getOpenClients');
            names = JSON.parse(result);
        }

        if (names.length === 0) {
            showStatus(t('status.noOpenClients'), 'error');
            return;
        }

        saveCharacters();
        if (!currentConfig.characters) currentConfig.characters = [];

        const existing = new Set(currentConfig.characters.map(c => (c.name || '').trim().toLowerCase()));
        let added = 0;
        for (const name of names) {
            if (!existing.has(name.trim().toLowerCase())) {
                currentConfig.characters.push({
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
        setTimeout(() => hideStatus(), 3000);
    } catch (error) {
        logError('Failed to populate characters from open clients:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('common.populateFromClients'); }
    }
}

function confirmRemove(buttonId, removeCallback, confirmText = 'Confirm') {
    const btn = document.getElementById(buttonId);
    if (!btn) return;

    if (btn.classList.contains('confirm-delete')) {
        // Second click - revert to normal appearance, then perform the action
        btn.classList.remove('confirm-delete');
        btn.textContent = btn.dataset.originalText || btn.textContent;
        removeCallback();
    } else {
        // First click - set confirm state
        const originalText = btn.textContent;
        btn.classList.add('confirm-delete');
        btn.textContent = confirmText;
        btn.dataset.originalText = originalText;
        
        // Reset after 2 seconds if not clicked
        setTimeout(() => {
            if (btn && btn.classList.contains('confirm-delete')) {
                btn.classList.remove('confirm-delete');
                btn.textContent = btn.dataset.originalText || 'Remove';
            }
        }, 2000);
    }
}

function confirmRemoveCharacter(index) {
    confirmRemove(`char_${index}_removeBtn`, () => removeCharacter(index));
}

// If the removed character was the selected one, falls back to whichever character now sits at the removed slot (or the last one).
function reselectCharacterAfterRemoval(selectedChar, removedIndex) {
    const chars = currentConfig.characters;
    const stillPresent = selectedChar ? chars.indexOf(selectedChar) : -1;
    selectedCharacterIndex = stillPresent !== -1 ? stillPresent : Math.min(removedIndex, chars.length - 1);
}

function removeCharacterByName(name) {
    if (!currentConfig.characters || !name.trim()) return;
    saveCharacters();
    const target = name.trim().toLowerCase();
    const index = currentConfig.characters.findIndex(c => (c.name || '').trim().toLowerCase() === target);
    if (index === -1) return;
    deletedCharacterNames.add(target);
    const selectedChar = currentConfig.characters[selectedCharacterIndex];
    currentConfig.characters.splice(index, 1);
    reselectCharacterAfterRemoval(selectedChar, index);
    populateCharacters();
}

function removeCharacter(index) {
    if (currentConfig.characters && currentConfig.characters[index]) {
        saveCharacters();
        deletedCharacterNames.add((currentConfig.characters[index].name || '').trim().toLowerCase());
        const selectedChar = currentConfig.characters[selectedCharacterIndex];
        currentConfig.characters.splice(index, 1);
        reselectCharacterAfterRemoval(selectedChar, index);
        markAsChanged();
        populateCharacters();
    }
}

function saveCharacters() {
    if (!currentConfig.characters) return;
    
    currentConfig.characters.forEach((char, index) => {
        const name = document.getElementById(`char_${index}_name`);
        const displayName = document.getElementById(`char_${index}_displayName`);
        const hotkey = document.getElementById(`char_${index}_hotkey`);
        const width = document.getElementById(`char_${index}_width`);
        const height = document.getElementById(`char_${index}_height`);
        const activeColor = document.getElementById(`char_${index}_activeColor`);
        const inactiveColor = document.getElementById(`char_${index}_inactiveColor`);
        const nameColor = document.getElementById(`char_${index}_nameColor`);
        const excludeMinimize = document.getElementById(`char_${index}_excludeMinimize`);
        const excludeCloseAll = document.getElementById(`char_${index}_excludeCloseAll`);
        const hideThumbnail = document.getElementById(`char_${index}_hideThumbnail`);

        if (name) char.name = name.value;
        if (displayName) char.displayName = displayName.value || null;
        if (hotkey) char.hotkey = hotkey.value || null;
        if (excludeMinimize) char.excludeFromMinimize = excludeMinimize.checked;
        if (excludeCloseAll) char.excludeFromCloseAll = excludeCloseAll.checked;
        if (hideThumbnail) char.hideThumbnail = hideThumbnail.checked;
        // Position is saved automatically when thumbnails are dragged, don't overwrite from dialog

        const w = width ? parseInt(width.value) : null;
        const h = height ? parseInt(height.value) : null;
        if (w || h) {
            char.thumbnailSize = { width: w, height: h };
        } else {
            char.thumbnailSize = null;
        }
        
        const activeOut = resolveOptionalCharacterColor(activeColor, !!(char.borderColors && char.borderColors.activeBorderColor));
        const inactiveOut = resolveOptionalCharacterColor(inactiveColor, !!(char.borderColors && char.borderColors.inactiveBorderColor));
        char.borderColors = (activeOut || inactiveOut)
            ? { activeBorderColor: activeOut, inactiveBorderColor: inactiveOut }
            : null;

        char.nameColor = resolveOptionalCharacterColor(nameColor, !!char.nameColor);
    });
}

function populateHotkeyGroups() {
    const container = document.getElementById('hotkeyGroupsList');
    if (!container) return;
    
    container.innerHTML = '';
    const groups = currentConfig.hotkeyGroups || [];
    
    groups.forEach((group, index) => {
        const groupDiv = document.createElement('div');
        groupDiv.className = 'accordion';
        groupDiv.id = `hkgroup_${index}_accordion`;
        groupDiv.dataset.index = index;
        const forwardDisplay = vkHexToFriendly(group.forwardKey) || '';
        const backwardDisplay = vkHexToFriendly(group.backwardKey) || '';
        const charCount = (group.characters || []).length;
        groupDiv.innerHTML = `
            <div class="accordion-header" onclick="toggleHotkeyGroupAccordion(${index})">
                <div class="accordion-title">
                    <span class="accordion-toggle"></span>
                    <span class="accordion-name" id="hkgroup_${index}_header_name">${group.name || t('dynamic.hotkeyGroup.defaultNamePrefix') + ' ' + (index + 1)}</span>
                    <span class="accordion-count-badge" id="hkgroup_${index}_countBadge">(${charCount})</span>
                </div>
                <div class="accordion-header-actions">
                    <span class="accordion-hotkey-badge" id="hkgroup_${index}_forwardBadge" style="${forwardDisplay ? '' : 'display:none'}">→[${forwardDisplay}]</span>
                    <span class="accordion-hotkey-badge" id="hkgroup_${index}_backwardBadge" style="${backwardDisplay ? '' : 'display:none'}">←[${backwardDisplay}]</span>
                    <button type="button" id="hkgroup_${index}_removeBtn" onclick="event.stopPropagation(); confirmRemove('hkgroup_${index}_removeBtn', () => removeHotkeyGroup(${index}))" style="margin-bottom: 0;">${t('common.remove')}</button>
                </div>
            </div>
            <div class="accordion-content">
                <label style="display: block; margin-top: 8px;">${t('dynamic.hotkeyGroup.nameLabel')}</label>
                <input type="text" id="hkgroup_${index}_name" value="${group.name || ''}" placeholder="${t('dynamic.hotkeyGroup.namePlaceholder')}" oninput="updateHotkeyGroupHeaderName(${index})">
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
                    <div>
                        <label>${t('dynamic.hotkeyGroup.forwardKeyLabel')}</label>
                        <div style="display: flex; gap: 8px; align-items: center;">${renderHotkeyInputHtml(`hkgroup_${index}_forward`, vkHexToFriendly(group.forwardKey) || '', t('dynamic.hotkeyGroup.forwardPlaceholder'))}</div>
                    </div>
                    <div>
                        <label>${t('dynamic.hotkeyGroup.backwardKeyLabel')}</label>
                        <div style="display: flex; gap: 8px; align-items: center;">${renderHotkeyInputHtml(`hkgroup_${index}_backward`, vkHexToFriendly(group.backwardKey) || '', t('dynamic.hotkeyGroup.backwardPlaceholder'))}</div>
                    </div>
                </div>
                <label style="display: block; margin-top: 8px;">${t('dynamic.hotkeyGroup.charactersLabel')}</label>
                <div class="hkgroup-chars-list" id="hkgroup_${index}_charsList" data-group-index="${index}">${renderHotkeyGroupCharRows(index, group.characters)}</div>
                <div style="display: flex; gap: 8px; align-items: center; margin-top: 4px;">
                    <input type="text" id="hkgroup_${index}_addChar" placeholder="${t('dynamic.hotkeyGroup.addCharPlaceholder')}" style="flex: 1; margin-bottom: 0;" onkeydown="if (event.key === 'Enter') { event.preventDefault(); addHotkeyGroupCharacter(${index}); }">
                    <button type="button" onclick="addHotkeyGroupCharacter(${index})" style="width: auto; margin-bottom: 0; white-space: nowrap;">${t('dynamic.hotkeyGroup.addBtnLabel')}</button>
                    <button type="button" id="hkgroup_${index}_fillBtn" onclick="fillHotkeyGroupFromClients(${index})" style="width: auto; margin-bottom: 0; white-space: nowrap;">${t('status.fillFromClientsLabel')}</button>
                </div>
            </div>
        `;
        container.appendChild(groupDiv);
    });

    setupHotkeyGroupCharDragAndDrop();
    updateHotkeyConflictHighlights();
}

function renderHotkeyGroupCharRows(groupIndex, characters) {
    return (characters || []).map((name, charIndex) => `
        <div class="hkgroup-char-row" data-char-index="${charIndex}">
            <span class="drag-index-chip character-drag-handle" draggable="true" title="${t('common.dragToReorder')}" onclick="event.stopPropagation()">${String(charIndex + 1).padStart(2, '0')}</span>
            <input type="text" class="hkgroup-char-input" value="${name}" placeholder="${t('common.characterName')}" style="flex: 1; margin-bottom: 0;">
            <button type="button" class="hotkey-clear-btn" onclick="removeHotkeyGroupCharacter(${groupIndex}, ${charIndex})" title="${t('common.remove')}" style="margin-bottom: 0;">×</button>
        </div>
    `).join('');
}

// Re-renders only the character rows for one group, so adding/removing/reordering doesn't collapse the accordion or disturb other groups' in-progress edits.
function refreshHotkeyGroupCharsList(groupIndex) {
    const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[groupIndex];
    const list = document.getElementById(`hkgroup_${groupIndex}_charsList`);
    if (!group || !list) return;

    list.innerHTML = renderHotkeyGroupCharRows(groupIndex, group.characters);
    setupHotkeyGroupCharDragAndDrop(list, groupIndex);
    updateHotkeyGroupHeaderCount(groupIndex);
}

function updateHotkeyGroupHeaderCount(groupIndex) {
    const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[groupIndex];
    const badge = document.getElementById(`hkgroup_${groupIndex}_countBadge`);
    if (!group || !badge) return;

    badge.textContent = `(${(group.characters || []).length})`;
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
            (fromIndex, insertBeforeIndex) => reorderHotkeyGroupChars(groupIndex, fromIndex, insertBeforeIndex)
        );
    });
}

function reorderHotkeyGroupChars(groupIndex, fromIndex, insertBeforeIndex) {
    saveHotkeyGroups();

    const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[groupIndex];
    if (!group) return;

    const chars = group.characters;
    const [moved] = chars.splice(fromIndex, 1);
    const insertAt = fromIndex < insertBeforeIndex ? insertBeforeIndex - 1 : insertBeforeIndex;
    chars.splice(insertAt, 0, moved);

    refreshHotkeyGroupCharsList(groupIndex);
}

function removeHotkeyGroupCharacter(groupIndex, charIndex) {
    saveHotkeyGroups();

    const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[groupIndex];
    if (!group || !group.characters) return;

    group.characters.splice(charIndex, 1);
    markAsChanged();
    refreshHotkeyGroupCharsList(groupIndex);
}

function addHotkeyGroupCharacter(groupIndex) {
    const input = document.getElementById(`hkgroup_${groupIndex}_addChar`);
    if (!input) return;

    const name = input.value.trim();
    if (!name) return;

    saveHotkeyGroups();

    const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[groupIndex];
    if (!group) return;

    if (!group.characters) group.characters = [];
    group.characters.push(name);
    markAsChanged();
    refreshHotkeyGroupCharsList(groupIndex);

    input.value = '';
    input.focus();
}

function addHotkeyGroup() {
    if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
    saveHotkeyGroups();
    currentConfig.hotkeyGroups.push({
        name: '',
        forwardKey: '',
        backwardKey: null,
        characters: []
    });
    markAsChanged();
    populateHotkeyGroups();

    const newIndex = currentConfig.hotkeyGroups.length - 1;
    toggleHotkeyGroupAccordion(newIndex);

    setTimeout(() => {
        document.getElementById(`hkgroup_${newIndex}_accordion`)?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }, 100);
}

async function addHotkeyGroupFromClients() {
    const btn = event?.target;
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let names = [];
        if (typeof webui !== 'undefined') {
            const result = await webui.call('getOpenClients');
            names = JSON.parse(result);
        }

        if (names.length === 0) {
            showStatus(t('status.noOpenClients'), 'error');
            return;
        }

        saveHotkeyGroups();
        if (!currentConfig.hotkeyGroups) currentConfig.hotkeyGroups = [];
        currentConfig.hotkeyGroups.push({
            name: '',
            forwardKey: null,
            backwardKey: null,
            characters: names
        });
        markAsChanged();

        populateHotkeyGroups();
        const newIndex = currentConfig.hotkeyGroups.length - 1;
        toggleHotkeyGroupAccordion(newIndex);

        setTimeout(() => {
            document.getElementById(`hkgroup_${newIndex}_accordion`)?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }, 100);

        showStatus(t('status.createdHotkeyGroup').replace('{n}', names.length), 'success');
        setTimeout(() => hideStatus(), 3000);
    } catch (error) {
        logError('Failed to create hotkey group from open clients:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('common.newGroupFromClients'); }
    }
}

async function fillHotkeyGroupFromClients(index) {
    const btn = document.getElementById(`hkgroup_${index}_fillBtn`);
    if (btn) { btn.disabled = true; btn.textContent = t('status.scanningLabel'); }

    try {
        let names = [];
        if (typeof webui !== 'undefined') {
            const result = await webui.call('getOpenClients');
            names = JSON.parse(result);
        }

        if (names.length === 0) {
            showStatus(t('status.noOpenClients'), 'error');
            return;
        }

        saveHotkeyGroups();
        const group = currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[index];
        if (!group) return;

        const existingSet = new Set((group.characters || []).map(s => s.toLowerCase()));
        const toAdd = names.filter(n => !existingSet.has(n.toLowerCase()));

        if (toAdd.length === 0) {
            showStatus(t('status.allClientsInGroup'), 'info');
        } else {
            if (!group.characters) group.characters = [];
            group.characters.push(...toAdd);
            refreshHotkeyGroupCharsList(index);
            showStatus(t('status.addedCharactersToGroup').replace('{n}', toAdd.length), 'success');
        }
        setTimeout(() => hideStatus(), 3000);
    } catch (error) {
        logError('Failed to fill hotkey group from open clients:', error);
        showStatus(t('status.scanClientsFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = t('status.fillFromClientsLabel'); }
    }
}

function removeHotkeyGroup(index) {
    if (currentConfig.hotkeyGroups && currentConfig.hotkeyGroups[index]) {
        saveHotkeyGroups();
        currentConfig.hotkeyGroups.splice(index, 1);
        markAsChanged();
        populateHotkeyGroups();
    }
}

function updateHotkeyGroupHeaderName(index) {
    syncAccordionHeaderName(`hkgroup_${index}_name`, `hkgroup_${index}_header_name`, 'Hotkey Group', index);
}

function toggleHotkeyGroupAccordion(index) {
    toggleAccordion('#hotkeyGroupsList', index);
}

function saveHotkeyGroups() {
    if (!currentConfig.hotkeyGroups) return;
    
    currentConfig.hotkeyGroups.forEach((group, index) => {
        const name = document.getElementById(`hkgroup_${index}_name`);
        const forward = document.getElementById(`hkgroup_${index}_forward`);
        const backward = document.getElementById(`hkgroup_${index}_backward`);
        const charsList = document.getElementById(`hkgroup_${index}_charsList`);

        if (name) group.name = name.value || '';
        if (forward) group.forwardKey = forward.value || null;
        if (backward) group.backwardKey = backward.value || null;
        if (charsList) {
            group.characters = Array.from(charsList.querySelectorAll('.hkgroup-char-input'))
                .map(input => input.value.trim())
                .filter(s => s);
        }
    });
}

// Quick Groups: membership is hover-driven and never persisted, so there's no character-list editor here.
function populateQuickGroups() {
    const container = document.getElementById('quickGroupsList');
    if (!container) return;

    container.innerHTML = '';
    const groups = currentConfig.quickGroups || [];

    groups.forEach((group, index) => {
        const groupDiv = document.createElement('div');
        groupDiv.className = 'accordion';
        groupDiv.id = `qg_${index}_accordion`;
        groupDiv.dataset.index = index;
        const assignDisplay = vkHexToFriendly(group.assignKey) || '';
        const forwardDisplay = vkHexToFriendly(group.forwardKey) || '';
        const backwardDisplay = vkHexToFriendly(group.backwardKey) || '';
        groupDiv.innerHTML = `
            <div class="accordion-header" onclick="toggleQuickGroupAccordion(${index})">
                <div class="accordion-title">
                    <span class="accordion-toggle"></span>
                    <span class="accordion-name" id="qg_${index}_header_name">${group.name || t('dynamic.quickGroup.defaultNamePrefix') + ' ' + (index + 1)}</span>
                </div>
                <div class="accordion-header-actions">
                    <span class="accordion-hotkey-badge" id="qg_${index}_assignBadge" style="${assignDisplay ? '' : 'display:none'}">[${assignDisplay}]</span>
                    <span class="accordion-hotkey-badge" id="qg_${index}_forwardBadge" style="${forwardDisplay ? '' : 'display:none'}">→[${forwardDisplay}]</span>
                    <span class="accordion-hotkey-badge" id="qg_${index}_backwardBadge" style="${backwardDisplay ? '' : 'display:none'}">←[${backwardDisplay}]</span>
                    <button type="button" id="qg_${index}_removeBtn" onclick="event.stopPropagation(); confirmRemove('qg_${index}_removeBtn', () => removeQuickGroup(${index}))" style="margin-bottom: 0;">${t('common.remove')}</button>
                </div>
            </div>
            <div class="accordion-content">
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
                    <div>
                        <label>${t('dynamic.quickGroup.nameLabel')}</label>
                        <input type="text" id="qg_${index}_name" value="${group.name || ''}" placeholder="${t('dynamic.quickGroup.namePlaceholder')}" oninput="updateQuickGroupHeaderName(${index})">
                    </div>
                    <div>
                        <label>${t('dynamic.quickGroup.assignKeyLabel')}</label>
                        <div style="display: flex; gap: 8px; align-items: center;">${renderHotkeyInputHtml(`qg_${index}_assign`, vkHexToFriendly(group.assignKey) || '', t('dynamic.quickGroup.assignPlaceholder'))}</div>
                    </div>
                </div>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
                    <div>
                        <label>${t('dynamic.quickGroup.forwardKeyLabel')}</label>
                        <div style="display: flex; gap: 8px; align-items: center;">${renderHotkeyInputHtml(`qg_${index}_forward`, vkHexToFriendly(group.forwardKey) || '', t('dynamic.quickGroup.forwardPlaceholder'))}</div>
                    </div>
                    <div>
                        <label>${t('dynamic.quickGroup.backwardKeyLabel')}</label>
                        <div style="display: flex; gap: 8px; align-items: center;">${renderHotkeyInputHtml(`qg_${index}_backward`, vkHexToFriendly(group.backwardKey) || '', t('dynamic.quickGroup.backwardPlaceholder'))}</div>
                    </div>
                </div>
            </div>
        `;
        container.appendChild(groupDiv);
    });

    updateHotkeyConflictHighlights();
}

function addQuickGroup() {
    if (!currentConfig.quickGroups) currentConfig.quickGroups = [];
    saveQuickGroups();

    currentConfig.quickGroups.push({
        name: '',
        assignKey: null,
        forwardKey: null,
        backwardKey: null
    });
    markAsChanged();
    populateQuickGroups();

    const newIndex = currentConfig.quickGroups.length - 1;
    toggleQuickGroupAccordion(newIndex);

    setTimeout(() => {
        document.getElementById(`qg_${newIndex}_accordion`)?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }, 100);
}

function removeQuickGroup(index) {
    if (currentConfig.quickGroups && currentConfig.quickGroups[index]) {
        saveQuickGroups();
        currentConfig.quickGroups.splice(index, 1);
        markAsChanged();
        populateQuickGroups();
    }
}

function updateQuickGroupHeaderName(index) {
    syncAccordionHeaderName(`qg_${index}_name`, `qg_${index}_header_name`, 'Quick Group', index);
}

function toggleQuickGroupAccordion(index) {
    toggleAccordion('#quickGroupsList', index);
}

function saveQuickGroups() {
    if (!currentConfig.quickGroups) return;

    currentConfig.quickGroups.forEach((group, index) => {
        const name = document.getElementById(`qg_${index}_name`);
        const assign = document.getElementById(`qg_${index}_assign`);
        const forward = document.getElementById(`qg_${index}_forward`);
        const backward = document.getElementById(`qg_${index}_backward`);

        if (name) group.name = name.value || '';
        if (assign) group.assignKey = assign.value || null;
        if (forward) group.forwardKey = forward.value || null;
        if (backward) group.backwardKey = backward.value || null;
    });
}

// Mirrors each quick group's assign/forward/backward inputs into its accordion header badges.
function refreshQuickGroupBadges() {
    document.querySelectorAll('#quickGroupsList > .accordion').forEach(accordion => {
        const index = accordion.dataset.index;
        [['assign', ''], ['forward', '→'], ['backward', '←']].forEach(([direction, arrow]) => {
            const input = document.getElementById(`qg_${index}_${direction}`);
            const badge = document.getElementById(`qg_${index}_${direction}Badge`);
            if (!input || !badge) return;

            const value = input.value.trim();
            const display = value && value !== 'Press keys...' && value !== 'Waiting for input...' ? value : '';
            badge.textContent = display ? `${arrow}[${display}]` : '';
            badge.style.display = display ? '' : 'none';
        });
    });
}

async function loadGlobalSettingsFromBackend() {
    try {
        if (typeof webui !== 'undefined') {
            const json = await webui.call('loadGlobalSettings');
            currentGlobalSettings = JSON.parse(json);
        } else {
            currentGlobalSettings = {};
        }
    } catch (error) {
        logError('Failed to load global settings:', error);
        currentGlobalSettings = {};
    }

    if (!currentGlobalSettings.profileSwitchHotkeys) currentGlobalSettings.profileSwitchHotkeys = [];
    await populateProfileSwitchHotkeys();

    if (!currentGlobalSettings.oreTable) currentGlobalSettings.oreTable = [];
    populateOreTable();

    setFieldValue('logLevel', currentGlobalSettings.logLevel || 'err');
    setFieldValue('languageSelect', currentGlobalSettings.language || 'en');
    setFieldValue('hotkeyNextProfile', vkHexToFriendly(currentGlobalSettings.hotkeyNextProfile));
    setFieldValue('hotkeyPreviousProfile', vkHexToFriendly(currentGlobalSettings.hotkeyPreviousProfile));
    setFieldValue('hotkeyCycleAllClientsForward', vkHexToFriendly(currentGlobalSettings.hotkeyCycleAllClientsForward));
    setFieldValue('hotkeyCycleAllClientsBackward', vkHexToFriendly(currentGlobalSettings.hotkeyCycleAllClientsBackward));
    setCheckboxValue('cycleAllClientsRespectExclusions', currentGlobalSettings.cycleAllClientsRespectExclusions);
    setFieldValue('hotkeyCycleNotLoggedInForward', vkHexToFriendly(currentGlobalSettings.hotkeyCycleNotLoggedInForward));
    setFieldValue('hotkeyCycleNotLoggedInBackward', vkHexToFriendly(currentGlobalSettings.hotkeyCycleNotLoggedInBackward));

    const advancedModeEnabled = !!currentGlobalSettings.advancedMode;
    const advancedToggle = document.getElementById('advancedModeToggle');
    if (advancedToggle) advancedToggle.checked = advancedModeEnabled;
    document.body.classList.toggle('advanced-mode', advancedModeEnabled);
    buildSectionNav();

    refreshCharacterPortraits();
}

// Preference lives in global.settings.json so it applies across all profiles.
function toggleAdvancedMode() {
    const enabled = document.getElementById('advancedModeToggle').checked;
    document.body.classList.toggle('advanced-mode', enabled);
    buildSectionNav();

    if (!currentGlobalSettings) currentGlobalSettings = {};
    currentGlobalSettings.advancedMode = enabled;

    // If an advanced-only tab was open when Advanced Mode got turned off, its sidebar entry just vanished - move to the always-visible About tab.
    if (!enabled) {
        const activePanel = document.querySelector('.panel-content.active');
        if (activePanel && activePanel.classList.contains('advanced-tab-panel')) {
            switchTab('about');
        }
    }
}

async function getAvailableProfileNames() {
    try {
        if (typeof webui !== 'undefined') {
            const response = await webui.call('listProfiles');
            const data = JSON.parse(response);
            return data.profiles || [];
        }
    } catch (error) {
        logError('Failed to load profile list for profile switch hotkeys:', error);
    }
    return [];
}

function profileSwitchHotkeyLabel(targetProfile, index) {
    return targetProfile ? `${t('dynamic.profileSwitchHotkey.switchPrefix')}${targetProfile.replace(/\.json$/, '')}` : `${t('dynamic.profileSwitchHotkey.defaultLabelPrefix')}${index + 1}`;
}

async function populateProfileSwitchHotkeys() {
    const container = document.getElementById('profileSwitchHotkeysList');
    if (!container) return;

    const profiles = await getAvailableProfileNames();
    const entries = currentGlobalSettings?.profileSwitchHotkeys || [];

    container.innerHTML = '';
    entries.forEach((entry, index) => {
        // If no target is set yet, the <select> auto-selects its first option, so treat that as the effective target for the header label too.
        const effectiveTarget = entry.targetProfile || profiles[0] || '';
        const optionsHtml = profiles.map(p => {
            const selected = p === effectiveTarget ? ' selected' : '';
            return `<option value="${p}"${selected}>${p.replace(/\.json$/, '')}</option>`;
        }).join('');

        const row = document.createElement('div');
        row.className = 'accordion';
        row.innerHTML = `
            <div class="accordion-header" onclick="toggleProfileSwitchHotkeyAccordion(${index})">
                <div class="accordion-title">
                    <span class="accordion-toggle"></span>
                    <span class="accordion-name" id="pshotkey_${index}_header_name">${profileSwitchHotkeyLabel(effectiveTarget, index)}</span>
                </div>
                <button type="button" id="pshotkey_${index}_removeBtn" onclick="event.stopPropagation(); confirmRemove('pshotkey_${index}_removeBtn', () => removeProfileSwitchHotkey(${index}))" style="margin-bottom: 0;">${t('common.remove')}</button>
            </div>
            <div class="accordion-content">
                <label>${t('dynamic.profileSwitchHotkey.targetLabel')}</label>
                <select id="pshotkey_${index}_target" onchange="updateProfileSwitchHotkeyHeaderName(${index})" style="margin-bottom: 8px;">
                    ${optionsHtml}
                </select>
                <label>${t('common.hotkeyLabel')}</label>
                <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 0;">${renderHotkeyInputHtml(`pshotkey_${index}_hotkey`, vkHexToFriendly(entry.hotkey) || '', t('dynamic.profileSwitchHotkey.hotkeyPlaceholder'))}</div>
            </div>
        `;
        container.appendChild(row);
    });

    updateHotkeyConflictHighlights();
}

function addProfileSwitchHotkey() {
    if (!currentGlobalSettings) currentGlobalSettings = {};
    if (!currentGlobalSettings.profileSwitchHotkeys) currentGlobalSettings.profileSwitchHotkeys = [];
    saveProfileSwitchHotkeys();

    currentGlobalSettings.profileSwitchHotkeys.push({
        hotkey: null,
        targetProfile: ''
    });
    markAsChanged();

    populateProfileSwitchHotkeys().then(() => {
        const newIndex = currentGlobalSettings.profileSwitchHotkeys.length - 1;
        toggleProfileSwitchHotkeyAccordion(newIndex);

        const contentPanel = document.getElementById('content-panel');
        if (contentPanel) {
            setTimeout(() => {
                contentPanel.scrollTop = contentPanel.scrollHeight;
            }, 100);
        }
    });
}

function removeProfileSwitchHotkey(index) {
    if (currentGlobalSettings?.profileSwitchHotkeys && currentGlobalSettings.profileSwitchHotkeys[index]) {
        saveProfileSwitchHotkeys();
        currentGlobalSettings.profileSwitchHotkeys.splice(index, 1);
        markAsChanged();
        populateProfileSwitchHotkeys();
    }
}

function updateProfileSwitchHotkeyHeaderName(index) {
    const select = document.getElementById(`pshotkey_${index}_target`);
    const headerName = document.getElementById(`pshotkey_${index}_header_name`);

    if (select && headerName) {
        headerName.textContent = profileSwitchHotkeyLabel(select.value, index);
    }
}

function toggleProfileSwitchHotkeyAccordion(index) {
    toggleAccordion('#profileSwitchHotkeysList', index);
}

function saveProfileSwitchHotkeys() {
    if (!currentGlobalSettings?.profileSwitchHotkeys) return;

    currentGlobalSettings.profileSwitchHotkeys.forEach((entry, index) => {
        const target = document.getElementById(`pshotkey_${index}_target`);
        const hotkey = document.getElementById(`pshotkey_${index}_hotkey`);

        if (target) entry.targetProfile = target.value || '';
        if (hotkey) entry.hotkey = hotkey.value || null;
    });
}

const ORE_CATEGORIES = ['Ore', 'Ice', 'Moons', 'Gas'];

function oreCategoryRank(category) {
    const i = ORE_CATEGORIES.indexOf(category);
    return i === -1 ? ORE_CATEGORIES.length : i;
}

// Price is the only user-editable field shown - name, category, and m3/unit are still tracked internally (see OreEntry in config.zig) and fixed, but category still drives the grouped/sorted display below (same rowspan'd-label + separator-border technique as the Event Alerts table's populateNotificationTypes).
// Name is deliberately not editable: chatlog.zig matches mined-ore log lines against this exact string, so renaming a row would silently break that ore's lookup.
function populateOreTable() {
    const tbody = document.getElementById('oreTableBody');
    if (!tbody) return;

    const entries = currentGlobalSettings?.oreTable || [];

    const displayOrder = entries.map((entry, index) => ({ entry, index }));
    displayOrder.sort((a, b) => {
        const rankDiff = oreCategoryRank(a.entry.category) - oreCategoryRank(b.entry.category);
        return rankDiff !== 0 ? rankDiff : a.index - b.index;
    });

    const categoryRowCounts = {};
    displayOrder.forEach(({ entry }) => {
        const category = entry.category || 'Ore';
        categoryRowCounts[category] = (categoryRowCounts[category] || 0) + 1;
    });

    tbody.innerHTML = '';
    let lastCategory = null;
    displayOrder.forEach(({ entry, index }) => {
        const category = entry.category || 'Ore';
        const isFirstInCategory = category !== lastCategory;
        const isFirstCategoryOverall = lastCategory === null;
        lastCategory = category;

        const row = document.createElement('tr');
        if (isFirstInCategory && !isFirstCategoryOverall) row.className = 'category-separator';

        row.innerHTML = `
            ${isFirstInCategory ? `<td rowspan="${categoryRowCounts[category]}" class="category-cell"><span class="category-cell-label">${escapeHtml(category)}</span></td>` : ''}
            <td class="event-name-cell">${escapeHtml(entry.name || '')}</td>
            <td><input type="number" class="ore-price-input" id="ore_${index}_price" value="${entry.price ?? 0}" min="0" step="0.01"></td>
        `;
        tbody.appendChild(row);
    });
}

function saveOreTable() {
    if (!currentGlobalSettings?.oreTable) return;

    currentGlobalSettings.oreTable.forEach((entry, index) => {
        const price = document.getElementById(`ore_${index}_price`);

        if (price) entry.price = parseFloat(price.value) || 0;
    });
}

let isFetchingOrePrices = false;

// Looks up each row's Jita buy price via ESI (public, no key needed) - see fetchOrePrices in config_dialog.zig for the actual request.
async function fetchOrePrices() {
    if (isFetchingOrePrices) return;
    if (!currentGlobalSettings?.oreTable?.length) return;

    saveOreTable();
    const names = currentGlobalSettings.oreTable.map(e => e.name).filter(n => n);
    if (names.length === 0) return;

    isFetchingOrePrices = true;
    const btn = document.getElementById('fetchOrePricesBtn');
    if (btn) btn.disabled = true;
    showStatus(`Fetching ${names.length} price(s) from ESI...`, 'info');

    try {
        const response = await webui.call('fetchOrePrices', JSON.stringify(names));
        const prices = JSON.parse(response);

        let updated = 0;
        currentGlobalSettings.oreTable.forEach(entry => {
            if (Object.prototype.hasOwnProperty.call(prices, entry.name)) {
                entry.price = prices[entry.name];
                updated++;
            }
        });

        markAsChanged();
        populateOreTable();
        showStatus(`Updated ${updated} of ${names.length} price(s) from ESI.`, updated > 0 ? 'success' : 'error');
    } catch (error) {
        logError('Failed to fetch ore prices:', error);
        showStatus('Failed to fetch prices from ESI.', 'error');
    } finally {
        isFetchingOrePrices = false;
        if (btn) btn.disabled = false;
        setTimeout(() => hideStatus(), 4000);
    }
}

const NOTIFICATION_TYPES = [
    { key: 'FleetInvite', category: 'fleet' },
    { key: 'FleetFollow', category: 'fleet' },
    { key: 'FleetRegroup', category: 'fleet' },
    { key: 'FleetDisband', category: 'fleet' },
    { key: 'MiningCompression', category: 'mining' },
    { key: 'AsteroidDepleted', category: 'mining' },
    { key: 'MiningIdle', category: 'mining' },
    { key: 'MiningStopped', category: 'mining' },
    { key: 'CargoFull', category: 'mining' },
    { key: 'CrystalBroke', category: 'mining' },
    { key: 'TakingDamage', category: 'combat' },
    { key: 'WarpScrambled', category: 'combat' },
    { key: 'WarpDisrupted', category: 'combat' },
    { key: 'Decloak', category: 'combat' },
    { key: 'ObservatoryDecloak', category: 'combat' },
    { key: 'CloakFailed', category: 'combat' },
    { key: 'BombLauncherEmpty', category: 'combat' },
    { key: 'SelfDestruct', category: 'combat' },
    { key: 'WarpBubble', category: 'combat' },
    { key: 'Docking', category: 'navigation' },
    { key: 'AutopilotReached', category: 'navigation' },
    { key: 'AutopilotApproaching', category: 'navigation' },
    { key: 'JumpRange', category: 'navigation' },
    { key: 'AggressionCantJump', category: 'navigation' },
    { key: 'ConduitJump', category: 'navigation' },
    { key: 'JumpCloning', category: 'navigation' },
    { key: 'SystemChange', category: 'navigation' },
    { key: 'ConversationInvite', category: 'general' },
    { key: 'Generic', category: 'general' }
];

const NOTIFICATION_CATEGORY_LABEL_KEYS = {
    fleet: 'notification.category.fleet.heading',
    mining: 'notification.category.mining.heading',
    combat: 'notification.category.combat-defense.heading',
    navigation: 'notification.category.navigation-travel.heading',
    general: 'notification.category.general.heading'
};

// Single source for the notification table's default swatch colors, falling back to '#FFFFFF'/'#606060' until defaultConfig loads. Border is an approximation - the true fallback is the Alert state's border color, which isn't wired up in this dialog yet.
function notifDefaultTextColorHtml() {
    return defaultConfig?.thumbnail?.textColor != null ? zigColorToHtml(defaultConfig.thumbnail.textColor) : '#FFFFFF';
}
function notifDefaultBorderColorHtml() {
    return defaultConfig?.thumbnail?.inactiveBorderColor != null ? zigColorToHtml(defaultConfig.thumbnail.inactiveBorderColor) : '#606060';
}

function populateNotificationTypes() {
    const container = document.getElementById('notificationTypesList');
    if (!container) return;
    
    container.innerHTML = '';

    if (!currentConfig.thumbnail) currentConfig.thumbnail = {};
    if (!currentConfig.thumbnail.notifications) currentConfig.thumbnail.notifications = {};
    if (!currentConfig.thumbnail.notifications.type_configs) {
        currentConfig.thumbnail.notifications.type_configs = {};
    }
    
    const typeConfigs = currentConfig.thumbnail.notifications.type_configs;

    const categoryRowCounts = {};
    NOTIFICATION_TYPES.forEach((nt) => {
        categoryRowCounts[nt.category] = (categoryRowCounts[nt.category] || 0) + 1;
    });
    let lastCategory = null;

    NOTIFICATION_TYPES.forEach((notifType) => {
        const isFirstInCategory = notifType.category !== lastCategory;
        const isFirstCategoryOverall = lastCategory === null;
        lastCategory = notifType.category;

        const config = typeConfigs[notifType.key] || {};

        const row = document.createElement('tr');
        row.id = `notif_${notifType.key}_row`;
        if (isFirstInCategory && !isFirstCategoryOverall) row.className = 'category-separator';

        const hasBorderColor = config.border_color != null;
        const borderColorHtml = hasBorderColor ? zigColorToHtml(config.border_color) : notifDefaultBorderColorHtml();
        const hasTextColor = config.text_color != null;
        const textColorHtml = hasTextColor ? zigColorToHtml(config.text_color) : notifDefaultTextColorHtml();

        row.innerHTML = `
            ${isFirstInCategory ? `<td rowspan="${categoryRowCounts[notifType.category]}" class="category-cell"><span class="category-cell-label">${t(NOTIFICATION_CATEGORY_LABEL_KEYS[notifType.category])}</span></td>` : ''}
            <td class="event-name-cell">
                <div class="event-name">${t('notification.' + notifType.key + '.label')}</div>
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_enabled" ${config.enabled ? 'checked' : ''}
                           onchange="toggleNotificationTypeEnabled('${notifType.key}')">
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <input type="number" id="notif_${notifType.key}_duration" min="0" max="60" step="0.1"
                       value="${config.duration_ms && config.duration_ms > 0 ? config.duration_ms / 1000 : 5}">
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_suppressFocused" 
                           ${config.suppress_when_focused ? 'checked' : ''}>
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_suppressClicked"
                           ${config.suppress_when_clicked ? 'checked' : ''}>
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <input type="number" id="notif_${notifType.key}_throttle" min="0" max="300" step="1"
                       title="Ignore repeat notifications of this type within this many seconds of the last one shown (0 = off)"
                       value="${config.throttle_ms !== undefined ? config.throttle_ms / 1000 : 10}">
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_tts"
                           ${config.tts_enabled ? 'checked' : ''}>
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <div style="display: flex; align-items: center; justify-content: center; gap: 4px;">
                    <input type="checkbox" id="notif_${notifType.key}_textColorEnabled"
                           title="Enable per-type notification text color override"
                           ${hasTextColor ? 'checked' : ''}
                           onchange="toggleNotifTextColor('${notifType.key}')">
                    <div class="swatch-wrap">
                        <input type="color" id="notif_${notifType.key}_textColor"
                               value="${textColorHtml}"
                               data-optional-color="true"
                               data-default-color="${notifDefaultTextColorHtml()}"
                               data-null-checkbox="notif_${notifType.key}_textColorEnabled"
                               data-base-title="Notification text color while this notification is active"
                               ${!hasTextColor ? 'data-cleared="true"' : ''}
                               title="${hasTextColor ? 'Notification text color while this notification is active' : 'Not set - inheriting default text color'}"
                               onchange="document.getElementById('notif_${notifType.key}_textColorEnabled').checked = true">
                    </div>
                </div>
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_showBorder"
                           title="Draw a border while this notification is active"
                           ${config.show_border ? 'checked' : ''}
                           onchange="toggleNotifShowBorder('${notifType.key}')">
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <label>
                    <input type="checkbox" id="notif_${notifType.key}_flashBorder"
                           title="Blink the border on/off 4 times when the notification starts"
                           ${config.flash_border ? 'checked' : ''}>
                    <span class="label-body"></span>
                </label>
            </td>
            <td style="text-align: center;">
                <div style="display: flex; align-items: center; justify-content: center; gap: 4px;">
                    <input type="checkbox" id="notif_${notifType.key}_borderColorEnabled"
                           title="Enable per-type border color override"
                           ${hasBorderColor ? 'checked' : ''}
                           onchange="toggleNotifBorderColor('${notifType.key}')">
                    <div class="swatch-wrap">
                        <input type="color" id="notif_${notifType.key}_borderColor"
                               value="${borderColorHtml}"
                               data-optional-color="true"
                               data-default-color="${notifDefaultBorderColorHtml()}"
                               data-null-checkbox="notif_${notifType.key}_borderColorEnabled"
                               data-base-title="Border color while this notification is active"
                               ${!hasBorderColor ? 'data-cleared="true"' : ''}
                               title="${hasBorderColor ? 'Border color while this notification is active' : 'Not set - inheriting default border color'}"
                               onchange="document.getElementById('notif_${notifType.key}_borderColorEnabled').checked = true">
                    </div>
                </div>
            </td>
        `;
        
        container.appendChild(row);

        toggleNotificationTypeEnabled(notifType.key);
    });

    toggleNotificationOptions();
}

function toggleNotificationTypeEnabled(typeKey) {
    const enabledCheckbox = document.getElementById(`notif_${typeKey}_enabled`);
    const durationInput = document.getElementById(`notif_${typeKey}_duration`);
    const suppressFocusedCheckbox = document.getElementById(`notif_${typeKey}_suppressFocused`);
    const suppressClickedCheckbox = document.getElementById(`notif_${typeKey}_suppressClicked`);
    const throttleInput = document.getElementById(`notif_${typeKey}_throttle`);
    const ttsCheckbox = document.getElementById(`notif_${typeKey}_tts`);
    const showBorderCheckbox = document.getElementById(`notif_${typeKey}_showBorder`);
    const flashBorderCheckbox = document.getElementById(`notif_${typeKey}_flashBorder`);
    const borderColorEnabledCheckbox = document.getElementById(`notif_${typeKey}_borderColorEnabled`);
    const borderColorInput = document.getElementById(`notif_${typeKey}_borderColor`);
    const textColorEnabledCheckbox = document.getElementById(`notif_${typeKey}_textColorEnabled`);
    const textColorInput = document.getElementById(`notif_${typeKey}_textColor`);

    const isEnabled = enabledCheckbox && enabledCheckbox.checked;
    const ttsMasterEnabled = document.getElementById('ttsEnabled');
    const isTtsAvailable = isEnabled && ttsMasterEnabled && ttsMasterEnabled.checked;

    if (durationInput) durationInput.disabled = !isEnabled;
    if (suppressFocusedCheckbox) suppressFocusedCheckbox.disabled = !isEnabled;
    if (suppressClickedCheckbox) suppressClickedCheckbox.disabled = !isEnabled;
    if (throttleInput) throttleInput.disabled = !isEnabled;
    if (ttsCheckbox) ttsCheckbox.disabled = !isTtsAvailable;
    if (showBorderCheckbox) showBorderCheckbox.disabled = !isEnabled;
    // Text color isn't tied to the border - it renders whenever the notification is enabled, regardless of border visibility.
    if (textColorEnabledCheckbox) textColorEnabledCheckbox.disabled = !isEnabled;
    if (textColorInput) textColorInput.disabled = !isEnabled;
    // Border override/color/flash are further gated by Show Border: a hidden border has no color to set and nothing to flash.
    const showBorderChecked = !showBorderCheckbox || showBorderCheckbox.checked;
    if (borderColorEnabledCheckbox) borderColorEnabledCheckbox.disabled = !isEnabled || !showBorderChecked;
    if (borderColorInput) borderColorInput.disabled = !isEnabled || !showBorderChecked;
    if (flashBorderCheckbox) flashBorderCheckbox.disabled = !isEnabled || !showBorderChecked;
}

function toggleNotifShowBorder(typeKey) {
    toggleNotificationTypeEnabled(typeKey);
}

// Keeps the swatch's cleared indicator/tooltip in sync when the checkbox is toggled directly instead of via the picker's "Clear to Default" button.
function toggleNotifBorderColor(typeKey) {
    syncNotifSwatchClearedState(`notif_${typeKey}_borderColorEnabled`, `notif_${typeKey}_borderColor`);
}

function toggleNotifTextColor(typeKey) {
    syncNotifSwatchClearedState(`notif_${typeKey}_textColorEnabled`, `notif_${typeKey}_textColor`);
}

function syncNotifSwatchClearedState(checkboxId, inputId) {
    const cb = document.getElementById(checkboxId);
    const input = document.getElementById(inputId);
    if (!cb || !input) return;

    if (cb.checked) {
        delete input.dataset.cleared;
        input.title = input.dataset.baseTitle || '';
        if (!input.title) input.removeAttribute('title');
    } else {
        input.dataset.cleared = 'true';
        input.title = 'Not set - inheriting default color';
    }
}

function resetNotificationColors(kind, defaultColorHtml) {
    NOTIFICATION_TYPES.forEach((notifType) => {
        const cb = document.getElementById(`notif_${notifType.key}_${kind}ColorEnabled`);
        const input = document.getElementById(`notif_${notifType.key}_${kind}Color`);
        if (cb) cb.checked = false;
        if (input) {
            input.value = defaultColorHtml();
            input.dataset.cleared = 'true';
            input.title = 'Not set - inheriting default color';
        }
    });
    markAsChanged();
}

function resetNotificationBorderColors() {
    resetNotificationColors('border', notifDefaultBorderColorHtml);
}

function resetNotificationTextColors() {
    resetNotificationColors('text', notifDefaultTextColorHtml);
}

// Returns the checkbox's checked state (or undefined if either element is missing) so callers that need to chain extra logic still can.
function applyOptionToggle(checkboxId, optionsId) {
    const checkbox = document.getElementById(checkboxId);
    const options = document.getElementById(optionsId);
    if (!checkbox || !options) return undefined;

    const enabled = checkbox.checked;
    options.style.opacity = enabled ? '1' : '0.5';
    options.style.pointerEvents = enabled ? 'auto' : 'none';
    return enabled;
}

function toggleSnappingOptions() {
    applyOptionToggle('snappingEnabled', 'snappingOptions');
}

function toggleClientListOptions() {
    const viewMode = document.getElementById('viewMode');
    const clientListOptions = document.getElementById('clientListOptions');
    const listViewOrder = document.getElementById('listViewOrder');
    const rememberListViewPosition = document.getElementById('rememberListViewPosition');
    const listViewOpacity = document.getElementById('listViewOpacity');
    const listViewColumns = document.getElementById('listViewColumns');
    const listViewFontName = document.getElementById('listViewFontName');
    const listViewFontSize = document.getElementById('listViewFontSize');
    const listViewFontWeight = document.getElementById('listViewFontWeight');

    if (!viewMode || !clientListOptions) return;

    const isClientList = viewMode.value === 'ClientList';

    clientListOptions.style.opacity = isClientList ? '1' : '0.5';
    clientListOptions.style.pointerEvents = isClientList ? 'auto' : 'none';

    if (listViewOrder) listViewOrder.disabled = !isClientList;
    if (rememberListViewPosition) rememberListViewPosition.disabled = !isClientList;
    if (listViewOpacity) listViewOpacity.disabled = !isClientList;
    if (listViewColumns) listViewColumns.disabled = !isClientList;
    if (listViewFontName) listViewFontName.disabled = !isClientList;
    if (listViewFontSize) listViewFontSize.disabled = !isClientList;
    if (listViewFontWeight) listViewFontWeight.disabled = !isClientList;
}

function toggleAspectRatioSlider() {
    const checkbox = document.getElementById('constrainAspectRatio');
    const container = document.getElementById('aspectRatioSliderContainer');
    if (!checkbox || !container) return;

    if (checkbox.checked) {
        container.style.opacity = '1';
        container.style.pointerEvents = 'auto';
        const w = parseFloat(document.getElementById('thumbWidth').value) || 200;
        const h = parseFloat(document.getElementById('thumbHeight').value) || 150;
        checkbox._baseWidth = w;
        checkbox._baseHeight = h;
        document.getElementById('thumbSizeSlider').value = 100;
        document.getElementById('thumbSizeValue').textContent = '100';
    } else {
        container.style.opacity = '0.5';
        container.style.pointerEvents = 'none';
    }
}

function onThumbSizeSlider() {
    const checkbox = document.getElementById('constrainAspectRatio');
    if (!checkbox || !checkbox.checked) return;
    const slider = document.getElementById('thumbSizeSlider');
    const pct = parseFloat(slider.value) / 100;
    document.getElementById('thumbSizeValue').textContent = slider.value;
    const newW = Math.round((checkbox._baseWidth || 200) * pct);
    const newH = Math.round((checkbox._baseHeight || 150) * pct);
    document.getElementById('thumbWidth').value = newW;
    document.getElementById('thumbHeight').value = newH;
}

function onThumbWidthInput() {
    const checkbox = document.getElementById('constrainAspectRatio');
    if (!checkbox || !checkbox.checked) return;
    const w = parseFloat(document.getElementById('thumbWidth').value);
    if (!w || !checkbox._baseWidth || !checkbox._baseHeight) return;
    const newH = Math.round(w * (checkbox._baseHeight / checkbox._baseWidth));
    document.getElementById('thumbHeight').value = newH;
    const pct = Math.round((w / checkbox._baseWidth) * 100);
    document.getElementById('thumbSizeSlider').value = pct;
    document.getElementById('thumbSizeValue').textContent = pct;
}

function onThumbHeightInput() {
    const checkbox = document.getElementById('constrainAspectRatio');
    if (!checkbox || !checkbox.checked) return;
    const h = parseFloat(document.getElementById('thumbHeight').value);
    if (!h || !checkbox._baseWidth || !checkbox._baseHeight) return;
    const newW = Math.round(h * (checkbox._baseWidth / checkbox._baseHeight));
    document.getElementById('thumbWidth').value = newW;
    const pct = Math.round((h / checkbox._baseHeight) * 100);
    document.getElementById('thumbSizeSlider').value = pct;
    document.getElementById('thumbSizeValue').textContent = pct;
}

function toggleWindowFilters() {
    applyOptionToggle('windowFiltersEnabled', 'windowFiltersOptions');
}

function toggleBorderOptions() {
    applyOptionToggle('borderEnabled', 'borderOptions');
    toggleUniqueCharacterColors();
}

function toggleFocusedBorderOptions() {
    applyOptionToggle('showBorderWhenFocused', 'focusedBorderOptions');
}

function toggleInactiveBorderOptions() {
    applyOptionToggle('showBorderWhenInactive', 'inactiveBorderOptions');
}

function toggleUniqueCharacterColors() {
    const uniqueColorsCheckbox = document.getElementById('assignUniqueCharacterColors');
    const focusedBorderColorOptions = document.getElementById('focusedBorderColorOptions');
    
    if (uniqueColorsCheckbox && focusedBorderColorOptions) {
        if (uniqueColorsCheckbox.checked) {
            focusedBorderColorOptions.style.opacity = '0.5';
            focusedBorderColorOptions.style.pointerEvents = 'none';

            assignUniqueColorsToAllCharacters();
        } else {
            focusedBorderColorOptions.style.opacity = '1';
            focusedBorderColorOptions.style.pointerEvents = 'auto';
        }
    }
}

function assignUniqueColorsToAllCharacters() {
    if (!currentConfig.characters) return;
    saveCharacters();
    currentConfig.characters.forEach((char, index) => {
        if (!char.borderColors) {
            char.borderColors = {};
        }
        char.borderColors.activeBorderColor = generateUniqueColor(index);
    });
    populateCharacters();
}

function toggleTextDisplayOptions() {
    applyOptionToggle('showText', 'textDisplayOptions');
}

function toggleCharacterNameOptions() {
    applyOptionToggle('showCharacterName', 'characterNameOptions');
}

function toggleSystemNameOptions() {
    applyOptionToggle('showSystemName', 'systemNameOptions');
}

function toggleQuickGroupBadgeOptions() {
    applyOptionToggle('showQuickGroupBadge', 'quickGroupBadgeOptions');
}

function toggleTextBgColorOptions() {
    const inherit = document.getElementById('textBgColorInheritBorderColor');
    const textBgColor = document.getElementById('textBgColor');

    if (inherit && textBgColor) {
        textBgColor.disabled = inherit.checked;
    }
}

// Opposite polarity of applyOptionToggle(): the target options are disabled when the checkbox IS checked.
function toggleInverseOption(checkboxId, optionsId) {
    const checkbox = document.getElementById(checkboxId);
    const options = document.getElementById(optionsId);
    if (!checkbox || !options) return;

    const disabled = checkbox.checked;
    options.style.opacity = disabled ? '0.5' : '1';
    options.style.pointerEvents = disabled ? 'none' : 'auto';
}

function toggleUniqueSystemColors() {
    toggleInverseOption('useUniqueSystemColors', 'systemNameColorOption');
}

function toggleUniqueCharacterNameColors() {
    toggleInverseOption('useUniqueCharacterNameColors', 'textColorOption');
}

function toggleAutoMinimizeOptions() {
    applyOptionToggle('autoMinimizeEnabled', 'autoMinimizeOptions');
}

function toggleNotificationOptions() {
    const notificationsEnabled = document.getElementById('notificationsEnabled');
    const notificationOptions = document.getElementById('notificationOptions');
    const notificationTypesTable = document.getElementById('notificationTypesTable');
    
    if (notificationsEnabled && notificationOptions) {
        const isEnabled = notificationsEnabled.checked;

        if (isEnabled) {
            notificationOptions.style.opacity = '1';
            notificationOptions.style.pointerEvents = 'auto';
        } else {
            notificationOptions.style.opacity = '0.5';
            notificationOptions.style.pointerEvents = 'none';
        }

        if (notificationTypesTable) {
            const inputs = notificationTypesTable.querySelectorAll('input');
            inputs.forEach(input => {
                input.disabled = !isEnabled;
            });

            // Re-apply per-row state so border color pickers aren't spuriously enabled when their per-type checkbox is unchecked.
            if (isEnabled && typeof NOTIFICATION_TYPES !== 'undefined') {
                NOTIFICATION_TYPES.forEach(nt => toggleNotificationTypeEnabled(nt.key));
            }
        }
    }
}

function toggleTtsOptions() {
    const ttsEnabled = document.getElementById('ttsEnabled');
    const ttsOptions = document.getElementById('ttsOptions');

    if (ttsEnabled && ttsOptions) {
        const isEnabled = ttsEnabled.checked;
        ttsOptions.style.opacity = isEnabled ? '1' : '0.5';
        ttsOptions.style.pointerEvents = isEnabled ? 'auto' : 'none';

        const inputs = ttsOptions.querySelectorAll('input');
        inputs.forEach(input => {
            input.disabled = !isEnabled;
        });
    }

    // The per-type "TTS" checkboxes only matter when the master switch is on.
    if (typeof NOTIFICATION_TYPES !== 'undefined') {
        NOTIFICATION_TYPES.forEach(nt => toggleNotificationTypeEnabled(nt.key));
    }
}

function toggleChatlogOptions() {
    applyOptionToggle('chatlogEnabled', 'chatlogOptions');
}

function toggleCombatOptions() {
    applyOptionToggle('combatEnabled', 'combatOptions');
    applyOptionToggle('combatEnabled', 'combatAlertsOptions');
}

function toggleMiningOptions() {
    applyOptionToggle('miningEnabled', 'miningOptions');
    applyOptionToggle('miningEnabled', 'miningAlertsOptions');
    applyOptionToggle('miningShowIskRate', 'miningIskRateOptions');
}

function toggleBountyOptions() {
    applyOptionToggle('bountyEnabled', 'bountyOptions');
}

async function browseChatlogDir() {
    console.log('Browsing for chatlog directory...');
    
    try {
        if (typeof webui !== 'undefined') {
            const result = await webui.call('browseChatlogDir');
            if (result && result !== '') {
                const chatlogDirInput = document.getElementById('chatlogDir');
                if (chatlogDirInput) {
                    chatlogDirInput.value = result;
                }
            }
        } else {
            logWarn('WebUI not available for browsing chatlog directory');
        }
    } catch (error) {
        logError('Failed to browse chatlog directory:', error);
    }
}

async function browseGamelogDir() {
    console.log('Browsing for gamelog directory...');
    
    try {
        if (typeof webui !== 'undefined') {
            const result = await webui.call('browseGamelogDir');
            if (result && result !== '') {
                const gamelogDirInput = document.getElementById('gamelogDir');
                if (gamelogDirInput) {
                    gamelogDirInput.value = result;
                }
            }
        } else {
            logWarn('WebUI not available for browsing gamelog directory');
        }
    } catch (error) {
        logError('Failed to browse gamelog directory:', error);
    }
}

function saveNotificationTypes() {
    if (!currentConfig.thumbnail) currentConfig.thumbnail = {};
    if (!currentConfig.thumbnail.notifications) currentConfig.thumbnail.notifications = {};
    if (!currentConfig.thumbnail.notifications.type_configs) {
        currentConfig.thumbnail.notifications.type_configs = {};
    }
    
    const typeConfigs = currentConfig.thumbnail.notifications.type_configs;

    NOTIFICATION_TYPES.forEach((notifType) => {
        const enabled = document.getElementById(`notif_${notifType.key}_enabled`);
        const duration = document.getElementById(`notif_${notifType.key}_duration`);
        const suppressFocused = document.getElementById(`notif_${notifType.key}_suppressFocused`);
        const suppressClicked = document.getElementById(`notif_${notifType.key}_suppressClicked`);
        const throttle = document.getElementById(`notif_${notifType.key}_throttle`);
        const ttsTypeEnabled = document.getElementById(`notif_${notifType.key}_tts`);

        if (!enabled) return;

        if (!typeConfigs[notifType.key]) {
            typeConfigs[notifType.key] = {};
        }

        const config = typeConfigs[notifType.key];

        config.enabled = enabled.checked;

        // Use explicit duration value (in seconds) or default to 5s, convert to ms for backend
        const durationValue = duration && duration.value ? parseFloat(duration.value) * 1000 : 5000;
        config.duration_ms = Math.round(durationValue);

        config.suppress_when_focused = suppressFocused ? suppressFocused.checked : false;
        config.suppress_when_clicked = suppressClicked ? suppressClicked.checked : false;

        const throttleValue = throttle && throttle.value ? parseFloat(throttle.value) * 1000 : 0;
        config.throttle_ms = Math.round(throttleValue);

        config.tts_enabled = ttsTypeEnabled ? ttsTypeEnabled.checked : false;

        const showBorder = document.getElementById(`notif_${notifType.key}_showBorder`);
        config.show_border = showBorder ? showBorder.checked : false;

        const flashBorder = document.getElementById(`notif_${notifType.key}_flashBorder`);
        config.flash_border = flashBorder ? flashBorder.checked : false;

        // null = use Alert state color; the override checkbox opts in.
        const borderColorEnabled = document.getElementById(`notif_${notifType.key}_borderColorEnabled`);
        const borderColorInput = document.getElementById(`notif_${notifType.key}_borderColor`);
        config.border_color = (borderColorEnabled && borderColorEnabled.checked && borderColorInput && borderColorInput.value)
            ? htmlColorToZig(borderColorInput.value)
            : null;

        // Save per-type notification text color override (null = use default text color).
        const textColorEnabled = document.getElementById(`notif_${notifType.key}_textColorEnabled`);
        const textColorInput = document.getElementById(`notif_${notifType.key}_textColor`);
        config.text_color = (textColorEnabled && textColorEnabled.checked && textColorInput && textColorInput.value)
            ? htmlColorToZig(textColorInput.value)
            : null;
    });
}

let searchState = {
    currentQuery: '',
    matchedElements: [],
    highlightedTab: null,
    initiallyHiddenTabs: []
};

// filterSettings() rescans every panel/section/label in the document, so it's debounced here; clearing the box runs immediately since there's no scan cost to an empty query.
let searchDebounceTimer = null;

function onSearchInput(query) {
    if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
    if (!query) {
        filterSettings(query);
        return;
    }
    searchDebounceTimer = setTimeout(() => filterSettings(query), 150);
}

function filterSettings(query) {
    searchState.currentQuery = query.toLowerCase().trim();
    
    if (!searchState.currentQuery) {
        document.querySelectorAll('.section').forEach(el => {
            el.style.display = '';
        });
        document.querySelectorAll('.tab-item').forEach(el => {
            const tabId = el.getAttribute('data-tab');
            if (!searchState.initiallyHiddenTabs.includes(tabId)) {
                el.style.display = '';
            }
        });
        updateSearchCount(0, 0);
        searchState.matchedElements = [];
        return;
    }
    
    const matches = [];

    document.querySelectorAll('.panel-content').forEach(panel => {
        const panelTab = panel.getAttribute('data-panel');

        if (searchState.initiallyHiddenTabs.includes(panelTab)) {
            return;
        }

        // Skip whole tabs gated behind Advanced Mode (like General) while it's off
        if (panel.classList.contains('advanced-tab-panel') && !document.body.classList.contains('advanced-mode')) {
            return;
        }

        const tab = document.querySelector(`.tab-item[data-tab="${panelTab}"]`);
        const sections = panel.querySelectorAll('.section');
        let panelHasMatches = false;
        
        sections.forEach(section => {
            // Advanced-only sections stay hidden while Advanced Mode is off, even if their contents would otherwise match.
            if (section.classList.contains('advanced-section') && !document.body.classList.contains('advanced-mode')) {
                section.style.display = 'none';
                return;
            }

            const sectionText = section.textContent.toLowerCase();
            const labels = section.querySelectorAll('label, h3, h4, p.hint, .accordion-name');
            const inputs = section.querySelectorAll('input[id], select[id], textarea[id]');

            let sectionHasMatches = false;

            const heading = section.querySelector('h3');
            if (heading && heading.textContent.toLowerCase().includes(searchState.currentQuery)) {
                sectionHasMatches = true;
            }

            labels.forEach(label => {
                const text = label.textContent.toLowerCase();
                if (text.includes(searchState.currentQuery)) {
                    sectionHasMatches = true;
                }
            });

            inputs.forEach(input => {
                const id = input.id.toLowerCase();
                const value = (input.value || '').toLowerCase();
                const placeholder = (input.placeholder || '').toLowerCase();
                
                if (id.includes(searchState.currentQuery) || 
                    value.includes(searchState.currentQuery) || 
                    placeholder.includes(searchState.currentQuery)) {
                    sectionHasMatches = true;
                }
            });

            if (sectionHasMatches) {
                section.style.display = '';
                matches.push({ panel: panelTab, section: section });
                panelHasMatches = true;
            } else {
                section.style.display = 'none';
            }
        });
        
        // Show/hide tabs based on matches (but never show initially hidden tabs)
        if (tab) {
            if (panelHasMatches) {
                tab.style.display = '';
            } else {
                tab.style.display = 'none';
            }
        }
    });
    
    searchState.matchedElements = matches;
    updateSearchCount(matches.length, matches.length);

    // Auto-switch to first tab with results if current tab has no matches
    const activePanel = document.querySelector('.panel-content.active');
    const activePanelHasMatches = activePanel && activePanel.querySelector('.section:not([style*="display: none"])');

    if (!activePanelHasMatches && matches.length > 0) {
        switchTab(matches[0].panel);
    }
}

// Replaces the native OS color dialog (which can't be themed) with a popup styled to match this UI; every input[type="color"] still acts as the real value/event source, so this works automatically on dynamically-created inputs with no extra wiring.
(function initCustomColorPicker() {
    let panel = null;
    let svArea = null;
    let svThumb = null;
    let hueSlider = null;
    let hueThumb = null;
    let hexInput = null;
    let clearBtn = null;
    let activeInput = null;
    const state = { h: 0, s: 0, v: 0 };

    function clamp(n, min, max) {
        return Math.min(max, Math.max(min, n));
    }

    function hexToRgb(hex) {
        let h = (hex || '#000000').replace('#', '');
        if (h.length === 3) h = h.split('').map(c => c + c).join('');
        const num = parseInt(h, 16) || 0;
        return { r: (num >> 16) & 255, g: (num >> 8) & 255, b: num & 255 };
    }

    function rgbToHex(r, g, b) {
        const toHex = v => clamp(Math.round(v), 0, 255).toString(16).padStart(2, '0');
        return '#' + toHex(r) + toHex(g) + toHex(b);
    }

    function rgbToHsv(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        const max = Math.max(r, g, b), min = Math.min(r, g, b);
        const d = max - min;
        let h = 0;
        if (d !== 0) {
            if (max === r) h = ((g - b) / d) % 6;
            else if (max === g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h *= 60;
            if (h < 0) h += 360;
        }
        return { h, s: max === 0 ? 0 : d / max, v: max };
    }

    function hsvToRgb(h, s, v) {
        const c = v * s;
        const x = c * (1 - Math.abs((h / 60) % 2 - 1));
        const m = v - c;
        let r = 0, g = 0, b = 0;
        if (h < 60) [r, g, b] = [c, x, 0];
        else if (h < 120) [r, g, b] = [x, c, 0];
        else if (h < 180) [r, g, b] = [0, c, x];
        else if (h < 240) [r, g, b] = [0, x, c];
        else if (h < 300) [r, g, b] = [x, 0, c];
        else [r, g, b] = [c, 0, x];
        return { r: (r + m) * 255, g: (g + m) * 255, b: (b + m) * 255 };
    }

    function currentHex() {
        const { r, g, b } = hsvToRgb(state.h, state.s, state.v);
        return rgbToHex(r, g, b);
    }

    function ensurePanel() {
        if (panel) return;

        panel = document.createElement('div');
        panel.id = 'custom-color-picker';
        panel.innerHTML = `
            <div class="cp-sv-area">
                <div class="cp-sv-white"></div>
                <div class="cp-sv-black"></div>
                <div class="cp-sv-thumb"></div>
            </div>
            <div class="cp-hue-row">
                <div class="cp-hue-slider">
                    <div class="cp-hue-thumb"></div>
                </div>
            </div>
            <div class="cp-hex-row">
                <span class="cp-hex-prefix">#</span>
                <input type="text" class="cp-hex-input" maxlength="6" spellcheck="false" autocomplete="off">
            </div>
            <button type="button" class="cp-clear-btn">Clear to Default</button>
        `;
        document.body.appendChild(panel);

        svArea = panel.querySelector('.cp-sv-area');
        svThumb = panel.querySelector('.cp-sv-thumb');
        hueSlider = panel.querySelector('.cp-hue-slider');
        hueThumb = panel.querySelector('.cp-hue-thumb');
        hexInput = panel.querySelector('.cp-hex-input');
        clearBtn = panel.querySelector('.cp-clear-btn');

        svArea.addEventListener('pointerdown', onSvPointerDown);
        hueSlider.addEventListener('pointerdown', onHuePointerDown);
        hexInput.addEventListener('input', () => {
            hexInput.value = hexInput.value.replace(/[^0-9a-fA-F]/g, '').slice(0, 6).toUpperCase();
        });
        hexInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') {
                commitHexInput();
                hexInput.blur();
            }
        });
        hexInput.addEventListener('blur', commitHexInput);
        clearBtn.addEventListener('click', () => {
            if (!activeInput) return;
            if (activeInput.dataset.optionalColor === 'true') {
                // #000000 is the display placeholder for "unset"; dataset.cleared is the actual signal consumed at save time, not the displayed color.
                activeInput.value = activeInput.dataset.defaultColor || '#000000';
                activeInput.dataset.cleared = 'true';
                activeInput.title = 'Not set - inheriting global color';
            } else if (activeInput.dataset.defaultColor) {
                activeInput.value = activeInput.dataset.defaultColor;
            } else {
                return;
            }
            activeInput.dispatchEvent(new Event('input', { bubbles: true }));
            activeInput.dispatchEvent(new Event('change', { bubbles: true }));

            // Some swatches use a paired "Enabled" checkbox, not dataset.cleared, as the real null signal; uncheck it last since the 'change' dispatch above force-checks it.
            const nullCheckboxId = activeInput.dataset.nullCheckbox;
            if (nullCheckboxId) {
                const cb = document.getElementById(nullCheckboxId);
                if (cb && cb.checked) {
                    cb.checked = false;
                    cb.dispatchEvent(new Event('change', { bubbles: true }));
                }
            }
            closePicker();
        });
    }

    function render() {
        const hueColor = 'hsl(' + state.h + ', 100%, 50%)';
        svArea.style.backgroundColor = hueColor;
        svThumb.style.left = (state.s * 100) + '%';
        svThumb.style.top = ((1 - state.v) * 100) + '%';
        hueThumb.style.left = (state.h / 360 * 100) + '%';

        if (document.activeElement !== hexInput) {
            hexInput.value = currentHex().slice(1).toUpperCase();
        }
    }

    function commit(isFinal) {
        if (!activeInput) return;
        activeInput.value = currentHex();
        delete activeInput.dataset.cleared;
        if (activeInput.dataset.baseTitle) {
            activeInput.title = activeInput.dataset.baseTitle;
        } else {
            activeInput.removeAttribute('title');
        }
        activeInput.dispatchEvent(new Event('input', { bubbles: true }));
        if (isFinal) {
            activeInput.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    function commitHexInput() {
        let v = hexInput.value.trim();
        if (v.length === 3) v = v.split('').map(c => c + c).join('');
        if (!/^[0-9a-fA-F]{6}$/.test(v)) {
            hexInput.value = currentHex().slice(1).toUpperCase();
            return;
        }
        const { r, g, b } = hexToRgb('#' + v);
        const hsv = rgbToHsv(r, g, b);
        state.h = hsv.h; state.s = hsv.s; state.v = hsv.v;
        render();
        commit(true);
    }

    function onSvPointerDown(e) {
        e.preventDefault();
        updateSv(e);
        const move = ev => updateSv(ev);
        const up = ev => {
            document.removeEventListener('pointermove', move);
            document.removeEventListener('pointerup', up);
            updateSv(ev);
            commit(true);
        };
        document.addEventListener('pointermove', move);
        document.addEventListener('pointerup', up);
    }

    function updateSv(e) {
        const rect = svArea.getBoundingClientRect();
        const x = clamp(e.clientX - rect.left, 0, rect.width);
        const y = clamp(e.clientY - rect.top, 0, rect.height);
        state.s = rect.width === 0 ? 0 : x / rect.width;
        state.v = rect.height === 0 ? 0 : 1 - (y / rect.height);
        render();
        commit(false);
    }

    function onHuePointerDown(e) {
        e.preventDefault();
        updateHue(e);
        const move = ev => updateHue(ev);
        const up = ev => {
            document.removeEventListener('pointermove', move);
            document.removeEventListener('pointerup', up);
            updateHue(ev);
            commit(true);
        };
        document.addEventListener('pointermove', move);
        document.addEventListener('pointerup', up);
    }

    function updateHue(e) {
        const rect = hueSlider.getBoundingClientRect();
        const x = clamp(e.clientX - rect.left, 0, rect.width);
        state.h = rect.width === 0 ? 0 : (x / rect.width) * 360;
        render();
        commit(false);
    }

    function positionPanel(input) {
        const rect = input.getBoundingClientRect();
        const margin = 6;
        const panelRect = panel.getBoundingClientRect();

        let top = rect.bottom + margin;
        let left = rect.left;

        if (top + panelRect.height > window.innerHeight) {
            top = rect.top - panelRect.height - margin;
        }
        if (left + panelRect.width > window.innerWidth) {
            left = window.innerWidth - panelRect.width - margin;
        }
        left = Math.max(margin, left);
        top = Math.max(margin, top);

        panel.style.left = left + 'px';
        panel.style.top = top + 'px';
    }

    function openPicker(input) {
        ensurePanel();
        activeInput = input;

        const { r, g, b } = hexToRgb(input.value);
        const hsv = rgbToHsv(r, g, b);
        state.h = hsv.h; state.s = hsv.s; state.v = hsv.v;

        const isClearable = input.dataset.optionalColor === 'true' || !!input.dataset.defaultColor;
        clearBtn.style.display = isClearable ? 'block' : 'none';

        render();
        panel.classList.add('open');
        positionPanel(input);

        document.addEventListener('mousedown', onDocMouseDown, true);
        document.addEventListener('keydown', onKeyDown, true);
    }

    function closePicker() {
        if (panel) panel.classList.remove('open');
        activeInput = null;
        document.removeEventListener('mousedown', onDocMouseDown, true);
        document.removeEventListener('keydown', onKeyDown, true);
    }

    function onDocMouseDown(e) {
        if (panel.contains(e.target) || e.target === activeInput) return;
        closePicker();
    }

    function onKeyDown(e) {
        if (e.key === 'Escape') closePicker();
    }

    document.addEventListener('click', function(e) {
        const input = e.target.closest && e.target.closest('input[type="color"]');
        if (!input) return;
        e.preventDefault();
        if (panel && panel.classList.contains('open') && activeInput === input) {
            closePicker();
        } else {
            openPicker(input);
        }
    }, true);
})();

function updateSearchCount(sections, elements) {
    const countEl = document.getElementById('search-results-count');
    if (!countEl) return;
    
    if (sections === 0 && !searchState.currentQuery) {
        countEl.textContent = '';
    } else if (sections === 0) {
        countEl.textContent = t('status.noMatches');
        countEl.style.color = '#ff6b6b';
    } else {
        countEl.textContent = `${sections} ${sections !== 1 ? t('status.sectionPlural') : t('status.sectionSingular')}`;
        countEl.style.color = '#4a9eff';
    }
}

function clearSearch() {
    const searchInput = document.getElementById('search-filter');
    if (searchInput) {
        searchInput.value = '';
        filterSettings('');
        searchInput.focus();
    }
}
