// The custom colour picker and inline hex inputs that replace the native ones.
import { t } from './i18n.js';

// Replaces the native OS color dialog (which can't be themed) with a popup styled to match this UI; every input[type="color"] still acts as the real value/event source, so this works automatically on dynamically-created inputs with no extra wiring.
(function initCustomColorPicker() {
    let panel = null;
    let svArea = null;
    let svThumb = null;
    let hueSlider = null;
    let hueThumb = null;
    let hexInput = null;
    let clearBtn = null;
    let activeInput = null;
    const state = { h: 0, s: 0, v: 0 };

    function clamp(n, min, max) {
        return Math.min(max, Math.max(min, n));
    }

    function hexToRgb(hex) {
        let h = (hex || '#000000').replace('#', '');
        if (h.length === 3) h = h.split('').map(c => c + c).join('');
        const num = parseInt(h, 16) || 0;
        return { r: (num >> 16) & 255, g: (num >> 8) & 255, b: num & 255 };
    }

    function rgbToHex(r, g, b) {
        const toHex = v => clamp(Math.round(v), 0, 255).toString(16).padStart(2, '0');
        return '#' + toHex(r) + toHex(g) + toHex(b);
    }

    function rgbToHsv(r, g, b) {
        r /= 255; g /= 255; b /= 255;
        const max = Math.max(r, g, b), min = Math.min(r, g, b);
        const d = max - min;
        let h = 0;
        if (d !== 0) {
            if (max === r) h = ((g - b) / d) % 6;
            else if (max === g) h = (b - r) / d + 2;
            else h = (r - g) / d + 4;
            h *= 60;
            if (h < 0) h += 360;
        }
        return { h, s: max === 0 ? 0 : d / max, v: max };
    }

    function hsvToRgb(h, s, v) {
        const c = v * s;
        const x = c * (1 - Math.abs((h / 60) % 2 - 1));
        const m = v - c;
        let r = 0, g = 0, b = 0;
        if (h < 60) [r, g, b] = [c, x, 0];
        else if (h < 120) [r, g, b] = [x, c, 0];
        else if (h < 180) [r, g, b] = [0, c, x];
        else if (h < 240) [r, g, b] = [0, x, c];
        else if (h < 300) [r, g, b] = [x, 0, c];
        else [r, g, b] = [c, 0, x];
        return { r: (r + m) * 255, g: (g + m) * 255, b: (b + m) * 255 };
    }

    function currentHex() {
        const { r, g, b } = hsvToRgb(state.h, state.s, state.v);
        return rgbToHex(r, g, b);
    }

    function ensurePanel() {
        if (panel) return;

        panel = document.createElement('div');
        panel.id = 'custom-color-picker';
        panel.innerHTML = `
            <div class="cp-sv-area">
                <div class="cp-sv-white"></div>
                <div class="cp-sv-black"></div>
                <div class="cp-sv-thumb"></div>
            </div>
            <div class="cp-hue-row">
                <div class="cp-hue-slider">
                    <div class="cp-hue-thumb"></div>
                </div>
            </div>
            <div class="cp-hex-row">
                <span class="cp-hex-prefix">#</span>
                <input type="text" class="cp-hex-input" maxlength="6" spellcheck="false" autocomplete="off">
            </div>
            <button type="button" class="cp-clear-btn">Clear to Default</button>
        `;
        document.body.appendChild(panel);

        svArea = panel.querySelector('.cp-sv-area');
        svThumb = panel.querySelector('.cp-sv-thumb');
        hueSlider = panel.querySelector('.cp-hue-slider');
        hueThumb = panel.querySelector('.cp-hue-thumb');
        hexInput = panel.querySelector('.cp-hex-input');
        clearBtn = panel.querySelector('.cp-clear-btn');

        svArea.addEventListener('pointerdown', onSvPointerDown);
        hueSlider.addEventListener('pointerdown', onHuePointerDown);
        hexInput.addEventListener('input', () => {
            hexInput.value = hexInput.value.replace(/[^0-9a-fA-F]/g, '').slice(0, 6).toUpperCase();
        });
        hexInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') {
                commitHexInput();
                hexInput.blur();
            }
        });
        hexInput.addEventListener('blur', commitHexInput);
        clearBtn.addEventListener('click', () => {
            if (!activeInput) return;
            if (activeInput.dataset.optionalColor === 'true') {
                // #000000 is the display placeholder for "unset"; dataset.cleared is the actual signal consumed at save time, not the displayed color.
                activeInput.value = activeInput.dataset.defaultColor || '#000000';
                activeInput.dataset.cleared = 'true';
                activeInput.title = t('common.notSetInheritingColor');
            } else if (activeInput.dataset.defaultColor) {
                activeInput.value = activeInput.dataset.defaultColor;
            } else {
                return;
            }
            activeInput.dispatchEvent(new Event('input', { bubbles: true }));
            activeInput.dispatchEvent(new Event('change', { bubbles: true }));

            // Some swatches use a paired "Enabled" checkbox, not dataset.cleared, as the real null signal; uncheck it last since the 'change' dispatch above force-checks it.
            const nullCheckboxId = activeInput.dataset.nullCheckbox;
            if (nullCheckboxId) {
                const cb = document.getElementById(nullCheckboxId);
                if (cb && cb.checked) {
                    cb.checked = false;
                    cb.dispatchEvent(new Event('change', { bubbles: true }));
                }
            }
            closePicker();
        });
    }

    function render() {
        const hueColor = 'hsl(' + state.h + ', 100%, 50%)';
        svArea.style.backgroundColor = hueColor;
        svThumb.style.left = (state.s * 100) + '%';
        svThumb.style.top = ((1 - state.v) * 100) + '%';
        hueThumb.style.left = (state.h / 360 * 100) + '%';

        if (document.activeElement !== hexInput) {
            hexInput.value = currentHex().slice(1).toUpperCase();
        }
    }

    function commit(isFinal) {
        if (!activeInput) return;
        activeInput.value = currentHex();
        delete activeInput.dataset.cleared;
        if (activeInput.dataset.baseTitle) {
            activeInput.title = activeInput.dataset.baseTitle;
        } else {
            activeInput.removeAttribute('title');
        }
        activeInput.dispatchEvent(new Event('input', { bubbles: true }));
        if (isFinal) {
            activeInput.dispatchEvent(new Event('change', { bubbles: true }));
        }
    }

    function commitHexInput() {
        let v = hexInput.value.trim();
        if (v.length === 3) v = v.split('').map(c => c + c).join('');
        if (!/^[0-9a-fA-F]{6}$/.test(v)) {
            hexInput.value = currentHex().slice(1).toUpperCase();
            return;
        }
        const { r, g, b } = hexToRgb('#' + v);
        const hsv = rgbToHsv(r, g, b);
        state.h = hsv.h; state.s = hsv.s; state.v = hsv.v;
        render();
        commit(true);
    }

    function onSvPointerDown(e) {
        e.preventDefault();
        updateSv(e);
        const move = ev => updateSv(ev);
        const up = ev => {
            document.removeEventListener('pointermove', move);
            document.removeEventListener('pointerup', up);
            updateSv(ev);
            commit(true);
        };
        document.addEventListener('pointermove', move);
        document.addEventListener('pointerup', up);
    }

    function updateSv(e) {
        const rect = svArea.getBoundingClientRect();
        const x = clamp(e.clientX - rect.left, 0, rect.width);
        const y = clamp(e.clientY - rect.top, 0, rect.height);
        state.s = rect.width === 0 ? 0 : x / rect.width;
        state.v = rect.height === 0 ? 0 : 1 - (y / rect.height);
        render();
        commit(false);
    }

    function onHuePointerDown(e) {
        e.preventDefault();
        updateHue(e);
        const move = ev => updateHue(ev);
        const up = ev => {
            document.removeEventListener('pointermove', move);
            document.removeEventListener('pointerup', up);
            updateHue(ev);
            commit(true);
        };
        document.addEventListener('pointermove', move);
        document.addEventListener('pointerup', up);
    }

    function updateHue(e) {
        const rect = hueSlider.getBoundingClientRect();
        const x = clamp(e.clientX - rect.left, 0, rect.width);
        state.h = rect.width === 0 ? 0 : (x / rect.width) * 360;
        render();
        commit(false);
    }

    function positionPanel(input) {
        const rect = input.getBoundingClientRect();
        const margin = 6;
        const panelRect = panel.getBoundingClientRect();

        let top = rect.bottom + margin;
        let left = rect.left;

        if (top + panelRect.height > window.innerHeight) {
            top = rect.top - panelRect.height - margin;
        }
        if (left + panelRect.width > window.innerWidth) {
            left = window.innerWidth - panelRect.width - margin;
        }
        left = Math.max(margin, left);
        top = Math.max(margin, top);

        panel.style.left = left + 'px';
        panel.style.top = top + 'px';
    }

    function openPicker(input) {
        ensurePanel();
        activeInput = input;

        const { r, g, b } = hexToRgb(input.value);
        const hsv = rgbToHsv(r, g, b);
        state.h = hsv.h; state.s = hsv.s; state.v = hsv.v;

        const isClearable = input.dataset.optionalColor === 'true' || !!input.dataset.defaultColor;
        clearBtn.style.display = isClearable ? 'block' : 'none';

        render();
        panel.classList.add('open');
        positionPanel(input);

        document.addEventListener('mousedown', onDocMouseDown, true);
        document.addEventListener('keydown', onKeyDown, true);
    }

    function closePicker() {
        if (panel) panel.classList.remove('open');
        activeInput = null;
        document.removeEventListener('mousedown', onDocMouseDown, true);
        document.removeEventListener('keydown', onKeyDown, true);
    }

    function onDocMouseDown(e) {
        if (panel.contains(e.target) || e.target === activeInput) return;
        closePicker();
    }

    function onKeyDown(e) {
        if (e.key === 'Escape') closePicker();
    }

    document.addEventListener('click', function(e) {
        const input = e.target.closest && e.target.closest('input[type="color"]');
        if (!input) return;
        e.preventDefault();
        if (panel && panel.classList.contains('open') && activeInput === input) {
            closePicker();
        } else {
            openPicker(input);
        }
    }, true);
})();

// A persistent, always-visible companion to the popup's hex field above - lets a
// swatch's exact value be read/typed without opening the picker. Wraps every
// input[type="color"] (or its .swatch-wrap, where one exists) in a
// .color-with-hex row at render time; a MutationObserver catches ones created
// later by the various populate* functions, same as the picker needs no extra
// wiring for dynamic inputs. Skips the overlay popover's own color field (its
// ~150px column has no room for a second control) and any color field inside
// a .modal (e.g. the profile create/copy/import accent color picker).
//
// syncSwatchHexInput is also called directly from setFieldValue() below -
// like the range slider's mirrored span, the browser only fires 'input' for
// user interaction, not a programmatic .value assignment, so config load
// (populateFormFields -> setFieldValue) would otherwise leave every hex field
// showing its pre-load value until the swatch was next touched by hand.
export function syncSwatchHexInput(color) {
    const hex = color.closest('.color-with-hex')?.querySelector('.swatch-hex-input');
    if (!hex || document.activeElement === hex) return;
    if (color.dataset.cleared === 'true') {
        hex.value = '';
        hex.placeholder = color.value.toUpperCase();
    } else {
        hex.value = color.value.toUpperCase();
        hex.placeholder = '';
    }
}

(function initInlineColorHex() {
    function commitToColor(hex, color) {
        const v = hex.value.replace('#', '');
        if (!/^[0-9a-fA-F]{6}$/.test(v)) {
            syncSwatchHexInput(color);
            return;
        }
        color.value = '#' + v;
        delete color.dataset.cleared;
        if (color.dataset.baseTitle) color.title = color.dataset.baseTitle;
        else color.removeAttribute('title');
        color.dispatchEvent(new Event('input', { bubbles: true }));
        color.dispatchEvent(new Event('change', { bubbles: true }));
        syncSwatchHexInput(color);
    }

    function attach(color) {
        if (color.dataset.hexAttached || color.closest('.overlay-popover') || color.closest('.modal')) return;
        color.dataset.hexAttached = 'true';

        const host = color.closest('.swatch-wrap') || color;
        const wrap = document.createElement('div');
        wrap.className = 'color-with-hex';
        host.parentNode.insertBefore(wrap, host);
        wrap.appendChild(host);

        const hex = document.createElement('input');
        hex.type = 'text';
        hex.className = 'swatch-hex-input';
        hex.maxLength = 7;
        hex.spellcheck = false;
        hex.autocomplete = 'off';
        if (color.id) hex.setAttribute('aria-label', document.querySelector(`label[for="${color.id}"]`)?.textContent?.trim() || t('common.hexColorLabel'));
        wrap.appendChild(hex);

        syncSwatchHexInput(color);

        hex.addEventListener('input', () => {
            const digits = hex.value.replace(/[^0-9a-fA-F]/g, '').slice(0, 6).toUpperCase();
            hex.value = digits ? '#' + digits : '';
        });
        hex.addEventListener('keydown', e => {
            if (e.key === 'Enter') { commitToColor(hex, color); hex.blur(); }
        });
        hex.addEventListener('blur', () => commitToColor(hex, color));

        color.addEventListener('input', () => syncSwatchHexInput(color));
        color.addEventListener('change', () => syncSwatchHexInput(color));
    }

    function scanNode(node) {
        if (node.nodeType !== 1) return;
        if (node.matches('input[type="color"]')) attach(node);
        node.querySelectorAll?.('input[type="color"]').forEach(attach);
    }

    document.querySelectorAll('input[type="color"]').forEach(attach);

    new MutationObserver(mutations => {
        for (const m of mutations) m.addedNodes.forEach(scanNode);
    }).observe(document.body, { childList: true, subtree: true });
})();
