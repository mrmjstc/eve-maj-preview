// Conversions between the backend's 0xAARRGGBB colours and the form's #rrggbb inputs, plus the accent theme.
import { app } from './state.js';
import { defaultFor } from './binding.js';

export function zigColorToHtml(color) {
    if (!color) return '#000000';

    let hexStr;
    if (typeof color === 'string') {
        hexStr = color.replace(/^(0x|#)/i, '');
    } else if (typeof color === 'number') {
        hexStr = color.toString(16).padStart(8, '0');
    } else {
        return '#000000';
    }
    
    const rgb = hexStr.length === 8 ? hexStr.slice(2) : hexStr.slice(-6);
    return '#' + rgb.toUpperCase();
}

export function htmlColorToZig(htmlColor) {
    if (!htmlColor) return '0xFF000000';

    const rgb = htmlColor.replace(/^#/, '').padStart(6, '0');
    return '0xFF' + rgb.toUpperCase();
}

export function defaultAccentColorHtml() {
    return zigColorToHtml(defaultFor('accentColor'));
}

// Retints the dialog's --color-accent* CSS variables from the active profile's accentColor
// (or, when previewing a not-yet-saved pick, overrideZig), so every profile can carry its own chrome color.
export function applyAccentColorTheme(overrideZig) {
    const accentZig = overrideZig || app.currentConfig?.accentColor || defaultFor('accentColor');
    // Until the schema arrives, the stylesheet's own accent shows.
    if (!accentZig) return;
    const hex = zigColorToHtml(accentZig);

    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);

    const hoverHex = '#' + [r, g, b].map(c => Math.round(c + (255 - c) * 0.15).toString(16).padStart(2, '0')).join('');
    const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    const inkHex = luminance > 0.55 ? '#1a1408' : '#f5f0e6';

    const root = document.documentElement.style;
    root.setProperty('--color-accent', hex);
    root.setProperty('--color-accent-hover', hoverHex);
    root.setProperty('--color-accent-rgb', `${r}, ${g}, ${b}`);
    root.setProperty('--color-accent-ink', inkHex);
}

export function zigColorWithAlpha(zigColorHex, alpha0to255) {
    if (!zigColorHex) return null;
    const rgb = zigColorHex.replace(/^0x/i, '').slice(-6).toUpperCase();
    const a = Math.max(0, Math.min(255, Math.round(alpha0to255))).toString(16).toUpperCase().padStart(2, '0');
    return '0x' + a + rgb;
}

// Defaults to fully opaque if no alpha channel is present (e.g. "0xRRGGBB").
export function zigColorAlpha(zigColorHex) {
    if (!zigColorHex) return 255;
    const hex = typeof zigColorHex === 'number' ? zigColorHex.toString(16).padStart(8, '0') : String(zigColorHex).replace(/^0x/i, '');
    if (hex.length < 8) return 255;
    return parseInt(hex.slice(0, 2), 16);
}
