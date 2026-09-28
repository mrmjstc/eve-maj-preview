// Entry point: wires up the page once the DOM is ready, and exposes the handlers inline on* attributes call.
import { app } from './state.js';
import { setupChangeDetection } from './changes.js';
import { addCharacter, clearCharacterSearch, confirmClearAllCharacterWindowPositions, confirmClearCharacterWindowPosition, confirmRemoveCharacter, onCharacterSearchInput, populateCharactersFromClients, refreshWindowPositionSourceOptions, selectCharacter, setAllCharacterWindowPositions, setCharacterWindowPosition, updateCharacterHeaderName } from './characters.js';
import { waitForWebUI } from './core.js';
import { loadDefaultConfig, loadValidationRanges, populateLanguageSelect, populateSharedSelectOptions } from './form.js';
import { addAppHotkey, addUrlHotkey, applyPickedWindowForAppHotkey, pickRunningWindowForAppHotkey, removeAppHotkey, removeUrlHotkey, updateUrlHotkeyUploadClipboardVisibility } from './global_hotkeys.js';
import { changeDialogScale, loadGlobalSettingsFromBackend, toggleAdvancedMode, toggleAlwaysOnTop, toggleSectionHint } from './global_settings.js';
import { addHotkeyGroup, addHotkeyGroupCharacter, fillHotkeyGroupFromClients, removeHotkeyGroup, removeHotkeyGroupCharacter, selectHotkeyGroup, suggestOpenClients, toggleHotkeyGroupMembershipEditor, updateHotkeyGroupHeaderName } from './hotkey_groups.js';
import { alignBindingLabelColumns, clearHotkey, recordHotkey, renderHotkeyBindings, toggleManualHotkeyEdit } from './hotkeys.js';
import { applyTranslations, switchLanguage, t } from './i18n.js';
import { closeImportModal, handleImportFileSelected, initImportAccentColorPreview, onImportDestChanged, onImportSourceProfileChanged, openImportModal, runImport } from './import.js';
import { buildSectionNav, closeDialog, initDelegatedKeyboardActivation, initializeTabs, showStatus } from './layout.js';
import { browseSoundFile, clearNotificationTypeSearch, clearSoundFile, onNotificationTypeSearchInput, selectNotificationType, testNotification, toggleNotifBorderColor, toggleNotifShowBorder, toggleNotifSoundEnabled, toggleNotifTextColor, toggleNotificationTypeEnabled } from './notifications.js';
import { browseChatlogDir, browseGamelogDir, initCombatShowRequiresEnabled, onThumbHeightInput, onThumbSizeSlider, onThumbWidthInput, toggleAspectRatioSlider, toggleAutoMinimizeOptions, toggleBorderOptions, toggleBountyOptions, toggleCharacterNameOptions, toggleChatlogOptions, toggleClickThroughOptions, toggleClientListOptions, toggleCombatOptions, toggleFocusedBorderOptions, toggleInactiveBorderOptions, toggleMiningOptions, toggleNotLoggedInSpaceOptions, toggleNotifInfoPanelMergeOptions, toggleNotifInfoPanelOptions, toggleNotificationOptions, toggleQuickGroupBadgeOptions, toggleRegionFitOptions, toggleResourcesOptions, toggleShiftClickExcludeOptions, toggleSnappingOptions, toggleSystemNameOptions, toggleTextDisplayOptions, toggleTravelOptions, toggleTtsDisplayNameOption, toggleUniqueCharacterColors, toggleUniqueCharacterNameColors, toggleUniqueSystemColors, toggleWindowFilters } from './options.js';
import { fetchOrePrices } from './ore_table.js';
import { initOverlayLayoutPreview } from './overlay_layout.js';
import { scheduleThumbnailPreview, setupThumbnailPreview } from './preview.js';
import { copyCurrentProfile, createNewProfile, deleteCurrentProfile, loadProfileList, resetCurrentProfile, restoreSelectedProfileBackup, switchProfile } from './profiles.js';
import { NOT_LOGGED_IN_FIELD_IDS, REGION_FIELD_IDS, clearRegion, startRegionSelectFlow } from './region.js';
import { clearSearch, onSearchInput, searchState } from './search.js';
import { loadAppVersion, loadConfigurationFromBackend, saveConfiguration } from './session.js';
import { addSystemColor, removeSystemColor } from './system_colors.js';
import { applyUltraPotatoMode, scanUltraPotatoProfiles } from './ultra_potato.js';
import { checkForUpdateNotification, openExternalLink } from './update.js';
import { confirmRemove, initConfirmButtonWidthReservation, toggleAccordionEl } from './widgets.js';
import { addWindowFilter, applyPickedWindowForFilter, pickRunningWindowForFilter, removeWindowFilter, selectWindowFilter, updateWindowFilterHeaderName } from './window_filters.js';

document.addEventListener('DOMContentLoaded', async function() {
    applyTranslations();
    renderHotkeyBindings();
    populateLanguageSelect();
    populateSharedSelectOptions();
    setupChangeDetection();
    setupThumbnailPreview();
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
        // Fire independent calls immediately instead of serializing a round trip each - only loadProfileList()'s completion is needed below.
        const profileListLoaded = loadProfileList();
        loadConfigurationFromBackend();
        const globalSettingsLoaded = loadGlobalSettingsFromBackend();
        loadAppVersion();
        loadDefaultConfig();
        loadValidationRanges();
        refreshWindowPositionSourceOptions();
        scanUltraPotatoProfiles();

        await profileListLoaded;
        app.dialogEditingProfile = document.getElementById('profile-select').value;

        await globalSettingsLoaded;
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
    fetchOrePrices,
    fillHotkeyGroupFromClients,
    handleImportFileSelected,
    onCharacterSearchInput,
    onImportDestChanged,
    onImportSourceProfileChanged,
    onNotificationTypeSearchInput,
    onSearchInput,
    onThumbHeightInput,
    onThumbSizeSlider,
    onThumbWidthInput,
    openExternalLink,
    openImportModal,
    pickRunningWindowForAppHotkey,
    pickRunningWindowForFilter,
    populateCharactersFromClients,
    recordHotkey,
    refreshWindowPositionSourceOptions,
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
    scheduleThumbnailPreview,
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
    toggleAspectRatioSlider,
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
