// Kiosk Fleet Web - the page. Everything it shows comes from the server
// (kfw, the Python app); everything it does goes back there, where the role
// is checked again. Nothing from the server is ever put into the page as
// HTML: text goes in as text.
'use strict';

const S = {
  me: null,
  fleet: null,
  live: null,
  stamp: '',
  view: 'Overview',
  selected: null,
  filter: '',
  onlyProblems: false,
  location: '',
  picks: new Set(),
  history: { host: null, days: 28, data: null, loading: false, error: '', seq: 0 },
  klist: { data: null, filter: '', show: 'all' },
  screens: { list: [], loaded: false, tab: '', location: '', filter: '', only: false, size: 'M', auto: 0, lastAuto: 0, taking: false, timer: null, sig: '' },
  sort: { key: null, dir: 1 },
  screenChoice: {},
  run: { from: 0, text: '', serial: null, timer: null },
  reports: [],
  audit: [],
  auditFilter: '',
  users: [],
  settings: null,
  pollTimer: null,
  toastTimer: null,
  modal: null
};

const NAMES = { NG: 'Mach2 Launcher NG', PBI: 'PBI Launcher', WEB: 'Web Launcher' };
const TAB_KIND = { Mach2: 'NG', PBI: 'PBI', Web: 'WEB' };
const TAB_TITLE = { Mach2: 'Mach2 kiosks', PBI: 'Power BI screens', Web: 'Web page screens', Other: 'Other kiosks' };

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (k === 'style') Object.assign(e.style, v);
      else if (k in e && typeof v !== 'string') e[k] = v;
      else e.setAttribute(k, v === true ? '' : v);
    }
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid === null || kid === undefined || kid === false) continue;
    e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return e;
}
const $ = (sel, root) => (root || document).querySelector(sel);
// replaceChildren, but nested lists are spread and nothing (null, false)
// stays nothing instead of turning into the text "null".
function setKids(node, ...kids) {
  node.replaceChildren(...kids.flat(Infinity).filter((k) => k !== null && k !== undefined && k !== false));
}
const can = (what) => !!(S.me && S.me.allowed && S.me.allowed.includes(what));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const plural = (n, one, many) => (n === 1 ? one : many);
const spinner = (cls) => el('span', { class: 'spinner' + (cls ? ' ' + cls : ''), 'aria-hidden': 'true' });
// The logo's iris as text: cols x rows characters (one is about twice as
// tall as wide), turned by `turn` radians, its opening from 0 to 1. Its
// blades are bounded by lines tangent to the opening, so each boundary
// turns with the distance; each blade is shaded from its edge across.
// (tools/make_logo.py draws the same iris in pixels.)
const IRIS_RAMP = '@@%%##**++=';
function irisText(cols, rows, turn, open) {
  const N = 6, hole = 0.18 + 0.4 * open, sector = (2 * Math.PI) / N;
  const lines = [];
  for (let r = 0; r < rows; r++) {
    let line = '';
    for (let c = 0; c < cols; c++) {
      const x = ((c + 0.5) / cols) * 2 - 1, y = ((r + 0.5) / rows) * 2 - 1;
      const d = Math.hypot(x, y);
      if (d > 1 || d < hole) { line += ' '; continue; }
      const phi = Math.atan2(y, x) + Math.acos(hole / d) - turn;
      const u = (((phi % sector) + sector) % sector) / sector;
      const gap = 0.07 / Math.max(d, 0.3);
      line += u < gap ? ' ' : IRIS_RAMP[Math.min(IRIS_RAMP.length - 1, Math.floor(((u - gap) / (1 - gap)) * IRIS_RAMP.length))];
    }
    lines.push(line);
  }
  return lines.join('\n');
}

// An iris on the page; `live` ones turn and breathe, all of them on one
// timer that stops by itself once none is left on the page.
const Iris = { timer: null, t: 0, still: false };
try { Iris.still = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { /* moves, then */ }
function irisPre(cols, rows, live, cls) {
  const pre = el('pre', { class: 'iris' + (cls ? ' ' + cls : ''), 'aria-hidden': 'true', text: irisText(cols, rows, 0.5, 0.5) });
  pre.dataset.cols = cols; pre.dataset.rows = rows;
  setIrisLive(pre, live);
  return pre;
}
function setIrisLive(pre, live) {
  if (live) pre.dataset.live = '1'; else delete pre.dataset.live;
  if (live && !Iris.timer && !Iris.still) Iris.timer = setInterval(irisTick, 90);
}
function irisTick() {
  const live = document.querySelectorAll('pre.iris[data-live]');
  if (!live.length) { clearInterval(Iris.timer); Iris.timer = null; return; }
  Iris.t++;
  const turn = 0.5 + Iris.t * 0.07, open = 0.45 + 0.35 * Math.sin(Iris.t * 0.05);
  for (const pre of live) pre.textContent = irisText(+pre.dataset.cols, +pre.dataset.rows, turn, open);
}

// What a view shows while it waits for its data: the iris turning, what
// it is waiting for, and grey lines where the content will be.
function loadingCard(text, attrs) {
  return el('div', Object.assign({ class: 'card loadingcard', role: 'status' }, attrs || {}),
    irisPre(22, 13, true, 'mini'),
    el('div', { class: 'lc-body' },
      el('div', { class: 'lc-head' }, el('span', { text })),
      el('div', { class: 'skel', 'aria-hidden': 'true' }, el('i'), el('i'), el('i'))));
}
// The thin bar along the top of the page: on while anything the person
// asked for is under way (a request, or a job on a kiosk being followed).
const Work = { n: 0 };
function working(delta) {
  Work.n = Math.max(0, Work.n + delta);
  document.body.classList.toggle('working', Work.n > 0);
}

class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

async function api(method, path, body) {
  const opts = { method, credentials: 'same-origin', headers: {} };
  if (method !== 'GET') {
    if (S.me && S.me.csrf) opts.headers['X-Fleet-Csrf'] = S.me.csrf;
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
  }
  let res;
  const quiet = method === 'GET' && (path.startsWith('/api/state') || path.startsWith('/api/jobs/'));
  if (!quiet) working(1);
  try { res = await fetch(path, opts); }
  catch (e) { throw new ApiError(0, 'The server does not answer.'); }
  finally { if (!quiet) working(-1); }
  let data = null;
  const type = res.headers.get('Content-Type') || '';
  if (type.includes('application/json')) { try { data = await res.json(); } catch (e) { data = null; } }
  if (res.status === 401 && path !== '/api/me' && path !== '/api/login' && path !== '/api/setup' && path !== '/api/me/password') {
    signedOut('You have been signed out.');
    throw new ApiError(401, 'Signed out.');
  }
  if (!res.ok) throw new ApiError(res.status, (data && data.error) || ('HTTP ' + res.status));
  return data;
}

function toast(text, sev, seconds) {
  let t = $('#toast');
  if (!t) { t = el('div', { id: 'toast', role: 'status' }); document.body.append(t); }
  t.className = 'toast ' + (sev || '');
  // BUSY stays up, with a spinner, until the outcome replaces it.
  if (sev === 'BUSY') setKids(t, spinner(), el('span', { text }));
  else setKids(t, el('span', { class: 'ticon', 'aria-hidden': 'true', 'data-icon': { OK: 'check', WARNING: 'alert', CRITICAL: 'error' }[sev] || 'info' }), el('span', { text }));
  t.classList.remove('hidden');
  clearTimeout(S.toastTimer);
  if (sev !== 'BUSY') S.toastTimer = setTimeout(() => t.classList.add('hidden'), (seconds || 6) * 1000);
}

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied.', 'OK', 3); }
  catch (e) { toast('Could not copy - select it and copy by hand.', 'WARNING'); }
}

function pill(status, sev) { return el('span', { class: 'pill ' + (sev || 'UNKNOWN'), text: status || '' }); }

// ---------------------------------------------------------------------------
// Signing in and out
// ---------------------------------------------------------------------------
async function start() {
  let r, d = null;
  try {
    r = await fetch('/api/me', { credentials: 'same-origin' });
    d = await r.json().catch(() => null);
  } catch (e) { $('#app').textContent = 'The server does not answer.'; return; }
  const token = new URLSearchParams(location.search).get('token');
  if (r.status === 401 && d && d.setup && location.pathname === '/setup' && token) return renderSetup(token);
  // Signed out, /api/me answers 401 with how to sign in.
  if (r.status === 401) return renderLogin('', d);
  if (!r.ok || !d) { $('#app').textContent = (d && d.error) || ('HTTP ' + r.status); return; }
  S.me = d;
  enter();
}

// Into the app - or, for an account whose password was set by an admin,
// first a new password of its own.
function enter() {
  if (location.pathname === '/setup') history.replaceState(null, '', '/');
  if (S.me && S.me.mustChange) return renderForcedPassword();
  boot();
}

function loginFrame(title, sub, card) {
  const app = $('#app');
  app.className = '';
  setKids(app, el('div', { class: 'login' }, el('div', { class: 'logo big', 'aria-hidden': 'true' }), el('h1', { class: 'term', text: title }), el('div', { class: 'dim', text: sub }), card));
}

async function renderLogin(message, known) {
  stopPolling();
  closeModal();
  let info = known;
  if (!info) { try { info = await (await fetch('/api/me', { credentials: 'same-origin' })).json(); } catch (e) { info = {}; } }
  const note = el('div', { class: 'note sev-CRITICAL', role: 'alert', text: message || '' });
  const user = el('input', { type: 'text', autocomplete: 'username', required: true, maxLength: 64 });
  const pass = el('input', { type: 'password', autocomplete: 'current-password', required: true, maxLength: 256 });
  const go = el('button', { class: 'btn primary', type: 'submit', text: 'Sign in' });
  const form = el('form', null,
    el('label', null, el('span', { class: 'lbl', text: 'Account' }), user),
    el('label', null, el('span', { class: 'lbl', text: 'Password' }), pass),
    el('div', { style: { marginTop: '14px' } }, go));
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    go.disabled = true;
    note.textContent = '';
    try {
      S.me = await api('POST', '/api/login', { user: user.value, password: pass.value });
      pass.value = '';
      enter();
    } catch (e) { note.textContent = e.message; go.disabled = false; pass.select(); }
  });
  const card = el('div', { class: 'card' }, form);
  if (info && info.setup) card.append(el('p', { class: 'hint', text: 'No accounts yet: open the setup link from the server\'s log to make the first admin.' }));
  if (info && info.insecure) card.append(el('p', { class: 'hint sev-WARNING', text: 'This connection is not encrypted: your password crosses the network as typed. Ask for the https:// address.' }));
  card.append(note);
  loginFrame('Kiosk Fleet', (info && info.site) || 'Every kiosk screen, and what can be done to it.', card);
  setTimeout(() => user.focus(), 0);
}

function passwordForm(o) {
  const note = el('div', { class: 'note sev-CRITICAL', role: 'alert' });
  const inputs = {};
  const field = (key, label, type, auto) => {
    inputs[key] = el('input', { type, autocomplete: auto, required: true, maxLength: key === 'user' ? 64 : 256 });
    return el('label', null, el('span', { class: 'lbl', text: label }), inputs[key]);
  };
  const go = el('button', { class: 'btn primary', type: 'submit', text: o.okText });
  const form = el('form', null, o.fields.map((f) => field(...f)),
    el('p', { class: 'hint', text: 'At least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more.' }),
    el('div', { style: { marginTop: '14px' } }, go), note);
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    go.disabled = true;
    note.textContent = '';
    const v = {};
    for (const [k, i] of Object.entries(inputs)) v[k] = i.value;
    try { await o.onOk(v); }
    catch (e) { note.textContent = e.message; go.disabled = false; }
  });
  setTimeout(() => Object.values(inputs)[0].focus(), 0);
  return el('div', { class: 'card' }, form);
}

function renderSetup(token) {
  loginFrame('Kiosk Fleet - first start', 'Make the first admin account. More accounts are added in Users afterwards.', passwordForm({
    okText: 'Make the account',
    fields: [['user', 'Account name', 'text', 'username'], ['password', 'Password', 'password', 'new-password'], ['password2', 'Password again', 'password', 'new-password']],
    onOk: async (v) => {
      if (v.password !== v.password2) throw new Error('The two passwords did not match.');
      S.me = await api('POST', '/api/setup', { token, user: v.user, password: v.password, password2: v.password2 });
      enter();
    }
  }));
}

function renderForcedPassword() {
  stopPolling();
  loginFrame('New password', `${S.me.user}: your password was set by an admin. Choose your own before you carry on.`, passwordForm({
    okText: 'Change it',
    fields: [['current', 'Current password', 'password', 'current-password'], ['password', 'New password', 'password', 'new-password'], ['password2', 'New password again', 'password', 'new-password']],
    onOk: async (v) => {
      if (v.password !== v.password2) throw new Error('The two new passwords did not match.');
      await api('POST', '/api/me/password', v);
      S.me = await api('GET', '/api/me');
      enter();
    }
  }));
}

function signedOut(message) {
  S.me = null;
  renderLogin(message);
}

async function signOut() {
  try { await api('POST', '/api/logout'); } catch (e) { /* signed out either way */ }
  signedOut('Signed out.');
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------
function boot() {
  const app = $('#app');
  app.className = '';
  setKids(app, 
    el('div', { class: 'shell' },
      el('header', { class: 'top', id: 'top' }),
      el('div', { class: 'banners', id: 'banners' }),
      el('nav', { class: 'nav', id: 'nav', 'aria-label': 'Views' }),
      el('main', { class: 'main', id: 'main' })));
  S.fleet = null;
  S.stamp = '';
  poll();
}

function stopPolling() {
  clearTimeout(S.pollTimer);
  clearTimeout(S.run.timer);
  S.pollTimer = null;
}

async function poll() {
  clearTimeout(S.pollTimer);
  if (!S.me) return;
  try {
    const data = await api('GET', '/api/state?since=' + encodeURIComponent(S.stamp));
    const changed = !!data.fleet;
    if (data.fleet) S.fleet = data.fleet;
    S.live = data.live;
    S.stamp = data.live.stamp;
    renderTop();
    renderBanners();
    renderNav();
    renderView(changed);
  } catch (e) {
    if (e.status === 401) return;
    if (e.status === 428) { S.me.mustChange = true; return renderForcedPassword(); }
    toast(e.message, 'CRITICAL', 4);
  }
  S.pollTimer = setTimeout(poll, S.live && S.live.run ? 2000 : 5000);
}

function refreshSoon() {
  clearTimeout(S.pollTimer);
  S.pollTimer = setTimeout(poll, 300);
}

function renderTop() {
  const top = $('#top');
  if (!top) return;
  const f = S.fleet, L = S.live;
  let head;
  if (!f || !f.Ok) head = el('span', { class: 'headline warn' }, el('span', { class: 'dot' }), 'NO DATA');
  else if (f.Attention === 0) head = el('span', { class: 'headline ok' }, el('span', { class: 'dot' }), `ALL ${f.Total} KIOSKS OK`);
  else head = el('span', { class: 'headline crit' }, el('span', { class: 'dot' }), `${f.Attention} KIOSK${f.Attention === 1 ? ' NEEDS' : 'S NEED'} ATTENTION`);

  const fresh = el('span', { class: 'fresh' + (L.fresh.stale ? ' stale' : ''), text: f && !f.Ok ? f.Error : L.fresh.text });
  const kids = [el('span', { class: 'brand' }, el('span', { class: 'logo', 'aria-hidden': 'true' }), el('span', { class: 'term', text: 'KIOSK FLEET' })), head, fresh, el('span', { class: 'spacer' })];

  if (L.run && L.run.kind === 'scan') {
    const bar = el('span', { class: 'bar' }, el('i', { style: { width: (L.run.scan ? L.run.scan.pct : 0) + '%' } }));
    kids.push(el('span', { class: 'scanbar', title: 'started by ' + L.run.who }, 'scanning', bar, (L.run.scan ? L.run.scan.text : '') + '  ' + L.run.elapsed));
  }
  if (can('scan')) {
    kids.push(el('button', { class: 'btn small', type: 'button', text: 'Scan now', disabled: !!L.run, title: 'Run the collector once', onclick: scanNow }));
  }
  const auto = L.autoscan;
  if (can('autoscan')) {
    kids.push(el('button', {
      class: 'btn small' + (auto.on ? ' on' : ''), type: 'button',
      text: auto.on ? `Auto-scan: every ${auto.minutes} min, next in ${auto.nextIn}` : 'Auto-scan: off',
      title: 'Keep the data fresh from this server, as the scheduled collector would', onclick: toggleAutoScan
    }));
  } else if (auto.on) {
    kids.push(el('span', { class: 'fresh', text: `auto-scan every ${auto.minutes} min` }));
  }
  kids.push(el('span', { class: 'clock', text: L.clock }));
  kids.push(el('span', { class: 'who' }, el('span', { class: 'avatar', 'aria-hidden': 'true', text: (S.me.user || '?').slice(0, 1).toUpperCase() }), S.me.user, el('span', { class: 'role ' + S.me.role, text: S.me.role }),
    el('button', { class: 'btn small', type: 'button', text: 'Password', title: 'Change your password', onclick: changePasswordDialog }),
    el('button', { class: 'btn small', type: 'button', text: 'Sign out', onclick: signOut })));
  setKids(top, ...kids);
}

function renderBanners() {
  const b = $('#banners');
  if (!b) return;
  const kids = [];
  if (S.me.insecure) kids.push(el('div', { class: 'banner warn', text: 'This connection is not encrypted (HTTP). Put the server behind an HTTPS reverse proxy, then use the https:// address.' }));
  if (S.live && !S.live.credential.ok && S.live.credential.note) kids.push(el('div', { class: 'banner crit', text: 'The server cannot reach kiosks: ' + S.live.credential.note }));
  if (S.live && !S.live.kioskList) {
    kids.push(el('div', { class: 'banner warn' }, 'There is no kiosk list yet, so there is nothing to scan. ',
      can('settings') ? el('button', { class: 'btn small', type: 'button', text: 'Upload one in Settings', onclick: () => show('Settings') }) : 'Ask an admin to upload one.'));
  }
  setKids(b, ...kids);
}

function tabKiosks(tab) {
  if (!S.fleet || !S.fleet.Ok) return [];
  return S.fleet.Kiosks.filter((k) => k.Tab === tab || (k.Tabs || []).includes(tab));
}

function renderNav() {
  const nav = $('#nav');
  if (!nav) return;
  const f = S.fleet;
  const tabs = f && f.Ok ? f.Tabs : {};
  const item = (id, label, badge, cls) => el('button', {
    type: 'button', class: S.view === id ? 'on' : '', 'aria-current': S.view === id ? 'page' : null,
    'data-icon': id, onclick: () => show(id)
  }, el('span', { class: 'lab', text: label }), badge ? el('span', { class: 'badge' + (cls ? ' ' + cls : ''), text: String(badge) }) : null);

  const kids = [item('Overview', 'Overview')];
  kids.push(item('Mach2', 'Mach2', tabs.Mach2 && tabs.Mach2.Attention));
  kids.push(item('PBI', 'Power BI', tabs.PBI && tabs.PBI.Attention));
  if ((tabs.Web && tabs.Web.Count) || S.view === 'Web') kids.push(item('Web', 'Web pages', tabs.Web && tabs.Web.Attention));
  if ((tabs.Other && tabs.Other.Count) || S.view === 'Other') kids.push(item('Other', 'Other', tabs.Other && tabs.Other.Attention));
  kids.push(item('Screens', 'Screens'));
  kids.push(item('History', 'History'));
  kids.push(el('hr'));
  kids.push(item('Activity', 'Activity', S.live && S.live.run ? (S.live.run.kind === 'scan' ? 'scanning' : 'running') : null, 'run'));
  if (can('audit')) kids.push(item('Audit', 'Audit log'));
  if (can('users') || can('settings')) kids.push(el('hr'));
  if (can('kiosklist')) kids.push(item('KioskList', 'Kiosk list'));
  if (can('users')) kids.push(item('Users', 'Users'));
  if (can('settings')) kids.push(item('Settings', 'Settings'));
  kids.push(el('div', { class: 'ver', text: 'Kiosk Fleet Web ' + (S.me.version || '') }));
  setKids(nav, ...kids);
}

function show(view, host) {
  const changedView = S.view !== view;
  S.view = view;
  if (host !== undefined) S.selected = host;
  if (changedView && ['Mach2', 'PBI', 'Web', 'Other'].includes(view)) { S.sort = { key: null, dir: 1 }; S.location = ''; S.picks.clear(); }
  renderNav();
  renderView(true, changedView);
  if (view === 'Activity') { loadReports(); pollRun(); }
  if (view === 'Audit') loadAudit();
  if (view === 'Users') loadUsers();
  if (view === 'Settings') loadSettings();
  if (view === 'History') loadHistory();
  if (view === 'Screens') { loadScreensPrefs(); loadScreens(); }
  if (view === 'KioskList') loadKioskList();
}

// The views keep their inputs between redraws (a filter being typed must
// not lose its caret every five seconds), so each is built once and then
// only its moving parts are redrawn.
function renderView(dataChanged, fresh) {
  const main = $('#main');
  if (!main || !S.live) return;
  if (main.dataset.view !== S.view || fresh) {
    main.dataset.view = S.view;
    setKids(main);
    main.scrollTop = 0;
    main.classList.add('enter');
    clearTimeout(S.enterTimer);
    S.enterTimer = setTimeout(() => main.classList.remove('enter'), 900);
    dataChanged = true;
  }
  switch (S.view) {
    case 'Overview': return renderOverview(main);
    case 'Mach2': case 'PBI': case 'Web': case 'Other': return renderKiosks(main);
    case 'Activity': return renderActivity(main);
    case 'Audit': return renderAudit(main);
    case 'Users': return renderUsers(main);
    case 'Settings': return renderSettings(main);
    case 'History': return renderHistory(main, dataChanged);
    case 'Screens': return renderScreens(main);
    case 'KioskList': return renderKioskList(main);
  }
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------
function renderOverview(main) {
  const f = S.fleet;
  if (!f || !f.Ok) {
    setKids(main, el('h2', { text: 'Overview' }), f ? el('div', { class: 'card empty', text: f.Error }) : loadingCard('Reading the fleet ...'));
    return;
  }
  const stat = (label, n, note, sev, icon) => el('div', { class: 'card stat' + (sev ? ' tone-' + sev : ''), 'data-icon': icon },
    el('div', { class: 'l', text: label }), el('div', { class: 'n' + (sev ? ' sev-' + sev : ''), text: String(n) }), el('div', { class: 'note', text: note }));
  const web = f.Tabs.Web.Count;
  const stats = el('div', { class: 'stats' },
    stat('KIOSKS', f.Total, `${f.Tabs.Mach2.Count} Mach2, ${f.Tabs.PBI.Count} Power BI${web ? `, ${web} web page` : ''}${f.Inactive ? `, ${f.Inactive} not watched` : ''}`, '', 'Mach2'),
    stat('NEED ATTENTION', f.Attention, f.Attention ? `${f.Critical} critical` : 'nothing to do', f.Attention ? 'CRITICAL' : 'OK', f.Attention ? 'alert' : 'check'),
    stat('REBOOTS 24H', f.Reboots24, f.Script24 ? `${f.Script24} by the watchdog` : 'none by the watchdog', '', 'reboot'),
    stat('SCREEN EVENTS 24H', f.Episodes24, 'white or blank screens', '', 'Screens'),
    stat('NEW LAUNCHERS', f.Launchers.Ng + f.Launchers.Pbi + f.Launchers.Web, `${f.Launchers.Ng} Mach2 NG, ${f.Launchers.Pbi} PBI Launcher${f.Launchers.Web ? `, ${f.Launchers.Web} Web Launcher` : ''}`, '', 'launcher'));

  const attention = f.Kiosks.filter((k) => k.Attention);
  let att;
  if (!attention.length) att = el('div', { class: 'card empty sev-OK', text: 'Every kiosk is fine.' });
  else {
    att = el('div', { class: 'tablewrap' }, el('table', null,
      el('thead', null, el('tr', null, ['KIOSK', 'LOCATION', 'TYPE', 'STATUS', 'LAUNCHER', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
      el('tbody', null, attention.map((k) => {
        const lv = k.Launchers[k.Tab] || k.Launchers.Other;
        return el('tr', { onclick: () => show(k.Tab, k.Host), title: 'Open ' + k.Host },
          el('td', { class: 'host', text: k.Host }), el('td', { text: k.Location }), el('td', { text: k.Type }),
          el('td', null, pill(k.Status, k.Severity)), el('td', { class: 'sev-' + lv.Severity, text: lv.State }),
          el('td', { class: 'dim', text: k.Note, title: k.Note }));
      }))));
  }

  const max = Math.max(1, ...f.Chart.map((d) => d.Count));
  const chart = el('div', { class: 'chart', role: 'img', 'aria-label': 'Reboots per day, last seven days' },
    f.Chart.map((d) => el('div', { class: 'col', title: `${d.Long}: ${d.Count} reboot(s)` },
      el('span', { class: 'c', text: d.Count ? String(d.Count) : '' }),
      el('div', { class: 'bar', style: { height: Math.max(2, Math.round(90 * d.Count / max)) + 'px' } }),
      el('span', { class: 'd', text: d.Label }))));

  const c = f.Collector;
  const kv = (k, v, cls) => [el('div', { class: 'k', text: k }), el('div', { class: 'v' + (cls ? ' ' + cls : ''), text: v })];
  const collector = el('div', { class: 'kv' },
    kv('Last scan', S.live.fresh.lastRun, S.live.fresh.stale ? 'sev-CRITICAL' : ''),
    c ? [kv('Took', c.Took + 's'), kv('Reached', `${c.Reachable} of ${c.Hosts} kiosks`), kv('New events', String(c.NewEvents)), kv('Collector', 'v' + c.Version), kv('Ran as', c.Runner, 'dim')] : null,
    kv('Events file', f.File, 'dim'), kv('Rows', String(f.RowCount), 'dim'));

  setKids(main, 
    el('h2', { text: 'Overview' }),
    el('p', { class: 'sub', text: 'Everything needing attention first. The tables are as of the last scan; Read live on a kiosk reads it now.' }),
    stats,
    el('div', { class: 'ov' },
      el('div', null, el('h3', { text: 'NEEDS ATTENTION' }), att),
      el('div', null,
        el('h3', { text: 'REBOOTS, LAST 7 DAYS' }), el('div', { class: 'card' }, chart),
        el('h3', { text: 'COLLECTION' }), el('div', { class: 'card' }, collector))));
}

// ---------------------------------------------------------------------------
// The kiosk tabs
// ---------------------------------------------------------------------------
const COLS = {
  host: { h: 'KIOSK', v: (k) => k.Host, cls: 'host' },
  type: { h: 'TYPE', v: (k) => k.Type },
  location: { h: 'LOCATION', v: (k) => k.Location },
  status: { h: 'STATUS', v: (k) => k.Status, sortv: (k) => k.Rank, cell: (k) => pill(k.Status, k.Severity) },
  launcher: { h: 'LAUNCHER', v: (k, lv) => lv.State, sev: (k, lv) => lv.Severity },
  for: { h: 'FOR', v: (k, lv) => lv.For },
  screen: { h: 'SCREEN', v: (k, lv) => lv.Screen, title: 'How white the screen is' },
  account: { h: 'SIGNED IN AS', v: (k, lv) => lv.Account, sev: (k) => (k.Status === 'WRONG_ACCOUNT' ? 'CRITICAL' : 'DIM') },
  ver: { h: 'VER', v: (k, lv) => lv.Version },
  watchdog: { h: 'WATCHDOG', v: (k) => k.Watchdog, sev: (k) => (k.Watchdog === 'DEAD' ? 'CRITICAL' : 'DIM') },
  log: { h: 'LOG', v: (k) => k.LogAge, title: 'Minutes since the watchdog last wrote' },
  agent: { h: 'AGENT', v: (k) => k.Agent },
  uptime: { h: 'UPTIME', v: (k) => k.Uptime },
  reb: { h: 'REB 24H', v: (k) => k.Reboots, sortv: (k) => k.Reboots24 * 1000 + k.Script24, title: 'Reboots in 24 hours (by the watchdog)' },
  days: { h: '7 DAYS', v: (k) => k.Days.join(','), sortv: (k) => k.Days.reduce((a, b) => a + b, 0), cell: (k, lv, max) => spark(k.Days, max) }
};
const TAB_COLS = {
  Mach2: ['host', 'location', 'status', 'launcher', 'screen', 'watchdog', 'log', 'agent', 'uptime', 'reb', 'days'],
  PBI: ['host', 'location', 'status', 'launcher', 'for', 'account', 'ver', 'uptime'],
  Web: ['host', 'location', 'status', 'launcher', 'for', 'ver', 'uptime'],
  Other: ['host', 'type', 'location', 'status', 'uptime']
};

function spark(days, max) {
  return el('span', { class: 'spark', title: days.join(' / ') + ' reboots, oldest first' },
    days.map((n) => (n > 0 ? el('i', { style: { height: Math.max(3, Math.round(14 * n / Math.max(1, max))) + 'px' } }) : el('i', { class: 'z' }))));
}

function matchesFilter(k, lv, text) {
  if (!text) return true;
  const t = text.trim().toLowerCase();
  if (!t) return true;
  return [k.Host, k.Location, k.Status, k.Type, lv.State, lv.Account].some((x) => x && x.toLowerCase().includes(t));
}

function renderKiosks(main) {
  const tab = S.view;
  if (!$('#ktool', main)) {
    const search = el('input', { type: 'search', id: 'kfilter', placeholder: 'Filter: name, location, status, account', value: S.filter, 'aria-label': 'Filter kiosks' });
    search.addEventListener('input', () => { S.filter = search.value; renderKioskTable(); });
    const only = el('input', { type: 'checkbox', checked: S.onlyProblems });
    only.addEventListener('change', () => { S.onlyProblems = only.checked; renderKioskTable(); });
    const loc = el('select', { id: 'kloc', 'aria-label': 'Only one location' });
    loc.addEventListener('change', () => { S.location = loc.value; renderKioskTable(); });
    main.append(
      el('h2', { id: 'ktitle' }), el('p', { class: 'sub', id: 'ksub' }),
      el('div', { class: 'toolbar', id: 'ktool' }, search, loc, el('label', { class: 'check' }, only, 'Only those needing attention')),
      el('div', { id: 'kgroup' }),
      el('div', { class: 'split' }, el('div', { id: 'ktable' }), el('aside', { class: 'card detail', id: 'kdetail', 'aria-live': 'polite' })));
  }
  const kiosks = tabKiosks(tab);
  const loc = $('#kloc', main);
  if (document.activeElement !== loc) {
    const places = [...new Set(kiosks.map((k) => k.Location).filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    if (S.location && !places.includes(S.location)) places.push(S.location);
    setKids(loc, el('option', { value: '', text: 'All locations' }), places.map((p) => el('option', { value: p, text: p })));
    loc.value = S.location;
  }
  $('#ktitle', main).textContent = TAB_TITLE[tab];
  $('#ksub', main).textContent = `${kiosks.length} kiosks, ${kiosks.filter((k) => k.Attention).length} needing attention`;
  renderKioskTable();
  renderDetail();
}

function renderKioskTable() {
  const box = $('#ktable');
  if (!box) return;
  const tab = S.view;
  const all = tabKiosks(tab);
  const cols = TAB_COLS[tab].map((id) => Object.assign({ id }, COLS[id]));
  const lvOf = (k) => k.Launchers[tab] || k.Launchers.Other;
  let rows = all.filter((k) => (!S.onlyProblems || k.Attention) && (!S.location || k.Location === S.location) && matchesFilter(k, lvOf(k), S.filter));
  // Picks stay with the kiosks still on this tab.
  const here = new Set(all.map((k) => k.Host));
  for (const h of [...S.picks]) if (!here.has(h)) S.picks.delete(h);
  renderGroupBar(rows);
  if (S.sort.key) {
    const c = COLS[S.sort.key];
    const key = (k) => (c.sortv ? c.sortv(k) : c.v(k, lvOf(k)) || '');
    rows = rows.slice().sort((a, b) => {
      const x = key(a), y = key(b);
      const r = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), undefined, { numeric: true });
      return r * S.sort.dir;
    });
  }
  if (!all.length) { setKids(box, S.fleet && S.fleet.Ok ? el('div', { class: 'card empty', text: `No ${tab} kiosks in the data.` }) : loadingCard('Reading the fleet ...')); return; }
  if (!rows.length) { setKids(box, el('div', { class: 'card empty', text: S.onlyProblems ? 'Nothing on this tab needs attention.' : 'Nothing matches the filter.' })); return; }
  const shown = rows.map((k) => k.Host);
  const allPicked = shown.every((h) => S.picks.has(h));
  const pickAll = el('input', { type: 'checkbox', checked: allPicked, 'aria-label': allPicked ? 'Unpick the kiosks shown' : 'Pick every kiosk shown' });
  pickAll.addEventListener('change', () => { for (const h of shown) { if (pickAll.checked) S.picks.add(h); else S.picks.delete(h); } renderKioskTable(); });

  const max = Math.max(1, ...all.flatMap((k) => k.Days));
  const busy = S.live.busy || {};
  const head = el('tr', null, el('th', { class: 'pick nosort', title: 'Pick the kiosks shown, for an action on all of them' }, pickAll), cols.map((c) => {
    const on = S.sort.key === c.id;
    return el('th', {
      title: c.title || 'Sort', scope: 'col', 'aria-sort': on ? (S.sort.dir > 0 ? 'ascending' : 'descending') : null,
      onclick: () => { S.sort = { key: c.id, dir: on ? -S.sort.dir : 1 }; renderKioskTable(); }
    }, c.h, on ? el('span', { class: 'arrow', text: S.sort.dir > 0 ? ' ▲' : ' ▼' }) : null);
  }));
  const body = el('tbody', null, rows.map((k) => {
    const lv = lvOf(k);
    const tick = el('input', { type: 'checkbox', checked: S.picks.has(k.Host), 'aria-label': 'Pick ' + k.Host });
    tick.addEventListener('click', (e) => e.stopPropagation());
    tick.addEventListener('change', () => { if (tick.checked) S.picks.add(k.Host); else S.picks.delete(k.Host); renderKioskTable(); });
    const tr = el('tr', { class: (k.Host === S.selected ? 'sel' : '') + (busy[k.Host] ? ' busy' : ''), tabindex: '0' },
      el('td', { class: 'pick' }, tick),
      cols.map((c) => {
        if (c.cell) return el('td', null, c.cell(k, lv, max));
        const v = c.v(k, lv) || '';
        return el('td', { class: [c.cls, c.sev ? 'sev-' + c.sev(k, lv) : ''].filter(Boolean).join(' '), text: v, title: v.length > 30 ? v : null });
      }));
    const pick = () => { S.selected = k.Host; renderKioskTable(); renderDetail(); };
    tr.addEventListener('click', pick);
    tr.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
    return tr;
  }));
  setKids(box, el('div', { class: 'tablewrap' }, el('table', null, el('thead', null, head), body)));
}

function getKiosk(host) {
  return S.fleet && S.fleet.Ok ? S.fleet.Kiosks.find((k) => k.Host === host) : null;
}

function screenTarget(k) {
  const c = S.screenChoice[k.Host] || '';
  const m = /^(S\d+)\|(NG|PBI|WEB)$/.exec(c);
  return m ? { screen: m[1], kind: m[2] } : { screen: '', kind: 'ALL' };
}

function renderDetail() {
  const box = $('#kdetail');
  if (!box) return;
  // A screen box someone is choosing from is not pulled from under them.
  if (box.contains(document.activeElement) && document.activeElement.tagName === 'SELECT') return;
  const k = S.selected ? getKiosk(S.selected) : null;
  if (!k || !(k.Tab === S.view || (k.Tabs || []).includes(S.view))) {
    setKids(box, el('div', { class: 'empty', text: 'Pick a kiosk to see its details and what can be done to it.' }));
    return;
  }
  const L = S.live;
  const busy = (L.busy || {})[k.Host];
  const kids = [
    el('div', { class: 'head' },
      el('div', null, el('div', { class: 'host', text: k.Host }), el('div', { class: 'dim', text: [k.Location, k.Type].filter(Boolean).join('  |  ') })),
      pill(k.Status, k.Severity)),
    busy ? el('div', { class: 'busy', role: 'status' }, spinner(), el('span', { text: busy.charAt(0).toUpperCase() + busy.slice(1) + ' ...' }), el('i', { class: 'shimmer' })) : null
  ];
  const row = (r) => el('div', { class: 'row' }, el('span', { class: 'k', text: r.Label }), el('span', { class: 'v sev-' + (r.Sev || 'TEXT'), text: r.Value }));
  for (const s of k.Detail) kids.push(el('h3', { text: s.Title }), s.Rows.map(row));

  const live = (L.live || {})[k.Host];
  if (live) kids.push(el('h3', { text: 'READ LIVE AT ' + live.At }), live.Lines.map(row));

  const snap = (L.snapshots || {})[k.Host];
  if (snap) {
    kids.push(el('h3', { text: 'SCREENSHOT' }),
      el('a', { href: '/api/snapshots/' + encodeURIComponent(snap.File), target: '_blank', rel: 'noopener', title: 'Open full size' },
        el('img', { class: 'snap', src: '/api/snapshots/' + encodeURIComponent(snap.File), alt: 'What was on the screen of ' + k.Host })),
      el('div', { class: 'hint', text: snap.Caption }));
  }

  if (k.Screens.length > 1) {
    const sel = el('select', { 'aria-label': 'Which screen the launcher buttons act on' },
      el('option', { value: '', text: 'All screens' }),
      k.Screens.map((s) => el('option', { value: `${s.Screen}|${s.Kind}`, text: `${s.Screen}  -  ${s.Name}  (${s.State})` })));
    sel.value = S.screenChoice[k.Host] || '';
    sel.addEventListener('change', () => { S.screenChoice[k.Host] = sel.value; renderDetail(); });
    kids.push(el('h3', { text: 'SCREEN' }), sel);
  }
  kids.push(renderActions(k, !!busy));
  setKids(box, ...kids);
}

function renderActions(k, busy) {
  const target = screenTarget(k);
  const onlyWeb = target.kind === 'WEB' || (target.kind === 'ALL' && k.Screens.length > 0 && k.Screens.every((s) => s.Kind === 'WEB'));
  const hold = !!(S.live.hold || {})[k.Host];
  const b = (text, what, fn, opts) => {
    opts = opts || {};
    if (!can(what)) return null;
    return el('button', {
      type: 'button', class: 'btn small' + (opts.danger ? ' danger' : ''), text,
      disabled: busy || opts.disabled, title: opts.title || null, onclick: () => fn(k)
    });
  };
  const noLauncher = !k.HasLauncher ? 'This kiosk is not on the new launcher yet' : null;
  const kiosk = [
    b('Restart...', 'restart', restartDialog, { disabled: !k.HasLauncher, title: k.HasLauncher ? 'Through the launcher (restart.txt)' : 'Restart goes through the launcher, and this kiosk has none yet' }),
    can('view') ? el('button', { type: 'button', class: 'btn small', text: 'Remote control', onclick: () => remoteControl(k) }) : null,
    b('Message...', 'message', messageDialog, { disabled: !k.MessageOk, title: k.MessageWhy || 'A window on the kiosk screen, put up by its watchdog' }),
    el('button', { type: 'button', class: 'btn small', text: 'Open share', onclick: () => openShare(k) }),
    el('button', { type: 'button', class: 'btn small', text: 'History', title: 'Its status, reboots and uptime over the weeks', onclick: () => openHistory(k.Host) }),
    can('kiosklist') ? el('button', { type: 'button', class: 'btn small', text: 'List entry...', title: 'Its row in the kiosk list: location, type, active', onclick: () => listEntryFor(k) }) : null
  ];
  const launcher = [
    b('Read live', 'live', (x) => runKioskJob(x, 'live', {}, { title: 'reading' })),
    b('Screenshot', 'snapshot', (x) => runKioskJob(x, 'snapshot', {}, { title: 'asking for a screenshot' }), { disabled: !k.HasLauncher, title: noLauncher }),
    b('Reload', 'reload', (x) => runKioskJob(x, 'reload', {}, { title: 'reloading the page' }), { disabled: !k.HasLauncher, title: noLauncher }),
    b('Restart browser', 'relaunch', (x) => runKioskJob(x, 'relaunch', {}, { title: 'restarting the browser' }), { disabled: !k.HasLauncher, title: noLauncher }),
    hold ? b('Resume', 'resume', (x) => runKioskJob(x, 'resume', {}, { title: 'carrying on' }), { disabled: !k.HasLauncher })
      : b('Hold', 'hold', holdDialog, { disabled: !k.HasLauncher, title: noLauncher }),
    b('Stop', 'stop', stopDialog, { danger: true, disabled: !k.HasLauncher, title: noLauncher }),
    b('Log', 'log', logDialog, { disabled: !k.HasLauncher, title: noLauncher }),
    b('Password...', 'password', passwordDialog, { disabled: !k.HasLauncher || onlyWeb, title: onlyWeb ? 'A web page screen signs in to nothing' : noLauncher }),
    b('Config...', 'config', openKioskConfig, { title: k.HasLauncher ? "The kiosk's own settings: URL, account, screen, refresh" : 'No launcher here yet - this writes the config it will read' }),
    b('Add screen...', 'config', (x) => instancePicker(x, true))
  ];
  return el('div', { class: 'actions' },
    el('h3', { text: 'KIOSK' }), el('div', { class: 'btnrow' }, kiosk),
    el('h3', { text: 'LAUNCHER' + (target.screen ? ` - ${target.screen} ${NAMES[target.kind]}` : '') }), el('div', { class: 'btnrow' }, launcher),
    S.me.role === 'operator' ? el('p', { class: 'hint', text: 'Restart, hold, stop, passwords and config are for admins.' }) : null);
}

// ---------------------------------------------------------------------------
// Many kiosks at once: the picked ones on a tab get a job each, and the
// card follows every one of them.
// ---------------------------------------------------------------------------
const GROUP = {
  live: { title: 'Read live', ok: 'Read them', body: 'Reads each kiosk now, as Read live does on one. Changes nothing.' },
  reload: { title: 'Reload', ok: 'Reload them', body: 'Each launcher reloads the page on every screen of its kiosk. Kiosks not on the new launcher yet are skipped.' },
  relaunch: { title: 'Restart browser', ok: 'Restart the browsers', body: 'Each launcher closes the browser and starts it again on every screen; the screens are blank for a few seconds. Kiosks not on the new launcher yet are skipped.' },
  message: { title: 'Message', ok: 'Show it on all of them', body: 'A window on each kiosk screen with an OK button and a countdown, put up by its watchdog. Kiosks without a watchdog that can show one are skipped.' }
};

function renderGroupBar(shownRows) {
  const bar = $('#kgroup');
  if (!bar) return;
  const n = S.picks.size;
  if (!n) { setKids(bar); bar.className = ''; return; }
  bar.className = 'groupbar';
  const b = (action) => (can(action) ? el('button', { class: 'btn small', type: 'button', text: GROUP[action].title + (action === 'message' ? '...' : ''), onclick: () => groupDialog(action) }) : null);
  const places = [...new Set([...S.picks].map((h) => (getKiosk(h) || {}).Location).filter(Boolean))];
  setKids(bar,
    el('span', { class: 'n', text: `${n} ${plural(n, 'kiosk', 'kiosks')} picked` }),
    el('span', { class: 'dim', text: places.length === 1 ? places[0] : places.length ? `${places.length} locations` : '' }),
    el('span', { style: { flex: '1' } }),
    b('live'), b('reload'), b('relaunch'), b('message'),
    el('button', { class: 'btn small', type: 'button', text: 'Unpick all', onclick: () => { S.picks.clear(); renderKioskTable(); } }));
}

async function followJobs(jobs, onDone) {
  const pending = new Map(jobs.map((x) => [x.job, x.host]));
  working(1);
  try { await followAll(pending, onDone); } finally { working(-1); }
}

async function followAll(pending, onDone) {
  while (pending.size) {
    await sleep(900);
    await Promise.all([...pending].map(async ([id, host]) => {
      try {
        const j = await api('GET', '/api/jobs/' + id);
        if (j.done) { pending.delete(id); onDone(host, j); }
      } catch (e) {
        if (e.status === 401) throw e;
        pending.delete(id);
        onDone(host, { ok: false, detail: e.message });
      }
    }));
  }
}

function groupDialog(action) {
  const G = GROUP[action];
  const hosts = [...S.picks].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  const rows = new Map(hosts.map((h) => [h, { state: 'picked', sev: 'DIM', detail: (getKiosk(h) || {}).Location || '' }]));
  const list = el('div', { class: 'grouplist' });
  const draw = () => setKids(list, el('table', null,
    el('thead', null, el('tr', null, ['KIOSK', '', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, [...rows].map(([h, r]) => el('tr', null,
      el('td', { class: 'host', text: h }), el('td', { class: 'sev-' + r.sev }, r.state.endsWith(' ...') ? spinner('small') : null, r.state), el('td', { class: 'dim', text: r.detail, title: r.detail }))))));
  draw();
  const fields = action === 'message' ? [
    { key: 'text', label: 'Message', kind: 'textarea', max: 1000 },
    { key: 'seconds', label: 'On screen for, at most, seconds', value: 60, kind: 'number' }
  ] : [];
  openModal({
    title: `${G.title} - ${hosts.length} ${plural(hosts.length, 'kiosk', 'kiosks')}`, body: G.body, fields, extra: list, wide: true, okText: G.ok,
    onOk: async (v, m) => {
      const body = { hosts };
      if (action === 'message') {
        if (!v.text) { m.setNote('Type the message first.', 'CRITICAL'); return true; }
        const secs = Number(v.seconds);
        if (!Number.isInteger(secs) || secs < 5 || secs > 900) { m.setNote('Between 5 and 900 seconds.', 'CRITICAL'); return true; }
        Object.assign(body, { text: v.text, seconds: secs });
      }
      m.busy(true, `${G.title}: starting`);
      const r = await api('POST', '/api/group/' + action, body);
      m.progress(`${G.title} on ${r.jobs.length} ${plural(r.jobs.length, 'kiosk', 'kiosks')}`);
      m.count(0, r.jobs.length);
      for (const x of r.skipped) rows.set(x.host, { state: 'skipped', sev: 'INACTIVE', detail: x.why });
      for (const x of r.jobs) rows.set(x.host, { state: r.label + ' ...', sev: 'UNKNOWN', detail: '' });
      draw();
      refreshSoon();
      let ok = 0, bad = 0;
      await followJobs(r.jobs, (host, j) => {
        if (j.ok) ok++; else bad++;
        m.count(ok + bad, r.jobs.length);
        const lines = j.result && j.result.lines ? j.result.lines.filter((l) => l.Sev === 'CRITICAL' || l.Sev === 'WARNING').map((l) => `${l.Label}: ${l.Value}`) : [];
        rows.set(host, { state: j.ok ? (j.waiting ? 'waiting' : 'done') : 'failed', sev: j.ok ? (j.waiting ? 'WARNING' : 'OK') : 'CRITICAL', detail: [j.detail, ...lines].filter(Boolean).join('  |  ') });
        draw();
      });
      refreshSoon();
      const skipped = r.skipped.length ? `, ${r.skipped.length} skipped` : '';
      m.finish(`${ok} done${bad ? `, ${bad} failed` : ''}${skipped}.`, bad ? 'CRITICAL' : (r.skipped.length ? 'WARNING' : 'OK'));
      return true;
    }
  });
}

// ---------------------------------------------------------------------------
// The card: one modal, dressed for whatever is being asked
// ---------------------------------------------------------------------------
function closeModal() {
  if (S.modal) { S.modal.root.remove(); S.modal = null; }
}

function openModal(o) {
  closeModal();
  const controls = {};
  const fields = el('div');
  const adv = el('div', { class: 'adv hidden' });
  let hasAdv = false;
  for (const f of o.fields || []) {
    const target = f.advanced ? adv : fields;
    if (f.advanced) hasAdv = true;
    if (f.kind === 'note') { target.append(el('div', { class: 'h', text: f.label })); continue; }
    const id = 'f_' + Math.random().toString(36).slice(2);
    let control, wrap;
    switch (f.kind) {
      case 'password': {
        const p1 = el('input', { type: 'password', id, autocomplete: 'new-password', maxLength: 256 });
        const p2 = el('input', { type: 'password', autocomplete: 'new-password', maxLength: 256, 'aria-label': f.label + ' again' });
        controls[f.key] = { kind: 'password', p1, p2 };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), p1,
          el('span', { class: 'lbl', style: { marginTop: '8px' }, text: 'again' }), p2);
        break;
      }
      case 'secret': {
        control = el('input', { type: 'password', id, autocomplete: 'current-password', maxLength: 256 });
        controls[f.key] = { kind: 'secret', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      case 'bool': {
        control = el('input', { type: 'checkbox', id, checked: ['1', 'true', 'True'].includes(String(f.value)) });
        controls[f.key] = { kind: 'bool', c: control };
        wrap = el('div', { class: 'field' }, el('span', { class: 'lbl', text: f.label }), el('label', { class: 'check', for: id }, control, f.hint || 'on'));
        break;
      }
      case 'choice': {
        control = el('select', { id }, (f.options || []).map((op) => el('option', { value: op.value, text: op.text })));
        if (f.value) control.value = f.value;
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      case 'textarea': {
        control = el('textarea', { id, rows: 3, maxLength: f.max || 1000 });
        control.value = f.value || '';
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
        break;
      }
      default: {
        control = el('input', { type: f.kind === 'number' ? 'number' : 'text', id, maxLength: f.max || 4000 });
        control.value = f.value == null ? '' : String(f.value);
        controls[f.key] = { kind: 'text', c: control };
        wrap = el('div', { class: 'field' }, el('label', { class: 'lbl', for: id, text: f.label }), control);
      }
    }
    if (f.hint && f.kind !== 'bool') wrap.append(el('div', { class: 'hint', text: f.hint }));
    target.append(wrap);
  }
  const note = el('div', { class: 'note', role: 'alert', text: o.note || '' });
  const log = el('pre', { class: 'log' + (o.withLog ? '' : ' hidden') });
  // While it works: what it is doing, the last step the server reported,
  // how long it has taken, and a bar (sliding, or filling when counted).
  const pTitle = el('div', { class: 'p1' }), pStep = el('div', { class: 'p2' }), pTime = el('span', { class: 'ptime' });
  const pFill = el('i');
  const prog = el('div', { class: 'progress hidden', role: 'status', 'aria-live': 'polite' },
    el('div', { class: 'prow' }, spinner('big'), el('div', { class: 'ptext' }, pTitle, pStep), pTime),
    el('div', { class: 'pbar' }, pFill));
  let pTimer = null;
  const stopProgress = () => { clearInterval(pTimer); pTimer = null; prog.classList.add('hidden'); ok.classList.remove('loading'); };
  const ok = el('button', { type: 'button', class: 'btn ' + (o.danger ? 'danger' : 'primary'), text: o.okText || 'OK' });
  const cancel = el('button', { type: 'button', class: 'btn', text: o.okText === null ? 'Close' : 'Cancel', onclick: closeModal });
  if (o.okText === null) ok.classList.add('hidden');
  const more = hasAdv ? el('button', { type: 'button', class: 'btn small', text: 'More settings', onclick: () => { adv.classList.toggle('hidden'); } }) : null;
  const modal = el('div', { class: 'modal' + (o.wide ? ' wide' : ''), role: 'dialog', 'aria-modal': 'true', 'aria-label': o.title },
    el('h2', { text: o.title }), o.sub ? el('div', { class: 'dim', text: o.sub }) : null,
    o.body ? el('div', { class: 'body', text: o.body }) : null,
    o.extra || null,
    fields, more, adv, prog, note, log,
    el('div', { class: 'foot' }, cancel, ok));
  const root = el('div', { class: 'overlay' }, modal);
  root.addEventListener('mousedown', (e) => { if (e.target === root && !m.working) closeModal(); });
  document.body.append(root);

  const m = {
    root, working: false,
    values() {
      const out = {};
      for (const [k, c] of Object.entries(controls)) {
        if (c.kind === 'password') { out[k] = c.p1.value; out[k + '.again'] = c.p2.value; }
        else if (c.kind === 'bool') out[k] = c.c.checked ? '1' : '0';
        else if (c.kind === 'secret') out[k] = c.c.value;
        else out[k] = c.c.value.trim();
      }
      return out;
    },
    clearSecrets() { for (const c of Object.values(controls)) { if (c.kind === 'password') { c.p1.value = ''; c.p2.value = ''; } else if (c.kind === 'secret') c.c.value = ''; } },
    setNote(text, sev) { note.textContent = text || ''; note.className = 'note' + (sev ? ' sev-' + sev : ''); },
    log(line) { log.classList.remove('hidden'); log.textContent += line + '\n'; log.scrollTop = log.scrollHeight; if (pTimer) pStep.textContent = line; },
    setLog(lines) { log.classList.remove('hidden'); log.textContent = lines.join('\n'); },
    progress(title, step) {
      m.working = true;
      pTitle.textContent = title;
      pStep.textContent = step || '';
      prog.classList.remove('hidden');
      prog.classList.add('sliding');
      prog.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      pFill.style.width = '';
      if (!pTimer) {
        const t0 = Date.now();
        pTime.textContent = '';
        pTimer = setInterval(() => {
          if (!root.isConnected) return clearInterval(pTimer);
          const sec = Math.round((Date.now() - t0) / 1000);
          pTime.textContent = sec < 60 ? sec + 's' : `${Math.floor(sec / 60)}m ${sec % 60}s`;
        }, 500);
      }
    },
    count(done, total) {
      prog.classList.remove('sliding');
      pFill.style.width = (total ? Math.round((100 * done) / total) : 0) + '%';
      pStep.textContent = `${done} of ${total} done`;
    },
    busy(on, title) {
      m.working = on; ok.disabled = on; ok.classList.toggle('loading', on);
      if (on) m.progress(title || o.busyText || 'Working on it', '');
      else stopProgress();
    },
    finish(text, sev) { stopProgress(); m.working = false; ok.classList.add('hidden'); cancel.textContent = 'Close'; m.setNote(text, sev); cancel.focus(); },
    close: closeModal
  };
  ok.addEventListener('click', async () => {
    if (!o.onOk) return closeModal();
    m.setNote('');
    try {
      const keep = await o.onOk(m.values(), m);
      if (keep !== true && S.modal === m) closeModal();
    } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
  });
  modal.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.tagName === 'INPUT' && e.target.type !== 'checkbox') { e.preventDefault(); ok.click(); }
  });
  S.modal = m;
  const first = modal.querySelector('input, select, textarea');
  setTimeout(() => (first || (o.okText === null ? cancel : ok)).focus(), 0);
  return m;
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && S.modal && !S.modal.working) closeModal();
});

// ---------------------------------------------------------------------------
// Doing something to a kiosk: the server starts it and answers with a job;
// the page follows the job until it is done.
// ---------------------------------------------------------------------------
async function waitJob(id, onLine) {
  let seen = 0;
  working(1);
  try {
    for (;;) {
      const j = await api('GET', '/api/jobs/' + id);
      for (; seen < j.lines.length; seen++) if (onLine) onLine(j.lines[seen]);
      if (j.done) return j;
      await sleep(700);
    }
  } finally { working(-1); }
}

async function runKioskJob(k, action, body, o) {
  o = o || {};
  const target = screenTarget(k);
  const payload = Object.assign({}, action.startsWith('config') ? {} : { screen: target.screen, kind: target.screen ? target.kind : '' }, body || {});
  const m = o.modal;
  try {
    const r = await api('POST', `/api/kiosks/${encodeURIComponent(k.Host)}/${action}`, payload);
    refreshSoon();
    if (!m) toast(`${k.Host}: ${o.title || action} ...`, 'BUSY');
    const j = await waitJob(r.job, m ? (l) => m.log(l) : null);
    refreshSoon();
    const sev = j.ok ? (j.waiting ? 'WARNING' : 'OK') : 'CRITICAL';
    if (o.onDone) o.onDone(j, sev);
    else if (m) { m.log(j.detail); m.finish(j.detail, sev); }
    else toast(`${k.Host}: ${j.detail}`, sev, j.ok ? 6 : 10);
    return j;
  } catch (e) {
    if (m) m.finish(e.message, 'CRITICAL');
    else toast(`${k.Host}: ${e.message}`, 'CRITICAL', 10);
    return null;
  }
}

function restartDialog(k) {
  openModal({
    title: `Restart ${k.Host}?`, sub: [k.Location, k.Type].filter(Boolean).join('  |  '),
    body: 'The launcher closes the browser and has Windows restart the kiosk after the countdown, with the message on screen. Anything running on it is closed. It comes back on its own. (Launchers from before the countdown restart after 10 s, without the message.)',
    fields: [
      { key: 'message', label: 'Message on the kiosk screen (empty for none)', value: S.live.restart.message, kind: 'textarea', max: 500 },
      { key: 'seconds', label: 'Countdown in seconds (0 restarts at once)', value: S.live.restart.seconds, kind: 'number' }
    ],
    okText: 'Restart the kiosk', danger: true, withLog: false,
    onOk: async (v, m) => {
      const secs = Number(v.seconds);
      if (!Number.isInteger(secs) || secs < 0 || secs > 3600) { m.setNote('The countdown has to be a whole number of seconds, 0 to 3600.', 'CRITICAL'); return true; }
      m.busy(true);
      m.log(`Restarting ${k.Host} ...`);
      runKioskJob(k, 'restart', { message: v.message, seconds: secs }, { modal: m });
      return true;
    }
  });
}

function messageDialog(k) {
  openModal({
    title: `Message on ${k.Host}`, sub: 'A window on the kiosk screen with an OK button and a countdown, put up by its watchdog.',
    fields: [
      { key: 'text', label: 'Message', kind: 'textarea', max: 1000 },
      { key: 'seconds', label: 'On screen for, at most, seconds', value: 60, kind: 'number' }
    ],
    okText: 'Show it',
    onOk: async (v, m) => {
      if (!v.text) { m.setNote('Type the message first.', 'CRITICAL'); return true; }
      const secs = Number(v.seconds);
      if (!Number.isInteger(secs) || secs < 5 || secs > 900) { m.setNote('Between 5 and 900 seconds.', 'CRITICAL'); return true; }
      m.busy(true);
      runKioskJob(k, 'message', { text: v.text, seconds: secs }, { modal: m });
      return true;
    }
  });
}

function holdDialog(k) {
  openModal({
    title: `Hold ${k.Host}?`,
    body: 'Hold leaves the screen exactly as it is: no checks, no reloads, no sign-in, and no restarts from the watchdog until you resume. The kiosk keeps showing whatever is on it now.',
    okText: 'Hold',
    onOk: async () => { runKioskJob(k, 'hold', {}, { title: 'holding' }); }
  });
}

function stopDialog(k) {
  openModal({
    title: `Stop the launcher on ${k.Host}?`,
    body: 'Stop closes the browser and ends the launcher. The screen stays empty until the kiosk restarts or its user logs on again. On a Mach2 kiosk that also stops the watchdog, so nothing is watching the screen.',
    okText: 'Stop the launcher', danger: true,
    onOk: async () => { runKioskJob(k, 'stop', {}, { title: 'stopping the launcher' }); }
  });
}

function logDialog(k) {
  const m = openModal({ title: `${k.Host} - launcher log`, sub: 'The end of the log the launcher writes on the kiosk.', okText: null, withLog: true, wide: true });
  m.progress(`Reading the launcher log from ${k.Host}`, 'asking the kiosk ...');
  runKioskJob(k, 'log', {}, {
    modal: m,
    onDone: (j, sev) => {
      m.busy(false);
      if (j.ok && j.result) { m.setLog(j.result.lines); m.setNote(j.result.path, 'DIM'); }
      else m.finish(j.detail, sev);
    }
  });
}

function passwordDialog(k) {
  const t = screenTarget(k);
  const who = t.kind === 'PBI' ? 'the Power BI account' : t.kind === 'NG' ? 'the Mach2 station account' : "every screen's sign-in account (not the web pages')";
  openModal({
    title: `Sign-in password for ${k.Host}`,
    sub: `The new password for ${who}. The launcher encrypts it for the kiosk account, checks it reads back, and wipes what you typed.`,
    fields: [{ key: 'password', label: 'New password', kind: 'password' }],
    note: 'Only the password changes; the account stays the one in the kiosk config.',
    okText: 'Hand it over',
    onOk: async (v, m) => {
      if (!v.password) { m.setNote('Type the password first.', 'CRITICAL'); return true; }
      if (v.password !== v['password.again']) { m.setNote('The two did not match. Nothing was changed.', 'CRITICAL'); return true; }
      m.busy(true);
      m.clearSecrets();
      m.log('writing password.seed ...');
      runKioskJob(k, 'password', { password: v.password, password2: v['password.again'] }, { modal: m });
      return true;
    }
  });
}

function remoteControl(k) {
  const site = S.live.remoteControl;
  const cmd = `CmRcViewer.exe ${k.Host}${site ? ' \\\\' + site : ''}`;
  openModal({
    title: `Remote control ${k.Host}`,
    body: 'SCCM remote control runs on your own PC, not on this server. With the Configuration Manager console installed, run:',
    extra: el('div', null, el('pre', { class: 'cmd', text: cmd }), el('div', { style: { marginTop: '8px' } }, el('button', { class: 'btn small', type: 'button', text: 'Copy', onclick: () => copyText(cmd) }))),
    okText: null
  });
}

function openShare(k) {
  const path = (S.live.shareTemplate || '').replace('{0}', k.Host);
  openModal({
    title: `${k.Host} - the kiosk's share`,
    body: 'The kiosk\'s Public Documents: the launchers keep their configs, status and logs here. Open it in Explorer from your own PC (with an account that may open the share):',
    extra: el('div', null, el('pre', { class: 'cmd', text: path }), el('div', { style: { marginTop: '8px' } }, el('button', { class: 'btn small', type: 'button', text: 'Copy', onclick: () => copyText(path) }))),
    okText: null
  });
}

// --- the kiosk's own settings ---------------------------------------------
function openKioskConfig(k) {
  const t = screenTarget(k);
  if (t.screen) return configEditor(k.Host, t.kind, t.screen);
  if (k.Screens.length === 1) return configEditor(k.Host, k.Screens[0].Kind, k.Screens[0].Screen);
  if (k.Screens.length === 0) return configEditor(k.Host, TAB_KIND[k.Tab] || TAB_KIND[S.view] || 'NG', '');
  instancePicker(k, false);
}

function instancePicker(k, newOnly) {
  const screens = k ? k.Screens : [];
  const options = [];
  if (!newOnly) for (const s of screens) options.push({ value: `${s.Screen}|${s.Kind}`, text: `${s.Screen}  -  ${s.Name}  (${s.State})` });
  const used = screens.map((s) => parseInt(s.Screen.slice(1), 10));
  let next = 1;
  while (used.includes(next)) next++;
  for (const kind of ['NG', 'PBI', 'WEB']) options.push({ value: `S${next}|${kind}|new`, text: `New screen S${next}  -  ${NAMES[kind]}` });
  const def = !newOnly && screens.length ? options[0].value : (k && TAB_KIND[k.Tab] && !screens.length ? `S1|${TAB_KIND[k.Tab]}|new` : options[0].value);
  openModal({
    title: `Which screen on ${k.Host}?`,
    sub: 'Each screen has its own config and its own launcher: Mach2 dashboard, Power BI report or a web page.',
    fields: [{ key: 'pick', label: 'Screen', kind: 'choice', value: def, options }],
    note: "A new screen gets its config from the launcher's EXAMPLE.json. The launcher starts on it once it is installed there.",
    okText: 'Open it',
    onOk: async (v) => {
      const m = /^(S\d+)\|(NG|PBI|WEB)/.exec(v.pick);
      if (m) configEditor(k.Host, m[2], m[1]);
      return true;
    }
  });
}

async function configEditor(host, kind, instance) {
  const m = openModal({ title: `Config for ${host}`, okText: null, withLog: true });
  m.progress(`Reading the config from ${host}`, 'asking the kiosk ...');
  let j;
  try {
    const r = await api('POST', `/api/kiosks/${encodeURIComponent(host)}/config-read`, { kind, instance });
    j = await waitJob(r.job, (l) => m.log(l));
  } catch (e) { m.finish(e.message, 'CRITICAL'); return; }
  m.busy(false);
  if (!j.ok || !j.result) { m.finish(j.detail, 'CRITICAL'); return; }
  const c = j.result;
  const where = `screen ${c.instance}, ${NAMES[c.kind]}`;
  let sub = c.isNew
    ? `No config on the kiosk yet: this is EXAMPLE.json, for you to fill in. Saving it writes ${host}.json, which the launcher reads once it is installed there.`
    : `The launcher reads its config every few seconds, so a change applies without a restart. Password: ${c.password}.`;
  if (c.instances.length > 1) sub += `  This kiosk has ${c.instances.join(', ')}; this is ${c.instance}.`;
  sub += c.launcherOptions
    ? `  More settings lists all ${c.launcherOptions} settings the ${NAMES[c.kind]} installed here reads.`
    : `  The ${NAMES[c.kind]} is not installed here (or could not be read), so More settings has only the file's own.`;
  const taken = c.taken || {};
  const fields = c.fields.map((f) => ({ key: f.Key, label: f.Label, value: f.Value, kind: f.Kind, hint: f.Hint, advanced: f.Advanced }));
  if (c.isNew) {
    const t = Object.keys(taken).sort().map((s) => `${s} (${NAMES[taken[s]]})`);
    fields.unshift({ key: '__instance', label: 'Screen folder', value: c.instance, hint: 'S1 is the first screen, S2 the second, each with its own config.' + (t.length ? ' Taken already: ' + t.join(', ') + '.' : '') });
  }
  const required = c.kind === 'WEB' ? ['DisplayURL'] : ['DisplayURL', 'UserName'];
  openModal({
    title: `${host} - ${where}`, sub, fields, withLog: false, wide: true,
    okText: c.isNew ? 'Write it to the kiosk' : 'Save to the kiosk',
    onOk: async (v, mm) => {
      if ((v.__password || '') !== (v['__password.again'] || '')) { mm.setNote('The two passwords did not match. Nothing was saved.', 'CRITICAL'); return true; }
      const missing = required.filter((r) => !v[r]);
      if (missing.length) { mm.setNote('Still empty: ' + missing.join(', ') + '.', 'CRITICAL'); return true; }
      let inst = c.instance;
      if (c.isNew) {
        inst = (v.__instance || '').toUpperCase();
        if (!/^S\d{1,2}$/.test(inst)) { mm.setNote('A screen folder is named like S1 or S2.', 'CRITICAL'); return true; }
        if (taken[inst]) { mm.setNote(`${inst} shows ${NAMES[taken[inst]]} already - one launcher per screen. Pick another screen folder.`, 'CRITICAL'); return true; }
      }
      const values = {};
      for (const f of c.fields) if (f.Kind !== 'password' && f.Kind !== 'note') values[f.Key] = v[f.Key];
      const body = { kind: c.kind, instance: inst, values, password: v.__password || '', password2: v['__password.again'] || '' };
      mm.busy(true, `Saving the config on ${host}`);
      mm.clearSecrets();
      mm.log(`writing ${host}.json to ${inst} ...`);
      try {
        const r = await api('POST', `/api/kiosks/${encodeURIComponent(host)}/config-write`, body);
        const jj = await waitJob(r.job, (l) => mm.log(l));
        refreshSoon();
        mm.finish(jj.detail, jj.ok ? 'OK' : 'CRITICAL');
        if (jj.ok) toast(`${host}: config saved.`, 'OK');
      } catch (e) { mm.finish(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

// ---------------------------------------------------------------------------
// Scanning
// ---------------------------------------------------------------------------
async function scanNow() {
  try { await api('POST', '/api/scan'); toast('Scan started - its output is in Activity.', 'OK', 4); refreshSoon(); }
  catch (e) { toast(e.message, 'WARNING', 8); }
}

async function toggleAutoScan() {
  try { await api('POST', '/api/autoscan', { on: !S.live.autoscan.on }); refreshSoon(); }
  catch (e) { toast(e.message, 'WARNING', 10); }
}

// ---------------------------------------------------------------------------
// Screens: the newest screenshot of every kiosk screen, in a grid
// ---------------------------------------------------------------------------
function loadScreensPrefs() {
  try {
    const p = JSON.parse(localStorage.getItem('kfw.screens') || '{}');
    if (['S', 'M', 'L'].includes(p.size)) S.screens.size = p.size;
    if ([0, 5, 10, 15, 30].includes(p.auto)) S.screens.auto = p.auto;
  } catch (e) { /* no storage: the defaults */ }
}
function saveScreensPrefs() {
  try { localStorage.setItem('kfw.screens', JSON.stringify({ size: S.screens.size, auto: S.screens.auto })); } catch (e) { /* fine */ }
}

async function loadScreens() {
  clearTimeout(S.screens.timer);
  if (S.view !== 'Screens' || !S.me) return;
  try {
    S.screens.list = (await api('GET', '/api/screens')).screens;
    S.screens.loaded = true;
  } catch (e) { if (e.status === 401) return; }
  if (S.view === 'Screens') drawScreens();
  // The pictures change only when someone takes new ones; the ages tick.
  S.screens.timer = setTimeout(loadScreens, S.screens.taking ? 3000 : 20000);
  autoScreens();
}

function screenKiosks() {
  const Sc = S.screens;
  const t = Sc.filter.trim().toLowerCase();
  const all = S.fleet && S.fleet.Ok ? S.fleet.Kiosks : [];
  return all.filter((k) => (!Sc.tab || k.Tab === Sc.tab || (k.Tabs || []).includes(Sc.tab)) &&
    (!Sc.location || k.Location === Sc.location) && (!Sc.only || k.Attention) &&
    (!t || [k.Host, k.Location, k.Status, k.Type].some((x) => x && x.toLowerCase().includes(t))))
    .sort((a, b) => (a.Location || '').localeCompare(b.Location || '', undefined, { numeric: true }) || a.Host.localeCompare(b.Host, undefined, { numeric: true }));
}

const agoText = (m) => (m < 1 ? 'just now' : m < 60 ? `${m} min ago` : m < 2880 ? `${Math.floor(m / 60)} h ago` : `${Math.floor(m / 1440)} days ago`);

function renderScreens(main) {
  const Sc = S.screens;
  if (!$('#stool', main)) {
    const tab = el('select', { 'aria-label': 'Which kiosks' },
      el('option', { value: '', text: 'All kiosks' }), ['Mach2', 'PBI', 'Web', 'Other'].map((t) => el('option', { value: t, text: TAB_TITLE[t] })));
    tab.value = Sc.tab;
    tab.addEventListener('change', () => { Sc.tab = tab.value; drawScreens(true); });
    const loc = el('select', { id: 'sloc', 'aria-label': 'Only one location' });
    loc.addEventListener('change', () => { Sc.location = loc.value; drawScreens(true); });
    const search = el('input', { type: 'search', placeholder: 'Filter: name, location, status', value: Sc.filter, 'aria-label': 'Filter kiosks' });
    search.addEventListener('input', () => { Sc.filter = search.value; drawScreens(true); });
    const only = el('input', { type: 'checkbox', checked: Sc.only });
    only.addEventListener('change', () => { Sc.only = only.checked; drawScreens(true); });
    const size = el('div', { class: 'seg', id: 'ssize', role: 'radiogroup', 'aria-label': 'Picture size', style: { marginBottom: '0' } },
      [['S', 'Small'], ['M', 'Medium'], ['L', 'Large']].map(([v, t]) => el('button', { type: 'button', class: 'btn small', 'data-size': v, role: 'radio', text: t,
        onclick: () => { Sc.size = v; saveScreensPrefs(); drawScreens(true); } })));
    const auto = el('select', { id: 'sauto', 'aria-label': 'Take new screenshots by themselves' },
      [[0, 'Retake: off'], [5, 'Retake every 5 min'], [10, 'Retake every 10 min'], [15, 'Retake every 15 min'], [30, 'Retake every 30 min']].map(([v, t]) => el('option', { value: String(v), text: t })));
    auto.value = String(Sc.auto);
    auto.addEventListener('change', () => { Sc.auto = Number(auto.value); Sc.lastAuto = Date.now(); saveScreensPrefs(); });
    setKids(main,
      el('h2', { text: 'Screens' }),
      el('p', { class: 'sub', text: 'The newest screenshot of every kiosk screen. Take new screenshots takes one of every screen shown, through its launcher; Retake does that by itself while this page is open. Screenshots need the new launchers.' }),
      el('div', { class: 'toolbar', id: 'stool' }, tab, loc, search, el('label', { class: 'check' }, only, 'Only those needing attention'), size,
        can('snapshot') ? auto : null,
        can('snapshot') ? el('button', { class: 'btn small primary', type: 'button', id: 'stake', text: 'Take new screenshots', onclick: () => takeScreens(false) }) : null,
        el('span', { class: 'dim', id: 'snote' })),
      el('div', { id: 'sgrid' }));
    Sc.sig = '';
  }
  drawScreens();
}

function drawScreens(force) {
  const Sc = S.screens;
  const grid = $('#sgrid');
  if (!grid) return;
  const ks = S.fleet && S.fleet.Ok ? S.fleet.Kiosks : [];
  const loc = $('#sloc');
  if (loc && document.activeElement !== loc) {
    const places = [...new Set(ks.map((k) => k.Location).filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
    setKids(loc, el('option', { value: '', text: 'All locations' }), places.map((p) => el('option', { value: p, text: p })));
    loc.value = places.includes(Sc.location) ? Sc.location : '';
    Sc.location = loc.value;
  }
  for (const b of document.querySelectorAll('#ssize button')) {
    const on = b.dataset.size === Sc.size;
    b.classList.toggle('on', on);
    b.setAttribute('aria-checked', String(on));
  }
  const take = $('#stake');
  if (take) take.disabled = Sc.taking;
  const kiosks = screenKiosks();
  const busy = (S.live && S.live.busy) || {};
  // Redrawn only when something on it changed, so the pictures do not flicker.
  const sig = JSON.stringify([Sc.loaded, Sc.size, S.stamp, kiosks.map((k) => k.Host), Sc.list.map((x) => [x.file, x.ageMinutes]), Object.keys(busy)]);
  if (!force && sig === Sc.sig) return;
  Sc.sig = sig;
  grid.className = 'sgrid ' + Sc.size;
  if (!Sc.loaded) { setKids(grid, loadingCard('Reading the screenshots ...')); return; }
  if (!kiosks.length) { setKids(grid, S.fleet && S.fleet.Ok ? el('div', { class: 'card empty', text: 'No kiosks match.' }) : loadingCard('Reading the fleet ...')); return; }
  const byHost = {};
  for (const x of Sc.list) (byHost[x.host] = byHost[x.host] || []).push(x);
  const tiles = [];
  for (const k of kiosks) {
    const pics = byHost[k.Host.toUpperCase()] || [];
    const caption = (pic) => el('div', { class: 'cap' },
      el('div', { class: 'r1' },
        el('button', { type: 'button', class: 'link host', text: k.Host + (pic ? '  ' + pic.screen : ''), title: 'Open ' + k.Host, onclick: () => show(k.Tab, k.Host) }),
        pill(k.Status, k.Severity)),
      el('div', { class: 'r2' },
        el('span', { text: k.Location || k.Type || '' }),
        pic ? el('span', { class: pic.ageMinutes > 60 ? 'sev-WARNING' : 'dim', text: agoText(pic.ageMinutes), title: 'Taken ' + pic.taken.replace('T', ' ') + (pic.by ? ' for ' + pic.by : '') }) : null),
      pic && (pic.state || pic.title) ? el('div', { class: 'r3 dim', text: [pic.state, pic.title || pic.url].filter(Boolean).join('  |  '), title: pic.url }) : null);
    const badge = busy[k.Host] ? el('span', { class: 'busybadge' }, spinner('small'), busy[k.Host] + ' ...') : null;
    if (!pics.length) {
      tiles.push(el('div', { class: 'tile' },
        el('div', { class: 'shot none' }, k.HasLauncher ? 'No screenshot yet' : 'No new launcher: no screenshots', badge), caption(null)));
      continue;
    }
    for (const pic of pics) {
      const src = '/api/snapshots/' + encodeURIComponent(pic.file);
      tiles.push(el('div', { class: 'tile' + (k.Attention ? ' attn' : '') },
        el('a', { class: 'shot', href: src, target: '_blank', rel: 'noopener', title: 'Open full size' },
          el('img', { src, alt: `What was on ${k.Host} ${pic.screen}`, loading: 'lazy' }), badge),
        caption(pic)));
    }
  }
  setKids(grid, tiles);
}

async function takeScreens(auto) {
  const Sc = S.screens;
  if (Sc.taking || !can('snapshot')) return;
  const hosts = screenKiosks().filter((k) => k.HasLauncher).map((k) => k.Host);
  const note = $('#snote');
  if (!hosts.length) { if (note) note.textContent = 'None of the kiosks shown has a new launcher to take one.'; return; }
  Sc.taking = true;
  Sc.lastAuto = Date.now();
  drawScreens(true);
  let r;
  try { r = await api('POST', '/api/group/snapshot', { hosts }); }
  catch (e) {
    Sc.taking = false;
    if (note) note.textContent = e.message;
    if (!auto) toast(e.message, 'WARNING', 8);
    drawScreens(true);
    return;
  }
  let done = 0, bad = 0;
  const total = r.jobs.length;
  const say = () => { if ($('#snote')) $('#snote').textContent = `taking ${total} ${plural(total, 'screenshot', 'screenshots')}: ${done} done${bad ? `, ${bad} failed` : ''}${r.skipped.length ? `, ${r.skipped.length} skipped` : ''}`; };
  say();
  refreshSoon();
  let reload = null;
  try {
    await followJobs(r.jobs, (host, j) => {
      done++;
      if (!j.ok) bad++;
      say();
      clearTimeout(reload);
      reload = setTimeout(loadScreens, 800);
    });
  } catch (e) { /* signed out */ }
  Sc.taking = false;
  refreshSoon();
  const when = new Date().toLocaleTimeString();
  if ($('#snote')) $('#snote').textContent = `${done - bad} new at ${when}${bad ? `, ${bad} failed` : ''}${r.skipped.length ? `, ${r.skipped.length} skipped` : ''}`;
  loadScreens();
}

function autoScreens() {
  const Sc = S.screens;
  if (!Sc.auto || Sc.taking || S.view !== 'Screens' || document.visibilityState !== 'visible') return;
  if (!Sc.lastAuto) { Sc.lastAuto = Date.now(); return; }
  if (Date.now() - Sc.lastAuto >= Sc.auto * 60000) takeScreens(true);
}

// ---------------------------------------------------------------------------
// History: one kiosk over the weeks, from the events the collector keeps
// ---------------------------------------------------------------------------
const RANGES = [7, 14, 28, 90];

function openHistory(host) {
  S.history.host = host;
  S.history.data = null;
  show('History');
}

async function loadHistory() {
  const H = S.history;
  if (!H.host) {
    const ks = S.fleet && S.fleet.Ok ? S.fleet.Kiosks : [];
    H.host = (ks.find((k) => k.Attention) || ks[0] || {}).Host || null;
  }
  if (!H.host) { if (S.view === 'History') renderHistory($('#main'), true); return; }
  const seq = ++H.seq;
  H.loading = true;
  H.error = '';
  if (S.view === 'History') renderHistory($('#main'), true);
  try {
    const d = await api('GET', `/api/kiosks/${encodeURIComponent(H.host)}/history?days=${H.days}`);
    if (seq !== H.seq) return;
    H.data = d;
  } catch (e) {
    if (seq !== H.seq) return;
    H.data = null;
    H.error = e.message;
  }
  H.loading = false;
  if (S.view === 'History') renderHistory($('#main'), true);
}

const localTime = (iso) => new Date(iso);  // the server's local ISO times, no zone: read as local
const shortWhen = (iso) => (iso || '').replace('T', ' ').slice(0, 16);

function renderHistory(main, force) {
  const H = S.history;
  if (!$('#htool', main)) {
    setKids(main,
      el('h2', { text: 'History' }),
      el('p', { class: 'sub', text: 'One kiosk over the weeks: how its status went, how often it rebooted and why, and how long it stayed up - from the events file the scans keep. Time no scan looked at is shown as no data, not as fine.' }),
      el('div', { class: 'toolbar', id: 'htool' }),
      el('div', { id: 'hbody' }));
    force = true;
  }
  // The toolbar is built once; its kiosk box is refilled when the fleet
  // changes, unless someone has it open.
  const tool = $('#htool', main);
  if (!tool.children.length) {
    const pick = el('select', { id: 'hpick', 'aria-label': 'Which kiosk' });
    pick.addEventListener('change', () => { H.host = pick.value; H.data = null; loadHistory(); });
    setKids(tool, pick,
      el('div', { class: 'seg', id: 'hrange', role: 'radiogroup', 'aria-label': 'How far back', style: { marginBottom: '0' } },
        RANGES.map((d) => el('button', { type: 'button', class: 'btn small', role: 'radio', 'data-days': String(d),
          text: d === 7 ? '1 week' : d === 90 ? '90 days' : `${d / 7} weeks`, onclick: () => { H.days = d; loadHistory(); } }))),
      el('button', { class: 'btn small', type: 'button', text: 'Refresh', onclick: loadHistory }),
      el('button', { class: 'btn small', type: 'button', id: 'hopen', onclick: () => { const k = getKiosk(H.host); if (k) show(k.Tab, k.Host); } }));
  }
  const pick = $('#hpick', tool);
  if (document.activeElement !== pick) {
    const ks = S.fleet && S.fleet.Ok ? S.fleet.Kiosks.slice().sort((a, b) => a.Host.localeCompare(b.Host, undefined, { numeric: true })) : [];
    setKids(pick, ks.map((k) => el('option', { value: k.Host, text: `${k.Host}${k.Location ? '  -  ' + k.Location : ''}${k.Attention ? '  (' + k.Status + ')' : ''}` })));
    if (H.host && !ks.some((k) => k.Host === H.host)) pick.append(el('option', { value: H.host, text: H.host }));
    pick.value = H.host || '';
  }
  for (const b of tool.querySelectorAll('#hrange button')) {
    const on = Number(b.dataset.days) === H.days;
    b.classList.toggle('on', on);
    b.setAttribute('aria-checked', String(on));
  }
  const cur = H.host ? getKiosk(H.host) : null;
  const open = $('#hopen', tool);
  open.classList.toggle('hidden', !cur);
  if (cur) open.textContent = `Open in ${TAB_TITLE[cur.Tab] || cur.Tab}`;
  if (!force) return;
  const box = $('#hbody', main);
  if (!H.host) { setKids(box, el('div', { class: 'card empty', text: 'No kiosks in the data yet.' })); return; }
  if (H.error) { setKids(box, el('div', { class: 'card empty sev-CRITICAL', text: H.error })); return; }
  if (!H.data) { setKids(box, loadingCard('Reading the events ...')); return; }
  const d = H.data;
  const k = getKiosk(d.Host);
  const stat = (label, n, note, sev, icon) => el('div', { class: 'card stat' + (sev ? ' tone-' + sev : ''), 'data-icon': icon },
    el('div', { class: 'l', text: label }), el('div', { class: 'n' + (sev ? ' sev-' + sev : ''), text: String(n) }), el('div', { class: 'note', text: note }));
  const avail = d.Availability;
  const availSev = avail == null ? 'INACTIVE' : avail >= 99 ? 'OK' : avail >= 95 ? 'WARNING' : 'CRITICAL';
  const hours = (h) => (h == null ? '-' : h >= 48 ? `${Math.round(h / 24)}d` : `${Math.round(h)}h`);
  const stats = el('div', { class: 'stats' },
    stat('FINE', avail == null ? '-' : avail + '%', d.Coverage < 99.5 ? `of the time scanned (${d.Coverage}% of it was)` : 'of the time', availSev, 'check'),
    stat('REBOOTS', d.Reboots, d.ScriptReboots ? `${d.ScriptReboots} by the watchdog` : 'none by the watchdog', d.ScriptReboots ? 'WARNING' : '', 'reboot'),
    stat('SCREEN EVENTS', d.Episodes, 'white or blank screens', d.Episodes ? 'WARNING' : '', 'Screens'),
    stat('LONGEST UP', hours(d.LongestRunHours), d.MeanRunHours != null ? `${hours(d.MeanRunHours)} between reboots on average` : 'no two reboots to measure between', '', 'History'),
    stat('UP NOW', d.Uptime || '-', 'since its last boot', '', 'launcher'),
    stat('STATUS CHANGES', d.Changes, `over ${d.Days} days`, '', 'Activity'));

  // The timeline: one bar, a block per status, with day marks under it.
  const from = localTime(d.From), to = localTime(d.To);
  const span = Math.max(1, to - from);
  const bar = el('div', { class: 'timeline', role: 'img', 'aria-label': `Status of ${d.Host} from ${shortWhen(d.From)} to ${shortWhen(d.To)}` },
    d.Timeline.map((t) => el('i', { class: t.Severity, style: { left: t.Left + '%', width: t.Width + '%' },
      title: `${t.Status === 'NO_DATA' ? 'no data' : t.Status}  ${shortWhen(t.From)} - ${shortWhen(t.To)}  (${t.For})` })));
  const step = d.Days <= 14 ? 1 : d.Days <= 31 ? 7 : 14;
  const ticks = [];
  for (let i = 0; i < d.PerDay.length; i += step) {
    const day = d.PerDay[i];
    // Each day's name under its middle; a week's mark at its start.
    const at = localTime(day.Date + 'T00:00:00').getTime() + (step === 1 ? 12 * 3600 * 1000 : 0);
    const left = Math.min(100, (100 * (at - from)) / span);
    if (left > 97) continue;
    ticks.push(el('span', { class: i === 0 && step > 1 ? 'first' : '', style: { left: left + '%' }, text: step === 1 ? `${day.Weekday} ${day.Label}` : day.Label }));
  }
  const legend = el('div', { class: 'legend' }, d.ByStatus.map((b) => el('span', null,
    pill(b.Status === 'NO_DATA' ? 'NO DATA' : b.Status, b.Severity), `${b.Text} (${b.Pct}%)`)));

  // Reboots per day, the watchdog's part on top; how fine each day was under it.
  const max = Math.max(1, ...d.PerDay.map((p) => p.Reboots));
  const many = d.PerDay.length > 31;
  const chart = el('div', { class: 'chart' + (d.PerDay.length > 14 ? ' many' : ''), role: 'img', 'aria-label': 'Reboots per day' },
    d.PerDay.map((p, i) => {
      const hTot = p.Reboots ? Math.max(3, Math.round(90 * p.Reboots / max)) : 2;
      const hScript = p.Reboots ? Math.round(hTot * p.Script / p.Reboots) : 0;
      const label = many ? (i % 7 === 0 ? p.Label : '') : (d.PerDay.length > 14 ? (i % 7 === 0 ? p.Label : p.Label.slice(0, 2)) : `${p.Weekday} ${p.Label.slice(0, 2)}`);
      return el('div', { class: 'col', title: `${p.Weekday} ${p.Label}: ${p.Reboots} ${plural(p.Reboots, 'reboot', 'reboots')}${p.Script ? ` (${p.Script} by the watchdog)` : ''}, ${p.Episodes} screen ${plural(p.Episodes, 'event', 'events')}${p.OkPct == null ? ', no data' : `, fine ${p.OkPct}% of the day`}` },
        el('span', { class: 'c', text: p.Reboots && !many ? String(p.Reboots) : '' }),
        hScript ? el('div', { class: 'bar script', style: { height: hScript + 'px' } }) : null,
        hTot - hScript > 0 ? el('div', { class: 'bar', style: { height: (hTot - hScript) + 'px', opacity: p.Reboots ? '1' : '.25' } }) : null,
        el('span', { class: 'd' + (p.Weekday === 'Mon' ? ' wk' : ''), text: label }));
    }));
  const strip = el('div', { class: 'okstrip', 'aria-hidden': 'true' }, d.PerDay.map((p) => el('i', {
    class: p.OkPct == null ? '' : p.OkPct >= 99 ? 'OK' : p.OkPct >= 90 ? 'WARNING' : 'CRITICAL',
    title: `${p.Weekday} ${p.Label}: ${p.OkPct == null ? 'no data' : 'fine ' + p.OkPct + '% of the day'}` })));

  const runs = d.Runs.length ? el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['UP FROM', 'UNTIL', 'FOR', 'ENDED BY', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, d.Runs.map((r) => el('tr', null,
      el('td', { text: r.Open ? `before ${shortWhen(r.From)}` : shortWhen(r.From) }),
      el('td', { class: r.Running ? 'sev-OK' : '', text: r.Running ? 'now - still up' : shortWhen(r.To) }),
      el('td', { text: (r.Open ? 'over ' : '') + r.For }),
      el('td', { class: r.EndedBy === 'the watchdog' ? 'sev-WARNING' : '', text: r.EndedBy }),
      el('td', { class: 'dim', text: r.Detail, title: r.Detail }))))))
    : el('div', { class: 'card empty', text: 'No reboots in this time.' });
  const sevOf = (e) => (e.Severity === 'CRITICAL' || e.Severity === 'ERROR' ? 'CRITICAL' : e.Severity === 'WARNING' ? 'WARNING' : 'DIM');
  const events = d.Events.length ? el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['WHEN', 'WHAT', 'OUTCOME', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, d.Events.map((e) => el('tr', null,
      el('td', { text: shortWhen(e.Time) }),
      el('td', { class: 'sev-' + sevOf(e), text: e.Type + (e.Reboot ? (e.Script ? '  (reboot, watchdog)' : '  (reboot)') : '') }),
      el('td', { text: e.Outcome }),
      el('td', { class: 'dim', text: e.Detail, title: e.Detail }))))))
    : el('div', { class: 'card empty', text: 'Nothing happened in this time.' });

  setKids(box,
    el('div', { class: 'hhead' },
      el('span', { class: 'host', text: d.Host }), el('span', { class: 'dim', text: [d.Location, d.Type].filter(Boolean).join('  |  ') }),
      k ? pill(k.Status, k.Severity) : (d.Status ? pill(d.Status, 'UNKNOWN') : pill('NOT IN THE LAST SCAN', 'INACTIVE')),
      el('span', { class: 'dim', text: `${shortWhen(d.From)} to ${shortWhen(d.To)}` })),
    stats,
    el('h3', { text: 'STATUS' }),
    el('div', { class: 'card' }, bar, el('div', { class: 'ticks' }, ticks), legend),
    el('h3', { text: 'REBOOTS PER DAY (THE WATCHDOG\'S IN RED); HOW FINE EACH DAY WAS BELOW' }),
    el('div', { class: 'card' }, chart, strip),
    el('div', { class: 'hgrid' },
      el('div', null, el('h3', { text: 'UP BETWEEN REBOOTS' }), runs),
      el('div', null, el('h3', { text: `EVENTS${d.EventCount > d.Events.length ? ` (THE NEWEST ${d.Events.length} OF ${d.EventCount})` : ''}` }), events)));
}

// ---------------------------------------------------------------------------
// The kiosk list, edited here: what is scanned, and what each kiosk is
// ---------------------------------------------------------------------------
async function loadKioskList() {
  try { S.klist.data = await api('GET', '/api/kiosklist'); } catch (e) { S.klist.data = { error: e.message, rows: [] }; }
  if (S.view === 'KioskList') renderKioskList($('#main'), true);
}

const ACTIVE_OPTIONS = [
  { value: '', text: 'Not set - scanned if it runs the watchdog, or is Power BI or a web page' },
  { value: 'Y', text: 'Yes - scanned' },
  { value: 'N', text: 'No - not scanned (shown as INACTIVE)' }
];

function renderKioskList(main, force) {
  if (!can('kiosklist')) { setKids(main, el('div', { class: 'card empty', text: 'The kiosk list is for admins.' })); return; }
  const K = S.klist;
  if (!$('#ltool', main)) {
    const search = el('input', { type: 'search', placeholder: 'Filter: name, location, type, group, info', value: K.filter, 'aria-label': 'Filter the list' });
    search.addEventListener('input', () => { K.filter = search.value; drawKioskList(); });
    const which = el('select', { 'aria-label': 'Which rows' },
      el('option', { value: 'all', text: 'Every row' }), el('option', { value: 'scanned', text: 'Scanned' }), el('option', { value: 'not', text: 'Not scanned' }));
    which.value = K.show;
    which.addEventListener('change', () => { K.show = which.value; drawKioskList(); });
    setKids(main,
      el('h2', { text: 'Kiosk list' }),
      el('p', { class: 'sub', text: 'Which kiosks the scans look at, and where each one is. A change here applies at the next scan; the list stays a file you can download, change in Excel and upload again in Settings.' }),
      el('div', { class: 'toolbar', id: 'ltool' }, search, which,
        el('button', { class: 'btn small primary', type: 'button', id: 'ladd', text: 'Add a kiosk...', onclick: () => kioskRowDialog(null) }),
        el('a', { class: 'btn small', href: '/api/settings/kiosk-list', id: 'ldown', text: 'Download' }),
        can('scan') ? el('button', { class: 'btn small', type: 'button', text: 'Scan now', onclick: scanNow }) : null),
      el('div', { id: 'lnote' }),
      el('div', { id: 'llist' }));
    force = true;
  }
  if (force) drawKioskList();
}

function kioskListRows() {
  const K = S.klist;
  const t = K.filter.trim().toLowerCase();
  return ((K.data && K.data.rows) || []).filter((r) =>
    (K.show === 'all' || (K.show === 'scanned') === r.scanned) &&
    (!t || [r.host, r.location, r.type, r.restartGroup, r.info, r.why].some((x) => x && x.toLowerCase().includes(t))));
}

function drawKioskList() {
  const box = $('#llist'), note = $('#lnote');
  if (!box) return;
  const d = S.klist.data;
  if (!d) { setKids(box, loadingCard('Reading the list ...')); return; }
  const editable = !!d.editable;
  $('#ladd').disabled = !editable;
  $('#ldown').classList.toggle('hidden', !d.path);
  const notes = [];
  if (d.error) notes.push(el('p', { class: 'sev-CRITICAL', text: 'The list could not be read: ' + d.error }));
  if (d.fixed) notes.push(el('p', { class: 'hint', text: `This server reads the list named by KFW_KIOSK_LIST (${d.path}); change it there. It is shown here as it is.` }));
  else if (!d.path) notes.push(el('p', { class: 'hint', text: 'There is no kiosk list yet. Add kiosks here one by one, or upload the master list in Settings.' }));
  else if (d.converts) notes.push(el('p', { class: 'hint', text: `The list is ${d.path.split('/').pop()}. The first change here keeps every row of it in kiosk-list.csv instead, and puts the original aside as kiosk-list-before-edit.` }));
  if (d.total) notes.push(el('p', { class: 'dim', text: `${d.total} ${plural(d.total, 'row', 'rows')}, ${d.scanned} scanned.` }));
  setKids(note, notes);
  const rows = kioskListRows();
  if (!d.rows.length) { setKids(box, el('div', { class: 'card empty', text: 'No kiosks in the list.' })); return; }
  if (!rows.length) { setKids(box, el('div', { class: 'card empty', text: 'Nothing matches.' })); return; }
  setKids(box, el('div', { class: 'tablewrap klist' }, el('table', null,
    el('thead', null, el('tr', null, ['KIOSK', 'LOCATION', 'TYPE', 'WATCHDOG', 'ACTIVE', 'GROUP', 'INFO', 'SCANNED', ''].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, rows.map((r) => el('tr', { class: r.scanned ? '' : 'dim' },
      el('td', { class: 'host', text: r.host }), el('td', { text: r.location }), el('td', { text: r.type, title: r.kind }),
      el('td', { text: r.watchdog ? 'yes' : '' }), el('td', { text: r.active === 'Y' ? 'yes' : r.active === 'N' ? 'no' : '-' }),
      el('td', { text: r.restartGroup }), el('td', { class: 'dim', text: r.info, title: r.info }),
      el('td', { class: r.scanned ? 'sev-OK' : 'sev-INACTIVE', text: r.scanned ? 'yes' : r.why }),
      el('td', null, el('div', { class: 'btnrow' },
        el('button', { class: 'btn small', type: 'button', text: 'Change...', disabled: !editable, onclick: () => kioskRowDialog(r) }),
        el('button', { class: 'btn small', type: 'button', text: r.scanned ? 'Stop scanning' : 'Scan it', disabled: !editable,
          title: r.scanned ? 'Active = no: kept in the list, shown as INACTIVE, not scanned' : 'Active = yes', onclick: () => setRowActive(r, !r.scanned) })))))))));
}

async function listChanged(text) {
  toast(text, 'OK');
  await loadKioskList();
  refreshSoon();
}

async function setRowActive(r, on) {
  try {
    await api('POST', '/api/kiosklist/active', { row: r.row, was: r.host, active: on });
    listChanged(`${r.host}: ${on ? 'scanned again' : 'not scanned any more'} from the next scan.`);
  } catch (e) { toast(e.message, 'CRITICAL', 10); if (e.status === 409) loadKioskList(); }
}

function kioskRowDialog(r, preset) {
  const isNew = !r;
  const v0 = r || Object.assign({ host: '', location: '', type: 'Mach2', watchdog: true, active: '', restartGroup: '', info: '', version: '' }, preset || {});
  openModal({
    title: isNew ? 'Add a kiosk to the list' : `${r.host} in the kiosk list`,
    sub: isNew ? 'It is scanned from the next scan on.' : (r.scanned ? 'Scanned.' : `Not scanned: ${r.why}.`) + (r.sheet && r.sheet !== 'csv' ? ` From the sheet ${r.sheet}.` : ''),
    fields: [
      { key: 'host', label: 'Kiosk name', value: v0.host, max: 63, hint: 'The name the kiosk answers to on the network.' },
      { key: 'location', label: 'Location', value: v0.location, max: 200, hint: 'Where it is: a line, a room. Kiosks in one location can be picked together on their tab.' },
      { key: 'type', label: 'Type', value: v0.type, max: 200, hint: 'Mach2 for a Mach2 dashboard; PBI or Power BI ... for a Power BI screen; Web ... for a web page screen; anything else is Other.' },
      { key: 'watchdog', label: 'Has MWST', kind: 'bool', value: v0.watchdog ? '1' : '0', hint: 'runs the MWST watchdog (Mach2 kiosks)' },
      { key: 'active', label: 'Active', kind: 'choice', value: v0.active, options: ACTIVE_OPTIONS },
      { key: 'restartGroup', label: 'Restart group', value: v0.restartGroup, max: 200, advanced: true },
      { key: 'info', label: 'Info', value: v0.info, max: 200, advanced: true },
      { key: 'version', label: 'Listed version', value: v0.version, max: 200, advanced: true }
    ],
    extra: isNew ? null : el('div', { class: 'btnrow' },
      el('button', { class: 'btn small', type: 'button', text: 'History', onclick: () => { closeModal(); openHistory(r.host); } }),
      el('button', { class: 'btn small danger', type: 'button', text: 'Remove from the list...', onclick: () => removeRowDialog(r) })),
    okText: isNew ? 'Add it' : 'Save',
    onOk: async (v, m) => {
      const name = (v.host || '').trim().replace(/^\\+|\\+$/g, '');
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { m.setNote('That is not a kiosk name.', 'CRITICAL'); return true; }
      m.busy(true);
      const body = { host: name, location: v.location, type: v.type, watchdog: v.watchdog === '1', active: v.active,
        restartGroup: v.restartGroup, info: v.info, version: v.version };
      if (!isNew) Object.assign(body, { row: r.row, was: r.host });
      try {
        const res = await api('POST', '/api/kiosklist', body);
        listChanged(`${res.host}: ${res.change}.`);
      } catch (e) {
        m.busy(false);
        m.setNote(e.message, 'CRITICAL');
        if (e.status === 409) loadKioskList();
        return true;
      }
    }
  });
}

function removeRowDialog(r) {
  openModal({
    title: `Remove ${r.host} from the list?`, danger: true, okText: 'Remove it',
    body: 'It is not scanned any more and drops off the tabs. Its history stays in the events file. To stop scanning a kiosk for a while, set Active to no instead: it stays in the list and shows as INACTIVE.',
    onOk: async (v, m) => {
      try {
        await api('POST', '/api/kiosklist/remove', { row: r.row, was: r.host });
        listChanged(`${r.host} removed from the list.`);
      } catch (e) { m.setNote(e.message, 'CRITICAL'); if (e.status === 409) loadKioskList(); return true; }
    }
  });
}

// From a kiosk's detail: its row in the list, or a new one filled in from the scan.
async function listEntryFor(k) {
  if (!S.klist.data || !S.klist.data.rows) {
    try { S.klist.data = await api('GET', '/api/kiosklist'); } catch (e) { toast(e.message, 'CRITICAL'); return; }
  }
  const d = S.klist.data;
  const r = (d.rows || []).find((x) => x.host.toLowerCase() === k.Host.toLowerCase());
  if (r) return kioskRowDialog(r);
  if (!d.editable) { toast(`${k.Host} is not in the kiosk list, and the list cannot be edited here.`, 'WARNING'); return; }
  kioskRowDialog(null, { host: k.Host, location: k.Location, type: k.Type, watchdog: k.Tab === 'Mach2' });
}

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------
async function loadReports() {
  try { S.reports = (await api('GET', '/api/reports')).reports; } catch (e) { S.reports = []; }
  if (S.view === 'Activity') renderReports();
}

async function pollRun() {
  clearTimeout(S.run.timer);
  if (S.view !== 'Activity' || !S.me) return;
  try {
    const r = await api('GET', '/api/run?from=' + S.run.from);
    if (r.text) {
      S.run.text += r.text;
      if (S.run.text.length > 1500000) S.run.text = S.run.text.slice(-1000000);
      const pre = $('#console');
      if (pre) {
        const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
        pre.textContent = S.run.text || 'Nothing has run since the server started.';
        if (atEnd) pre.scrollTop = pre.scrollHeight;
      }
    }
    S.run.from = r.next;
    if (S.run.wasRunning && !r.running) loadReports();
    S.run.wasRunning = r.running;
  } catch (e) { /* the next tick tries again */ }
  S.run.timer = setTimeout(pollRun, S.live && S.live.run ? 1000 : 3000);
}

function renderActivity(main) {
  if (!$('#console', main)) {
    main.append(
      el('h2', { text: 'Activity' }),
      el('p', { class: 'sub', text: 'The output of every scan as it happens, whoever started it. Each run\'s output is kept on the server (logs/run in the data folder) for two weeks.' }),
      el('div', { class: 'toolbar', id: 'atool' }),
      el('div', { class: 'scanpanel', id: 'scanpanel' }, irisPre(44, 26, false), el('div', { class: 'scaninfo', id: 'scaninfo' })),
      el('pre', { class: 'console', id: 'console', tabindex: '0', 'aria-label': 'Output', text: S.run.text || 'Nothing has run since the server started.' }),
      el('h3', { text: 'REPORTS' }),
      el('div', { id: 'reports' }));
    renderReports();
    const pre = $('#console', main);
    pre.scrollTop = pre.scrollHeight;
  }
  const run = S.live.run, last = S.live.lastRun;
  renderScanPanel(main, run, last);
  const state = run ? `${run.title} - running for ${run.elapsed} (${run.who})`
    : last ? `${last.Title} - finished with code ${last.Code} after ${last.Seconds}s at ${last.Finished}` : 'Nothing running.';
  setKids($('#atool', main), 
    el('span', { class: run ? 'sev-UNKNOWN' : (last && last.Code !== 0 ? 'sev-WARNING' : 'dim'), text: state }),
    el('span', { style: { flex: '1' } }),
    can('stoprun') ? el('button', { class: 'btn small danger', type: 'button', text: 'Stop it', disabled: !run, onclick: stopRun }) : null,
    el('button', { class: 'btn small', type: 'button', text: 'Clear', onclick: () => { S.run.text = ''; $('#console').textContent = ''; } }),
    el('button', { class: 'btn small', type: 'button', text: 'Save output', onclick: saveOutput }));
}

// The iris turns while a scan runs; at rest, it shows how the last one went.
function renderScanPanel(main, run, last) {
  const panel = $('#scanpanel', main);
  if (!panel) return;
  setIrisLive($('pre.iris', panel), !!run);
  panel.className = 'scanpanel ' + (run ? 'running' : last && last.Code !== 0 ? 'warn' : 'idle');
  const big = (t) => el('div', { class: 'scanbig', text: t });
  const kv = (k, v) => el('div', { class: 'scankv' }, el('span', { text: k }), el('span', { text: v }));
  let kids;
  if (run) {
    const pct = run.scan ? run.scan.pct : 0;
    kids = [big(run.kind === 'scan' ? 'SCANNING' : 'RUNNING'),
      el('div', { class: 'scanbar2' }, el('i', { style: { width: pct + '%' } })),
      kv('progress', run.scan ? `${pct}%  ${run.scan.text}` : 'starting ...'),
      kv('task', run.title), kv('running for', run.elapsed), kv('started by', run.who)];
  } else if (last) {
    kids = [big(last.Code === 0 ? 'STANDING BY' : 'LAST RUN FAILED'),
      kv('last', last.Title), kv('finished', `${last.Finished}, after ${last.Seconds}s`), kv('exit code', String(last.Code)),
      el('div', { class: 'scanhint', text: 'Scan now (top right) starts one.' })];
  } else {
    kids = [big('STANDING BY'), kv('last', 'nothing since the server started'), el('div', { class: 'scanhint', text: 'Scan now (top right) starts one.' })];
  }
  setKids($('#scaninfo', panel), ...kids);
}

function saveOutput() {
  const blob = new Blob([S.run.text], { type: 'text/plain' });
  const a = el('a', { href: URL.createObjectURL(blob), download: 'kiosk-fleet-output.txt' });
  document.body.append(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function renderReports() {
  const box = $('#reports');
  if (!box) return;
  if (!S.reports.length) { setKids(box, el('div', { class: 'card empty', text: 'No reports yet.' })); return; }
  setKids(box, el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['WHEN', 'WHAT', 'FILE'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, S.reports.map((r) => el('tr', null,
      el('td', { text: r.when }), el('td', { text: r.kind }),
      el('td', null, el('a', { href: '/api/reports/' + encodeURIComponent(r.name), download: r.name, text: r.name }))))))));
}

function stopRun() {
  openModal({
    title: 'Stop it?', danger: true, okText: 'Stop it',
    body: `${S.live.run ? S.live.run.title : 'It'} is still running. Stopping it ends the scan where it is; what it found so far is not written.`,
    onOk: async () => {
      try { await api('POST', '/api/run/stop'); toast('Stopped.', 'WARNING'); refreshSoon(); }
      catch (e) { toast(e.message, 'CRITICAL'); }
    }
  });
}

// ---------------------------------------------------------------------------
// Audit
// ---------------------------------------------------------------------------
async function loadAudit() {
  try { S.audit = (await api('GET', '/api/audit?q=' + encodeURIComponent(S.auditFilter))).entries; } catch (e) { S.audit = []; toast(e.message, 'WARNING'); }
  if (S.view === 'Audit') renderAudit($('#main'), true);
}

function renderAudit(main, force) {
  if (!$('#atool2', main)) {
    const search = el('input', { type: 'search', value: S.auditFilter, placeholder: 'Search: user, action, kiosk, result, detail', 'aria-label': 'Search the audit log' });
    let t = null;
    search.addEventListener('input', () => { S.auditFilter = search.value; clearTimeout(t); t = setTimeout(loadAudit, 300); });
    setKids(main,
      el('h2', { text: 'Audit log' }),
      el('p', { class: 'sub', text: 'Who did what, newest first: every sign-in, every action on a kiosk, every scan, every change to an account. The newest 400 that match are shown; the whole log downloads as CSV.' }),
      el('div', { class: 'toolbar', id: 'atool2' }, search,
        el('button', { class: 'btn small', type: 'button', text: 'Refresh', onclick: loadAudit }),
        el('a', { class: 'btn small', href: '/api/audit.csv', download: 'kiosk-fleet-audit.csv', text: 'Download all (CSV)' })),
      el('div', { id: 'audit' }));
    force = true;
  }
  if (!force) return;
  const res = (r) => (r === 'ok' || r === 'started' ? 'sev-OK' : r === 'failed' || r === 'refused' ? 'sev-CRITICAL' : r === 'waiting' ? 'sev-WARNING' : 'dim');
  setKids($('#audit', main), S.audit.length ? el('div', { class: 'tablewrap' }, el('table', null,
    el('thead', null, el('tr', null, ['TIME', 'USER', 'ROLE', 'FROM', 'ACTION', 'TARGET', 'RESULT', 'DETAIL'].map((h) => el('th', { class: 'nosort', text: h })))),
    el('tbody', null, S.audit.map((a) => el('tr', null,
      el('td', { text: (a.Time || '').replace('T', ' ') }), el('td', { text: a.User }), el('td', { text: a.Role }),
      el('td', { class: 'dim', text: a.Ip }), el('td', { text: a.Action }), el('td', { text: a.Target, title: a.Target }),
      el('td', { class: res(a.Result), text: a.Result }), el('td', { class: 'dim', text: a.Detail, title: a.Detail }))))))
    : el('div', { class: 'card empty', text: S.auditFilter ? 'Nothing matches.' : 'Nothing yet.' }));
}

// ---------------------------------------------------------------------------
// Your own password
// ---------------------------------------------------------------------------
function changePasswordDialog() {
  openModal({
    title: 'Change your password', sub: S.me.user,
    fields: [{ key: 'current', label: 'Current password', kind: 'secret' }, { key: 'password', label: 'New password', kind: 'password' }],
    note: 'At least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more. Your other sessions are signed out.',
    okText: 'Change it',
    onOk: async (v, m) => {
      if (v.password !== v['password.again']) { m.setNote('The two new passwords did not match.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        await api('POST', '/api/me/password', { current: v.current, password: v.password, password2: v['password.again'] });
        m.clearSecrets();
        m.finish('Changed.', 'OK');
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------
async function loadUsers() {
  try { S.users = (await api('GET', '/api/users')).users; } catch (e) { S.users = []; toast(e.message, 'WARNING'); }
  if (S.view === 'Users') renderUsers($('#main'), true);
}

function renderUsers(main, force) {
  if (!can('users')) { setKids(main, el('div', { class: 'card empty', text: 'Accounts are for admins.' })); return; }
  if ($('#users', main) && !force) return;
  const rows = S.users.map((u) => el('tr', { class: u.disabled ? 'dim' : '' },
    el('td', { class: 'host', text: u.name }),
    el('td', null, el('span', { class: 'role ' + u.role, text: u.role })),
    el('td', { class: u.disabled || u.mustChange ? 'sev-WARNING' : 'sev-OK', text: u.disabled ? 'disabled' : (u.mustChange ? 'must change password' : 'active') }),
    el('td', { text: (u.lastLogin || 'never').replace('T', ' ') }),
    el('td', { text: u.sessions ? String(u.sessions) : '' }),
    el('td', { text: (u.created || '').replace('T', ' ').slice(0, 16) }),
    el('td', null, el('button', { class: 'btn small', type: 'button', text: 'Change...', onclick: () => userDialog(u) }))));
  setKids(main,
    el('h2', { text: 'Users' }),
    el('p', { class: 'sub', text: 'Everyone signs in with an account of their own. Operators see everything and can do what cannot break a kiosk; admins can do everything, including this page.' }),
    el('div', { class: 'toolbar' }, el('button', { class: 'btn small primary', type: 'button', text: 'Add an account...', onclick: addUserDialog }),
      el('button', { class: 'btn small', type: 'button', text: 'Refresh', onclick: loadUsers })),
    el('div', { id: 'users' }, S.users.length ? el('div', { class: 'tablewrap' }, el('table', null,
      el('thead', null, el('tr', null, ['ACCOUNT', 'ROLE', 'STATE', 'LAST SIGN-IN', 'SESSIONS', 'CREATED', ''].map((h) => el('th', { class: 'nosort', text: h })))),
      el('tbody', null, rows))) : el('div', { class: 'card empty', text: 'No accounts.' })));
}

const ROLE_OPTIONS = [{ value: 'operator', text: 'Operator - sees everything; scan, read live, screenshot, reload, message, log' }, { value: 'admin', text: 'Admin - everything' }];

function addUserDialog() {
  openModal({
    title: 'Add an account',
    fields: [
      { key: 'name', label: 'Account name', hint: 'Letters, digits, dots, dashes, underscores or @ - an e-mail address works.', max: 64 },
      { key: 'role', label: 'Role', kind: 'choice', value: 'operator', options: ROLE_OPTIONS },
      { key: 'password', label: 'Password', kind: 'password' },
      { key: 'mustChange', label: 'At first sign-in', kind: 'bool', value: '1', hint: 'they choose a password of their own' }
    ],
    note: 'Any password will do here. They choose one of their own at first sign-in if that is ticked, and theirs needs at least 12 characters, with three of: lower case, upper case, digits, symbols - or 20 characters or more.',
    okText: 'Add it',
    onOk: async (v, m) => {
      if (v.password !== v['password.again']) { m.setNote('The two passwords did not match.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        await api('POST', '/api/users', { name: v.name, role: v.role, password: v.password, password2: v['password.again'], mustChange: v.mustChange === '1' });
        toast(`${v.name} added.`, 'OK');
        loadUsers();
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
}

function userDialog(u) {
  const self = u.name.toLowerCase() === S.me.user.toLowerCase();
  const m = openModal({
    title: u.name, sub: `${u.role}${u.disabled ? ', disabled' : ''}. Last sign-in: ${(u.lastLogin || 'never').replace('T', ' ')}.`,
    fields: [
      { key: 'role', label: 'Role', kind: 'choice', value: u.role, options: ROLE_OPTIONS },
      { key: 'disabled', label: 'Disabled', kind: 'bool', value: u.disabled ? '1' : '0', hint: 'cannot sign in; signed out at once' },
      { key: 'h1', label: 'NEW PASSWORD (leave empty to keep it; any password will do here)', kind: 'note' },
      { key: 'password', label: 'New password', kind: 'password' },
      { key: 'mustChange', label: 'At next sign-in', kind: 'bool', value: self ? '0' : '1', hint: 'they choose a password of their own' }
    ],
    extra: el('div', { class: 'btnrow' },
      el('button', { class: 'btn small', type: 'button', text: 'Sign out everywhere', onclick: async () => {
        try { await api('POST', '/api/users/' + encodeURIComponent(u.name), { signOut: true }); toast(`${u.name} is signed out.`, 'OK'); loadUsers(); }
        catch (e) { toast(e.message, 'CRITICAL'); }
      } }),
      self ? null : el('button', { class: 'btn small danger', type: 'button', text: 'Remove the account...', onclick: () => removeUserDialog(u) })),
    okText: 'Save',
    onOk: async (v, mm) => {
      const body = {};
      if (v.role !== u.role) body.role = v.role;
      if ((v.disabled === '1') !== u.disabled) body.disabled = v.disabled === '1';
      if (v.password || v['password.again']) {
        if (v.password !== v['password.again']) { mm.setNote('The two passwords did not match.', 'CRITICAL'); return true; }
        Object.assign(body, { password: v.password, password2: v['password.again'], mustChange: v.mustChange === '1' });
      }
      if (!Object.keys(body).length) return;
      mm.busy(true);
      try {
        const r = await api('POST', '/api/users/' + encodeURIComponent(u.name), body);
        toast(`${u.name}: ${r.changed.join(', ') || 'saved'}.`, 'OK');
        loadUsers();
      } catch (e) { mm.busy(false); mm.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
  return m;
}

function removeUserDialog(u) {
  openModal({
    title: `Remove ${u.name}?`, danger: true, okText: 'Remove it',
    body: 'The account goes, and with it every session it has open. What it did stays in the audit log. To stop someone signing in for a while, disable the account instead.',
    onOk: async (v, m) => {
      try { await api('DELETE', '/api/users/' + encodeURIComponent(u.name)); toast(`${u.name} removed.`, 'OK'); loadUsers(); }
      catch (e) { m.setNote(e.message, 'CRITICAL'); return true; }
    }
  });
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------
async function loadSettings() {
  try { S.settings = await api('GET', '/api/settings'); } catch (e) { S.settings = null; toast(e.message, 'WARNING'); }
  if (S.view === 'Settings') renderSettings($('#main'), true);
}

function renderSettings(main, force) {
  if (!can('settings')) { setKids(main, el('div', { class: 'card empty', text: 'Settings are for admins.' })); return; }
  if ($('#settings', main) && !force) return;
  const c = S.settings;
  if (!c) { setKids(main, el('h2', { text: 'Settings' }), loadingCard('Reading the settings ...', { id: 'settings' })); return; }
  const kv = (k, v, cls) => [el('div', { class: 'k', text: k }), el('div', { class: 'v' + (cls ? ' ' + cls : ''), text: v })];
  const L = c.kioskList;
  const file = el('input', { type: 'file', accept: '.xlsx,.csv,.txt', 'aria-label': 'Kiosk list file' });
  const upNote = el('div', { class: 'note', role: 'status' });
  const upload = el('button', { class: 'btn small primary', type: 'button', text: 'Upload', disabled: c.kioskListFixed, onclick: async () => {
    if (!file.files.length) { upNote.textContent = 'Pick a file first.'; upNote.className = 'note sev-WARNING'; return; }
    const fd = new FormData();
    fd.append('file', file.files[0]);
    upload.disabled = true;
    upNote.textContent = 'uploading ...';
    upNote.className = 'note';
    try {
      const r = await fetch('/api/settings/kiosk-list', { method: 'POST', body: fd, credentials: 'same-origin', headers: { 'X-Fleet-Csrf': S.me.csrf } });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.error || ('HTTP ' + r.status));
      toast(`Kiosk list saved: ${d.kiosks} kiosks to scan.`, 'OK');
      loadSettings();
      refreshSoon();
    } catch (e) { upNote.textContent = e.message; upNote.className = 'note sev-CRITICAL'; upload.disabled = false; }
  } });
  const listCard = el('div', { class: 'card' },
    L.exists ? el('div', { class: 'kv' },
      kv('File', L.path, 'dim'), kv('Changed', L.modified || ''),
      L.error ? kv('Problem', L.error, 'sev-CRITICAL') : [kv('Rows', String(L.rows)), kv('To scan', `${L.included} (${L.watchdog} with the watchdog)`),
        kv('Not scanned', `${L.inactive} not active, ${L.notFlagged} not flagged`)])
      : el('p', { class: 'sev-WARNING', text: 'No kiosk list yet.' }),
    el('p', { class: 'hint', text: 'An .xlsx (the master kiosk list: NAME or HOST, TYPE, HAS MWST, ACTIVE, LOCATION, RESTART GROUP columns), a .csv with Host, Location, Type, HasMwst, Active, RestartGroup, or a .txt with one kiosk name per line.' }),
    c.kioskListFixed ? el('p', { class: 'hint', text: 'This server reads the list named by KFW_KIOSK_LIST; change it there.' })
      : el('div', { class: 'btnrow' }, file, upload, L.exists ? el('a', { class: 'btn small', href: '/api/settings/kiosk-list', text: 'Download the current one' }) : null),
    el('div', { class: 'btnrow', style: { marginTop: '8px' } }, el('button', { class: 'btn small', type: 'button', text: c.kioskListFixed ? 'See the list' : 'Edit the list here', onclick: () => show('KioskList') })),
    upNote);
  const k = c.kiosks;
  const kioskCard = el('div', { class: 'card' }, el('div', { class: 'kv' },
    kv('Kiosk share', k.shareTemplate.replace('{0}', '<kiosk>'), 'dim'),
    kv('Reached over', k.smb ? `SMB, ${k.auth}` : 'a local folder (test or demo kiosks)'),
    k.smb ? kv('Share account', k.credential ? k.user : 'none - set KFW_SHARE_USER and KFW_SHARE_PASSWORD', k.credential ? '' : 'sev-CRITICAL') : null),
    el('div', { class: 'btnrow', style: { marginTop: '10px' } }, el('button', { class: 'btn small', type: 'button', text: 'Test a kiosk...', onclick: testKioskDialog })));
  const col = c.collector, ses = c.sessions, d = c.data;
  const other = el('div', { class: 'card' }, el('div', { class: 'kv' },
    kv('Data folder', d.dir, 'dim'), kv('Events file', d.csv, 'dim'), kv('Also published to', d.published || '-', 'dim'),
    kv('Auto-scan', `${col.autoscanDefault ? 'on at start' : 'off at start'}, every ${col.minutes} min`),
    kv('Kiosks at a time', String(col.parallel)), kv('Give up on a kiosk after', col.hostTimeout + ' s'),
    kv('Keep events for', col.retentionDays + ' days'), kv('Trust watchdog data from', 'v' + col.trustedFrom),
    kv('Sessions', `signed out after ${ses.idleMinutes} min idle, ${ses.hours} h at most`),
    kv('Secure cookies', ses.secureCookies + (ses.trustProxy ? ', behind a trusted proxy' : '')),
    kv('Version', c.version)));
  setKids(main,
    el('h2', { text: 'Settings' }),
    el('p', { class: 'sub', text: 'What this server scans and how it reaches the kiosks. Everything but the kiosk list is set by environment variables when the container starts (see the README).' }),
    el('div', { id: 'settings', class: 'ov' },
      el('div', null, el('h3', { text: 'KIOSK LIST' }), listCard),
      el('div', null, el('h3', { text: 'REACHING THE KIOSKS' }), kioskCard, el('h3', { text: 'THIS SERVER' }), other)));
}

function testKioskDialog() {
  openModal({
    title: 'Test a kiosk', sub: 'Can this server reach it, and open its admin share?',
    fields: [{ key: 'host', label: 'Kiosk name', max: 63 }],
    okText: 'Test it', withLog: true,
    onOk: async (v, m) => {
      const name = (v.host || '').trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/.test(name)) { m.setNote('That is not a kiosk name.', 'CRITICAL'); return true; }
      m.busy(true);
      try {
        const r = await api('POST', `/api/kiosks/${encodeURIComponent(name)}/test`, {});
        const j = await waitJob(r.job, (l) => m.log(l));
        if (j.result && j.result.lines) for (const l of j.result.lines) m.log(`${l.Label}: ${l.Value}`);
        m.busy(false);
        m.setNote(j.detail, j.ok ? 'OK' : 'CRITICAL');
      } catch (e) { m.busy(false); m.setNote(e.message, 'CRITICAL'); }
      return true;
    }
  });
}

start();
