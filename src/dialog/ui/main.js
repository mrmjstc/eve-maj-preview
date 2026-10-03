// Entry point: wires up the page once the DOM is ready, and exposes the handlers inline on* attributes call.
import { loadSchema } from './binding.js';
import { setupChangeDetection } from './changes.js';
import { addCharacter, clearCharacterSearch, confirmClearAllCharacterWindowPositions, confirmClearCharacterWindowPosition, confirmRemoveCharacter, onCharacterSearchInput, populateCharactersFromClients, refreshWindowPositionSourceOptions, selectCharacter, setAllCharacterWindowPositions, setCharacterWindowPosition, updateCharacterHeaderName } from './characters.js';
import { logError, waitForWebUI } from './core.js';
import { populateLanguageSelect, populateSharedSelectOptions } from './form.js';
import { addAppHotkey, addUrlHotkey, applyPickedWindowForAppHotkey, pickRunningWindowForAppHotkey, removeAppHotkey, removeUrlHotkey, updateUrlHotkeyUploadClipboardVisibility } from './global_hotkeys.js';
import { changeDialogScale, toggleAdvancedMode, toggleAlwaysOnTop, toggleSectionHint } from './global_settings.js';
import { addHotkeyGroup, addHotkeyGroupCharacter, fillHotkeyGroupFromClients, removeHotkeyGroup, removeHotkeyGroupCharacter, selectHotkeyGroup, suggestOpenClients, toggleHotkeyGroupMembershipEditor, updateHotkeyGroupHeaderName } from './hotkey_groups.js';
import { alignBindingLabelColumns, clearHotkey, recordHotkey, renderHotkeyBindings, toggleManualHotkeyEdit } from './hotkeys.js';
import { applyTranslations, switchLanguage, t } from './i18n.js';
import { closeImportModal, handleImportFileSelected, initImportAccentColorPreview, onImportDestChanged, onImportSourceProfileChanged, openImportModal, runImport } from './import.js';
import { buildSectionNav, closeDialog, initDelegatedKeyboardActivation, initializeTabs, showStatus } from './layout.js';
import { browseSoundFile, clearNotificationTypeSearch, clearSoundFile, onNotificationTypeSearchInput, selectNotificationType, testNotification, toggleNotifBorderColor, toggleNotificationTypeEnabled, toggleNotifShowBorder, toggleNotifSoundEnabled, toggleNotifTextColor } from './notifications.js';
import { browseChatlogDir, browseGamelogDir, initCombatShowRequiresEnabled, toggleAutoMinimizeOptions, toggleBorderOptions, toggleBountyOptions, toggleCharacterNameOptions, toggleChatlogOptions, toggleClickThroughOptions, toggleClientListOptions, toggleCombatOptions, toggleFocusedBorderOptions, toggleInactiveBorderOptions, toggleMiningOptions, toggleNotificationOptions, toggleNotifInfoPanelMergeOptions, toggleNotifInfoPanelOptions, toggleNotLoggedInSpaceOptions, toggleQuickGroupBadgeOptions, toggleRegionFitOptions, toggleResourcesOptions, toggleShiftClickExcludeOptions, toggleSnappingOptions, toggleSystemNameOptions, toggleTextDisplayOptions, toggleTravelOptions, toggleTtsDisplayNameOption, toggleUniqueCharacterColors, toggleUniqueCharacterNameColors, toggleUniqueSystemColors, toggleWindowFilters } from './options.js';
import { fetchOrePrices } from './ore_table.js';
import { initOverlayLayoutPreview } from './overlay_layout.js';
import { copyCurrentProfile, createNewProfile, deleteCurrentProfile, resetCurrentProfile, restoreSelectedProfileBackup, switchProfile } from './profiles.js';
import { clearRegion, NOT_LOGGED_IN_FIELD_IDS, REGION_FIELD_IDS, startRegionSelectFlow } from './region.js';
import { clearSearch, onSearchInput, searchState } from './search.js';
import { loadAppVersion, openSession, saveConfiguration } from './session.js';
import { addSystemColor, removeSystemColor } from './system_colors.js';
import { detectThumbnailClientSize, onThumbAspectRatioChange, onThumbHeightChange, onThumbHeightInput, onThumbSizeSlider, onThumbWidthChange, onThumbWidthInput } from './thumbnail_size.js';
import { applyUltraPotatoMode, scanUltraPotatoProfiles } from './ultra_potato.js';
import { checkForUpdateNotification, openExternalLink } from './update.js';
import { confirmRemove, initConfirmButtonWidthReservation, toggleAccordionEl } from './widgets.js';
import { addWindowFilter, applyPickedWindowForFilter, carryWindowFilterRename, pickRunningWindowForFilter, rememberWindowFilterName, removeWindowFilter, selectWindowFilter, updateWindowFilterHeaderName } from './window_filters.js';

document.addEventListener('DOMContentLoaded', async function() {
    applyTranslations();
    renderHotkeyBindings();
    populateLanguageSelect();
    populateSharedSelectOptions();
    setupChangeDetection();
    initOverlayLayoutPreview();
    initCombatShowRequiresEnabled();
    initImportAccentColorPreview();

    // Mark initially hidden tabs for search filter
    document.querySelectorAll('.tab-item').forEach(tab => {
        if (tab.style.display === 'none') {
            const tabId = tab.getAttribute('data-tab');
            searchState.initiallyHiddenTabs.push(tabId);
        }
    });
    
    initializeTabs();
    // The default active tab never goes through switchTab(), so its .binding-lists would otherwise
    // never get the shared computed column width every other tab gets when first switched to.
    const initialPanel = document.querySelector('.panel-content.active')?.dataset.panel;
    if (initialPanel) alignBindingLabelColumns(`.panel-content[data-panel="${initialPanel}"]`);
    initDelegatedKeyboardActivation();
    initConfirmButtonWidthReservation();
    buildSectionNav();

    const ready = await waitForWebUI();
    if (ready) {
        // Fire independent calls immediately instead of serializing a round trip each.
        // The form binds by the schema, so the session waits for it.
        const sessionOpened = loadSchema().then(openSession, (error) => {
            logError('Failed to load the settings schema:', error);
            showStatus(t('status.failedPrefix') + error.message, 'error');
        });
        loadAppVersion();
        refreshWindowPositionSourceOptions();
        scanUltraPotatoProfiles();

        await sessionOpened;
        checkForUpdateNotification();
    } else {
        showStatus(t('status.webuiInitFailed'), 'error');
    }
});

// Inline on* handlers in the HTML and in rendered templates run in global scope.
Object.assign(window, {
    NOT_LOGGED_IN_FIELD_IDS,
    REGION_FIELD_IDS,
    addAppHotkey,
    addCharacter,
    addHotkeyGroup,
    addHotkeyGroupCharacter,
    addSystemColor,
    addUrlHotkey,
    addWindowFilter,
    applyPickedWindowForAppHotkey,
    applyPickedWindowForFilter,
    applyUltraPotatoMode,
    browseChatlogDir,
    browseGamelogDir,
    browseSoundFile,
    carryWindowFilterRename,
    changeDialogScale,
    clearCharacterSearch,
    clearHotkey,
    clearNotificationTypeSearch,
    clearRegion,
    clearSearch,
    clearSoundFile,
    closeDialog,
    closeImportModal,
    confirmClearAllCharacterWindowPositions,
    confirmClearCharacterWindowPosition,
    confirmRemove,
    confirmRemoveCharacter,
    copyCurrentProfile,
    createNewProfile,
    deleteCurrentProfile,
    detectThumbnailClientSize,
    fetchOrePrices,
    fillHotkeyGroupFromClients,
    handleImportFileSelected,
    onCharacterSearchInput,
    onImportDestChanged,
    onImportSourceProfileChanged,
    onNotificationTypeSearchInput,
    onSearchInput,
    onThumbAspectRatioChange,
    onThumbHeightChange,
    onThumbHeightInput,
    onThumbSizeSlider,
    onThumbWidthChange,
    onThumbWidthInput,
    openExternalLink,
    openImportModal,
    pickRunningWindowForAppHotkey,
    pickRunningWindowForFilter,
    populateCharactersFromClients,
    recordHotkey,
    refreshWindowPositionSourceOptions,
    rememberWindowFilterName,
    removeAppHotkey,
    removeHotkeyGroup,
    removeHotkeyGroupCharacter,
    removeSystemColor,
    removeUrlHotkey,
    removeWindowFilter,
    resetCurrentProfile,
    restoreSelectedProfileBackup,
    runImport,
    saveConfiguration,
    scanUltraPotatoProfiles,
    selectCharacter,
    selectHotkeyGroup,
    selectNotificationType,
    selectWindowFilter,
    setAllCharacterWindowPositions,
    setCharacterWindowPosition,
    startRegionSelectFlow,
    suggestOpenClients,
    switchLanguage,
    switchProfile,
    testNotification,
    toggleAccordionEl,
    toggleAdvancedMode,
    toggleAlwaysOnTop,
    toggleAutoMinimizeOptions,
    toggleBorderOptions,
    toggleBountyOptions,
    toggleCharacterNameOptions,
    toggleChatlogOptions,
    toggleClickThroughOptions,
    toggleClientListOptions,
    toggleCombatOptions,
    toggleFocusedBorderOptions,
    toggleHotkeyGroupMembershipEditor,
    toggleInactiveBorderOptions,
    toggleManualHotkeyEdit,
    toggleMiningOptions,
    toggleNotLoggedInSpaceOptions,
    toggleNotifBorderColor,
    toggleNotifInfoPanelMergeOptions,
    toggleNotifInfoPanelOptions,
    toggleNotifShowBorder,
    toggleNotifSoundEnabled,
    toggleNotifTextColor,
    toggleNotificationOptions,
    toggleNotificationTypeEnabled,
    toggleQuickGroupBadgeOptions,
    toggleRegionFitOptions,
    toggleResourcesOptions,
    toggleSectionHint,
    toggleShiftClickExcludeOptions,
    toggleSnappingOptions,
    toggleSystemNameOptions,
    toggleTextDisplayOptions,
    toggleTravelOptions,
    toggleTtsDisplayNameOption,
    toggleUniqueCharacterColors,
    toggleUniqueCharacterNameColors,
    toggleUniqueSystemColors,
    toggleWindowFilters,
    updateCharacterHeaderName,
    updateHotkeyGroupHeaderName,
    updateUrlHotkeyUploadClipboardVisibility,
    updateWindowFilterHeaderName,
});
