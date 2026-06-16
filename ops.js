// Control Tower client. Vanilla JS, no build step. Mirrors the dashboard's robustness patterns:
// arr() coercion (PS 5.1 ConvertTo-Json mangles 0/1-row arrays), cache:'no-store', X-Ops-User identity.
'use strict';
const $ = s => document.querySelector(s);
const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
const esc = s => ('' + (s ?? '')).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);   // coerce PS single/empty -> array
const isYmd = s => !s || /^\d{4}-\d{2}-\d{2}$/.test(('' + s).trim());   // house date standard: yyyy-mm-dd only

const state = { user: localStorage.getItem('opsUser') || '', roster: [], lens: 'mine', teammate: '', bound: localStorage.getItem('opsBound') || 'Import', tmode: localStorage.getItem('opsMode') || 'Sea',
  from: '', to: '', company: '', searchField: 'company', ref: '', alertsOnly: false, notesOnly: false, pols: [], pods: [], station: localStorage.getItem('opsStation') || '', _companies: [], _portDim: [], _activePorts: { pol: [], pod: [] }, _stations: [],
  ib: { origin: '', party: '', q: '', pols: [], pods: [] } };   // inbound (pre-arrival) panel search
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
  try { const c = await api('/api-ops/config'); $('#appName').textContent = c.appName || 'Control Tower'; $('#appSub').textContent = c.appSubtitle || ''; document.title = c.appName || 'Control Tower'; state._stations = arr(c.stations); } catch (e) {}
  if (ME.authOn) {
    state.user = ME.username;                          // session identity replaces the demo picker
    $('#userPicker').style.display = 'none'; const ol = $('#opLabel'); if (ol) ol.style.display = 'none';
    const ub = $('#userbar');
    if (ub) {
      ub.innerHTML = '<b>' + esc(ME.displayName || ME.username) + '</b> · ' + esc(ME.role || '') +
        (ME.admin ? ' · <a href="admin-ops.html" style="color:var(--accent)">Admin</a>' : '') +
        ' · <a href="#" id="signOut" style="color:var(--accent)">Sign out</a>';
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
  // username -> { name, team, station } so the @-mention picker can label colleagues (matters at ~500 users)
  state.rosterMeta = {}; ru.forEach(u => { state.rosterMeta[u.username] = { name: u.displayName || u.username, team: u.team || '', station: u.station || '' }; });
  if (!state.user && state.roster.length) state.user = state.roster[0];
  buildUserPicker(); buildTeammate();
  wireLens(); wireBound(); wireMode(); wireFilters(); wireTheme();
  applyAccessGating();
  await loadFilters();
  $('#refreshBtn').onclick = refreshAll;
  $('#collapseAll').onclick = () => {
    allCollapsed = !allCollapsed;
    document.querySelectorAll('.vgroup').forEach(g => g.classList.toggle('collapsed', allCollapsed));
    $('#collapseAll').textContent = allCollapsed ? '⊕ Expand all' : '⊖ Collapse all';
  };
  $('#tasksBtn').onclick = () => $('#tasksPanel').scrollIntoView({ behavior: 'smooth' });
  $('#closeDrawer').onclick = closeDrawer; $('#drawerBg').onclick = closeDrawer;
  refreshAll();
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
  sel.innerHTML = '<option value="">' + (mySts.length ? 'All my stations' : 'All stations') + '</option>';
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
    btn.textContent = label[t];
  };
  const saved = localStorage.getItem('theme'); apply(saved === 'light' || saved === 'dark' ? saved : 'auto');
  btn.onclick = () => { const cur = localStorage.getItem('theme') || 'auto'; apply(order[(order.indexOf(cur) + 1) % order.length]); };
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
    if (wkBtn) wkBtn.textContent = DATE_MODES[state.dateMode];
    if (reloadIt && state.dateMode !== 2) loadWorklist();   // custom mode leaves the current list until you type
  }
  // manual edit: blank = open-ended on that side (so clearing both = all dates); switches to custom mode.
  const applyDate = (inp, key) => {
    const v = inp.value.trim();
    if (v === '' || isYmd(v)) {
      inp.classList.remove('bad'); state[key] = v;
      state.dateMode = 2; if (wkBtn) wkBtn.textContent = DATE_MODES[2];
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
  const applyFiltersHidden = h => { if (fbar) fbar.classList.toggle('hidden', h); if (vctl) vctl.classList.toggle('hidden', h); if (tf) tf.textContent = h ? 'Show filters' : 'Hide filters'; };
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
    if (!items.length) { pop.innerHTML = '<div class="mut">no ' + (cc ? cc + ' ' : '') + 'port matches' + (ql ? ' “' + esc(ql) + '”' : '') + '</div>'; pop.style.display = 'block'; active = -1; return; }
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
      const ch = el('span', 'pchip', esc(code) + '<span class="x" title="remove">✕</span>');
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
const SEARCH_PH = { company: 'Company name…', job: 'Job number…', booking: 'Booking / SO number…', po: 'PO number…', house: 'House B/L number…', master: 'Master B/L number…', conv: 'Vessel / voyage (sea) or flight no (air)…' };
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
    if (!items.length) { pop.innerHTML = '<div class="mut">No active company matches “' + esc(q) + '”</div>'; pop.style.display = 'block'; active = -1; return; }
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
    inp.placeholder = SEARCH_PH[state.searchField] || 'Search…';
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
// so we coordinate from booking -> delivery. Reads only the pgsops feed; assign locally to an operator.
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
    '<div class="ib-head">Inbound bookings (pre-arrival)<span class="ib-station"></span> <span class="cnt ib-count"></span>' +
      '<button class="ghost ib-alltoggle"></button><button class="ghost ib-collapse" title="Collapse">▾</button></div>' +
    '<div class="ib-search">' +
      '<select id="ibOrigin" title="Origin office that received the booking"><option value="">All origins</option></select>' +
      '<input type="text" id="ibParty" placeholder="shipper / consignee / customer" autocomplete="off" title="Match a party name or code in any role">' +
      '<input type="text" id="ibQ" placeholder="booking / ship-id / PO / HBL / ctr" autocomplete="off" title="Search booking no, spot/ship ID, PO, house or master bill, container">' +
      '<span class="combo portchips" id="ibPolChips" title="POL — type a code or name"><input type="text" placeholder="POL…" autocomplete="off"><div class="mention-pop"></div><span class="chiprow"></span></span>' +
      '<span class="combo portchips" id="ibPodChips" title="POD — type a code or name"><input type="text" placeholder="POD…" autocomplete="off"><div class="mention-pop"></div><span class="chiprow"></span></span>' +
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
  tg.textContent = state.ibShowAll ? 'recent only' : 'show all';
  tg.title = state.ibShowAll ? 'Showing all — click to show only recent/upcoming' : 'Showing recent + upcoming — click to show all';
  let q = '/api-ops/inbound?mode=' + encodeURIComponent(state.tmode) + (state.ibShowAll ? '&showAll=1' : '');
  if (state.ib.origin) q += '&origin=' + encodeURIComponent(state.ib.origin);
  if (state.ib.party) q += '&party=' + encodeURIComponent(state.ib.party);
  if (state.ib.q) q += '&q=' + encodeURIComponent(state.ib.q);
  if (state.ib.pols.length) q += '&pol=' + encodeURIComponent(state.ib.pols.join(','));
  if (state.ib.pods.length) q += '&pod=' + encodeURIComponent(state.ib.pods.join(','));
  const data = await api(q);
  const rows = arr(data.rows); const station = data.station || '';
  panel.querySelector('.ib-station').textContent = station ? ' · ' + station : '';
  panel.querySelector('.ib-count').textContent = rows.length;
  const body = panel.querySelector('.ib-body'); body.innerHTML = '';
  const searching = !!(state.ib.origin || state.ib.party || state.ib.q || state.ib.pols.length || state.ib.pods.length);
  if (!rows.length) {
    body.appendChild(el('div', 'bh', 'nothing ' + (state.ibShowAll ? '' : 'recent/upcoming ') + 'in the feed' +
      (searching ? ' matching the search' : '') + (state.ibShowAll ? '' : ' — try “show all”')));
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
      body.appendChild(el('div', 'bh', esc(k) + ' <span class="cnt">' + gs.length + '</span>'));
      gs.sort(ibByDate).forEach(r => body.appendChild(inboundCard(r)));
    });
  } else {
    IB_STAGES.forEach(g => {
      const gs = rows.filter(r => ibStage(r) === g.k).sort(ibByDate);
      if (!gs.length) return;
      body.appendChild(el('div', 'bh', esc(g.t) + ' <span class="cnt">' + gs.length + '</span>'));
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
  const headWho = ctrl ? 'cust: ' + esc(ctrl) : 'cgne: ' + esc(cnee);
  const route = [r.pol, r.pod].filter(Boolean).join(' → ');
  // service label only meaningful for sea (FCL/LCL); for air "Air" is redundant (mode already selected)
  const svc = (r.cargoType && r.cargoType.toUpperCase() !== 'AIR') ? (r.service ? r.cargoType + ' (' + r.service.trim() + ')' : r.cargoType) : '';
  const qty = [r.bookingQty, r.bookingWgt].filter(Boolean).join(' / ') || r.cargoSummary || '';
  const conv = r.vesselFlight ? esc(r.vesselFlight) : '';
  const asg = r.assignedTo ? '<span class="ib-asg" title="Reassign">' + esc(r.assignedTo) + '</span>'
                           : '<button class="tick primary ib-assign">Assign</button>';
  // dates are the operator's lever for talking to the consignee — give them their own prominent row
  const dates = [];
  if (r.cargoReady) dates.push('cargo-ready <b>' + esc(r.cargoReady) + '</b>');
  if (r.etd) dates.push('ETD <b>' + esc(r.etd) + '</b>');
  const dateRow = dates.length ? dates.join('&nbsp;&nbsp;·&nbsp;&nbsp;') : 'dates not set yet — confirm with origin';
  // line 2: the operational shape — origin, service, qty, route, planned conveyance
  const sub = ['from ' + esc(r.sourceStation), esc(svc), esc(qty), esc(route), conv].filter(Boolean).join('  ·  ');
  // line 3: the reference numbers used when talking to the consignee / tracing the box
  const ids = [r.masterBill ? (r.mode === 'Air' ? 'MAWB ' : 'MBL ') + esc(r.masterBill) : '',
    r.containerNo ? 'ctr ' + esc(r.containerNo) : '', r.spotId ? 'ship-id ' + esc(r.spotId) : '',
    r.poNo ? 'PO ' + esc(r.poNo) : '']
    .filter(Boolean).join('  ·  ');
  // parties subline: clickable — fills the panel's party search (matches name or code in any role)
  const mkPty = (lbl, name, code, title) => (name || code)
    ? '<span class="pty" data-q="' + esc(code || name) + '" title="' + esc(title) + ' — click to search the feed for this company">' + lbl + ' ' + esc(name || code) + '</span>' : '';
  const pty = [mkPty('shpr', r.shipperName, r.shipperCode, 'shipper'), mkPty('cgne', r.consigneeName, r.consigneeCode, 'consignee'),
    mkPty('agnt', r.agentName, r.agentCode, 'agent (agn2)')].filter(Boolean).join('  ·  ');
  c.innerHTML =
    '<div class="r1"><span class="mref">' + esc(r.bookingNo) + '</span>' +
      (r.incoterm ? '<span class="minco">' + esc(r.incoterm) + '</span>' : '') +
      '<span class="mwho" title="' + (ctrl ? 'controlling customer (rcustomer)' : 'consignee') + '">' + headWho + '</span><span class="mspacer"></span>' + asg + '</div>' +
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
  box.innerHTML = '<h3>Assign inbound booking</h3><p class="modal-msg">' + esc(r.bookingNo) + ' from ' + esc(r.sourceStation) + ' · consignee ' + esc(r.consigneeName || r.consigneeCode || '—') + '</p>';
  const sel = el('select'); sel.innerHTML = '<option value="">— unassign —</option>';
  state.roster.forEach(u => { const o = el('option'); o.value = u; o.textContent = u; if (u === r.assignedTo) o.selected = true; sel.appendChild(o); });
  box.appendChild(sel);
  const ta = el('textarea'); ta.placeholder = 'note to the operator (optional)'; box.appendChild(ta);
  const bar = el('div', 'modal-bar'); const cancel = el('button', 'ghost', 'Cancel'); const ok = el('button', 'primary', 'Save');
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
  const wl = $('#worklist'); wl.innerHTML = '<div class="empty">Loading…</div>';
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
  const word = (state.tmode === 'Air' ? 'air ' : 'sea ') + state.bound.toLowerCase();
  wl.innerHTML = '';
  if (!rows.length) {
    $('#wlCount').textContent = '0 ' + word + ' shipments';
    if (refMode) { wl.innerHTML = '<div class="empty">No shipment found for ' + esc(($('#fSearchField') && $('#fSearchField').selectedOptions[0].text) || '') + ' “' + esc(state.ref) + '” (searched all dates, within your access).</div>'; return; }
    if (state.notesOnly) { wl.innerHTML = '<div class="empty">No ' + esc(word) + ' shipments you’ve noted' + (state.alertsOnly ? ' with a red/amber alert' : '') + '. Notes you add appear here on any date.</div>'; return; }
    if (state.alertsOnly) { wl.innerHTML = '<div class="empty">No ' + esc(word) + ' shipments with a red/amber alert in this view.</div>'; return; }
    const win = (state.from || state.to) ? ' moving, due or created in ' + esc(state.from || '…') + ' → ' + esc(state.to || '…') + ' (clear the dates to see all)' : '';
    const filt = (state.company || state.pols.length || state.pods.length) ? ' matching the active filters' : '';
    wl.innerHTML = '<div class="empty">No ' + esc(word) + ' shipments' + filt + win + '.</div>'; return;
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
  $('#wlCount').textContent = rows.length + ' ' + word + ' · ' + gList.length + ' ' + conv + (gList.length === 1 ? '' : 's');
  buckets.forEach(bk => {
    const gs = gList.filter(g => g.key === bk.key).sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0));
    if (!gs.length) return;
    const ships = gs.reduce((a, g) => a + g.rows.length, 0);
    const sec = el('div', 'bucket');
    sec.appendChild(el('div', 'bh', esc(bk.title) + ' <span class="cnt">' + gs.length + ' ' + conv + (gs.length === 1 ? '' : 's') + ' · ' + ships + ' shp</span>'));
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
  const unit = isAir ? '' : (totalCont ? ' · ' + totalCont + ' ctr' : '');
  const box = el('div', 'vgroup' + (allCollapsed ? ' collapsed' : ''));
  const head = el('div', 'vhead ' + worst);
  // air group headers add the flight (vesselVoyage = airline+flight) and the leg route — flight numbers repeat
  // weekly, so MAWB + flight + route together identify the consol at a glance
  const airBits = isAir ? [sample.vesselVoyage ? esc(sample.vesselVoyage) : '', sample.routeSummary ? '<span class="vroute">' + esc(sample.routeSummary) + '</span>' : '']
    .filter(Boolean).map(s => ' · ' + s).join('') : '';
  head.innerHTML = '<span class="vtoggle">▾</span><span class="vname">' + esc(g.vv) + airBits + '</span>' +
    arrivalChip(sample) + '<span class="vmeta">' + rs.length + ' shp' + unit + '</span>';
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
    case 'arrived': return '<span class="chip arrived">Arrived ' + esc(r.ata || '') + '</span>';
    case 'arriving': return '<span class="chip transit">In transit' + (r.eta ? ' · ETA ' + esc(r.eta) : (r.etd ? ' · dep ' + esc(r.etd) : '')) + '</span>';
    case 'planning': return '<span class="chip plan">Planning</span>';
    case 'no_space': return '<span class="chip nospace">Awaiting space</span>';
    case 'customs_window': return '<span class="chip transit">Customs' + (r.etd ? ' · ETD ' + esc(r.etd) : '') + '</span>';
    case 'cargo_pending': return '<span class="chip plan">Cargo pending</span>';
    case 'on_track': return '<span class="chip arrived">On track</span>';
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
  const updTip = (r.updateMilestone ? r.updateMilestone + ' — ' : '') + (r.updateMilestoneName || 'status update') + ' (updated, no remark)';
  // 💬 tooltip shows WHAT was written (latest note), prefixed by its milestone code — e.g. "A3: Temporary Release".
  // Milestone-tick notes are stored as "Ticked A3 complete: <reason>" — strip the boilerplate, keep the reason.
  let noteTip = 'has a remark / note';
  if (r.noteText) {
    const txt = r.noteText.replace(/^Ticked\s+\S+\s+complete:?\s*/i, '').replace(/^Re-opened\s+\S+\s*:?\s*/i, '');
    noteTip = (r.noteMilestone ? r.noteMilestone + ': ' : '') + (txt || r.noteText);
  }
  const note = (r.hasNotes ? '<span class="note-ind" title="' + esc(noteTip) + '">💬</span>' : '')
    + (r.hasUpdate ? '<span class="upd-ind" title="' + esc(updTip) + '">' + (updLbl ? esc(updLbl) : 'updated') + '</span>' : '');
  const mLbl = isAir ? 'MAWB' : 'MBL';
  // 🆕 = job created within the last 7 days — a fresh booking the operator may not have seen yet
  const today = (ME && ME.today) ? new Date(ME.today + 'T00:00:00') : new Date();
  const isNew = r.anchor && (today - new Date(r.anchor + 'T00:00:00')) / 86400000 < 7;
  const newTag = isNew ? '<span class="chip newbk" title="new booking - created ' + esc(r.anchor) + '">NEW</span>' : '';
  // primary id: the PER-SHIPMENT number the operator/customer recognises, never the internal synthetic key
  // and never the job number first (one job no can cover many house bills). Lead with the house bill, then the
  // booking (sono) — both per-HBL — then the job no, then the synthetic key as a last resort.
  const humanId = isImport
    ? (r.houseBill || r.sono || r.erpJobNo || r.masterBill || r.jobNo)
    : (r.houseBill || r.sono || r.erpJobNo || r.jobNo);
  const primary = esc(humanId);
  const inco = r.incoterm ? '<span class="minco" title="Incoterm — your delivery responsibility">' + esc(r.incoterm) + '</span>' : '';
  // sub-line bits (all pre-escaped)
  const diff = r.containerNo
    ? 'ctr ' + esc(r.containerNo) + (r.containerCount > 1 ? ' +' + (r.containerCount - 1) : '')
    : (r.linerSo ? 'SO ' + esc(r.linerSo) : '');
  // import: show the master (OBL for sea, MAWB for air). House bill is the headline, job no rides jobTag,
  // booking rides the sono bit — so this only adds the master, and only for import.
  const otherBill = (isImport && r.masterBill) ? (mLbl + ' ' + esc(r.masterBill)) : '';
  // sea custRef = spot/ship ID, air = customer PO (both are what the customer quotes back)
  const po = r.custRef ? (isAir ? 'PO ' : 'ship-id ') + esc(r.custRef) : '';
  const sono = (r.sono && r.sono !== humanId) ? 'bkg ' + esc(r.sono) : '';   // skip if the booking is already the headline
  const commod = r.commodity ? '<span title="' + esc(r.commodity) + '">' + esc(r.commodity.length > 28 ? r.commodity.slice(0, 28) + '…' : r.commodity) + '</span>' : '';
  const exp = !isImport ? [r.cargoReady ? 'cargo-ready ' + esc(r.cargoReady) : '', r.etd ? 'ETD ' + esc(r.etd) : ''].filter(Boolean).join(' · ') : '';
  // import logistics dates: pickup-available and (expected or actual) delivery — the consignee's questions
  const impDates = isImport ? [r.availableDate ? 'avail ' + esc(r.availableDate) : '',
    r.goodsDelivery ? 'dlvd ' + esc(r.goodsDelivery) : (r.etaDelivery ? 'dlv ' + esc(r.etaDelivery) : '')].filter(Boolean).join(' · ') : '';
  const jobTag = (r.erpJobNo && r.erpJobNo !== humanId) ? 'job ' + esc(r.erpJobNo) : '';   // always keep the human job no visible when it isn't the headline
  const sub = [diff, cargo, commod, po, sono, otherBill, exp, impDates, esc(r.routeSummary || r.lane || ''), jobTag].filter(Boolean).join('  ·  ');
  // parties subline: shipper / consignee / agent — each clickable to apply the company filter
  const mkPty = (lbl, code, title) => code
    ? '<span class="pty" data-code="' + esc(code) + '" title="' + esc(title) + ' — click to filter the worklist by this company">' + lbl + ' ' + esc(compName(code)) + '</span>' : '';
  const pty = [mkPty('shpr', r.shipperCode, 'shipper'), mkPty('cgne', r.consigneeCode, 'consignee'), mkPty('agnt', r.agentCode, 'agent (agn2)')].filter(Boolean).join('  ·  ');
  c.innerHTML =
    '<div class="r1">' +
      '<span class="mref">' + (primary || '—') + '</span>' + newTag + inco +
      '<span class="mwho" title="controlling customer (rcustomer)">' + esc(who || '—') + '</span>' +
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
  $('#dJob').textContent = label || job; $('#dLane').textContent = ''; $('#drawerBody').innerHTML = '<div class="empty">Loading…</div>';
  const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job));
  renderShipment(job, data);
}
function closeDrawer() { $('#drawerBg').classList.remove('open'); $('#drawer').classList.remove('open'); }

function renderShipment(job, data) {
  const chk = data.checklist || {}; const sh = chk.shipment || {}; const roll = chk.rollup || {};
  $('#dLight').className = 'dot ' + (roll.worst_light || 'G');
  $('#dLane').textContent = (sh.bound || '') + ' · ' + (sh.lane || '');
  const body = $('#drawerBody'); body.innerHTML = '';
  const head = el('div', 'muted', 'ETD ' + (sh.etd || '—') + ' · ETA ' + (sh.eta || '—') + ' · ATD ' + (sh.atd || '—') +
    ' &nbsp;|&nbsp; auto ' + (roll.automation ? roll.automation.auto : 0) + ' · manual ' + (roll.automation ? roll.automation.manual : 0));
  head.style.marginBottom = '8px';
  // pen = quick shortcut to the Edit ERP data editor (same as the panel button lower down)
  const pen = el('span', 'penedit', '✎');
  pen.title = 'Edit ERP data'; pen.style.cssText = 'cursor:pointer;margin-left:8px;color:var(--accent,#2563eb)';
  pen.onclick = () => window.open('erp-edit.html?job=' + encodeURIComponent(job), '_blank');
  head.appendChild(pen);
  body.appendChild(head);
  // reference docs the operator + customer recognise (house/master bill, incoterm, PO, container, cargo-ready)
  const isAir = sh.mode === 'Air';
  const refBits = [];
  if (sh.house_bill) refBits.push('<b>' + (isAir ? 'HAWB' : 'House BL') + '</b> ' + esc(sh.house_bill));
  if (sh.master_bill) refBits.push((isAir ? 'MAWB' : 'Master BL') + ' ' + esc(sh.master_bill));
  if (sh.incoterm) refBits.push('Incoterm <b>' + esc(sh.incoterm) + '</b>');
  if (sh.cust_ref) refBits.push('Cust PO ' + esc(sh.cust_ref));
  if (sh.container_no) refBits.push('Ctr ' + esc(sh.container_no) + (sh.container_count > 1 ? ' +' + (sh.container_count - 1) : ''));
  else if (sh.liner_so) refBits.push('Liner SO ' + esc(sh.liner_so));
  if (sh.cargo_ready) refBits.push('Cargo-ready ' + esc(sh.cargo_ready));
  const ex = data.extra || {};
  if (ex.sono) refBits.push('Bkg/SO ' + esc(ex.sono));
  if (ex.availableDate) refBits.push('Avail pickup ' + esc(ex.availableDate));
  if (ex.goodsDelivery) refBits.push('Delivered ' + esc(ex.goodsDelivery));
  else if (ex.etaDelivery) refBits.push('Exp delivery ' + esc(ex.etaDelivery));
  if (refBits.length) { const rd = el('div', 'refdocs', refBits.join(' &nbsp;·&nbsp; ')); body.appendChild(rd); }

  // route timeline + cargo + internal remark (seeded snapshot, refreshable live from the ERP)
  body.appendChild(deepDetailSection(job, data));

  const actions = el('div'); actions.style.cssText = 'margin-bottom:10px';
  const rb = el('button', 'ghost', 'Remind me'); rb.style.fontSize = '12px'; rb.onclick = () => remindMe(job);
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
  nx.appendChild(el('h3', null, 'Notes & reminders'));
  nx.appendChild(composer(job, null));
  const list = el('div', 'notelist');
  plain.forEach(n => list.appendChild(noteItem(n)));
  if (!plain.length) list.appendChild(el('div', 'empty', 'No notes yet.'));
  nx.appendChild(list);
  body.appendChild(nx);
}
const ARR_TYPES = [
  { key: 'customer', label: 'Customer' },
  { key: 'trucker', label: 'Trucker' },
  { key: 'broker', label: 'Customs broker' },
  { key: 'warehouse', label: 'Warehouse' },
];
function arrPlaceholder(t) { return ({ customer: 'customer contact person', trucker: 'trucker company', broker: 'broker name', warehouse: 'warehouse' })[t] || 'party'; }
function arrangementsPanel(job, sh, notes) {
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, 'Arrangements'));
  const isImport = (sh.bound || 'Import') === 'Import';
  const who = isImport ? sh.consignee_name : sh.shipper_name;
  const bits = [];
  if (sh.cust_contact) bits.push(esc(sh.cust_contact));
  if (sh.cust_phone) bits.push('Phone: <a href="tel:' + esc(sh.cust_phone) + '">' + esc(sh.cust_phone) + '</a>');
  if (sh.cust_email) bits.push('Email: <a href="mailto:' + esc(sh.cust_email) + '">' + esc(sh.cust_email) + '</a>');
  const contact = el('div', 'contact');
  contact.innerHTML = '<span class="lbl">' + (isImport ? 'Consignee' : 'Shipper') + '</span> <b>' + esc(who || '—') + '</b>' +
    (bits.length ? ' · ' + bits.join(' · ') : ' <span class="mut">(no contact on file)</span>');
  wrap.appendChild(contact);
  const byType = {};
  arr(notes).filter(n => n.kind === 'arrangement').forEach(n => { (byType[n.arrType] = byType[n.arrType] || []).push(n); });
  ARR_TYPES.forEach(t => {
    const row = el('div', 'arr-row');
    const items = byType[t.key] || [];
    let html = '<div class="arr-head"><span class="arr-label">' + t.label + '</span>' +
      '<button class="tick ghost arr-add" data-type="' + t.key + '">+ reminder</button></div>';
    if (items.length) {
      html += '<div class="arr-items">' + items.map(n =>
        '<div class="arr-item' + (n.status === 'done' ? ' done' : '') + '" data-id="' + esc(n.id) + '">' +
        (n.party ? '<b>' + esc(n.party) + '</b> ' : '') + '<span>' + esc(n.note) + '</span>' +
        (n.contact ? ' <span class="mut">' + esc(n.contact) + '</span>' : '') +
        ' <span class="arr-st ' + esc(n.arrStatus || 'todo') + '">' + esc(n.arrStatus || 'todo') + '</span>' +
        (n.status === 'done' ? ' <span class="mut">✔ ' + esc(n.doneBy) + '</span>' : '<button class="tick ghost arr-done" data-id="' + esc(n.id) + '">done</button>') +
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
    '<input class="ai party" placeholder="' + arrPlaceholder(type) + '">' +
    '<input class="ai contact" placeholder="contact / phone (optional)">' +
    '<input class="ai note" placeholder="reminder, e.g. confirm pickup from terminal → warehouse">' +
    '<select class="ai status"><option value="todo">to-do</option><option value="arranged">arranged</option><option value="confirmed">confirmed</option></select>' +
    '<span class="mentwrap"><input class="ai ment" placeholder="@mention a colleague — type name, team or station (optional)"><div class="mention-pop"></div></span>';
  const bar = el('div'); bar.style.cssText = 'display:flex;gap:8px;margin-top:6px';
  const save = el('button', 'primary', 'Save'); const cancel = el('button', 'ghost', 'Cancel');
  bar.appendChild(save); bar.appendChild(cancel); f.appendChild(bar); wrap.appendChild(f);
  wireMention(f.querySelector('.ment'), f.querySelector('.mention-pop'));   // same @-mention picker as the note composer
  cancel.onclick = () => f.remove();
  save.onclick = async () => {
    const party = f.querySelector('.party').value.trim();
    const contact = f.querySelector('.contact').value.trim();
    const note = f.querySelector('.note').value.trim();
    const arr_status = f.querySelector('.status').value;
    const mentions = extractMentions(f.querySelector('.ment').value);
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
  h.innerHTML = '<h3>Route & ERP detail</h3>';
  const stamp = el('span', 'deep-stamp mut', '');
  const btn = el('button', 'ghost deep-btn', 'Refresh from ERP');
  btn.title = 'Fetch this shipment live from the station ERP (one keyed lookup) — remark, route and cargo as of right now';
  h.appendChild(stamp); h.appendChild(btn);
  const inner = el('div', 'deep-body');
  wrap.appendChild(h); wrap.appendChild(inner);
  const renderInner = (d, live) => {
    let html = routeTimeline(d.route);
    const cg = cargoLine(d.cargo); if (cg) html += '<div class="deep-cargo">Cargo: ' + cg + '</div>';
    if (d.commodity.length) html += '<div class="deep-comm">Goods: ' + d.commodity.map(esc).join(' · ') + '</div>';
    if (d.remark) html += '<div class="deep-rem"><span class="lbl">Internal remark</span><div class="rem">' + esc(d.remark) + '</div></div>';
    if (d.special) html += '<div class="deep-rem"><span class="lbl">Special remark</span><div class="rem">' + esc(d.special) + '</div></div>';
    inner.innerHTML = html || '<div class="empty">No route / remark on the snapshot yet — try “Refresh from ERP”.</div>';
    stamp.className = 'deep-stamp ' + (live ? 'live' : 'mut');
    stamp.textContent = live ? ('live · ' + (d.stamp || '')) : (d.stamp ? 'snapshot · ' + d.stamp : '');
  };
  renderInner(normDeep(data), false);
  btn.onclick = async () => {
    btn.disabled = true; btn.textContent = 'fetching…';
    try {
      const live = await api('/api-ops/erp-detail?job=' + encodeURIComponent(job));
      if (live && live.error) { stamp.className = 'deep-stamp err'; stamp.textContent = live.error; }
      else renderInner(normDeep(live), true);
    } catch (e) { stamp.className = 'deep-stamp err'; stamp.textContent = 'ERP fetch failed — is the VPN/source DB reachable?'; }
    btn.disabled = false; btn.textContent = 'Refresh from ERP';
  };
  return wrap;
}
function milestoneRow(job, m) {
  const tracked = m.tracked !== false && m.state !== 'n/a';
  const row = el('div', 'ms ' + (m.state || ''));
  let tag = '';
  if (m.state === 'done') tag = '<span class="tag auto">auto ✓</span>';
  else if (m.state === 'bypassed') tag = '<span class="tag manual">manual ✓</span>';
  else if (m.state === 'n/a') tag = '<span class="tag na">n/a</span>';
  const lightClass = (m.state === 'done' || m.state === 'bypassed') ? 'G' : (m.light || 'G');
  const light = tracked ? '<span class="dot ' + lightClass + '"></span>' : '<span class="dot x"></span>';
  row.innerHTML = '<span class="seqn">' + esc(m.seq) + '</span>' + light +
    '<span class="nm">' + esc(m.code) + ' · ' + esc(m.name) + '<div class="st">' + esc(m.basis || '') + (m.due ? ' (' + esc(m.due) + ')' : '') + '</div></span>' + tag;
  // tick / untick control — only for tracked milestones
  if (tracked) {
    if (m.state === 'bypassed') {
      const b = el('button', 'tick ghost', 'Un-tick'); b.onclick = () => closeMilestone(job, m.code, false, null); row.appendChild(b);
    } else if (m.state !== 'done') {
      const b = el('button', 'tick primary', '✓ Tick'); b.onclick = () => promptBypass(job, m.code, m.name); row.appendChild(b);
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
    const cancel = el('button', 'ghost', 'Cancel');
    const ok = el('button', 'primary', okLabel || 'Confirm');
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
    box.innerHTML = '<h3>Remind me</h3><p class="modal-msg">A note to yourself about what to follow up on this shipment. Set a date to chase it (optional).</p>';
    const ta = el('textarea'); ta.placeholder = 'e.g. chase trucker to confirm terminal pickup → warehouse'; box.appendChild(ta);
    const drow = el('div', 'modal-date');
    drow.innerHTML = '<span class="muted">Follow up on</span>';
    const date = el('input'); date.type = 'text'; date.placeholder = 'yyyy-mm-dd'; date.maxLength = 10; date.className = 'datebox'; drow.appendChild(date); box.appendChild(drow);
    const bar = el('div', 'modal-bar');
    const cancel = el('button', 'ghost', 'Cancel');
    const ok = el('button', 'primary', 'Set reminder');
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
  wrap.appendChild(el('h3', null, 'Draft ' + dtype + ' review'));
  const bodyEl = el('div', null, '<div class="empty">Loading…</div>');
  wrap.appendChild(bodyEl);
  api('/api-ops/docs?job=' + encodeURIComponent(job)).then(d => {
    bodyEl.innerHTML = '';
    const docs = arr(d.docs);
    if (!docs.length) {
      const b = el('button', 'ghost', '+ Create draft ' + dtype + ' from this shipment');
      b.style.fontSize = '12px';
      const label = b.textContent;
      b.onclick = async () => {
        // Open the editor tab NOW (inside the click = a user gesture, so the browser won't block it); it shows a
        // "preparing" placeholder and we point it at the editor once the draft is ready. Creating the draft reads
        // the ERP, so it takes a few seconds — keep the button honest about that instead of a silent spinner.
        let w = null; try { w = window.open('about:blank', '_blank'); } catch (e) {}
        if (w) { try { w.document.write('<!doctype html><meta charset="utf-8"><title>Preparing draft ' + dtype + '…</title><body style="font:15px -apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:48px;color:#333">Preparing your draft ' + dtype + ' from the shipment and ERP… this tab opens the editor automatically when it\'s ready.</body>'); } catch (e) {} }
        b.disabled = true; b.textContent = 'Creating draft ' + dtype + '… (reading ERP, a few seconds)';
        let r; try { r = await api('/api-ops/doc-create', { method: 'POST', body: { job_no: job } }); }
        catch (e) { r = { error: 'network error' }; }
        if (r.error && !r.docId) { if (w) w.close(); alert(r.error); b.disabled = false; b.textContent = label; return; }
        const url = 'doc-editor.html?id=' + encodeURIComponent(r.docId);
        if (w) w.location = url;                 // navigate the already-open tab to the editor
        b.textContent = 'Draft ' + dtype + ' ready' + (w ? '' : ' — click “Open editor” below');
        openShipment(job);   // refresh the drawer so the panel shows the new doc + its Open editor button
      };
      bodyEl.appendChild(b);
      return;
    }
    docs.forEach(dc => {
      const card = el('div', 'doccard');
      const bits = ['<span class="docstatus s-' + esc(dc.status) + '">' + esc(DOC_STATUS_LABEL[dc.status] || dc.status) + '</span>',
        'v' + dc.currentVersion];
      if (dc.erpDocNo) bits.push('official no. <b>' + esc(dc.erpDocNo) + '</b>');
      if (dc.amendCount) bits.push('amend #' + dc.amendCount);
      if (dc.activeToken) bits.push('link live (' + esc(dc.activeToken.customerEmail || 'customer') + ', viewed ' + dc.activeToken.viewCount + 'x)');
      else if (dc.customerEmail) bits.push(esc(dc.customerEmail));
      card.innerHTML = '<b>' + esc(dc.docType) + '</b> · ' + bits.join(' · ') + ' ';
      const open = el('button', 'ghost', 'Open editor');
      open.style.fontSize = '12px';
      open.onclick = () => window.open('doc-editor.html?id=' + encodeURIComponent(dc.docId), '_blank');
      card.appendChild(open);
      bodyEl.appendChild(card);
    });
  }).catch(() => { bodyEl.innerHTML = '<div class="empty">Could not load documents.</div>'; });
  return wrap;
}

// Correct bad ERP master data for this shipment (staff-internal). Opens erp-edit.html in its own tab, which
// self-seeds the current ERP values + master-code lookups and pushes only the changed fields to /booking/update.
function erpEditPanel(job, sh) {
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, 'Edit ERP data'));
  const b = el('button', 'ghost', 'Edit ERP data');
  b.style.cssText = 'font-size:12px;margin-top:6px';
  b.onclick = () => window.open('erp-edit.html?job=' + encodeURIComponent(job), '_blank');
  wrap.appendChild(b);
  return wrap;
}

// Browse the files the ERP holds for this shipment. Read-only this round (document type / file name / remark);
// the heading shows which identifier was used so it's clear what the ERP matched on. Download comes later.
function erpFilesPanel(job, sh) {
  const wrap = el('div', 'arrange');
  const h = el('h3', null, 'ERP files');
  wrap.appendChild(h);
  const bodyEl = el('div', null, '<div class="empty">Loading…</div>');
  wrap.appendChild(bodyEl);
  api('/api-ops/erp-files?job=' + encodeURIComponent(job)).then(d => {
    bodyEl.innerHTML = '';
    if (d.error) { bodyEl.innerHTML = '<div class="empty">' + esc(d.error) + '</div>'; return; }
    if (d.mock) { bodyEl.innerHTML = '<div class="empty">ERP not configured — no live file lookup in this environment.</div>'; return; }
    const keyLabel = (d.keyKind || 'booking') + (d.keyUsed ? ' ' + d.keyUsed : '');
    const files = arr(d.files);
    h.textContent = 'ERP files · ' + keyLabel;
    if (!files.length) {
      bodyEl.appendChild(el('div', 'empty', 'No files in the ERP for this ' + esc((d.keyKind || 'booking').toLowerCase()) + '.'));
    } else {
      files.forEach(f => {
        const card = el('div', 'doccard');
        const bits = [];
        if (f.documentTypeCode) bits.push('<span class="docstatus">' + esc(f.documentTypeCode) + '</span>');
        bits.push('<b>' + esc(f.fileName || '(unnamed)') + '</b>');
        if (f.remark) bits.push('<span class="mut">' + esc(f.remark) + '</span>');
        const meta = el('span'); meta.innerHTML = bits.join(' · '); card.appendChild(meta);
        if (f.fileName) {
          const dl = el('button', 'ghost', 'Download'); dl.style.cssText = 'margin-left:auto;font-size:11px;padding:2px 8px';
          dl.onclick = () => downloadErpFile(job, f.fileName, dl);
          card.appendChild(dl);
        }
        bodyEl.appendChild(card);
      });
    }
    // upload a missing document -> ERP /file/upload; a successful upload clears its milestone alert
    const clearable = arr(d.clearableDoctypes);
    if (clearable.length) bodyEl.appendChild(erpUploadRow(job, clearable));
  }).catch(() => { bodyEl.innerHTML = '<div class="empty">Could not reach the ERP for files.</div>'; });
  return wrap;
}
// Upload a missing document straight to the ERP. The doctype list comes from the server (only types that would
// clear a milestone on this shipment). The file is base64'd in the browser and POSTed; nothing is stored locally.
// On success the whole drawer is refreshed so the cleared milestone light + the new file both show.
function erpUploadRow(job, doctypes) {
  const row = el('div', 'erpupload');
  row.appendChild(el('div', 'erpupload-lbl', 'Missing a document? Upload it to the ERP to clear the alert:'));
  const line = el('div', 'erpupload-line');
  const sel = el('select');
  doctypes.forEach(dt => { const o = el('option'); o.value = dt; o.textContent = dt; sel.appendChild(o); });
  const file = el('input'); file.type = 'file'; file.accept = '.pdf,.png,.jpg,.jpeg';
  const btn = el('button', 'primary', 'Upload'); btn.style.fontSize = '11px';
  const msg = el('span', 'mut'); msg.style.cssText = 'font-size:11px;margin-left:4px';
  line.appendChild(sel); line.appendChild(file); line.appendChild(btn); line.appendChild(msg);
  row.appendChild(line);
  btn.onclick = async () => {
    const f = file.files && file.files[0];
    if (!f) { msg.textContent = 'choose a file first'; return; }
    if (f.size > 5 * 1024 * 1024) { msg.textContent = 'file too large (max 5 MB)'; return; }
    if (!['application/pdf', 'image/png', 'image/jpeg'].includes(f.type)) { msg.textContent = 'PDF, PNG or JPEG only'; return; }
    const old = btn.textContent; btn.disabled = true; btn.textContent = 'Uploading…'; msg.textContent = '';
    try {
      const base64 = await new Promise((res, rej) => {
        const rd = new FileReader();
        rd.onload = () => res(('' + rd.result).split(',')[1] || '');
        rd.onerror = rej;
        rd.readAsDataURL(f);
      });
      const r = await api('/api-ops/erp-file-upload', { method: 'POST', body: { job: job, doctype: sel.value, fileName: f.name, content_type: f.type, base64: base64 } });
      if (r.error) { msg.textContent = r.error; btn.disabled = false; btn.textContent = old; return; }
      const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data); loadWorklist();
    } catch (e) { msg.textContent = 'upload failed'; btn.disabled = false; btn.textContent = old; }
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
    if (!r.ok) { btn.textContent = 'unavailable'; setTimeout(() => { btn.textContent = old; btn.disabled = false; }, 2500); return; }
    const blob = await r.blob();
    const url = URL.createObjectURL(blob);
    const a = el('a'); a.href = url; a.download = fileName || 'erp-file';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    btn.textContent = old; btn.disabled = false;
  } catch (e) { btn.textContent = 'failed'; setTimeout(() => { btn.textContent = old; btn.disabled = false; }, 2500); }
}

async function remindMe(job) {
  const r = await askReminder();
  if (!r) return;
  await api('/api-ops/notes', { method: 'POST', body: { job_no: job, kind: 'reminder', note: r.note, remind_on: r.date, mentions: [] } });
  const d = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, d); loadTasks();
}
async function promptBypass(job, code, name) {
  const reason = await askText({
    title: 'Mark complete · ' + code + ' ' + name,
    message: 'Confirm this step is done. Add a short note if you like (e.g. filed via portal, hard-copy received).',
    placeholder: 'Note (optional)',
    okLabel: '✓ Confirm done'
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
  const ta = el('textarea'); ta.placeholder = 'Add a note… use @ to remind a colleague'; if (prefill) ta.value = prefill;
  const pop = el('div', 'mention-pop');
  const bar = el('div'); bar.style.cssText = 'display:flex;gap:8px;margin-top:6px;align-items:center';
  const send = el('button', 'primary', 'Post note');
  const hint = el('span', 'muted', ''); hint.style.fontSize = '11.5px';
  bar.appendChild(send); bar.appendChild(hint);
  c.appendChild(ta); c.appendChild(pop); c.appendChild(bar);
  wireMention(ta, pop);
  send.onclick = async () => {
    const text = ta.value.trim(); if (!text) return;
    const mentions = extractMentions(text);
    send.disabled = true;
    await api('/api-ops/notes', { method: 'POST', body: { job_no: job, note: text, mentions } });
    send.disabled = false; ta.value = '';
    const data = await api('/api-ops/shipment?job=' + encodeURIComponent(job)); renderShipment(job, data);
    loadTasks(); loadWorklist();
  };
  return c;
}
function extractMentions(text) {
  const set = new Set(); const re = /@([A-Za-z0-9_.\-]+)/g; let m;
  while ((m = re.exec(text))) { const cand = state.roster.find(u => u.toLowerCase() === m[1].toLowerCase()); if (cand) set.add(cand); }
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
    // match on username, real name, team OR station — so "@HKG" or "@sales" narrows the ~500-user list
    items = state.roster.filter(u => {
      const m = meta[u] || {};
      return u.toLowerCase().includes(q) || (m.name || '').toLowerCase().includes(q) ||
        (m.team || '').toLowerCase().includes(q) || (m.station || '').toLowerCase().includes(q);
    }).slice(0, 8);
    if (!items.length) return close();
    pop.innerHTML = ''; items.forEach((u, i) => {
      const m = meta[u] || {};
      const sub = [m.team, m.station].filter(Boolean).join(' · ');
      const d = el('div', i === 0 ? 'sel' : '');
      d.innerHTML = '<span class="mname">@' + esc(u) + '</span>' +
        (m.name && m.name !== u ? ' <span class="mmeta">' + esc(m.name) + '</span>' : '') +
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
    const s = ta.selectionStart; const before = ta.value.slice(0, s).replace(/@([A-Za-z0-9_.\-]*)$/, '@' + u + ' ');
    ta.value = before + ta.value.slice(s); ta.focus(); close();
  }
}
function noteItem(n) {
  const d = el('div', 'noteitem');
  const ment = arr(n.mentions).map(m => '<span class="mtag">@' + esc(m) + '</span>').join(' ');
  const kindTag = (n.kind && n.kind !== 'note') ? '<span class="kind ' + esc(n.kind) + '">' + esc(n.kind) + '</span> ' : '';
  const done = n.status === 'done';
  d.innerHTML = '<div class="who">' + kindTag + '<strong>' + esc(n.user) + '</strong> · ' + esc((n.created || '').slice(0, 16).replace('T', ' ')) +
    (done ? ' · <span class="muted">✔ ack by ' + esc(n.doneBy) + '</span>' : '') + '</div>' +
    '<div>' + esc(n.note) + ' ' + ment + '</div>';
  if (!done) {
    const b = el('button', 'tick ghost', '✓ Acknowledge'); b.style.marginTop = '6px'; b.style.fontSize = '12px';
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
    body.appendChild(el('div', 'muted', '📄 Draft reviews'));
    drafts.forEach(dr => body.appendChild(draftCard(dr)));
    const h0 = el('div', 'muted', '🔔 Reminders from others'); h0.style.marginTop = '10px'; body.appendChild(h0);
  } else body.appendChild(el('div', 'muted', '🔔 Reminders from others'));
  if (!assigned.length) body.appendChild(el('div', 'empty', 'Nothing waiting on you.'));
  assigned.forEach(t => body.appendChild(taskCard(t, true, today)));
  const h = el('div', 'muted', '📌 My follow-ups'); h.style.marginTop = '10px'; body.appendChild(h);
  if (!mine.length) body.appendChild(el('div', 'empty', 'No reminders set. Open a shipment → 🔔 Remind me.'));
  mine.forEach(t => body.appendChild(taskCard(t, false, today)));
}
function draftCard(dr) {
  const d = el('div', 'task');
  const who = dr.consignee || dr.customerName || dr.jobNo;
  const approved = dr.status === 'CUSTOMER_APPROVED';
  const label = approved ? '✅ approved · ready to agree' : '✏️ customer replied';
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
    const lbl = cls === ' over' ? ' · overdue' : (cls === ' now' ? ' · today' : '');
    due = '<span class="due' + cls + '">🔔 ' + esc(t.remindOn) + lbl + '</span>';
  }
  const kindTag = t.arrType ? '<span class="kind">' + esc(t.arrType) + '</span> ' : '';
  const ctx = [t.cargo, t.vesselVoyage, t.lane].filter(Boolean).map(esc).join(' · ');
  d.innerHTML =
    '<button class="tk-done" title="Mark done">✓</button>' +
    '<div class="tk-head">' + kindTag + '<strong>' + esc(who) + '</strong>' + due + '</div>' +
    '<div class="tk-sub mut">' + esc(t.job_no) + (fromOthers ? ' · from ' + esc(t.user) : '') + (ctx ? ' · ' + ctx : '') + '</div>' +
    '<div class="tk-note">' + esc(t.note) + '</div>';
  d.onclick = () => openShipment(t.job_no);   // whole card opens the shipment
  d.querySelector('.tk-done').onclick = async e => { e.stopPropagation(); await api('/api-ops/note-done', { method: 'POST', body: { id: t.id, done: true } }); loadTasks(); };
  return d;
}

linkBoot().then(init);
