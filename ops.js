// Control Tower client. Vanilla JS, no build step. Mirrors the dashboard's robustness patterns:
// arr() coercion (PS 5.1 ConvertTo-Json mangles 0/1-row arrays), cache:'no-store', X-Ops-User identity.
'use strict';
const $ = s => document.querySelector(s);
const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
const esc = s => ('' + (s ?? '')).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);   // coerce PS single/empty -> array
const isYmd = s => !s || /^\d{4}-\d{2}-\d{2}$/.test(('' + s).trim());   // house date standard: yyyy-mm-dd only

const state = { user: localStorage.getItem('opsUser') || '', roster: [], lens: 'mine', teammate: '', bound: localStorage.getItem('opsBound') || 'Import', tmode: localStorage.getItem('opsMode') || 'Sea',
  from: '', to: '', company: '', pol: '', pod: '', station: localStorage.getItem('opsStation') || '', _companies: [], _ports: { pol: [], pod: [] }, _stations: [] };
let allCollapsed = false;   // collapse-all toggle for vessel groups

async function api(path, opts) {
  opts = opts || {};
  opts.cache = 'no-store';
  opts.headers = Object.assign({ 'X-Ops-User': state.user || '(open)' }, opts.headers || {});
  if (opts.body && typeof opts.body !== 'string') { opts.body = JSON.stringify(opts.body); opts.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opts);
  return r.json();
}

// ---------- init ----------
async function init() {
  try { const c = await api('/api-ops/config'); $('#appName').textContent = c.appName || 'Control Tower'; $('#appSub').textContent = c.appSubtitle || ''; document.title = c.appName || 'Control Tower'; state._stations = arr(c.stations); } catch (e) {}
  buildStationPicker();
  const rost = await api('/api-ops/roster'); state.roster = arr(rost.users).map(u => u.username);
  if (!state.user && state.roster.length) state.user = state.roster[0];
  buildUserPicker(); buildTeammate();
  wireLens(); wireBound(); wireMode(); wireFilters();
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
  sel.innerHTML = '<option value="">All stations</option>';
  state._stations.forEach(s => { const o = el('option'); o.value = s.code; o.textContent = s.code + ' · ' + (s.name || s.code); if (s.code === state.station) o.selected = true; sel.appendChild(o); });
  sel.style.display = state._stations.length > 1 ? '' : 'none';   // hide for single-station instances
  sel.onchange = () => { state.station = sel.value; localStorage.setItem('opsStation', state.station); loadWorklist(); };
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
      document.querySelectorAll('#boundSeg button').forEach(x => x.classList.remove('on'));
      b.classList.add('on'); state.bound = b.dataset.bound; localStorage.setItem('opsBound', state.bound);
      loadWorklist(); loadInbound();
    };
  });
}
function wireMode() {
  document.querySelectorAll('#modeSeg button').forEach(b => {
    if (b.dataset.tmode === state.tmode) b.classList.add('on'); else b.classList.remove('on');
    b.onclick = () => {
      document.querySelectorAll('#modeSeg button').forEach(x => x.classList.remove('on'));
      b.classList.add('on'); state.tmode = b.dataset.tmode; localStorage.setItem('opsMode', state.tmode);
      state.pol = ''; state.pod = '';   // POL/POD lists are mode-specific; reset when switching transport mode
      renderFilterOptions();
      loadWorklist(); loadInbound();
    };
  });
}
// ---------- filters (date window + company + POL/POD) ----------
function fmtDate(x) { const m = String(x.getMonth() + 1).padStart(2, '0'); const d = String(x.getDate()).padStart(2, '0'); return x.getFullYear() + '-' + m + '-' + d; }
function currentWeek() { const d = new Date(); const dow = (d.getDay() + 6) % 7; const mon = new Date(d); mon.setDate(d.getDate() - dow); const sun = new Date(mon); sun.setDate(mon.getDate() + 6); return { from: fmtDate(mon), to: fmtDate(sun) }; }
function wireFilters() {
  const wk = currentWeek(); state.from = wk.from; state.to = wk.to;
  const ff = $('#fFrom'), ft = $('#fTo'); ff.value = state.from; ft.value = state.to;
  const applyDate = (inp, key) => { const v = inp.value.trim(); if (isYmd(v)) { inp.classList.remove('bad'); state[key] = v; loadWorklist(); } else { inp.classList.add('bad'); } };
  ff.onchange = () => applyDate(ff, 'from');
  ft.onchange = () => applyDate(ft, 'to');
  $('#thisWeek').onclick = () => { const w = currentWeek(); state.from = w.from; state.to = w.to; ff.value = w.from; ft.value = w.to; loadWorklist(); };
  $('#allDates').onclick = () => { state.from = ''; state.to = ''; ff.value = ''; ft.value = ''; loadWorklist(); };
  wireCompanyCombo();
  $('#fPol').onchange = e => { state.pol = e.target.value; loadWorklist(); };
  $('#fPod').onchange = e => { state.pod = e.target.value; loadWorklist(); };
}
// Company type-ahead: search the active-worklist companies by NAME (or code) — bounded list loaded client-side,
// so it's instant and never queries the 300k master. (You can only filter shipments by a company that has one.)
function companyLabel(code) { const c = (state._companies || []).find(x => x.code === code); return c ? c.name + ' (' + c.code + ')' : (code || ''); }
function setCompany(code) {
  state.company = code || '';
  const inp = $('#fCompany'); if (inp) inp.value = code ? companyLabel(code) : '';
  const x = $('#fCompanyClear'); if (x) x.style.display = code ? '' : 'none';
}
function wireCompanyCombo() {
  const inp = $('#fCompany'), pop = $('#fCompanyPop'), clr = $('#fCompanyClear');
  if (!inp) return;
  let items = [], active = -1;
  const close = () => { pop.style.display = 'none'; active = -1; };
  const render = q => {
    const ql = ('' + q).trim().toLowerCase();
    items = (state._companies || []).filter(c => !ql || c.name.toLowerCase().includes(ql) || c.code.toLowerCase().includes(ql)).slice(0, 12);
    if (!items.length) { pop.innerHTML = '<div class="mut">No active company matches “' + esc(q) + '”</div>'; pop.style.display = 'block'; active = -1; return; }
    pop.innerHTML = ''; items.forEach((c, i) => { const d = el('div', i === 0 ? 'sel' : '', esc(c.name) + ' <span class="mut">' + esc(c.code) + '</span>'); d.onmousedown = e => { e.preventDefault(); pick(c); }; pop.appendChild(d); });
    active = 0; pop.style.display = 'block';
  };
  const pick = c => { setCompany(c.code); close(); loadWorklist(); };
  const hi = () => { [...pop.children].forEach((d, i) => d.className = i === active ? 'sel' : ''); };
  inp.addEventListener('focus', () => { inp.select(); render(''); });
  inp.addEventListener('input', () => render(inp.value));
  inp.addEventListener('keydown', e => {
    if (pop.style.display !== 'block') return;
    if (e.key === 'ArrowDown') { e.preventDefault(); active = Math.min(active + 1, items.length - 1); hi(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(active - 1, 0); hi(); }
    else if (e.key === 'Enter') { e.preventDefault(); if (items[active]) pick(items[active]); }
    else if (e.key === 'Escape') { close(); inp.blur(); }
  });
  inp.addEventListener('blur', () => { setTimeout(() => { close(); inp.value = state.company ? companyLabel(state.company) : ''; }, 120); });
  if (clr) clr.onclick = () => { setCompany(''); close(); loadWorklist(); };
}
async function loadFilters() {
  try { const c = await api('/api-ops/companies'); state._companies = arr(c.companies); } catch (e) { state._companies = []; }
  try { const p = await api('/api-ops/ports'); state._ports = { pol: arr(p.pol), pod: arr(p.pod) }; } catch (e) { state._ports = { pol: [], pod: [] }; }
  renderFilterOptions();
}
function renderFilterOptions() {
  setCompany(state.company);   // refresh the combo's displayed name now that the company list is loaded
  buildPortSelect('#fPol', (state._ports || {}).pol || [], state.pol, 'All POL');
  buildPortSelect('#fPod', (state._ports || {}).pod || [], state.pod, 'All POD');
}
function buildPortSelect(sel, list, cur, allLabel) {
  const s = $(sel); if (!s) return;
  const codes = [...new Set(list.filter(x => !x.mode || x.mode === state.tmode).map(x => x.code).filter(Boolean))].sort();
  s.innerHTML = '<option value="">' + allLabel + '</option>';
  codes.forEach(code => { const o = el('option'); o.value = code; o.textContent = code; if (code === cur) o.selected = true; s.appendChild(o); });
}
function refreshAll() { loadWorklist(); loadTasks(); loadInbound(); }

// ---------- inbound cross-station bookings (pre-arrival) ----------
// Shown on the Import bound only: bookings created at OTHER stations whose destination is OUR station,
// so we coordinate from booking -> delivery. Reads only the pgsops feed; assign locally to an operator.
// Grouped by booking STAGE (what the origin has done so far), not urgency — so the operator sees what is coming
// before it is EDI'd to them: a fresh booking (no schedule) vs one where the vessel/flight is already arranged.
const IB_STAGES = [
  { k: 'sched', t: '🚢 Vessel / flight scheduled' },
  { k: 'new', t: '🆕 New booking — awaiting schedule' },
];
function ibStage(r) { return (r.vesselFlight || r.etd) ? 'sched' : 'new'; }
function ibByDate(a, b) { const x = a.etd || a.cargoReady || a.bookingDate || '9999'; const y = b.etd || b.cargoReady || b.bookingDate || '9999'; return x < y ? -1 : x > y ? 1 : 0; }
async function loadInbound() {
  const panel = $('#inboundPanel'); if (!panel) return;
  if (state.bound !== 'Import') { panel.style.display = 'none'; panel.innerHTML = ''; return; }
  panel.style.display = '';
  const data = await api('/api-ops/inbound?mode=' + encodeURIComponent(state.tmode) + (state.ibShowAll ? '&showAll=1' : ''));
  const rows = arr(data.rows); const station = data.station || '';
  const head = '📥 Inbound bookings (pre-arrival)' + (station ? ' · ' + esc(station) : '');
  // toggle: default view hides stale/departed + already-received; "show all" reveals the full feed
  const toggle = '<button class="ghost ib-alltoggle" title="' + (state.ibShowAll ? 'Showing all — click to show only recent/upcoming' : 'Showing recent + upcoming — click to show all') + '">'
    + (state.ibShowAll ? 'recent only' : 'show all') + '</button>';
  const headHtml = '<div class="ib-head">' + head + ' <span class="cnt">' + rows.length + '</span>' + toggle
    + '<button class="ghost ib-collapse" title="Collapse">▾</button></div>';
  if (!rows.length) {
    panel.innerHTML = headHtml + '<div class="ib-body"><div class="bh" style="opacity:.7">nothing ' + (state.ibShowAll ? '' : 'recent/upcoming ') + 'in the feed' + (state.ibShowAll ? '' : ' — try “show all”') + '</div></div>';
    const t0 = panel.querySelector('.ib-alltoggle'); if (t0) t0.onclick = () => { state.ibShowAll = !state.ibShowAll; loadInbound(); };
    return;
  }
  panel.innerHTML = headHtml;
  const body = el('div', 'ib-body');
  IB_STAGES.forEach(g => {
    const gs = rows.filter(r => ibStage(r) === g.k).sort(ibByDate);
    if (!gs.length) return;
    body.appendChild(el('div', 'bh', esc(g.t) + ' <span class="cnt">' + gs.length + '</span>'));
    gs.forEach(r => body.appendChild(inboundCard(r)));
  });
  panel.appendChild(body);
  panel.querySelector('.ib-collapse').onclick = () => { body.style.display = body.style.display === 'none' ? '' : 'none'; };
  const tg = panel.querySelector('.ib-alltoggle'); if (tg) tg.onclick = () => { state.ibShowAll = !state.ibShowAll; loadInbound(); };
}
function inboundCard(r) {
  const c = el('div', 'ibcard ' + (r.light || 'G'));
  // the CONSIGNEE is who receives the cargo at destination — the party this operator coordinates with
  const cnee = r.consigneeName || r.consigneeCode || '—';
  const route = [r.pol, r.pod].filter(Boolean).join(' → ');
  const svc = r.cargoType ? (r.service ? r.cargoType + ' (' + r.service.trim() + ')' : r.cargoType) : (r.service || '');
  const qty = [r.bookingQty, r.bookingWgt].filter(Boolean).join(' / ') || r.cargoSummary || '';
  const conv = r.vesselFlight ? (r.mode === 'Air' ? '✈ ' : '🚢 ') + esc(r.vesselFlight) : '';
  const asg = r.assignedTo ? '<span class="ib-asg" title="Reassign">👤 ' + esc(r.assignedTo) + '</span>'
                           : '<button class="tick primary ib-assign">Assign</button>';
  // dates are the operator's lever for talking to the consignee — give them their own prominent row
  const dates = [];
  if (r.cargoReady) dates.push('📅 cargo-ready <b>' + esc(r.cargoReady) + '</b>');
  if (r.etd) dates.push((r.mode === 'Air' ? '🛫' : '⚓') + ' ETD <b>' + esc(r.etd) + '</b>');
  const dateRow = dates.length ? dates.join('&nbsp;&nbsp;·&nbsp;&nbsp;') : '⏳ dates not set yet — confirm with origin';
  // line 2: the operational shape — origin, service, qty, route, planned conveyance
  const sub = ['from ' + esc(r.sourceStation), esc(svc), esc(qty), esc(route), conv].filter(Boolean).join('  ·  ');
  // line 3: the reference numbers used when talking to the consignee / tracing the box
  const ids = [r.masterBill ? (r.mode === 'Air' ? 'MAWB ' : 'MBL ') + esc(r.masterBill) : '',
    r.containerNo ? '📦 ' + esc(r.containerNo) : '', r.spotId ? 'ship-id ' + esc(r.spotId) : '',
    r.poNo ? 'PO ' + esc(r.poNo) : '', r.shipperName ? 'shpr ' + esc(r.shipperName) : '']
    .filter(Boolean).join('  ·  ');
  c.innerHTML =
    '<div class="r1"><span class="mref">' + esc(r.bookingNo) + '</span>' +
      (r.incoterm ? '<span class="minco">' + esc(r.incoterm) + '</span>' : '') +
      '<span class="mwho" title="consignee">cgne: ' + esc(cnee) + '</span><span class="mspacer"></span>' + asg + '</div>' +
    '<div class="ib-dates">' + dateRow + '</div>' +
    (sub ? '<div class="r2">' + sub + '</div>' : '') +
    (ids ? '<div class="r2 ib-ids">' + ids + '</div>' : '');
  const ab = c.querySelector('.ib-assign'); if (ab) ab.onclick = e => { e.stopPropagation(); assignInbound(r); };
  const ac = c.querySelector('.ib-asg'); if (ac) ac.onclick = e => { e.stopPropagation(); assignInbound(r); };
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
    { key: 'arrived', title: '🚢 Arrived — deliver now' },
    { key: 'arriving', title: '⏳ Arriving — prepare' },
    { key: 'planning', title: '🗓 Planning' },
  ],
  Export: [
    { key: 'no_space', title: '⛔ No space (carrier)' },
    { key: 'customs_window', title: '📋 Customs window (ETD−3)' },
    { key: 'cargo_pending', title: '📦 Cargo not ready' },
    { key: 'on_track', title: '✅ On track' },
  ],
};
async function loadWorklist() {
  const wl = $('#worklist'); wl.innerHTML = '<div class="empty">Loading…</div>';
  let q = '/api-ops/worklist?lens=' + encodeURIComponent(state.lens);
  if (state.lens === 'user') q += '&user=' + encodeURIComponent(state.teammate || state.user);
  if (state.from) q += '&from=' + encodeURIComponent(state.from);
  if (state.to) q += '&to=' + encodeURIComponent(state.to);
  if (state.company) q += '&company=' + encodeURIComponent(state.company);
  if (state.pol) q += '&pol=' + encodeURIComponent(state.pol);
  if (state.pod) q += '&pod=' + encodeURIComponent(state.pod);
  if (state.station) q += '&station=' + encodeURIComponent(state.station);
  const data = await api(q);
  const rows = arr(data.rows).filter(r => (r.bound || 'Import') === state.bound && (r.mode || 'Sea') === state.tmode);
  const word = (state.tmode === 'Air' ? 'air ' : 'sea ') + state.bound.toLowerCase();
  wl.innerHTML = '';
  if (!rows.length) {
    $('#wlCount').textContent = '0 ' + word + ' shipments';
    const win = (state.from || state.to) ? ' in ' + esc(state.from || '…') + ' → ' + esc(state.to || '…') + ' (try “All dates”)' : '';
    const filt = (state.company || state.pol || state.pod) ? ' matching the active filters' : '';
    wl.innerHTML = '<div class="empty">No ' + esc(word) + ' shipments' + filt + win + '.</div>'; return;
  }
  const buckets = BUCKETS[state.bound] || BUCKETS.Import;
  const ord = {}; buckets.forEach((b, i) => ord[b.key] = i);
  // group rows by vessel/voyage; derive ONE status per vessel (most-advanced state across its shipments,
  // so a vessel isn't split across buckets just because ATA is filled on only some of its bills)
  const gmap = new Map();
  const noConv = state.tmode === 'Air' ? '(no flight no. yet)' : '(no vessel / voyage yet)';
  rows.forEach(r => { const k = r.vesselVoyage || noConv; if (!gmap.has(k)) gmap.set(k, { vv: k, rows: [] }); gmap.get(k).rows.push(r); });
  const gList = [...gmap.values()].map(g => {
    let best = 99, sk = '';
    g.rows.forEach(r => { const o = (ord[r.arrivalState] != null ? ord[r.arrivalState] : 9); if (o < best) best = o; if (r.sortKey && (!sk || r.sortKey < sk)) sk = r.sortKey; });
    g.key = (buckets[best] && buckets[best].key) || 'other'; g.sortKey = sk;
    return g;
  });
  const conv = state.tmode === 'Air' ? 'flight' : 'vessel';
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
  const rs = g.rows;
  const worst = rs.some(r => r.worst === 'R') ? 'R' : (rs.some(r => r.worst === 'A') ? 'A' : 'G');
  const sample = rs.find(r => r.arrivalState === g.key) || rs[0];
  const totalCont = rs.reduce((a, r) => a + (r.containerCount || 0), 0);
  const isAir = (rs[0] && rs[0].mode === 'Air');
  const icon = isAir ? '✈' : '🚢';
  const unit = isAir ? '' : (totalCont ? ' · ' + totalCont + ' ctr' : '');
  const box = el('div', 'vgroup' + (allCollapsed ? ' collapsed' : ''));
  const head = el('div', 'vhead ' + worst);
  head.innerHTML = '<span class="vtoggle">▾</span><span class="vname">' + icon + ' ' + esc(g.vv) + '</span>' +
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
    case 'no_space': return '<span class="chip nospace">No space</span>';
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
  const who = isImport ? (r.consigneeName || r.custCode) : (r.shipperName || r.custCode);
  const cargo = cargoProfile(r);
  const sev = r.openRed ? '<span class="pill R">' + r.openRed + 'R</span>' : (r.openAmber ? '<span class="pill A">' + r.openAmber + 'A</span>' : '');
  const note = (r.hasNotes ? '<span class="note-ind" title="has a remark / note">💬</span>' : '')
    + (r.hasUpdate ? '<span class="upd-ind" title="status updated — no remark">🔄' + (r.updateMilestone ? ' ' + esc(r.updateMilestone) : '') + '</span>' : '');
  const docLbl = isAir ? 'HAWB' : 'HBL';
  const mLbl = isAir ? 'MAWB' : 'MBL';
  // primary id: import customers know the origin house bill, not our internal job number
  const primary = (isImport && r.houseBill) ? esc(r.houseBill) : esc(r.jobNo);
  const inco = r.incoterm ? '<span class="minco" title="Incoterm — your delivery responsibility">' + esc(r.incoterm) + '</span>' : '';
  // sub-line bits (all pre-escaped)
  const diff = r.containerNo
    ? '🔢 ' + esc(r.containerNo) + (r.containerCount > 1 ? ' +' + (r.containerCount - 1) : '')
    : (r.linerSo ? 'SO ' + esc(r.linerSo) : '');
  const otherBill = isImport ? (r.masterBill ? mLbl + ' ' + esc(r.masterBill) : '')
                             : (r.houseBill ? docLbl + ' ' + esc(r.houseBill) : '');
  const po = r.custRef ? 'PO ' + esc(r.custRef) : '';
  const exp = !isImport ? [r.cargoReady ? 'cargo-ready ' + esc(r.cargoReady) : '', r.etd ? 'ETD ' + esc(r.etd) : ''].filter(Boolean).join(' · ') : '';
  const jobTag = (isImport && r.houseBill) ? esc(r.jobNo) : '';   // keep our job no visible when HBL is primary
  const sub = [diff, cargo, po, otherBill, exp, esc(r.lane || ''), jobTag].filter(Boolean).join('  ·  ');
  c.innerHTML =
    '<div class="r1">' +
      '<span class="mref">' + (primary || '—') + '</span>' + inco +
      '<span class="mwho">' + esc(who || '—') + '</span>' +
      '<span class="mspacer"></span>' + sev + note +
    '</div>' +
    (sub ? '<div class="r2">' + sub + '</div>' : '');
  c.onclick = () => openShipment(r.jobNo);
  return c;
}

// ---------- shipment drawer ----------
async function openShipment(job) {
  $('#drawerBg').classList.add('open'); $('#drawer').classList.add('open');
  $('#dJob').textContent = job; $('#dLane').textContent = ''; $('#drawerBody').innerHTML = '<div class="empty">Loading…</div>';
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
  head.style.marginBottom = '8px'; body.appendChild(head);
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
  if (refBits.length) { const rd = el('div', 'refdocs', refBits.join(' &nbsp;·&nbsp; ')); body.appendChild(rd); }
  const actions = el('div'); actions.style.cssText = 'margin-bottom:10px';
  const rb = el('button', 'ghost', '🔔 Remind me'); rb.style.fontSize = '12px'; rb.onclick = () => remindMe(job);
  actions.appendChild(rb); body.appendChild(actions);

  // milestones
  arr(chk.milestones).forEach(m => body.appendChild(milestoneRow(job, m)));

  // arrangements (who to contact + trucker/broker/warehouse tasks)
  body.appendChild(arrangementsPanel(job, sh, arr(data.notes)));

  // notes (plain notes only — arrangement-kind notes live in the panel above)
  const plain = arr(data.notes).filter(n => n.kind !== 'arrangement');
  const nx = el('div', 'notes');
  nx.appendChild(el('h3', null, '💬 Notes & reminders'));
  nx.appendChild(composer(job, null));
  const list = el('div', 'notelist');
  plain.forEach(n => list.appendChild(noteItem(n)));
  if (!plain.length) list.appendChild(el('div', 'empty', 'No notes yet.'));
  nx.appendChild(list);
  body.appendChild(nx);
}
const ARR_TYPES = [
  { key: 'customer', label: '👤 Customer' },
  { key: 'trucker', label: '🚚 Trucker' },
  { key: 'broker', label: '🛃 Customs broker' },
  { key: 'warehouse', label: '🏭 Warehouse' },
];
function arrPlaceholder(t) { return ({ customer: 'customer contact person', trucker: 'trucker company', broker: 'broker name', warehouse: 'warehouse' })[t] || 'party'; }
function arrangementsPanel(job, sh, notes) {
  const wrap = el('div', 'arrange');
  wrap.appendChild(el('h3', null, '📦 Arrangements'));
  const isImport = (sh.bound || 'Import') === 'Import';
  const who = isImport ? sh.consignee_name : sh.shipper_name;
  const bits = [];
  if (sh.cust_contact) bits.push(esc(sh.cust_contact));
  if (sh.cust_phone) bits.push('<a href="tel:' + esc(sh.cust_phone) + '">📞 ' + esc(sh.cust_phone) + '</a>');
  if (sh.cust_email) bits.push('<a href="mailto:' + esc(sh.cust_email) + '">✉ ' + esc(sh.cust_email) + '</a>');
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
    '<input class="ai ment" placeholder="@mention a colleague (optional)">';
  const bar = el('div'); bar.style.cssText = 'display:flex;gap:8px;margin-top:6px';
  const save = el('button', 'primary', 'Save'); const cancel = el('button', 'ghost', 'Cancel');
  bar.appendChild(save); bar.appendChild(cancel); f.appendChild(bar); wrap.appendChild(f);
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
    box.innerHTML = '<h3>🔔 Remind me</h3><p class="modal-msg">A note to yourself about what to follow up on this shipment. Set a date to chase it (optional).</p>';
    const ta = el('textarea'); ta.placeholder = 'e.g. chase trucker to confirm terminal pickup → warehouse'; box.appendChild(ta);
    const drow = el('div', 'modal-date');
    drow.innerHTML = '<span class="muted">Follow up on</span>';
    const date = el('input'); date.type = 'text'; date.placeholder = 'yyyy-mm-dd'; date.maxLength = 10; date.className = 'datebox'; drow.appendChild(date); box.appendChild(drow);
    const bar = el('div', 'modal-bar');
    const cancel = el('button', 'ghost', 'Cancel');
    const ok = el('button', 'primary', '🔔 Set reminder');
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
    items = state.roster.filter(u => u.toLowerCase().includes(q)).slice(0, 8);
    if (!items.length) return close();
    pop.innerHTML = ''; items.forEach((u, i) => { const d = el('div', i === 0 ? 'sel' : '', esc(u)); d.onclick = () => pick(u); pop.appendChild(d); });
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
  const assigned = arr(data.assigned), mine = arr(data.mine), today = data.today || '';
  const n = (data.assignedOpen || assigned.length) + (data.dueNow || 0);   // from others + my due/overdue
  ['#taskBadge', '#taskBadge2'].forEach(s => { const b = $(s); if (n > 0) { b.textContent = n; b.style.display = ''; } else b.style.display = 'none'; });
  const body = $('#tasksBody'); body.innerHTML = '';
  body.appendChild(el('div', 'muted', '🔔 Reminders from others'));
  if (!assigned.length) body.appendChild(el('div', 'empty', 'Nothing waiting on you.'));
  assigned.forEach(t => body.appendChild(taskCard(t, true, today)));
  const h = el('div', 'muted', '📌 My follow-ups'); h.style.marginTop = '10px'; body.appendChild(h);
  if (!mine.length) body.appendChild(el('div', 'empty', 'No reminders set. Open a shipment → 🔔 Remind me.'));
  mine.forEach(t => body.appendChild(taskCard(t, false, today)));
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

init();
