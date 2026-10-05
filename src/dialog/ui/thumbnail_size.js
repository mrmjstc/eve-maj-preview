// The Dimensions section: thumbnail width and height kept to a chosen aspect ratio, and checked against a running EVE client's shape.
import { logWarn, rpc } from './core.js';
import { markAsChanged } from './changes.js';
import { refreshOverlayLayoutPreview } from './overlay_layout.js';

// Last detected client size, or null when none is running.
let clientSize = null;
// The shape the slider keeps while the ratio is Custom; set whenever a size is loaded or typed.
let customRatio = 16 / 9;
// The size the ratio choice was made for, so a refresh that leaves it alone keeps the user's choice.
let shownSize = null;

const field = id => document.getElementById(id);

function readSize() {
    return { width: parseFloat(field('thumbWidth').value) || 0, height: parseFloat(field('thumbHeight').value) || 0 };
}

function bounds() {
    const widthField = field('thumbWidth');
    const heightField = field('thumbHeight');
    return {
        minWidth: parseFloat(widthField.min) || 1,
        maxWidth: parseFloat(widthField.max) || Infinity,
        minHeight: parseFloat(heightField.min) || 1,
        maxHeight: parseFloat(heightField.max) || Infinity,
    };
}

// width / height for the select's value, or null for Custom (or Match EVE Client with no client).
function ratioFor(value) {
    if (value === 'client') return clientSize ? clientSize.width / clientSize.height : null;
    const [w, h] = value.split(':').map(Number);
    return w && h ? w / h : null;
}

function currentRatio() {
    return ratioFor(field('thumbAspectRatio').value) ?? customRatio;
}

function fitsRatio(size, ratio) {
    return Math.abs(Math.round(size.width / ratio) - size.height) <= 1;
}

// Presets win over the client so a saved size shows the same choice whether or not a client is running.
function inferRatioChoice(size) {
    const select = field('thumbAspectRatio');
    for (const option of select.options) {
        if (option.value === 'client' || option.value === 'custom') continue;
        if (fitsRatio(size, ratioFor(option.value))) return option.value;
    }
    if (clientSize && fitsRatio(size, clientSize.width / clientSize.height)) return 'client';
    return 'custom';
}

// Keeps the ratio while clamping to the field bounds, so the backend never has to clamp one side alone.
function sizeFromWidth(width, ratio) {
    const b = bounds();
    const maxWidth = Math.min(b.maxWidth, b.maxHeight * ratio);
    const minWidth = Math.max(b.minWidth, b.minHeight * ratio);
    const w = Math.round(Math.min(maxWidth, Math.max(minWidth, width)));
    return { width: w, height: Math.round(w / ratio) };
}

function writeSize(size) {
    field('thumbWidth').value = size.width;
    field('thumbHeight').value = size.height;
}

function refreshSlider(size) {
    field('thumbSizeSlider').value = size.width;
}

function refreshClientDisplay() {
    field('thumbAspectRatio').querySelector('option[value="client"]').disabled = !clientSize;
}

function refreshAll(size) {
    shownSize = { ...size };
    refreshSlider(size);
    refreshOverlayLayoutPreview();
}

// Called whenever saved values land in the form.
export function refreshThumbnailSize() {
    const size = readSize();
    if (shownSize?.width !== size.width || shownSize?.height !== size.height) {
        if (size.width > 0 && size.height > 0) customRatio = size.width / size.height;
        field('thumbAspectRatio').value = inferRatioChoice(size);
    }
    refreshClientDisplay();
    refreshAll(size);
}

// Run on profile load and on focus of the ratio list, since clients open and close while the dialog is up.
export async function detectThumbnailClientSize() {
    if (typeof eveRpc === 'undefined') return;
    try {
        clientSize = await rpc('getClientSize');
    } catch (error) {
        logWarn(`Failed to read the EVE client size: ${error.message}`);
        clientSize = null;
    }
    const select = field('thumbAspectRatio');
    const size = readSize();
    if (select.value === 'client' && !clientSize) select.value = inferRatioChoice(size);
    else if (select.value === 'custom' && clientSize && fitsRatio(size, clientSize.width / clientSize.height)) select.value = 'client';
    refreshClientDisplay();
}

export function onThumbAspectRatioChange() {
    const ratio = ratioFor(field('thumbAspectRatio').value);
    if (!ratio) {
        const size = readSize();
        if (size.width > 0 && size.height > 0) customRatio = size.width / size.height;
        return;
    }
    const size = sizeFromWidth(readSize().width, ratio);
    writeSize(size);
    refreshAll(size);
}

export function onThumbSizeSlider() {
    const size = sizeFromWidth(parseFloat(field('thumbSizeSlider').value), currentRatio());
    writeSize(size);
    refreshAll(size);
}

function fitsBounds(size) {
    const b = bounds();
    return size.width >= b.minWidth && size.width <= b.maxWidth && size.height >= b.minHeight && size.height <= b.maxHeight;
}

export function onThumbWidthInput() {
    const ratio = ratioFor(field('thumbAspectRatio').value);
    const size = readSize();
    if (!size.width) return;
    if (ratio) {
        size.height = Math.round(size.width / ratio);
        // "3" on the way to "300" would hand height a value the app clamps alone; onThumbWidthChange settles it instead.
        if (!fitsBounds(size)) return;
        field('thumbHeight').value = size.height;
    } else if (size.height) {
        customRatio = size.width / size.height;
    }
    refreshAll(size);
}

export function onThumbHeightInput() {
    const ratio = ratioFor(field('thumbAspectRatio').value);
    const size = readSize();
    if (!size.height) return;
    if (ratio) {
        size.width = Math.round(size.height * ratio);
        if (!fitsBounds(size)) return;
        field('thumbWidth').value = size.width;
    } else if (size.width) {
        customRatio = size.width / size.height;
    }
    refreshAll(size);
}

// Runs before form.js's generic clamp, so a ratio-locked field is clamped with its partner rather than alone.
export function onThumbWidthChange() {
    const ratio = ratioFor(field('thumbAspectRatio').value);
    const size = readSize();
    if (!size.width) return;
    const b = bounds();
    commitTypedSize(ratio ? sizeFromWidth(size.width, ratio) : { width: Math.min(b.maxWidth, Math.max(b.minWidth, size.width)), height: size.height });
}

export function onThumbHeightChange() {
    const ratio = ratioFor(field('thumbAspectRatio').value);
    const size = readSize();
    if (!size.height) return;
    const b = bounds();
    commitTypedSize(ratio ? sizeFromWidth(size.height * ratio, ratio) : { width: size.width, height: Math.min(b.maxHeight, Math.max(b.minHeight, size.height)) });
}

function commitTypedSize(size) {
    const before = readSize();
    writeSize(size);
    if (size.width > 0 && size.height > 0 && !ratioFor(field('thumbAspectRatio').value)) customRatio = size.width / size.height;
    refreshAll(size);
    // Number fields only report 'input' edits, so a value set here needs flushing by hand.
    if (size.width !== before.width || size.height !== before.height) markAsChanged();
}
