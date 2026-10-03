// Per-type notification settings, sounds and the Test button.
import { app } from './state.js';
import { applyDocToForm, applySchemaToInputs, baseName, defaultFor, readFormToDoc } from './binding.js';
import { zigColorToHtml } from './colors.js';
import { escapeHtml, logError, logWarn, rpc } from './core.js';
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

// Where a placeholder chip inserts, per type; falls back to the type's first box.
const lastFocusedTextBox = new Map();

const CUSTOM_TEXT_MAX_LENGTH = 100;

const notificationTypeSearchFilter = makeRosterSearchFilter('notificationTypesList');
export function onNotificationTypeSearchInput(query) { notificationTypeSearchFilter.onInput(query); }
export function clearNotificationTypeSearch() { notificationTypeSearchFilter.clear('notificationTypeSearchFilter'); }
function applyNotificationTypeFilter() { notificationTypeSearchFilter.apply(); }

export function populateNotificationTypes() {
    const container = document.getElementById('notificationTypesList');
    if (!container) return;

    const types = notificationTypes();

    if (selectedNotificationTypeIndex >= types.length) selectedNotificationTypeIndex = types.length - 1;
    if (selectedNotificationTypeIndex < 0) selectedNotificationTypeIndex = 0;

    const rosterRows = types.map((notifType, index) => {
        // The short name keeps the roster narrow; the header and tooltip use the full one.
        const eventLabel = t('notification.' + notifType.key + '.label');
        const shortLabel = t('notification.' + notifType.key + '.shortLabel');

        return `
            <div class="roster-row ${index === selectedNotificationTypeIndex ? 'selected' : ''}" role="tab" tabindex="0" aria-selected="${index === selectedNotificationTypeIndex}" data-index="${index}" onclick="selectNotificationType(${index})">
                <span class="roster-name" title="${eventLabel}">${shortLabel}</span>
            </div>
        `;
    }).join('');

    const detailPanels = types.map((notifType, index) => `
        <div class="detail-panel ${index === selectedNotificationTypeIndex ? 'active' : ''}" data-index="${index}">
            <div class="detail-panel-header">
                <span class="detail-panel-name-label">${t('notification.' + notifType.key + '.label')}</span>
            </div>
            <div class="detail-form">
                <div class="detail-field detail-field-top">
                    <label>${t('tab.notifications.table.notification.heading')}</label>
                    <div class="detail-checks">
                        <label title="${t('tab.notifications.table.enabled.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_enabled" data-path="thumbnail.notifications.type_configs.${notifType.key}.enabled"
                                   onchange="toggleNotificationTypeEnabled('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.enabled.heading')}</span>
                        </label>
                        <div class="field-row">
                            <label for="notif_${notifType.key}_duration" title="${t('tab.notifications.table.duration.title')}">${t('tab.notifications.table.duration.heading')}</label>
                            <input type="number" class="detail-number-input" id="notif_${notifType.key}_duration" data-path="thumbnail.notifications.type_configs.${notifType.key}.duration_ms" data-unit="s" step="0.1">
                        </div>
                        <p class="hint hint-extra">${t('tab.notifications.detail.duration.hint')}</p>
                        <div class="field-row">
                            <label for="notif_${notifType.key}_throttle" title="${t('tab.notifications.table.throttle.title')}">${t('tab.notifications.table.throttle.heading')}</label>
                            <input type="number" class="detail-number-input" id="notif_${notifType.key}_throttle" data-path="thumbnail.notifications.type_configs.${notifType.key}.throttle_ms" data-unit="s" step="1"
                                   title="${t('tab.notifications.table.throttle.title')}">
                        </div>
                        <p class="hint hint-extra">${t('tab.notifications.detail.throttle.hint')}</p>
                    </div>
                </div>
                ${customTextField(notifType)}
                <div class="detail-field detail-field-top">
                    <label>${t('dynamic.character.behaviorHeading')}</label>
                    <div class="detail-checks">
                        <label title="${t('tab.notifications.table.suppress-focused.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_suppressFocused" data-path="thumbnail.notifications.type_configs.${notifType.key}.suppress_when_focused">
                            <span class="label-body">${t('tab.notifications.detail.suppress-focused.heading')}</span>
                        </label>
                        <p class="hint hint-extra">${t('tab.notifications.detail.suppress-focused.hint')}</p>
                        <label title="${t('tab.notifications.table.suppress-clicked.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_suppressClicked" data-path="thumbnail.notifications.type_configs.${notifType.key}.suppress_when_clicked">
                            <span class="label-body">${t('tab.notifications.detail.suppress-clicked.heading')}</span>
                        </label>
                        <p class="hint hint-extra">${t('tab.notifications.detail.suppress-clicked.hint')}</p>
                        <label title="${t('tab.notifications.table.speech.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_tts" data-path="thumbnail.notifications.type_configs.${notifType.key}.tts_enabled">
                            <span class="label-body">${t('tab.notifications.detail.speech.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.sound.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_soundEnabled" data-path="thumbnail.notifications.type_configs.${notifType.key}.sound_enabled"
                                   onchange="toggleNotifSoundEnabled('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.sound.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.border-show.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_showBorder" data-path="thumbnail.notifications.type_configs.${notifType.key}.show_border"
                                   onchange="toggleNotifShowBorder('${notifType.key}')">
                            <span class="label-body">${t('tab.notifications.detail.border-show.heading')}</span>
                        </label>
                        <label title="${t('tab.notifications.table.border-flash.title')}">
                            <input type="checkbox" id="notif_${notifType.key}_flashBorder" data-path="thumbnail.notifications.type_configs.${notifType.key}.flash_border">
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
                                       onchange="toggleNotifTextColor('${notifType.key}')">
                                <div class="swatch-wrap">
                                    <input type="color" id="notif_${notifType.key}_textColor" data-path="thumbnail.notifications.type_configs.${notifType.key}.text_color"
                                           data-optional-color="true"
                                           data-default-color="${notifDefaultTextColorHtml()}"
                                           data-null-checkbox="notif_${notifType.key}_textColorEnabled"
                                           data-base-title="${t('tab.notifications.detail.text-color.activeTitle')}"
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
                                       onchange="toggleNotifBorderColor('${notifType.key}')">
                                <div class="swatch-wrap">
                                    <input type="color" id="notif_${notifType.key}_borderColor" data-path="thumbnail.notifications.type_configs.${notifType.key}.border_color"
                                           data-optional-color="true"
                                           data-default-color="${notifDefaultBorderColorHtml()}"
                                           data-null-checkbox="notif_${notifType.key}_borderColorEnabled"
                                           data-base-title="${t('tab.notifications.detail.border-color.activeTitle')}"
                                           onchange="document.getElementById('notif_${notifType.key}_borderColorEnabled').checked = true">
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="detail-field">
                    <label>${t('tab.notifications.detail.sound.pathLabel')}</label>
                    <div class="field-row">
                        <input type="text" id="notif_${notifType.key}_soundPath" readonly data-path="thumbnail.notifications.type_configs.${notifType.key}.sound_path" data-format="path"
                               placeholder="${t('tab.notifications.detail.sound.noFile')}">
                        <button type="button" class="btn-nowrap" id="notif_${notifType.key}_soundBrowseBtn" onclick="browseSoundFile('${notifType.key}')">${t('common.browse')}</button>
                        <button type="button" class="button-icon button-icon-danger" id="notif_${notifType.key}_soundClearBtn" onclick="clearSoundFile('${notifType.key}')" title="${t('tab.notifications.detail.sound.clear')}">&times;</button>
                    </div>
                </div>
                <div class="detail-field">
                    <label></label>
                    <div class="field-row">
                        <label for="notif_${notifType.key}_soundVolume">${t('field.soundVolume.label')}</label>
                        <input type="range" id="notif_${notifType.key}_soundVolume" data-path="thumbnail.notifications.type_configs.${notifType.key}.sound_volume" data-value-target="notif_${notifType.key}_soundVolumeValue">
                        <span id="notif_${notifType.key}_soundVolumeValue"></span>
                    </div>
                </div>
            </div>
            <div class="button-row">
                <button type="button" id="notif_${notifType.key}_testBtn" onclick="testNotification('${notifType.key}')">${t('tab.notifications.detail.test.button')}</button>
            </div>
        </div>
    `).join('');

    container.innerHTML = `
        <div class="master-detail">
            <div class="roster" role="tablist" aria-orientation="vertical">${rosterRows}</div>
            <div class="detail-stack">${detailPanels}</div>
        </div>
    `;

    applySchemaToInputs(container);
    applyDocToForm(path => path.startsWith('thumbnail.notifications.type_configs.'), container);
    container.querySelectorAll('.notif-custom-text').forEach(updateNotifTextPreview);
    types.forEach((notifType) => {
        toggleNotifTextColor(notifType.key);
        toggleNotifBorderColor(notifType.key);
        toggleNotificationTypeEnabled(notifType.key);
    });
    toggleNotificationOptions();
    applyNotificationTypeFilter();
}

// The first box gets its own grid row so the rail label centers on it, not the whole stack.
function customTextField(notifType) {
    const texts = notifType.texts || [];
    const boxes = texts.map(text => {
        const id = `notif_${notifType.key}_${text.field}`;
        const stateLabel = texts.length > 1 ? `<label for="${id}">${t('notification.state.' + text.state + '.label')}</label>` : '';
        return {
            row: `
                <div class="field-row">
                    ${stateLabel}
                    <input type="text" id="${id}" class="notif-custom-text" maxlength="${CUSTOM_TEXT_MAX_LENGTH}" data-type-key="${notifType.key}"
                           data-path="thumbnail.notifications.type_configs.${notifType.key}.${text.field}"
                           placeholder="${escapeHtml(text.defaultText)}"
                           oninput="updateNotifTextPreview(this)" onfocus="rememberNotifTextBox(this)">
                    <button type="button" class="button-icon button-icon-danger notif-custom-text-clear" data-type-key="${notifType.key}"
                            onclick="clearNotifCustomText('${id}')" title="${t('tab.notifications.detail.text.clear')}">&times;</button>
                </div>`,
            preview: `<p class="hint notif-text-preview" id="${id}_preview"></p>`,
        };
    });
    const [first, ...rest] = boxes;
    const chips = (notifType.placeholders || []).map(placeholder => `
        <button type="button" class="placeholder-chip" title="${escapeHtml(t('notification.placeholder.' + placeholder.name + '.title'))}"
                onclick="insertNotifPlaceholder('${notifType.key}', '${placeholder.name}')">{${placeholder.name}}</button>`).join('');
    return `
        <div class="detail-field">
            <label>${t('tab.notifications.detail.text.heading')}</label>
            ${first?.row ?? ''}
        </div>
        <div class="detail-field">
            <label></label>
            <div class="detail-checks">
                ${rest.map(box => box.row).join('')}
                ${chips ? `<div class="placeholder-chips" id="notif_${notifType.key}_placeholders">${chips}</div>` : ''}
                ${boxes.map(box => box.preview).join('')}
                <p class="hint hint-extra">${t('tab.notifications.detail.text.hint')}</p>
            </div>
        </div>`;
}

export function clearNotifCustomText(inputId) {
    const input = document.getElementById(inputId);
    if (!input || input.value === '') return;
    input.value = '';
    // Programmatic edits don't fire input.
    input.dispatchEvent(new Event('input', { bubbles: true }));
}

export function rememberNotifTextBox(input) {
    lastFocusedTextBox.set(input.dataset.typeKey, input);
}

export function insertNotifPlaceholder(typeKey, name) {
    const input = lastFocusedTextBox.get(typeKey)?.isConnected ? lastFocusedTextBox.get(typeKey)
        : document.querySelector(`.notif-custom-text[data-type-key="${typeKey}"]`);
    if (!input || input.disabled) return;

    const token = `{${name}}`;
    const start = input.selectionStart ?? input.value.length;
    const end = input.selectionEnd ?? start;
    if (input.value.length - (end - start) + token.length > CUSTOM_TEXT_MAX_LENGTH) return;
    input.setRangeText(token, start, end, 'end');
    input.focus();
    // Programmatic edits don't fire input.
    input.dispatchEvent(new Event('input', { bubbles: true }));
}

// Mirrors notifications/template.zig's render, using each placeholder's sample value.
export function updateNotifTextPreview(input) {
    const preview = document.getElementById(`${input.id}_preview`);
    if (!preview) return;
    const text = input.value.trim();
    if (text === '') {
        preview.textContent = t('tab.notifications.detail.text.preview') + ' ' + input.placeholder;
        return;
    }
    const placeholders = notificationTypes().find(type => type.key === input.dataset.typeKey)?.placeholders || [];
    const rendered = text.replace(/\{([^{}]*)\}/g, (match, name) => {
        const placeholder = placeholders.find(p => p.name.toLowerCase() === name.toLowerCase());
        return placeholder?.sample ?? match;
    });
    preview.textContent = t('tab.notifications.detail.text.preview') + ' ' + rendered;
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
    const customTextInputs = document.querySelectorAll(`.notif-custom-text[data-type-key="${typeKey}"], .notif-custom-text-clear[data-type-key="${typeKey}"], #notif_${typeKey}_placeholders button`);

    const isEnabled = enabledCheckbox && enabledCheckbox.checked;

    customTextInputs.forEach(el => { el.disabled = !isEnabled; });

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
                input.value = baseName(result);
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
export function saveNotificationTypes() {
    readFormToDoc(path => path.startsWith('thumbnail.notifications.type_configs.'));
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
