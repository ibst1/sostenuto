// Sostenuto GUI. Same architecture as DeskPilot and DalSegno: AHK pushes
// one state object into window.receiveState, the page posts {action:…} back.
//
// Scope note: this window owns the ini file. The layer scripts are shown but
// not edited here - they hold real logic (fallback from a Start menu name to
// a path, version-numbered install folders, Alt for word-wise movement) that
// a table cannot express without becoming a programming environment.
let st = null;
let dirty = false;
let ridSeq = 0;          // row ids, so a browse dialog's answer finds its row

const MODIFIERS = ['none', 'LCtrl', 'RCtrl', 'LAlt', 'RAlt',
                   'LShift', 'RShift', 'LWin', 'RWin'];

// How a chosen modifier is written in other scripts. This is the single most
// useful thing the GUI can tell you, and it is easy to get wrong by hand.
const PREFIX = {
  LCtrl: '^x', RCtrl: '>^x', LAlt: '!x', RAlt: '>!x',
  LShift: '+x', RShift: '>+x', LWin: '<#x', RWin: '>#x', none: '—'
};

// What the Insert… menu offers. Values are ini syntax: keys to send, run:,
// call:. Two groups are built at click time instead: launchers ask for their
// argument, and the functions come from the host (parsed from
// core\functions.ahk, so the list cannot drift from what exists).
const INSERT = [
  { cat: 'Volume & media', items: [
    ['Volume up', '{Volume_Up}'], ['Volume down', '{Volume_Down}'],
    ['Mute', '{Volume_Mute}'], ['Play / pause', '{Media_Play_Pause}'],
    ['Next track', '{Media_Next}'], ['Previous track', '{Media_Prev}'] ] },
  { cat: 'Screen brightness', items: [
    ['Brighter', 'call:BrightnessUp'], ['Darker', 'call:BrightnessDown'] ] },
  { cat: 'Date & time', items: [
    ['Date (2026-09-01)', 'call:InsertDate'], ['Date (260901)', 'call:InsertDateDots'],
    ['Date and time', 'call:InsertDateTime'], ['Time (14:35)', 'call:InsertTime'],
    ['Week number (v202636)', 'call:InsertWeek'] ] },
  { cat: 'Navigation', items: [
    ['Up', '{Up}'], ['Down', '{Down}'], ['Left', '{Left}'], ['Right', '{Right}'],
    ['Home', '{Home}'], ['End', '{End}'], ['Page up', '{PgUp}'], ['Page down', '{PgDn}'],
    ['Word left', '^{Left}'], ['Word right', '^{Right}'],
    ['Start of document', '^{Home}'], ['End of document', '^{End}'] ] },
  { cat: 'Editing', items: [
    ['Enter', '{Enter}'], ['Tab', '{Tab}'], ['Escape', '{Esc}'],
    ['Backspace', '{Backspace}'], ['Delete', '{Delete}'],
    ['Delete word left', '^{Backspace}'], ['Delete word right', '^{Delete}'],
    ['Copy', '^c'], ['Paste', '^v'], ['Undo', '^z'] ] },
  { cat: 'Scrolling', items: [
    ['Scroll up', '{WheelUp}{WheelUp}{WheelUp}'],
    ['Scroll down', '{WheelDown}{WheelDown}{WheelDown}'] ] },
  { cat: 'Windows', items: [
    ['Explorer', 'run:explorer.exe'], ['Task view', '#{Tab}'],
    ['Snap window left', '#{Left}'], ['Snap window right', '#{Right}'],
    ['Lock the computer', 'run:rundll32.exe user32.dll,LockWorkStation'] ] }
];

const T = {
  tabModifiers: 'Modifiers', tabKeys: 'Keys', tabLayers: 'Layers',

  modH: 'What the keys become',
  modHelp: 'Windows has exactly eight modifier keys and no way to add a ninth, ' +
    'and AutoHotkey’s prefix characters are hardcoded in its parser. So a key ' +
    'is made usable everywhere by expressing it AS one of the eight - then every ' +
    'script can address it with ordinary syntax.',
  lblCaps: 'CapsLock becomes', lblCopilot: 'Copilot key becomes',
  capsHelp: 'Prefer a right-hand modifier. >^x is reachable only through this ' +
    'script, while ^x is also plain Ctrl - so the focused program’s own ' +
    'shortcuts collide with yours.',
  copilotHelp: 'The Copilot key is a tap, not a hold: a modifier chosen here is ' +
    'held for the seconds after a tap, so every key you press then that the ' +
    'layer does not bind becomes modifier+key. none is the safe choice; the ' +
    'individual keys below work either way.',
  capsAltIsCtrl: 'While CapsLock is held, use left Alt as Ctrl',
  capsAltIsCtrlHelp: 'CapsLock + Alt + j sends a clean Ctrl+Left instead of lifting ' +
    'Alt and inserting Ctrl. It survives a lossy link (Glissando) and reuses the ' +
    'CapsLock modifier, so >^x without Alt is unchanged. CapsLock + Alt + i/k then ' +
    'give Ctrl+Up/Down, not PgUp/PgDn. Right Alt (AltGr) is untouched.',
  inScripts: 'in other scripts: ',
  warnWin: 'A Win modifier inherits every Windows shortcut, and Win+L cannot be ' +
    'intercepted by any hook - it is handled at the secure-attention level. With ' +
    'RWin chosen, that key + L locks the machine.',
  warnMismatch: '{file} binds its hotkeys with the {used} prefix, but the ' +
    'modifier is set to {want}. Those hotkeys will silently stop matching - an ' +
    'unmatched hotkey is not an error. Either change the setting back or edit ' +
    'the prefixes in that file.',
  noneNote: 'With none, the individual keys below still work - they fire on the ' +
    'physical key. What goes away is the ability to address the key from other ' +
    'scripts at all.',

  keysH: 'Individual keys',
  keysHelp: 'Left: any key name (j, Down, F5, sc027), with modifiers in AutoHotkey ' +
    'syntax (!j is Alt+CapsLock+J). Right: what it does - Insert… offers the ' +
    'usual values, or type keys to send in AutoHotkey syntax, run:<command> to ' +
    'launch something, call:<function>. This column is keys, NOT code: there is ' +
    'nothing to evaluate, so Send(FormatTime()) would be typed out literally - ' +
    'anything computed is a call: function in core\\functions.ahk (the date ones ' +
    'are under Insert…). A bare word like Spotify is TYPED; ' +
    'write run:Spotify to start it. CapsLock entries fire while CapsLock is ' +
    'held. Copilot entries fire after a tap - that key cannot be held, its whole ' +
    'chord arrives within a millisecond - and entries that send keys keep the ' +
    'layer armed for the next press, so Copilot, Down, Down, Down works, as does ' +
    'holding Down; launchers close it. AltGr entries fire while AltGr is held.',
  capsSecH: 'While CapsLock is held', copilotSecH: 'After a Copilot tap (next key within {s} s)',
  altgrSecH: 'While AltGr is held', heldSecH: 'While {key} is held',
  altgrHelp: 'AltGr is a modifier already (<^>!x in any script), so it has no ' +
    'setting on the Modifiers tab - only these keys. Shift is not carried ' +
    'through here: write the Shift variant as its own row (+q). The defaults ' +
    'are a left-hand number pad: q w e / a s d / < z x are 1-9, f is 0.',
  heldHelp: 'An extra layer: these fire while {key} is physically held and ' +
    'are sent plainly, like the AltGr ones. In the ini this is the [{key}] section.',
  addLayerH: 'Another key as a layer',
  addLayerHelp: 'Any of the eight modifier keys can carry its own set of keys, ' +
    'the way AltGr does - LShift with "-" giving ? while RShift with "-" keeps ' +
    'its _, for instance. The layer appears above; fill it in and save.',
  lblAddLayer: 'Key', addLayer: 'Add layer', removeLayer: 'Remove layer',
  otherKey: 'Other key…',
  promptKey: 'Key name as AutoHotkey knows it (LShift, RShift, LWin, RWin, LCtrl, LAlt…):',
  removeConfirm: 'Remove the "{layer}" layer and every row in it? The file changes when you save.',
  layerExists: 'There is a "{layer}" layer already.',
  thKey: 'Key', thValue: 'Sends / runs',
  addRow: 'Add row', saveKeys: 'Save keys', unsaved: 'unsaved changes',
  delTip: 'Remove this row', emptyRows: 'Nothing yet.',
  insert: 'Insert…', insTip: 'Pick a ready-made value for this row',
  insLaunch: 'Launch', insBrowse: 'Program or file… (browse)',
  insApps: 'Installed app… (pick from a list)',
  insByName: 'Command name… (what you would type in Win+R)', insUrl: 'Web address…',
  insFunctions: 'Functions (core\\functions.ahk)',
  promptName: 'Command name, exactly as it works in the Run box (Win+R):\n\n' +
    'notepad, calc, mspaint, control, cmd, explorer, winword, excel\n\n' +
    'Only programs Windows knows by name work here - for anything else use ' +
    '"Installed app…" or "Program or file…" instead.',
  promptUrl: 'Web address to open:',
  appsH: 'Installed apps', appsFilter: 'Type to filter…',
  appsEmpty: 'No app matches that.', appsLoading: 'Reading the Start menu…',
  resetKeys: 'Restore defaults',
  resetConfirm: 'Replace every row under "{layer}" with the defaults? Unsaved edits are lost.',

  layersH: 'Layer scripts',
  layersHelp: 'What each layer file binds, read from the files themselves so this ' +
    'list cannot drift from what actually applies. Edit them as code - they hold ' +
    'logic an ini cannot express.',
  openFile: 'Open file', openIni: 'Open the ini file…',
  binds: ' bindings',

  status: '{caps} for CapsLock, {copilot} for the Copilot key'
};

function t(id) { return T[id] ?? id; }
function esc(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function $(id) { return document.getElementById(id); }
function post(m) { window.chrome.webview.postMessage(m); }

// ── state ──────────────────────────────────────────────────────────────
window.receiveState = function (s) {
  st = s;
  localizeStatic();
  renderModifiers();
  if (!dirty) renderKeys();
  renderLayers();
  renderStatus();
};

function localizeStatic() {
  const set = (id, key) => { const e = $(id); if (e) e.textContent = t(key); };
  set('tabBtnModifiers', 'tabModifiers'); set('tabBtnKeys', 'tabKeys');
  set('tabBtnLayers', 'tabLayers');
  set('modH', 'modH'); set('modHelp', 'modHelp');
  set('lblCaps', 'lblCaps'); set('lblCopilot', 'lblCopilot');
  set('capsHelp', 'capsHelp'); set('copilotHelp', 'copilotHelp');
  set('warnWin', 'warnWin');
  set('keysH', 'keysH'); set('keysHelp', 'keysHelp');
  set('addLayerH', 'addLayerH'); set('addLayerHelp', 'addLayerHelp');
  set('lblAddLayer', 'lblAddLayer'); set('btnAddLayer', 'addLayer');
  set('btnSaveKeys', 'saveKeys');
  set('layersH', 'layersH'); set('layersHelp', 'layersHelp');
  set('btnOpenIni', 'openIni');
}

function renderStatus() {
  $('status').textContent = t('status')
    .replace('{caps}', PREFIX[st.caps] ?? st.caps)
    .replace('{copilot}', PREFIX[st.copilot] ?? st.copilot);
}

// ── modifiers ──────────────────────────────────────────────────────────
function fillSelect(sel, chosen) {
  sel.innerHTML = MODIFIERS.map(m =>
    `<option value="${m}"${m === chosen ? ' selected' : ''}>${m}</option>`).join('');
}
function renderModifiers() {
  fillSelect($('selCaps'), st.caps || 'none');
  fillSelect($('selCopilot'), st.copilot || 'none');
  $('hintCaps').textContent = t('inScripts') + (PREFIX[st.caps] ?? '—');
  $('hintCopilot').textContent = t('inScripts') + (PREFIX[st.copilot] ?? '—');
  // the warning is only true when a Win modifier is actually chosen
  const win = (st.caps || '').includes('Win') || (st.copilot || '').includes('Win');
  $('warnWin').style.display = win ? '' : 'none';

  // A layer file writes its prefix once; changing the setting away from it
  // breaks every hotkey there without any error. Say so, with the file named.
  const mm = st.mismatch;
  const box = $('warnMismatch');
  if (mm && mm.file) {
    box.textContent = t('warnMismatch').replace('{file}', mm.file)
      .replace('{used}', mm.used).replace('{want}', mm.want);
    box.style.display = '';
  } else box.style.display = 'none';

  $('noneNote').style.display =
    (st.caps === 'none' || st.copilot === 'none') ? '' : 'none';
  $('noneNote').textContent = t('noneNote');

  $('chkCapsAltIsCtrl').checked = !!st.capsAltIsCtrl;
  $('lblCapsAltIsCtrl').textContent = t('capsAltIsCtrl');
  $('capsAltIsCtrlHelp').textContent = t('capsAltIsCtrlHelp');
}
$('selCaps').addEventListener('change', e =>
  post({ action: 'setModifier', which: 'CapsLock', value: e.target.value }));
$('selCopilot').addEventListener('change', e =>
  post({ action: 'setModifier', which: 'Copilot', value: e.target.value }));
$('chkCapsAltIsCtrl').addEventListener('change', e =>
  post({ action: 'setCapsAltIsCtrl', value: e.target.checked }));

// ── keys ───────────────────────────────────────────────────────────────
// One section per layer, in the host's order: the three built in, then
// every extra [key] section the ini has. Nothing here knows the layer
// names in advance - a layer added below is a section like any other until
// Save, when the host rewrites the file from what is on screen.
const BUILTIN = ['CapsLock', 'Copilot', 'AltGr'];
const LAYER_KEYS = ['LShift', 'RShift', 'LCtrl', 'RCtrl', 'LAlt', 'LWin', 'RWin'];

function keyRow(k, v) {
  return `<tr data-rid="r${++ridSeq}">
    <td><input class="k-key" value="${esc(k)}"></td>
    <td><input class="k-val wide" value="${esc(v)}"></td>
    <td class="actions">
      <button class="small act-ins" title="${esc(t('insTip'))}">${esc(t('insert'))}</button>
      <button class="small act-del" title="${esc(t('delTip'))}">✕</button>
    </td>
  </tr>`;
}
function rowsHtml(rows) {
  const entries = Object.entries(rows || {});
  return entries.length
    ? entries.map(([k, v]) => keyRow(k, v)).join('')
    : `<tr class="empty-row"><td colspan="3">${esc(t('emptyRows'))}</td></tr>`;
}
function sectionTitle(layer) {
  if (layer === 'CapsLock') return t('capsSecH');
  if (layer === 'Copilot')
    return t('copilotSecH').replace('{s}', ((st && st.window) ? st.window / 1000 : 2).toString());
  if (layer === 'AltGr') return t('altgrSecH');
  return t('heldSecH').replace('{key}', layer);
}
function sectionHelp(layer) {
  if (layer === 'AltGr') return t('altgrHelp');
  if (!BUILTIN.includes(layer)) return t('heldHelp').replace(/\{key\}/g, layer);
  return '';
}
function sectionHtml(layer, rows) {
  const builtin = BUILTIN.includes(layer);
  const help = sectionHelp(layer);
  return `<section class="keylayer" data-layer="${esc(layer)}">
    <h3>${esc(sectionTitle(layer))}</h3>
    ${help ? `<p class="help">${esc(help)}</p>` : ''}
    <div class="tablewrap">
      <table>
        <thead><tr><th>${esc(t('thKey'))}</th><th>${esc(t('thValue'))}</th><th></th></tr></thead>
        <tbody class="kbody">${rowsHtml(rows)}</tbody>
      </table>
    </div>
    <p><button class="small act-addrow">${esc(t('addRow'))}</button>
       ${builtin
         ? `<button class="small act-reset">${esc(t('resetKeys'))}</button>`
         : `<button class="small act-remove">${esc(t('removeLayer'))}</button>`}</p>
  </section>`;
}
function layersOnScreen() {
  return Array.from($('layerSections').querySelectorAll('section.keylayer'))
    .map(s => s.dataset.layer);
}
function renderKeys() {
  const order = st.order || BUILTIN;
  $('layerSections').innerHTML = order.map(l => sectionHtml(l, st.remaps[l])).join('');
  fillLayerSelect();
  setDirty(false);
}
// The add-layer list offers the modifiers that have no section yet; RAlt is
// the AltGr section already. "Other key…" asks for any name AutoHotkey
// knows - the host reports one it does not, in a tray tip, and skips it.
function fillLayerSelect() {
  const have = layersOnScreen();
  const free = LAYER_KEYS.filter(k => !have.includes(k));
  $('selNewLayer').innerHTML = free.map(k => `<option value="${k}">${k}</option>`).join('')
    + `<option value="*">${esc(t('otherKey'))}</option>`;
}
function setDirty(v) {
  dirty = v;
  $('keysDirty').textContent = v ? t('unsaved') : '';
}
function collect(body) {
  const out = [];
  body.querySelectorAll('tr').forEach(tr => {
    const k = tr.querySelector('.k-key'), v = tr.querySelector('.k-val');
    if (!k || !v) return;
    if (k.value.trim() !== '' && v.value.trim() !== '')
      out.push({ key: k.value.trim(), value: v.value.trim() });
  });
  return out;
}
function collectAll() {
  const order = [], layers = {};
  $('layerSections').querySelectorAll('section.keylayer').forEach(s => {
    order.push(s.dataset.layer);
    layers[s.dataset.layer] = collect(s.querySelector('.kbody'));
  });
  return { order, layers };
}
function addRow(body) {
  const empty = body.querySelector('.empty-row');
  if (empty) empty.remove();
  body.insertAdjacentHTML('beforeend', keyRow('', ''));
  setDirty(true);
  const rows = body.querySelectorAll('tr');
  rows[rows.length - 1].querySelector('.k-key').focus();
}
$('layerSections').addEventListener('input', () => setDirty(true));
$('layerSections').addEventListener('click', e => {
  const sec = e.target.closest('section.keylayer');
  if (!sec) return;
  const layer = sec.dataset.layer, body = sec.querySelector('.kbody');
  const tr = e.target.closest('tr');
  if (e.target.classList.contains('act-del')) {
    tr.remove();
    if (!body.querySelector('tr'))
      body.innerHTML = `<tr class="empty-row"><td colspan="3">${esc(t('emptyRows'))}</td></tr>`;
    setDirty(true);
  } else if (e.target.classList.contains('act-ins')) {
    openMenu(e.target, tr, layer);
  } else if (e.target.classList.contains('act-addrow')) {
    addRow(body);
  } else if (e.target.classList.contains('act-reset')) {
    resetLayer(layer);
  } else if (e.target.classList.contains('act-remove')) {
    if (!confirm(t('removeConfirm').replace('{layer}', layer))) return;
    sec.remove();
    fillLayerSelect();
    setDirty(true);
  }
});
function addLayer() {
  let name = $('selNewLayer').value;
  if (name === '*') {
    name = (prompt(t('promptKey'), '') || '').trim();
    if (!name) return;
  }
  if (layersOnScreen().some(l => l.toLowerCase() === name.toLowerCase())) {
    alert(t('layerExists').replace('{layer}', name));
    return;
  }
  $('layerSections').insertAdjacentHTML('beforeend', sectionHtml(name, {}));
  fillLayerSelect();
  setDirty(true);
  const sec = $('layerSections').lastElementChild;
  addRow(sec.querySelector('.kbody'));
  sec.scrollIntoView({ block: 'nearest' });
}
$('btnAddLayer').addEventListener('click', addLayer);
$('btnSaveKeys').addEventListener('click', () => {
  post(Object.assign({ action: 'saveKeys' }, collectAll()));
  setDirty(false);
});

// Restore defaults: the host rewrites the section and pushes new state, which
// only re-renders while nothing is dirty - so drop the dirty flag first.
function resetLayer(layer) {
  if (!confirm(t('resetConfirm').replace('{layer}', layer))) return;
  setDirty(false);
  post({ action: 'resetKeys', layer });
}

// ── insert menu ────────────────────────────────────────────────────────
// One popover for all rows, filled on demand. Choosing an item writes the
// row's value; the three launch items ask for their argument first, and the
// browse one asks the host for a file dialog and gets the answer back through
// window.browsed with the row id.
let menuRow = null, menuLayer = null, menuAnchor = null;

function menuHtml() {
  const item = (label, value, cls = 'item') =>
    `<div class="${cls}" data-value="${esc(value)}"><span>${esc(label)}</span><code>${esc(value)}</code></div>`;
  let h = '';
  h += `<div class="cat">${esc(t('insLaunch'))}</div>`;
  h += `<div class="item" data-special="apps"><span>${esc(t('insApps'))}</span><code>run:…</code></div>`;
  h += `<div class="item" data-special="browse"><span>${esc(t('insBrowse'))}</span><code>run:…</code></div>`;
  h += `<div class="item" data-special="name"><span>${esc(t('insByName'))}</span><code>run:…</code></div>`;
  h += `<div class="item" data-special="url"><span>${esc(t('insUrl'))}</span><code>run:https://…</code></div>`;
  for (const g of INSERT) {
    h += `<div class="cat">${esc(g.cat)}</div>`;
    for (const [label, value] of g.items) h += item(label, value);
  }
  const fns = (st && st.functions) || [];
  if (fns.length) {
    h += `<div class="cat">${esc(t('insFunctions'))}</div>`;
    for (const f of fns) h += item(f, 'call:' + f);
  }
  return h;
}
function openMenu(btn, tr, layer) {
  const menu = $('menu');
  menuRow = tr; menuLayer = layer; menuAnchor = btn;
  menu.innerHTML = menuHtml();
  place(menu, btn);
}
// Below the anchor, or above it when the bottom of the window is close.
function place(menu, btn) {
  menu.hidden = false;
  const r = btn.getBoundingClientRect();
  const mh = Math.min(menu.offsetHeight, window.innerHeight * 0.7);
  const top = (r.bottom + 4 + mh <= window.innerHeight) ? r.bottom + 4 : Math.max(4, r.top - 4 - mh);
  const left = Math.max(4, Math.min(r.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 4));
  menu.style.top = top + 'px';
  menu.style.left = left + 'px';
}
function closeMenu() {
  $('menu').hidden = true;
  menuRow = null; menuLayer = null; menuAnchor = null;
}

// ── installed-app picker ───────────────────────────────────────────────
// "What name?" is the wrong question to put to anyone, so the host reads the
// Start menu and the answer is picked from a filtered list. The value is the
// AppUserModelID launch line, which is what Store apps need and what ordinary
// programs accept too.
let appPickRow = null;

window.appList = function (m) {
  const tr = document.querySelector(`tr[data-rid="${m.rid}"]`);
  if (!tr || !menuAnchor) return;
  showAppPicker(tr, m.apps || []);
};

function showAppPicker(tr, apps) {
  const menu = $('menu');
  appPickRow = tr;
  const rows = apps.slice().sort((a, b) => a.name.localeCompare(b.name));
  menu.innerHTML = `<div class="cat">${esc(t('appsH'))}</div>`
    + `<div class="filterwrap"><input id="appFilter" type="text" placeholder="${esc(t('appsFilter'))}"></div>`
    + `<div id="appRows">${appRowsHtml(rows)}</div>`;
  place(menu, menuAnchor);
  const inp = $('appFilter');
  inp.addEventListener('input', () => {
    const q = inp.value.trim().toLowerCase();
    const hit = q ? rows.filter(a => a.name.toLowerCase().includes(q)) : rows;
    $('appRows').innerHTML = appRowsHtml(hit);
  });
  inp.focus();
}
function appRowsHtml(rows) {
  if (!rows.length) return `<div class="cat">${esc(t('appsEmpty'))}</div>`;
  return rows.slice(0, 300).map(a =>
    `<div class="item app" data-id="${esc(a.id)}"><span>${esc(a.name)}</span></div>`).join('');
}
function setRowValue(tr, value) {
  if (!tr || !tr.isConnected) return;
  const v = tr.querySelector('.k-val');
  v.value = value;
  setDirty(true);
  v.focus();
}
$('menu').addEventListener('click', e => {
  const el = e.target.closest('.item');
  if (!el) return;
  // an app row: the picker is already open, this is the choice
  if (el.classList.contains('app')) {
    const tr = appPickRow;
    appPickRow = null;
    closeMenu();
    setRowValue(tr, 'run:explorer shell:AppsFolder\\' + el.dataset.id);
    return;
  }
  const tr = menuRow, layer = menuLayer;
  if (el.dataset.special === 'apps') {
    $('menu').innerHTML = `<div class="cat">${esc(t('appsLoading'))}</div>`;
    post({ action: 'listApps', rid: tr.dataset.rid });
    return;                       // stays open; window.appList fills it in
  }
  closeMenu();
  if (el.dataset.special === 'browse') {
    post({ action: 'browse', layer, rid: tr.dataset.rid });
    return;
  }
  if (el.dataset.special === 'name') {
    const name = prompt(t('promptName'), '');
    if (name && name.trim()) setRowValue(tr, 'run:' + name.trim());
    return;
  }
  if (el.dataset.special === 'url') {
    const url = prompt(t('promptUrl'), 'https://');
    if (url && url.trim() && url.trim() !== 'https://') setRowValue(tr, 'run:' + url.trim());
    return;
  }
  setRowValue(tr, el.dataset.value);
});
window.browsed = function (m) {
  const tr = document.querySelector(`tr[data-rid="${m.rid}"]`);
  setRowValue(tr, m.value);
};
document.addEventListener('mousedown', e => {
  if ($('menu').hidden) return;
  if (e.target.closest('#menu') || e.target.classList.contains('act-ins')) return;
  closeMenu();
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeMenu(); });

// ── layers ─────────────────────────────────────────────────────────────
function renderLayers() {
  $('layerList').innerHTML = (st.layers || []).map(l => `
    <div class="layerbox">
      <div class="layerhead">
        <b>${esc(l.file)}</b>
        <span class="dim">${esc(l.count)}${esc(t('binds'))}</span>
        <span class="spacer"></span>
        <button class="small act-open" data-file="${esc(l.file)}">${esc(t('openFile'))}</button>
      </div>
      <div class="layerdesc">${esc(l.note)}</div>
      <div class="bindlist">${l.binds.map(b => `<code>${esc(b)}</code>`).join(' ')}</div>
    </div>`).join('');
}
$('layerList').addEventListener('click', e => {
  if (!e.target.classList.contains('act-open')) return;
  post({ action: 'openLayer', file: e.target.dataset.file });
});
$('btnOpenIni').addEventListener('click', () => post({ action: 'openIni' }));

// ── tabs ───────────────────────────────────────────────────────────────
document.querySelectorAll('#tabs .tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('#tabs .tab').forEach(b => b.classList.toggle('active', b === btn));
    document.querySelectorAll('.tabpane').forEach(p =>
      p.classList.toggle('active', p.id === 'tab-' + btn.dataset.tab));
  });
});

post({ action: 'ready' });
