// Control Tower client. Vanilla JS, no build step. Mirrors the dashboard's robustness patterns:
// arr() coercion (PS 5.1 ConvertTo-Json mangles 0/1-row arrays), cache:'no-store', X-Ops-User identity.
'use strict';
const $ = s => document.querySelector(s);
const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
const esc = s => ('' + (s ?? '')).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);   // coerce PS single/empty -> array
const isYmd = s => !s || /^\d{4}-\d{2}-\d{2}$/.test(('' + s).trim());   // house date standard: yyyy-mm-dd only
// i18n shims: tr() comes from i18n.js (English source string = key). plural() keeps English -s but drops it
// in other languages where a trailing "s" reads wrong. Safe no-op fallback if i18n.js failed to load.
if (typeof window.tr !== 'function') window.tr = (s) => s;
const curLang = () => (window.I18N && I18N.current()) || 'en';
const plural = (n, word) => tr(word) + (n !== 1 && curLang() === 'en' ? 's' : '');

const state = { user: localStorage.getItem('opsUser') || '', roster: [], lens: 'mine', teammate: '', bound: localStorage.getItem('opsBound') || 'Import', tmode: localStorage.getItem('opsMode') || 'Sea',
  from: '', to: '', company: '', searchField: 'company', ref: '', alertsOnly: false, notesOnly: false, pols: [], pods: [], station: localStorage.getItem('opsStation') || '', _companies: [], _portDim: [], _activePorts: { pol: [], pod: [] }, _stations: [],
  ib: { origin: '', party: '', q: '', pols: [], pods: [], from: '', to: '' } };   // inbound (pre-arrival) panel search
let allCollapsed = false;   // collapse-all toggle for vessel groups

let ME = null;   // /api-ops/me payload; ME.authOn = real login mode (identity from the session, not the picker)
async function api(path, opts) {
  opts = opts || {};
  opts.cache = 'no-store';
  opts.headers = Object.assign({ 'X-Ops-User': state.user || '(open)' }, opts.headers || {});
  if (opts.body && typeof opts.body !== 'string') { opts.body = JSON.stringify(opts.body); opts.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opts);
  if (r.status === 401) { location.href = 'login.html'; return new Promise(() => {}); }   // halt in-flight init
  return r.json();
}
// access gating: ME.access = allowed mode-bound pairs; empty/open mode = everything allowed
function hasPair(m, b) { return !ME || !ME.authOn || !arr(ME.access).length || arr(ME.access).includes(m + '-' + b); }

// ---------- SWIVEL L!NK iframe boot ----------
// L!NK opens this app embedded as: index.html?mode={light|dark}&site={CODE}#code={CODE}&state={STATE}
// Read mode/site (non-secret context) + the one-time code/state from the URL FRAGMENT, apply the theme, store the
// site context, then redeem the code for OUR OWN session before init() runs. code/state are sensitive + single-use
// (~60s) so we strip them from the visible URL immediately. No code = an ordinary load (login.html fallback still
// applies). Inert end-to-end unless L!NK actually hands us a code; the server endpoint is itself env-gated.
async function linkBoot() {
  let q, h;
  try { q = new URLSearchParams(location.search); h = new URLSearchParams((location.hash || '').replace(/^#/, '')); } catch (e) { return; }
  const mode = q.get('mode'), site = q.get('site');
  if (mode === 'dark' || mode === 'light') { document.documentElement.setAttribute('data-theme', mode); try { localStorage.setItem('theme', mode); } catch (e) {} }
  window.MG_LINK_CONTEXT = { mode: mode || 'light', site: site || '' };   // L!NK site/company context (NOT auth)
  const code = h.get('code'), st = h.get('state');
  if (!code || !st) return;
  try { history.replaceState(null, document.title, location.pathname + location.search); } catch (e) {}   // scrub the sensitive fragment
  try {
    await fetch('/api-ops/link-oauth-login', { method: 'POST', cache: 'no-store', credentials: 'include',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, state: st }) });
  } catch (e) {}   // success -> session cookie set, /api-ops/me passes; failure -> /me 401 -> login.html
}

// ---------- init ----------
async function init() {
  ME = await api('/api-ops/me');   // FIRST: 401 here bounces to login.html before anything renders
  // language: profile default unless this device has its own choice; loads the dict + translates the static DOM
  if (window.I18N) await I18N.boot(ME && ME.language);
  try { const c = await api('/api-ops/config'); $('#appName').textContent = c.appName || 'Control Tower'; $('#appSub').textContent = c.appSubtitle || ''; document.title = c.appName || 'Control Tower'; state._stations = arr(c.stations); } catch (e) {}
  if (ME.authOn) {
    state.user = ME.username;                          // session identity replaces the demo picker
    $('#userPicker').style.display = 'none'; const ol = $('#opLabel'); if (ol) ol.style.display = 'none';
    const ub = $('#userbar');
    if (ub) {
      ub.innerHTML = '<b>' + esc(ME.displayName || ME.username) + '</b> · ' + esc(tr(ME.role || '')) +
        (ME.admin ? ' · <a href="admin-ops.html" style="color:var(--accent)">' + tr('Admin') + '</a>' : '') +
        ' · <a href="#" id="signOut" style="color:var(--accent)">' + tr('Sign out') + '</a>';
      ub.querySelector('#signOut').onclick = async e => { e.preventDefault(); await fetch('/api-ops/logout', { method: 'POST' }); location.href = 'login.html'; };
    }
    // sanitize the persisted mode/bound against my access BEFORE the first load
    if (!hasPair(state.tmode, state.bound)) {
      const all = [['Air', 'Export'], ['Air', 'Import'], ['Sea', 'Export'], ['Sea', 'Import']];
      const keep = all.find(p => p[0] === state.tmode && hasPair(p[0], p[1])) || all.find(p => hasPair(p[0], p[1]));
      if (keep) { state.tmode = keep[0]; state.bound = keep[1]; localStorage.setItem('opsMode', state.tmode); localStorage.setItem('opsBound', state.bound); }
    }
    // station selection limited to my stations, defaulting to my primary
    const mySts = arr(ME.stations);
    if (mySts.length && (!state.station || !mySts.includes(state.station))) state.station = ME.primaryStation || mySts[0] || '';
  }
  buildStationPicker();
  const rost = await api('/api-ops/roster'); const ru = arr(rost.users);
  state.roster = ru.map(u => u.username);
  // username -> { name, team, station, email } so the @-mention picker shows the display name (matters at ~500 users)
  state.rosterMeta = {}; ru.forEach(u => { state.rosterMeta[u.username] = { name: u.displayName || u.username, team: u.team || '', station: u.station || '', email: u.email || '' }; });
  if (!state.user && state.roster.length) state.user = state.roster[0];
  buildUserPicker(); buildTeammate();
  wireLens(); wireBound(); wireMode(); wireFilters(); wireTheme(); buildLangPicker();
  applyAccessGating();
  await loadFilters();
  $('#refreshBtn').onclick = refreshAll;
  $('#collapseAll').onclick = () => {
    allCollapsed = !allCollapsed;
    document.querySelectorAll('.vgroup').forEach(g => g.classList.toggle('collapsed', allCollapsed));
    $('#collapseAll').textContent = allCollapsed ? tr('⊕ Expand all') : tr('⊖ Collapse all');
  };
  // block:'nearest' scrolls only when the panel isn't already on screen — on a wide layout the
  // sidebar panel is already visible, so this no longer jerks the whole page up ("rolls up").
  $('#tasksBtn').onclick = () => $('#tasksPanel').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  $('#closeDrawer').onclick = closeDrawer; $('#drawerBg').onclick = closeDrawer;
  wireFind();
  wireBookings();
  refreshAll();
}

// ---------- natural-language Find (dedicated, mode-agnostic page) ----------
function wireFind() {
  const fb = $('#findBtn'); if (fb) fb.onclick = openFind;
  const fc = $('#findClose'); if (fc) fc.onclick = closeFind;
  const ft = $('#findText');
  if (ft) ft.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); runOpsFind(); } else if (e.key === 'Escape') closeFind(); });
  const fs = $('#findSend'); if (fs) fs.onclick = function () { runOpsFind(); };
  const fv = $('#findView'); if (fv) fv.addEventListener('click', e => { if (e.target === fv) closeFind(); });
}
function openFind() { const v = $('#findView'); if (!v) return; v.style.display = 'flex'; const i = $('#findText'); if (i) i.focus(); }
function closeFind() { const v = $('#findView'); if (v) v.style.display = 'none'; }

// ---------- New bookings (newly-received bookings for the operator's station(s), scoped server-side) ----------
function wireBookings() {
  const b = $('#bkgBtn'); if (b) b.onclick = openBookings;
  const c = $('#bkgClose'); if (c) c.onclick = closeBookings;
  const v = $('#bkgView'); if (v) v.addEventListener('click', e => { if (e.target === v) closeBookings(); });
  const s = $('#bkgSearch'); if (s) s.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); loadBookings(); } else if (e.key === 'Escape') closeBookings(); });
  const m = $('#bkgMode'); if (m) m.onchange = loadBookings;   // Air / Sea filter
  const bn = $('#bookNowBtn'); if (bn) bn.onclick = openBookNow;
}
function openBookings() { const v = $('#bkgView'); if (!v) return; v.style.display = 'flex'; loadBookings(); }
function closeBookings() { const v = $('#bkgView'); if (v) v.style.display = 'none'; }
async function loadBookings() {
  const feed = $('#bkgFeed'); if (!feed) return;
  feed.innerHTML = '<div class="find-msg muted">' + esc(tr('Loading…')) + '</div>';
  const q = ($('#bkgSearch') && $('#bkgSearch').value.trim()) || '';
  const mode = ($('#bkgMode') && $('#bkgMode').value) || '';
  const qs = [];
  if (q) qs.push('q=' + encodeURIComponent(q));
  if (mode) qs.push('mode=' + encodeURIComponent(mode));
  let d;
  try { d = await api('/api-ops/new-bookings' + (qs.length ? ('?' + qs.join('&')) : '')); }
  catch (e) { feed.innerHTML = '<div class="find-msg">' + esc(tr('Could not load bookings.')) + '</div>'; return; }
  const rows = arr(d.rows);
  // subtitle (top line) = station scope + count only — e.g. "station HKG : 91 booking(s)"; the date window drops to
  // its own second row (#bkgDates) so the header stays on one line and the + Book button isn't pushed down.
  const stns = [...new Set(rows.map(r => r.station).filter(Boolean))];
  const stnLbl = stns.length === 1 ? (tr('station') + ' ' + stns[0]) : (stns.length > 1 ? stns.join('/') : '');
  $('#bkgSub').textContent = (stnLbl ? stnLbl + ' : ' : '') + (d.count != null ? d.count : rows.length) + ' ' + tr('booking(s)');
  const dd = $('#bkgDates'); if (dd) dd.textContent = (d.from || d.to) ? ((d.from || '') + ' → ' + (d.to || '')) : '';
  if (!rows.length) { feed.innerHTML = '<div class="find-msg muted">' + esc(tr('No new bookings for your station(s) in this window.')) + '</div>'; return; }
  feed.innerHTML = '';
  rows.forEach(b => {
    // a row only opens once it's been pulled into the worklist (shipJobNo set). The status chip ([confirmed] etc.)
    // is about the ERP booking number, NOT about whether details are viewable - so show a clear, distinct hint.
    const clickable = !!b.shipJobNo;
    const card = el('div', 'mcard G bkgrow ' + (clickable ? 'clickable' : 'pending'));
    const lane = (b.pol || '') + (b.pod ? ' → ' + b.pod : '');
    const stChip = b.channel === 'book-now'
      ? (b.status === 'erp-failed' ? '<span class="chip nospace">' + esc(tr('ERP failed')) + '</span>'
        : b.status === 'erp-pending' ? '<span class="chip">' + esc(tr('registering…')) + '</span>'
        : '<span class="chip arrived">' + esc(tr('confirmed')) + '</span>')
      : b.status === 'notified' ? '<span class="chip arrived">' + esc(tr('notified')) + '</span>'
      : (b.status === 'failed' ? '<span class="chip nospace">' + esc(tr('alert failed')) + '</span>' : '');
    const inco = b.incoterm ? '<span class="minco" title="' + esc(tr('Incoterm — your delivery responsibility')) + '">' + esc(b.incoterm) + '</span>' : '';
    // headline owner = controlling customer (ctrl), falling back to the shipper/customer when none is recorded
    const who = (b.ctrlCode ? compName(b.ctrlCode) : '') || b.shipperName || b.custCode || '';
    const cargo = cargoProfile(b);   // reuses the worklist profile (Air pcs+kg / FCL containers / LCL kg+cbm)
    const commod = b.commodity ? '<span title="' + esc(b.commodity) + '">' + esc(b.commodity.length > 28 ? b.commodity.slice(0, 28) + '…' : b.commodity) + '</span>' : '';
    // parties subline (worklist style): shipper / consignee / agent company names
    const pn = (code, fb) => code ? esc(compName(code)) : (fb ? esc(fb) : '');
    const mkPty = (lbl, txt) => txt ? '<span class="pty">' + tr(lbl) + ' ' + txt + '</span>' : '';
    const pty = [mkPty('shpr', pn(b.shipperCode, b.shipperName)), mkPty('cgne', pn(b.consigneeCode, b.consigneeName)), mkPty('agnt', pn(b.agentCode))].filter(Boolean).join('  ·  ');
    const contact = [b.factoryContact, b.factoryEmail].filter(Boolean).join(' · ');
    const sub = [cargo, commod].filter(Boolean).join('  ·  ');
    // identifiers that appear as the booking progresses (blank at pure booking stage): bills, container/SO, PO/ship-id
    const isAir = b.mode === 'Air';
    const ctr = b.containerNo ? tr('ctr') + ' ' + esc(b.containerNo) + (b.containerCount > 1 ? ' +' + (b.containerCount - 1) : '')
      : (b.linerSo ? tr('SO') + ' ' + esc(b.linerSo) : '');
    const hb = b.houseBill ? (isAir ? 'HAWB' : tr('House BL')) + ' ' + esc(b.houseBill) : '';
    const mb = b.masterBill ? (isAir ? 'MAWB' : tr('Master BL')) + ' ' + esc(b.masterBill) : '';
    const po = b.custRef ? (isAir ? 'PO ' : tr('ship-id') + ' ') + esc(b.custRef) : '';
    // for a Book Now booking show our system Ref No alongside the ERP booking number (they differ)
    const sysref = (b.channel === 'book-now' && b.erpRef && b.erpRef !== b.bookingNo) ? (tr('ref') + ' ' + esc(b.erpRef)) : '';
    const ids = [hb, mb, ctr, po, sysref].filter(Boolean).join('  ·  ');
    const meta = [esc(b.station + ' ' + b.mode), esc(lane), contact ? esc(tr('shpr') + ' ' + contact) : '',
      b.srcCreated ? esc(tr('received') + ' ' + b.srcCreated) : ''].filter(Boolean).join('  ·  ');
    // right side of r1: once the booking is openable, the "view" affordance REPLACES the status chip (a viewable row
    // no longer needs the [confirmed] badge); a not-yet-openable row keeps its status chip (e.g. registering…/confirmed).
    const right = clickable
      ? '<span class="bkgopen" title="' + esc(tr('Open to see full details')) + '">' + esc(tr('view ›')) + '</span>'
      : stChip;
    card.innerHTML =
      '<div class="r1"><span class="chip bkgstage">' + esc(tr('BOOKING')) + '</span>' +
        '<span class="mref">' + esc(b.bookingNo || b.jobNo || '—') + '</span>' + inco +
        '<span class="mwho">' + esc(who) + '</span>' +
        '<span class="mspacer"></span>' + right + '</div>' +
      (sub ? '<div class="r2">' + sub + '</div>' : '') +
      (ids ? '<div class="r2">' + ids + '</div>' : '') +
      (pty ? '<div class="r2 pty-row">' + pty + '</div>' : '') +
      '<div class="r2 muted">' + meta + '</div>';
    // deep-link via the synthetic shipment_alerts key (ship_job); the raw ERP job_no does NOT match the shipment API.
    // No match yet (booking not in the worklist set) -> not clickable, with a hint instead of a dead/wrong click.
    if (clickable) card.onclick = () => { closeBookings(); openShipment(b.shipJobNo, b.bookingNo || b.jobNo); };
    else card.title = tr('Details appear after the next worklist refresh');
    feed.appendChild(card);
  });
}
// ---------- Book Now (quick-create a NEW booking in the ERP; auto bookingNo) ----------
// Container-mix parser lifted from erp-quotation Quote builder (app.js normContainer/containerCounts) so the
// captions + behaviour match. "1x20GP, 2x40HQ" -> {20GP,40GP,40HQ,45GP}; 45GP maps to the ERP containerOthers.
function normContainer(t) {
  t = ('' + t).toUpperCase().replace(/['\s"]/g, '');
  if (t === '20' || t === '20GP' || t === '20DC' || t === '20DV' || t === '20FT') return '20GP';
  if (t === '40' || t === '40GP' || t === '40DC' || t === '40DV' || t === '40FT') return '40GP';
  if (t === '40H' || t === '40HQ' || t === '40HC') return '40HQ';
  if (t === '45' || t === '45GP' || t === '45HQ' || t === '45HC') return '45GP';
  return '';
}
function containerCounts(mix) {
  const m = { '20GP': 0, '40GP': 0, '40HQ': 0, '45GP': 0 };
  ('' + (mix || '')).split(/[,;]+/).forEach(tok => {
    tok = tok.trim(); if (!tok) return;
    const mm = tok.match(/(\d+(?:\.\d+)?)\s*[xX*]\s*([0-9A-Za-z'"]+)/);
    const n = mm ? +mm[1] : 1, t = normContainer(mm ? mm[2] : tok);
    if (t && m[t] != null) m[t] += n;
  });
  return m;
}

let _bnCtx = null;   // { station, mode } shared with the master-lookup dropdown
// plain text/number/date/textarea cell: caption above the input.
function bnText(label, o) {
  o = o || {};
  const cell = el('label', 'bncell' + (o.wide ? ' wide' : ''));
  cell.appendChild(el('span', 'bncap', esc(label)));
  const inp = o.area ? el('textarea') : el('input');
  if (!o.area) inp.type = 'text';
  inp.autocomplete = 'off';
  if (o.ph) inp.placeholder = o.ph;
  if (o.val != null) inp.value = o.val;
  if (o.num) inp.inputMode = 'decimal';
  if (o.max) inp.maxLength = o.max;
  cell.appendChild(inp);
  return { cell, inp, val: () => inp.value.trim() };
}
// the ERP master display format: "NAME (CODE) - city, country" (e.g. "HONG KONG (HKHKG)", "ABC CO LTD (A0023) - USLAX, US").
function bnFmtMaster(r) {
  const code = (r.code || '').trim(), name = (r.name || '').trim(), loc = (r.loc || '').trim();
  return (name || code) + (name && code ? ' (' + code + ')' : '') + (loc ? ' - ' + loc : '');
}
// master-lookup cell, Edit-ERP style: the "..." trigger sits INLINE next to the caption (no separate button). The
// VISIBLE field holds the NAME (people type/recognise names, e.g. "HONG KONG", "ABC FOOTWEAR LTD") - the code is
// resolved behind it: from a "..." pick (stored on dataset.code) or, when the user just types a name, by the ERP on
// submit. So typing a name directly is fine and is NOT validated here. Mode-aware (the dropdown queries _bnCtx.mode).
function bnLook(label, kind, o) {
  o = o || {};
  const cell = el('label', 'bncell' + (o.wide ? ' wide' : ''));
  const cap = el('span', 'bncap'); cap.appendChild(document.createTextNode(label + ' '));
  const dots = el('span', 'bndots', '...'); dots.title = tr('Look up'); cap.appendChild(dots); cell.appendChild(cap);
  const inp = el('input', 'bncodein'); inp.type = 'text'; inp.autocomplete = 'off'; inp.spellcheck = false;
  // codeDisplay (e.g. Incoterm): the field shows/stores the short CODE (EXW); the dropdown still shows the full name
  // for findability but no full wording is displayed in the field/hint.
  if (o.codeDisplay) inp.dataset.codeDisplay = '1';
  inp.value = o.codeDisplay ? (o.code || '') : (o.name || o.code || '');
  if (o.code) inp.dataset.code = o.code;
  const hint = el('span', 'bnhint'); hint.textContent = o.codeDisplay ? '' : ((o.name || o.code) ? bnFmtMaster({ code: o.code, name: o.name }) : '');
  cell.appendChild(inp); cell.appendChild(hint);
  inp.oninput = () => { inp.dataset.code = ''; if (!o.codeDisplay) hint.textContent = ''; };   // typed value -> resolved later
  dots.onclick = (e) => { e.preventDefault(); bnLookup(kind, cell, inp, hint); };
  return { cell, code: () => (inp.dataset.code || '').trim() || (o.codeDisplay ? inp.value.trim() : ''), name: () => inp.value.trim(),
    setVal: (c, n) => { inp.value = o.codeDisplay ? (c || '') : (n || c || ''); inp.dataset.code = c || ''; hint.textContent = o.codeDisplay ? '' : ((n || c) ? bnFmtMaster({ code: c, name: n }) : ''); } };
}
// a tiny labelled input for the compact cargo row (Qty / Unit / Gross weight / CBM on one line).
function bnMini(label, o) {
  o = o || {};
  const w = el('div', 'bnmini'); w.appendChild(el('span', 'bnmcap', esc(label)));
  const i = el('input'); i.type = 'text'; i.autocomplete = 'off'; if (o.num) i.inputMode = 'decimal';
  if (o.val != null) i.value = o.val; if (o.max) i.maxLength = o.max;
  w.appendChild(i); return { w, val: () => i.value.trim() };
}

// type-ahead dropdown (ported from erp-edit.js openLookup; repointed at /api-ops/book-now-master, station-scoped).
function bnLookup(kind, anchorEl, inp, hintEl) {
  const ex = anchorEl.querySelector('.lookbox'); if (ex) { ex.remove(); return; }
  const box = el('div', 'lookbox');
  const q = el('input', 'lq'); q.type = 'text'; q.placeholder = tr('code or name…'); q.spellcheck = false; box.appendChild(q);
  const list = el('div'); box.appendChild(list); anchorEl.appendChild(box);
  const ar = inp.getBoundingClientRect();
  const vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight, bw = box.offsetWidth || 240;
  box.style.position = 'fixed'; box.style.left = Math.max(8, Math.min(ar.left, vw - 8 - bw)) + 'px'; box.style.right = 'auto';
  const below = vh - ar.bottom - 10, above = ar.top - 10;
  if (below >= 160 || below >= above) { box.style.top = (ar.bottom + 3) + 'px'; box.style.bottom = 'auto'; box.style.maxHeight = Math.max(120, below) + 'px'; }
  else { box.style.bottom = (vh - ar.top + 3) + 'px'; box.style.top = 'auto'; box.style.maxHeight = Math.max(120, above) + 'px'; }
  try { q.focus({ preventScroll: true }); } catch (e) { q.focus(); }
  let t = null;
  const run = async () => {
    list.innerHTML = '<div class="li">' + esc(tr('searching…')) + '</div>';
    let d; try {
      d = await api('/api-ops/book-now-master?station=' + encodeURIComponent(_bnCtx.station) + '&mode=' + encodeURIComponent(_bnCtx.mode) +
        '&kind=' + encodeURIComponent(kind) + '&q=' + encodeURIComponent(q.value.trim()));
    } catch (e) { d = { error: tr('lookup failed') }; }
    list.innerHTML = '';
    if (d.error) { list.innerHTML = '<div class="li">' + esc(d.error) + '</div>'; return; }
    const res = arr(d.results);
    if (!res.length) { list.innerHTML = '<div class="li">' + esc(tr('no matches')) + '</div>'; return; }
    res.forEach(r => {
      const li = el('div', 'li', esc(bnFmtMaster(r)));
      li.onclick = () => { inp.value = inp.dataset.codeDisplay ? (r.code || '') : (r.name || r.code); inp.dataset.code = r.code || ''; if (hintEl) hintEl.textContent = inp.dataset.codeDisplay ? '' : bnFmtMaster(r); box.remove(); };
      list.appendChild(li);
    });
  };
  q.oninput = () => { clearTimeout(t); t = setTimeout(run, 220); };
  run();
  setTimeout(() => { document.addEventListener('click', function h(e) { if (!anchorEl.contains(e.target)) { box.remove(); document.removeEventListener('click', h); } }); }, 0);
}

function bnToast(text) {
  const t = el('div', 'bn-toast', esc(text)); document.body.appendChild(t);
  setTimeout(() => { t.classList.add('show'); }, 10);
  setTimeout(() => { t.classList.remove('show'); setTimeout(() => t.remove(), 300); }, 6000);
}

async function openBookNow() {
  const mode0 = (state.tmode === 'Air') ? 'Air' : 'Sea';
  let seed; try { seed = await api('/api-ops/book-now-seed?mode=' + encodeURIComponent(mode0)); }
  catch (e) { seed = { error: tr('Could not start a new booking.') }; }
  if (!seed || seed.error) { alert((seed && seed.error) || tr('Could not start a new booking.')); return; }
  _bnCtx = { station: seed.station, mode: mode0 };

  const bg = el('div', 'modal-bg'); const box = el('div', 'modal booknow');
  box.appendChild(el('h3', '', esc(tr('Book Now')) + ' — ' + esc(tr('new ERP booking'))));

  // --- compact top strip: Mode · Export/Import · Station · Ref No (small controls on one line) ---
  const top = el('div', 'bntop');
  const modeSel = el('select'); ['Sea', 'Air'].forEach(m => { const o = el('option'); o.value = m; o.textContent = tr(m); if (m === mode0) o.selected = true; modeSel.appendChild(o); });
  const boundSel = el('select'); ['Export', 'Import'].forEach(v => { const o = el('option'); o.value = v; o.textContent = tr(v); boundSel.appendChild(o); });
  const stns = arr(seed.stations);
  let stationCtl;
  if (stns.length > 1) { stationCtl = el('select'); stns.forEach(s => { const o = el('option'); o.value = s; o.textContent = s; if (s === seed.station) o.selected = true; stationCtl.appendChild(o); }); }
  else { stationCtl = el('input'); stationCtl.type = 'text'; stationCtl.value = seed.station; stationCtl.readOnly = true; }
  const refInp = el('input'); refInp.type = 'text'; refInp.autocomplete = 'off';
  const stationVal = () => (stationCtl.value || seed.station || '').trim();
  const tcell = (lab, ctl) => { const c = el('div', 'bntf'); c.appendChild(el('span', 'bncap', esc(lab))); c.appendChild(ctl); return c; };
  // left grid column: Mode · Bound · Station (Station grows to the column edge, aligning with Cargo ready date below);
  // right grid column: Ref No (aligns with ETD below). The strip uses the same 2-col grid as the form for alignment.
  const topL = el('div', 'bntop-l');
  topL.appendChild(tcell(tr('Mode'), modeSel));
  topL.appendChild(tcell(tr('Export/Import'), boundSel));
  const stCell = tcell(tr('Station'), stationCtl); stCell.classList.add('bntf-grow');
  topL.appendChild(stCell);
  top.appendChild(topL);
  top.appendChild(tcell(tr('Ref No'), refInp));
  box.appendChild(top);

  // --- main grid (two columns; paired fields keep it short) ---
  const f = el('div', 'bnf'); box.appendChild(f);
  const cargoReady = bnText(tr('Cargo ready date'), { ph: 'yyyy-mm-dd' });
  const etd = bnText(tr('ETD (departure)'), { ph: 'yyyy-mm-dd', val: seed.today || '' });   // ETD defaults to today
  f.appendChild(cargoReady.cell); f.appendChild(etd.cell);

  const pol = bnLook(tr('Port of loading'), 'port', { code: seed.defaultPol && seed.defaultPol.code, name: seed.defaultPol && seed.defaultPol.name });
  const pod = bnLook(tr('Port of discharge'), 'port', {});
  f.appendChild(pol.cell); f.appendChild(pod.cell);

  // Service type is not shown - it's auto-set per mode on the server (AIR for air, the Sea default for sea).
  // Incoterm (narrow, code-only EXW) + Commodity (wide) share one row.
  const incoterm = bnLook(tr('Incoterm'), 'incoterm', { codeDisplay: true });   // -> incoTermsCode
  const commodity = bnText(tr('Commodity'), { max: 21 });
  const icRow = el('div', 'wide bnic-row');
  incoterm.cell.classList.add('bnic'); commodity.cell.classList.add('bncom');
  icRow.appendChild(incoterm.cell); icRow.appendChild(commodity.cell);
  f.appendChild(icRow);

  // cargo row: Qty · Unit · Gross weight · CBM on one line
  const mQty = bnMini(tr('Qty'), { num: true }), mUnit = bnMini(tr('Unit'), { val: seed.quantityUnit || 'CTN', max: 10 });
  const mGwt = bnMini(tr('Gross weight'), { num: true }), mCbm = bnMini(tr('CBM'), { num: true });
  const cargoCell = el('div', 'bncell wide'); cargoCell.appendChild(el('span', 'bncap', esc(tr('Cargo'))));
  const cargoG = el('div', 'bncargo'); [mQty, mUnit, mGwt, mCbm].forEach(m => cargoG.appendChild(m.w)); cargoCell.appendChild(cargoG);
  f.appendChild(cargoCell);

  // container mix - Sea freight only (hidden for Air); live deduced preview underneath
  const mix = bnText(tr('Container mix') + ' (' + tr('sea freight only') + ')', { wide: true, ph: '1x20GP, 2x40HQ' });
  const mixPrev = el('div', 'bnmix-prev muted'); mix.cell.appendChild(mixPrev);
  const updatePrev = () => { const c = containerCounts(mix.val()); mixPrev.textContent = "20':" + c['20GP'] + "  40':" + c['40GP'] + "  HQ:" + c['40HQ'] + "  " + tr('Other') + ':' + c['45GP']; };
  mix.inp.oninput = updatePrev; updatePrev(); f.appendChild(mix.cell);
  if (mode0 === 'Air') mix.cell.style.display = 'none';   // initial state (applyMode keeps it in sync on toggle)

  // optional parties (code + name, both sent)
  const shipper = bnLook(tr('Shipper') + ' (' + tr('optional') + ')', 'custsub', {});
  const consignee = bnLook(tr('Consignee') + ' (' + tr('optional') + ')', 'custsub', {});
  f.appendChild(shipper.cell); f.appendChild(consignee.cell);

  const remark = bnText(tr('Remark'), { wide: true, area: true, max: 2000 });
  f.appendChild(remark.cell);

  const msg = el('div', 'bn-msg'); box.appendChild(msg);
  const bar = el('div', 'modal-bar'); const cancel = el('button', 'ghost', tr('Cancel')); const ok = el('button', 'primary', tr('Create booking'));
  bar.appendChild(cancel); bar.appendChild(ok); box.appendChild(bar);
  bg.appendChild(box); document.body.appendChild(bg);
  const done = () => bg.remove();
  cancel.onclick = done; bg.onclick = e => { if (e.target === bg) done(); };

  // mode/station change: keep the lookup context current AND re-default POL + service for the new mode so the
  // port dropdown (and the prefilled codes) follow Air/Sea, mirroring Edit ERP.
  let lastMode = mode0;
  const applyMode = async () => {
    _bnCtx.mode = modeSel.value; _bnCtx.station = stationVal();
    const air = modeSel.value === 'Air';
    mix.cell.style.display = air ? 'none' : '';
    refInp.placeholder = stationVal() + (air ? 'A' : 'S') + 'yymmdd0001';
    if (modeSel.value !== lastMode || stationCtl.tagName === 'SELECT') {
      lastMode = modeSel.value;
      try {
        const sd = await api('/api-ops/book-now-seed?mode=' + encodeURIComponent(modeSel.value) + '&station=' + encodeURIComponent(stationVal()));
        if (sd && !sd.error && sd.defaultPol) pol.setVal(sd.defaultPol.code, sd.defaultPol.name);   // POL follows the mode
      } catch (e) { }
    }
  };
  modeSel.onchange = applyMode; if (stns.length > 1) stationCtl.onchange = applyMode;
  refInp.placeholder = stationVal() + (mode0 === 'Air' ? 'A' : 'S') + 'yymmdd0001';

  ok.onclick = async () => {
    if (!isYmd(cargoReady.val()) || !isYmd(etd.val())) { msg.className = 'bn-msg'; msg.textContent = tr('Dates must be yyyy-mm-dd.'); return; }
    const okLabel = ok.textContent;
    ok.disabled = true; ok.textContent = tr('Creating…'); msg.className = 'bn-msg'; msg.textContent = '';
    const air = modeSel.value === 'Air', c = containerCounts(mix.val());
    const body = {
      station: stationVal(), mode: modeSel.value, bound: boundSel.value, refNo: refInp.value.trim(),
      cargoReady: cargoReady.val(), etd: etd.val(),
      polCode: pol.code(), polName: pol.name(), podCode: pod.code(), podName: pod.name(),
      serviceCode: '', incoterm: incoterm.code() || incoterm.name(), commodity: commodity.val(),
      quantity: mQty.val(), quantityUnit: mUnit.val() || 'CTN', grossWeight: mGwt.val(), cbm: mCbm.val(),
      shipperCode: shipper.code(), shipperName: shipper.name(), consigneeCode: consignee.code(), consigneeName: consignee.name(),
      remark: remark.val(),
    };
    if (!air) { body.container20 = c['20GP']; body.container40 = c['40GP']; body.containerHQ = c['40HQ']; body.containerOthers = c['45GP']; }
    let d; try { d = await api('/api-ops/book-now', { method: 'POST', body }); } catch (e) { d = { error: tr('Request failed.') }; }
    if (!d || d.error || d.ok === false) { msg.className = 'bn-msg'; msg.textContent = (d && d.error) || tr('Could not create the booking.'); ok.disabled = false; ok.textContent = okLabel; return; }
    done();
    // async: the booking is registered instantly with our Ref No; the ERP push runs in the background and the
    // creator gets a My Tasks note when it confirms. No waiting on the ~10s ERP call.
    bnToast(tr('Booking registered') + ': ' + (d.refNo || '') + (d.mock ? ' [' + tr('mock') + ']' : '') + ' — ' + tr('creating in the ERP; you will get a My Tasks note when confirmed.'));
    loadBookings(); if (typeof loadTasks === 'function') loadTasks();
  };
}

function buildUserPicker() {
  const sel = $('#userPicker'); sel.innerHTML = '';
  state.roster.forEach(u => { const o = el('option'); o.value = u; o.textContent = u; if (u === state.user) o.selected = true; sel.appendChild(o); });
  sel.onchange = () => { state.user = sel.value; localStorage.setItem('opsUser', state.user); refreshAll(); };
}
function buildTeammate() {
  const sel = $('#teammate'); sel.innerHTML = '';
  state.roster.forEach(u => { const o = el('option'); o.value = u; o.textContent = u; sel.appendChild(o); });
  state.teammate = sel.value || '';
  sel.onchange = () => { state.teammate = sel.value; if (state.lens === 'user') loadWorklist(); };
}
function buildStationPicker() {
  const sel = $('#stationPicker'); if (!sel) return;
  // auth mode with station scope: only MY stations, defaulting to the primary; '' = all MY stations
  const mySts = (ME && ME.authOn) ? arr(ME.stations) : [];
  const list = mySts.length ? state._stations.filter(s => mySts.includes(s.code)) : state._stations;
  sel.innerHTML = '<option value="">' + esc(mySts.length ? tr('All my stations') : tr('All stations')) + '</option>';
  list.forEach(s => { const o = el('option'); o.value = s.code; o.textContent = s.code + ' · ' + (s.name || s.code); if (s.code === state.station) o.selected = true; sel.appendChild(o); });
  sel.style.display = list.length > 1 ? '' : 'none';   // hide for single-station users/instances
  sel.onchange = () => { state.station = sel.value; localStorage.setItem('opsStation', state.station); loadWorklist(); };
}
// Theme: cycle Auto (follow device) -> Light -> Dark. 'auto' clears the override so prefers-color-scheme wins.
function wireTheme() {
  const btn = $('#themeBtn'); if (!btn) return;
  const order = ['auto', 'light', 'dark'], label = { auto: 'Auto', light: 'Light', dark: 'Dark' };
  const apply = t => {
    if (t === 'auto') { document.documentElement.removeAttribute('data-theme'); localStorage.removeItem('theme'); }
    else { document.documentElement.setAttribute('data-theme', t); localStorage.setItem('theme', t); }
    btn.textContent = tr(label[t]);
  };
  const saved = localStorage.getItem('theme'); apply(saved === 'light' || saved === 'dark' ? saved : 'auto');
  btn.onclick = () => { const cur = localStorage.getItem('theme') || 'auto'; apply(order[(order.indexOf(cur) + 1) % order.length]); };
}
// Language picker: lists the supported languages; picking one persists per device and reloads.
// English is always offered so anyone can switch back to the source language at any time.
function buildLangPicker() {
  const sel = $('#langPicker'); if (!sel || !window.I18N) return;
  sel.innerHTML = '';
  const sup = I18N.supported || { en: 'English' };
  Object.keys(sup).forEach(code => { const o = el('option'); o.value = code; o.textContent = sup[code]; if (code === I18N.current()) o.selected = true; sel.appendChild(o); });
  sel.style.display = Object.keys(sup).length > 1 ? '' : 'none';   // hide if only English is available
  sel.onchange = () => I18N.setLang(sel.value);
}
function wireLens() {
  document.querySelectorAll('#lensSeg button').forEach(b => b.onclick = () => {
    document.querySelectorAll('#lensSeg button').forEach(x => x.classList.remove('on'));
    b.classList.add('on'); state.lens = b.dataset.lens;
    $('#teammate').style.display = state.lens === 'user' ? '' : 'none';
    loadWorklist();
  });
}
function wireBound() {
  document.querySelectorAll('#boundSeg button').forEach(b => {
    if (b.dataset.bound === state.bound) b.classList.add('on'); else b.classList.remove('on');
    b.onclick = () => {
      if (b.classList.contains('disabled')) return;   // outside my access pairs
      document.querySelectorAll('#boundSeg button').forEach(x => x.classList.remove('on'));
      b.classList.add('on'); state.bound = b.dataset.bound; localStorage.setItem('opsBound', state.bound);
      applyAccessGating();
      loadWorklist(); loadInbound();
    };
  });
}
function wireMode() {
  document.querySelectorAll('#modeSeg button').forEach(b => {
    if (b.dataset.tmode === state.tmode) b.classList.add('on'); else b.classList.remove('on');
    b.onclick = () => {
      if (b.classList.contains('disabled')) return;   // no pair at all for that mode
      document.querySelectorAll('#modeSeg button').forEach(x => x.classList.remove('on'));
      b.classList.add('on'); state.tmode = b.dataset.tmode; localStorage.setItem('opsMode', state.tmode);
      // if the current bound isn't allowed for this mode, auto-select the one that is
      // (e.g. Air-both + Sea-Export only: choosing Sea forces Export)
      if (!hasPair(state.tmode, state.bound)) {
        const nb = hasPair(state.tmode, 'Export') ? 'Export' : (hasPair(state.tmode, 'Import') ? 'Import' : state.bound);
        state.bound = nb; localStorage.setItem('opsBound', nb);
        document.querySelectorAll('#boundSeg button').forEach(x => x.classList.toggle('on', x.dataset.bound === nb));
      }
      applyAccessGating();
      // POL/POD code spaces are mode-specific (5-letter sea vs 3-letter air) — clear picks on mode switch
      state.pols = []; state.pods = []; state.ib.pols = []; state.ib.pods = [];
      renderFilterOptions();
      loadWorklist(); loadInbound();
    };
  });
}
// disable the mode/bound buttons my access pairs don't cover (open mode / empty access: everything enabled)
function applyAccessGating() {
  document.querySelectorAll('#modeSeg button').forEach(b => {
    const m = b.dataset.tmode;
    b.classList.toggle('disabled', !(hasPair(m, 'Import') || hasPair(m, 'Export')));
  });
  document.querySelectorAll('#boundSeg button').forEach(b => {
    b.classList.toggle('disabled', !hasPair(state.tmode, b.dataset.bound));
  });
}
// align the mode/bound toggle to a value (used so an identifier search shows its hit in the right view)
function syncModeBound(m, b) {
  if (m) { state.tmode = m; localStorage.setItem('opsMode', m); }
  if (b) { state.bound = b; localStorage.setItem('opsBound', b); }
  document.querySelectorAll('#modeSeg button').forEach(x => x.classList.toggle('on', x.dataset.tmode === state.tmode));
  document.querySelectorAll('#boundSeg button').forEach(x => x.classList.toggle('on', x.dataset.bound === state.bound));
  applyAccessGating();
}
// ---------- filters (date window + company + POL/POD) ----------
function fmtDate(x) { const m = String(x.getMonth() + 1).padStart(2, '0'); const d = String(x.getDate()).padStart(2, '0'); return x.getFullYear() + '-' + m + '-' + d; }
function shiftYmd(ymd, days) { const d = new Date(ymd + 'T00:00:00'); d.setDate(d.getDate() + days); return fmtDate(d); }
function currentWeek() { const d = (ME && ME.today) ? new Date(ME.today + 'T00:00:00') : new Date(); const dow = (d.getDay() + 6) % 7; const mon = new Date(d); mon.setDate(d.getDate() - dow); const sun = new Date(mon); sun.setDate(mon.getDate() + 6); return { from: fmtDate(mon), to: fmtDate(sun) }; }
function wireFilters() {
  const wk = currentWeek(); state.from = wk.from; state.to = wk.to;
  const ff = $('#fFrom'), ft = $('#fTo'); ff.value = state.from; ft.value = state.to;
  // The date button cycles three presets: 0 = this week, 1 = last week -> today (recent catch-up),
  // 2 = custom (clears both boxes and waits for you to type a range; does NOT auto-load everything).
  const wkBtn = $('#thisWeek');
  const DATE_MODES = ['This week', 'Last wk → today', 'Custom dates'];
  state.dateMode = 0;
  function applyDateMode(reloadIt) {
    const w = currentWeek();
    const today = (ME && ME.today) ? ME.today : fmtDate(new Date());
    if (state.dateMode === 0) { state.from = w.from; state.to = w.to; }
    else if (state.dateMode === 1) { state.from = shiftYmd(w.from, -7); state.to = today; }
    else { state.from = ''; state.to = ''; }   // custom: clear, wait for the operator to type
    ff.value = state.from; ft.value = state.to; ff.classList.remove('bad'); ft.classList.remove('bad');
    if (wkBtn) wkBtn.textContent = tr(DATE_MODES[state.dateMode]);
    if (reloadIt && state.dateMode !== 2) loadWorklist();   // custom mode leaves the current list until you type
  }
  // manual edit: blank = open-ended on that side (so clearing both = all dates); switches to custom mode.
  const applyDate = (inp, key) => {
    const v = inp.value.trim();
    if (v === '' || isYmd(v)) {
      inp.classList.remove('bad'); state[key] = v;
      state.dateMode = 2; if (wkBtn) wkBtn.textContent = tr(DATE_MODES[2]);
      loadWorklist();
    } else { inp.classList.add('bad'); }
  };
  ff.onchange = () => applyDate(ff, 'from');
  ft.onchange = () => applyDate(ft, 'to');
  if (wkBtn) wkBtn.onclick = () => { state.dateMode = (state.dateMode + 1) % 3; applyDateMode(true); };
  // show/hide ALL filter + view controls (Sea/Air, Import/Export, lens, station, dates, search, POL/POD) to
  // reclaim space, esp. on mobile. The toggle, Collapse-all and the count stay visible; the count keeps the
  // current Sea/Air · Import/Export context so you still know which view you're in while collapsed. Choice persists.
  const tf = $('#toggleFilters'), fbar = $('#filters'), vctl = $('#viewControls');
  const applyFiltersHidden = h => { if (fbar) fbar.classList.toggle('hidden', h); if (vctl) vctl.classList.toggle('hidden', h); if (tf) tf.textContent = h ? tr('Show filters') : tr('Hide filters'); };
  let filtersHidden = localStorage.getItem('opsFiltersHidden') === '1';
  applyFiltersHidden(filtersHidden);
  if (tf) tf.onclick = () => { filtersHidden = !filtersHidden; localStorage.setItem('opsFiltersHidden', filtersHidden ? '1' : '0'); applyFiltersHidden(filtersHidden); };
  // quick filters: "Alerts" narrows the current view to red/amber; "My notes" surfaces shipments I've noted (any date)
  const fa = $('#fAlerts'), fn = $('#fNotes');
  if (fa) fa.onclick = () => { state.alertsOnly = !state.alertsOnly; fa.classList.toggle('on', state.alertsOnly); loadWorklist(); };
  if (fn) fn.onclick = () => { state.notesOnly = !state.notesOnly; fn.classList.toggle('on', state.notesOnly); setDateBoxesEnabled(!state.notesOnly); loadWorklist(); };
  wireCompanyCombo();
  state._polChips = makePortChips('#fPolChips', { kind: 'pol', get: () => state.pols, set: v => { state.pols = v; }, onChange: loadWorklist });
  state._podChips = makePortChips('#fPodChips', { kind: 'pod', get: () => state.pods, set: v => { state.pods = v; }, onChange: loadWorklist });
}
// Multi-select port picker: type-ahead over the FULL port master (code OR name, e.g. "tokyo" → TYO/HND/JPTYO),
// optional country narrowing with a "jp:" prefix, removable chips, OR-filter. Scoped to the current transport
// mode's code space (SEA 5-letter / AIR 3-letter). Ports already on active shipments rank first.
function makePortChips(rootSel, opts) {
  const root = $(rootSel); if (!root) return { refresh: () => {} };
  const inp = root.querySelector('input'), pop = root.querySelector('.mention-pop'), chiprow = root.querySelector('.chiprow');
  let items = [], active = -1;
  const close = () => { pop.style.display = 'none'; active = -1; };
  const moduleNow = () => state.tmode === 'Air' ? 'AIR' : 'SEA';
  const activeCodes = () => new Set(((state._activePorts || {})[opts.kind] || []).filter(x => !x.mode || x.mode === state.tmode).map(x => x.code));
  const render = q => {
    let ql = ('' + q).trim().toLowerCase(), cc = '';
    const m = ql.match(/^([a-z]{2}):\s*(.*)$/); if (m) { cc = m[1].toUpperCase(); ql = m[2]; }   // "jp:tok" → country JP
    const cur = new Set(opts.get()); const act = activeCodes();
    let cand = (state._portDim || []).filter(p => p.module === moduleNow() && !cur.has(p.code));
    if (cc) cand = cand.filter(p => (p.country || '') === cc);
    if (ql) cand = cand.filter(p => p.code.toLowerCase().includes(ql) || (p.name || '').toLowerCase().includes(ql));
    cand.sort((a, b) => {
      const aa = act.has(a.code) ? 0 : 1, ba = act.has(b.code) ? 0 : 1; if (aa !== ba) return aa - ba;
      const ap = ql && a.code.toLowerCase().startsWith(ql) ? 0 : 1, bp = ql && b.code.toLowerCase().startsWith(ql) ? 0 : 1; if (ap !== bp) return ap - bp;
      return a.code < b.code ? -1 : a.code > b.code ? 1 : 0;
    });
    items = cand.slice(0, 12);
    if (!items.length) { pop.innerHTML = '<div class="mut">' + esc(tr('No matching port')) + (cc ? ' (' + esc(cc) + ')' : '') + (ql ? ' “' + esc(ql) + '”' : '') + '</div>'; pop.style.display = 'block'; active = -1; return; }
    pop.innerHTML = '';
    items.forEach((p, i) => {
      const d = el('div', i === 0 ? 'sel' : '', '<b>' + esc(p.code) + '</b> · ' + esc(p.name || '') +
        ' <span class="mut">(' + esc(p.country || '') + ')' + (act.has(p.code) ? ' · active' : '') + '</span>');
      d.onmousedown = e => { e.preventDefault(); pick(p); };
      pop.appendChild(d);
    });
    active = 0; pop.style.display = 'block';
  };
  const pick = p => {
    const cur = opts.get(); if (!cur.includes(p.code)) opts.set(cur.concat(p.code));
    inp.value = ''; close(); drawChips(); opts.onChange();
  };
  const drawChips = () => {
    chiprow.innerHTML = '';
    opts.get().forEach(code => {
      const port = (state._portDim || []).find(p => p.code === code);
      const ch = el('span', 'pchip', esc(code) + '<span class="x" title="' + esc(tr('remove')) + '">✕</span>');
      if (port && port.name) ch.title = port.name + (port.country ? ' (' + port.country + ')' : '');
      ch.querySelector('.x').onclick = () => { opts.set(opts.get().filter(c => c !== code)); drawChips(); opts.onChange(); };
      chiprow.appendChild(ch);
    });
  };
  const hi = () => { [...pop.children].forEach((d, i) => d.className = i === active ? 'sel' : ''); };
  inp.addEventListener('focus', () => { render(inp.value); });
  inp.addEventListener('input', () => render(inp.value));
  inp.addEventListener('keydown', e => {
    if (pop.style.display !== 'block') return;
    if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(active + 1, items.length - 1); hi(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(active - 1, 0); hi(); }
    else if (e.key === 'Enter') { e.preventDefault(); if (items[active]) pick(items[active]); }
    else if (e.key === 'Escape') { close(); inp.blur(); }
    else if (e.key === 'Backspace' && !inp.value) { const cur = opts.get(); if (cur.length) { opts.set(cur.slice(0, -1)); drawChips(); opts.onChange(); } }
  });
  inp.addEventListener('blur', () => setTimeout(close, 120));
  drawChips();
  return { refresh: drawChips };
}
// Company type-ahead: search the active-worklist companies by NAME (or code) — bounded list loaded client-side,
// so it's instant and never queries the 300k master. (You can only filter shipments by a company that has one.)
function companyLabel(code) { const c = (state._companies || []).find(x => x.code === code); return c ? c.name + ' (' + c.code + ')' : (code || ''); }
// code -> display name via the loaded active-company list (covers every role code on an active shipment)
function compName(code) { if (!code) return ''; const c = (state._companies || []).find(x => x.code === code); return (c && c.name) || code; }
function setCompany(code) {
  state.company = code || '';
  const inp = $('#fCompany'); if (inp) inp.value = code ? companyLabel(code) : '';
  const x = $('#fCompanyClear'); if (x) x.style.display = code ? '' : 'none';
}
// Unified search: a field selector + one box. "Company" = the instant client-side type-ahead (date-windowed,
// filters by role code). Any identifier field (job/booking/PO/house/master) = a server lookup that ignores the
// date window AND the ownership lens, so you can pull up any file by its number even if it's outside this week
// or another operator's. The date boxes are disabled in identifier mode to make that explicit.
const SEARCH_PH = { company: 'Company name…', job: 'Job number…', booking: 'Booking / SO number…', po: 'PO / Ref / Ship ID number…', house: 'House B/L number…', master: 'Master B/L number…', conv: 'Vessel / voyage (sea) or flight no (air)…' };
function setDateBoxesEnabled(on) {
  ['#fFrom', '#fTo', '#thisWeek'].forEach(s => { const e = $(s); if (e) { e.disabled = !on; e.style.opacity = on ? '' : '.5'; } });
}
function wireCompanyCombo() {
  const inp = $('#fCompany'), pop = $('#fCompanyPop'), clr = $('#fCompanyClear'), sf = $('#fSearchField');
  if (!inp) return;
  let items = [], active = -1, debTimer = null;
  const close = () => { pop.style.display = 'none'; active = -1; };
  const isCompany = () => state.searchField === 'company';
  const render = q => {   // company type-ahead only
    const ql = ('' + q).trim().toLowerCase();
    items = (state._companies || []).filter(c => !ql || c.name.toLowerCase().includes(ql) || c.code.toLowerCase().includes(ql)).slice(0, 12);
    if (!items.length) { pop.innerHTML = '<div class="mut">' + esc(tr('No active company matches')) + ' “' + esc(q) + '”</div>'; pop.style.display = 'block'; active = -1; return; }
    pop.innerHTML = ''; items.forEach((c, i) => { const d = el('div', i === 0 ? 'sel' : '', esc(c.name) + ' <span class="mut">' + esc(c.code) + '</span>'); d.onmousedown = e => { e.preventDefault(); pick(c); }; pop.appendChild(d); });
    active = 0; pop.style.display = 'block';
  };
  const pick = c => { setCompany(c.code); close(); loadWorklist(); };
  const hi = () => { [...pop.children].forEach((d, i) => d.className = i === active ? 'sel' : ''); };
  const runRef = () => { state.ref = inp.value.trim(); clr.style.display = state.ref ? '' : 'none'; loadWorklist(); };
  inp.addEventListener('focus', () => { if (isCompany()) { inp.select(); render(''); } });
  inp.addEventListener('input', () => {
    if (isCompany()) { render(inp.value); return; }
    clearTimeout(debTimer); debTimer = setTimeout(runRef, 350);   // identifier mode: debounced server lookup
  });
  inp.addEventListener('keydown', e => {
    if (!isCompany()) { if (e.key === 'Enter') { e.preventDefault(); clearTimeout(debTimer); runRef(); } else if (e.key === 'Escape') { inp.blur(); } return; }
    if (pop.style.display !== 'block') return;
    if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(active + 1, items.length - 1); hi(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(active - 1, 0); hi(); }
    else if (e.key === 'Enter') { e.preventDefault(); if (items[active]) pick(items[active]); }
    else if (e.key === 'Escape') { close(); inp.blur(); }
  });
  inp.addEventListener('blur', () => { setTimeout(() => { close(); if (isCompany()) inp.value = state.company ? companyLabel(state.company) : ''; }, 120); });
  if (clr) clr.onclick = () => { if (isCompany()) setCompany(''); else { state.ref = ''; inp.value = ''; clr.style.display = 'none'; } close(); loadWorklist(); };
  if (sf) sf.onchange = () => {
    // switching field clears the other mode's value so the two never combine
    state.searchField = sf.value; state.company = ''; state.ref = ''; inp.value = ''; close();
    inp.placeholder = tr(SEARCH_PH[state.searchField] || 'Search…');
    clr.style.display = 'none'; setDateBoxesEnabled(isCompany());
    loadWorklist();
  };
}
async function loadFilters() {
  try { const c = await api('/api-ops/companies'); state._companies = arr(c.companies); } catch (e) { state._companies = []; }
  // full port master (~5k rows, served from a 15-min server-side cache) + the active pol/pod codes for ranking
  try { const p = await api('/api-ops/ports'); state._portDim = arr(p.ports); state._activePorts = { pol: arr(p.activePol), pod: arr(p.activePod) }; }
  catch (e) { state._portDim = []; state._activePorts = { pol: [], pod: [] }; }
  renderFilterOptions();
}
function renderFilterOptions() {
  setCompany(state.company);   // refresh the combo's displayed name now that the company list is loaded
  if (state._polChips) state._polChips.refresh();
  if (state._podChips) state._podChips.refresh();
  if (state._ibPolChips) state._ibPolChips.refresh();
  if (state._ibPodChips) state._ibPodChips.refresh();
}
function refreshAll() { loadWorklist(); loadTasks(); loadInbound(); }

// ---------- inbound cross-station bookings (pre-arrival) ----------
// Shown on the Import bound only: bookings created at OTHER stations whose destination is OUR station,
// so we coordinate from booking -> delivery. Reads only the erpops feed; assign locally to an operator.
// Grouped by booking STAGE (what the origin has done so far), not urgency — so the operator sees what is coming
// before it is EDI'd to them: a fresh booking (no schedule) vs one where the vessel/flight is already arranged.
const IB_STAGES = [
  { k: 'sched', t: 'Vessel / flight scheduled' },
  { k: 'new', t: 'New booking — awaiting schedule' },
];
function ibStage(r) { return (r.vesselFlight || r.etd) ? 'sched' : 'new'; }
function ibByDate(a, b) { const x = a.etd || a.cargoReady || a.bookingDate || '9999'; const y = b.etd || b.cargoReady || b.bookingDate || '9999'; return x < y ? -1 : x > y ? 1 : 0; }
// The panel shell (header + search bar) is built ONCE and only the list body re-renders — rebuilding the
// whole panel per keystroke would destroy the focused search input. Text inputs are debounced 300ms.
function debounce(fn, ms) { let t; return () => { clearTimeout(t); t = setTimeout(fn, ms || 300); }; }
function buildInboundShell(panel) {
  if (panel.dataset.built) return;
  panel.dataset.built = '1';
  panel.innerHTML =
    '<div class="ib-head">' + esc(tr('Inbound bookings (pre-arrival)')) + ' <span class="cnt ib-count"></span>' +
      '<button class="ghost ib-alltoggle"></button>' +
      '<label class="fl" title="' + esc(tr('ETD on/after (yyyy-mm-dd) — blank = open-ended')) + '"><input type="text" id="ibFrom" class="datebox" placeholder="yyyy-mm-dd" maxlength="10" inputmode="numeric" autocomplete="off"></label>' +
      '<span class="fl">→</span>' +
      '<label class="fl" title="' + esc(tr('ETD on/before (yyyy-mm-dd) — blank = open-ended')) + '"><input type="text" id="ibTo" class="datebox" placeholder="yyyy-mm-dd" maxlength="10" inputmode="numeric" autocomplete="off"></label>' +
      '<button class="ghost ib-collapse" title="' + esc(tr('Collapse')) + '">▾</button></div>' +
    '<div class="ib-search">' +
      '<select id="ibOrigin" title="' + esc(tr('Origin office that received the booking')) + '"><option value="">' + esc(tr('All origins')) + '</option></select>' +
      '<input type="text" id="ibParty" placeholder="' + esc(tr('shipper / consignee / customer')) + '" autocomplete="off" title="' + esc(tr('Match a party name or code in any role')) + '">' +
      '<input type="text" id="ibQ" placeholder="' + esc(tr('booking / ship-id / PO / HBL / ctr')) + '" autocomplete="off" title="' + esc(tr('Search booking no, spot/ship ID, PO, house or master bill, container')) + '">' +
      '<span class="combo portchips" id="ibPolChips" title="' + esc(tr('POL — type a code or name')) + '"><input type="text" placeholder="POL…" autocomplete="off"><div class="mention-pop"></div><span class="chiprow"></span></span>' +
      '<span class="combo portchips" id="ibPodChips" title="' + esc(tr('POD — type a code or name')) + '"><input type="text" placeholder="POD…" autocomplete="off"><div class="mention-pop"></div><span class="chiprow"></span></span>' +
    '</div>' +
    '<div class="ib-body"></div>';
  const orig = panel.querySelector('#ibOrigin');
  state._stations.forEach(s => { const o = el('option'); o.value = s.code; o.textContent = s.code; orig.appendChild(o); });
  orig.onchange = () => { state.ib.origin = orig.value; loadInbound(); };
  const party = panel.querySelector('#ibParty'), qIn = panel.querySelector('#ibQ');
  party.addEventListener('input', debounce(() => { state.ib.party = party.value.trim(); loadInbound(); }));
  qIn.addEventListener('input', debounce(() => { state.ib.q = qIn.value.trim(); loadInbound(); }));
  state._ibPolChips = makePortChips('#ibPolChips', { kind: 'pol', get: () => state.ib.pols, set: v => { state.ib.pols = v; }, onChange: loadInbound });
  state._ibPodChips = makePortChips('#ibPodChips', { kind: 'pod', get: () => state.ib.pods, set: v => { state.ib.pods = v; }, onChange: loadInbound });
  // ETD date-range filter (compact from → to, like the worklist date window): blank = open-ended on that side;
  // a typed range bypasses the recent/upcoming clip so historical ranges work. Same yyyy-mm-dd / .bad pattern.
  // Default window = last 100 days -> today (set once when the shell is first built).
  const ibFrom = panel.querySelector('#ibFrom'), ibTo = panel.querySelector('#ibTo');
  const ibToday = (ME && ME.today) ? ME.today : fmtDate(new Date());
  state.ib.to = ibToday; state.ib.from = shiftYmd(ibToday, -100);
  ibFrom.value = state.ib.from; ibTo.value = state.ib.to;
  const applyIbDate = (inp, key) => { const v = inp.value.trim(); if (v === '' || isYmd(v)) { inp.classList.remove('bad'); state.ib[key] = v; loadInbound(); } else { inp.classList.add('bad'); } };
  ibFrom.onchange = () => applyIbDate(ibFrom, 'from');
  ibTo.onchange = () => applyIbDate(ibTo, 'to');
  panel.querySelector('.ib-collapse').onclick = () => { const b = panel.querySelector('.ib-body'), s = panel.querySelector('.ib-search'); const hide = b.style.display !== 'none'; b.style.display = hide ? 'none' : ''; s.style.display = hide ? 'none' : ''; };
  panel.querySelector('.ib-alltoggle').onclick = () => { state.ibShowAll = !state.ibShowAll; loadInbound(); };
}
async function loadInbound() {
  const panel = $('#inboundPanel'); if (!panel) return;
  // pre-arrival is import-by-nature: shown on the Import view AND only if I may handle imports in this mode
  if (state.bound !== 'Import' || !hasPair(state.tmode, 'Import')) { panel.style.display = 'none'; return; }
  panel.style.display = '';
  buildInboundShell(panel);
  const tg = panel.querySelector('.ib-alltoggle');
  tg.textContent = state.ibShowAll ? tr('recent only') : tr('show all');
  tg.title = state.ibShowAll ? tr('Showing all — click to show only recent/upcoming') : tr('Showing recent + upcoming — click to show all');
  // a typed ETD range bypasses the recent/upcoming window (so a historical range isn't clipped to 0).
  const ibFromOk = isYmd(state.ib.from) && state.ib.from, ibToOk = isYmd(state.ib.to) && state.ib.to;
  const ibDateRange = !!(ibFromOk || ibToOk);
  let q = '/api-ops/inbound?mode=' + encodeURIComponent(state.tmode) + ((state.ibShowAll || ibDateRange) ? '&showAll=1' : '');
  if (state.ib.origin) q += '&origin=' + encodeURIComponent(state.ib.origin);
  if (state.ib.party) q += '&party=' + encodeURIComponent(state.ib.party);
  if (state.ib.q) q += '&q=' + encodeURIComponent(state.ib.q);
  if (state.ib.pols.length) q += '&pol=' + encodeURIComponent(state.ib.pols.join(','));
  if (state.ib.pods.length) q += '&pod=' + encodeURIComponent(state.ib.pods.join(','));
  if (ibFromOk) q += '&from=' + encodeURIComponent(state.ib.from);
  if (ibToOk) q += '&to=' + encodeURIComponent(state.ib.to);
  const data = await api(q);
  const rows = arr(data.rows);
  panel.querySelector('.ib-count').textContent = rows.length;
  const body = panel.querySelector('.ib-body'); body.innerHTML = '';
  const searching = !!(state.ib.origin || state.ib.party || state.ib.q || state.ib.pols.length || state.ib.pods.length || ibDateRange);
  if (!rows.length) {
    const wide = state.ibShowAll || ibDateRange;   // a typed ETD range already widens past the recent/upcoming window
    const base = wide ? tr('Nothing in the feed') : tr('Nothing recent/upcoming in the feed');
    body.appendChild(el('div', 'bh', base + (searching ? ' ' + tr('matching the search') : '') + (wide ? '' : ' ' + tr('— try “show all”'))));
    body.firstChild.style.opacity = '.7';
    return;
  }
  if (state.tmode === 'Air') {
    // Air: group by flight no so scattered bookings on the same flight sit together ('(no flight yet)' last)
    const fmap = new Map();
    rows.forEach(r => { const k = r.vesselFlight || '(no flight yet)'; if (!fmap.has(k)) fmap.set(k, []); fmap.get(k).push(r); });
    const fgroups = [...fmap.entries()].sort((a, b) => {
      if (a[0].startsWith('(no')) return 1; if (b[0].startsWith('(no')) return -1;
      const ea = a[1].slice().sort(ibByDate)[0], eb = b[1].slice().sort(ibByDate)[0];
      const x = (ea && (ea.etd || ea.cargoReady)) || '9999', y = (eb && (eb.etd || eb.cargoReady)) || '9999';
      return x < y ? -1 : x > y ? 1 : 0;
    });
    fgroups.forEach(([k, gs]) => {
      body.appendChild(el('div', 'bh', esc(k === '(no flight yet)' ? tr('(no flight yet)') : k) + ' <span class="cnt">' + gs.length + '</span>'));
      gs.sort(ibByDate).forEach(r => body.appendChild(inboundCard(r)));
    });
  } else {
    IB_STAGES.forEach(g => {
      const gs = rows.filter(r => ibStage(r) === g.k).sort(ibByDate);
      if (!gs.length) return;
      body.appendChild(el('div', 'bh', esc(tr(g.t)) + ' <span class="cnt">' + gs.length + '</span>'));
      gs.forEach(r => body.appendChild(inboundCard(r)));
    });
  }
}
function inboundCard(r) {
  const c = el('div', 'ibcard ' + (r.light || 'G'));
  // headline = CONTROLLING CUSTOMER (rcustomer) when the origin recorded one; else the consignee.
  // The full party set (shpr/cgne/agnt) lives on its own clickable subline.
  const cnee = r.consigneeName || r.consigneeCode || '—';
  const ctrl = r.ctrlName || r.ctrlCode || '';
  const headWho = ctrl ? tr('cust:') + ' ' + esc(ctrl) : tr('cgne:') + ' ' + esc(cnee);
  const route = [r.pol, r.pod].filter(Boolean).join(' → ');
  // service label only meaningful for sea (FCL/LCL); for air "Air" is redundant (mode already selected)
  const svc = (r.cargoType && r.cargoType.toUpperCase() !== 'AIR') ? (r.service ? r.cargoType + ' (' + r.service.trim() + ')' : r.cargoType) : '';
  const qty = [r.bookingQty, r.bookingWgt].filter(Boolean).join(' / ') || r.cargoSummary || '';
  const conv = r.vesselFlight ? esc(r.vesselFlight) : '';
  const asg = r.assignedTo ? '<span class="ib-asg" title="' + esc(tr('Reassign')) + '">' + esc(r.assignedTo) + '</span>'
                           : '<button class="tick primary ib-assign">' + tr('Assign') + '</button>';
  // dates are the operator's lever for talking to the consignee — give them their own prominent row
  const dates = [];
  if (r.cargoReady) dates.push(tr('cargo-ready') + ' <b>' + esc(r.cargoReady) + '</b>');
  if (r.etd) dates.push('ETD <b>' + esc(r.etd) + '</b>');
  const dateRow = dates.length ? dates.join('&nbsp;&nbsp;·&nbsp;&nbsp;') : tr('dates not set yet — confirm with origin');
  // line 2: the operational shape — origin, service, qty, route, planned conveyance
  const sub = [tr('from') + ' ' + esc(r.sourceStation), esc(svc), esc(qty), esc(route), conv].filter(Boolean).join('  ·  ');
  // line 3: the reference numbers used when talking to the consignee / tracing the box
  const ids = [r.masterBill ? (r.mode === 'Air' ? 'MAWB ' : 'MBL ') + esc(r.masterBill) : '',
    r.containerNo ? tr('ctr') + ' ' + esc(r.containerNo) : '', r.spotId ? tr('ship-id') + ' ' + esc(r.spotId) : '',
    r.poNo ? 'PO ' + esc(r.poNo) : '']
    .filter(Boolean).join('  ·  ');
  // parties subline: clickable — fills the panel's party search (matches name or code in any role)
  const mkPty = (lbl, name, code, title) => (name || code)
    ? '<span class="pty" data-q="' + esc(code || name) + '" title="' + esc(tr(title) + ' — ' + tr('click to search the feed for this company')) + '">' + tr(lbl) + ' ' + esc(name || code) + '</span>' : '';
  const pty = [mkPty('shpr', r.shipperName, r.shipperCode, 'shipper'), mkPty('cgne', r.consigneeName, r.consigneeCode, 'consignee'),
    mkPty('agnt', r.agentName, r.agentCode, 'agent (agn2)')].filter(Boolean).join('  ·  ');
  // OFFSHORE: we're only an off-bill party (controlling/routing agent) — not the destination agent/notify/consignee
  // shown on the bill — so this is a cross-trade move we coordinate, not a real import arriving to us.
  const offTag = r.offshore ? '<span class="chip offshore" title="' + esc(tr('Offshore: we are only the controlling/routing agent (not shown on the bill) — not an actual import to us')) + '">' + esc(tr('OFFSHORE')) + '</span>' : '';
  c.innerHTML =
    '<div class="r1"><span class="mref">' + esc(r.bookingNo) + '</span>' + offTag +
      (r.incoterm ? '<span class="minco">' + esc(r.incoterm) + '</span>' : '') +
      '<span class="mwho" title="' + esc(ctrl ? tr('controlling customer (rcustomer)') : tr('consignee')) + '">' + headWho + '</span><span class="mspacer"></span>' + asg + '</div>' +
    '<div class="ib-dates">' + dateRow + '</div>' +
    (sub ? '<div class="r2">' + sub + '</div>' : '') +
    (pty ? '<div class="r2 pty-row">' + pty + '</div>' : '') +
    (ids ? '<div class="r2 ib-ids">' + ids + '</div>' : '');
  const ab = c.querySelector('.ib-assign'); if (ab) ab.onclick = e => { e.stopPropagation(); assignInbound(r); };
  const ac = c.querySelector('.ib-asg'); if (ac) ac.onclick = e => { e.stopPropagation(); assignInbound(r); };
  c.querySelectorAll('.pty').forEach(p => p.onclick = e => {
    e.stopPropagation();
    state.ib.party = p.dataset.q;
    const inp = $('#ibParty'); if (inp) inp.value = p.dataset.q;
    loadInbound();
  });
  return c;
}
function assignInbound(r) {
  const bg = el('div', 'modal-bg'); const box = el('div', 'modal');
  box.innerHTML = '<h3>' + esc(tr('Assign inbound booking')) + '</h3><p class="modal-msg">' + esc(r.bookingNo) + ' ' + esc(tr('from')) + ' ' + esc(r.sourceStation) + ' · ' + esc(tr('consignee')) + ' ' + esc(r.consigneeName || r.consigneeCode || '—') + '</p>';
  const sel = el('select'); sel.innerHTML = '<option value="">' + esc(tr('— unassign —')) + '</option>';
  state.roster.forEach(u => { const o = el('option'); o.value = u; o.textContent = u; if (u === r.assignedTo) o.selected = true; sel.appendChild(o); });
  box.appendChild(sel);
  const ta = el('textarea'); ta.placeholder = tr('note to the operator (optional)'); box.appendChild(ta);
  const bar = el('div', 'modal-bar'); const cancel = el('button', 'ghost', tr('Cancel')); const ok = el('button', 'primary', tr('Save'));
  bar.appendChild(cancel); bar.appendChild(ok); box.appendChild(bar);
  bg.appendChild(box); document.body.appendChild(bg);
  const done = () => bg.remove();
  cancel.onclick = done; bg.onclick = e => { if (e.target === bg) done(); };
  ok.onclick = async () => {
    ok.disabled = true;
    await api('/api-ops/inbound-assign', { method: 'POST', body: { source_station: r.sourceStation, mode: r.mode, booking_no: r.bookingNo, assignee: sel.value, note: ta.value.trim(), mentions: [] } });
    done(); loadInbound(); loadTasks();
  };
}

// ---------- worklist ----------
// arrival-driven buckets, by bound. Rows arrive already server-sorted (bound, arrival rank, sort_key).
const BUCKETS = {
  Import: [
    { key: 'arrived', title: 'Arrived — deliver now' },
    { key: 'arriving', title: 'Arriving — prepare' },
    { key: 'planning', title: 'Planning' },
  ],
  Export: [
    { key: 'no_space', title: 'Awaiting booking / space' },
    { key: 'customs_window', title: 'Customs window (ETD−3)' },
    { key: 'cargo_pending', title: 'Cargo not ready' },
    { key: 'on_track', title: 'On track' },
  ],
};
async function loadWorklist() {
  const wl = $('#worklist'); wl.innerHTML = '<div class="empty">' + esc(tr('Loading…')) + '</div>';
  const refMode = state.searchField !== 'company' && state.ref;
  let q = '/api-ops/worklist?lens=' + encodeURIComponent(state.lens);
  if (state.lens === 'user') q += '&user=' + encodeURIComponent(state.teammate || state.user);
  if (refMode) {
    // identifier lookup: ignore date window, lens and other filters server-side; just find the file by its number
    q += '&ref=' + encodeURIComponent(state.ref) + '&refField=' + encodeURIComponent(state.searchField);
  } else {
    // "My notes": server returns shipments I've noted across ALL dates (so a note never gets lost off-window)
    if (state.notesOnly) q += '&flag=notes';
    else { if (state.from) q += '&from=' + encodeURIComponent(state.from); if (state.to) q += '&to=' + encodeURIComponent(state.to); }
    if (state.company) q += '&company=' + encodeURIComponent(state.company);
    if (state.pols.length) q += '&pol=' + encodeURIComponent(state.pols.join(','));
    if (state.pods.length) q += '&pod=' + encodeURIComponent(state.pods.join(','));
    if (state.station) q += '&station=' + encodeURIComponent(state.station);
  }
  const data = await api(q);
  // an identifier hit may be a different mode/bound than the current toggle — align the view so it shows in context
  if (refMode && arr(data.rows).length) { const r0 = arr(data.rows)[0]; syncModeBound(r0.mode, r0.bound || 'Import'); }
  let rows = arr(data.rows).filter(r => (r.bound || 'Import') === state.bound && (r.mode || 'Sea') === state.tmode);
  if (state.alertsOnly) rows = rows.filter(r => r.worst === 'R' || r.worst === 'A');   // narrow to red/amber alerts
  const word = (state.tmode === 'Air' ? tr('air') : tr('sea')) + ' ' + (state.bound === 'Import' ? tr('import') : tr('export'));
  const shipsW = tr('shipments');
  wl.innerHTML = '';
  if (!rows.length) {
    $('#wlCount').textContent = '0 ' + word + ' ' + shipsW;
    if (refMode) { wl.innerHTML = '<div class="empty">' + esc(tr('No shipment found for') + ' ' + (($('#fSearchField') && $('#fSearchField').selectedOptions[0].text) || '')) + ' “' + esc(state.ref) + '” ' + esc(tr('(searched all dates, within your access).')) + '</div>'; return; }
    if (state.notesOnly) { wl.innerHTML = '<div class="empty">' + esc(tr('No') + ' ' + word + ' ' + tr('shipments you have noted')) + (state.alertsOnly ? ' ' + esc(tr('with a red/amber alert')) : '') + '. ' + esc(tr('Notes you add appear here on any date.')) + '</div>'; return; }
    if (state.alertsOnly) { wl.innerHTML = '<div class="empty">' + esc(tr('No') + ' ' + word + ' ' + tr('shipments with a red/amber alert in this view.')) + '</div>'; return; }
    const win = (state.from || state.to) ? ' ' + esc(tr('moving, due or created in') + ' ' + (state.from || '…') + ' → ' + (state.to || '…') + ' ' + tr('(clear the dates to see all)')) : '';
    const filt = (state.company || state.pols.length || state.pods.length) ? ' ' + esc(tr('matching the active filters')) : '';
    wl.innerHTML = '<div class="empty">' + esc(tr('No') + ' ' + word + ' ' + tr('shipments')) + filt + win + '.</div>'; return;
  }
  const buckets = BUCKETS[state.bound] || BUCKETS.Import;
  const ord = {}; buckets.forEach((b, i) => ord[b.key] = i);
  // group rows by vessel/voyage; derive ONE status per vessel (most-advanced state across its shipments,
  // so a vessel isn't split across buckets just because ATA is filled on only some of its bills)
  const gmap = new Map();
  const isAirMode = state.tmode === 'Air';
  // Air groups by MAWB (flight numbers repeat — same weekly flight — so MAWB is the true consolidation unit);
  // Sea groups by vessel/voyage. No master yet → one shared bucket so consolidation candidates sit together.
  const noConv = isAirMode ? '(no MAWB yet)' : '(no vessel / voyage yet)';
  rows.forEach(r => { const k = (isAirMode ? r.masterBill : r.vesselVoyage) || noConv; if (!gmap.has(k)) gmap.set(k, { vv: k, rows: [] }); gmap.get(k).rows.push(r); });
  const gList = [...gmap.values()].map(g => {
    let best = 99, sk = '';
    g.rows.forEach(r => { const o = (ord[r.arrivalState] != null ? ord[r.arrivalState] : 9); if (o < best) best = o; if (r.sortKey && (!sk || r.sortKey < sk)) sk = r.sortKey; });
    g.key = (buckets[best] && buckets[best].key) || 'other'; g.sortKey = sk;
    return g;
  });
  const conv = isAirMode ? 'MAWB' : 'vessel';
  $('#wlCount').textContent = rows.length + ' ' + word + ' · ' + gList.length + ' ' + plural(gList.length, conv);
  buckets.forEach(bk => {
    const gs = gList.filter(g => g.key === bk.key).sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0));
    if (!gs.length) return;
    const ships = gs.reduce((a, g) => a + g.rows.length, 0);
    const sec = el('div', 'bucket');
    sec.appendChild(el('div', 'bh', esc(tr(bk.title)) + ' <span class="cnt">' + gs.length + ' ' + plural(gs.length, conv) + ' · ' + ships + ' ' + esc(tr('shp')) + '</span>'));
    gs.forEach(g => sec.appendChild(vesselGroup(g)));
    wl.appendChild(sec);
  });
}
function vesselGroup(g) {
  const rs = g.rows.slice();
  // ungrouped bucket (no MAWB / no vessel yet): order by routing (lane) then consignee so an operator can
  // eyeball which shipments share a destination/consignee and could be consolidated onto one MAWB.
  if (/^\(no /.test(g.vv)) rs.sort((a, b) => { const ka = (a.lane || '') + '|' + (a.consigneeName || ''); const kb = (b.lane || '') + '|' + (b.consigneeName || ''); return ka < kb ? -1 : ka > kb ? 1 : 0; });
  const worst = rs.some(r => r.worst === 'R') ? 'R' : (rs.some(r => r.worst === 'A') ? 'A' : 'G');
  const sample = rs.find(r => r.arrivalState === g.key) || rs[0];
  const totalCont = rs.reduce((a, r) => a + (r.containerCount || 0), 0);
  const isAir = (rs[0] && rs[0].mode === 'Air');
  const unit = isAir ? '' : (totalCont ? ' · ' + totalCont + ' ' + tr('ctr') : '');
  const box = el('div', 'vgroup' + (allCollapsed ? ' collapsed' : ''));
  const head = el('div', 'vhead ' + worst);
  // air group headers add the flight (vesselVoyage = airline+flight) and the leg route — flight numbers repeat
  // weekly, so MAWB + flight + route together identify the consol at a glance
  const airBits = isAir ? [sample.vesselVoyage ? esc(sample.vesselVoyage) : '', sample.routeSummary ? '<span class="vroute">' + esc(sample.routeSummary) + '</span>' : '']
    .filter(Boolean).map(s => ' · ' + s).join('') : '';
  head.innerHTML = '<span class="vtoggle">▾</span><span class="vname">' + esc(/^\(no /.test(g.vv) ? tr(g.vv) : g.vv) + airBits + '</span>' +
    arrivalChip(sample) + '<span class="vmeta">' + rs.length + ' ' + esc(tr('shp')) + unit + '</span>';
  const list = el('div', 'vlist');
  rs.forEach(r => list.appendChild(miniCard(r)));
  head.onclick = () => box.classList.toggle('collapsed');
  box.appendChild(head); box.appendChild(list);
  return box;
}
function fmtNum(s) { const n = parseFloat(s); return isNaN(n) ? '' : Math.round(n).toLocaleString(); }
function cargoProfile(r) {   // Air -> pieces + weight; FCL -> containers; LCL -> weight (+cbm)
  if (r.cargoType === 'AIR') {
    const w = fmtNum(r.totalWeight);
    return esc([r.containerSummary || '', w ? w + ' kg' : ''].filter(Boolean).join(' · '));
  }
  if (r.cargoType === 'LCL') {
    const w = fmtNum(r.totalWeight); const cbm = parseFloat(r.totalCbm);
    let s = w ? w + ' kg' : '';
    if (!isNaN(cbm) && cbm > 0) s += (s ? ' · ' : '') + cbm.toFixed(2) + ' cbm';
    return esc(s);
  }
  return r.containerSummary ? esc(r.containerSummary).replace(/(\d+)x/g, '$1×') : '';
}
function arrivalChip(r) {
  switch (r.arrivalState) {
    case 'arrived': return '<span class="chip arrived">' + esc(tr('Arrived')) + ' ' + esc(r.ata || '') + '</span>';
    case 'arriving': return '<span class="chip transit">' + esc(tr('In transit')) + (r.eta ? ' · ETA ' + esc(r.eta) : (r.etd ? ' · ' + esc(tr('dep')) + ' ' + esc(r.etd) : '')) + '</span>';
    case 'planning': return '<span class="chip plan">' + esc(tr('Planning')) + '</span>';
    case 'no_space': return '<span class="chip nospace">' + esc(tr('Awaiting space')) + '</span>';
    case 'customs_window': return '<span class="chip transit">' + esc(tr('Customs')) + (r.etd ? ' · ETD ' + esc(r.etd) : '') + '</span>';
    case 'cargo_pending': return '<span class="chip plan">' + esc(tr('Cargo pending')) + '</span>';
    case 'on_track': return '<span class="chip arrived">' + esc(tr('On track')) + '</span>';
    default: return '';
  }
}
// compact per-shipment row inside a vessel/flight group. Vessel + arrival status live on the group header.
// Top line: the doc the party recognises (import → origin house BL/AWB; export → our job no) + incoterm + who.
// Sub line: what distinguishes near-identical shipments — container no / liner SO, cargo, customer PO,
// the other bill, lane, and (export) cargo-ready/ETD so urgency is visible before a vessel is even booked.
function miniCard(r) {
  const c = el('div', 'mcard ' + r.worst);
  const isImport = (r.bound || 'Import') === 'Import';
  const isAir = r.mode === 'Air';
  // headline = the CONTROLLING CUSTOMER (rcustomer) — whose business this is; falls back to the
  // consignee/shipper when no controlling customer is recorded. The parties live on their own subline.
  const ctrlName = r.ctrlCode ? compName(r.ctrlCode) : '';
  const who = ctrlName || (isImport ? (r.consigneeName || r.custCode) : (r.shipperName || r.custCode));
  const cargo = cargoProfile(r);
  const sev = r.openRed ? '<span class="pill R">' + r.openRed + 'R</span>' : (r.openAmber ? '<span class="pill A">' + r.openAmber + 'A</span>' : '');
  const updLbl = r.updateMilestoneName || r.updateMilestone || '';
  const updTip = (r.updateMilestone ? r.updateMilestone + ' — ' : '') + (r.updateMilestoneName || tr('status update')) + ' ' + tr('(updated, no remark)');
  // 💬 tooltip shows WHAT was written (latest note), prefixed by its milestone code — e.g. "A3: Temporary Release".
  // Milestone-tick notes are stored as "Ticked A3 complete: <reason>" — strip the boilerplate, keep the reason.
  let noteTip = tr('has a remark / note');
  if (r.noteText) {
    const txt = r.noteText.replace(/^Ticked\s+\S+\s+complete:?\s*/i, '').replace(/^Re-opened\s+\S+\s*:?\s*/i, '');
    noteTip = (r.noteMilestone ? r.noteMilestone + ': ' : '') + (txt || r.noteText);
  }
  const note = (r.hasNotes ? '<span class="note-ind" title="' + esc(noteTip) + '">💬</span>' : '')
    + (r.hasUpdate ? '<span class="upd-ind" title="' + esc(updTip) + '">' + (updLbl ? esc(updLbl) : tr('updated')) + '</span>' : '');
  const mLbl = isAir ? 'MAWB' : 'MBL';
  // 🆕 = job created within the last 7 days — a fresh booking the operator may not have seen yet
  const today = (ME && ME.today) ? new Date(ME.today + 'T00:00:00') : new Date();
  const isNew = r.anchor && (today - new Date(r.anchor + 'T00:00:00')) / 86400000 < 7;
  const newTag = isNew ? '<span class="chip newbk" title="' + esc(tr('new booking - created') + ' ' + (r.anchor || '')) + '">' + esc(tr('NEW')) + '</span>' : '';
  // booking-stage record (pre-house booking): flag it so operators see it's not yet a confirmed house bill/AWB
  const bkgTag = (r.billStage === 'booking') ? '<span class="chip bkgstage" title="' + esc(tr('Booking stage - not yet a house bill/AWB')) + '">' + esc(tr('BOOKING')) + '</span>' : '';
  // primary id: the PER-SHIPMENT number the operator/customer recognises, never the internal synthetic key
  // and never the job number first (one job no can cover many house bills). Lead with the house bill, then the
  // booking (sono) — both per-HBL — then the job no, then the synthetic key as a last resort.
  const humanId = isImport
    ? (r.houseBill || r.sono || r.erpJobNo || r.masterBill || r.jobNo)
    : (r.houseBill || r.sono || r.erpJobNo || r.jobNo);
  const primary = esc(humanId);
  const inco = r.incoterm ? '<span class="minco" title="' + esc(tr('Incoterm — your delivery responsibility')) + '">' + esc(r.incoterm) + '</span>' : '';
  // sub-line bits (all pre-escaped)
  const diff = r.containerNo
    ? tr('ctr') + ' ' + esc(r.containerNo) + (r.containerCount > 1 ? ' +' + (r.containerCount - 1) : '')
    : (r.linerSo ? tr('SO') + ' ' + esc(r.linerSo) : '');
  // import: show the master (OBL for sea, MAWB for air). House bill is the headline, job no rides jobTag,
  // booking rides the sono bit — so this only adds the master, and only for import.
  const otherBill = (isImport && r.masterBill) ? (mLbl + ' ' + esc(r.masterBill)) : '';
  // sea custRef = spot/ship ID, air = customer PO (both are what the customer quotes back)
  const po = r.custRef ? (isAir ? 'PO ' : tr('ship-id') + ' ') + esc(r.custRef) : '';
  const sono = (r.sono && r.sono !== humanId) ? tr('bkg') + ' ' + esc(r.sono) : '';   // skip if the booking is already the headline
  const commod = r.commodity ? '<span title="' + esc(r.commodity) + '">' + esc(r.commodity.length > 28 ? r.commodity.slice(0, 28) + '…' : r.commodity) + '</span>' : '';
  const exp = !isImport ? [r.cargoReady ? tr('cargo-ready') + ' ' + esc(r.cargoReady) : '', r.etd ? 'ETD ' + esc(r.etd) : ''].filter(Boolean).join(' · ') : '';
  // import logistics dates: pickup-available and (expected or actual) delivery — the consignee's questions
  const impDates = isImport ? [r.availableDate ? tr('avail') + ' ' + esc(r.availableDate) : '',
    r.goodsDelivery ? tr('dlvd') + ' ' + esc(r.goodsDelivery) : (r.etaDelivery ? tr('dlv') + ' ' + esc(r.etaDelivery) : '')].filter(Boolean).join(' · ') : '';
  const jobTag = (r.erpJobNo && r.erpJobNo !== humanId) ? tr('job') + ' ' + esc(r.erpJobNo) : '';   // always keep the human job no visible when it isn't the headline
  const sub = [diff, cargo, commod, po, sono, otherBill, exp, impDates, esc(r.routeSummary || r.lane || ''), jobTag].filter(Boolean).join('  ·  ');
  // parties subline: shipper / consignee / agent — each clickable to apply the company filter
  const mkPty = (lbl, code, title) => code
    ? '<span class="pty" data-code="' + esc(code) + '" title="' + esc(tr(title) + ' — ' + tr('click to filter the worklist by this company')) + '">' + tr(lbl) + ' ' + esc(compName(code)) + '</span>' : '';
  const pty = [mkPty('shpr', r.shipperCode, 'shipper'), mkPty('cgne', r.consigneeCode, 'consignee'), mkPty('agnt', r.agentCode, 'agent (agn2)')].filter(Boolean).join('  ·  ');
  c.innerHTML =
    '<div class="r1">' +
      '<span class="mref">' + (primary || '—') + '</span>' + bkgTag + newTag + inco +
      '<span class="mwho" title="' + esc(tr('controlling customer (rcustomer)')) + '">' + esc(who || '—') + '</span>' +
      '<span class="mspacer"></span>' + sev + note +
    '</div>' +
    (sub ? '<div class="r2">' + sub + '</div>' : '') +
    (pty ? '<div class="r2 pty-row">' + pty + '</div>' : '');
  c.onclick = () => openShipment(r.jobNo, humanId);
  c.querySelectorAll('.pty').forEach(p => p.onclick = e => { e.stopPropagation(); setCompany(p.dataset.code); loadWorklist(); });
  return c;
}

// ---------- shipment drawer ----------
async function openShipment(job, label) {
  $('#drawerBg').classList.add('open'); $('#drawer').classList.add('open');
  $('#dJob').textContent = label || job; $('#dLane').textContent = ''; $('#drawerBody').innerHTML = '<div class="empty">' + esc(tr('Loading…')) + '</div>';
  const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job));
  renderShipment(job, data);
}
function closeDrawer() { $('#drawerBg').classList.remove('open'); $('#drawer').classList.remove('open'); }

// Open the EDITABLE shipment for a Book Now confirmation note: resolve the ERP booking number to its worklist job_no
// (it's pulled in by the delta seed), then open the drawer (which has the Edit ERP editor). If it isn't in the
// worklist yet, say so rather than opening a dead 'Edit ERP' on a job that doesn't exist.
async function openBookingNote(bookingNo) {
  if (!bookingNo) return;
  let d; try { d = await api('/api-ops/booking-job?ref=' + encodeURIComponent(bookingNo)); } catch (e) { d = {}; }
  if (d && d.jobNo) openShipment(d.jobNo, bookingNo);
  else bnToast(tr('Booking') + ' ' + bookingNo + ': ' + tr('not in the worklist yet — it becomes editable after the next refresh.'));
}

function renderShipment(job, data) {
  const chk = data.checklist || {}; const sh = chk.shipment || {}; const roll = chk.rollup || {};
  $('#dLight').className = 'dot ' + (roll.worst_light || 'G');
  $('#dLane').textContent = (sh.bound || '') + ' · ' + (sh.lane || '');
  const body = $('#drawerBody'); body.innerHTML = '';
  const head = el('div', 'muted', 'ETD ' + (sh.etd || '—') + ' · ETA ' + (sh.eta || '—') + ' · ATD ' + (sh.atd || '—') +
    ' &nbsp;|&nbsp; ' + tr('auto') + ' ' + (roll.automation ? roll.automation.auto : 0) + ' · ' + tr('manual') + ' ' + (roll.automation ? roll.automation.manual : 0));
  head.style.marginBottom = '8px';
  // pen = quick shortcut to the Edit ERP data editor (same as the panel button lower down)
  const pen = el('span', 'penedit', '✎');
  pen.title = tr('Edit ERP data'); pen.style.cssText = 'cursor:pointer;margin-left:8px;color:var(--accent,#2563eb)';
  pen.onclick = () => window.open('erp-edit.html?job=' + encodeURIComponent(job), '_blank');
  head.appendChild(pen);
  body.appendChild(head);
  // reference docs the operator + customer recognise (house/master bill, incoterm, PO, container, cargo-ready)
  const isAir = sh.mode === 'Air';
  const refBits = [];
  if (sh.house_bill) refBits.push('<b>' + (isAir ? 'HAWB' : tr('House BL')) + '</b> ' + esc(sh.house_bill));
  if (sh.master_bill) refBits.push((isAir ? 'MAWB' : tr('Master BL')) + ' ' + esc(sh.master_bill));
  if (sh.incoterm) refBits.push(tr('Incoterm') + ' <b>' + esc(sh.incoterm) + '</b>');
  if (sh.cust_ref) refBits.push(tr('Cust PO') + ' ' + esc(sh.cust_ref));
  if (sh.container_no) refBits.push(tr('Ctr') + ' ' + esc(sh.container_no) + (sh.container_count > 1 ? ' +' + (sh.container_count - 1) : ''));
  else if (sh.liner_so) refBits.push(tr('Liner SO') + ' ' + esc(sh.liner_so));
  if (sh.cargo_ready) refBits.push(tr('Cargo-ready') + ' ' + esc(sh.cargo_ready));
  const ex = data.extra || {};
  if (ex.sono) refBits.push(tr('Bkg/SO') + ' ' + esc(ex.sono));
  if (ex.availableDate) refBits.push(tr('Avail pickup') + ' ' + esc(ex.availableDate));
  if (ex.goodsDelivery) refBits.push(tr('Delivered') + ' ' + esc(ex.goodsDelivery));
  else if (ex.etaDelivery) refBits.push(tr('Exp delivery') + ' ' + esc(ex.etaDelivery));
  if (refBits.length) { const rd = el('div', 'refdocs', refBits.join(' &nbsp;·&nbsp; ')); body.appendChild(rd); }

  // route timeline + cargo + internal remark (seeded snapshot, refreshable live from the ERP)
  body.appendChild(deepDetailSection(job, data));

  const actions = el('div'); actions.style.cssText = 'margin-bottom:10px';
  const rb = el('button', 'ghost', tr('Remind me')); rb.style.fontSize = '12px'; rb.onclick = () => remindMe(job);
  actions.appendChild(rb); body.appendChild(actions);

  // milestones
  arr(chk.milestones).forEach(m => body.appendChild(milestoneRow(job, m)));

  // arrangements (who to contact + trucker/broker/warehouse tasks)
  body.appendChild(arrangementsPanel(job, sh, arr(data.notes)));

  // draft document review (HBL/HAWB customer agreement loop; editor opens in its own tab)
  body.appendChild(documentsPanel(job, sh));

  // files the ERP already holds for this shipment (browse only; keyed by booking/bill number)
  body.appendChild(erpFilesPanel(job, sh));

  // correct bad ERP master data (DUMMY party codes, ZZZ incoterm/port codes, etc.) - opens its own tab
  body.appendChild(erpEditPanel(job, sh));

  // notes (plain notes only — arrangement-kind notes live in the panel above)
  const plain = arr(data.notes).filter(n => n.kind !== 'arrangement');
  const nx = el('div', 'notes');
  nx.appendChild(el('h3', null, tr('Notes & reminders')));
  nx.appendChild(composer(job, null));
  const list = el('div', 'notelist');
  plain.forEach(n => list.appendChild(noteItem(n)));
  if (!plain.length) list.appendChild(el('div', 'empty', tr('No notes yet.')));
  nx.appendChild(list);
  body.appendChild(nx);
}
const ARR_TYPES = [
  { key: 'customer', label: 'Customer' },
  { key: 'trucker', label: 'Trucker' },
  { key: 'broker', label: 'Customs broker' },
  { key: 'warehouse', label: 'Warehouse' },
];
function arrPlaceholder(t) { return tr(({ customer: 'customer contact person', trucker: 'trucker company', broker: 'broker name', warehouse: 'warehouse' })[t] || 'party'); }
function arrangementsPanel(job, sh, notes) {
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, tr('Arrangements')));
  const isImport = (sh.bound || 'Import') === 'Import';
  const who = isImport ? sh.consignee_name : sh.shipper_name;
  const bits = [];
  if (sh.cust_contact) bits.push(esc(sh.cust_contact));
  if (sh.cust_phone) bits.push('Phone: <a href="tel:' + esc(sh.cust_phone) + '">' + esc(sh.cust_phone) + '</a>');
  if (sh.cust_email) bits.push('Email: <a href="mailto:' + esc(sh.cust_email) + '">' + esc(sh.cust_email) + '</a>');
  const contact = el('div', 'contact');
  contact.innerHTML = '<span class="lbl">' + esc(isImport ? tr('Consignee') : tr('Shipper')) + '</span> <b>' + esc(who || '—') + '</b>' +
    (bits.length ? ' · ' + bits.join(' · ') : ' <span class="mut">' + esc(tr('(no contact on file)')) + '</span>');
  wrap.appendChild(contact);
  const byType = {};
  arr(notes).filter(n => n.kind === 'arrangement').forEach(n => { (byType[n.arrType] = byType[n.arrType] || []).push(n); });
  ARR_TYPES.forEach(t => {
    const row = el('div', 'arr-row');
    const items = byType[t.key] || [];
    let html = '<div class="arr-head"><span class="arr-label">' + esc(tr(t.label)) + '</span>' +
      '<button class="tick ghost arr-add" data-type="' + t.key + '">' + esc(tr('+ reminder')) + '</button></div>';
    if (items.length) {
      html += '<div class="arr-items">' + items.map(n =>
        '<div class="arr-item' + (n.status === 'done' ? ' done' : '') + '" data-id="' + esc(n.id) + '">' +
        (n.party ? '<b>' + esc(n.party) + '</b> ' : '') + '<span>' + esc(n.note) + '</span>' +
        (n.contact ? ' <span class="mut">' + esc(n.contact) + '</span>' : '') +
        ' <span class="arr-st ' + esc(n.arrStatus || 'todo') + '">' + esc(tr(n.arrStatus || 'todo')) + '</span>' +
        (n.status === 'done' ? ' <span class="mut">✔ ' + esc(n.doneBy) + '</span>' : '<button class="tick ghost arr-done" data-id="' + esc(n.id) + '">' + esc(tr('done')) + '</button>') +
        '</div>').join('') + '</div>';
    }
    row.innerHTML = html;
    wrap.appendChild(row);
  });
  wrap.querySelectorAll('.arr-add').forEach(btn => btn.onclick = () => openArrangeForm(job, btn.dataset.type, wrap));
  wrap.querySelectorAll('.arr-done').forEach(btn => btn.onclick = async () => {
    await api('/api-ops/note-done', { method: 'POST', body: { id: btn.dataset.id, done: true } });
    const d = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, d); loadTasks();
  });
  return wrap;
}
function openArrangeForm(job, type, wrap) {
  const existing = wrap.querySelector('.arr-form'); if (existing) existing.remove();
  const f = el('div', 'arr-form');
  f.innerHTML =
    '<input class="ai party" placeholder="' + esc(arrPlaceholder(type)) + '">' +
    '<input class="ai contact" placeholder="' + esc(tr('contact / phone (optional)')) + '">' +
    '<input class="ai note" placeholder="' + esc(tr('reminder, e.g. confirm pickup from terminal → warehouse')) + '">' +
    '<select class="ai status"><option value="todo">' + esc(tr('to-do')) + '</option><option value="arranged">' + esc(tr('arranged')) + '</option><option value="confirmed">' + esc(tr('confirmed')) + '</option></select>' +
    '<span class="mentwrap"><input class="ai ment" placeholder="' + esc(tr('@mention a colleague — type name, team or station (optional)')) + '"><div class="mention-pop"></div></span>';
  const bar = el('div'); bar.style.cssText = 'display:flex;gap:8px;margin-top:6px';
  const save = el('button', 'primary', tr('Save')); const cancel = el('button', 'ghost', tr('Cancel'));
  bar.appendChild(save); bar.appendChild(cancel); f.appendChild(bar); wrap.appendChild(f);
  wireMention(f.querySelector('.ment'), f.querySelector('.mention-pop'));   // same @-mention picker as the note composer
  cancel.onclick = () => f.remove();
  save.onclick = async () => {
    const party = f.querySelector('.party').value.trim();
    const contact = f.querySelector('.contact').value.trim();
    const note = f.querySelector('.note').value.trim();
    const arr_status = f.querySelector('.status').value;
    const mentions = extractMentions(f.querySelector('.ment'));
    if (!note && !party) return;
    save.disabled = true;
    await api('/api-ops/notes', { method: 'POST', body: { job_no: job, kind: 'arrangement', arr_type: type, party, contact, arr_status, note: note || ('Arrange ' + type), mentions } });
    const d = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, d); loadTasks(); loadWorklist();
  };
}
// ---------- deep detail: route timeline + cargo + internal remark (snapshot ⇄ live ERP) ----------
// Normalize the two payload shapes into one: the seeded /api-ops/shipment response (route[], detail{}) and
// the live /api-ops/erp-detail response (top-level remark/commodity/cargo/route).
function normDeep(d) {
  const det = d.detail || {};
  return {
    route: arr(d.route),
    remark: det.remark || d.remark || '',
    special: det.special_remark || d.specialRemark || '',
    commodity: arr(det.commodity || d.commodity),
    cargo: det.cargo || d.cargo || null,
    stamp: d.fetchedAt || ((d.extra || {}).snapshotAt || ''),
  };
}
function routeTimeline(route) {
  const pts = arr(route); if (!pts.length) return '';
  return '<div class="rt">' + pts.map(p => {
    const dates = [p.dep ? 'dep <b>' + esc(p.dep) + (p.time ? ' ' + esc(p.time) : '') + '</b>' : '',
      p.arr ? 'arr <b>' + esc(p.arr) + '</b>' : ''].filter(Boolean).join(' · ');
    const conv = [p.flight ? 'flight ' + esc(p.flight) : '', p.vessel ? 'vessel ' + esc(p.vessel) : ''].filter(Boolean).join(' ');
    return '<div class="rt-pt"><span class="rt-role ' + esc(p.role || '') + '">' + esc(p.role || '') + '</span>' +
      '<span class="rt-port"><b>' + esc(p.code || '') + '</b>' + (p.name ? ' · ' + esc(p.name) : '') + '</span>' +
      (conv ? '<span class="rt-conv">' + conv + '</span>' : '') +
      (dates ? '<span class="rt-dates">' + dates + '</span>' : '') + '</div>';
  }).join('') + '</div>';
}
function cargoLine(c) {
  if (!c) return '';
  const f = o => [o.qty != null ? fmtNum(o.qty) + ' pcs' : '', o.wgt != null ? fmtNum(o.wgt) + ' kg' : '',
    o.cbm != null ? o.cbm + ' cbm' : '', o.cwt != null ? fmtNum(o.cwt) + ' cwt' : ''].filter(Boolean).join(' · ');
  const bits = [];
  if (c.book) { const s = f(c.book); if (s) bits.push('booked <b>' + s + '</b>'); }
  if (c.rece) { const s = f(c.rece); if (s) bits.push('received <b>' + s + '</b>'); }
  return bits.join(' &nbsp;|&nbsp; ');
}
function deepDetailSection(job, data) {
  const wrap = el('div', 'deep');
  const h = el('div', 'deep-head');
  h.innerHTML = '<h3>' + esc(tr('Route & ERP detail')) + '</h3>';
  const stamp = el('span', 'deep-stamp mut', '');
  const btn = el('button', 'ghost deep-btn', tr('Refresh from ERP'));
  btn.title = tr('Fetch this shipment live from the station ERP (one keyed lookup) — remark, route and cargo as of right now');
  h.appendChild(stamp); h.appendChild(btn);
  const inner = el('div', 'deep-body');
  wrap.appendChild(h); wrap.appendChild(inner);
  const renderInner = (d, live) => {
    let html = routeTimeline(d.route);
    const cg = cargoLine(d.cargo); if (cg) html += '<div class="deep-cargo">' + esc(tr('Cargo:')) + ' ' + cg + '</div>';
    if (d.commodity.length) html += '<div class="deep-comm">' + esc(tr('Goods:')) + ' ' + d.commodity.map(esc).join(' · ') + '</div>';
    if (d.remark) html += '<div class="deep-rem"><span class="lbl">' + esc(tr('Internal remark')) + '</span><div class="rem">' + esc(d.remark) + '</div></div>';
    if (d.special) html += '<div class="deep-rem"><span class="lbl">' + esc(tr('Special remark')) + '</span><div class="rem">' + esc(d.special) + '</div></div>';
    inner.innerHTML = html || '<div class="empty">' + esc(tr('No route / remark on the snapshot yet — try “Refresh from ERP”.')) + '</div>';
    stamp.className = 'deep-stamp ' + (live ? 'live' : 'mut');
    stamp.textContent = live ? (tr('live') + ' · ' + (d.stamp || '')) : (d.stamp ? tr('snapshot') + ' · ' + d.stamp : '');
  };
  renderInner(normDeep(data), false);
  btn.onclick = async () => {
    btn.disabled = true; btn.textContent = tr('fetching…');
    try {
      const live = await api('/api-ops/erp-detail?job=' + encodeURIComponent(job));
      if (live && live.error) { stamp.className = 'deep-stamp err'; stamp.textContent = live.error; }
      else renderInner(normDeep(live), true);
    } catch (e) { stamp.className = 'deep-stamp err'; stamp.textContent = tr('ERP fetch failed — is the VPN/source DB reachable?'); }
    btn.disabled = false; btn.textContent = tr('Refresh from ERP');
  };
  return wrap;
}
function milestoneRow(job, m) {
  const tracked = m.tracked !== false && m.state !== 'n/a';
  const row = el('div', 'ms ' + (m.state || ''));
  let tag = '';
  if (m.state === 'done') tag = '<span class="tag auto">' + esc(tr('auto ✓')) + '</span>';
  else if (m.state === 'bypassed') tag = '<span class="tag manual">' + esc(tr('manual ✓')) + '</span>';
  else if (m.state === 'n/a') tag = '<span class="tag na">' + esc(tr('n/a')) + '</span>';
  const lightClass = (m.state === 'done' || m.state === 'bypassed') ? 'G' : (m.light || 'G');
  const light = tracked ? '<span class="dot ' + lightClass + '"></span>' : '<span class="dot x"></span>';
  row.innerHTML = '<span class="seqn">' + esc(m.seq) + '</span>' + light +
    '<span class="nm">' + esc(m.code) + ' · ' + esc(tr(m.name)) + '<div class="st">' + esc(tr(m.basis || '')) + (m.due ? ' (' + esc(m.due) + ')' : '') + '</div></span>' + tag;
  // tick / untick control — only for tracked milestones
  if (tracked) {
    if (m.state === 'bypassed') {
      const b = el('button', 'tick ghost', tr('Un-tick')); b.onclick = () => closeMilestone(job, m.code, false, null); row.appendChild(b);
    } else if (m.state !== 'done') {
      const b = el('button', 'tick primary', tr('✓ Tick')); b.onclick = () => promptBypass(job, m.code, m.name); row.appendChild(b);
    }
  }
  return row;
}
// custom in-page text dialog (replaces native prompt() so there's no "localhost:8078 says" chrome)
function askText({ title, message, placeholder, okLabel }) {
  return new Promise(resolve => {
    const bg = el('div', 'modal-bg');
    const box = el('div', 'modal');
    box.innerHTML = '<h3>' + esc(title || '') + '</h3>' + (message ? '<p class="modal-msg">' + esc(message) + '</p>' : '');
    const ta = el('textarea'); ta.placeholder = placeholder || ''; box.appendChild(ta);
    const bar = el('div', 'modal-bar');
    const cancel = el('button', 'ghost', tr('Cancel'));
    const ok = el('button', 'primary', okLabel || tr('Confirm'));
    bar.appendChild(cancel); bar.appendChild(ok); box.appendChild(bar);
    bg.appendChild(box); document.body.appendChild(bg);
    setTimeout(() => ta.focus(), 30);
    const done = val => { bg.remove(); document.removeEventListener('keydown', onKey); resolve(val); };
    ok.onclick = () => done(ta.value);
    cancel.onclick = () => done(null);
    bg.onclick = e => { if (e.target === bg) done(null); };
    const onKey = e => { if (e.key === 'Escape') done(null); else if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) done(ta.value); };
    document.addEventListener('keydown', onKey);
  });
}
// dated self-reminder dialog: a note + optional follow-up date
function askReminder() {
  return new Promise(resolve => {
    const bg = el('div', 'modal-bg');
    const box = el('div', 'modal');
    box.innerHTML = '<h3>' + esc(tr('Remind me')) + '</h3><p class="modal-msg">' + esc(tr('A note to yourself about what to follow up on this shipment. Set a date to chase it (optional).')) + '</p>';
    const ta = el('textarea'); ta.placeholder = tr('e.g. chase trucker to confirm terminal pickup → warehouse'); box.appendChild(ta);
    const drow = el('div', 'modal-date');
    drow.innerHTML = '<span class="muted">' + esc(tr('Follow up on')) + '</span>';
    const date = el('input'); date.type = 'text'; date.placeholder = 'yyyy-mm-dd'; date.maxLength = 10; date.className = 'datebox'; drow.appendChild(date); box.appendChild(drow);
    const bar = el('div', 'modal-bar');
    const cancel = el('button', 'ghost', tr('Cancel'));
    const ok = el('button', 'primary', tr('Set reminder'));
    bar.appendChild(cancel); bar.appendChild(ok); box.appendChild(bar);
    bg.appendChild(box); document.body.appendChild(bg);
    setTimeout(() => ta.focus(), 30);
    const done = val => { bg.remove(); document.removeEventListener('keydown', onKey); resolve(val); };
    ok.onclick = () => { const t = ta.value.trim(); if (!t) { ta.focus(); return; } const dv = date.value.trim(); if (dv && !isYmd(dv)) { date.classList.add('bad'); date.focus(); return; } done({ note: t, date: dv }); };
    cancel.onclick = () => done(null);
    bg.onclick = e => { if (e.target === bg) done(null); };
    const onKey = e => { if (e.key === 'Escape') done(null); };
    document.addEventListener('keydown', onKey);
  });
}
// ---------- draft document review panel (HBL/HAWB customer agreement loop) ----------
const DOC_STATUS_LABEL = {
  DRAFT: 'Draft', SENT: 'Sent to customer', CUSTOMER_SUBMITTED: 'Customer sent corrections',
  CUSTOMER_APPROVED: 'Customer approved', AGREED: 'Agreed - ready to issue', ISSUED: 'Issued',
  AMEND_DRAFT: 'Amendment draft (fee applies)'
};
function documentsPanel(job, sh) {
  const dtype = sh.mode === 'Air' ? 'HAWB' : 'HBL';
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, tr('Draft {d} review').replace('{d}', dtype)));
  const bodyEl = el('div', null, '<div class="empty">' + esc(tr('Loading…')) + '</div>');
  wrap.appendChild(bodyEl);
  api('/api-ops/docs?job=' + encodeURIComponent(job)).then(d => {
    bodyEl.innerHTML = '';
    const docs = arr(d.docs);
    if (!docs.length) {
      const b = el('button', 'ghost', tr('+ Create draft {d} from this shipment').replace('{d}', dtype));
      b.style.fontSize = '12px';
      const label = b.textContent;
      b.onclick = async () => {
        // Open the editor tab NOW (inside the click = a user gesture, so the browser won't block it); it shows a
        // "preparing" placeholder and we point it at the editor once the draft is ready. Creating the draft reads
        // the ERP, so it takes a few seconds — keep the button honest about that instead of a silent spinner.
        let w = null; try { w = window.open('about:blank', '_blank'); } catch (e) {}
        if (w) { try { w.document.write('<!doctype html><meta charset="utf-8"><title>' + esc(tr('Preparing draft {d}…').replace('{d}', dtype)) + '</title><body style="font:15px -apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:48px;color:#333">' + esc(tr('Preparing your draft {d} from the shipment and ERP… this tab opens the editor automatically when it is ready.').replace('{d}', dtype)) + '</body>'); } catch (e) {} }
        b.disabled = true; b.textContent = tr('Creating draft {d}… (reading ERP, a few seconds)').replace('{d}', dtype);
        let r; try { r = await api('/api-ops/doc-create', { method: 'POST', body: { job_no: job } }); }
        catch (e) { r = { error: 'network error' }; }
        if (r.error && !r.docId) { if (w) w.close(); alert(r.error); b.disabled = false; b.textContent = label; return; }
        const url = 'doc-editor.html?id=' + encodeURIComponent(r.docId);
        if (w) w.location = url;                 // navigate the already-open tab to the editor
        b.textContent = tr('Draft {d} ready').replace('{d}', dtype) + (w ? '' : ' ' + tr('— click “Open editor” below'));
        openShipment(job);   // refresh the drawer so the panel shows the new doc + its Open editor button
      };
      bodyEl.appendChild(b);
      return;
    }
    docs.forEach(dc => {
      const card = el('div', 'doccard');
      const bits = ['<span class="docstatus s-' + esc(dc.status) + '">' + esc(tr(DOC_STATUS_LABEL[dc.status] || dc.status)) + '</span>',
        'v' + dc.currentVersion];
      if (dc.erpDocNo) bits.push(esc(tr('official no.')) + ' <b>' + esc(dc.erpDocNo) + '</b>');
      if (dc.amendCount) bits.push(esc(tr('amend #')) + dc.amendCount);
      if (dc.activeToken) bits.push(esc(tr('link live')) + ' (' + esc(dc.activeToken.customerEmail || tr('customer')) + ', ' + esc(tr('viewed')) + ' ' + dc.activeToken.viewCount + 'x)');
      else if (dc.customerEmail) bits.push(esc(dc.customerEmail));
      card.innerHTML = '<b>' + esc(dc.docType) + '</b> · ' + bits.join(' · ') + ' ';
      const open = el('button', 'ghost', tr('Open editor'));
      open.style.fontSize = '12px';
      open.onclick = () => window.open('doc-editor.html?id=' + encodeURIComponent(dc.docId), '_blank');
      card.appendChild(open);
      bodyEl.appendChild(card);
    });
  }).catch(() => { bodyEl.innerHTML = '<div class="empty">' + esc(tr('Could not load documents.')) + '</div>'; });
  return wrap;
}

// Correct bad ERP master data for this shipment (staff-internal). Opens erp-edit.html in its own tab, which
// self-seeds the current ERP values + master-code lookups and pushes only the changed fields to /booking/update.
function erpEditPanel(job, sh) {
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, tr('Edit ERP data')));
  const b = el('button', 'ghost', tr('Edit ERP data'));
  b.style.cssText = 'font-size:12px;margin-top:6px';
  b.onclick = () => window.open('erp-edit.html?job=' + encodeURIComponent(job), '_blank');
  wrap.appendChild(b);
  return wrap;
}

// Browse the files the ERP holds for this shipment. Read-only this round (document type / file name / remark);
// the heading shows which identifier was used so it's clear what the ERP matched on. Download comes later.
function erpFilesPanel(job, sh) {
  const wrap = el('div', 'arrange');
  const h = el('h3', null, tr('ERP files'));
  wrap.appendChild(h);
  const bodyEl = el('div', null, '<div class="empty">' + esc(tr('Loading…')) + '</div>');
  wrap.appendChild(bodyEl);
  api('/api-ops/erp-files?job=' + encodeURIComponent(job)).then(d => {
    bodyEl.innerHTML = '';
    if (d.error) { bodyEl.innerHTML = '<div class="empty">' + esc(d.error) + '</div>'; return; }
    if (d.mock) { bodyEl.innerHTML = '<div class="empty">' + esc(tr('ERP not configured — no live file lookup in this environment.')) + '</div>'; return; }
    const keyLabel = (d.keyKind || 'booking') + (d.keyUsed ? ' ' + d.keyUsed : '');
    const files = arr(d.files);
    h.textContent = tr('ERP files') + ' · ' + keyLabel;
    if (!files.length) {
      bodyEl.appendChild(el('div', 'empty', tr('No files in the ERP for this {k}.').replace('{k}', (d.keyKind || 'booking').toLowerCase())));
    } else {
      files.forEach(f => {
        const card = el('div', 'doccard');
        const bits = [];
        if (f.documentTypeCode) bits.push('<span class="docstatus">' + esc(f.documentTypeCode) + '</span>');
        bits.push('<b>' + esc(f.fileName || tr('(unnamed)')) + '</b>');
        if (f.remark) bits.push('<span class="mut">' + esc(f.remark) + '</span>');
        const meta = el('span'); meta.innerHTML = bits.join(' · '); card.appendChild(meta);
        if (f.fileName) {
          const dl = el('button', 'ghost', tr('Download')); dl.style.cssText = 'margin-left:auto;font-size:11px;padding:2px 8px';
          dl.onclick = () => downloadErpFile(job, f.fileName, dl);
          card.appendChild(dl);
        }
        bodyEl.appendChild(card);
      });
    }
    // upload to the ERP -> /file/upload. Always available (not only when a milestone would clear): offer every
    // configured doctype, flag the ones that also clear an alert on this shipment. Falls back to clearable list
    // (older server) or free-text (no doctypes configured) so upload is never blocked.
    const clearable = arr(d.clearableDoctypes);
    const allDt = arr(d.uploadDoctypes);
    bodyEl.appendChild(erpUploadRow(job, allDt.length ? allDt : clearable, clearable));
    // generate a document straight from the ERP (admin-configured documentTypeCode + houseTypeCode)
    const genOpts = arr(d.generateOptions);
    if (genOpts.length) bodyEl.appendChild(erpGenerateRow(job, genOpts));
  }).catch(() => { bodyEl.innerHTML = '<div class="empty">' + esc(tr('Could not reach the ERP for files.')) + '</div>'; });
  return wrap;
}
// Generate a document in the ERP from an admin-configured documentTypeCode + its related houseTypeCode(s). `options`
// = [{ documentTypeCode, houseTypes:[{houseTypeCode, invoiceRequired}] }]. Pick a document type -> the house-type
// dropdown cascades; an invoice-required type reveals an invoice-no field. On success the whole drawer refreshes so
// the ERP returns the generated PDF inline (it does NOT store it), so Generate streams it straight to a download.
function erpGenerateRow(job, options) {
  const row = el('div', 'erpupload erpgen');
  row.appendChild(el('div', 'erpupload-lbl', esc(tr('Generate a document from the ERP:'))));
  const line = el('div', 'erpupload-line');
  const docSel = el('select');
  options.forEach(o => { const op = el('option'); op.value = o.documentTypeCode; op.textContent = o.documentTypeCode; docSel.appendChild(op); });
  const houseSel = el('select');
  const inv = el('input'); inv.type = 'text'; inv.placeholder = tr('Invoice no.'); inv.style.cssText = 'width:120px;display:none';
  const btn = el('button', 'primary', tr('Generate')); btn.style.fontSize = '11px';
  const msg = el('span', 'mut'); msg.style.cssText = 'font-size:11px;margin-left:4px';
  const curOpt = () => options.find(o => o.documentTypeCode === docSel.value) || { houseTypes: [] };
  const curHouse = () => arr(curOpt().houseTypes).find(h => h.houseTypeCode === houseSel.value) || null;
  function fillHouses() {
    houseSel.innerHTML = '';
    const hs = arr(curOpt().houseTypes);
    if (!hs.length) { const op = el('option'); op.value = ''; op.textContent = tr('(no house type)'); houseSel.appendChild(op); }
    hs.forEach(h => { const op = el('option'); op.value = h.houseTypeCode; op.textContent = h.houseTypeCode || tr('(no house type)'); houseSel.appendChild(op); });
    toggleInvoice();
  }
  function toggleInvoice() { const h = curHouse(); inv.style.display = (h && h.invoiceRequired) ? '' : 'none'; if (inv.style.display === 'none') inv.value = ''; }
  docSel.onchange = fillHouses;
  houseSel.onchange = toggleInvoice;
  line.appendChild(docSel); line.appendChild(houseSel); line.appendChild(inv); line.appendChild(btn); line.appendChild(msg);
  row.appendChild(line);
  fillHouses();
  btn.onclick = async () => {
    const old = btn.textContent; btn.disabled = true; btn.textContent = tr('Generating…'); msg.textContent = '';
    try {
      const r = await fetch('/api-ops/erp-doc-generate', {
        method: 'POST', cache: 'no-store',
        headers: { 'Content-Type': 'application/json', 'X-Ops-User': state.user || '(open)' },
        body: JSON.stringify({ job: job, documentTypeCode: docSel.value, houseTypeCode: houseSel.value, invoiceNumber: inv.value.trim() })
      });
      const ctype = r.headers.get('content-type') || '';
      if (r.ok && ctype.indexOf('application/pdf') >= 0) {
        const blob = await r.blob();
        const cd = r.headers.get('content-disposition') || ''; const mm = cd.match(/filename="?([^"]+)"?/);
        const name = (mm && mm[1]) || (docSel.value + '.pdf');
        const url = URL.createObjectURL(blob); const a = el('a'); a.href = url; a.download = name;
        document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 4000);
        msg.textContent = tr('Generated') + ' · ' + name;
      } else {
        let j = {}; try { j = await r.json(); } catch (e) { }
        if (j.ok && j.mock) msg.textContent = tr('Generated') + ' [' + tr('mock') + ']';
        else msg.textContent = j.error || tr('generate failed');
      }
    } catch (e) { msg.textContent = tr('generate failed'); }
    btn.disabled = false; btn.textContent = old;
  };
  return row;
}
// Upload a document straight to the ERP. `doctypes` = the configured ERP Document Type codes (admin Documents tab);
// `clearable` = the subset that would also clear a milestone on this shipment. The file is base64'd in the browser
// and POSTed; nothing is stored locally. On success the whole drawer is refreshed so any cleared milestone light
// and the new file both show. If no doctypes are configured, a free-text field lets any ERP code still be sent.
function erpUploadRow(job, doctypes, clearable) {
  clearable = clearable || [];
  const row = el('div', 'erpupload');
  // legend goes in the caption (not the option text) so a clearable type reads e.g. "Booking*", not "Booking (clears alert)"
  const hasClearableInList = doctypes.some(dt => clearable.includes(dt));
  row.appendChild(el('div', 'erpupload-lbl', esc(tr('Upload a document to the ERP:')) +
    (hasClearableInList ? ' <span class="mut">' + esc(tr('* clears alert')) + '</span>' : '')));
  const line = el('div', 'erpupload-line');
  let getDoctype;
  if (doctypes.length) {
    const sel = el('select');
    doctypes.forEach(dt => { const o = el('option'); o.value = dt; o.textContent = dt + (clearable.includes(dt) ? '*' : ''); sel.appendChild(o); });
    line.appendChild(sel); getDoctype = () => sel.value;
  } else {
    const ti = el('input'); ti.type = 'text'; ti.placeholder = tr('ERP document type code'); ti.style.cssText = 'width:150px';
    line.appendChild(ti); getDoctype = () => ti.value.trim();
  }
  const file = el('input'); file.type = 'file'; file.accept = '.pdf,.png,.jpg,.jpeg';
  const btn = el('button', 'primary', tr('Upload')); btn.style.fontSize = '11px';
  const msg = el('span', 'mut'); msg.style.cssText = 'font-size:11px;margin-left:4px';
  line.appendChild(file); line.appendChild(btn); line.appendChild(msg);
  row.appendChild(line);
  btn.onclick = async () => {
    const dt = getDoctype();
    if (!dt) { msg.textContent = tr('choose a document type'); return; }
    const f = file.files && file.files[0];
    if (!f) { msg.textContent = tr('choose a file first'); return; }
    if (f.size > 5 * 1024 * 1024) { msg.textContent = tr('file too large (max 5 MB)'); return; }
    if (!['application/pdf', 'image/png', 'image/jpeg'].includes(f.type)) { msg.textContent = tr('PDF, PNG or JPEG only'); return; }
    const old = btn.textContent; btn.disabled = true; btn.textContent = tr('Uploading…'); msg.textContent = '';
    try {
      const base64 = await new Promise((res, rej) => {
        const rd = new FileReader();
        rd.onload = () => res(('' + rd.result).split(',')[1] || '');
        rd.onerror = rej;
        rd.readAsDataURL(f);
      });
      const r = await api('/api-ops/erp-file-upload', { method: 'POST', body: { job: job, doctype: dt, fileName: f.name, content_type: f.type, base64: base64 } });
      if (r.error) { msg.textContent = r.error; btn.disabled = false; btn.textContent = old; return; }
      const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data); loadWorklist();
    } catch (e) { msg.textContent = tr('upload failed'); btn.disabled = false; btn.textContent = old; }
  };
  return row;
}
// Fetch the file bytes through the authed fetch (carries the cookie / X-Ops-User header in either mode), then
// trigger a browser download with the right filename. Avoids relying on cookie presence for a plain link.
async function downloadErpFile(job, fileName, btn) {
  const old = btn.textContent; btn.disabled = true; btn.textContent = '…';
  try {
    const r = await fetch('/api-ops/erp-file-download?job=' + encodeURIComponent(job) + '&file=' + encodeURIComponent(fileName),
      { cache: 'no-store', headers: { 'X-Ops-User': state.user || '(open)' } });
    if (!r.ok) { btn.textContent = tr('unavailable'); setTimeout(() => { btn.textContent = old; btn.disabled = false; }, 2500); return; }
    const blob = await r.blob();
    const url = URL.createObjectURL(blob);
    const a = el('a'); a.href = url; a.download = fileName || 'erp-file';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    btn.textContent = old; btn.disabled = false;
  } catch (e) { btn.textContent = tr('failed'); setTimeout(() => { btn.textContent = old; btn.disabled = false; }, 2500); }
}

async function remindMe(job) {
  const r = await askReminder();
  if (!r) return;
  await api('/api-ops/notes', { method: 'POST', body: { job_no: job, kind: 'reminder', note: r.note, remind_on: r.date, mentions: [] } });
  const d = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, d); loadTasks();
}
async function promptBypass(job, code, name) {
  const reason = await askText({
    title: tr('Mark complete') + ' · ' + code + ' ' + tr(name || ''),
    message: tr('Confirm this step is done. Add a short note if you like (e.g. filed via portal, hard-copy received).'),
    placeholder: tr('Note (optional)'),
    okLabel: tr('✓ Confirm done')
  });
  if (reason === null) return;   // cancelled
  await closeMilestone(job, code, true, reason);
}
async function closeMilestone(job, code, done, reason) {
  await api('/api-ops/milestone-close', { method: 'POST', body: { job_no: job, milestone_code: code, done: done, reason: reason } });
  const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data);
  loadWorklist();
}

// ---------- note composer with @-mention ----------
function composer(job, prefill) {
  const c = el('div', 'composer');
  const ta = el('textarea'); ta.placeholder = tr('Add a note… use @ to remind a colleague'); if (prefill) ta.value = prefill;
  const pop = el('div', 'mention-pop');
  const bar = el('div'); bar.style.cssText = 'display:flex;gap:8px;margin-top:6px;align-items:center';
  const send = el('button', 'primary', tr('Post note'));
  const hint = el('span', 'muted', ''); hint.style.fontSize = '11.5px';
  bar.appendChild(send); bar.appendChild(hint);
  c.appendChild(ta); c.appendChild(pop); c.appendChild(bar);
  wireMention(ta, pop);
  send.onclick = async () => {
    const text = ta.value.trim(); if (!text) return;
    const mentions = extractMentions(ta);
    send.disabled = true;
    await api('/api-ops/notes', { method: 'POST', body: { job_no: job, note: text, mentions } });
    send.disabled = false; ta.value = '';
    const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data);
    loadTasks(); loadWorklist();
  };
  return c;
}
// Resolve mentions from a textarea/input (or a raw string). The picker inserts the colleague's DISPLAY NAME as the
// visible @token (so an email-style username never shows), but records the real username on the element. We return the
// recorded usernames whose token is still present, plus any @display-name / @username typed by hand — so deleting the
// text removes the mention and a manual mention still resolves.
function mentionPresent(text, label) {
  if (!label) return false; const at = '@' + label;
  return text.includes(at + ' ') || text.includes(at + '\n') || text.includes(at + '\t') || text.endsWith(at);
}
function extractMentions(elOrText) {
  const isEl = elOrText && typeof elOrText === 'object';
  const text = isEl ? (elOrText.value || '') : (elOrText || '');
  const set = new Set();
  const tracked = (isEl && elOrText._mentions) ? [...elOrText._mentions] : [];
  tracked.forEach(u => { if (mentionPresent(text, findNameOf(u)) || mentionPresent(text, u)) set.add(u); });
  // fallback: a colleague typed by display name or username without using the picker
  state.roster.forEach(u => { if (mentionPresent(text, findNameOf(u)) || mentionPresent(text, u)) set.add(u); });
  return [...set];
}
function wireMention(ta, pop) {
  let active = -1, items = [];
  const close = () => { pop.style.display = 'none'; active = -1; };
  ta.addEventListener('input', () => {
    const v = ta.value.slice(0, ta.selectionStart); const mt = v.match(/@([A-Za-z0-9_.\-]*)$/);
    if (!mt) return close();
    const q = mt[1].toLowerCase();
    const meta = state.rosterMeta || {};
    // match on real name, username/email, team OR station — so "@HKG" or "@sales" narrows the ~500-user list
    items = state.roster.filter(u => {
      const m = meta[u] || {};
      return (m.name || '').toLowerCase().includes(q) || u.toLowerCase().includes(q) ||
        (m.email || '').toLowerCase().includes(q) ||
        (m.team || '').toLowerCase().includes(q) || (m.station || '').toLowerCase().includes(q);
    }).slice(0, 8);
    if (!items.length) return close();
    pop.innerHTML = ''; items.forEach((u, i) => {
      const m = meta[u] || {};
      const name = m.name || u;
      const ident = (m.email || u);                       // show the email/username as the muted secondary line
      const sub = [ident !== name ? ident : '', m.team, m.station].filter(Boolean).join(' · ');
      const d = el('div', i === 0 ? 'sel' : '');
      d.innerHTML = '<span class="mname">@' + esc(name) + '</span>' +
        (sub ? ' <span class="mmeta">' + esc(sub) + '</span>' : '');
      d.onclick = () => pick(u); pop.appendChild(d);
    });
    active = 0; pop.style.display = 'block';
  });
  ta.addEventListener('keydown', e => {
    if (pop.style.display !== 'block') return;
    if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(active + 1, items.length - 1); hi(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(active - 1, 0); hi(); }
    else if (e.key === 'Enter') { e.preventDefault(); pick(items[active]); }
    else if (e.key === 'Escape') close();
  });
  function hi() { [...pop.children].forEach((d, i) => d.className = i === active ? 'sel' : ''); }
  function pick(u) {
    const label = findNameOf(u) || u;                     // insert the display name, not the username/email
    const s = ta.selectionStart; const before = ta.value.slice(0, s).replace(/@([^@]*)$/, '@' + label + ' ');
    ta.value = before + ta.value.slice(s);
    (ta._mentions || (ta._mentions = new Set())).add(u);  // remember who this @token resolves to
    ta.focus(); close();
  }
}
function noteItem(n) {
  const d = el('div', 'noteitem');
  const ment = arr(n.mentions).map(m => '<span class="mtag" title="' + esc(m) + '">@' + esc(findNameOf(m)) + '</span>').join(' ');
  const kindTag = (n.kind && n.kind !== 'note') ? '<span class="kind ' + esc(n.kind) + '">' + esc(tr(n.kind)) + '</span> ' : '';
  const done = n.status === 'done';
  d.innerHTML = '<div class="who">' + kindTag + '<strong>' + esc(n.user) + '</strong> · ' + esc((n.created || '').slice(0, 16).replace('T', ' ')) +
    (done ? ' · <span class="muted">✔ ' + esc(tr('ack by')) + ' ' + esc(n.doneBy) + '</span>' : '') + '</div>' +
    '<div>' + esc(n.note) + ' ' + ment + '</div>';
  if (!done) {
    const b = el('button', 'tick ghost', tr('✓ Acknowledge')); b.style.marginTop = '6px'; b.style.fontSize = '12px';
    b.onclick = async () => { await api('/api-ops/note-done', { method: 'POST', body: { id: n.id, done: true } }); loadTasks(); const job = n.job_no; const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data); };
    d.appendChild(b);
  }
  return d;
}

// ---------- My Tasks ----------
async function loadTasks() {
  const data = await api('/api-ops/my-tasks');
  const assigned = arr(data.assigned), mine = arr(data.mine), drafts = arr(data.drafts), today = data.today || '';
  const n = (data.assignedOpen || assigned.length) + (data.dueNow || 0) + (data.draftCount || drafts.length);   // from others + my due/overdue + draft reviews
  ['#taskBadge', '#taskBadge2'].forEach(s => { const b = $(s); if (n > 0) { b.textContent = n; b.style.display = ''; } else b.style.display = 'none'; });
  const body = $('#tasksBody'); body.innerHTML = '';
  if (drafts.length) {   // customer-acted drafts awaiting you — most actionable, shown first
    body.appendChild(el('div', 'muted', tr('📄 Draft reviews')));
    drafts.forEach(dr => body.appendChild(draftCard(dr)));
    const h0 = el('div', 'muted', tr('🔔 Reminders from others')); h0.style.marginTop = '10px'; body.appendChild(h0);
  } else body.appendChild(el('div', 'muted', tr('🔔 Reminders from others')));
  if (!assigned.length) body.appendChild(el('div', 'empty', tr('Nothing waiting on you.')));
  assigned.forEach(t => body.appendChild(taskCard(t, true, today)));
  const h = el('div', 'muted', tr('📌 My follow-ups')); h.style.marginTop = '10px'; body.appendChild(h);
  if (!mine.length) body.appendChild(el('div', 'empty', tr('No reminders set. Open a shipment → 🔔 Remind me.')));
  mine.forEach(t => body.appendChild(taskCard(t, false, today)));
}
function draftCard(dr) {
  const d = el('div', 'task');
  const who = dr.consignee || dr.customerName || dr.jobNo;
  const approved = dr.status === 'CUSTOMER_APPROVED';
  const label = approved ? tr('✅ approved · ready to agree') : tr('✏️ customer replied');
  d.innerHTML =
    '<div class="tk-head"><span class="kind">📄 ' + esc(dr.docType) + '</span> <strong>' + esc(who) + '</strong> <span class="due now">' + label + '</span></div>' +
    '<div class="tk-sub mut">' + esc(dr.jobNo) + ' · v' + esc('' + dr.version) + (dr.updatedAt ? ' · ' + esc(dr.updatedAt) : '') + '</div>' +
    (dr.comment ? '<div class="tk-note">💬 ' + esc(dr.comment) + '</div>' : '');
  d.onclick = () => openShipment(dr.jobNo);   // open the shipment → its 📄 Draft review panel
  return d;
}
function taskCard(t, fromOthers, today) {
  const d = el('div', 'task');
  const who = t.consignee || t.job_no;
  let due = '';
  if (t.remindOn) {
    const cls = (today && t.remindOn < today) ? ' over' : (today && t.remindOn === today ? ' now' : '');
    const lbl = cls === ' over' ? ' · ' + tr('overdue') : (cls === ' now' ? ' · ' + tr('today') : '');
    due = '<span class="due' + cls + '">🔔 ' + esc(t.remindOn) + lbl + '</span>';
  }
  // a Book Now confirmation (kind 'booking') is informational - it has no worklist shipment, so it does NOT open the
  // drawer / Edit-ERP (that would 'die' on a job that isn't in shipment_alerts). Show it with a tag, tick-done only.
  const isBooking = t.kind === 'booking';
  const kindTag = isBooking ? '<span class="kind">' + esc(tr('booking')) + '</span> '
    : (t.arrType ? '<span class="kind">' + esc(tr(t.arrType)) + '</span> ' : '');
  const ctx = [t.cargo, t.vesselVoyage, t.lane].filter(Boolean).map(esc).join(' · ');
  d.innerHTML =
    '<button class="tk-done" title="' + esc(tr('Mark done')) + '">✓</button>' +
    '<div class="tk-head">' + kindTag + '<strong>' + esc(who) + '</strong>' + due + '</div>' +
    '<div class="tk-sub mut">' + esc(t.job_no) + (fromOthers ? ' · ' + esc(tr('from')) + ' ' + esc(t.user) : '') + (ctx ? ' · ' + ctx : '') + '</div>' +
    '<div class="tk-note">' + esc(t.note) + '</div>';
  // a booking note opens the EDITABLE shipment by resolving its booking number; a normal task opens its shipment.
  if (isBooking) d.onclick = () => openBookingNote(t.job_no);
  else d.onclick = () => openShipment(t.job_no);   // whole card opens the shipment
  d.querySelector('.tk-done').onclick = async e => { e.stopPropagation(); await api('/api-ops/note-done', { method: 'POST', body: { id: t.id, done: true } }); loadTasks(); };
  return d;
}

/* ============================================================================
   Natural-language Find — rule-based parser (no LLM). Adapted from erp-quotation's parseCustomerQuery:
   subtract the known clues (date / mode / bound / identifiers / lane / note author+body+mention / "who"),
   the significant leftover is the company/contact. Everything shows in an editable "Looking for:" summary so a
   misparse is corrected, not silently wrong. An LLM fallback is a documented future seam (Part 4) — not wired.
   ============================================================================ */
// drop noise words but KEEP unknown words (a place name or a commodity) so the server LIKE can try them.
var OPS_PLACE_NOISE = /\b(by|air|airfreight|sea|seafreight|ocean|oceanfreight|freight|fcl|lcl|vessel|liner|carrier|flight|booking|bookings|shipment|shipments|file|files|job|jobs|cargo|container|containers|please|pls|thanks|thank|you|find|me|get|got|want|need|needed|looking|look|check|show|ship|shipped|shipping|send|sent|only|just|with|via|on|the|some|for|of|to|from|that|this|about|customs|cleared|ready|arrived|arriving|delivered|pickup)\b/gi;
function opsStripNoise(s) { var x = ' ' + ('' + s).toLowerCase() + ' '; x = x.replace(/[?.,;!]/g, ' '); x = x.replace(OPS_PLACE_NOISE, ' '); return x.replace(/\s+/g, ' ').trim(); }
// command / grammar / ops-vocabulary stop-words: whatever survives is the company/contact name.
var OPS_FIND_STOP = /\b(find|search|show|tell|give|get|got|list|fetch|pull|look|looking|lookup|locate|check|want|wanted|need|needed|see|view|just|only|kindly|what|whats|who|whose|which|when|where|me|us|my|mine|our|own|team|teams|the|a|an|any|all|recent|recently|latest|last|new|old|message|messages|note|notes|msg|chat|activity|activities|history|anything|everything|something|about|re|regarding|saying|says|said|with|for|to|from|of|on|by|at|in|and|or|please|pls|do|does|did|you|know|i|we|remember|recall|forgot|forget|forgotten|help|that|this|these|those|has|have|had|is|was|are|were|been|be|prepared|made|create|created|raise|raised|handle|handled|arrange|arranged|arranging|contact|contacted|contacting|update|updated|name|air|sea|ocean|freight|fcl|lcl|vessel|liner|flight|booking|bookings|shipment|shipments|shipped|shipping|ship|file|files|job|jobs|cargo|but|anyone|everyone|everybody|customer|client|account|consignee|shipper|agent|carrier|today|yesterday|week|weeks|month|months|day|days|year|years|ago|few|couple|previous|since|import|imports|export|exports|inbound|outbound|customs|cleared|clearance|ready|arrived|arriving|delivered|delivery|pickup|hbl|hawb|house|mbl|mawb|master|container|containers|po|so|sono|id|number|no|ref)\b/gi;
// relative date phrases -> {from,to,label}. Ported verbatim from erp-quotation (Monday-based ISO weeks).
function parseDateWindow(text) {
  var t = (' ' + ('' + (text || '')).toLowerCase() + ' ');
  var now = new Date();
  function z(n) { return (n < 10 ? '0' : '') + n; }
  function iso(d) { return d.getFullYear() + '-' + z(d.getMonth() + 1) + '-' + z(d.getDate()); }
  function addDays(d, n) { var x = new Date(d); x.setDate(x.getDate() + n); return x; }
  function startOfWeek(d) { var x = new Date(d); x.setDate(x.getDate() - ((x.getDay() + 6) % 7)); return x; }
  var m;
  if (m = t.match(/\b(?:last|past|previous|recent)\s+(\d+)\s+(day|days|week|weeks|month|months)\b/)) {
    var n = +m[1], u = m[2], days = u.indexOf('day') === 0 ? n : u.indexOf('week') === 0 ? n * 7 : n * 30;
    return { from: iso(addDays(now, -days)), to: iso(now), label: 'last ' + n + ' ' + u.replace(/s$/, '') + (n > 1 ? 's' : '') };
  }
  if (/\btoday\b/.test(t)) return { from: iso(now), to: iso(now), label: 'today' };
  if (/\byesterday\b/.test(t)) { var y = addDays(now, -1); return { from: iso(y), to: iso(y), label: 'yesterday' }; }
  if (/\bthis week\b/.test(t)) return { from: iso(startOfWeek(now)), to: iso(now), label: 'this week' };
  if (/\b(?:last|past|previous) week\b/.test(t)) { var sow = startOfWeek(now); return { from: iso(addDays(sow, -7)), to: iso(addDays(sow, -1)), label: 'last week' }; }
  if (/\bthis month\b/.test(t)) return { from: iso(new Date(now.getFullYear(), now.getMonth(), 1)), to: iso(now), label: 'this month' };
  if (/\b(?:last|past|previous) month\b/.test(t)) { var ft = new Date(now.getFullYear(), now.getMonth(), 1), lme = addDays(ft, -1); return { from: iso(new Date(lme.getFullYear(), lme.getMonth(), 1)), to: iso(lme), label: 'last month' }; }
  if (/\bthis year\b/.test(t)) return { from: iso(new Date(now.getFullYear(), 0, 1)), to: iso(now), label: 'this year' };
  if (/\b(?:last|past|previous) year\b/.test(t)) return { from: iso(new Date(now.getFullYear() - 1, 0, 1)), to: iso(new Date(now.getFullYear() - 1, 11, 31)), label: 'last year' };
  if (/\b(?:last|past)\s+(?:few|couple of?)\s+(?:days|weeks)\b/.test(t)) return { from: iso(addDays(now, -7)), to: iso(now), label: 'last few days' };
  return null;
}
function parseOpsQuery(text) {
  var raw = ('' + (text || '')).replace(/\s+/g, ' ').trim();
  var work = ' ' + raw.replace(/\s*(->|→|—>|-->)\s*/g, ' to ') + ' ';
  var out = { who: '', pol: '', pod: '', commodity: '', mode: '', bound: '', ref: '', refField: '', noteAuthor: '', noteText: '', tome: false, mine: true, from: '', to: '', dateLabel: '' };
  var dw = parseDateWindow(raw); if (dw) { out.from = dw.from; out.to = dw.to; out.dateLabel = dw.label; }
  if (/\bby air\b|\bair\s?freight\b|\bairfreight\b|\bawb\b|\bmawb\b|\bhawb\b|\bflight\b|\bflew\b|\bair\b/i.test(work)) out.mode = 'Air';
  else if (/\bby sea\b|\bsea\s?freight\b|\bocean\b|\bfcl\b|\blcl\b|\bvessel\b|\bsea\b/i.test(work)) out.mode = 'Sea';
  if (/\bimport\b|\binbound\b|\bincoming\b|\barriv\w*\b/i.test(work)) out.bound = 'Import';
  else if (/\bexport\b|\boutbound\b|\boutgoing\b/i.test(work)) out.bound = 'Export';
  // ownership: default to "mine" (the shipment an operator wants is one they handle/are mentioned in); widen on "anyone".
  if (/\banyone\b|\beveryone\b|\beverybody\b|\bany (?:operator|one|user|colleague)\b|\ball (?:shipments|files|jobs|operators?)\b|\bentire (?:team|office)\b|\bwhole (?:team|office)\b/i.test(work)) out.mine = false;
  // explicit identifier (field + value). "forgot the booking number" sets no value -> ref stays empty (other clues drive it).
  var idm;
  if (idm = work.match(/\b(?:booking|bkg|so|sono)\s*#?\s*([a-z0-9][a-z0-9\-\/]{2,})\b/i)) { out.ref = idm[1]; out.refField = 'booking'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:po|p\/o|order)\s*#?\s*([a-z0-9][a-z0-9\-\/]{2,})\b/i)) { out.ref = idm[1]; out.refField = 'po'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:hbl|hawb|house\s*(?:bill|b\/l|bl|awb)?)\s*#?\s*([a-z0-9][a-z0-9\-\/]{3,})\b/i)) { out.ref = idm[1]; out.refField = 'house'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:mbl|mawb|master\s*(?:bill|b\/l|bl|awb)?)\s*#?\s*([a-z0-9][a-z0-9\-\/]{3,})\b/i)) { out.ref = idm[1]; out.refField = 'master'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:ship-?\s?id|shipid|spot-?\s?id|spotid|spot)\s*#?\s*([a-z0-9][a-z0-9\-\/:_]{1,})\b/i)) { out.ref = idm[1]; out.refField = 'shipid'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:vessel|vsl|m\/?v|voyage)\s+(?:(?:named?|called|under|is|name\s+of)\s+)?#?\s*([a-z0-9][\w\-\/]*(?:\s+(?!to\b|from\b|about\b|last\b|this\b|please\b)[a-z0-9][\w\-\/]*){0,3})/i)) { out.ref = idm[1].trim(); out.refField = 'conv'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b([A-Z]{4}\d{7})\b/)) { out.ref = idm[1]; out.refField = 'container'; work = work.replace(idm[0], ' '); }
  else if (idm = work.match(/\b(?:job|file)\s*(?:no\.?|number|#)?\s*([a-z]{2,}[a-z0-9\-]{3,})\b/i)) { out.ref = idm[1]; out.refField = 'job'; work = work.replace(idm[0], ' '); }
  // an explicit role word pins the company: "shipper ABC", "consignee X", "customer Y".
  var role = work.match(/\b(?:shipper|consignee|cnee|customer|client|account)\s+([a-z0-9][\w&.\- ]*?)(?=\s+(?:shipped|shipping|sent|ship|to|from|about|by|last|this|please|,|\?)|\s*$)/i);
  if (role) { var rw = role[1].replace(/[?.,;!]/g, ' ').replace(/\s+/g, ' ').trim(); if (rw) { out.who = rw; work = work.replace(role[0], ' '); } }
  // lane: "from X to Y"; else "from X" (origin only). Stop at a comma so a trailing commodity/date doesn't leak in.
  var lane = work.match(/\bfrom\s+([^,?]+?)\s+to\s+([^,?]+?)(?=\s+(?:about|re|regarding|with|for|by|last|this|please|\?)|,|\s*$)/i);
  if (lane) { out.pol = opsStripNoise(lane[1]); out.pod = opsStripNoise(lane[2]); work = work.replace(lane[0], ' '); }
  else { var only = work.match(/\bfrom\s+([^,?]+?)(?=\s+(?:about|re|regarding|with|for|by|last|this|please|\?)|,|\s*$)/i); if (only) { out.pol = opsStripNoise(only[1]); work = work.replace(only[0], ' '); } }
  // note clues: who it's to (me), who wrote it, what it says.
  if (/\b(?:to|told|sent\s+to|messaged|texted|emailed|dropped|pinged)\s+me\b|\bme\s+(?:about|regarding|a message|a note)\b|\bdropped me\b/i.test(work)) out.tome = true;
  var av = work.match(/\b([a-z][\w.'-]*)\s+(?:told|said|messaged|texted|emailed|wrote|mentioned|replied|sent|dropped|pinged|noted)\b/i);
  if (av) { OPS_FIND_STOP.lastIndex = 0; if (!OPS_FIND_STOP.test(' ' + av[1] + ' ')) { out.noteAuthor = av[1]; work = work.replace(av[0], ' '); } OPS_FIND_STOP.lastIndex = 0; }
  var noteCentric = !!(out.noteAuthor || out.tome);
  // "about/regarding/saying X" -> note body when note-centric, else the shipment commodity. Stop at a comma.
  var cm = work.match(/\b(?:about|re|regarding|saying|mentioning)\s+([^,?]+?)(?=\s+(?:from|to|with|for|by|last|this|please|\?)|,|\s*$)/i);
  if (cm) { OPS_FIND_STOP.lastIndex = 0; var capt = cm[1].replace(OPS_FIND_STOP, ' ').replace(/\s+/g, ' ').trim(); OPS_FIND_STOP.lastIndex = 0; if (noteCentric) out.noteText = capt; else out.commodity = capt; work = work.replace(cm[0], ' '); }
  // the significant leftover: a company/contact, or (short, when a lane is already set, or a bare token) a commodity.
  OPS_FIND_STOP.lastIndex = 0;
  var leftover = work.replace(/'s\b/gi, ' ').replace(/[?.,;!']/g, ' ').replace(OPS_FIND_STOP, ' ').replace(/\s+/g, ' ').trim();
  OPS_FIND_STOP.lastIndex = 0;
  if (leftover) {
    var words = leftover.split(' ').length;
    // a single bare token that looks like a reference number (has digits) -> identifier search across all id
    // columns (booking/bill/container/PO/ship-id/flight), bypassing the "mine" lens, so pasting a number finds it.
    if (!out.ref && words === 1 && /^[A-Za-z0-9][A-Za-z0-9\-\/]{4,}$/.test(leftover) && /\d/.test(leftover)) { out.ref = leftover; out.refField = ''; }
    else if (!out.who && !((out.pol || out.pod) && words <= 2)) out.who = leftover;
    else if (!out.commodity) out.commodity = leftover;
    else if (!out.who) out.who = leftover;
  }
  if (out.ref) out.mine = false;   // an explicit identifier finds any file (matches the server bypassing the lens)
  return out;
}
// clue object (from parseOpsQuery OR the LLM fallback — same shape) -> /api-ops/find query params.
function opsFindParams(p) {
  var params = {};
  if (p.who) params.who = p.who;
  if (p.pol) params.pol = p.pol;
  if (p.pod) params.pod = p.pod;
  if (p.commodity) params.commodity = p.commodity;
  if (p.mode) params.mode = p.mode;
  if (p.bound) params.bound = p.bound;
  if (p.ref) { params.ref = p.ref; params.refField = p.refField; }
  if (p.noteAuthor) params.noteauthor = p.noteAuthor;
  if (p.noteText) params.notetext = p.noteText;
  if (p.tome) params.tome = 1;
  if (p.mine) params.mine = 1;
  if (p.from) params.from = p.from;
  if (p.to) params.to = p.to;
  return params;
}
// editable "Looking for:" summary — fix any clue by editing the box; it re-runs. `aiNote` flags an AI-assisted parse.
function opsFindSummary(p, aiNote) {
  var bits = [];
  bits.push(p.mine ? '<b>' + esc(tr('mine only')) + '</b>' : "<span class='muted'>" + esc(tr('anyone')) + '</span>');
  if (p.who) bits.push('<b>' + esc(p.who) + '</b>');
  if (p.noteAuthor) bits.push('💬 ' + esc(tr('from')) + ' <b>' + esc(p.noteAuthor) + '</b>');
  if (p.tome) bits.push('💬 ' + esc(tr('to me')));
  if (p.noteText) bits.push('💬 “' + esc(p.noteText) + '”');
  if (p.pol || p.pod) bits.push(esc(p.pol || '…') + ' → ' + esc(p.pod || '…'));
  if (p.commodity) bits.push(esc(tr('commodity')) + ': ' + esc(p.commodity));
  if (p.ref) { var rfL = { conv: 'vessel', vessel: 'vessel', shipid: 'Ship ID', booking: 'booking', po: 'PO / Ref', house: 'HBL', master: 'MBL', container: 'container', liner: 'liner SO', job: 'job' }; bits.push(esc(rfL[p.refField] || p.refField || 'ref') + ' ' + esc(p.ref)); }
  if (p.bound) bits.push(esc(p.bound));
  bits.push(p.mode ? esc(p.mode) : "<span class='muted'>" + esc(tr('Air + Sea')) + '</span>');
  if (p.dateLabel) bits.push('📅 ' + esc(p.dateLabel));
  return (aiNote ? '✨ ' + esc(tr('AI-assisted')) + ' · ' : '') + esc(tr('Looking for:')) + ' ' + bits.join(' · ');
}
// Append a chat bubble to the Find transcript and scroll it into view. Returns the element so an async
// answer can fill it in once results arrive. cls: '' (Find answer) | 'me' (the operator) | 'sys' (error).
function findBubble(cls, html) {
  var feed = $('#findFeed'); if (!feed) return null;
  var d = document.createElement('div'); d.className = 'find-msg' + (cls ? ' ' + cls : ''); d.innerHTML = html;
  feed.appendChild(d); feed.scrollTop = feed.scrollHeight; return d;
}
// Each Send is an independent, fresh search: post the operator's words as a 'me' bubble, then a pending Find
// bubble that gets filled with the parsed summary + result cards (or an LLM-assisted retry / an error).
async function runOpsFind() {
  var box = $('#findText'); var text = box ? ('' + box.value).trim() : '';
  if (!text) return;
  findBubble('me', "<div class='find-meta'>" + esc(tr('you')) + '</div>' + esc(text));
  if (box) box.value = '';
  var p = parseOpsQuery(text);
  var pend = findBubble('', "<div class='find-meta'>" + esc(tr('Find')) + '</div>' + "<div class='find-sum'>" + opsFindSummary(p, false) + '</div>' + "<div class='muted sm'>" + esc(tr('Searching…')) + '</div>');
  try {
    var res = await api('/api-ops/find?' + new URLSearchParams(opsFindParams(p)).toString());
    var items = arr(res.items);
    // Optional LLM fallback (Part 4): only when the rule parse found nothing. Inert unless enabled server-side
    // (the endpoint returns 501) — the original summary stays visible; the LLM only re-suggests clues.
    if (!items.length && await opsFindLlmFallback(text, pend)) return;
    fillFindAnswer(pend, opsFindSummary(p, false), items);
  } catch (e) {
    if (pend) { pend.className = 'find-msg sys'; pend.innerHTML = "<div class='find-meta'>" + esc(tr('Find')) + '</div>' + esc(tr('Search failed')) + ': ' + esc((e && e.message) || e); }
  }
}
// Ask the (flag-gated) LLM to re-interpret the text, then re-run Find with its clues, filling the pending
// bubble. Returns true if it rendered results. Fails silently (false) when disabled (501) or on error.
async function opsFindLlmFallback(text, pend) {
  try {
    var r = await api('/api-ops/parse-find', { method: 'POST', body: { text: text } });
    if (!r || !r.clue) return false;
    var c = r.clue;
    var res = await api('/api-ops/find?' + new URLSearchParams(opsFindParams(c)).toString());
    var items = arr(res.items);
    if (!items.length) return false;
    fillFindAnswer(pend, opsFindSummary(c, true), items);
    return true;
  } catch (e) { return false; }
}
function findNameOf(u) { var m = state.rosterMeta && state.rosterMeta[u]; return (m && m.name) || u || ''; }
// Find shipment card — mirrors the worklist mini-card (incoterm, cargo, ship-id, booking, dates, parties) so the
// operator has enough to pick the right file. Reuses cargoProfile / compName / arrivalChip; data from /api-ops/find.
function findShipRow(it) {
  var isImport = (it.bound || 'Import') === 'Import';
  var isAir = it.mode === 'Air';
  var who = (it.ctrlCode ? compName(it.ctrlCode) : '') || (isImport ? (it.consigneeName || it.custCode) : (it.shipperName || it.custCode));
  var cargo = cargoProfile(it);   // already escaped
  var diff = it.containerNo
    ? tr('ctr') + ' ' + esc(it.containerNo) + (it.containerCount > 1 ? ' +' + (it.containerCount - 1) : '')
    : (it.linerSo ? tr('SO') + ' ' + esc(it.linerSo) : '');
  var commod = it.commodity ? '<span title="' + esc(it.commodity) + '">' + esc(it.commodity.length > 28 ? it.commodity.slice(0, 28) + '…' : it.commodity) + '</span>' : '';
  var po = it.custRef ? (isAir ? 'PO ' : tr('ship-id') + ' ') + esc(it.custRef) : '';
  var bkg = (it.sono && it.sono !== it.humanId) ? tr('bkg') + ' ' + esc(it.sono) : '';
  var otherBill = (isImport && it.masterBill) ? ((isAir ? 'MAWB' : 'MBL') + ' ' + esc(it.masterBill)) : '';
  var dates = []; if (it.etd) dates.push('ETD ' + esc(it.etd)); if (it.eta) dates.push('ETA ' + esc(it.eta)); if (it.ata) dates.push('ATA ' + esc(it.ata));
  var jobTag = (it.erpJobNo && it.erpJobNo !== it.humanId) ? tr('job') + ' ' + esc(it.erpJobNo) : '';
  var lane = esc(it.routeSummary || it.lane || '');
  var sub = [diff, cargo, commod, po, bkg, otherBill, dates.join(' · '), lane, jobTag].filter(Boolean).join('  ·  ');
  var mkPty = function (lbl, nm, code) { var v = nm || (code ? compName(code) : ''); return v ? '<span class="pty">' + tr(lbl) + ' ' + esc(v) + '</span>' : ''; };
  var pty = [mkPty('shpr', it.shipperName, it.shipperCode), mkPty('cgne', it.consigneeName, it.consigneeCode), mkPty('agnt', '', it.agentCode)].filter(Boolean).join('  ·  ');
  var inco = it.incoterm ? '<span class="minco" title="' + esc(tr('Incoterm — your delivery responsibility')) + '">' + esc(it.incoterm) + '</span>' : '';
  var status = arrivalChip(it);
  var meta = [it.mode, it.bound].filter(Boolean).join('/');
  var closed = (it.jobStatus && it.jobStatus !== 'active') ? " <span class='badge cl'>" + esc(it.jobStatus) + '</span>' : '';
  var note = it.hasNote ? ' <span class="note-ind" title="' + esc(tr('has a remark / note')) + '">💬</span>' : '';
  return "<div class='find-row' data-job='" + esc(it.jobNo) + "' data-label='" + esc(it.humanId) + "'>" +
    "<div class='find-h'><span class='dot " + esc(it.worst || 'G') + "'></span> <b>" + esc(it.humanId) + '</b> ' + inco +
      " <span class='mwho'>" + esc(who || '') + '</span>' + note +
      " <span class='muted sm'>" + esc(meta) + '</span> ' + status + closed + '</div>' +
    (sub ? "<div class='muted sm'>" + sub + '</div>' : '') +
    (pty ? "<div class='muted sm pty-row'>" + pty + '</div>' : '') +
    '</div>';
}
// Render one Find result (shipment card or note) — shared by every answer bubble.
function renderFindItem(it) {
  if (it.type === 'note') {
    var who = findNameOf(it.author);
    var ctx = [it.lane, it.consigneeName || it.shipperName].filter(Boolean).join(' · ');
    return "<div class='find-row' data-job='" + esc(it.jobNo) + "' data-label='" + esc(it.humanId) + "'>" +
      "<div class='find-h'><span class='badge nb'>💬 " + esc(tr('note')) + '</span> <b>' + esc(who) + "</b> <span class='muted sm'>" + esc(('' + (it.created || '')).slice(0, 10)) + '</span></div>' +
      '<div>' + esc(('' + (it.note || '')).slice(0, 160)) + '</div>' +
      "<div class='muted sm'>" + esc(it.humanId) + (ctx ? ' · ' + esc(ctx) : '') + '</div></div>';
  }
  return findShipRow(it);
}
// Fill a pending Find answer bubble with the parsed summary line + the result cards (or a no-match hint),
// then wire each card to deep-link into the drawer. summaryHtml comes from opsFindSummary (already escaped).
function fillFindAnswer(pend, summaryHtml, items) {
  if (!pend) return;
  var head = "<div class='find-meta'>" + esc(tr('Find')) + ' · ' + items.length + ' ' + esc(tr('result(s)')) + '</div>';
  var body = items.length
    ? items.map(renderFindItem).join('')
    : "<div class='empty'>" + esc(tr('Nothing matched — try fewer words, a different name, or turn off “mine only” (say “anyone”).')) + '</div>';
  pend.innerHTML = head + "<div class='find-sum'>" + summaryHtml + '</div>' + body;
  pend.querySelectorAll('.find-row').forEach(function (row) { row.onclick = function () { closeFind(); openShipment(row.dataset.job, row.dataset.label); }; });
  var feed = $('#findFeed'); if (feed) feed.scrollTop = feed.scrollHeight;
}

linkBoot().then(init);
