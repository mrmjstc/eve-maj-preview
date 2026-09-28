// Live preview: pushes unsaved edits to the running thumbnails as they're made.
import { app } from './state.js';
import { htmlColorToZig, zigColorWithAlpha } from './colors.js';
import { logWarn, rpc } from './core.js';
import { getFieldValue, getNullableFieldValue, msFieldValue, opacityToPercent, percentToOpacity } from './form.js';

// Pushes an unsaved patch to the running main app so open thumbnails reflect edits immediately, without writing to disk. startX/startY are excluded since they can be live-dragged (see painter.zig's repositionAllThumbnails()).
const THUMBNAIL_PREVIEW_FIELD_IDS = [
    'borderEnabled', 'showBorderWhenFocused', 'borderWidth', 'borderStyle', 'borderColor',
    'showBorderWhenInactive', 'inactiveBorderWidth', 'inactiveBorderStyle', 'inactiveBorderColor',
    'thumbOpacity', 'applyOpacityToOverlayTexts', 'activeThumbnailHidden',
    'showText', 'showCharacterName', 'showSystemName', 'useUniqueSystemColors',
    'characterNameFontName', 'characterNameFontSize', 'characterNameFontWeight',
    'characterNamePosition', 'characterNameOffsetX', 'characterNameOffsetY', 'characterNameColor',
    'useUniqueCharacterNameColors', 'useUniqueCharacterBorderColors',
    'systemNamePosition', 'systemNameOffsetX', 'systemNameOffsetY', 'systemNameColor',
    'systemNameFontName', 'systemNameFontSize', 'systemNameFontWeight',
    'showQuickGroupBadge', 'quickGroupBadgePosition', 'quickGroupBadgeOffsetX', 'quickGroupBadgeOffsetY', 'quickGroupBadgeColor',
    'quickGroupBadgeFontName', 'quickGroupBadgeFontSize', 'quickGroupBadgeFontWeight',
    'exclusionOverlayStyle', 'exclusionOverlayColor', 'exclusionOverlayOpacity',
    'characterNameBgColor', 'characterNameBgOpacity', 'systemNameBgColor', 'systemNameBgOpacity',
    'quickGroupBadgeBgColor', 'quickGroupBadgeBgOpacity',
    'thumbWidth', 'thumbHeight', 'thumbSizeSlider', 'hideWhenNoEveFocus',
    'listViewOpacity', 'listViewFontName', 'listViewFontSize', 'listViewFontWeight',
    'notifInfoPanelWidth', 'notifInfoPanelHeight', 'notifInfoPanelMaxRows', 'notifInfoPanelShowTimestamp', 'notifInfoPanelShowCategoryFilters',
    'notifInfoPanelMergeEnabled', 'notifInfoPanelMergeWindowSec',
    'notifInfoPanelOpacity', 'notifInfoPanelFontName', 'notifInfoPanelFontSize', 'notifInfoPanelFontWeight',
    'spacing', 'newThumbnailSpacing', 'layoutMode', 'regionFitDirection',
    'regionFitEnabled', 'regionFitOrder', 'regionFitReorderLoggedOut', 'hideThumbnailsDuringRegionSelect', 'regionFitLimitToThumbnailSize', 'regionX', 'regionY', 'regionWidth', 'regionHeight',
    'notLoggedInSpaceEnabled', 'notLoggedInSpaceSpacing', 'notLoggedInSpaceLimitToThumbnailSize', 'notLoggedInSpaceHideThumbnailsDuringRegionSelect', 'notLoggedInSpaceX', 'notLoggedInSpaceY', 'notLoggedInSpaceWidth', 'notLoggedInSpaceHeight',
    'monitorIndex', 'useMonitorWorkArea', 'honorSavedPositions',
    'notificationsEnabled', 'notificationPosition', 'notificationOffsetX', 'notificationOffsetY',
    'notificationFontName', 'notificationFontSize', 'notificationFontWeight',
    'notificationBgColor', 'notificationBgOpacity',
    'combatEnabled', 'combatWindowSeconds', 'combatUpdateIntervalMs',
    'combatShowIncoming', 'combatShowOutgoing',
    'combatIncomingPosition', 'combatOutgoingPosition',
    'combatIncomingColor', 'combatOutgoingColor',
    'combatIncomingBgColor', 'combatIncomingBgOpacity', 'combatOutgoingBgColor', 'combatOutgoingBgOpacity',
    'combatIncomingFontSize', 'combatIncomingFontName', 'combatIncomingFontWeight',
    'combatOutgoingFontSize', 'combatOutgoingFontName', 'combatOutgoingFontWeight',
    'combatIncomingOffsetX', 'combatIncomingOffsetY', 'combatOutgoingOffsetX', 'combatOutgoingOffsetY',
    'combatIncomingShowPrefix', 'combatOutgoingShowPrefix', 'combatDamageAlertExcludedWeapons',
    'miningEnabled', 'miningWindowSeconds', 'miningUpdateIntervalMs', 'miningPosition', 'miningColor',
    'miningFontSize', 'miningFontName', 'miningFontWeight', 'miningOffsetX', 'miningOffsetY',
    'miningBgColor', 'miningBgOpacity', 'miningShowIskRate', 'miningIskRateUnit', 'miningShowPrefix',
    'miningIdleAlertWindowSeconds', 'miningIdleAlertThreshold', 'miningStoppedAlertWindowSeconds',
    'bountyEnabled', 'bountyWindowSeconds', 'bountyUpdateIntervalMs', 'bountyPosition', 'bountyColor',
    'bountyFontSize', 'bountyFontName', 'bountyFontWeight', 'bountyOffsetX', 'bountyOffsetY',
    'bountyBgColor', 'bountyBgOpacity', 'bountyIskRateUnit', 'bountyShowPrefix',
    'resourcesEnabled', 'resourcesShowCpu', 'resourcesShowRam', 'resourcesShowVram', 'resourcesUpdateIntervalMs',
    'resourcesPosition', 'resourcesColor', 'resourcesFontSize', 'resourcesFontName', 'resourcesFontWeight',
    'resourcesOffsetX', 'resourcesOffsetY', 'resourcesBgColor', 'resourcesBgOpacity',
];

let thumbnailPreviewDebounceTimer = null;

export function scheduleThumbnailPreview() {
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
        thumbnailOpacity: percentToOpacity(getFieldValue('thumbOpacity')),
        applyOpacityToOverlayTexts: getFieldValue('applyOpacityToOverlayTexts'),
        activeThumbnailHidden: getFieldValue('activeThumbnailHidden'),
        showText: getFieldValue('showText'),
        showCharacterName: getFieldValue('showCharacterName'),
        showSystemName: getFieldValue('showSystemName'),
        useUniqueSystemColors: getFieldValue('useUniqueSystemColors'),
        characterNameFontName: getFieldValue('characterNameFontName'),
        characterNameFontSize: getFieldValue('characterNameFontSize'),
        characterNameFontWeight: getFieldValue('characterNameFontWeight'),
        characterNamePosition: getFieldValue('characterNamePosition'),
        characterNameOffsetX: getFieldValue('characterNameOffsetX'),
        characterNameOffsetY: getFieldValue('characterNameOffsetY'),
        characterNameColor: getFieldValue('characterNameColor'),
        characterNameBgColor: zigColorWithAlpha(getFieldValue('characterNameBgColor'), percentToOpacity(getFieldValue('characterNameBgOpacity'))),
        useUniqueCharacterNameColors: getFieldValue('useUniqueCharacterNameColors'),
        useUniqueCharacterBorderColors: getFieldValue('useUniqueCharacterBorderColors'),
        systemNamePosition: getFieldValue('systemNamePosition'),
        systemNameOffsetX: getFieldValue('systemNameOffsetX'),
        systemNameOffsetY: getFieldValue('systemNameOffsetY'),
        systemNameColor: getFieldValue('systemNameColor'),
        systemNameBgColor: zigColorWithAlpha(getFieldValue('systemNameBgColor'), percentToOpacity(getFieldValue('systemNameBgOpacity'))),
        systemNameFontName: getFieldValue('systemNameFontName'),
        systemNameFontSize: getFieldValue('systemNameFontSize'),
        systemNameFontWeight: getFieldValue('systemNameFontWeight'),
        showQuickGroupBadge: getFieldValue('showQuickGroupBadge'),
        quickGroupBadgePosition: getFieldValue('quickGroupBadgePosition'),
        quickGroupBadgeOffsetX: getFieldValue('quickGroupBadgeOffsetX'),
        quickGroupBadgeOffsetY: getFieldValue('quickGroupBadgeOffsetY'),
        quickGroupBadgeColor: getFieldValue('quickGroupBadgeColor'),
        quickGroupBadgeBgColor: zigColorWithAlpha(getFieldValue('quickGroupBadgeBgColor'), percentToOpacity(getFieldValue('quickGroupBadgeBgOpacity'))),
        quickGroupBadgeFontName: getFieldValue('quickGroupBadgeFontName'),
        quickGroupBadgeFontSize: getFieldValue('quickGroupBadgeFontSize'),
        quickGroupBadgeFontWeight: getFieldValue('quickGroupBadgeFontWeight'),
        exclusionOverlayStyle: getFieldValue('exclusionOverlayStyle'),
        exclusionOverlayColor: zigColorWithAlpha(getFieldValue('exclusionOverlayColor'), percentToOpacity(getFieldValue('exclusionOverlayOpacity'))),
        systemColors: buildSystemColorsPreviewPatch(),
        hotkeyGroupBadges: buildHotkeyGroupBadgesPreviewPatch(),
        width: getFieldValue('thumbWidth'),
        height: getFieldValue('thumbHeight'),
        hideWhenNoEveFocus: getFieldValue('hideWhenNoEveFocus'),
        display: {
            listViewOpacity: percentToOpacity(getFieldValue('listViewOpacity')),
            listViewFontName: getFieldValue('listViewFontName'),
            listViewFontSize: getFieldValue('listViewFontSize'),
            listViewFontWeight: getFieldValue('listViewFontWeight'),
            notifInfoPanelWidth: getFieldValue('notifInfoPanelWidth'),
            notifInfoPanelHeight: getFieldValue('notifInfoPanelHeight'),
            notifInfoPanelMaxRows: getFieldValue('notifInfoPanelMaxRows'),
            notifInfoPanelShowTimestamp: getFieldValue('notifInfoPanelShowTimestamp'),
            notifInfoPanelShowCategoryFilters: getFieldValue('notifInfoPanelShowCategoryFilters'),
            notifInfoPanelMergeEnabled: getFieldValue('notifInfoPanelMergeEnabled'),
            notifInfoPanelMergeWindowSec: getFieldValue('notifInfoPanelMergeWindowSec'),
            notifInfoPanelOpacity: percentToOpacity(getFieldValue('notifInfoPanelOpacity')),
            notifInfoPanelFontName: getFieldValue('notifInfoPanelFontName'),
            notifInfoPanelFontSize: getFieldValue('notifInfoPanelFontSize'),
            notifInfoPanelFontWeight: getFieldValue('notifInfoPanelFontWeight'),
            // startX/startY are deliberately omitted - see repositionAllThumbnails() in painter.zig.
            spacing: getFieldValue('spacing'),
            newThumbnailSpacing: getFieldValue('newThumbnailSpacing'),
            layoutMode: getFieldValue('layoutMode'),
            regionFitDirection: getFieldValue('regionFitDirection'),
            regionFitOrder: getFieldValue('regionFitOrder'),
            regionFitReorderLoggedOut: getFieldValue('regionFitReorderLoggedOut'),
            hideThumbnailsDuringRegionSelect: getFieldValue('hideThumbnailsDuringRegionSelect'),
            regionFitLimitToThumbnailSize: getFieldValue('regionFitLimitToThumbnailSize'),
            regionX: getNullableFieldValue('regionX'),
            regionY: getNullableFieldValue('regionY'),
            regionWidth: getNullableFieldValue('regionWidth'),
            regionHeight: getNullableFieldValue('regionHeight'),
            notLoggedInSpaceEnabled: getFieldValue('notLoggedInSpaceEnabled'),
            notLoggedInSpaceSpacing: getFieldValue('notLoggedInSpaceSpacing'),
            notLoggedInSpaceLimitToThumbnailSize: getFieldValue('notLoggedInSpaceLimitToThumbnailSize'),
            notLoggedInSpaceHideThumbnailsDuringRegionSelect: getFieldValue('notLoggedInSpaceHideThumbnailsDuringRegionSelect'),
            notLoggedInSpaceX: getNullableFieldValue('notLoggedInSpaceX'),
            notLoggedInSpaceY: getNullableFieldValue('notLoggedInSpaceY'),
            notLoggedInSpaceWidth: getNullableFieldValue('notLoggedInSpaceWidth'),
            notLoggedInSpaceHeight: getNullableFieldValue('notLoggedInSpaceHeight'),
            monitorIndex: getNullableFieldValue('monitorIndex'),
            useMonitorWorkArea: getFieldValue('useMonitorWorkArea'),
            honorSavedPositions: getFieldValue('honorSavedPositions'),
        },
        characterOverrides: buildCharacterOverridesPreviewPatch(includePositions),
        notifications: {
            enabled: getFieldValue('notificationsEnabled'),
            position: getFieldValue('notificationPosition'),
            offset_x: getFieldValue('notificationOffsetX'),
            offset_y: getFieldValue('notificationOffsetY'),
            font_name: getFieldValue('notificationFontName'),
            font_size: getFieldValue('notificationFontSize'),
            font_weight: getFieldValue('notificationFontWeight'),
            bg_color: zigColorWithAlpha(getFieldValue('notificationBgColor'), percentToOpacity(getFieldValue('notificationBgOpacity'))),
        },
        combat: {
            enabled: getFieldValue('combatEnabled'),
            window_seconds: getFieldValue('combatWindowSeconds'),
            update_interval_ms: msFieldValue('combatUpdateIntervalMs'),
            show_incoming: getFieldValue('combatShowIncoming'),
            show_outgoing: getFieldValue('combatShowOutgoing'),
            incoming_position: getFieldValue('combatIncomingPosition'),
            outgoing_position: getFieldValue('combatOutgoingPosition'),
            incoming_color: getFieldValue('combatIncomingColor'),
            outgoing_color: getFieldValue('combatOutgoingColor'),
            incoming_bg_color: zigColorWithAlpha(getFieldValue('combatIncomingBgColor'), percentToOpacity(getFieldValue('combatIncomingBgOpacity'))),
            outgoing_bg_color: zigColorWithAlpha(getFieldValue('combatOutgoingBgColor'), percentToOpacity(getFieldValue('combatOutgoingBgOpacity'))),
            incoming_font_size: getFieldValue('combatIncomingFontSize'),
            incoming_font_name: getFieldValue('combatIncomingFontName'),
            incoming_font_weight: getFieldValue('combatIncomingFontWeight'),
            outgoing_font_size: getFieldValue('combatOutgoingFontSize'),
            outgoing_font_name: getFieldValue('combatOutgoingFontName'),
            outgoing_font_weight: getFieldValue('combatOutgoingFontWeight'),
            incoming_offset_x: getFieldValue('combatIncomingOffsetX'),
            incoming_offset_y: getFieldValue('combatIncomingOffsetY'),
            outgoing_offset_x: getFieldValue('combatOutgoingOffsetX'),
            outgoing_offset_y: getFieldValue('combatOutgoingOffsetY'),
            incoming_show_prefix: getFieldValue('combatIncomingShowPrefix'),
            outgoing_show_prefix: getFieldValue('combatOutgoingShowPrefix'),
            damage_alert_excluded_weapons: getFieldValue('combatDamageAlertExcludedWeapons'),
        },
        mining: {
            enabled: getFieldValue('miningEnabled'),
            window_seconds: getFieldValue('miningWindowSeconds'),
            update_interval_ms: msFieldValue('miningUpdateIntervalMs'),
            color: getFieldValue('miningColor'),
            bg_color: zigColorWithAlpha(getFieldValue('miningBgColor'), percentToOpacity(getFieldValue('miningBgOpacity'))),
            font_size: getFieldValue('miningFontSize'),
            font_name: getFieldValue('miningFontName'),
            font_weight: getFieldValue('miningFontWeight'),
            position: getFieldValue('miningPosition'),
            offset_x: getFieldValue('miningOffsetX'),
            offset_y: getFieldValue('miningOffsetY'),
            show_isk_rate: getFieldValue('miningShowIskRate'),
            isk_rate_unit: getFieldValue('miningIskRateUnit'),
            show_prefix: getFieldValue('miningShowPrefix'),
            idle_alert_window_seconds: getFieldValue('miningIdleAlertWindowSeconds'),
            idle_alert_threshold: getFieldValue('miningIdleAlertThreshold'),
            stopped_alert_window_seconds: getFieldValue('miningStoppedAlertWindowSeconds'),
        },
        bounty: {
            enabled: getFieldValue('bountyEnabled'),
            window_seconds: getFieldValue('bountyWindowSeconds'),
            update_interval_ms: msFieldValue('bountyUpdateIntervalMs'),
            color: getFieldValue('bountyColor'),
            bg_color: zigColorWithAlpha(getFieldValue('bountyBgColor'), percentToOpacity(getFieldValue('bountyBgOpacity'))),
            font_size: getFieldValue('bountyFontSize'),
            font_name: getFieldValue('bountyFontName'),
            font_weight: getFieldValue('bountyFontWeight'),
            position: getFieldValue('bountyPosition'),
            offset_x: getFieldValue('bountyOffsetX'),
            offset_y: getFieldValue('bountyOffsetY'),
            isk_rate_unit: getFieldValue('bountyIskRateUnit'),
            show_prefix: getFieldValue('bountyShowPrefix'),
        },
        resources: {
            enabled: getFieldValue('resourcesEnabled'),
            show_cpu: getFieldValue('resourcesShowCpu'),
            show_ram: getFieldValue('resourcesShowRam'),
            show_vram: getFieldValue('resourcesShowVram'),
            update_interval_ms: msFieldValue('resourcesUpdateIntervalMs'),
            color: getFieldValue('resourcesColor'),
            bg_color: zigColorWithAlpha(getFieldValue('resourcesBgColor'), percentToOpacity(getFieldValue('resourcesBgOpacity'))),
            font_size: getFieldValue('resourcesFontSize'),
            font_name: getFieldValue('resourcesFontName'),
            font_weight: getFieldValue('resourcesFontWeight'),
            position: getFieldValue('resourcesPosition'),
            offset_x: getFieldValue('resourcesOffsetX'),
            offset_y: getFieldValue('resourcesOffsetY'),
        },
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

// Badge flags only, in group order - the running app keeps its own membership, which for a temporary group exists nowhere else.
function buildHotkeyGroupBadgesPreviewPatch() {
    if (!app.currentConfig || !app.currentConfig.hotkeyGroups) return [];
    return app.currentConfig.hotkeyGroups.map((group, index) => {
        const field = document.getElementById(`hkgroup_${index}_showBadge`);
        return field ? field.checked : !!group.showBadge;
    });
}

// A color counts as "set" if it was already set on load, or the user changed it from the #000000 default; "Clear to Default" sets dataset.cleared to override this.
export function resolveOptionalColor(input, hadValue) {
    if (!input || input.dataset.cleared === 'true') return null;
    const changed = input.value.toUpperCase() !== '#000000';
    return (hadValue || changed) ? htmlColorToZig(input.value) : null;
}

// No separate "override enabled" toggle - a slider left at the current global opacity reads as "inherit" (null); moving it away from that value is what marks it as a per-character override.
export function resolveCharacterOpacity(field) {
    if (!field) return null;
    const percent = parseInt(field.value);
    return (percent !== opacityToPercent(app.currentConfig.thumbnail.thumbnailOpacity)) ? percentToOpacity(percent) : null;
}

// Reads straight from the accordion DOM using the same "set OR changed from #000000 default" convention as saveCharacters(), so live preview and Save agree on what counts as "set".
function buildCharacterOverridesPreviewPatch(includePositions = false) {
    if (!app.currentConfig || !app.currentConfig.characters) return [];
    const result = [];
    app.currentConfig.characters.forEach((char, index) => {
        if (!char.name) return;

        const width = document.getElementById(`char_${index}_width`);
        const height = document.getElementById(`char_${index}_height`);
        const activeColor = document.getElementById(`char_${index}_activeColor`);
        const inactiveColor = document.getElementById(`char_${index}_inactiveColor`);
        const nameColor = document.getElementById(`char_${index}_nameColor`);
        const displayNameField = document.getElementById(`char_${index}_displayName`);
        const hideThumbnailField = document.getElementById(`char_${index}_hideThumbnail`);
        const opacityField = document.getElementById(`char_${index}_opacity`);
        if (!width && !height && !activeColor && !inactiveColor && !nameColor && !displayNameField && !hideThumbnailField && !opacityField) return;

        const displayName = displayNameField ? (displayNameField.value.trim() || null) : null;
        const hideThumbnail = hideThumbnailField ? hideThumbnailField.checked : false;
        const opacity = resolveCharacterOpacity(opacityField);

        const w = width ? (parseInt(width.value) || null) : null;
        const h = height ? (parseInt(height.value) || null) : null;
        const thumbnailSize = (w || h) ? { width: w, height: h } : null;

        const activeOut = resolveOptionalColor(activeColor, !!(char.borderColors && char.borderColors.activeBorderColor));
        const inactiveOut = resolveOptionalColor(inactiveColor, !!(char.borderColors && char.borderColors.inactiveBorderColor));
        const borderColors = (activeOut || inactiveOut)
            ? { activeBorderColor: activeOut, inactiveBorderColor: inactiveOut }
            : null;

        const nameColorOut = resolveOptionalColor(nameColor, !!char.nameColor);

        const entry = { name: char.name, displayName, hideThumbnail, thumbnailSize, borderColors, nameColor: nameColorOut, opacity };
        if (includePositions && char.position) entry.position = char.position;
        result.push(entry);
    });
    return result;
}

export async function sendThumbnailPreview(includePositions = false) {
    if (typeof webui === 'undefined' || !app.webuiReady || !app.currentConfig) return;
    // Never push a preview onto a profile the dialog hasn't confirmed is actually running - see switchProfile()'s live-switch modal.
    if (!app.dialogEditingProfile || app.dialogEditingProfile !== app.liveConfirmedProfile) return;
    try {
        await rpc('previewThumbnailConfig', { json: JSON.stringify(buildThumbnailPreviewPatch(includePositions)) });
    } catch (error) {
        logWarn('Failed to send thumbnail preview:', error);
    }
}

export function setupThumbnailPreview() {
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
        const isPreviewableCharField = (id) => /^char_\d+_(width|height|activeColor|inactiveColor|nameColor|displayName|hideThumbnail|opacity)$/.test(id);
        charactersList.addEventListener('input', (e) => {
            if (isPreviewableCharField(e.target.id)) scheduleThumbnailPreview();
        });
        charactersList.addEventListener('change', (e) => {
            if (isPreviewableCharField(e.target.id)) scheduleThumbnailPreview();
        });
    }
}
