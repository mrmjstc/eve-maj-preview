// Per-type notification settings, sounds and the Test button.
import { app } from './state.js';
import { htmlColorToZig, zigColorToHtml } from './colors.js';
import { escapeHtml, logError, logWarn, rpc } from './core.js';
import { applySchemaToInputs, defaultFor } from './binding.js';
import { soundFileBaseName } from './form.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { toggleNotificationOptions } from './options.js';
import { flushEdits } from './session.js';
import { makeRosterSearchFilter, selectMasterDetailRow } from './widgets.js';

// In the app's order, grouped by category (see config/schema.zig).
export function notificationTypes() {
    return (app.schema?.notificationTypes || []).map(type => ({ ...type, key: type.name }));
}

// Border is an approximation - the true fallback is the Alert state's border color, which isn't wired up in this dialog yet.
function notifDefaultTextColorHtml() {
    return zigColorToHtml(defaultFor('thumbnail.characterNameColor'));
}
function notifDefaultBorderColorHtml() {
    return zigColorToHtml(defaultFor('thumbnail.inactiveBorderColor'));
}

// Which event type's detail panel is showing in the master-detail Event Alerts view.
let selectedNotificationTypeIndex = 0;

const notificationTypeSearchFilter = makeRosterSearchFilter('notificationTypesList');
export function onNotificationTypeSearchInput(query) { notificationTypeSearchFilter.onInput(query); }
export function clearNotificationTypeSearch() { notificationTypeSearchFilter.clear('notificationTypeSearchFilter'); }
function applyNotificationTypeFilter() { notificationTypeSearchFilter.apply(); }

export function populateNotificationTypes() {
    const container = document.getElementById('notificationTypesList');
    if (!container) return;

    if (!app.currentConfig.thumbnail) app.currentConfig.thumbnail = {};
    if (!app.currentConfig.thumbnail.notifications) app.currentConfig.thumbnail.notifications = {};
    if (!app.currentConfig.thumbnail.notifications.type_configs) {
        app.currentConfig.thumbnail.notifications.type_configs = {};
    }

    const typeConfigs = app.currentConfig.thumbnail.notifications.type_configs;
    const types = notificationTypes();

    if (selectedNotificationTypeIndex >= types.length) selectedNotificationTypeIndex = types.length - 1;
    if (selectedNotificationTypeIndex < 0) selectedNotificationTypeIndex = 0;

    const rosterRows = types.map((notifType, index) => {
        const eventLabel = t('notification.' + notifType.key + '.label');

        return `
            <div class="roster-row ${index === selectedNotificationTypeIndex ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${index === selectedNotificationTypeIndex}" data-index="${index}" onclick="selectNotificationType(${index})">
                <span class="roster-name" title="${eventLabel}">${eventLabel}</span>
            </div>
        `;
    }).join('');

    const detailPanels = types.map((notifType, index) => {
        const config = typeConfigs[notifType.key] || {};
        const hasBorderColor = config.border_color != null;
        const borderColorHtml = hasBorderColor ? zigColorToHtml(config.border_color) : notifDefaultBorderColorHtml();
        const hasTextColor = config.text_color != null;
        const textColorHtml = hasTextColor ? zigColorToHtml(config.text_color) : notifDefaultTextColorHtml();

        return `
        <div class="detail-panel ${index === selectedNotificationTypeIndex ? 'active' : ''}" data-index="${index}">
            <div class="detail-panel-header">
                <span class="detail-panel-name-label">${t('notification.' + notifType.key + '.label')}</span>
            </div>
            <div class="detail-form">
                <div class="detail-field detail-field-top">
                    <label>${t('tab.notifications.table.notification.heading')}</label>
                    <div class="detail-checks">
                        <label title="${t('tab.notifications.table.enabled.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_enabled" ${config.enabled ? 'checked' : ''}
                                   onchange="toggleNotificationTypeEnabled('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.enabled.heading')}</span>
                        </label>
                        <div class="field-row">
                            <label for="notif_${notifType.key}_duration" title="${t('tab.notifications.table.duration.title')}">${t('tab.notifications.table.duration.heading')}</label>
                            <input type="number" class="detail-number-input" id="notif_${notifType.key}_duration" data-range="thumbnail.notifications.type_configs.*.duration_ms" data-unit="s" step="0.1"
                                   value="${config.duration_ms && config.duration_ms > 0 ? config.duration_ms / 1000 : 5}">
                        </div>
                        <p class="hint hint-extra">${t('tab.notifications.detail.duration.hint')}</p>
                        <div class="field-row">
                            <label for="notif_${notifType.key}_throttle" title="${t('tab.notifications.table.throttle.title')}">${t('tab.notifications.table.throttle.heading')}</label>
                            <input type="number" class="detail-number-input" id="notif_${notifType.key}_throttle" data-range="thumbnail.notifications.type_configs.*.throttle_ms" data-unit="s" step="1"
                                   title="${t('tab.notifications.table.throttle.title')}"
                                   value="${config.throttle_ms !== undefined ? config.throttle_ms / 1000 : 10}">
                        </div>
                        <p class="hint hint-extra">${t('tab.notifications.detail.throttle.hint')}</p>
                    </div>
                </div>
                <div class="detail-field detail-field-top">
                    <label>${t('dynamic.character.behaviorHeading')}</label>
                    <div class="detail-checks">
                        <label title="${t('tab.notifications.table.suppress-focused.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_suppressFocused"
                                   ${config.suppress_when_focused ? 'checked' : ''}>
                            <span class="label-body">${t('tab.notifications.detail.suppress-focused.heading')}</span>
                        </label>
                        <p class="hint hint-extra">${t('tab.notifications.detail.suppress-focused.hint')}</p>
                        <label title="${t('tab.notifications.table.suppress-clicked.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_suppressClicked"
                                   ${config.suppress_when_clicked ? 'checked' : ''}>
                            <span class="label-body">${t('tab.notifications.detail.suppress-clicked.heading')}</span>
                        </label>
                        <p class="hint hint-extra">${t('tab.notifications.detail.suppress-clicked.hint')}</p>
                        <label title="${t('tab.notifications.table.speech.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_tts"
                                   ${config.tts_enabled ? 'checked' : ''}>
                            <span class="label-body">${t('tab.notifications.detail.speech.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.sound.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_soundEnabled"
                                   ${config.sound_enabled ? 'checked' : ''}
                                   onchange="toggleNotifSoundEnabled('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.sound.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.border-show.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_showBorder"
                                   ${config.show_border ? 'checked' : ''}
                                   onchange="toggleNotifShowBorder('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.border-show.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.border-flash.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_flashBorder"
                                   ${config.flash_border ? 'checked' : ''}>
                            <span class="label-body">${t('tab.notifications.detail.border-flash.heading')}</span>
                        </label>
                    </div>
                </div>
                <div class="detail-field">
                    <label>${t('dynamic.character.borderColorsHeading')}</label>
                    <div class="detail-checks detail-color-rows">
                        <div class="color-row">
                            <span class="label-body">${t('tab.notifications.detail.text-color.heading')}</span>
                            <div class="notif-cell-inline">
                                <input type="checkbox" id="notif_${notifType.key}_textColorEnabled"
                                       title="${t('tab.notifications.detail.text-color.enableTitle')}"
                                       ${hasTextColor ? 'checked' : ''}
                                       onchange="toggleNotifTextColor('${notifType.key}')">
                                <div class="swatch-wrap">
                                    <input type="color" id="notif_${notifType.key}_textColor"
                                           value="${textColorHtml}"
                                           data-optional-color="true"
                                           data-default-color="${notifDefaultTextColorHtml()}"
                                           data-null-checkbox="notif_${notifType.key}_textColorEnabled"
                                           data-base-title="${t('tab.notifications.detail.text-color.activeTitle')}"
                                           ${!hasTextColor ? 'data-cleared="true"' : ''}
                                           title="${hasTextColor ? t('tab.notifications.detail.text-color.activeTitle') : t('tab.notifications.detail.text-color.notSetTitle')}"
                                           onchange="document.getElementById('notif_${notifType.key}_textColorEnabled').checked = true">
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="detail-checks detail-color-rows">
                        <div class="color-row">
                            <span class="label-body">${t('tab.notifications.detail.border-color.heading')}</span>
                            <div class="notif-cell-inline">
                                <input type="checkbox" id="notif_${notifType.key}_borderColorEnabled"
                                       title="${t('tab.notifications.detail.border-color.enableTitle')}"
                                       ${hasBorderColor ? 'checked' : ''}
                                       onchange="toggleNotifBorderColor('${notifType.key}')">
                                <div class="swatch-wrap">
                                    <input type="color" id="notif_${notifType.key}_borderColor"
                                           value="${borderColorHtml}"
                                           data-optional-color="true"
                                           data-default-color="${notifDefaultBorderColorHtml()}"
                                           data-null-checkbox="notif_${notifType.key}_borderColorEnabled"
                                           data-base-title="${t('tab.notifications.detail.border-color.activeTitle')}"
                                           ${!hasBorderColor ? 'data-cleared="true"' : ''}
                                           title="${hasBorderColor ? t('tab.notifications.detail.border-color.activeTitle') : t('tab.notifications.detail.border-color.notSetTitle')}"
                                           onchange="document.getElementById('notif_${notifType.key}_borderColorEnabled').checked = true">
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label>${t('tab.notifications.detail.sound.pathLabel')}</label>
                    <div class="field-row">
                        <input type="text" id="notif_${notifType.key}_soundPath" readonly
                               data-full-path="${config.sound_path || ''}"
                               value="${escapeHtml(soundFileBaseName(config.sound_path))}"
                               title="${config.sound_path || ''}"
                               placeholder="${t('tab.notifications.detail.sound.noFile')}">
                        <button type="button" class="btn-nowrap" id="notif_${notifType.key}_soundBrowseBtn" onclick="browseSoundFile('${notifType.key}')">${t('common.browse')}</button>
                        <button type="button" class="button-icon button-icon-danger" id="notif_${notifType.key}_soundClearBtn" onclick="clearSoundFile('${notifType.key}')" title="${t('tab.notifications.detail.sound.clear')}">&times;</button>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="field-row">
                        <label for="notif_${notifType.key}_soundVolume">${t('field.soundVolume.label')}</label>
                        <input type="range" id="notif_${notifType.key}_soundVolume" data-range="thumbnail.notifications.type_configs.*.sound_volume"
                               value="${config.sound_volume ?? 100}" data-value-target="notif_${notifType.key}_soundVolumeValue">
                        <span id="notif_${notifType.key}_soundVolumeValue">${config.sound_volume ?? 100}</span>
                    </div>
                </div>
            </div>
            <div class="button-row">
                <button type="button" id="notif_${notifType.key}_testBtn" onclick="testNotification('${notifType.key}')">${t('tab.notifications.detail.test.button')}</button>
            </div>
        </div>
    `;
    }).join('');

    container.innerHTML = `
        <div class="master-detail">
            <div class="roster" role="tablist" aria-orientation="vertical">${rosterRows}</div>
            <div class="detail-stack">${detailPanels}</div>
        </div>
    `;

    types.forEach((notifType) => toggleNotificationTypeEnabled(notifType.key));
    toggleNotificationOptions();
    applyNotificationTypeFilter();
    applySchemaToInputs(container);
}

export function selectNotificationType(index) {
    selectedNotificationTypeIndex = index;
    selectMasterDetailRow('notificationTypesList', index);
}

export function toggleNotificationTypeEnabled(typeKey) {
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
    const soundEnabledCheckbox = document.getElementById(`notif_${typeKey}_soundEnabled`);
    const soundPathInput = document.getElementById(`notif_${typeKey}_soundPath`);
    const soundBrowseBtn = document.getElementById(`notif_${typeKey}_soundBrowseBtn`);
    const soundClearBtn = document.getElementById(`notif_${typeKey}_soundClearBtn`);
    const soundVolumeInput = document.getElementById(`notif_${typeKey}_soundVolume`);
    const testBtn = document.getElementById(`notif_${typeKey}_testBtn`);

    const isEnabled = enabledCheckbox && enabledCheckbox.checked;

    if (testBtn) testBtn.disabled = !isEnabled;
    if (durationInput) durationInput.disabled = !isEnabled;
    if (suppressFocusedCheckbox) suppressFocusedCheckbox.disabled = !isEnabled;
    if (suppressClickedCheckbox) suppressClickedCheckbox.disabled = !isEnabled;
    if (throttleInput) throttleInput.disabled = !isEnabled;
    // TTS is self-contained too (no global master switch to also check).
    if (ttsCheckbox) ttsCheckbox.disabled = !isEnabled;
    if (showBorderCheckbox) showBorderCheckbox.disabled = !isEnabled;
    // Sound alert is self-contained as well.
    if (soundEnabledCheckbox) soundEnabledCheckbox.disabled = !isEnabled;
    // The checkbox only gates whether the alert fires for real - picking/clearing a file and setting its
    // volume are always allowed while the type is enabled, regardless of the checkbox (browseSoundFile() checks
    // it automatically once a file is set).
    if (soundPathInput) soundPathInput.disabled = !isEnabled;
    if (soundBrowseBtn) soundBrowseBtn.disabled = !isEnabled;
    if (soundClearBtn) soundClearBtn.disabled = !isEnabled;
    if (soundVolumeInput) soundVolumeInput.disabled = !isEnabled;
    // Text color isn't tied to the border - it renders whenever the notification is enabled, regardless of border visibility.
    if (textColorEnabledCheckbox) textColorEnabledCheckbox.disabled = !isEnabled;
    if (textColorInput) textColorInput.disabled = !isEnabled;
    // Border override/color/flash are further gated by Show Border: a hidden border has no color to set and nothing to flash.
    const showBorderChecked = !showBorderCheckbox || showBorderCheckbox.checked;
    if (borderColorEnabledCheckbox) borderColorEnabledCheckbox.disabled = !isEnabled || !showBorderChecked;
    if (borderColorInput) borderColorInput.disabled = !isEnabled || !showBorderChecked;
    if (flashBorderCheckbox) flashBorderCheckbox.disabled = !isEnabled || !showBorderChecked;
}

export function toggleNotifShowBorder(typeKey) {
    toggleNotificationTypeEnabled(typeKey);
}

export function toggleNotifSoundEnabled(typeKey) {
    toggleNotificationTypeEnabled(typeKey);
}

// Keeps the swatch's cleared indicator/tooltip in sync when the checkbox is toggled directly instead of via the picker's "Clear to Default" button.
export function toggleNotifBorderColor(typeKey) {
    syncNotifSwatchClearedState(`notif_${typeKey}_borderColorEnabled`, `notif_${typeKey}_borderColor`);
}

export function toggleNotifTextColor(typeKey) {
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
        input.title = t('tab.notifications.detail.notSetInheritingDefaultColor');
    }
}

export async function browseSoundFile(typeKey) {
    try {
        if (typeof webui === 'undefined') {
            logWarn('WebUI not available for browsing sound file');
            return;
        }
        const result = await rpc('browseSoundFile');
        if (result) {
            const input = document.getElementById(`notif_${typeKey}_soundPath`);
            if (input) {
                input.value = soundFileBaseName(result);
                input.title = result;
                input.dataset.fullPath = result;
            }
            const enabledCheckbox = document.getElementById(`notif_${typeKey}_soundEnabled`);
            if (enabledCheckbox) enabledCheckbox.checked = true;
            toggleNotificationTypeEnabled(typeKey);
        }
    } catch (error) {
        logError('Failed to browse sound file:', error);
    }
}

export function clearSoundFile(typeKey) {
    const input = document.getElementById(`notif_${typeKey}_soundPath`);
    if (input) {
        input.value = '';
        input.title = '';
        input.dataset.fullPath = '';
    }
}

// Null if the type's panel isn't rendered.
function readNotificationTypeConfig(typeKey) {
    const enabled = document.getElementById(`notif_${typeKey}_enabled`);
    if (!enabled) return null;

    const duration = document.getElementById(`notif_${typeKey}_duration`);
    const suppressFocused = document.getElementById(`notif_${typeKey}_suppressFocused`);
    const suppressClicked = document.getElementById(`notif_${typeKey}_suppressClicked`);
    const throttle = document.getElementById(`notif_${typeKey}_throttle`);
    const ttsTypeEnabled = document.getElementById(`notif_${typeKey}_tts`);
    const soundTypeEnabled = document.getElementById(`notif_${typeKey}_soundEnabled`);
    const soundPath = document.getElementById(`notif_${typeKey}_soundPath`);
    const soundVolume = document.getElementById(`notif_${typeKey}_soundVolume`);
    const showBorder = document.getElementById(`notif_${typeKey}_showBorder`);
    const flashBorder = document.getElementById(`notif_${typeKey}_flashBorder`);
    const borderColorEnabled = document.getElementById(`notif_${typeKey}_borderColorEnabled`);
    const borderColorInput = document.getElementById(`notif_${typeKey}_borderColor`);
    const textColorEnabled = document.getElementById(`notif_${typeKey}_textColorEnabled`);
    const textColorInput = document.getElementById(`notif_${typeKey}_textColor`);

    const durationValue = duration && duration.value ? parseFloat(duration.value) * 1000 : 5000;
    const throttleValue = throttle && throttle.value ? parseFloat(throttle.value) * 1000 : 0;

    return {
        enabled: enabled.checked,
        duration_ms: Math.round(durationValue),
        suppress_when_focused: suppressFocused ? suppressFocused.checked : false,
        suppress_when_clicked: suppressClicked ? suppressClicked.checked : false,
        throttle_ms: Math.round(throttleValue),
        tts_enabled: ttsTypeEnabled ? ttsTypeEnabled.checked : false,
        sound_enabled: soundTypeEnabled ? soundTypeEnabled.checked : false,
        sound_path: soundPath && soundPath.dataset.fullPath ? soundPath.dataset.fullPath : null,
        sound_volume: soundVolume ? parseInt(soundVolume.value, 10) : 100,
        show_border: showBorder ? showBorder.checked : false,
        flash_border: flashBorder ? flashBorder.checked : false,
        // null = use Alert state color; the override checkbox opts in.
        border_color: (borderColorEnabled && borderColorEnabled.checked && borderColorInput && borderColorInput.value)
            ? htmlColorToZig(borderColorInput.value)
            : null,
        // null = use default text color.
        text_color: (textColorEnabled && textColorEnabled.checked && textColorInput && textColorInput.value)
            ? htmlColorToZig(textColorInput.value)
            : null,
    };
}

export function saveNotificationTypes() {
    if (!app.currentConfig.thumbnail) app.currentConfig.thumbnail = {};
    if (!app.currentConfig.thumbnail.notifications) app.currentConfig.thumbnail.notifications = {};
    if (!app.currentConfig.thumbnail.notifications.type_configs) {
        app.currentConfig.thumbnail.notifications.type_configs = {};
    }

    const typeConfigs = app.currentConfig.thumbnail.notifications.type_configs;

    notificationTypes().forEach((notifType) => {
        const fromForm = readNotificationTypeConfig(notifType.key);
        if (!fromForm) return;
        typeConfigs[notifType.key] = Object.assign(typeConfigs[notifType.key] || {}, fromForm);
    });
}

export async function testNotification(typeKey) {
    if (typeof webui === 'undefined' || !app.webuiReady) {
        logWarn('WebUI not available for testing notification');
        return;
    }
    try {
        // The app tests with the settings it holds, so the form's latest edits go first.
        await flushEdits();
        await rpc('testNotification', { type: typeKey });
    } catch (error) {
        logError('Failed to test notification:', error);
        showStatus(t('status.testNotificationFailedPrefix') + error.message, 'error');
    }
}
