// Binds every [data-path] input to the setting it names, taking its kind, bounds and default from the app's schema (see config/schema.zig).
// A path is dotted field names with a list item's index or a map child's name, e.g. "characters.3.opacity"; the global settings are under "global.".
// Inputs can also say how the setting shows:
//   data-unit           "s" for milliseconds, "%" for 0-255 opacity
//   data-part           "rgb" or "alpha", for one colour split across a swatch and an opacity slider
//   data-inherit        a path whose value this one shows while unset, until the user moves it; setting it back to that value unsets it again
//   data-null-checkbox  the id of a checkbox that must be ticked for this value to be set
//   data-format         "csv" for a list of strings typed comma-separated, "items" for one on a container of [data-item] inputs,
//                       "path" for a file shown by its name with the full path in data-full-path
// A nullable section whose inputs are all empty is saved unset. Rebuilt rows name their schema entry in data-range for bounds only.
import { app } from './state.js';
import { syncSwatchHexInput } from './color_picker.js';
import { htmlColorToZig, zigColorAlpha, zigColorToHtml, zigColorWithAlpha } from './colors.js';
import { rpc } from './core.js';
import { hotkeyToSaved, vkHexToFriendly } from './hotkeys.js';
import { t } from './i18n.js';

const schemaKeys = new Map();

export async function loadSchema() {
    app.schema = await rpc('getSchema');
    schemaKeys.clear();
    applySchemaToInputs();
}

// "characters.3.opacity" -> "characters.*.opacity": every item of a list, or child of a map, shares one entry.
function schemaKey(path) {
    let key = schemaKeys.get(path);
    if (key !== undefined) return key;
    const out = [];
    for (const segment of path.split('.')) {
        const parent = app.schema?.fields[out.join('.')];
        out.push(parent && (parent.kind === 'list' || parent.kind === 'map') ? '*' : segment);
    }
    key = out.join('.');
    schemaKeys.set(path, key);
    return key;
}

function specFor(path) {
    return app.schema?.fields[schemaKey(path)];
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

export function baseName(path) {
    return path ? path.split(/[\\/]/).pop() : '';
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

function showColor(el, spec, value) {
    const toggle = el.dataset.nullCheckbox && document.getElementById(el.dataset.nullCheckbox);
    if (toggle) toggle.checked = value != null;
    if (value == null && spec.nullable) {
        el.value = el.dataset.defaultColor || '#000000';
        if (!toggle) {
            el.dataset.cleared = 'true';
            el.title = t('common.notSetInheritingColor');
        }
    } else {
        el.value = zigColorToHtml(value);
        delete el.dataset.cleared;
        el.removeAttribute('title');
    }
    syncSwatchHexInput(el);
}

function showValue(el) {
    const path = el.dataset.path;
    const spec = specFor(path) || {};
    let value = valueAt(path);
    const format = el.dataset.format;
    if (format === 'items') return;
    if (el.dataset.inherit) {
        if (value == null) {
            value = valueAt(el.dataset.inherit);
            el.dataset.inheriting = 'true';
        } else {
            delete el.dataset.inheriting;
        }
    }

    if (el.type === 'checkbox') {
        el.checked = !!value;
    } else if (format === 'csv') {
        el.value = (value || []).join(', ');
    } else if (format === 'path') {
        el.dataset.fullPath = value || '';
        el.value = baseName(value);
        el.title = value || '';
    } else if (spec.kind === 'key') {
        el.value = vkHexToFriendly(value) || '';
    } else if (spec.kind === 'color' && el.dataset.part === 'alpha') {
        setInputValue(el, toDisplay(zigColorAlpha(value), '%'));
    } else if (spec.kind === 'color') {
        showColor(el, spec, value);
    } else {
        setInputValue(el, value == null ? '' : toDisplay(value, el.dataset.unit));
    }
}

// Undefined leaves the setting as it is: an unknown path, or a number field left empty or mid-edit.
function readValue(el) {
    const path = el.dataset.path;
    const spec = specFor(path);
    if (!spec) return undefined;
    const format = el.dataset.format;
    const toggle = el.dataset.nullCheckbox && document.getElementById(el.dataset.nullCheckbox);
    if (toggle && !toggle.checked) return null;

    if (format === 'items') {
        return Array.from(el.querySelectorAll('[data-item]')).map(item => item.value.trim()).filter(Boolean);
    }
    if (format === 'csv') return el.value.split(',').map(part => part.trim()).filter(Boolean);
    if (format === 'path') return el.dataset.fullPath || null;
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
            if (el.dataset.inheriting === 'true') {
                // Follows what it inherits, which may have just changed, rather than turning the old value into a setting of its own.
                setInputValue(el, toDisplay(valueAt(el.dataset.inherit), el.dataset.unit));
                return null;
            }
            if (el.value === '') return spec.nullable ? null : undefined;
            const number = parseFloat(el.value);
            if (isNaN(number)) return undefined;
            // "3" on the way to "300" waits until it's in range or the field is left, where the form clamps it (see form.js).
            if (el === document.activeElement && !inBounds(el, number)) return undefined;
            if (el.dataset.inherit && number === toDisplay(valueAt(el.dataset.inherit), el.dataset.unit)) return null;
            const value = fromDisplay(number, el.dataset.unit);
            return spec.kind === 'int' ? Math.round(value) : value;
        }
        case 'string': {
            // Surrounding spaces are never meant, and would stop a name or path matching.
            const text = el.value.trim();
            return text === '' && spec.nullable ? null : text;
        }
        default:
            return el.value;
    }
}

function inBounds(el, number) {
    return (el.min === '' || number >= parseFloat(el.min)) && (el.max === '' || number <= parseFloat(el.max));
}

// Moving an inheriting input gives it a value of its own.
document.addEventListener('input', (e) => {
    if (e.target.dataset?.inheriting) delete e.target.dataset.inheriting;
});

// The nearest enclosing nullable section, e.g. "characters.3.borderColors" for "characters.3.borderColors.activeBorderColor".
function nullableSection(path) {
    const keys = path.split('.');
    for (let end = keys.length - 1; end > 0; end--) {
        const section = keys.slice(0, end).join('.');
        const spec = specFor(section);
        if (spec?.kind === 'section' && spec.nullable) return section;
    }
    return null;
}

// `include` picks which settings by path, `root` where to look; all of them by default.
export function applyDocToForm(include = () => true, root = document) {
    for (const el of root.querySelectorAll('[data-path]')) {
        if (include(el.dataset.path)) showValue(el);
    }
}

export function readFormToDoc(include = () => true, root = document) {
    const sections = new Map();
    const values = [];
    for (const el of root.querySelectorAll('[data-path]')) {
        const path = el.dataset.path;
        if (el.dataset.part === 'alpha' || !include(path)) continue;
        const value = readValue(el);
        if (value === undefined) continue;
        values.push([path, value]);
        const section = nullableSection(path);
        if (section) sections.set(section, sections.get(section) || value !== null);
    }
    for (const [section, anySet] of sections) {
        if (!anySet) setValueAt(section, null);
        else if (valueAt(section) == null) setValueAt(section, {});
    }
    for (const [path, value] of values) {
        const section = nullableSection(path);
        if (!section || sections.get(section)) setValueAt(path, value);
    }
}
