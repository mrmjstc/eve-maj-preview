// Binds config fields to form inputs: the field schema, value conversions, validation ranges and defaults.
import { languageNames } from './catalogs.js';
import { app } from './state.js';
import { ensureBlankRosterEntries, populateCharacters } from './characters.js';
import { syncSwatchHexInput } from './color_picker.js';
import { applyAccentColorTheme, htmlColorToZig, zigColorAlpha, zigColorToHtml, zigColorWithAlpha } from './colors.js';
import { logError, logWarn, rpc } from './core.js';
import { populateHotkeyGroups } from './hotkey_groups.js';
import { vkHexToFriendly } from './hotkeys.js';
import { t } from './i18n.js';
import { populateNotificationTypes, refreshNotificationColorDefaults } from './notifications.js';
import { toggleAspectRatioSlider, toggleAutoMinimizeOptions, toggleBorderOptions, toggleBountyOptions, toggleCharacterNameOptions, toggleChatlogOptions, toggleClickThroughOptions, toggleClientListOptions, toggleCombatOptions, toggleFocusedBorderOptions, toggleInactiveBorderOptions, toggleMiningOptions, toggleNotLoggedInSpaceOptions, toggleNotifInfoPanelMergeOptions, toggleNotifInfoPanelOptions, toggleNotificationOptions, toggleQuickGroupBadgeOptions, toggleRegionFitOptions, toggleResourcesOptions, toggleShiftClickExcludeOptions, toggleSnappingOptions, toggleSystemNameOptions, toggleTextDisplayOptions, toggleTravelOptions, toggleTtsDisplayNameOption, toggleUniqueCharacterNameColors, toggleUniqueSystemColors, toggleWindowFilters } from './options.js';
import { refreshOverlayLayoutPreview, syncOverlayStyleFromCharacterName } from './overlay_layout.js';
import { refreshRegionButtons } from './region.js';
import { populateSystemColors } from './system_colors.js';
import { populateWindowFilters } from './window_filters.js';

// Shared <option> lists for the many identical position/font <select> elements across tabs.
// Second element is an i18n key, not the label text - resolved via t() at population time so a live language switch (see switchLanguage()) is reflected.
export const POSITION_OPTIONS = [
    ['TopLeft', 'dynamic.position.topLeft'], ['TopCenter', 'dynamic.position.topCenter'], ['TopRight', 'dynamic.position.topRight'],
    ['LeftCenter', 'dynamic.position.leftCenter'], ['Center', 'dynamic.position.center'], ['RightCenter', 'dynamic.position.rightCenter'],
    ['BottomLeft', 'dynamic.position.bottomLeft'], ['BottomCenter', 'dynamic.position.bottomCenter'], ['BottomRight', 'dynamic.position.bottomRight'],
];

export const FONT_OPTIONS = [
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
    document.querySelectorAll('select.position-options').forEach(select => {
        POSITION_OPTIONS.forEach(([value, labelKey]) => select.add(new Option(t(labelKey), value)));
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
    { id: 'clickThrough', path: 'interaction.clickThrough' },
    { id: 'hoverCursor', path: 'interaction.hoverCursor', default: 'Default' },

    { id: 'snappingEnabled', path: 'snapping.enabled' },
    { id: 'snappingThreshold', path: 'snapping.threshold' },
    { id: 'snappingScreenEdges', path: 'snapping.screenEdges' },
    { id: 'snappingThumbnailEdges', path: 'snapping.thumbnailEdges' },
    { id: 'snappingGhostPositions', path: 'snapping.ghostPositions' },
    { id: 'snappingShowGhostBorders', path: 'snapping.showGhostPositionBorders' },

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
    { id: 'systemNameFontName', path: 'thumbnail.systemNameFontName' },
    { id: 'systemNameFontSize', path: 'thumbnail.systemNameFontSize' },
    { id: 'systemNameFontWeight', path: 'thumbnail.systemNameFontWeight' },
    { id: 'showQuickGroupBadge', path: 'thumbnail.showQuickGroupBadge' },
    { id: 'quickGroupBadgePosition', path: 'thumbnail.quickGroupBadgePosition' },
    { id: 'quickGroupBadgeOffsetX', path: 'thumbnail.quickGroupBadgeOffsetX' },
    { id: 'quickGroupBadgeOffsetY', path: 'thumbnail.quickGroupBadgeOffsetY' },
    { id: 'quickGroupBadgeColor', path: 'thumbnail.quickGroupBadgeColor' },
    { id: 'quickGroupBadgeFontName', path: 'thumbnail.quickGroupBadgeFontName' },
    { id: 'quickGroupBadgeFontSize', path: 'thumbnail.quickGroupBadgeFontSize' },
    { id: 'quickGroupBadgeFontWeight', path: 'thumbnail.quickGroupBadgeFontWeight' },
    { id: 'exclusionOverlayStyle', path: 'thumbnail.exclusionOverlayStyle' },
    // exclusionOverlayColor/exclusionOverlayOpacity are special-cased below.
    { id: 'useUniqueSystemColors', path: 'thumbnail.useUniqueSystemColors' },
    { id: 'useUniqueCharacterNameColors', path: 'thumbnail.useUniqueCharacterNameColors' },
    { id: 'useUniqueCharacterBorderColors', path: 'thumbnail.useUniqueCharacterBorderColors' },
    { id: 'characterNameFontName', path: 'thumbnail.characterNameFontName' },
    { id: 'characterNameFontSize', path: 'thumbnail.characterNameFontSize' },
    { id: 'characterNameFontWeight', path: 'thumbnail.characterNameFontWeight' },
    { id: 'activeThumbnailHidden', path: 'thumbnail.activeThumbnailHidden' },
    { id: 'hideWhenNoEveFocus', path: 'thumbnail.hideWhenNoEveFocus' },
    { id: 'hideDebounceMs', path: 'thumbnail.hideDebounceMs', transform: 'ms' },
    { id: 'characterNameColor', path: 'thumbnail.characterNameColor' },
    { id: 'systemNameColor', path: 'thumbnail.systemNameColor' },
    // showBorderWhenFocused/showBorderWhenInactive/borderEnabled and the *BgColor/*BgOpacity pairs (see BG_COLOR_FIELDS) are special-cased below.

    { id: 'spacing', path: 'display.spacing' },
    { id: 'newThumbnailSpacing', path: 'display.newThumbnailSpacing' },
    { id: 'layoutMode', path: 'display.layoutMode' },
    { id: 'viewMode', path: 'display.viewMode' },
    { id: 'listViewOrder', path: 'display.listViewOrder', default: 'Tracked' },
    { id: 'rememberListViewPosition', path: 'display.rememberListViewPosition' },
    { id: 'listViewOpacity', path: 'display.listViewOpacity', transform: 'opacity', default: 255 },
    { id: 'listViewColumns', path: 'display.listViewColumns', default: 1 },
    { id: 'listViewFontName', path: 'display.listViewFontName' },
    { id: 'listViewFontSize', path: 'display.listViewFontSize' },
    { id: 'listViewFontWeight', path: 'display.listViewFontWeight' },
    { id: 'regionFitDirection', path: 'display.regionFitDirection' },
    { id: 'regionX', path: 'display.regionX', transform: 'nullable' },
    { id: 'regionY', path: 'display.regionY', transform: 'nullable' },
    { id: 'regionWidth', path: 'display.regionWidth', transform: 'nullable' },
    { id: 'regionHeight', path: 'display.regionHeight', transform: 'nullable' },
    { id: 'regionFitOrder', path: 'display.regionFitOrder' },
    { id: 'regionFitReorderLoggedOut', path: 'display.regionFitReorderLoggedOut' },
    { id: 'hideThumbnailsDuringRegionSelect', path: 'display.hideThumbnailsDuringRegionSelect', default: true },
    { id: 'notLoggedInSpaceHideThumbnailsDuringRegionSelect', path: 'display.notLoggedInSpaceHideThumbnailsDuringRegionSelect', default: true },
    { id: 'regionFitLimitToThumbnailSize', path: 'display.regionFitLimitToThumbnailSize', default: false },
    { id: 'notLoggedInSpaceLimitToThumbnailSize', path: 'display.notLoggedInSpaceLimitToThumbnailSize', default: false },
    { id: 'notLoggedInSpaceEnabled', path: 'display.notLoggedInSpaceEnabled', default: false },
    { id: 'notLoggedInSpaceSpacing', path: 'display.notLoggedInSpaceSpacing' },
    { id: 'notLoggedInSpaceX', path: 'display.notLoggedInSpaceX', transform: 'nullable' },
    { id: 'notLoggedInSpaceY', path: 'display.notLoggedInSpaceY', transform: 'nullable' },
    { id: 'notLoggedInSpaceWidth', path: 'display.notLoggedInSpaceWidth', transform: 'nullable' },
    { id: 'notLoggedInSpaceHeight', path: 'display.notLoggedInSpaceHeight', transform: 'nullable' },
    { id: 'monitorIndex', path: 'display.monitorIndex', transform: 'nullable' },
    { id: 'useMonitorWorkArea', path: 'display.useMonitorWorkArea' },
    { id: 'honorSavedPositions', path: 'display.honorSavedPositions' },
    { id: 'showNotifInfoPanel', path: 'display.showNotifInfoPanel' },
    { id: 'notifInfoPanelWidth', path: 'display.notifInfoPanelWidth' },
    { id: 'notifInfoPanelHeight', path: 'display.notifInfoPanelHeight' },
    { id: 'notifInfoPanelOpacity', path: 'display.notifInfoPanelOpacity', transform: 'opacity', default: 255 },
    { id: 'notifInfoPanelFontName', path: 'display.notifInfoPanelFontName' },
    { id: 'notifInfoPanelFontSize', path: 'display.notifInfoPanelFontSize' },
    { id: 'notifInfoPanelFontWeight', path: 'display.notifInfoPanelFontWeight' },
    { id: 'notifInfoPanelMaxRows', path: 'display.notifInfoPanelMaxRows', default: 15 },
    { id: 'notifInfoPanelShowTimestamp', path: 'display.notifInfoPanelShowTimestamp' },
    { id: 'notifInfoPanelMergeEnabled', path: 'display.notifInfoPanelMergeEnabled' },
    { id: 'notifInfoPanelMergeWindowSec', path: 'display.notifInfoPanelMergeWindowSec', default: 10 },
    { id: 'notifInfoPanelShowCategoryFilters', path: 'display.notifInfoPanelShowCategoryFilters' },
    { id: 'rememberNotifInfoPanelPosition', path: 'display.rememberNotifInfoPanelPosition' },
    { id: 'hideNotifInfoPanelWhenNoCharacters', path: 'display.hideNotifInfoPanelWhenNoCharacters' },
    // startX/startY/notifInfoPanelX/notifInfoPanelY are populate-only - saveConfiguration reloads them from disk instead of the form (see reloadLivePositions).

    { id: 'autoMinimizeEnabled', path: 'autoMinimize.enabled' },
    { id: 'autoMinimizeDelay', path: 'autoMinimize.delayMs', transform: 'ms' },
    { id: 'autoMinimizeExemptLastActive', path: 'autoMinimize.exemptLastActiveOnFocusLoss' },

    { id: 'autoMovePositionEnabled', path: 'autoMovePosition.enabled' },
    { id: 'autoMoveOnStartup', path: 'autoMovePosition.moveOnStartup' },
    { id: 'autoMoveVerifyInterval', path: 'autoMovePosition.verifyIntervalMs', transform: 'ms' },
    { id: 'autoMoveVerifyCount', path: 'autoMovePosition.verifyCount' },

    { id: 'enableShiftClickExclude', path: 'exclusion.enableShiftClickExclude' },
    { id: 'autoMinimizeExcludedCharacters', path: 'exclusion.autoMinimizeExcluded' },

    { id: 'closeAllExcludeLoginScreenClients', path: 'closeAll.excludeLoginScreenClients' },

    { id: 'requireEveFocus', path: 'hotkeys.requireEveFocus' },
    { id: 'resetGroupIndexOnNonGroupFocus', path: 'hotkeys.resetGroupIndexOnNonGroupFocus' },
    { id: 'allowHotkeyAutoRepeat', path: 'hotkeys.allowHotkeyAutoRepeat' },
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

    // State Overrides section is currently hidden in the dialog (see index.html) - these are disabled along with it.
    // "active" is intentionally not here - unchecking it must write null (defer to activeThumbnailHidden), not false; see applySpecialFields*.
    // { id: 'stateInactiveShow', path: 'thumbnail.inactive.showThumbnail' },
    // { id: 'stateAlertShow', path: 'thumbnail.alert.showThumbnail' },
    // { id: 'stateMinimizedShow', path: 'thumbnail.minimized.showThumbnail' },
    // { id: 'stateDraggingShow', path: 'thumbnail.dragging.showThumbnail' },

    { id: 'notificationsEnabled', path: 'thumbnail.notifications.enabled' },
    { id: 'notificationPosition', path: 'thumbnail.notifications.position' },
    { id: 'notificationOffsetX', path: 'thumbnail.notifications.offset_x' },
    { id: 'notificationOffsetY', path: 'thumbnail.notifications.offset_y' },
    { id: 'notificationFontName', path: 'thumbnail.notifications.font_name' },
    { id: 'notificationFontSize', path: 'thumbnail.notifications.font_size' },
    { id: 'notificationFontWeight', path: 'thumbnail.notifications.font_weight' },
    { id: 'notifSuppressClickDuration', path: 'thumbnail.notifications.suppress_click_duration_ms', transform: 'ms' },
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
    { id: 'combatIncomingFontSize', path: 'combat.incoming_font_size' },
    { id: 'combatIncomingFontName', path: 'combat.incoming_font_name' },
    { id: 'combatIncomingFontWeight', path: 'combat.incoming_font_weight' },
    { id: 'combatOutgoingFontSize', path: 'combat.outgoing_font_size' },
    { id: 'combatOutgoingFontName', path: 'combat.outgoing_font_name' },
    { id: 'combatOutgoingFontWeight', path: 'combat.outgoing_font_weight' },
    { id: 'combatIncomingOffsetX', path: 'combat.incoming_offset_x' },
    { id: 'combatIncomingOffsetY', path: 'combat.incoming_offset_y' },
    { id: 'combatOutgoingOffsetX', path: 'combat.outgoing_offset_x' },
    { id: 'combatOutgoingOffsetY', path: 'combat.outgoing_offset_y' },
    { id: 'combatIncomingShowPrefix', path: 'combat.incoming_show_prefix' },
    { id: 'combatOutgoingShowPrefix', path: 'combat.outgoing_show_prefix' },
    { id: 'combatDamageAlertExcludedWeapons', path: 'combat.damage_alert_excluded_weapons', default: '' },

    { id: 'miningEnabled', path: 'mining.enabled' },
    { id: 'miningWindowSeconds', path: 'mining.window_seconds' },
    { id: 'miningUpdateIntervalMs', path: 'mining.update_interval_ms', transform: 'ms' },
    { id: 'miningPosition', path: 'mining.position' },
    { id: 'miningColor', path: 'mining.color' },
    { id: 'miningFontSize', path: 'mining.font_size' },
    { id: 'miningFontName', path: 'mining.font_name' },
    { id: 'miningFontWeight', path: 'mining.font_weight' },
    { id: 'miningOffsetX', path: 'mining.offset_x' },
    { id: 'miningOffsetY', path: 'mining.offset_y' },
    { id: 'miningShowIskRate', path: 'mining.show_isk_rate' },
    { id: 'miningIskRateUnit', path: 'mining.isk_rate_unit' },
    { id: 'miningShowPrefix', path: 'mining.show_prefix' },
    { id: 'miningIdleAlertWindowSeconds', path: 'mining.idle_alert_window_seconds' },
    { id: 'miningIdleAlertThreshold', path: 'mining.idle_alert_threshold' },
    { id: 'miningStoppedAlertWindowSeconds', path: 'mining.stopped_alert_window_seconds' },

    { id: 'bountyEnabled', path: 'bounty.enabled' },
    { id: 'bountyWindowSeconds', path: 'bounty.window_seconds' },
    { id: 'bountyUpdateIntervalMs', path: 'bounty.update_interval_ms', transform: 'ms' },
    { id: 'bountyPosition', path: 'bounty.position' },
    { id: 'bountyColor', path: 'bounty.color' },
    { id: 'bountyFontSize', path: 'bounty.font_size' },
    { id: 'bountyFontName', path: 'bounty.font_name' },
    { id: 'bountyFontWeight', path: 'bounty.font_weight' },
    { id: 'bountyOffsetX', path: 'bounty.offset_x' },
    { id: 'bountyOffsetY', path: 'bounty.offset_y' },
    { id: 'bountyIskRateUnit', path: 'bounty.isk_rate_unit' },
    { id: 'bountyShowPrefix', path: 'bounty.show_prefix' },

    { id: 'resourcesEnabled', path: 'resources.enabled' },
    { id: 'resourcesShowCpu', path: 'resources.show_cpu' },
    { id: 'resourcesShowRam', path: 'resources.show_ram' },
    { id: 'resourcesShowVram', path: 'resources.show_vram' },
    { id: 'resourcesUpdateIntervalMs', path: 'resources.update_interval_ms', transform: 'ms' },
    { id: 'resourcesPosition', path: 'resources.position' },
    { id: 'resourcesColor', path: 'resources.color' },
    { id: 'resourcesFontSize', path: 'resources.font_size' },
    { id: 'resourcesFontName', path: 'resources.font_name' },
    { id: 'resourcesFontWeight', path: 'resources.font_weight' },
    { id: 'resourcesOffsetX', path: 'resources.offset_x' },
    { id: 'resourcesOffsetY', path: 'resources.offset_y' },

    { id: 'travelEnabled', path: 'travel.enabled' },
    { id: 'travelWindowSeconds', path: 'travel.window_seconds' },
    { id: 'travelThresholdMode', path: 'travel.threshold_mode' },
    { id: 'travelThresholdPercent', path: 'travel.threshold_percent' },
    { id: 'travelThresholdCount', path: 'travel.threshold_count' },
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

export function applyConfigSchemaToForm() {
    for (const f of CONFIG_SCHEMA) {
        let value = getConfigPath(app.currentConfig, f.path);
        if (value == null && f.default !== undefined) value = f.default;
        if (f.transform === 'ms') value = value != null ? value / 1000 : null;
        else if (f.transform === 'opacity') value = opacityToPercent(value ?? 255);
        else if (f.transform === 'vkhex') value = vkHexToFriendly(value);

        const field = document.getElementById(f.id);
        if (field && field.type === 'checkbox') setCheckboxValue(f.id, value);
        else setFieldValue(f.id, value);
    }
}

export function applyConfigSchemaFromForm() {
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
        setConfigPath(app.currentConfig, f.path, value);
    }
}

// Fetched once from Zig (not hand-copied) so validate() bound changes never need a matching edit here.
function clampToValidationRange(path, value) {
    if (value == null || typeof value !== 'number' || isNaN(value)) return value;
    const range = app.VALIDATION_RANGES[path];
    if (!range) return value;
    return Math.min(range.max, Math.max(range.min, value));
}

function toDisplayRange(range, transform) {
    if (transform === 'ms') return { min: range.min / 1000, max: range.max / 1000 };
    if (transform === 'opacity') return { min: opacityToPercent(range.min), max: opacityToPercent(range.max) };
    return { min: range.min, max: range.max };
}

// Re-keys VALIDATION_RANGES by field id in display units, so getFieldValue() can clamp a raw DOM read without knowing about CONFIG_SCHEMA/transforms.
function buildFieldRanges() {
    app.FIELD_RANGES = {};
    for (const f of CONFIG_SCHEMA) {
        const range = app.VALIDATION_RANGES[f.path];
        if (range) app.FIELD_RANGES[f.id] = toDisplayRange(range, f.transform);
    }
}

// Inputs rebuilt per list row or notification type have no CONFIG_SCHEMA entry, so they name their VALIDATION_RANGES key in data-range instead.
function rangeForField(field) {
    if (app.FIELD_RANGES[field.id]) return app.FIELD_RANGES[field.id];
    const range = field.dataset && field.dataset.range && app.VALIDATION_RANGES[field.dataset.range];
    return range ? toDisplayRange(range, field.dataset.rangeTransform) : null;
}

// Sets native min/max so the browser reflects real backend limits; `root` narrows it to freshly rebuilt rows.
export function applyValidationRangesToInputs(root = document) {
    if (root === document) {
        for (const id of Object.keys(app.FIELD_RANGES)) {
            const field = document.getElementById(id);
            if (field) applyRangeToInput(field);
        }
    }
    root.querySelectorAll('[data-range]').forEach(applyRangeToInput);
}

function applyRangeToInput(field) {
    if (field.type !== 'number' && field.type !== 'range') return;
    const range = rangeForField(field);
    if (!range) return;
    field.min = range.min;
    field.max = range.max;
}

export async function loadValidationRanges() {
    try {
        app.VALIDATION_RANGES = await rpc('getValidationRanges');
    } catch (error) {
        logWarn('Failed to load validation ranges:', error);
        app.VALIDATION_RANGES = {};
    }
    buildFieldRanges();
    applyValidationRangesToInputs();
}

// Native min/max only affects spinner UI, not typed values, so clamp visually on 'change' (not 'input', which would fight mid-keystroke) once the user commits a value.
document.addEventListener('change', (e) => {
    const field = e.target;
    if (field.type !== 'number' && field.type !== 'range') return;
    const range = rangeForField(field);
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

// Each element's background is one u32 (color + opacity packed into the alpha byte) split across two UI inputs.
const BG_COLOR_FIELDS = [
    { colorId: 'characterNameBgColor', opacityId: 'characterNameBgOpacity', path: 'thumbnail.characterNameBgColor' },
    { colorId: 'systemNameBgColor', opacityId: 'systemNameBgOpacity', path: 'thumbnail.systemNameBgColor' },
    { colorId: 'quickGroupBadgeBgColor', opacityId: 'quickGroupBadgeBgOpacity', path: 'thumbnail.quickGroupBadgeBgColor' },
    { colorId: 'notificationBgColor', opacityId: 'notificationBgOpacity', path: 'thumbnail.notifications.bg_color' },
    { colorId: 'combatIncomingBgColor', opacityId: 'combatIncomingBgOpacity', path: 'combat.incoming_bg_color' },
    { colorId: 'combatOutgoingBgColor', opacityId: 'combatOutgoingBgOpacity', path: 'combat.outgoing_bg_color' },
    { colorId: 'miningBgColor', opacityId: 'miningBgOpacity', path: 'mining.bg_color' },
    { colorId: 'bountyBgColor', opacityId: 'bountyBgOpacity', path: 'bounty.bg_color' },
    { colorId: 'resourcesBgColor', opacityId: 'resourcesBgOpacity', path: 'resources.bg_color' },
];

/* State Overrides section is currently hidden in the dialog (see index.html) - kept here, correct and working, in case it gets re-enabled later.
// The 5 thumbnail states the Advanced tab's "State Overrides" accordions can override; idPrefix matches
// the HTML (e.g. stateActiveBorderWidth) and key matches the Zig config (thumbnail.active.borderWidth).
// showThumbnail isn't listed here - Active's is a special case (see applySpecialFieldsFromForm) and the
// other four are plain CONFIG_SCHEMA entries, since only these six fields need the nullable handling below.
const THUMBNAIL_STATE_OVERRIDES = [
    { idPrefix: 'stateActive', key: 'active' },
    { idPrefix: 'stateInactive', key: 'inactive' },
    { idPrefix: 'stateAlert', key: 'alert' },
    { idPrefix: 'stateMinimized', key: 'minimized' },
    { idPrefix: 'stateDragging', key: 'dragging' },
];

// Mirrors setFieldValue for a nullable data-optional-color swatch: shows its data-default-color placeholder
// and marks it cleared when unset, matching the "Clear to Default" convention resolveOptionalColor() reads back.
function setOptionalColorField(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;
    if (value === null || value === undefined) {
        field.value = field.dataset.defaultColor || '#000000';
        field.dataset.cleared = 'true';
        field.title = t('common.notSetInheritingColor');
    } else {
        field.value = zigColorToHtml(value);
        delete field.dataset.cleared;
        field.removeAttribute('title');
    }
    syncSwatchHexInput(field);
}

function applyStateOverridesToForm() {
    THUMBNAIL_STATE_OVERRIDES.forEach(({ idPrefix, key }) => {
        const override = currentConfig.thumbnail?.[key] || {};
        setCheckboxValue(`${idPrefix}ShowBorder`, override.showBorder);
        setFieldValue(`${idPrefix}BorderWidth`, override.borderWidth);
        setFieldValue(`${idPrefix}BorderStyle`, override.borderStyle);
        setOptionalColorField(`${idPrefix}BorderColor`, override.borderColor);
        setOptionalColorField(`${idPrefix}TextColor`, override.textColor);
        setOptionalColorField(`${idPrefix}TextBgColor`, override.textBgColor);
    });
}

// showBorder is saved as a plain true/false (not preserved as null/"inherit") once touched - same
// simplification already used by the Inactive/Alert/Minimized/Dragging showThumbnail checkboxes here.
function applyStateOverridesFromForm() {
    THUMBNAIL_STATE_OVERRIDES.forEach(({ idPrefix, key }) => {
        if (!currentConfig.thumbnail[key]) currentConfig.thumbnail[key] = {};
        const override = currentConfig.thumbnail[key];

        override.showBorder = getFieldValue(`${idPrefix}ShowBorder`);
        override.borderWidth = getNullableFieldValue(`${idPrefix}BorderWidth`);
        override.borderStyle = getFieldValue(`${idPrefix}BorderStyle`) || null;
        override.borderColor = resolveOptionalColor(document.getElementById(`${idPrefix}BorderColor`), override.borderColor != null);
        override.textColor = resolveOptionalColor(document.getElementById(`${idPrefix}TextColor`), override.textColor != null);
        override.textBgColor = resolveOptionalColor(document.getElementById(`${idPrefix}TextBgColor`), override.textBgColor != null);
    });
}
*/

// Fields that can't be expressed as a single {id, path} pair: composite values, asymmetric load/save, or non-trivial defaults.
export function applySpecialFieldsToForm() {
    setFieldValue('startX', app.currentConfig.display?.startX);
    setFieldValue('startY', app.currentConfig.display?.startY);

    setCheckboxValue('showBorderWhenFocused', app.currentConfig.thumbnail?.showBorderWhenFocused);
    setCheckboxValue('showBorderWhenInactive', app.currentConfig.thumbnail?.showBorderWhenInactive);
    const hasBorder = app.currentConfig.thumbnail?.showBorderWhenFocused || app.currentConfig.thumbnail?.showBorderWhenInactive;
    setCheckboxValue('borderEnabled', hasBorder);

    BG_COLOR_FIELDS.forEach(({ colorId, opacityId, path }) => {
        const value = getConfigPath(app.currentConfig, path);
        setFieldValue(colorId, value);
        setFieldValue(opacityId, opacityToPercent(zigColorAlpha(value)));
    });

    setFieldValue('exclusionOverlayColor', app.currentConfig.thumbnail?.exclusionOverlayColor);
    const exclusionOverlayOpacityPercent = opacityToPercent(zigColorAlpha(app.currentConfig.thumbnail?.exclusionOverlayColor));
    setFieldValue('exclusionOverlayOpacity', exclusionOverlayOpacityPercent);

    // State Overrides section is currently hidden in the dialog - see index.html.
    // setCheckboxValue('stateActiveShow', currentConfig.thumbnail?.active?.showThumbnail);
    // applyStateOverridesToForm();

    setCheckboxValue('ttsSpeakCharacterName', app.currentConfig.thumbnail?.notifications?.tts_speak_character_name !== false);
    setFieldValue('notifCycleRetention', app.currentConfig.thumbnail?.notifications?.notified_cycle_retention_seconds ?? 30);

    setCheckboxValue('regionFitEnabled', app.currentConfig.display?.layoutMode === 'RegionFit');
}

export function applySpecialFieldsFromForm() {
    const borderEnabled = getFieldValue('borderEnabled');
    app.currentConfig.thumbnail.showBorderWhenFocused = borderEnabled && getFieldValue('showBorderWhenFocused');
    app.currentConfig.thumbnail.showBorderWhenInactive = borderEnabled && getFieldValue('showBorderWhenInactive');

    BG_COLOR_FIELDS.forEach(({ colorId, opacityId, path }) => {
        setConfigPath(app.currentConfig, path, zigColorWithAlpha(getFieldValue(colorId), percentToOpacity(getFieldValue(opacityId))));
    });

    app.currentConfig.thumbnail.exclusionOverlayColor = zigColorWithAlpha(getFieldValue('exclusionOverlayColor'), percentToOpacity(getFieldValue('exclusionOverlayOpacity')));

    // State Overrides section is currently hidden in the dialog - see index.html.
    // if (!currentConfig.thumbnail.active) currentConfig.thumbnail.active = {};
    // currentConfig.thumbnail.active.showThumbnail = getFieldValue('stateActiveShow') ? true : null;
    // applyStateOverridesFromForm();

    const rawRetention = parseInt(document.getElementById('notifCycleRetention').value, 10) || 30;
    app.currentConfig.thumbnail.notifications.notified_cycle_retention_seconds =
        clampToValidationRange('thumbnail.notifications.notified_cycle_retention_seconds', rawRetention);
}

// Mirrors any range slider's value into its data-value-target span, covering all offset/opacity sliders without a per-slider handler.
document.addEventListener('input', (e) => {
    if (e.target.matches('input[type="range"][data-value-target]')) {
        const span = document.getElementById(e.target.dataset.valueTarget);
        if (span) span.textContent = e.target.value;
    }
});

// Deliberately not awaited before the first render - consumers of defaultConfig fall back to their hardcoded literal until this resolves.
export async function loadDefaultConfig() {
    try {
        if (typeof webui === 'undefined') return;
        app.defaultConfig = await rpc('getDefaultConfig');
        applyBackendDefaultColors();
        refreshNotificationColorDefaults();
    } catch (error) {
        logError('Failed to load default config:', error);
    }
}

// Upgrades the swatches' static data-default-color (see initCustomColorPicker's "Clear to Default") to the real backend value once fetched.
function applyBackendDefaultColors() {
    if (!app.defaultConfig) return;
    const map = {
        borderColor: app.defaultConfig.thumbnail?.borderColor,
        inactiveBorderColor: app.defaultConfig.thumbnail?.inactiveBorderColor,
        characterNameColor: app.defaultConfig.thumbnail?.characterNameColor,
        systemNameColor: app.defaultConfig.thumbnail?.systemNameColor,
        exclusionOverlayColor: app.defaultConfig.thumbnail?.exclusionOverlayColor,
        combatIncomingColor: app.defaultConfig.combat?.incoming_color,
        combatOutgoingColor: app.defaultConfig.combat?.outgoing_color,
        miningColor: app.defaultConfig.mining?.color,
        bountyColor: app.defaultConfig.bounty?.color,
        resourcesColor: app.defaultConfig.resources?.color,
        characterNameBgColor: app.defaultConfig.thumbnail?.characterNameBgColor,
        systemNameBgColor: app.defaultConfig.thumbnail?.systemNameBgColor,
        quickGroupBadgeBgColor: app.defaultConfig.thumbnail?.quickGroupBadgeBgColor,
        notificationBgColor: app.defaultConfig.thumbnail?.notifications?.bg_color,
        combatIncomingBgColor: app.defaultConfig.combat?.incoming_bg_color,
        combatOutgoingBgColor: app.defaultConfig.combat?.outgoing_bg_color,
        miningBgColor: app.defaultConfig.mining?.bg_color,
        bountyBgColor: app.defaultConfig.bounty?.bg_color,
        resourcesBgColor: app.defaultConfig.resources?.bg_color,
    };
    for (const [id, value] of Object.entries(map)) {
        if (value == null) continue;
        const el = document.getElementById(id);
        if (el) el.dataset.defaultColor = zigColorToHtml(value);
    }
}

export function populateFormFields() {
    if (!app.currentConfig) return;

    applyAccentColorTheme();
    applyConfigSchemaToForm();
    applySpecialFieldsToForm();

    if (document.getElementById('syncOverlayStyling')?.checked) syncOverlayStyleFromCharacterName();

    // Order-independent: each just reads fields already populated above and adjusts unrelated elements' disabled state.
    toggleAspectRatioSlider();
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

    populateWindowFilters();

    const hasFilters = app.currentConfig.windowFilters && app.currentConfig.windowFilters.length > 0;
    setCheckboxValue('windowFiltersEnabled', hasFilters);
    toggleWindowFilters();

    populateSystemColors();
    ensureBlankRosterEntries();
    populateCharacters();
    populateHotkeyGroups();
    populateNotificationTypes();

    refreshOverlayLayoutPreview();
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

export function setCheckboxValue(fieldId, value) {
    const field = document.getElementById(fieldId);
    if (!field) return;
    field.checked = !!value;
}

// Opacity is stored internally as 0-255 (matches the win32 alpha channel) but shown in the UI as a 0-100% slider
export function opacityToPercent(value) {
    return Math.round(Math.max(0, Math.min(255, value)) / 255 * 100);
}

export function percentToOpacity(percent) {
    return Math.round(Math.max(0, Math.min(100, percent)) / 100 * 255);
}

export function soundFileBaseName(path) {
    return path ? path.split(/[\\/]/).pop() : '';
}

// Mirrors applyConfigSchemaFromForm()'s 'ms' transform, for fields (e.g. update_interval_ms) whose DOM value is fractional seconds.
export function msFieldValue(fieldId) {
    const raw = parseFloat(document.getElementById(fieldId)?.value);
    return Math.round((isNaN(raw) ? 0 : raw) * 1000);
}

export function getFieldValue(fieldId) {
    const field = document.getElementById(fieldId);
    if (!field) return null;

    if (field.type === 'number' || field.type === 'range') {
        const value = parseInt(field.value) || 0;
        const range = app.FIELD_RANGES[fieldId];
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
export function getNullableFieldValue(fieldId) {
    const field = document.getElementById(fieldId);
    if (!field) return null;

    if (field.value === '' || field.value === null || field.value === undefined) {
        return null;
    }

    const parsed = parseInt(field.value);
    return isNaN(parsed) ? null : parsed;
}
