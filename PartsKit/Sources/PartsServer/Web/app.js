// partsd's web pages: the inventory as the Mac app shows it — parts with filters and a part's page, identify
// from a photo, locations, projects and settings — over partsd's REST API (/api, with the bearer token).
// No libraries, no build step. Everything shown is built as DOM nodes (never HTML from data).
'use strict';

// MARK: Small things

const $app = document.getElementById('app');

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  let value;
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'value') value = v;
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'disabled' || k === 'selected' || k === 'multiple') el[k] = !!v;
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k === 'ref') v(el);
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  append(el, kids);
  if (value !== undefined) el.value = value;
  return el;
}
function append(el, ...kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return el;
}
function clear(el) { while (el.firstChild) el.firstChild.remove(); return el; }

const ICONS = {
  parts: 'M21 8l-9-5-9 5v8l9 5 9-5z M3 8l9 5 9-5 M12 13v8',
  table: 'M3 5h18v14H3z M3 10h18 M3 15h18 M9 5v14',
  identify: 'M4 8V5a1 1 0 011-1h3 M16 4h3a1 1 0 011 1v3 M20 16v3a1 1 0 01-1 1h-3 M8 20H5a1 1 0 01-1-1v-3 M9 9h6v6H9z',
  location: 'M3 4h18v4H3z M5 8v12h14V8 M10 12h4',
  project: 'M9 3h6v3H9z M7 4.5H5V21h14V4.5h-2 M8 11h8 M8 15h6',
  settings: 'M12 15a3 3 0 100-6 3 3 0 000 6z M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z',
  search: 'M11 18a7 7 0 100-14 7 7 0 000 14z M21 21l-4.3-4.3',
  plus: 'M12 5v14 M5 12h14',
  x: 'M18 6L6 18 M6 6l12 12',
  down: 'M6 9l6 6 6-6',
  back: 'M15 18l-6-6 6-6',
  trash: 'M3 6h18 M8 6V4h8v2 M6 6l1 14h10l1-14',
  external: 'M14 4h6v6 M20 4l-9 9 M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5',
  doc: 'M14 3H6v18h12V7z M14 3v4h4 M9 13h6 M9 17h6',
  upload: 'M12 16V4 M7 9l5-5 5 5 M4 20h16',
  download: 'M12 4v12 M7 11l5 5 5-5 M4 20h16',
  filter: 'M3 5h18l-7 8v6l-4 2v-8z',
  refresh: 'M20 11a8 8 0 10-2.3 5.7 M20 4v7h-7',
  copy: 'M9 9h11v11H9z M5 15H4V4h11v1',
  logout: 'M15 4h4v16h-4 M10 8l-4 4 4 4 M6 12h10',
  pencil: 'M4 20h4L19 9l-4-4L4 16z',
  globe: 'M12 21a9 9 0 100-18 9 9 0 000 18z M3 12h18 M12 3a14 14 0 010 18 M12 3a14 14 0 000 18',
  photo: 'M3 5h18v14H3z M3 16l5-5 4 4 3-3 6 6 M15.5 9.5a1.5 1.5 0 100-.01',
  R: 'M4 7h16 M4 12h16 M4 17h16',
  C: 'M9 5v14 M15 5v14',
  LED: 'M9 18h6 M10 21h4 M12 3a6 6 0 00-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0012 3z',
  U: 'M7 7h10v10H7z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4',
  J: 'M7 3v6 M17 3v6 M5 9h14v4a7 7 0 01-14 0z M12 20v2',
  board: 'M3 6h18v12H3z M7 10h3v4H7z M14 10h3 M14 14h3 M6 18v3 M10 18v3 M14 18v3 M18 18v3',
};
function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('class', 'i');
  s.setAttribute('aria-hidden', 'true');
  for (const d of (ICONS[name] || ICONS.parts).split(' M').map((p, i) => (i ? 'M' + p : p))) {
    const p = document.createElementNS(ns, 'path');
    p.setAttribute('d', d);
    s.append(p);
  }
  return s;
}

function toast(msg, err) {
  let box = document.querySelector('.toasts');
  if (!box) { box = h('div', { class: 'toasts', role: 'status', 'aria-live': 'polite' }); document.body.append(box); }
  const t = h('div', { class: 'toast' + (err ? ' err' : '') }, msg);
  box.append(t);
  setTimeout(() => t.remove(), err ? 6500 : 3000);
}
const fail = e => toast(e && e.message ? e.message : String(e), true);

function debounce(f, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); }; }
const store = {
  get(k) { try { return localStorage.getItem('partsd:' + k); } catch { return null; } },
  set(k, v) { try { v == null ? localStorage.removeItem('partsd:' + k) : localStorage.setItem('partsd:' + k, v); } catch { /* private window */ } },
};
const safeHref = u => (typeof u === 'string' && /^https?:\/\//i.test(u) ? u : null);
const title = p => p.mpn || p.description || 'Unnamed part';
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const sameText = (a, b) => (a || '').localeCompare(b || '', undefined, { numeric: true, sensitivity: 'base' });
function money(v, cur) {
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency: cur || 'USD', maximumSignificantDigits: 4 }).format(v); }
  catch { return '$' + v; }
}
function when(iso) {
  const d = new Date(iso);
  return isNaN(d) ? '' : d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}
function kindIcon(p) {
  const k = p.params && p.params.kind;
  if (k && ICONS[k]) return k;
  return /^(modules|boards)/i.test(p.category || '') ? 'board' : 'parts';
}
const SUPPLIERS = [
  { id: 'digikey', name: 'Digi-Key', search: q => 'https://www.digikey.com/en/products/result?keywords=' + encodeURIComponent(q) },
  { id: 'mouser', name: 'Mouser', search: q => 'https://www.mouser.com/c/?q=' + encodeURIComponent(q) },
  { id: 'lcsc', name: 'LCSC', search: q => 'https://www.lcsc.com/search?q=' + encodeURIComponent(q) },
  { id: 'farnell', name: 'Farnell / Newark', search: q => 'https://www.farnell.com/search?st=' + encodeURIComponent(q) },
  { id: 'other', name: 'Other', search: () => null },
];
const supplierName = id => (SUPPLIERS.find(s => s.id === id) || { name: id }).name;

// Pictures to send: JPEG, at most 1600 px on the long side (big phone photos are slow to read and to keep).
async function shrink(file, max = 1600) {
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, max / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    return await new Promise((res, rej) => c.toBlob(b => (b ? res(b) : rej(new Error('Couldn’t read the picture.'))), 'image/jpeg', 0.9));
  } catch {
    if (/^image\/(jpeg|png)$/.test(file.type)) return file;
    throw new Error('This browser can’t read that picture. Use a JPEG or PNG.');
  }
}
const blobToBase64 = b => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result).replace(/^data:[^,]*,/, '')); r.onerror = rej; r.readAsDataURL(b); });
function pickFile(accept, capture) {
  return new Promise(res => {
    const i = h('input', { type: 'file', accept, capture: capture ? 'environment' : null, class: 'hidden' });
    i.addEventListener('change', () => { res(i.files[0] || null); i.remove(); });
    document.body.append(i);
    i.click();
  });
}
function download(blob, name) {
  const a = h('a', { href: URL.createObjectURL(blob), download: name, class: 'hidden' });
  document.body.append(a); a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
async function copy(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied.'); }
  catch { toast('Couldn’t copy here — select the text and copy it.', true); }
}

// MARK: The API

let token = store.get('token') || '';

class APIError extends Error { constructor(status, message) { super(message); this.status = status; } }

async function api(method, path, body, raw) {
  const headers = { Authorization: 'Bearer ' + token };
  let send;
  if (body instanceof Blob) { send = body; headers['Content-Type'] = body.type || 'application/octet-stream'; }
  else if (body !== undefined) { send = JSON.stringify(body); headers['Content-Type'] = 'application/json'; }
  let r;
  try { r = await fetch(path, { method, headers, body: send }); }
  catch { throw new APIError(0, 'Can’t reach partsd. Is it running?'); }
  if (r.status === 401) { signOut('The token wasn’t accepted. Sign in again.'); throw new APIError(401, 'Not signed in.'); }
  if (raw) { if (!r.ok) throw new APIError(r.status, (await r.json().catch(() => ({}))).error || r.statusText); return r; }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new APIError(r.status, j.error || `${r.status} ${r.statusText}`);
  return j;
}
const enc = encodeURIComponent;

// A part's photos as object URLs, fetched once with the token.
const photoCache = new Map();
function photoURL(part, i) {
  const key = part.photoIds[i];
  if (!photoCache.has(key)) {
    photoCache.set(key, api('GET', `/api/parts/${enc(part.id)}/photos/${i}`, undefined, true).then(r => r.blob()).then(b => URL.createObjectURL(b))
      .catch(e => { photoCache.delete(key); throw e; }));
  }
  return photoCache.get(key);
}
function photoImg(part, i, cls) {
  const img = h('img', { alt: '', class: cls, loading: 'lazy' });
  photoURL(part, i).then(u => { img.src = u; }).catch(() => img.remove());
  return img;
}

// MARK: State

const S = {
  health: null,
  parts: [],
  locations: [],
  loadedAt: 0,
  q: '',
  qIds: null,          // the server's matches for the search (parametric: "10k 0603 1%"), or null for no search
  filters: { category: new Set(), location: new Set(), manufacturer: new Set(), package: new Set(), stock: new Set(), tag: new Set() },
  open: { category: true, location: true, manufacturer: true, package: false, stock: true, tag: false },
  more: {},
  view: store.get('view') || 'list',
  sort: { key: 'part', dir: 1 },
  filtersShown: false,
};

async function loadAll() {
  const [health, locs] = await Promise.all([api('GET', '/api/health'), api('GET', '/api/locations')]);
  const parts = [];
  for (let off = 0; ; off += 1000) {
    const page = await api('GET', `/api/parts?limit=1000&offset=${off}`);
    parts.push(...page.parts);
    if (parts.length >= page.total || !page.parts.length) break;
  }
  S.health = health; S.parts = parts; S.locations = locs.locations; S.loadedAt = Date.now();
  if (S.q) await runSearch();
}
const partById = id => S.parts.find(p => p.id === id);
function putPart(p) {
  const i = S.parts.findIndex(x => x.id === p.id);
  if (i >= 0) S.parts[i] = { ...S.parts[i], ...p }; else S.parts.push(p);
  return partById(p.id);
}
async function reloadLocations() { S.locations = (await api('GET', '/api/locations')).locations; }

async function runSearch() {
  if (!S.q.trim()) { S.qIds = null; return; }
  const r = await api('GET', `/api/parts?limit=1000&q=${enc(S.q)}`);
  S.qIds = new Set(r.parts.map(p => p.id));
}

// MARK: Filters

const FACETS = [
  { key: 'category', title: 'Category' },
  { key: 'location', title: 'Location' },
  { key: 'stock', title: 'Stock' },
  { key: 'manufacturer', title: 'Manufacturer' },
  { key: 'package', title: 'Package' },
  { key: 'tag', title: 'Tags' },
];
function facetValues(p, key) {
  switch (key) {
    case 'category': {
      const segs = (p.category || '').split('/').map(s => s.trim()).filter(Boolean);
      return segs.map((_, i) => segs.slice(0, i + 1).join('/'));
    }
    case 'location': {
      const segs = (p.locationPath || '').split(' › ').filter(Boolean);
      return segs.length ? segs.map((_, i) => segs.slice(0, i + 1).join(' › ')) : ['(none)'];
    }
    case 'manufacturer': return p.manufacturer ? [p.manufacturer] : [];
    case 'package': return p.package ? [p.package] : [];
    case 'stock': return [p.qty <= 0 ? 'Out of stock' : 'In stock', ...(p.isLow ? ['Low'] : [])];
    case 'tag': return p.tags || [];
  }
  return [];
}
function passes(p, except) {
  if (S.qIds && !S.qIds.has(p.id)) return false;
  for (const f of FACETS) {
    if (f.key === except) continue;
    const want = S.filters[f.key];
    if (!want.size) continue;
    const have = facetValues(p, f.key);
    if (![...want].some(v => have.includes(v))) return false;
  }
  return true;
}
function shownParts() {
  const list = S.parts.filter(p => passes(p));
  const k = S.sort.key, d = S.sort.dir;
  const val = p => ({ part: title(p), manufacturer: p.manufacturer, description: p.description, value: p.summary, package: p.package, location: p.locationPath, qty: p.qty }[k]);
  return list.sort((a, b) => (k === 'qty' ? (a.qty - b.qty) : sameText(val(a), val(b))) * d || sameText(title(a), title(b)));
}
const anyFilter = () => FACETS.some(f => S.filters[f.key].size) || !!S.q;

// MARK: Routing

function route() {
  const [, view = 'parts', id = ''] = (location.hash.replace(/^#\/?/, '') || 'parts').match(/^([^/]*)\/?(.*)$/) || [];
  return { view: ['parts', 'identify', 'locations', 'projects', 'settings'].includes(view) ? view : 'parts', id: decodeURIComponent(id) };
}
const go = hash => { if (location.hash !== hash) location.hash = hash; else render(); };

// MARK: Sign in

function signOut(why) {
  token = ''; store.set('token', null);
  photoCache.clear();
  renderSignIn(why);
}

function renderSignIn(message) {
  clear($app);
  let input, err;
  const submit = async e => {
    e.preventDefault();
    const t = input.value.trim();
    if (!t) return;
    token = t;
    try {
      await api('GET', '/api/parts?limit=1');
      store.set('token', t);
      start();
    } catch (x) { if (x.status !== 401) err.textContent = x.message; }
  };
  append($app, h('div', { class: 'signin' },
    h('form', { class: 'card', onsubmit: submit },
      h('h1', {}, h('img', { src: 'icon.svg', alt: '' }), 'Parts Inventory'),
      h('p', {}, 'Sign in with partsd’s API token. On the server, run ', h('code', {}, 'partsd --print-token'), ' (or read ', h('code', {}, '~/.local/share/partsd/token'), ').'),
      h('input', { class: 'field mono', type: 'password', placeholder: 'API token', autocomplete: 'current-password', ref: el => { input = el; } }),
      h('div', { class: 'err-text', ref: el => { err = el; } }, message || ''),
      h('div', { class: 'row' }, h('span', { class: 'grow faint' }, 'The token is kept in this browser only.'), h('button', { class: 'btn primary', type: 'submit' }, 'Sign in')))));
  input.focus();
}

// MARK: Shell

let $main, $nav;
function renderShell() {
  clear($app);
  const navItem = (view, label, ic) => h('a', { class: 'nav', href: '#/' + view, dataset: { view } }, icon(ic), h('span', {}, label), h('span', { class: 'badge' }));
  $nav = h('nav', { class: 'sidebar', 'aria-label': 'Sections' },
    h('div', { class: 'brand' }, h('img', { src: 'icon.svg', alt: '' }), h('div', {}, 'Parts Inventory', h('small', {}, location.hostname))),
    navItem('parts', 'Parts', 'parts'),
    navItem('identify', 'Identify', 'identify'),
    navItem('locations', 'Locations', 'location'),
    navItem('projects', 'Projects', 'project'),
    navItem('settings', 'Settings', 'settings'),
    h('div', { class: 'foot' }));
  $main = h('main', { class: 'main' });
  append($app, h('div', { class: 'shell' }, $nav, $main));
}
function renderNav() {
  const r = route();
  for (const a of $nav.querySelectorAll('.nav')) {
    a.classList.toggle('on', a.dataset.view === r.view);
    if (a.dataset.view === 'parts') a.querySelector('.badge').textContent = S.parts.length || '';
    if (a.dataset.view === 'locations') a.querySelector('.badge').textContent = S.locations.length || '';
  }
  const foot = clear($nav.querySelector('.foot'));
  const units = S.parts.reduce((n, p) => n + (p.qty || 0), 0);
  append(foot,
    h('div', {}, h('span', { class: 'dot' }), `partsd ${S.health ? S.health.version : ''}`),
    h('div', {}, `${plural(S.parts.length, 'part')}, ${units.toLocaleString()} units`),
    h('div', {}, h('span', { class: 'dot' + (S.health && S.health.identify ? '' : ' off') }), S.health && S.health.identify ? 'Photo identify on' : 'Photo identify off'));
}

function render() {
  if (!token) return renderSignIn();
  if (!$main || !$main.isConnected) renderShell();
  renderNav();
  const r = route();
  document.title = { parts: 'Parts', identify: 'Identify', locations: 'Locations', projects: 'Projects', settings: 'Settings' }[r.view] + ' · Parts Inventory';
  ({ parts: renderParts, identify: renderIdentify, locations: renderLocations, projects: renderProjects, settings: renderSettings })[r.view](r.id);
}

// MARK: Parts

let $parts, $facets, $list, $chips, $count, $detail;
let detailFor = null;

function renderParts(id) {
  if (!$parts || !$parts.isConnected) {
    clear($main);
    let input;
    const doSearch = debounce(async () => {
      try { await runSearch(); } catch (e) { fail(e); }
      renderFacets(); renderList();
    }, 220);
    const bar = h('div', { class: 'toolbar' },
      h('h1', {}, 'Parts'),
      h('div', { class: 'search' }, icon('search'),
        h('input', { type: 'search', placeholder: 'Search: lm358, 10k 0603 1%, cat:caps, low', value: S.q, 'aria-label': 'Search parts', ref: el => { input = el; },
          oninput: () => { S.q = input.value; doSearch(); } })),
      h('button', { class: 'btn only-phone', onclick: () => { S.filtersShown = !S.filtersShown; $facets.classList.toggle('open', S.filtersShown); } }, icon('filter'), 'Filters'),
      h('span', { class: 'grow hide-phone' }),
      h('span', { class: 'muted num hide-phone', ref: el => { $count = el; } }),
      h('div', { class: 'seg hide-phone', role: 'group', 'aria-label': 'Show as' },
        h('button', { class: S.view === 'list' ? 'on' : '', title: 'List', onclick: e => setView('list', e) }, icon('parts')),
        h('button', { class: S.view === 'table' ? 'on' : '', title: 'Table', onclick: e => setView('table', e) }, icon('table'))),
      h('button', { class: 'btn icon plain', title: 'Reload', onclick: () => refresh(true) }, icon('refresh')),
      h('button', { class: 'btn primary', onclick: () => addPartDialog() }, icon('plus'), h('span', { class: 'hide-phone' }, 'Add part')));
    $facets = h('aside', { class: 'facets', 'aria-label': 'Filters' });
    $chips = h('div', { class: 'chips hidden' });
    $list = h('div', { class: 'list' });
    $detail = h('section', { class: 'detail hidden', 'aria-label': 'Part' });
    $parts = h('div', { class: 'parts' }, $facets, h('div', { class: 'listcol' }, $chips, $list), $detail);
    append($main, bar, $parts);
    detailFor = null;
    renderFacets();
    renderList();
  }
  // Choosing another part only changes the selection and the part's page; the list keeps its place.
  showDetail(id && partById(id) ? id : null);
}
function setView(v, e) {
  S.view = v; store.set('view', v);
  for (const b of e.currentTarget.parentElement.children) b.classList.toggle('on', b === e.currentTarget);
  renderList();
}

function renderFacets() {
  clear($facets);
  append($facets, h('div', { class: 'row only-phone' }, h('span', { class: 'grow' }), h('button', { class: 'btn plain', onclick: () => { S.filtersShown = false; $facets.classList.remove('open'); } }, 'Done')));
  for (const f of FACETS) {
    const counts = new Map();
    for (const p of S.parts) if (passes(p, f.key)) for (const v of new Set(facetValues(p, f.key))) counts.set(v, (counts.get(v) || 0) + 1);
    for (const v of S.filters[f.key]) if (!counts.has(v)) counts.set(v, 0);
    if (!counts.size) continue;
    let values = [...counts.keys()];
    const depth = v => (f.key === 'category' ? v.split('/').length - 1 : f.key === 'location' ? v.split(' › ').length - 1 : 0);
    if (f.key === 'stock') values = ['In stock', 'Low', 'Out of stock'].filter(v => counts.has(v));
    else if (f.key === 'category' || f.key === 'location') values.sort((a, b) => (a === '(none)') - (b === '(none)') || sameText(a, b));
    else values.sort((a, b) => counts.get(b) - counts.get(a) || sameText(a, b));
    const limit = S.more[f.key] ? Infinity : 8;
    const ul = h('ul', {});
    values.slice(0, limit).forEach(v => {
      const on = S.filters[f.key].has(v);
      const label = f.key === 'category' ? v.split('/').pop() : f.key === 'location' ? v.split(' › ').pop() : v;
      ul.append(h('li', { class: (on ? 'on ' : '') + 'indent' + Math.min(3, depth(v)), title: v, role: 'checkbox', 'aria-checked': on ? 'true' : 'false', tabindex: 0,
        onclick: () => toggleFilter(f.key, v), onkeydown: e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); toggleFilter(f.key, v); } } },
        h('span', { class: 'box' }), h('span', { class: 'ellipsis grow' }, label), h('span', { class: 'n num' }, counts.get(v))));
    });
    const sec = h('div', { class: 'facet' + (S.open[f.key] ? '' : ' closed') },
      h('h3', { onclick: () => { S.open[f.key] = !S.open[f.key]; renderFacets(); } }, f.title, icon('down')), ul);
    if (values.length > 8) sec.append(h('div', { class: 'more', onclick: () => { S.more[f.key] = !S.more[f.key]; renderFacets(); } }, S.more[f.key] ? 'Show fewer' : `Show ${values.length - 8} more`));
    $facets.append(sec);
  }
}
function toggleFilter(key, v) {
  const s = S.filters[key];
  s.has(v) ? s.delete(v) : s.add(v);
  renderFacets(); renderList();
}

function renderChips() {
  clear($chips);
  const chips = [];
  for (const f of FACETS) for (const v of S.filters[f.key]) {
    chips.push(h('span', { class: 'chip' }, `${f.title}: ${f.key === 'category' ? v.replace(/\//g, ' › ') : v}`,
      h('button', { 'aria-label': 'Remove filter', onclick: () => toggleFilter(f.key, v) }, '×')));
  }
  $chips.classList.toggle('hidden', !chips.length);
  if (chips.length) append($chips, chips, h('button', { class: 'clearall', onclick: () => { for (const f of FACETS) S.filters[f.key].clear(); renderFacets(); renderList(); } }, 'Clear all'));
}

function renderList() {
  renderChips();
  const list = shownParts();
  const sel = route().id;
  $count.textContent = anyFilter() ? `${list.length} of ${S.parts.length}` : plural(S.parts.length, 'part');
  const top = $list.scrollTop;
  clear($list);
  requestAnimationFrame(() => { $list.scrollTop = top; });
  if (!S.parts.length) {
    $list.append(h('div', { class: 'empty' }, icon('parts'), h('h2', {}, 'No parts yet'),
      h('p', {}, 'Add one by hand, identify one from a photo, or import a backup from the Mac or iPhone app in Settings.'),
      h('div', { class: 'row' }, h('button', { class: 'btn primary', onclick: () => addPartDialog() }, icon('plus'), 'Add part'), h('a', { class: 'btn', href: '#/settings' }, 'Import a backup'))));
    return;
  }
  if (!list.length) {
    $list.append(h('div', { class: 'empty' }, icon('search'), h('h2', {}, 'Nothing matches'), h('p', {}, S.q ? `No parts match “${S.q}” with these filters.` : 'No parts match these filters.')));
    return;
  }
  if (S.view === 'table' && window.innerWidth > 760) return renderTable(list, sel);
  const frag = document.createDocumentFragment();
  for (const p of list) {
    const thumb = h('div', { class: 'thumb' });
    if (p.photoCount) thumb.append(photoImg(p, 0)); else thumb.append(icon(kindIcon(p)));
    const sub = [p.summary, p.description].filter(Boolean).join(' · ');
    frag.append(h('div', { class: 'prow' + (p.id === sel ? ' sel' : ''), tabindex: 0, role: 'button', dataset: { id: p.id },
      onclick: () => go('#/parts/' + enc(p.id)), onkeydown: e => { if (e.key === 'Enter') go('#/parts/' + enc(p.id)); } },
      thumb,
      h('div', { class: 'grow' },
        h('div', { class: 't ellipsis' }, title(p)),
        sub && h('div', { class: 's muted ellipsis' }, sub),
        p.locationPath && h('div', { class: 'l faint ellipsis' }, icon('location'), p.locationPath)),
      h('div', { class: 'qty' + (p.isLow ? ' low' : '') }, p.qty)));
  }
  $list.append(frag);
}

function renderTable(list, sel) {
  const cols = [['part', 'Part'], ['manufacturer', 'Manufacturer'], ['description', 'Description'], ['value', 'Value'], ['package', 'Package'], ['location', 'Location'], ['qty', 'Qty', 'r']];
  const head = h('tr', {}, cols.map(([k, label, cls]) => h('th', { class: cls, onclick: () => { S.sort = { key: k, dir: S.sort.key === k ? -S.sort.dir : 1 }; renderList(); } },
    label, S.sort.key === k ? h('span', { class: 'arrow' }, S.sort.dir > 0 ? '▲' : '▼') : null)));
  const body = h('tbody', {});
  for (const p of list) {
    body.append(h('tr', { class: 'click' + (p.id === sel ? ' sel' : ''), dataset: { id: p.id }, onclick: () => go('#/parts/' + enc(p.id)) },
      h('td', {}, h('b', {}, title(p))), h('td', {}, p.manufacturer), h('td', { title: p.description }, p.description), h('td', {}, p.summary),
      h('td', {}, p.package), h('td', { class: 'muted' }, p.locationPath), h('td', { class: 'r num' + (p.isLow ? ' low' : '') }, p.qty)));
  }
  $list.append(h('table', { class: 'grid' }, h('thead', {}, head), body));
}

// MARK: A part's page

function showDetail(id) {
  $parts.classList.toggle('with-detail', !!id);
  $detail.classList.toggle('hidden', !id);
  for (const r of $list.querySelectorAll('.prow, tr.click')) r.classList.toggle('sel', r.dataset.id === id);
  if (!id) { detailFor = null; clear($detail); return; }
  if (detailFor === id && $detail.firstChild) return;
  detailFor = id;
  buildDetail(partById(id));
  api('GET', `/api/parts/${enc(id)}`).then(full => {
    if (detailFor !== id) return;
    putPart(full);
    const box = $detail.querySelector('[data-history]');
    if (box) fillHistory(box, full.history || []);
  }).catch(fail);
}
function refreshDetail() { if (detailFor) { const id = detailFor; detailFor = null; showDetail(id); } }

function flashSaved() {
  const s = $detail.querySelector('.saved');
  if (!s) return;
  s.classList.add('show');
  clearTimeout(s._t); s._t = setTimeout(() => s.classList.remove('show'), 1400);
}
async function patch(id, fields, rebuild) {
  try {
    const p = putPart(await api('PATCH', `/api/parts/${enc(id)}`, fields));
    renderList();
    if (rebuild) refreshDetail(); else updateDetailHead(p);
    flashSaved();
    return p;
  } catch (e) { fail(e); refreshDetail(); }
}
async function changeStock(id, body) {
  try {
    await api('POST', `/api/parts/${enc(id)}/stock`, body);
    putPart(await api('GET', `/api/parts/${enc(id)}`));
    renderList(); renderNav(); refreshDetail();
  } catch (e) { fail(e); }
}
function updateDetailHead(p) {
  const t = $detail.querySelector('.dhead h2'), s = $detail.querySelector('.dhead .sub');
  if (t) t.textContent = title(p);
  if (s) s.textContent = [p.manufacturer, p.summary].filter(Boolean).join(' · ');
}

function buildDetail(p) {
  clear($detail);
  const id = p.id;
  const text = (key, placeholder, opts = {}) => {
    const el = h(opts.area ? 'textarea' : 'input', { class: 'bare' + (opts.mono ? ' mono' : ''), placeholder, value: p[key] || '', rows: opts.area ? 3 : null, 'aria-label': placeholder });
    el.addEventListener('change', () => patch(id, { [key]: el.value }, opts.rebuild));
    return el;
  };
  const r = (label, ...kids) => h('div', { class: 'r' }, label != null ? h('label', {}, label) : null, ...kids);
  const section = (name, ...kids) => h('div', { class: 'section' }, name && h('h4', {}, name), h('div', { class: 'card' }, ...kids));

  // In stock
  let counted;
  const locSelect = h('select', { class: 'field', 'aria-label': 'Location', onchange: async e => {
    if (e.target.value === '__new') {
      const path = await ask('New location', 'Where it is, outside in: “Cabinet A / Drawer 3”.', 'Cabinet A / Drawer 3', p.locationPath ? p.locationPath.replace(/ › /g, ' / ') + ' / ' : '');
      if (!path) { e.target.value = p.locationId || ''; return; }
      await patch(id, { location: path }, true);
      await reloadLocations(); renderNav(); renderFacets();
      return;
    }
    patch(id, { locationId: e.target.value || null }, true);
  } }, h('option', { value: '' }, 'None'), sortedLocations().map(l => h('option', { value: l.id }, l.path)), h('option', { value: '__new' }, 'New location…'));
  locSelect.value = p.locationId || '';
  const low = h('input', { class: 'bare num', type: 'number', min: 0, placeholder: 'Default', value: p.lowStock ?? '', 'aria-label': 'Low-stock warning at' });
  low.addEventListener('change', () => patch(id, { lowStock: low.value === '' ? null : Number(low.value) }));
  const stock = section('In stock',
    r(null, h('div', { class: 'stock grow' },
      h('button', { class: 'round', 'aria-label': 'Use one', disabled: p.qty <= 0, onclick: () => changeStock(id, { delta: -1, note: 'Used' }) }, '−'),
      h('div', { class: 'big' + (p.isLow ? ' low' : '') }, p.qty),
      h('button', { class: 'round', 'aria-label': 'Add one', onclick: () => changeStock(id, { delta: 1, note: 'Added' }) }, '+'),
      h('span', { class: 'grow' }),
      h('input', { class: 'field num', type: 'number', min: 0, placeholder: 'Counted', ref: el => { counted = el; }, onkeydown: e => { if (e.key === 'Enter') setCount(); } }),
      h('button', { class: 'btn', onclick: () => setCount() }, 'Set count'))),
    r('Location', locSelect),
    r('Low stock at', low));
  counted.style.width = '96px';
  function setCount() {
    const n = parseInt(counted.value, 10);
    if (Number.isFinite(n) && n >= 0) changeStock(id, { set: n, note: 'Counted' });
  }

  // Part
  const paramText = h('input', { class: 'bare', placeholder: 'Set from text: 10k 1% 0603', onkeydown: e => { if (e.key === 'Enter') applyParams(); } });
  function applyParams() { if (paramText.value.trim()) patch(id, { paramsText: paramText.value.trim() }, true); }
  const tags = h('input', { class: 'bare', placeholder: 'smd, resistor', value: (p.tags || []).join(', ') });
  tags.addEventListener('change', () => patch(id, { tags: tags.value }));
  const part = section('Part',
    r('Part number', text('mpn', 'Manufacturer part number', { mono: true })),
    r('Manufacturer', text('manufacturer', 'Manufacturer')),
    r('Description', text('description', 'Description', { area: true })),
    r('Category', text('category', 'Passives/Resistors')),
    r('Package', text('package', '0603, SOIC-8…')),
    r('Parameters', h('div', { class: 'grow' }, h('div', { class: p.summary ? '' : 'faint' }, p.summary || '—'))),
    r('', paramText, h('button', { class: 'btn small', onclick: applyParams }, 'Apply')),
    r('Tags', tags));

  // Datasheet and suppliers
  const ds = text('datasheet', 'https://…', { rebuild: true });
  const supplierRows = (p.suppliers || []).map((s, i) => {
    const b = (s.breaks || [])[0];
    const href = safeHref(s.url) || (SUPPLIERS.find(x => x.id === s.supplier) || { search: () => null }).search(s.pn);
    return h('div', { class: 'sup' },
      h('span', { class: 'who' }, supplierName(s.supplier)),
      h('div', { class: 'grow' },
        href ? h('a', { href, target: '_blank', rel: 'noopener noreferrer', class: 'mono' }, s.pn) : h('span', { class: 'mono' }, s.pn),
        b && h('div', { class: 'price num' }, `${money(b.unit, s.currency)} · ${(s.stock || 0).toLocaleString()} in stock`)),
      h('button', { class: 'btn icon plain', title: 'Remove', 'aria-label': 'Remove supplier', onclick: () => {
        const list = p.suppliers.slice(); list.splice(i, 1); patch(id, { suppliers: list }, true);
      } }, icon('x')));
  });
  const newSup = h('select', { class: 'field', 'aria-label': 'Supplier' }, SUPPLIERS.map(s => h('option', { value: s.id }, s.name)));
  newSup.style.width = 'auto';
  const newPN = h('input', { class: 'bare mono', placeholder: 'Supplier part number' });
  const addSup = () => { const pn = newPN.value.trim(); if (pn) patch(id, { suppliers: [...(p.suppliers || []), { supplier: newSup.value, pn }] }, true); };
  newPN.addEventListener('keydown', e => { if (e.key === 'Enter') addSup(); });
  const dsHref = safeHref(p.datasheet);
  const suppliers = section('Datasheet and suppliers',
    r(null, h('button', { class: 'btn', disabled: !p.mpn && !(p.suppliers || []).length, onclick: () => lookupDialog(partById(id)) }, icon('globe'), 'Look up online'),
      dsHref && h('a', { class: 'btn plain', href: dsHref, target: '_blank', rel: 'noopener noreferrer' }, icon('doc'), 'Datasheet')),
    r('Datasheet', ds),
    supplierRows,
    r(null, newSup, newPN, h('button', { class: 'btn small', onclick: addSup }, 'Add')),
    p.mpn && h('div', { class: 'links r' }, h('span', { class: 'muted' }, 'Search:'),
      [['Octopart', 'https://octopart.com/search?q='], ['Digi-Key', 'https://www.digikey.com/en/products/result?keywords='], ['Mouser', 'https://www.mouser.com/c/?q='],
        ['LCSC', 'https://www.lcsc.com/search?q='], ['Datasheets', 'https://www.google.com/search?q=datasheet+']]
        .map(([n, u]) => h('a', { href: u + enc(p.mpn), target: '_blank', rel: 'noopener noreferrer' }, n))));

  // Photos
  const photos = h('div', { class: 'photos' });
  (p.photoIds || []).forEach((_, i) => {
    const img = photoImg(p, i);
    photos.append(h('div', { class: 'ph', onclick: () => lightbox(img.src) }, img,
      h('button', { class: 'x', title: 'Delete photo', 'aria-label': 'Delete photo', onclick: async e => {
        e.stopPropagation();
        if (!(await confirmDialog('Delete this photo?', 'It’s removed from the part for good.', 'Delete'))) return;
        try { putPart(await api('DELETE', `/api/parts/${enc(id)}/photos/${i}`)); renderList(); refreshDetail(); } catch (x) { fail(x); }
      } }, '×')));
  });
  const addPhoto = async capture => {
    const f = await pickFile('image/*', capture);
    if (!f) return;
    try { putPart(await api('POST', `/api/parts/${enc(id)}/photos`, await shrink(f))); renderList(); refreshDetail(); toast('Photo added.'); } catch (x) { fail(x); }
  };
  const photoSec = section('Photos',
    p.photoIds && p.photoIds.length ? photos : null,
    r(null, h('button', { class: 'btn', onclick: () => addPhoto(false) }, icon('photo'), 'Add a photo'),
      h('button', { class: 'btn only-phone', onclick: () => addPhoto(true) }, icon('identify'), 'Take one')));

  const notes = section('Notes', r(null, text('notes', 'Notes', { area: true })));
  const hist = h('div', { dataset: { history: '1' } }, h('div', { class: 'r faint' }, 'Loading…'));
  const history = section('History', hist);
  const danger = h('div', { class: 'row' }, h('span', { class: 'grow faint' }, p.created ? 'Added ' + new Date(p.created).toLocaleDateString() : ''),
    h('button', { class: 'btn danger', onclick: async () => {
      if (!(await confirmDialog(`Delete ${title(p)}?`, 'The part, its photos and its history are removed. This can’t be undone (export a backup first if unsure).', 'Delete'))) return;
      try { await api('DELETE', `/api/parts/${enc(id)}`); S.parts = S.parts.filter(x => x.id !== id); toast(`Deleted ${title(p)}.`); go('#/parts'); renderFacets(); renderList(); renderNav(); }
      catch (x) { fail(x); }
    } }, icon('trash'), 'Delete part'));

  append($detail,
    h('div', { class: 'dhead' },
      h('button', { class: 'btn icon plain back', 'aria-label': 'Back', onclick: () => go('#/parts') }, icon('back')),
      h('div', { class: 'grow' }, h('h2', {}, title(p)), h('div', { class: 'sub' }, [p.manufacturer, p.summary].filter(Boolean).join(' · '))),
      h('span', { class: 'saved' }, 'Saved'),
      h('button', { class: 'btn icon plain hide-phone', title: 'Close', 'aria-label': 'Close', onclick: () => go('#/parts') }, icon('x'))),
    h('div', { class: 'sections' }, stock, part, suppliers, photoSec, notes, history, danger));
}

function fillHistory(box, history) {
  clear(box);
  if (!history.length) { box.append(h('div', { class: 'r faint' }, 'No stock changes yet.')); return; }
  for (const c of history) {
    box.append(h('div', { class: 'hist' },
      h('span', { class: 'd ' + (c.delta > 0 ? 'up' : 'down') }, c.delta > 0 ? '+' + c.delta : String(c.delta)),
      h('span', {}, c.reason || 'Change'),
      h('span', { class: 'muted num' }, c.qtyAfter != null ? '→ ' + c.qtyAfter : ''),
      h('span', { class: 'when' }, when(c.at))));
  }
}

function sortedLocations() { return S.locations.slice().sort((a, b) => sameText(a.path, b.path)); }

// MARK: Dialogs

function dialog(build, wide) {
  return new Promise(resolve => {
    const prev = document.activeElement;
    let done = false;
    const close = v => { if (done) return; done = true; scrim.remove(); document.removeEventListener('keydown', esc); if (prev && prev.focus) prev.focus(); resolve(v); };
    const esc = e => { if (e.key === 'Escape') close(undefined); };
    const box = h('div', { class: 'dialog' + (wide ? ' wide' : ''), role: 'dialog', 'aria-modal': 'true' });
    const scrim = h('div', { class: 'scrim', onmousedown: e => { if (e.target === scrim) close(undefined); } }, box);
    build(box, close);
    document.body.append(scrim);
    document.addEventListener('keydown', esc);
    const f = box.querySelector('[autofocus], input, select, textarea, button.primary');
    if (f) f.focus();
  });
}
function confirmDialog(t, msg, verb) {
  return dialog((box, close) => append(box,
    h('header', {}, h('h3', {}, t), msg && h('p', {}, msg)),
    h('footer', {}, h('button', { class: 'btn', onclick: () => close(false) }, 'Cancel'), h('button', { class: 'btn primary', onclick: () => close(true) }, verb || 'OK'))));
}
function ask(t, msg, placeholder, value) {
  return dialog((box, close) => {
    let input;
    append(box, h('form', { onsubmit: e => { e.preventDefault(); close(input.value.trim()); } },
      h('header', {}, h('h3', {}, t), msg && h('p', {}, msg)),
      h('div', { class: 'body' }, h('input', { class: 'field', placeholder, value: value || '', ref: el => { input = el; }, autofocus: true })),
      h('footer', {}, h('button', { class: 'btn', type: 'button', onclick: () => close('') }, 'Cancel'), h('button', { class: 'btn primary', type: 'submit' }, 'OK'))));
  });
}
function lightbox(src) {
  if (!src) return;
  const lb = h('div', { class: 'lightbox', onclick: () => lb.remove() }, h('img', { src, alt: '' }));
  document.body.append(lb);
}

// A new part: by hand, from a photo's reading, with Digi-Key and Mouser filling in what they know.
function addPartDialog(pre = {}) {
  return dialog((box, close) => {
    const f = {};
    const field = (k, label, props = {}) => h('label', { class: 'form-r' }, h('span', {}, label), f[k] = h(props.area ? 'textarea' : 'input', { class: 'field' + (props.mono ? ' mono' : ''), ...props, value: pre[k] ?? props.value ?? '' }));
    const paths = h('datalist', { id: 'loc-paths' }, sortedLocations().map(l => h('option', { value: l.path.replace(/ › /g, ' / ') })));
    let busy, lookup;
    const submit = async e => {
      e.preventDefault();
      const body = { mpn: f.mpn.value.trim(), description: f.description.value.trim(), qty: parseInt(f.qty.value, 10) || 0, location: f.location.value.trim(),
        paramsText: f.paramsText.value.trim(), manufacturer: pre.manufacturer || undefined, category: pre.category || undefined, lookup: lookup.checked && !!f.mpn.value.trim(),
        reason: pre.photo ? 'Identified from a photo' : 'Added' };
      if (!body.mpn && !body.description) { toast('Give it a part number or a description.', true); return; }
      if (pre.photo) body.photo = await blobToBase64(pre.photo);
      busy.classList.remove('hidden');
      try {
        const p = await api('POST', '/api/parts', body);
        putPart(p);
        if (body.location) await reloadLocations();
        const used = p.lookup && p.lookup.used || [];
        const errs = p.lookup && p.lookup.errors ? Object.entries(p.lookup.errors) : [];
        toast(`Added ${title(p)}` + (used.length ? ` — filled in from ${[...new Set(used.map(u => u.supplierName))].join(' and ')}.` : '.'));
        if (errs.length) toast('Lookup: ' + errs.map(([k, v]) => `${k}: ${v}`).join('; '), true);
        close(p);
        go('#/parts/' + enc(p.id));
      } catch (x) { fail(x); busy.classList.add('hidden'); }
    };
    append(box, h('form', { onsubmit: submit },
      h('header', {}, h('h3', {}, 'Add a part'), h('p', {}, 'Give the manufacturer’s part number and Digi-Key and Mouser fill in the rest.')),
      h('div', { class: 'body' },
        field('mpn', 'Part number', { mono: true, placeholder: 'LM358DR', autofocus: true }),
        field('description', 'Description', { placeholder: 'Optional if the part number is known' }),
        h('div', { class: 'row' }, h('div', { class: 'grow' }, field('qty', 'Quantity', { type: 'number', min: 0, value: '1' })), h('div', { class: 'grow' }, field('paramsText', 'Parameters', { placeholder: '10k 1% 0603' }))),
        field('location', 'Location', { list: 'loc-paths', placeholder: 'Cabinet A / Drawer 3' }), paths,
        h('label', { class: 'chk' }, lookup = h('input', { type: 'checkbox', checked: true }), 'Look it up at Digi-Key and Mouser'),
        pre.photo && h('div', { class: 'muted' }, icon('photo'), ' The photo is kept with the part.')),
      h('footer', {}, h('span', { class: 'left hidden', ref: el => { busy = el; } }, h('span', { class: 'spinner' }), ' Adding…'),
        h('button', { class: 'btn', type: 'button', onclick: () => close(null) }, 'Cancel'), h('button', { class: 'btn primary', type: 'submit' }, 'Add part'))));
  });
}

// Look a part up at Digi-Key and Mouser and fill it in from the listing chosen.
function lookupDialog(p) {
  return dialog((box, close) => {
    let q, results;
    const run = async () => {
      clear(results).append(h('div', { class: 'muted' }, h('span', { class: 'spinner' }), ' Asking Digi-Key and Mouser…'));
      try {
        const r = await api('GET', `/api/lookup?q=${enc(q.value.trim())}`);
        clear(results);
        for (const [k, v] of Object.entries(r.errors || {})) results.append(h('div', { class: 'err-text' }, `${k}: ${v}`));
        if (!r.results.length) { results.append(h('div', { class: 'muted' }, 'Nothing found.')); return; }
        for (const x of r.results) {
          const price = (x.prices || [])[0];
          const img = safeHref(x.image) ? h('img', { src: x.image, alt: '', referrerpolicy: 'no-referrer' }) : h('div', { class: 'noimg' });
          results.append(h('div', { class: 'lk' }, img,
            h('div', { class: 'grow' },
              h('div', { class: 't' }, x.mpn, ' ', h('span', { class: 'muted' }, x.manufacturer)),
              h('div', { class: 'm' }, x.description || x.detail),
              h('div', { class: 'm num' }, [x.supplierName + ' ' + x.spn, x.package, x.stock != null ? x.stock.toLocaleString() + ' in stock' : '', price ? money(price.unit, price.currency) + ' @ ' + price.qty : ''].filter(Boolean).join(' · '))),
            h('button', { class: 'btn primary small', onclick: async e => {
              e.target.disabled = true;
              try {
                const r2 = await api('POST', `/api/parts/${enc(p.id)}/fill`, { query: q.value.trim(), supplier: x.supplier, spn: x.spn });
                putPart(r2); renderList(); refreshDetail(); toast(`Filled in from ${x.supplierName}.`); close(true);
              } catch (y) { fail(y); e.target.disabled = false; }
            } }, 'Use')));
        }
      } catch (x) { clear(results).append(h('div', { class: 'err-text' }, x.message)); }
    };
    append(box,
      h('header', {}, h('h3', {}, 'Look up online'), h('p', {}, 'Choose a listing: empty fields are filled in from it and its supplier number and prices are kept with the part.')),
      h('div', { class: 'body' },
        h('form', { class: 'row', onsubmit: e => { e.preventDefault(); run(); } },
          q = h('input', { class: 'field mono', value: p.mpn || (p.suppliers || [])[0]?.pn || '', 'aria-label': 'Part number' }), h('button', { class: 'btn', type: 'submit' }, 'Search')),
        results = h('div', { class: 'lookup' })),
      h('footer', {}, h('button', { class: 'btn', onclick: () => close(false) }, 'Close')));
    run();
  }, true);
}

// MARK: Identify

let idState = { file: null, url: null, result: null, busy: false, error: '' };

function renderIdentify() {
  $parts = null;
  clear($main);
  const page = h('div', { class: 'page-inner' });
  append($main, h('div', { class: 'toolbar' }, h('h1', {}, 'Identify')), h('div', { class: 'page' }, page));
  if (S.health && !S.health.identify) {
    page.append(h('div', { class: 'empty' }, icon('identify'), h('h2', {}, 'Photo identify is off'),
      h('p', {}, 'partsd needs a vision model to read a part’s markings: set PARTSD_AI_URL and PARTSD_VISION_MODEL (for example Ollama with qwen2.5vl:7b) and restart it.')));
    return;
  }
  const drop = h('div', { class: 'drop' }, icon('identify'),
    h('div', {}, h('b', {}, 'Drop a photo of a part'), ' — or'),
    h('div', { class: 'row wrap' },
      h('button', { class: 'btn primary', onclick: async () => { const f = await pickFile('image/*'); if (f) identify(f); } }, icon('upload'), 'Choose a photo'),
      h('button', { class: 'btn only-phone', onclick: async () => { const f = await pickFile('image/*', true); if (f) identify(f); } }, icon('identify'), 'Take a photo')),
    h('div', { class: 'faint' }, 'The markings are read by the vision model on the server and matched against the parts catalogue and your inventory. Close-ups of the top, in focus, work best.'));
  drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('over'); const f = e.dataTransfer.files[0]; if (f) identify(f); });
  page.append(drop);
  if (idState.url) page.append(identifyResult());
}

async function identify(file) {
  let blob;
  try { blob = await shrink(file); } catch (e) { return fail(e); }
  if (idState.url) URL.revokeObjectURL(idState.url);
  idState = { file: blob, url: URL.createObjectURL(blob), result: null, busy: true, error: '', started: Date.now() };
  renderIdentify();
  try { idState.result = await api('POST', '/api/identify', blob); }
  catch (e) { idState.error = e.message; }
  idState.busy = false;
  if (route().view === 'identify') renderIdentify();
}

function identifyResult() {
  const right = h('div', { class: 'grid' });
  const wrap = h('div', { class: 'idgrid' }, h('img', { src: idState.url, alt: 'The photo', onclick: () => lightbox(idState.url) }), right);
  if (idState.busy) {
    const t = h('span', { class: 'num' }, '');
    const tick = setInterval(() => { if (!t.isConnected) return clearInterval(tick); t.textContent = Math.round((Date.now() - idState.started) / 1000) + ' s'; }, 500);
    right.append(h('div', { class: 'card' }, h('div', { class: 'r' }, h('span', { class: 'spinner' }), h('span', { class: 'grow' }, 'Reading the markings…'), t)),
      h('p', { class: 'faint' }, 'The first photo after a while can take a minute: the model has to load.'));
    return wrap;
  }
  if (idState.error) { right.append(h('div', { class: 'card' }, h('div', { class: 'r err-text' }, idState.error))); return wrap; }
  const r = idState.result;
  right.append(h('div', { class: 'section' }, h('h4', {}, 'Markings'), h('div', { class: 'card' }, h('div', { class: 'markings' }, r.markings || '(nothing legible)'))));
  if (r.warning) right.append(h('p', { class: 'muted' }, r.warning));
  const cands = r.candidates || [];
  const card = h('div', { class: 'card' });
  if (!cands.length) card.append(h('div', { class: 'r muted' }, 'Nothing recognised. Try a sharper close-up of the markings, or add it by hand.'));
  for (const c of cands) {
    const inv = c.kind === 'inventory' && partById(c.partId);
    const kind = { catalog: 'Built-in list', inventory: 'In your inventory', generic: 'Kind of part', unknown: 'Unknown number', reading: 'AI reading' }[c.kind] || c.kind;
    card.append(h('div', { class: 'cand' },
      h('div', { class: 'top' }, h('span', { class: 'name' }, c.name), h('span', { class: 'conf ' + c.confidence }, c.confidence), h('span', { class: 'kind' }, kind),
        h('span', { class: 'grow' }),
        inv ? h('a', { class: 'btn small', href: '#/parts/' + enc(inv.id) }, `Open (${inv.qty} in stock)`)
          : (c.mpn || c.description) && h('button', { class: 'btn small primary', onclick: () => addPartDialog({ mpn: c.mpn || '', description: c.description || '', manufacturer: c.manufacturer, category: c.category, photo: idState.file }) }, icon('plus'), 'Add to inventory')),
      (c.manufacturer || c.description) && h('div', { class: 'muted' }, [c.manufacturer, c.description].filter(Boolean).join(' · ')),
      c.reasons && c.reasons.length && h('div', { class: 'reasons' }, c.reasons.join(' · ')),
      safeHref(c.datasheet) && h('a', { href: c.datasheet, target: '_blank', rel: 'noopener noreferrer' }, icon('doc'), ' Datasheet')));
  }
  right.append(h('div', { class: 'section' }, h('h4', {}, 'What it could be'), card),
    h('div', { class: 'row' }, h('button', { class: 'btn', onclick: () => addPartDialog({ photo: idState.file }) }, 'Add by hand with this photo')));
  return wrap;
}

// MARK: Locations

function renderLocations(id) {
  $parts = null;
  clear($main);
  const sel = S.locations.find(l => l.id === id);
  const left = h('div', { class: 'left' });
  const right = h('div', { class: 'right' });
  append($main,
    h('div', { class: 'toolbar' },
      sel && h('button', { class: 'btn icon plain back', 'aria-label': 'Back', onclick: () => go('#/locations') }, icon('back')),
      h('h1', {}, 'Locations'), h('span', { class: 'grow' }),
      h('button', { class: 'btn primary', onclick: () => addLocation('') }, icon('plus'), h('span', { class: 'hide-phone' }, 'Add location'))),
    h('div', { class: 'split' + (sel ? ' chosen' : '') }, left, right));

  const kids = new Map();
  for (const l of sortedLocations()) { const k = l.parentId || ''; if (!kids.has(k)) kids.set(k, []); kids.get(k).push(l); }
  for (const list of kids.values()) list.sort((a, b) => sameText(a.name, b.name));
  const tree = parent => {
    const list = kids.get(parent) || [];
    if (!list.length) return null;
    return h('ul', {}, list.map(l => h('li', {},
      h('a', { class: 'node' + (l.id === id ? ' sel' : ''), href: '#/locations/' + enc(l.id) }, icon('location'), h('span', { class: 'ellipsis' }, l.name),
        h('span', { class: 'n muted num' }, l.partsBelow || '')),
      (() => { const t = tree(l.id); if (t) t.style.paddingLeft = '16px'; return t; })())));
  };
  if (!S.locations.length) left.append(h('div', { class: 'empty' }, h('p', {}, 'No locations yet. Add cabinets, drawers and bins, outside in.')));
  else left.append(h('div', { class: 'tree' }, tree('')));

  if (!sel) {
    right.append(h('div', { class: 'empty' }, icon('location'), h('h2', {}, 'Choose a location'),
      h('p', {}, `${plural(S.locations.length, 'location')}. ${S.parts.filter(p => !p.locationId).length} parts aren’t anywhere yet.`)));
    return;
  }
  const here = S.parts.filter(p => p.locationId === sel.id).sort((a, b) => sameText(title(a), title(b)));
  const below = S.parts.filter(p => p.locationId !== sel.id && (p.locationPath || '').startsWith(sel.path + ' › ')).sort((a, b) => sameText(title(a), title(b)));
  const notes = h('textarea', { class: 'bare', rows: 2, placeholder: 'Notes', value: sel.notes || '' });
  notes.addEventListener('change', () => editLocation(sel.id, { notes: notes.value }));
  const parent = h('select', { class: 'field', 'aria-label': 'Inside', onchange: e => editLocation(sel.id, { parentId: e.target.value || null }) },
    h('option', { value: '' }, 'Top level'),
    sortedLocations().filter(l => l.id !== sel.id && !l.path.startsWith(sel.path + ' › ')).map(l => h('option', { value: l.id }, l.path)));
  parent.value = sel.parentId || '';
  const partRow = p => h('a', { class: 'prow', href: '#/parts/' + enc(p.id) },
    h('div', { class: 'thumb' }, p.photoCount ? photoImg(p, 0) : icon(kindIcon(p))),
    h('div', { class: 'grow' }, h('div', { class: 't ellipsis' }, title(p)), h('div', { class: 's muted ellipsis' }, [p.summary, p.description].filter(Boolean).join(' · '))),
    h('div', { class: 'qty' + (p.isLow ? ' low' : '') }, p.qty));
  append(right, h('div', { class: 'pad' },
    h('div', {}, h('div', { class: 'muted' }, sel.path.split(' › ').slice(0, -1).join(' › ') || 'Top level'), h('h2', {}, sel.name)),
    h('div', { class: 'stat' }, h('span', {}, h('b', {}, here.length), 'here'), h('span', {}, h('b', {}, below.length), 'inside')),
    h('div', { class: 'row wrap' },
      h('button', { class: 'btn', onclick: () => addLocation(sel.path.replace(/ › /g, ' / ') + ' / ') }, icon('plus'), 'Add inside'),
      h('button', { class: 'btn', onclick: async () => { const n = await ask('Rename', '', 'Name', sel.name); if (n) editLocation(sel.id, { name: n }); } }, icon('pencil'), 'Rename'),
      h('button', { class: 'btn', onclick: () => { S.filters.location = new Set([sel.path]); go('#/parts'); } }, icon('filter'), 'Show in Parts'),
      h('button', { class: 'btn danger', onclick: async () => {
        if (!(await confirmDialog(`Remove ${sel.name}?`, `Its ${plural(here.length, 'part')} and the places inside it move up to ${sel.path.split(' › ').slice(0, -1).join(' › ') || 'the top level'}.`, 'Remove'))) return;
        try { await api('DELETE', `/api/locations/${enc(sel.id)}`); await loadAll(); toast(`Removed ${sel.name}.`); go('#/locations'); } catch (x) { fail(x); }
      } }, icon('trash'), 'Remove')),
    h('div', { class: 'section' }, h('div', { class: 'card' }, h('div', { class: 'r' }, h('label', {}, 'Inside'), parent), h('div', { class: 'r' }, h('label', {}, 'Notes'), notes))),
    here.length ? h('div', { class: 'section' }, h('h4', {}, 'Here'), h('div', { class: 'card' }, here.map(partRow))) : null,
    below.length ? h('div', { class: 'section' }, h('h4', {}, 'Inside'), h('div', { class: 'card' }, below.map(p => { const r = partRow(p); r.querySelector('.s').textContent = p.locationPath.slice(sel.path.length + 3); return r; }))) : null));
}
async function addLocation(prefix) {
  const path = await ask('Add a location', 'Outside in, with slashes: “Cabinet A / Drawer 3 / Bin 2”. Missing places along the way are made too.', 'Cabinet A / Drawer 3', prefix);
  if (!path) return;
  try { const l = await api('POST', '/api/locations', { path }); await reloadLocations(); renderNav(); go('#/locations/' + enc(l.id)); } catch (x) { fail(x); }
}
async function editLocation(id, fields) {
  try { await api('PATCH', `/api/locations/${enc(id)}`, fields); await loadAll(); renderNav(); render(); toast('Saved.'); } catch (x) { fail(x); }
}

// MARK: Projects

let projectsCache = null;
async function renderProjects(id) {
  $parts = null;
  clear($main);
  const left = h('div', { class: 'left' }), right = h('div', { class: 'right' });
  append($main, h('div', { class: 'toolbar' },
    id && h('button', { class: 'btn icon plain back', 'aria-label': 'Back', onclick: () => go('#/projects') }, icon('back')),
    h('h1', {}, 'Projects')), h('div', { class: 'split' + (id ? ' chosen' : '') }, left, right));
  try { projectsCache = (await api('GET', '/api/projects')).projects; } catch (x) { return fail(x); }
  if (!projectsCache.length) {
    clear($main.querySelector('.split')).append(h('div', { class: 'empty' }, icon('project'), h('h2', {}, 'No projects'),
      h('p', {}, 'Projects are BOMs (KiCad, CSV) imported in the Mac or iPhone app; they come across with a backup. Here you can see what you can build from what’s in stock.')));
    $main.querySelector('.split').style.display = 'block';
    return;
  }
  left.append(h('div', { class: 'tree' }, projectsCache.map(p => h('a', { class: 'node' + (p.id === id ? ' sel' : ''), href: '#/projects/' + enc(p.id) }, icon('project'),
    h('div', { class: 'grow' }, h('div', { class: 'ellipsis' }, p.name), h('div', { class: 'muted' }, `${plural(p.lineCount, 'line')} · enough for ${p.canBuild}`))))));
  if (!id) { right.append(h('div', { class: 'empty' }, icon('project'), h('h2', {}, 'Choose a project'))); return; }
  let pr;
  try { pr = await api('GET', `/api/projects/${enc(id)}`); } catch (x) { return fail(x); }
  const rows = pr.lines.map(l => h('tr', { class: (l.partId ? 'click' : '') + (l.need > l.have ? ' short' : ''), onclick: l.partId ? () => go('#/parts/' + enc(l.partId)) : null },
    h('td', { title: l.refs.join(', ') }, l.refs.join(', ')), h('td', {}, l.value), h('td', { class: 'muted' }, l.footprint), h('td', { class: 'mono' }, l.partMpn || l.mpn),
    h('td', { class: 'muted' }, l.location), h('td', { class: 'r num' }, l.dnp ? 'DNP' : l.need), h('td', { class: 'r num' + (l.need > l.have ? ' low' : '') }, l.have)));
  append(right, h('div', { class: 'pad' },
    h('h2', {}, pr.name),
    h('div', { class: 'stat' }, h('span', {}, h('b', {}, pr.boards), 'boards planned'), h('span', {}, h('b', {}, pr.canBuild), 'can be built'), h('span', {}, h('b', {}, pr.short), 'lines short')),
    pr.notes && h('p', { class: 'muted' }, pr.notes),
    h('div', { class: 'card' }, h('table', { class: 'grid' },
      h('thead', {}, h('tr', {}, ['Refs', 'Value', 'Footprint', 'Part', 'Location', 'Need', 'Have'].map((t, i) => h('th', { class: i > 4 ? 'r' : '' }, t)))),
      h('tbody', {}, rows)))));
}

// MARK: Settings

function renderSettings() {
  $parts = null;
  clear($main);
  const base = location.origin;
  const cmd = `claude mcp add --transport http parts-inventory ${base}/mcp --header "Authorization: Bearer ${token}"`;
  let shown = false, tokenEl, importInput;
  const theme = h('select', { class: 'field', onchange: e => { store.set('theme', e.target.value || null); applyTheme(); } },
    h('option', { value: '' }, 'Match the system'), h('option', { value: 'light' }, 'Light'), h('option', { value: 'dark' }, 'Dark'));
  theme.value = store.get('theme') || '';
  const exportBackup = async photos => {
    try {
      const r = await api('GET', `/api/export${photos ? '?photos=true' : ''}`, undefined, true);
      download(await r.blob(), `parts-inventory-${new Date().toISOString().slice(0, 10)}.json`);
    } catch (x) { fail(x); }
  };
  const importBackup = async () => {
    const f = importInput.files[0];
    importInput.value = '';
    if (!f) return;
    if (!(await confirmDialog(`Import ${f.name}?`, 'Parts, locations, projects and photos from the backup are merged in: new ones are added and newer copies replace older ones. Nothing here is deleted.', 'Import'))) return;
    try {
      const r = await api('POST', '/api/import', new Blob([await f.arrayBuffer()], { type: 'application/json' }));
      await loadAll(); renderNav();
      toast(`Imported: ${r.added} added, ${r.updated} updated, ${r.kept} kept, ${plural(r.photos, 'photo')}.`);
      for (const w of r.warnings || []) toast(w, true);
    } catch (x) { fail(x); }
  };
  const r = (label, ...kids) => h('div', { class: 'r' }, h('label', {}, label), ...kids);
  append($main, h('div', { class: 'toolbar' }, h('h1', {}, 'Settings')), h('div', { class: 'page' }, h('div', { class: 'page-inner' },
    h('div', { class: 'section' }, h('h4', {}, 'Server'), h('div', { class: 'card' },
      r('Address', h('span', { class: 'mono grow' }, base)),
      r('Version', h('span', { class: 'grow' }, `partsd ${S.health?.version || ''}`)),
      r('Inventory', h('span', { class: 'grow' }, `${plural(S.parts.length, 'part')}, ${plural(S.locations.length, 'location')}`)),
      r('Photo identify', h('span', { class: 'grow' }, S.health?.identify ? 'On — a vision model reads the markings' : 'Off (set PARTSD_AI_URL and PARTSD_VISION_MODEL)')))),
    h('div', { class: 'section' }, h('h4', {}, 'Backup'), h('div', { class: 'card' },
      h('div', { class: 'r' }, h('div', { class: 'grow muted' }, 'The same JSON backup as the Mac and iPhone app and the web version: export from one, import into another.')),
      h('div', { class: 'r' },
        h('button', { class: 'btn', onclick: () => exportBackup(true) }, icon('download'), 'Export with photos'),
        h('button', { class: 'btn', onclick: () => exportBackup(false) }, 'Without photos'),
        h('span', { class: 'grow' }),
        h('button', { class: 'btn', onclick: () => importInput.click() }, icon('upload'), 'Import a backup…'),
        importInput = h('input', { type: 'file', accept: 'application/json,.json', class: 'hidden', onchange: importBackup })))),
    h('div', { class: 'section' }, h('h4', {}, 'Claude and other AI tools (MCP)'), h('div', { class: 'card' },
      h('div', { class: 'r' }, h('div', { class: 'grow muted' }, 'Give Claude Code the inventory’s tools — search, add, adjust stock, identify photos:')),
      h('div', { class: 'r' }, h('code', { class: 'code grow' }, cmd.replace(token, '••••••••')), h('button', { class: 'btn small', onclick: () => copy(cmd) }, icon('copy'), 'Copy')),
      h('div', { class: 'r' }, h('div', { class: 'grow muted' }, 'REST API: ', h('a', { href: '/api/openapi.json', target: '_blank' }, '/api/openapi.json'), ' — send the token as “Authorization: Bearer …”.')))),
    h('div', { class: 'section' }, h('h4', {}, 'This browser'), h('div', { class: 'card' },
      r('Appearance', theme),
      r('API token', tokenEl = h('code', { class: 'code grow' }, '••••••••'),
        h('button', { class: 'btn small', onclick: e => { shown = !shown; tokenEl.textContent = shown ? token : '••••••••'; e.target.textContent = shown ? 'Hide' : 'Show'; } }, 'Show'),
        h('button', { class: 'btn small', onclick: () => copy(token) }, icon('copy'))),
      h('div', { class: 'r' }, h('span', { class: 'grow muted' }, 'Signing out forgets the token here; the server and other devices are unaffected.'),
        h('button', { class: 'btn danger', onclick: () => signOut() }, icon('logout'), 'Sign out')))))));
}

function applyTheme() {
  const t = store.get('theme');
  if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
}

// MARK: Start

async function refresh(manual) {
  const was = detailFor && partById(detailFor);
  const before = was ? JSON.stringify([was.updated, was.qty, was.photoIds]) : '';
  try { await loadAll(); } catch (e) { if (manual) fail(e); return; }
  const r = route();
  renderNav();
  if (r.view === 'parts' && $parts && $parts.isConnected) {
    renderFacets(); renderList();
    // Show a change made elsewhere (MCP, another browser) to the part on show, unless it's being edited here.
    const now = detailFor && partById(detailFor);
    if (detailFor && !now) go('#/parts');
    else if (now && JSON.stringify([now.updated, now.qty, now.photoIds]) !== before && !$detail.contains(document.activeElement)) refreshDetail();
  } else if (r.view === 'locations') render();
  if (manual) toast('Up to date.');
}

async function start() {
  // A link with the token (#token=…) signs this browser in, then drops it from the address bar.
  const m = location.hash.match(/^#token=([^&]+)/);
  if (m) { token = decodeURIComponent(m[1]); store.set('token', token); history.replaceState(null, '', location.pathname + '#/parts'); }
  applyTheme();
  if (!token) return renderSignIn();
  clear($app).append(h('div', { class: 'signin' }, h('div', { class: 'muted' }, h('span', { class: 'spinner' }), ' Loading the inventory…')));
  try { await loadAll(); }
  catch (e) { if (e.status !== 401) { clear($app).append(h('div', { class: 'signin' }, h('div', { class: 'card' }, h('h1', {}, 'Can’t load the inventory'), h('p', {}, e.message), h('button', { class: 'btn primary', onclick: start }, 'Try again')))); } return; }
  $main = null;
  render();
}

window.addEventListener('hashchange', () => { if (token) render(); });
window.addEventListener('focus', () => { if (token && Date.now() - S.loadedAt > 15000) refresh(); });
setInterval(() => { if (token && document.visibilityState === 'visible' && !document.querySelector('.scrim') && Date.now() - S.loadedAt > 60000) refresh(); }, 15000);
let lastWidth = window.innerWidth;
window.addEventListener('resize', debounce(() => { if ((lastWidth > 760) !== (window.innerWidth > 760) && route().view === 'parts' && $list) renderList(); lastWidth = window.innerWidth; }, 150));
start();
