// Runs in the isolated control world of one frame, only when a person watching live asks to sign in;
// nothing here watches the page. "find" picks the visible sign-in fields of one form and keeps them
// in this world, out of the page's reach, under a token; "fill" puts a person's values into the fields
// kept under that token; "clear" empties the password fields "fill" filled. Values are never kept.
// Arguments: mode, token, expectedOrigin, entered (the values, for "fill") and submit.
const kept = globalThis.__noodleSignIn;
const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

// Sets a field as typing would end: the native setter, so frameworks that track the value they set
// (React among them) see a change, then the input and change events their listeners wait for.
function put(field, value) {
    if (!field.isConnected) throw Error('changed');
    valueSetter.call(field, value);
    field.dispatchEvent(new InputEvent('input', {bubbles: true, composed: true, inputType: 'insertReplacementText', data: value}));
    field.dispatchEvent(new Event('change', {bubbles: true}));
}
function deepElements(root, selector) {
    const found = [];
    const walk = node => {
        for (const element of node.querySelectorAll('*')) {
            if (found.length >= 2000) return;
            if (element.matches(selector)) found.push(element);
            if (element.shadowRoot) walk(element.shadowRoot);
        }
    };
    walk(root);
    return found;
}
function shown(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    const style = getComputedStyle(element);
    return style.visibility !== 'hidden' && style.display !== 'none';
}

if (mode === 'clear') {
    let cleared = 0;
    for (const field of kept?.filled ?? []) {
        if (field.isConnected && field.value !== '') { put(field, ''); cleared++; }
    }
    delete globalThis.__noodleSignIn;
    return cleared;
}

if (mode === 'fill') {
    if (!kept || kept.token !== token || self.origin !== expectedOrigin) throw Error('changed');
    const values = {username: entered.username, email: entered.username, password: entered.password,
                    'new-password': entered.newPassword, 'one-time-code': entered.oneTimeCode};
    if (kept.fields.some(({elements}) => elements.some(element => !element.isConnected))) throw Error('changed');
    const filled = new Set(kept.filled);
    let last = null, count = 0;
    for (const {kind, elements} of kept.fields) {
        const value = values[kind];
        if (value == null) continue;
        if (elements.length > 1) {
            // A code split across boxes, one character in each.
            const characters = [...value];
            elements.forEach((element, index) => { element.focus({preventScroll: true}); put(element, characters[index] ?? ''); });
        } else {
            elements[0].focus({preventScroll: true});
            put(elements[0], value);
        }
        if (kind === 'password' || kind === 'new-password') elements.forEach(element => filled.add(element));
        last = elements[elements.length - 1];
        count++;
    }
    kept.filled = [...filled];
    let submitted = false;
    if (submit && last) {
        const form = kept.form?.isConnected ? kept.form : null;
        const button = form
            ? deepElements(form, 'button, input[type=submit], input[type=image]')
                .find(element => (element.type === 'submit' || element.type === 'image') && !element.disabled && shown(element))
            : deepElements(document, 'button, [role=button], input[type=submit]')
                .find(element => !element.disabled && shown(element)
                    && /^(sign ?in|log ?in|continue|next|submit|verify)$/i.test((element.value || element.textContent || '').trim()));
        if (button) button.click();
        else if (form) form.requestSubmit();
        else {
            for (const type of ['keydown', 'keypress', 'keyup']) {
                last.dispatchEvent(new KeyboardEvent(type, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true}));
            }
        }
        submitted = true;
    }
    return {filled: count, submitted};
}

// mode === 'find'
// The form a field belongs to, across the shadow roots between them; null for a field outside any.
function formOf(field) {
    if (field.form) return field.form;
    for (let node = field.parentNode; node; node = node.parentNode ?? node.host) {
        if (node.tagName === 'FORM') return node;
    }
    return null;
}
function words(field) {
    const label = field.labels?.[0]?.textContent ?? '';
    return [field.name, field.id, field.placeholder, field.getAttribute('aria-label'), label].join(' ').toLowerCase();
}
function label(field) {
    const text = field.labels?.[0]?.textContent || field.getAttribute('aria-label') || field.placeholder || '';
    return text.replace(/\s+/g, ' ').trim().slice(0, 60);
}
function deepFocus() {
    let element = document.activeElement;
    while (element?.shadowRoot?.activeElement) element = element.shadowRoot.activeElement;
    return element;
}
function classify(field) {
    const autocomplete = (field.getAttribute('autocomplete') ?? '').toLowerCase().split(/\s+/);
    const said = words(field);
    if (field.type === 'password') {
        if (autocomplete.includes('current-password')) return 'password';
        if (autocomplete.includes('new-password')) return 'new-password';
        return /current|old|existing/.test(said) ? 'password' : /new|confirm|repeat|retype|again/.test(said) ? 'new-password' : 'password';
    }
    if (autocomplete.includes('one-time-code')) return 'one-time-code';
    if (autocomplete.includes('username')) return 'username';
    if (autocomplete.includes('email') || field.type === 'email') return 'email';
    if (/one.?time|otp|totp|2fa|mfa|verification|security.?code|passcode|auth.*code|\bcode\b|\bpin\b/.test(said)) return 'one-time-code';
    if (/e-?mail/.test(said)) return 'email';
    if (/user|login|log.?in|account|identifier|phone|mobile/.test(said)) return 'username';
    return null;
}

const textTypes = ['text', 'email', 'tel', 'number', ''];
const inputs = deepElements(document, 'input').filter(field => {
    const type = (field.getAttribute('type') ?? '').toLowerCase();
    return (type === 'password' || textTypes.includes(type)) && !field.disabled && shown(field);
});

// Codes split across boxes: four to ten single-character boxes in a row.
const split = new Map();
for (let start = 0; start < inputs.length;) {
    let end = start;
    while (end < inputs.length && inputs[end].type !== 'password' && inputs[end].maxLength === 1) end++;
    if (end - start >= 4 && end - start <= 10) split.set(inputs[start], inputs.slice(start, end));
    start = Math.max(end, start + 1);
}
const inSplit = new Set([...split.values()].flat());

// Fields grouped by their form; fields outside any form make one group for the whole document.
const groups = new Map();
for (const field of inputs) {
    if (inSplit.has(field) && !split.has(field)) continue;
    const form = formOf(field);
    if (!groups.has(form)) groups.set(form, []);
    groups.get(form).push(field);
}

const focused = deepFocus();
let best = null;
for (const [form, members] of groups) {
    const passwords = members.filter(field => field.type === 'password');
    const found = [];
    for (const [index, field] of members.entries()) {
        let kind = split.has(field) ? 'one-time-code' : classify(field);
        if (field.type === 'password' && passwords.length > 1) {
            // Two or more passwords: the current one is named as such, the rest are new.
            const current = (field.getAttribute('autocomplete') ?? '').includes('current-password') || /current|old|existing/.test(words(field));
            kind = current ? 'password' : 'new-password';
        }
        // A plain field just before the first password is the account name.
        if (!kind && passwords.length && members[index + 1] === passwords[0]) kind = 'username';
        if (kind) found.push({kind, index, elements: split.get(field) ?? [field], label: label(field)});
    }
    // One account name, the last before the first password or else the first, and one code.
    const first = passwords.length ? members.indexOf(passwords[0]) : Infinity;
    const names = found.filter(({kind}) => kind === 'username' || kind === 'email');
    const name = names.filter(({index}) => index < first).pop() ?? names[0];
    const code = found.find(({kind}) => kind === 'one-time-code');
    const fields = found.filter(field => !['username', 'email', 'one-time-code'].includes(field.kind) || field === name || field === code);
    if (!fields.length) continue;
    let score = 0;
    if (passwords.length) score += 10;
    if (code) score += 8;
    if (name) score += 3;
    if (focused && fields.some(({elements}) => elements.includes(focused))) score += 100;
    if (!best || score > best.score) best = {form, fields, score};
}

if (!best) return {score: 0, origin: self.origin, fields: []};
// A password filled earlier in this page stays listed, so it is still emptied when the viewer leaves.
globalThis.__noodleSignIn = {token, form: best.form, filled: kept?.filled ?? [],
                             fields: best.fields.map(({kind, elements}) => ({kind, elements}))};
return {
    score: best.score, origin: self.origin,
    fields: best.fields.map(({kind, elements, label}) => elements.length > 1 ? {kind, label, length: elements.length} : {kind, label})
};
