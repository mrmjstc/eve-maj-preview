// Ultra Potato Mode: patching EVE's own graphics settings files.
import { escapeHtml, logError, rpc } from './core.js';
import { t } from './i18n.js';
import { showStatus } from './layout.js';

// Populates the Ultra Potato Mode dropdown with EVE's core_public__.yaml settings profiles found on disk, plus an "All Profiles" entry when there's more than one.
export async function scanUltraPotatoProfiles() {
    const select = document.getElementById('ultraPotatoProfileSelect');
    const applyBtn = document.getElementById('applyUltraPotatoBtn');
    if (!select || typeof webui === 'undefined') return;

    select.innerHTML = `<option value="">${escapeHtml(t('tab.behavior.section.ultra-potato.scanning'))}</option>`;
    select.disabled = true;
    if (applyBtn) applyBtn.disabled = true;

    try {
        const profiles = await rpc('scanUltraPotatoProfiles');

        if (profiles.length === 0) {
            select.innerHTML = `<option value="">${escapeHtml(t('tab.behavior.section.ultra-potato.none-found'))}</option>`;
            return;
        }

        select.dataset.profiles = JSON.stringify(profiles);
        const allOption = profiles.length > 1
            ? `<option value="__all__">${escapeHtml(t('tab.behavior.section.ultra-potato.all-profiles'))}</option>`
            : '';
        select.innerHTML = allOption + profiles.map(p => `<option value="${escapeHtml(p.path)}">${escapeHtml(p.label)}</option>`).join('');
        select.disabled = false;
        if (applyBtn) applyBtn.disabled = false;
    } catch (error) {
        logError('Failed to scan EVE settings profiles:', error);
        select.innerHTML = `<option value="">${escapeHtml(t('tab.behavior.section.ultra-potato.scan-failed'))}</option>`;
    }
}

// Patches the selected profile(s)' core_public__.yaml on disk via the Zig backend, reporting through the same status bar saveConfiguration() uses.
export async function applyUltraPotatoMode() {
    const select = document.getElementById('ultraPotatoProfileSelect');
    if (!select || typeof webui === 'undefined') return;

    const selected = select.value;
    if (!selected) return;

    const paths = selected === '__all__'
        ? JSON.parse(select.dataset.profiles || '[]').map(p => p.path)
        : [selected];
    if (paths.length === 0) return;

    const btn = document.getElementById('applyUltraPotatoBtn');
    if (btn) btn.disabled = true;
    showStatus(t('status.ultraPotatoApplying'), 'info');

    try {
        const data = await rpc('applyUltraPotatoMode', { paths });

        const changed = data.results.filter(r => r.ok && r.changed).length;
        const alreadySet = data.results.filter(r => r.ok && !r.changed).length;
        const failed = data.results.filter(r => !r.ok);

        if (failed.length > 0) {
            const summary = t('status.ultraPotatoPartialFailurePrefix')
                .replace('{n}', String(changed + alreadySet))
                .replace('{total}', String(data.results.length));
            const details = failed.map(r => `${r.path} (${r.error || t('status.unknownError')})`).join(', ');
            showStatus(summary + ' ' + details, 'error');
            return;
        }

        let message;
        if (changed > 0 && alreadySet > 0) {
            message = t('status.ultraPotatoAppliedAndAlreadySet').replace('{n}', String(changed)).replace('{m}', String(alreadySet));
        } else if (changed > 0) {
            message = t('status.ultraPotatoApplied').replace('{n}', String(changed));
        } else {
            message = t('status.ultraPotatoAlreadySet').replace('{n}', String(alreadySet));
        }
        showStatus(message, 'success');
    } catch (error) {
        logError('Failed to apply Ultra Potato Mode:', error);
        showStatus(t('status.ultraPotatoFailedPrefix') + error.message, 'error');
    } finally {
        if (btn) btn.disabled = false;
    }
}
