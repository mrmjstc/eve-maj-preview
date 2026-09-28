// Binds every [data-path] input to the setting it names, taking its kind, bounds and default from the app's schema (see config/schema.zig).
// data-unit shows a value in other units ("s" for milliseconds, "%" for 0-255 opacity); data-part splits one colour across an "rgb" and an "alpha" input.
// A path under "global." is a global setting; list rows name their schema entry in data-range instead, with "*" for the item.
import { app } from './state.js';
import { syncSwatchHexInput } from './color_picker.js';
import { htmlColorToZig, zigColorAlpha, zigColorToHtml, zigColorWithAlpha } from './colors.js';
import { rpc } from './core.js';
import { hotkeyToSaved, vkHexToFriendly } from './hotkeys.js';
import { t } from './i18n.js';

export async function loadSchema() {
    app.schema = await rpc('getSchema');
    applySchemaToInputs();
}

function specFor(path) {
    return app.schema?.fields[path];
}

export function defaultFor(path) {
    return specFor(path)?.default;
}

function docAndKeys(path) {
    return path.startsWith('global.')
        ? [app.currentGlobalSettings, path.slice('global.'.length).split('.')]
        : [app.currentConfig, path.split('.')];
}

function valueAt(path) {
    const [doc, keys] = docAndKeys(path);
    return keys.reduce((node, key) => (node == null ? undefined : node[key]), doc);
}

function setValueAt(path, value) {
    const [doc, keys] = docAndKeys(path);
    const parent = keys.slice(0, -1).reduce((node, key) => (node == null ? undefined : node[key]), doc);
    if (parent != null) parent[keys[keys.length - 1]] = value;
}

function toDisplay(value, unit) {
    if (unit === 's') return value / 1000;
    if (unit === '%') return Math.round(Math.max(0, Math.min(255, value)) / 255 * 100);
    return value;
}

function fromDisplay(value, unit) {
    if (unit === 's') return value * 1000;
    if (unit === '%') return Math.max(0, Math.min(100, value)) / 100 * 255;
    return value;
}

function setInputValue(el, value) {
    el.value = value;
    // The browser only fires 'input' for user interaction, so a mirrored value span is updated by hand.
    const span = el.dataset.valueTarget && document.getElementById(el.dataset.valueTarget);
    if (span) span.textContent = el.value;
}

// Native min/max and the colour swatches' "Clear to Default" value, in each input's own units.
export function applySchemaToInputs(root = document) {
    for (const el of root.querySelectorAll('[data-path], [data-range]')) {
        const spec = specFor(el.dataset.path || el.dataset.range);
        if (!spec) continue;
        if ((el.type === 'number' || el.type === 'range') && spec.min != null) {
            el.min = toDisplay(spec.min, el.dataset.unit);
            el.max = toDisplay(spec.max, el.dataset.unit);
        }
        if (el.type === 'color' && spec.default != null) el.dataset.defaultColor = zigColorToHtml(spec.default);
        if (el.tagName === 'SELECT' && spec.kind === 'enum') fillEnumOptions(el, spec);
    }
}

// Labelled by data-i18n, so a language switch relabels them with the rest of the page.
function fillEnumOptions(select, spec) {
    select.replaceChildren(...spec.options.map(value => {
        const option = new Option(t(`enum.${spec.enumType}.${value}`), value);
        option.dataset.i18n = `enum.${spec.enumType}.${value}`;
        return option;
    }));
}

function showValue(el) {
    const path = el.dataset.path;
    const spec = specFor(path) || {};
    const value = valueAt(path);
    if (el.type === 'checkbox') {
        el.checked = !!value;
    } else if (spec.kind === 'key') {
        el.value = vkHexToFriendly(value) || '';
    } else if (spec.kind === 'color' && el.dataset.part === 'alpha') {
        setInputValue(el, toDisplay(zigColorAlpha(value), '%'));
    } else if (spec.kind === 'color') {
        el.value = zigColorToHtml(value);
        syncSwatchHexInput(el);
    } else {
        setInputValue(el, value == null ? '' : toDisplay(value, el.dataset.unit));
    }
}

// Undefined leaves the setting as it is: an unknown path, or a number field left empty or mid-edit.
function readValue(el) {
    const path = el.dataset.path;
    const spec = specFor(path);
    if (!spec) return undefined;
    if (el.type === 'checkbox') return el.checked;
    switch (spec.kind) {
        case 'key':
            return hotkeyToSaved(el.value);
        case 'color': {
            if (spec.nullable && el.dataset.cleared === 'true') return null;
            const alphaInput = document.querySelector(`[data-path="${path}"][data-part="alpha"]`);
            const alpha = alphaInput ? fromDisplay(parseFloat(alphaInput.value) || 0, '%') : zigColorAlpha(valueAt(path) ?? spec.default);
            return zigColorWithAlpha(htmlColorToZig(el.value), alpha);
        }
        case 'int':
        case 'float': {
            if (el.value === '') return spec.nullable ? null : undefined;
            const number = parseFloat(el.value);
            if (isNaN(number)) return undefined;
            const value = fromDisplay(number, el.dataset.unit);
            // Out-of-range values go as typed: the app clamps them and the form shows what it kept.
            return spec.kind === 'int' ? Math.round(value) : value;
        }
        default:
            return el.value;
    }
}

// `include` picks which settings by path; all of them by default.
export function applyDocToForm(include = () => true) {
    for (const el of document.querySelectorAll('[data-path]')) {
        if (include(el.dataset.path)) showValue(el);
    }
}

export function readFormToDoc() {
    for (const el of document.querySelectorAll('[data-path]')) {
        if (el.dataset.part === 'alpha') continue;
        const value = readValue(el);
        if (value !== undefined) setValueAt(el.dataset.path, value);
    }
}
