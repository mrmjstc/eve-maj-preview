// The import dialog. The app recognises and reads the file (EVE-X, EVE-APM, EVE-O or another EVE-Maj profile, see config/import/) and applies the chosen sections as unsaved edits.
import { hasUnsavedChanges } from './changes.js';
import { applyAccentColorTheme, defaultAccentColorHtml, htmlColorToZig } from './colors.js';
import { escapeHtml, logError, rpc } from './core.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';
import { cleanProfileName, loadImportBackupsList, switchProfile } from './profiles.js';
import { flushEdits, reloadSession, saveConfiguration } from './session.js';

const DETECTED_STATUS = {
    maj: 'status.detectedMajFile',
    evex: 'status.detectedEvexFile',
    eveo: 'status.detectedEveoFile',
    apm: 'status.detectedApmFile',
};

// The file as read, and what the app found in it.
let importText = null;
let importFileName = '';
let importAnalysis = null;

// Live-previews the import modal's accent color pick the same way showProfileNameModal does.
export function initImportAccentColorPreview() {
    const input = document.getElementById('importAccentColor');
    if (input) input.addEventListener('input', () => applyAccentColorTheme(htmlColorToZig(input.value)));
}

// A translation key and its parameters from the app, some of which are keys of their own.
function translate(text) {
    let out = t(text.key);
    for (const [name, value] of Object.entries(text.params || {})) {
        out = out.replaceAll(`{${name}}`, typeof value === 'object' ? t(value.t) : value);
    }
    return out;
}

function renderImportSections() {
    const container = document.getElementById('importSectionsList');
    if (!container) return;
    const sections = importAnalysis?.sections || [];
    container.innerHTML = sections.map(s => `
        <label class="import-section-item" title="${escapeHtml(s.available ? translate(s.hint) : t('dynamic.import.nothingToImportHint'))}">
            <input type="checkbox" id="import_${s.id}" data-section="${s.id}" ${s.available ? 'checked' : 'disabled'}>
            <span class="label-body">${escapeHtml(t(s.title))}</span>
        </label>
    `).join('');
}

function chosenSections() {
    return Array.from(document.querySelectorAll('#importSectionsList input[data-section]'))
        .filter(input => input.checked && !input.disabled)
        .map(input => input.dataset.section);
}

export function openImportModal() {
    importText = null;
    importAnalysis = null;

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

    loadImportBackupsList();

    const modal = document.getElementById('import-settings-modal');
    modal.classList.add('show');
}

export function closeImportModal() {
    const modal = document.getElementById('import-settings-modal');
    modal.classList.remove('show');
    applyAccentColorTheme();
}

export async function handleImportFileSelected(event) {
    const file = event.target.files && event.target.files[0];
    const statusEl = document.getElementById('importFileStatus');
    const optionsStep = document.getElementById('import-step-options');
    const runBtn = document.getElementById('import-modal-run');

    optionsStep.style.display = 'none';
    runBtn.disabled = true;
    importText = null;
    importAnalysis = null;

    if (!file) {
        statusEl.textContent = '';
        return;
    }

    statusEl.textContent = t('status.readingFile');

    try {
        importText = await file.text();
        importFileName = file.name;
        importAnalysis = await rpc('analyzeImport', { text: importText, fileName: importFileName });
        if (!importAnalysis.format) {
            statusEl.textContent = t('status.unrecognizedSettingsFile');
            importText = null;
            return;
        }

        const profiles = importAnalysis.profiles || [];
        const select = document.getElementById('importSourceProfile');
        select.replaceChildren(...profiles.map(name => new Option(name, name)));
        if (importAnalysis.sourceProfile) select.value = importAnalysis.sourceProfile;
        document.getElementById('importSourceProfileRow').style.display = profiles.length > 1 ? '' : 'none';
        document.getElementById('importNewProfileName').value = importAnalysis.defaultName;
        statusEl.textContent = t(DETECTED_STATUS[importAnalysis.format]).replace('{n}', profiles.length);

        renderImportSections();
        optionsStep.style.display = '';
        runBtn.disabled = false;
        onImportDestChanged();
    } catch (err) {
        logError('Failed to read the settings file:', err);
        importText = null;
        importAnalysis = null;
        statusEl.textContent = t('status.readParseFailedPrefix') + err.message;
    }
}

// An EVE-X file holds several profiles, each with its own sections.
export async function onImportSourceProfileChanged() {
    if (importAnalysis?.format !== 'evex') return;
    const sourceProfile = document.getElementById('importSourceProfile').value;
    try {
        importAnalysis = await rpc('analyzeImport', { text: importText, fileName: importFileName, sourceProfile });
        document.getElementById('importNewProfileName').value = importAnalysis.defaultName;
        renderImportSections();
    } catch (err) {
        logError('Failed to read the chosen profile:', err);
    }
}

export function onImportDestChanged() {
    const isNew = document.getElementById('import-dest-new').checked;
    document.getElementById('importNewProfileRow').style.display = isNew ? '' : 'none';
    if (isNew) {
        document.getElementById('importAccentColor').value = defaultAccentColorHtml();
        applyAccentColorTheme(htmlColorToZig(defaultAccentColorHtml()));
    } else {
        applyAccentColorTheme();
    }

    const profileSelect = document.getElementById('profile-select');
    const currentLabel = document.getElementById('importDestCurrentLabel');
    if (currentLabel && profileSelect && profileSelect.value) {
        currentLabel.textContent = t('status.currentProfilePrefix') + profileSelect.value.replace(/\.json$/, '') + ')';
    }
}

export async function runImport() {
    if (!importText || !importAnalysis) return;

    const runBtn = document.getElementById('import-modal-run');
    runBtn.disabled = true;

    // A brand-new profile only auto-saves if "Live" was picked; otherwise it stays a draft for review, which doesn't preview.
    let autoSaveAfterImport = false;

    try {
        if (document.getElementById('import-dest-new').checked) {
            const name = cleanProfileName(document.getElementById('importNewProfileName').value);
            if (name === '') {
                showStatus(t('status.invalidNewProfileName'), 'error');
                runBtn.disabled = false;
                return;
            }

            const accentColorInput = document.getElementById('importAccentColor');
            const accentColor = accentColorInput ? htmlColorToZig(accentColorInput.value) : '';
            try {
                await rpc('createProfile', { name, accentColor });
            } catch (error) {
                showStatus(t('status.createProfileFailedPrefix') + error.message, 'error');
                runBtn.disabled = false;
                return;
            }

            const switchChoice = await switchProfile(true, false, name + '.json');
            if (switchChoice === 'cancel') {
                // The window still edits the old profile, which importing now would write into instead.
                runBtn.disabled = false;
                return;
            }
            autoSaveAfterImport = switchChoice === 'live';
        }

        // The app merges into its own copy, so the form's latest edits go first.
        await flushEdits();
        const { notes, skipped } = await rpc('applyImport', {
            text: importText,
            sourceProfile: importAnalysis.sourceProfile ?? null,
            sections: chosenSections(),
            cycleGroupName: t('dynamic.import.eveo.cycleGroupName'),
        });
        await reloadSession();
        if (autoSaveAfterImport) await saveConfiguration();

        const hint = autoSaveAfterImport && !hasUnsavedChanges()
            ? t('dynamic.import.liveNowHint')
            : t('dynamic.import.reviewAndSaveHint');
        const summaryEl = document.getElementById('importSummary');
        // Apart from the notes, so settings left unchanged don't read like ones that came in.
        const skippedBlock = skipped.length === 0 ? '' :
            '<div class="import-skipped">' +
            `<p>${escapeHtml(translate({ key: 'dynamic.import.skippedHeading', params: { n: String(skipped.length) } }))}</p>` +
            `<ul>${skipped.map(path => `<li><code>${escapeHtml(path)}</code></li>`).join('')}</ul>` +
            '</div>';
        summaryEl.innerHTML = `<p class="hint" style="margin: 0 0 0.5rem 0;">${escapeHtml(t('dynamic.import.completeHeading'))}</p>` +
            skippedBlock +
            '<ul style="margin: 0; padding-left: 1.125rem;">' +
            notes.map(n => `<li>${escapeHtml(translate(n))}</li>`).join('') +
            '</ul>' +
            `<p class="hint" style="margin-top: 0.5rem;">${hint}</p>`;
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
