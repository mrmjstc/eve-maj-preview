// Profile list, switching, creating, copying, deleting, resetting and restoring backups.
import { app } from './state.js';
import { applyAccentColorTheme, defaultAccentColorHtml, htmlColorToZig, zigColorToHtml } from './colors.js';
import { logError, rpc } from './core.js';
import { t } from './i18n.js';
import { closeImportModal } from './import.js';
import { showStatus } from './layout.js';
import { openSession } from './session.js';
import { confirmRemove } from './widgets.js';

// Backup filenames are "<unixSeconds>_<originalFilename>.json", stamped by deleteProfile().
function parseBackupFilename(filename) {
    const match = filename.match(/^(\d+)_(.+)\.json$/);
    if (!match) return { displayName: filename.replace(/\.json$/, ''), dateLabel: '' };
    return {
        displayName: match[2],
        dateLabel: new Date(parseInt(match[1], 10) * 1000).toLocaleString(),
    };
}

export async function loadImportBackupsList() {
    const section = document.getElementById('importBackupsSection');
    const select = document.getElementById('importBackupSelect');
    if (!section || !select) return;

    if (typeof webui === 'undefined') {
        section.style.display = 'none';
        return;
    }

    try {
        const { backups } = await rpc('listProfileBackups');

        if (backups.length === 0) {
            section.style.display = 'none';
            select.innerHTML = '';
            return;
        }

        select.innerHTML = '';
        backups.forEach(filename => {
            const { displayName, dateLabel } = parseBackupFilename(filename);
            const opt = document.createElement('option');
            opt.value = filename;
            opt.textContent = dateLabel ? `${displayName} — ${dateLabel}` : displayName;
            select.appendChild(opt);
        });
        section.style.display = '';
    } catch (err) {
        logError('Failed to load profile backups:', err);
        section.style.display = 'none';
    }
}

export function restoreSelectedProfileBackup() {
    const select = document.getElementById('importBackupSelect');
    if (!select || !select.value) return;
    const { displayName } = parseBackupFilename(select.value);
    restoreProfileBackup(select.value, displayName);
}

async function restoreProfileBackup(filename, displayName) {
    const restoreResult = await showProfileNameModal(t('dynamic.profile.restoreModalTitle').replace('{name}', displayName), displayName);
    if (!restoreResult) return;
    const { name: newName, color: accentColor } = restoreResult;

    const sanitizedName = cleanProfileName(newName);
    if (sanitizedName === '') {
        showStatus(t('status.invalidProfileName'), 'error');
        return;
    }

    showStatus(t('status.restoringProfile'), 'info');

    try {
        if (typeof webui !== 'undefined') {
            await rpc('restoreProfileBackup', { backup: filename, target: sanitizedName, accentColor: htmlColorToZig(accentColor) });
            showStatus(t('status.profileRestoredSuccess'), 'success');
            closeImportModal();
            await switchProfile(false, false, sanitizedName + '.json');
        } else {
            showStatus(t('status.mockCopyPrefix') + filename + t('status.mockCopyMiddle') + sanitizedName, 'info');
        }
    } catch (error) {
        logError('Failed to restore profile backup:', error);
        showStatus(t('status.restoreProfileFailedPrefix') + error.message, 'error');
    }
}

// The characters and length the app accepts in a profile name (see validateName in config/profiles.zig).
export function cleanProfileName(name) {
    return name.trim().replace(/[^a-zA-Z0-9_\-\s]/g, '').slice(0, app.schema.profileNameMaxLength);
}

// From the profiles the session listed, with the one the window edits selected.
export function renderProfileSelect() {
    const profileSelect = document.getElementById('profile-select');
    const profiles = app.profiles.length > 0 ? app.profiles : ['default.json'];
    profileSelect.replaceChildren(...profiles.map(profile => new Option(profile.replace(/\.json$/, ''), profile)));
    profileSelect.value = app.dialogEditingProfile;
}

// deferLivePush skips the immediate switchProfileLive call for a profile runImport() just created (still empty) - runImport() does the actual live push once it has real data to save.
// `target` is a profile just created, which the dropdown doesn't list until the session reopens.
export async function switchProfile(deferLivePush = false, forceLive = false, target = null) {
    const profileSelect = document.getElementById('profile-select');
    const selectedProfile = target ?? profileSelect.value;
    let liveChoice = null;

    // Ask before making it live, since that means an immediate thumbnail/hotkey/chatlog reload in the running app.
    if (app.dialogEditingProfile && selectedProfile !== app.dialogEditingProfile) {
        const choice = forceLive ? 'live' : await showLiveSwitchModal(selectedProfile);
        liveChoice = choice;
        if (choice === 'cancel') {
            profileSelect.value = app.dialogEditingProfile;
            return choice;
        }
        if (choice === 'live' && !deferLivePush) {
            try {
                if (typeof webui !== 'undefined') {
                    // The window follows the app onto it, and the profileSwitched event reopens the session.
                    await rpc('switchProfileLive', { name: selectedProfile });
                    app.dialogEditingProfile = selectedProfile;
                    showStatus(t('status.profileSwitchedSuccess'), 'success');
                    return liveChoice;
                }
            } catch (error) {
                logError('Failed to make profile live:', error);
                showStatus(t('status.makeProfileLiveFailedPrefix') + error.message, 'error');
            }
        }
        // choice === 'edit' -> the window edits a draft, which doesn't preview until it's saved.
    }

    showStatus(t('status.switchingToProfilePrefix') + selectedProfile.replace(/\.json$/, '') + '...', 'info');

    try {
        if (typeof webui !== 'undefined') {
            await rpc('switchProfile', { name: selectedProfile });
            app.dialogEditingProfile = selectedProfile;
            showStatus(t('status.profileSwitchedSuccess'), 'success');
            await openSession();
        } else {
            showStatus(t('status.mockSwitchPrefix') + selectedProfile, 'info');
        }
    } catch (error) {
        logError('Failed to switch profile:', error);
        showStatus(t('status.switchProfileFailedPrefix') + error.message, 'error');
    }

    return liveChoice;
}

function showLiveSwitchModal(selectedProfile) {
    return new Promise((resolve) => {
        const modal = document.getElementById('live-switch-modal');
        const message = document.getElementById('live-switch-message');
        const liveBtn = document.getElementById('live-switch-modal-live');
        const editBtn = document.getElementById('live-switch-modal-edit');
        const cancelBtn = document.getElementById('live-switch-modal-cancel');

        message.textContent = t('status.liveSwitchConfirm').replace('{name}', selectedProfile.replace(/\.json$/, ''));

        // All .modal elements share the same z-index, so DOM order decides who paints on top; re-parent to the end of <body> to stay above other open modals.
        document.body.appendChild(modal);
        modal.classList.add('show');

        const handle = (choice) => {
            cleanup();
            resolve(choice);
        };
        const handleLive = () => handle('live');
        const handleEdit = () => handle('edit');
        const handleCancel = () => handle('cancel');

        const cleanup = () => {
            modal.classList.remove('show');
            liveBtn.removeEventListener('click', handleLive);
            editBtn.removeEventListener('click', handleEdit);
            cancelBtn.removeEventListener('click', handleCancel);
        };

        liveBtn.addEventListener('click', handleLive);
        editBtn.addEventListener('click', handleEdit);
        cancelBtn.addEventListener('click', handleCancel);
    });
}

export async function createNewProfile() {
    const result0 = await showProfileNameModal(t('button.create-new-profile.title'), '');
    if (!result0) return;
    const { name: profileName, color: accentColor } = result0;

    const sanitizedName = cleanProfileName(profileName);
    if (sanitizedName === '') {
        showStatus(t('status.invalidProfileName'), 'error');
        return;
    }

    showStatus(t('status.creatingProfile'), 'info');

    try {
        if (typeof webui !== 'undefined') {
            await rpc('createProfile', { name: sanitizedName, accentColor: htmlColorToZig(accentColor) });
            showStatus(t('status.profileCreatedSuccess'), 'success');
            await switchProfile(false, false, sanitizedName + '.json');
        } else {
            showStatus(t('status.mockCreateProfilePrefix') + sanitizedName, 'info');
        }
    } catch (error) {
        logError('Failed to create profile:', error);
        showStatus(t('status.createProfileFailedPrefix') + error.message, 'error');
    }
}

export async function copyCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    const currentDisplayName = currentProfile.replace(/\.json$/, '');
    
    const defaultColor = zigColorToHtml(app.currentConfig.accentColor);
    const copyResult = await showProfileNameModal(t('dynamic.profile.copyModalTitle').replace('{name}', currentDisplayName), currentDisplayName + ' - Copy', defaultColor);
    if (!copyResult) return;
    const { name: newName, color: accentColor } = copyResult;

    const sanitizedName = cleanProfileName(newName);
    if (sanitizedName === '') {
        showStatus(t('status.invalidProfileName'), 'error');
        return;
    }

    showStatus(t('status.copyingProfile'), 'info');

    try {
        if (typeof webui !== 'undefined') {
            await rpc('copyProfile', { source: currentProfile, target: sanitizedName, accentColor: htmlColorToZig(accentColor) });
            showStatus(t('status.profileCopiedSuccess'), 'success');
            await switchProfile(false, false, sanitizedName + '.json');
        } else {
            showStatus(t('status.mockCopyPrefix') + currentProfile + t('status.mockCopyMiddle') + sanitizedName, 'info');
        }
    } catch (error) {
        logError('Failed to copy profile:', error);
        showStatus(t('status.copyProfileFailedPrefix') + error.message, 'error');
    }
}

function showProfileNameModal(title, defaultValue = '', defaultColor = defaultAccentColorHtml()) {
    return new Promise((resolve) => {
        const modal = document.getElementById('profile-name-modal');
        const titleEl = document.getElementById('profile-modal-title');
        const input = document.getElementById('profile-name-input');
        const colorInput = document.getElementById('profile-name-color');
        const okBtn = document.getElementById('profile-modal-ok');
        const cancelBtn = document.getElementById('profile-modal-cancel');

        titleEl.textContent = title;
        input.value = defaultValue.slice(0, app.schema.profileNameMaxLength);
        colorInput.value = defaultColor;
        applyAccentColorTheme(htmlColorToZig(defaultColor));

        modal.classList.add('show');
        setTimeout(() => {
            input.focus();
            input.select();
        }, 100);

        const handleOk = () => {
            const value = input.value.trim();
            const color = colorInput.value;
            cleanup();
            resolve(value ? { name: value, color } : null);
        };

        const handleCancel = () => {
            cleanup();
            resolve(null);
        };

        const handleKeyDown = (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                handleOk();
            }
        };

        // Previews the picked accent live on the dialog itself, so a drag through the
        // picker shows what the profile's own chrome will look like before OK is pressed.
        const handleColorPreview = () => applyAccentColorTheme(htmlColorToZig(colorInput.value));

        const cleanup = () => {
            modal.classList.remove('show');
            okBtn.removeEventListener('click', handleOk);
            cancelBtn.removeEventListener('click', handleCancel);
            input.removeEventListener('keydown', handleKeyDown);
            colorInput.removeEventListener('input', handleColorPreview);
            applyAccentColorTheme();
        };

        okBtn.addEventListener('click', handleOk);
        colorInput.addEventListener('input', handleColorPreview);
        cancelBtn.addEventListener('click', handleCancel);
        input.addEventListener('keydown', handleKeyDown);
    });
}

export function deleteCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    
    if (currentProfile === 'default.json') {
        showStatus(t('status.cannotDeleteDefaultProfile'), 'error');
        return;
    }
    
    confirmRemove('delete-profile-btn', async () => {
        showStatus(t('status.deletingProfile'), 'info');
        
        try {
            if (typeof webui !== 'undefined') {
                // The app moved the window onto the profile it now runs; when that meant a switch, its profileSwitched event reopens the session.
                const { reloaded } = await rpc('deleteProfile', { name: currentProfile });
                if (!reloaded) await openSession();

                showStatus(t('status.profileDeletedSuccess'), 'success');
            } else {
                showStatus(t('status.mockDeletePrefix') + currentProfile, 'info');
            }
        } catch (error) {
            logError('Failed to delete profile:', error);
            showStatus(t('status.deleteProfileFailedPrefix') + error.message, 'error');
        }
    }, '✓');
}

export function resetCurrentProfile() {
    const profileSelect = document.getElementById('profile-select');
    const currentProfile = profileSelect.value;
    const currentDisplayName = currentProfile.replace(/\.json$/, '');

    confirmRemove('reset-profile-btn', async () => {
        showStatus(t('status.resettingProfile').replace('{name}', currentDisplayName), 'info');

        try {
            if (typeof webui !== 'undefined') {
                // Resetting the running profile reloads the app, whose profileSwitched event reopens the session.
                const { reloaded } = await rpc('resetProfile', { name: currentProfile });
                if (!reloaded) await openSession();
                showStatus(t('status.profileResetDone').replace('{name}', currentDisplayName), 'success');
            } else {
                showStatus(t('status.mockResetPrefix') + currentProfile, 'info');
            }
        } catch (error) {
            logError('Failed to reset profile:', error);
            showStatus(t('status.resetProfileFailedPrefix') + error.message, 'error');
        }
    }, '✓');
}

