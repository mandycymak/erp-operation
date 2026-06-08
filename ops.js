// Control Tower client. Vanilla JS, no build step. Mirrors the dashboard's robustness patterns:
// arr() coercion (PS 5.1 ConvertTo-Json mangles 0/1-row arrays), cache:'no-store', X-Ops-User identity.
'use strict';
const $ = s => document.querySelector(s);
const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
const esc = s => ('' + (s ?? '')).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);   // coerce PS single/empty -> array

const state = { user: localStorage.getItem('opsUser') || '', roster: [], lens: 'mine', teammate: '' };

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
  try { const c = await api('/api-ops/config'); $('#appName').textContent = c.appName || 'Control Tower'; $('#appSub').textContent = c.appSubtitle || ''; document.title = c.appName || 'Control Tower'; } catch (e) {}
  const rost = await api('/api-ops/roster'); state.roster = arr(rost.users).map(u => u.username);
  if (!state.user && state.roster.length) state.user = state.roster[0];
  buildUserPicker(); buildTeammate();
  wireLens();
  $('#refreshBtn').onclick = refreshAll;
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
function wireLens() {
  document.querySelectorAll('#lensSeg button').forEach(b => b.onclick = () => {
    document.querySelectorAll('#lensSeg button').forEach(x => x.classList.remove('on'));
    b.classList.add('on'); state.lens = b.dataset.lens;
    $('#teammate').style.display = state.lens === 'user' ? '' : 'none';
    loadWorklist();
  });
}
function refreshAll() { loadWorklist(); loadTasks(); }

// ---------- worklist ----------
async function loadWorklist() {
  const wl = $('#worklist'); wl.innerHTML = '<div class="empty">Loading…</div>';
  let q = '/api-ops/worklist?lens=' + encodeURIComponent(state.lens);
  if (state.lens === 'user') q += '&user=' + encodeURIComponent(state.teammate || state.user);
  const data = await api(q);
  const rows = arr(data.rows);
  $('#wlCount').textContent = rows.length + ' shipment' + (rows.length === 1 ? '' : 's');
  if (!rows.length) { wl.innerHTML = '<div class="empty">No shipments for this lens.</div>'; return; }
  // bucket: Critical = Red; This Week = Amber or open notes; Monitor = the rest
  const crit = rows.filter(r => r.worst === 'R');
  const week = rows.filter(r => r.worst === 'A' || (r.worst !== 'R' && r.hasNotes));
  const mon = rows.filter(r => r.worst !== 'R' && !(r.worst === 'A' || r.hasNotes));
  wl.innerHTML = '';
  wl.appendChild(bucket('🔴 Today / Critical', crit));
  wl.appendChild(bucket('🟠 This Week', week));
  wl.appendChild(bucket('🗂 Monitor', mon));
}
function bucket(title, rows) {
  const b = el('div', 'bucket');
  b.appendChild(el('div', 'bh', esc(title) + ' <span class="cnt">' + rows.length + '</span>'));
  if (!rows.length) { b.appendChild(el('div', 'empty', 'Nothing here.')); return b; }
  rows.forEach(r => b.appendChild(card(r)));
  return b;
}
function card(r) {
  const c = el('div', 'card ' + r.worst);
  const noteInd = r.hasNotes ? '<span class="note-ind">💬 notes</span>' : '';
  c.innerHTML =
    '<div class="top"><span class="job">' + esc(r.jobNo) + '</span>' +
    '<span class="pill ' + r.worst + '"><span class="dot ' + r.worst + '"></span>' + (r.openRed ? r.openRed + 'R ' : '') + (r.openAmber ? r.openAmber + 'A' : (r.worst === 'G' ? 'on track' : '')) + '</span>' +
    noteInd + '</div>' +
    '<div class="lane">' + esc(r.bound) + ' · ' + esc(r.cargoType || '—') + ' · ' + esc(r.lane) + '</div>' +
    '<div class="meta"><span>PIC ' + esc(r.picUser || '—') + '</span><span>carrier ' + esc(r.carrier || '—') + '</span>' +
    (r.nextDue ? '<span>next due ' + esc(r.nextDue) + '</span>' : '') + (r.etd ? '<span>ETD ' + esc(r.etd) + '</span>' : '') + '</div>';
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

  // milestones
  arr(chk.milestones).forEach(m => body.appendChild(milestoneRow(job, m)));

  // notes
  const nx = el('div', 'notes');
  nx.appendChild(el('h3', null, '💬 Notes & reminders'));
  nx.appendChild(composer(job, null));
  const list = el('div', 'notelist');
  arr(data.notes).forEach(n => list.appendChild(noteItem(n)));
  if (!arr(data.notes).length) list.appendChild(el('div', 'empty', 'No notes yet.'));
  nx.appendChild(list);
  body.appendChild(nx);
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
async function promptBypass(job, code, name) {
  const reason = prompt('Tick & Confirm "' + code + ' ' + name + '" complete.\nReason (e.g. filed via portal, hard-copy received):', '');
  if (reason === null) return;
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
  const assigned = arr(data.assigned), mine = arr(data.mine);
  const n = data.assignedOpen || assigned.length;
  ['#taskBadge', '#taskBadge2'].forEach(s => { const b = $(s); if (n > 0) { b.textContent = n; b.style.display = ''; } else b.style.display = 'none'; });
  const body = $('#tasksBody'); body.innerHTML = '';
  body.appendChild(el('div', 'muted', 'Assigned to me'));
  if (!assigned.length) body.appendChild(el('div', 'empty', 'Nothing waiting on you.'));
  assigned.forEach(t => body.appendChild(taskCard(t, true)));
  body.appendChild(el('div', 'muted', 'Raised by me')); body.lastChild.style.marginTop = '8px';
  if (!mine.length) body.appendChild(el('div', 'empty', "You haven't raised any."));
  mine.forEach(t => body.appendChild(taskCard(t, false)));
}
function taskCard(t, ack) {
  const d = el('div', 'task');
  const kindTag = (t.kind && t.kind !== 'note') ? '<span class="kind ' + esc(t.kind) + '">' + esc(t.kind) + '</span> ' : '';
  d.innerHTML = '<div class="who">' + kindTag + esc(t.job_no) + ' · from <strong>' + esc(t.user) + '</strong></div><div>' + esc(t.note) + '</div>';
  const row = el('div', 'row');
  const open = el('button', 'ghost', 'Open'); open.onclick = () => openShipment(t.job_no); row.appendChild(open);
  if (ack) { const a = el('button', 'primary', '✓ Acknowledge'); a.onclick = async () => { await api('/api-ops/note-done', { method: 'POST', body: { id: t.id, done: true } }); loadTasks(); }; row.appendChild(a); }
  d.appendChild(row); return d;
}

init();
