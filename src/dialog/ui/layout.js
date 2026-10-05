// Tabs, section navigation, the status bar, and closing the window.
import { hasUnsavedChanges } from './changes.js';
import { logError, rpc } from './core.js';
import { fitHotkeyGroupCharsList, selectedHotkeyGroupIndex } from './hotkey_groups.js';
import { alignBindingLabelColumns, updateHotkeyPlaceholders } from './hotkeys.js';
import { refreshOverlayLayoutPreview } from './overlay_layout.js';
import { flushEdits, saveConfiguration } from './session.js';
import { alignDetailPanelNameLabel } from './widgets.js';

// Checked per call so a mid-session OS change is picked up. scrollIntoView takes
// its behavior as a JS argument, so the reduced-motion media query in the
// stylesheet can't reach it - this is the scroll half of that rule.
export function scrollBehavior() {
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
}

export function initializeTabs() {
    const tabs = document.querySelectorAll('.tab-item');
    tabs.forEach(tab => {
        tab.setAttribute('role', 'tab');
        tab.setAttribute('tabindex', '0');

        tab.addEventListener('click', function() {
            const targetPanel = this.getAttribute('data-tab');
            switchTab(targetPanel);
        });

        // These are divs, not buttons, so Enter/Space need wiring by hand.
        tab.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                switchTab(this.getAttribute('data-tab'));
            }
        });
    });
}

// Rows that act like controls but have to stay divs - accordion headers contain
// their own Remove buttons, roster rows contain a drag handle. The lists they
// live in re-render constantly, so one delegated listener covers them all
// without rebinding. Guarded to the row itself: Enter on a nested button must
// do that button's job, not the row's.
const KEYBOARD_ACTIVATABLE = '.accordion-header, .roster-row';

export function initDelegatedKeyboardActivation() {
    document.addEventListener('keydown', e => {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        if (!e.target.matches?.(KEYBOARD_ACTIVATABLE)) return;
        e.preventDefault();
        e.target.click();
    });
}

export function switchTab(panelId) {
    document.querySelectorAll('.tab-item').forEach(tab => {
        const isActive = tab.getAttribute('data-tab') === panelId;
        tab.classList.toggle('active', isActive);
        tab.setAttribute('aria-selected', isActive ? 'true' : 'false');
    });

    document.querySelectorAll('.panel-content').forEach(panel => {
        panel.classList.remove('active');
        if (panel.getAttribute('data-panel') === panelId) {
            panel.classList.add('active');
        }
    });

    const contentPanel = document.getElementById('content-panel');
    if (contentPanel) {
        contentPanel.scrollTop = 0;
    }

    // Both read as 0 via getBoundingClientRect while the panel is display:none - recompute now that it's visible.
    if (panelId === 'thumbnails') refreshOverlayLayoutPreview();
    if (panelId === 'hotkey-groups') {
        alignDetailPanelNameLabel('hotkeyGroupsList');
        fitHotkeyGroupCharsList(selectedHotkeyGroupIndex);
    }
    if (panelId === 'characters') alignDetailPanelNameLabel('charactersList');
    // A no-op on panels with no .binding-list, so every tab can share this call rather than listing each one.
    alignBindingLabelColumns(`.panel-content[data-panel="${panelId}"]`);
    // Hotkey inputs on the panel just made visible read a real clientWidth for the first time - recheck their placeholder fit.
    updateHotkeyPlaceholders();

    setActiveSection(null);
}

// Tabs whose sections are too few/short to be worth a sidebar sub-list.
const TABS_WITHOUT_SUBHEADERS = ['about', 'characters', 'chatlog', 'hotkey-groups', 'resources', 'combat', 'bounty'];

// IDs/labels are derived from each section's h3[data-i18n] rather than hand-maintained, so they can't drift out of sync as sections are added/removed.
export function buildSectionNav() {
    document.querySelectorAll('.subheader-list').forEach(el => el.remove());

    document.querySelectorAll('.tab-item').forEach(tabItem => {
        const tabName = tabItem.getAttribute('data-tab');
        if (TABS_WITHOUT_SUBHEADERS.includes(tabName)) return;
        const panel = document.querySelector(`.panel-content[data-panel="${tabName}"]`);
        if (!panel) return;

        const list = document.createElement('div');
        list.className = 'subheader-list';

        let lastNavSection = null;
        panel.querySelectorAll('.section').forEach((section, index) => {
            if (section.style.display === 'none') return;
            if (section.classList.contains('advanced-section') && !document.body.classList.contains('advanced-mode')) return;

            if (section.classList.contains('no-subheader')) {
                // Piggybacks on the nearest preceding real entry, so that entry highlights this section too (see setActiveSection).
                if (lastNavSection) {
                    lastNavSection._linkedSections.push(section);
                    section._navItem = lastNavSection._navItem;
                }
                return;
            }

            const heading = section.querySelector('h3');
            if (!heading) return;

            const i18nKey = heading.getAttribute('data-i18n') || '';
            const slugMatch = i18nKey.match(/^tab\.[a-z0-9-]+\.section\.([a-z0-9-]+)\.heading$/);
            section.id = `section-${tabName}-${slugMatch ? slugMatch[1] : index}`;

            const item = document.createElement('div');
            item.className = 'subheader-item';
            item.textContent = heading.textContent;
            item.addEventListener('click', () => jumpToSection(tabName, section.id));
            list.appendChild(item);

            section._navItem = item;
            section._linkedSections = [section];
            lastNavSection = section;
        });

        tabItem.insertAdjacentElement('afterend', list);
    });
}

function jumpToSection(tabName, sectionId) {
    // Only switchTab() (resets scroll to top) when the tab isn't already showing, so a same-tab jump smooth-scrolls instead of snapping to top.
    const tabItem = document.querySelector(`.tab-item[data-tab="${tabName}"]`);
    if (!tabItem || !tabItem.classList.contains('active')) {
        switchTab(tabName);
    }
    requestAnimationFrame(() => {
        const section = document.getElementById(sectionId);
        if (!section) return;
        section.scrollIntoView({ behavior: scrollBehavior(), block: 'start' });
        setActiveSection(section);
    });
}

// No timer: the CSS transition on .section-active handles both the fade-in and fade-out.
function setActiveSection(section) {
    document.querySelectorAll('.section-active').forEach(el => el.classList.remove('section-active'));
    document.querySelectorAll('.subheader-item-active').forEach(el => el.classList.remove('subheader-item-active'));
    if (!section) return;
    // A no-subheader section (e.g. Not-Logged-In Thumbnail Space) shares its nav entry with the section it's linked to, so both light up together.
    (section._linkedSections || [section]).forEach(s => s.classList.add('section-active'));
    if (section._navItem) {
        section._navItem.classList.add('subheader-item-active');
    }
}

export async function closeDialog() {
    await flushEdits();
    if (hasUnsavedChanges()) {
        const choice = await showUnsavedCloseModal();
        if (choice === 'cancel') return;
        if (choice === 'save') {
            await saveConfiguration();
            // Save can fail (validation, hotkey conflict) without throwing, so don't close out from under the error.
            if (hasUnsavedChanges()) return;
        }
    }
    doCloseDialog();
}

function doCloseDialog() {
    if (typeof eveRpc !== 'undefined') {
        rpc('closeDialog').catch((error) => logError('Failed to close the dialog:', error));
    }
}

function showUnsavedCloseModal() {
    return new Promise((resolve) => {
        const modal = document.getElementById('unsaved-close-modal');
        const saveBtn = document.getElementById('unsaved-close-modal-save');
        const discardBtn = document.getElementById('unsaved-close-modal-discard');
        const cancelBtn = document.getElementById('unsaved-close-modal-cancel');

        // All .modal elements share the same z-index, so DOM order decides who paints on top; re-parent to the end of <body> to stay above other open modals.
        document.body.appendChild(modal);
        modal.classList.add('show');

        const handle = (choice) => {
            cleanup();
            resolve(choice);
        };
        const handleSave = () => handle('save');
        const handleDiscard = () => handle('discard');
        const handleCancel = () => handle('cancel');

        const cleanup = () => {
            modal.classList.remove('show');
            saveBtn.removeEventListener('click', handleSave);
            discardBtn.removeEventListener('click', handleDiscard);
            cancelBtn.removeEventListener('click', handleCancel);
        };

        saveBtn.addEventListener('click', handleSave);
        discardBtn.addEventListener('click', handleDiscard);
        cancelBtn.addEventListener('click', handleCancel);
    });
}

// Best-effort guard for the native title-bar close button / Alt+F4, which don't go through closeDialog() above.
// Browsers (and Chromium-based webviews) show their own fixed dialog here - the returnValue text itself is ignored by modern engines, only whether it's set matters.
window.addEventListener('beforeunload', (e) => {
    if (hasUnsavedChanges()) {
        e.preventDefault();
        e.returnValue = '';
    }
});

let statusHideTimer = null;
const STATUS_HIDE_DELAY_MS = 10000;

export function showStatus(message, type) {
    const statusEl = document.getElementById('status-message');
    statusEl.textContent = message;
    statusEl.className = 'status-message ' + type;
    // flex, not block - .status-message's align-items only takes effect on a flex box.
    statusEl.style.display = 'flex';

    if (statusHideTimer) clearTimeout(statusHideTimer);
    statusHideTimer = setTimeout(hideStatus, STATUS_HIDE_DELAY_MS);
}

function hideStatus() {
    const statusEl = document.getElementById('status-message');
    statusEl.style.display = 'none';
    if (statusHideTimer) {
        clearTimeout(statusHideTimer);
        statusHideTimer = null;
    }
}
