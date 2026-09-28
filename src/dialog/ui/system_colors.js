// The System Color Overrides list.
import { app } from './state.js';
import { applyDocToForm, readFormToDoc } from './binding.js';
import { markAsChanged } from './changes.js';
import { t } from './i18n.js';
import { scrollContentPanelToBottom } from './widgets.js';

export function populateSystemColors() {
    const container = document.getElementById('systemColorsList');
    if (!container) return;
    
    container.innerHTML = '';
    const colors = app.currentConfig.systemColors || [];
    
    colors.forEach((sc, index) => {
        const colorDiv = document.createElement('div');
        colorDiv.className = 'field-row list-container';
        colorDiv.innerHTML = `
            <input type="text" id="systemColor_${index}_name" data-path="systemColors.${index}.systemName" placeholder="${t('dynamic.systemColor.namePlaceholder')}">
            <input type="color" id="systemColor_${index}_color" data-path="systemColors.${index}.color">
            <button type="button" class="button-remove" id="systemColor_${index}_removeBtn" onclick="confirmRemove('systemColor_${index}_removeBtn', () => removeSystemColor(${index}))">${t('common.remove')}</button>
        `;
        container.appendChild(colorDiv);
    });
    applyDocToForm(path => path.startsWith('systemColors.'), container);
}

export function addSystemColor() {
    if (!app.currentConfig.systemColors) app.currentConfig.systemColors = [];
    saveSystemColors();
    app.currentConfig.systemColors.push({ systemName: '', color: '0xFFFFFFFF' });
    markAsChanged();
    populateSystemColors();
    scrollContentPanelToBottom();
}

export function removeSystemColor(index) {
    if (app.currentConfig.systemColors && app.currentConfig.systemColors[index] !== undefined) {
        saveSystemColors();
        app.currentConfig.systemColors.splice(index, 1);
        markAsChanged();
        populateSystemColors();
    }
}

export function saveSystemColors() {
    readFormToDoc(path => path.startsWith('systemColors.'));
}
