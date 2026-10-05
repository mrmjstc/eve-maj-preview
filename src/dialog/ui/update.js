// The update-available notice and external links.
import { app } from './state.js';
import { logError, rpc } from './core.js';

// The app's update check is a background HTTP request that may still be in flight on the first call.
const UPDATE_STATUS_RETRY_DELAY_MS = 4000;

export async function checkForUpdateNotification(isRetry) {
    if (app.currentGlobalSettings && app.currentGlobalSettings.disableUpdateChecks) return;

    try {
        if (typeof eveRpc === 'undefined') return;
        const status = await rpc('getUpdateStatus');
        if (status.available) {
            showUpdateAvailableModal(status.version, status.url, status.notes);
        } else if (!isRetry) {
            setTimeout(() => checkForUpdateNotification(true), UPDATE_STATUS_RETRY_DELAY_MS);
        }
    } catch (error) {
        logError('Failed to check update status:', error);
    }
}

function showUpdateAvailableModal(version, url, notes) {
    const modal = document.getElementById('update-available-modal');
    const linkEl = document.getElementById('update-available-link');
    const notesEl = document.getElementById('update-available-notes');
    const closeBtn = document.getElementById('update-available-modal-close');

    linkEl.href = url;
    linkEl.textContent = version || url;

    if (notes) {
        notesEl.textContent = notes;
        notesEl.style.display = '';
    } else {
        notesEl.textContent = '';
        notesEl.style.display = 'none';
    }

    modal.classList.add('show');

    const handleClose = () => {
        modal.classList.remove('show');
        closeBtn.removeEventListener('click', handleClose);
    };

    closeBtn.addEventListener('click', handleClose);
}

// Opens in the OS default browser via the backend instead of letting the WebView2 host spawn a popup for a plain target="_blank" link.
export function openExternalLink(event) {
    event.preventDefault();
    if (typeof eveRpc !== 'undefined') {
        rpc('openUrlInBrowser', { url: event.currentTarget.href })
            .catch(error => logError('Failed to open release URL:', error));
    }
    return false;
}
