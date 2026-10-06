// Showing and hiding dependent options as their parent settings change.
import { logError, logWarn, rpc } from './core.js';
import { notificationTypes, toggleNotificationTypeEnabled } from './notifications.js';
import { setOverlayCheckboxValue } from './overlay_layout.js';
import { alignDetailPanelNameLabel } from './widgets.js';

// Returns the checkbox's checked state (or undefined if either element is missing) so callers that need to chain extra logic still can.
function applyOptionToggle(checkboxId, optionsId) {
    const checkbox = document.getElementById(checkboxId);
    const options = document.getElementById(optionsId);
    if (!checkbox || !options) return undefined;

    const enabled = checkbox.checked;
    options.classList.toggle('is-disabled', !enabled);
    return enabled;
}

export function toggleSnappingOptions() {
    applyOptionToggle('snappingEnabled', 'snappingOptions');
}

export function toggleNotifInfoPanelOptions() {
    applyOptionToggle('showNotifInfoPanel', 'notifInfoPanelOptions');
}

export function toggleNotifInfoPanelMergeOptions() {
    applyOptionToggle('notifInfoPanelMergeEnabled', 'notifInfoPanelMergeOptions');
}

// Only the chosen placement mode's settings show.
export function togglePlacementMode() {
    const isSpaces = document.getElementById('placementMode')?.value === 'ThumbnailSpaces';
    const manual = document.getElementById('placementManualOptions');
    const spaces = document.getElementById('placementSpacesOptions');
    if (manual) manual.style.display = isSpaces ? 'none' : '';
    if (spaces) spaces.style.display = isSpaces ? '' : 'none';
    // The list could only be measured once it's shown.
    if (isSpaces) alignDetailPanelNameLabel('thumbnailSpacesList');
}

export function toggleShiftClickExcludeOptions() {
    applyOptionToggle('enableShiftClickExclude', 'shiftClickExcludeOptions');
}

export function toggleClientListOptions() {
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

    clientListOptions.classList.toggle('is-disabled', !isClientList);

    if (listViewOrder) listViewOrder.disabled = !isClientList;
    if (rememberListViewPosition) rememberListViewPosition.disabled = !isClientList;
    if (listViewOpacity) listViewOpacity.disabled = !isClientList;
    if (listViewColumns) listViewColumns.disabled = !isClientList;
    if (listViewFontName) listViewFontName.disabled = !isClientList;
    if (listViewFontSize) listViewFontSize.disabled = !isClientList;
    if (listViewFontWeight) listViewFontWeight.disabled = !isClientList;
}

export function toggleWindowFilters() {
    applyOptionToggle('windowFiltersEnabled', 'windowFiltersOptions');
}

export function toggleBorderOptions() {
    applyOptionToggle('borderEnabled', 'borderOptions');
    toggleUniqueCharacterColors();
}

export function toggleFocusedBorderOptions() {
    applyOptionToggle('showBorderWhenFocused', 'focusedBorderOptions');
}

export function toggleInactiveBorderOptions() {
    applyOptionToggle('showBorderWhenInactive', 'inactiveBorderOptions');
}

export function toggleUniqueCharacterColors() {
    const uniqueColorsCheckbox = document.getElementById('useUniqueCharacterBorderColors');
    const focusedBorderColorOptions = document.getElementById('focusedBorderColorOptions');
    const inactiveBorderColorOptions = document.getElementById('inactiveBorderColorOptions');

    if (uniqueColorsCheckbox) {
        // Inactive border color is per-character too (see resolveOptionalColor) -
        // it dims along with the focused field instead of staying interactive while overridden.
        focusedBorderColorOptions?.classList.toggle('is-disabled', uniqueColorsCheckbox.checked);
        inactiveBorderColorOptions?.classList.toggle('is-disabled', uniqueColorsCheckbox.checked);
    }
}

export function toggleTextDisplayOptions() {
    applyOptionToggle('showText', 'textDisplayOptions');
}

export function toggleCharacterNameOptions() {
    applyOptionToggle('showCharacterName', 'characterNameOptions');
}

export function toggleSystemNameOptions() {
    applyOptionToggle('showSystemName', 'systemNameOptions');
}

export function toggleQuickGroupBadgeOptions() {
    applyOptionToggle('showQuickGroupBadge', 'quickGroupBadgeOptions');
}

export function toggleSessionTimerOptions() {
    applyOptionToggle('showSessionTimer', 'sessionTimerOptions');
}

export function toggleHoverZoomOptions() {
    applyOptionToggle('hoverZoomEnabled', 'hoverZoomOptions');
}

// Opposite polarity of applyOptionToggle(): the target options are disabled when the checkbox IS checked.
function toggleInverseOption(checkboxId, optionsId) {
    const checkbox = document.getElementById(checkboxId);
    const options = document.getElementById(optionsId);
    if (!checkbox || !options) return;

    options.classList.toggle('is-disabled', checkbox.checked);
}

export function toggleUniqueSystemColors() {
    toggleInverseOption('useUniqueSystemColors', 'systemNameColorOption');
}

export function toggleClickThroughOptions() {
    toggleInverseOption('clickThrough', 'clickThroughOptions');
    toggleInverseOption('clickThrough', 'enableDraggingOption');
    toggleInverseOption('clickThrough', 'hoverZoomClickThroughOptions');
}

export function toggleUniqueCharacterNameColors() {
    toggleInverseOption('useUniqueCharacterNameColors', 'characterNameColorOption');
}

export function toggleAutoMinimizeOptions() {
    applyOptionToggle('autoMinimizeEnabled', 'autoMinimizeOptions');
}

export function toggleNotificationOptions() {
    const notificationsEnabled = document.getElementById('notificationsEnabled');
    const notificationOptions = document.getElementById('notificationOptions');
    const notificationTypesContainer = document.getElementById('notificationTypesList');
    // Text-to-Speech is its own section now, but it still only means something
    // while notifications are firing, so it dims with the rest - same pattern
    // as Combat/Mining's Alerts sections depending on their own Enable checkbox.
    const ttsSection = document.getElementById('ttsSection');

    if (notificationsEnabled && notificationOptions) {
        const isEnabled = notificationsEnabled.checked;

        notificationOptions.classList.toggle('is-disabled', !isEnabled);
        ttsSection?.classList.toggle('is-disabled', !isEnabled);

        if (notificationTypesContainer) {
            const inputs = notificationTypesContainer.querySelectorAll('input');
            inputs.forEach(input => {
                input.disabled = !isEnabled;
            });

            // Re-apply per-row state so border color pickers aren't spuriously enabled when their per-type checkbox is unchecked.
            if (isEnabled) notificationTypes().forEach(nt => toggleNotificationTypeEnabled(nt.key));
        }
    }
}

// Use Display Name only matters when the character name is actually spoken.
export function toggleTtsDisplayNameOption() {
    const speakCharacterName = document.getElementById('ttsSpeakCharacterName');
    const useDisplayName = document.getElementById('ttsUseDisplayName');
    if (useDisplayName) {
        useDisplayName.disabled = !(speakCharacterName && speakCharacterName.checked);
    }
}

export function toggleChatlogOptions() {
    applyOptionToggle('chatlogEnabled', 'chatlogOptions');
    toggleChatlogGateNotice('notificationsChatlogGate');
}

// Notifications are driven by chatlog/gamelog parsing, so it's worth flagging
// up front rather than leaving a checkbox that silently does nothing.
function toggleChatlogGateNotice(gateNoticeId) {
    const chatlogEnabled = document.getElementById('chatlogEnabled');
    const gateNotice = document.getElementById(gateNoticeId);
    if (!chatlogEnabled || !gateNotice) return;

    gateNotice.classList.toggle('show', !chatlogEnabled.checked);
}

export function initCombatShowRequiresEnabled() {
    ['combatShowIncoming', 'combatShowOutgoing'].forEach(id => {
        document.getElementById(id)?.addEventListener('change', function () {
            if (this.checked) setOverlayCheckboxValue('combatEnabled', true);
        });
    });
}

export function toggleCombatOptions() {
    applyOptionToggle('combatEnabled', 'combatOptions');
}

export function toggleMiningOptions() {
    applyOptionToggle('miningEnabled', 'miningOptions');
    applyOptionToggle('miningEnabled', 'miningAlertsOptions');
    applyOptionToggle('miningShowIskRate', 'miningIskRateOptions');
}

export function toggleBountyOptions() {
    applyOptionToggle('bountyEnabled', 'bountyOptions');
}

export function toggleResourcesOptions() {
    applyOptionToggle('resourcesEnabled', 'resourcesOptions');
}

export function toggleTravelOptions() {
    applyOptionToggle('travelEnabled', 'travelOptions');

    const mode = document.getElementById('travelThresholdMode');
    const percentRow = document.getElementById('travelThresholdPercentRow');
    const countRow = document.getElementById('travelThresholdCountRow');
    if (!mode || !percentRow || !countRow) return;

    const isPercent = mode.value === 'percent';
    percentRow.style.display = isPercent ? '' : 'none';
    countRow.style.display = isPercent ? 'none' : '';
}

async function browseLogDir(method, inputId, label) {
    try {
        if (typeof eveRpc !== 'undefined') {
            const result = await rpc(method);
            if (result) {
                const input = document.getElementById(inputId);
                if (input) {
                    input.value = result;
                }
            }
        } else {
            logWarn(`App connection not available for browsing ${label} directory`);
        }
    } catch (error) {
        logError(`Failed to browse ${label} directory:`, error);
    }
}

export function browseChatlogDir() {
    return browseLogDir('browseChatlogDir', 'chatlogDir', 'chatlog');
}

export function browseGamelogDir() {
    return browseLogDir('browseGamelogDir', 'gamelogDir', 'gamelog');
}
