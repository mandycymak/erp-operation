// erp-edit.js - staff-internal ERP data correction editor, laid out like a House Bill.
// Opened from the worklist drawer as erp-edit.html?job=<job_no>. Each party is a bill box: the master code is a
// short editable chip (SHIPPER (A0001)) you can click to search/fix; name/address edit in the box; tel/tax sit
// with the party but are flagged "not printed". Liner agent + controlling customer go in a sidebar (internal,
// never on the bill). Containers use a table. Only the changed fields are sent to /booking/update. The client
// sends the FULL seeded field set overlaid with edits, so a field never touched is never seen as cleared.
'use strict';
(function () {
  const $ = s => document.querySelector(s);
  const esc = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);
  const strv = v => ('' + (v == null ? '' : v));
  const norm = v => (typeof v === 'string' || v == null) ? strv(v) : JSON.stringify(v);
  const job = (new URLSearchParams(location.search).get('job') || '').trim();

  let SEED = {}, DICT = [], RESOLVED = {};

  // party grouping (the Parties section codes are <party>_<role>)
  const PARTIES = ['shipper', 'consignee', 'notify', 'agent', 'liner', 'ctrl'];
  const PLABEL = { shipper: 'Shipper', consignee: 'Consignee', notify: 'Notify party', agent: 'Delivery agent', liner: 'Liner agent', ctrl: 'Controlling customer' };
  const partyOf = code => { for (const p of PARTIES) { if (code === p + '_code' || code.indexOf(p + '_') === 0) return p; } return code; };
  const roleOf = (code, p) => code.slice(p.length + 1);
  const byRole = fields => { const o = {}; fields.forEach(d => { o[roleOf(d.code, partyOf(d.code))] = d; }); return o; };

  async function api(path, body) {
    const opts = { cache: 'no-store', headers: { 'X-Ops-User': localStorage.getItem('opsUser') || '(open)' } };
    if (body) { opts.method = 'POST'; opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const r = await fetch(path, opts);
    if (r.status === 401) { location.href = 'login.html'; return new Promise(() => {}); }
    return r.json();
  }
  const fail = m => { $('#msg').innerHTML = '<div class="err">' + esc(m) + '</div>'; };

  async function load() {
    if (!job) { fail('No shipment specified.'); $('#sections').innerHTML = ''; return; }
    const d = await api('/api-ops/erp-edit?job=' + encodeURIComponent(job));
    if (d.error) { $('#sections').innerHTML = ''; fail(d.error); $('#status').textContent = 'error'; return; }
    SEED = d.fields || {}; DICT = arr(d.dict); RESOLVED = d.resolved || {};
    $('#status').textContent = (d.mode || '') + ' ' + (d.bound || '');
    $('#sub').textContent = 'Job ' + job;
    render();
  }

  function wireChange(inp, code, after) {
    inp.addEventListener('input', () => {
      if (norm(SEED[code]) !== norm(inp.value)) inp.classList.add('chg'); else inp.classList.remove('chg');
      if (after) after();
    });
  }
  function textInput(def, multiline) {
    const i = multiline ? el('textarea') : (() => { const x = el('input'); x.type = 'text'; return x; })();
    i.dataset.code = def.code; i.value = strv(SEED[def.code]); i.placeholder = def.label; i.spellcheck = false;
    if (!def.writeKey) i.disabled = true;
    wireChange(i, def.code);
    return i;
  }
  // the short editable master-code chip + magnifier that opens a search popup
  function codeChip(def, hintEl) {
    const wrap = el('span', 'codechip lookup');
    const inp = el('input'); inp.type = 'text'; inp.dataset.code = def.code; inp.value = strv(SEED[def.code]); inp.spellcheck = false;
    if (!def.writeKey) inp.disabled = true;
    wireChange(inp, def.code, () => { if (hintEl) hintEl.textContent = ''; });   // typing a code clears the old resolved name
    wrap.appendChild(inp);
    if (def.writeKey && def.lookup) { const fb = el('button', 'findbtn', '🔍'); fb.type = 'button'; fb.title = 'Search the master'; fb.onclick = () => openLookup(def, wrap, inp, hintEl); wrap.appendChild(fb); }
    return wrap;
  }
  function rhint(code) { const h = el('div', 'rhint'); h.textContent = RESOLVED[code] ? ('→ ' + RESOLVED[code]) : ''; return h; }

  function partyBox(p, info) {
    const box = el('div', 'pbox');
    const f = byRole(info.fields);
    const lab = el('div', 'plabel'); lab.appendChild(document.createTextNode(PLABEL[p]));
    let hint = null;
    if (f.code) { hint = rhint(f.code.code); lab.appendChild(codeChip(f.code, hint)); }
    box.appendChild(lab);
    if (hint) box.appendChild(hint);
    if (f.name) { const d = el('div', 'pname'); d.appendChild(textInput(f.name)); box.appendChild(d); }
    if (f.address) { const d = el('div', 'paddr'); d.appendChild(textInput(f.address, true)); box.appendChild(d); }
    const extras = [f.phone, f.tax].filter(Boolean);
    if (extras.length) box.appendChild(extraBlock(extras));
    return box;
  }
  function extraBlock(defs) {
    const wrap = el('div', 'extra');
    const h = el('div', 'xh'); h.appendChild(document.createTextNode('Additional')); h.appendChild(el('span', 'tag', 'not printed')); wrap.appendChild(h);
    const row = el('div', 'xrow');
    defs.forEach(d => { const c = el('div', 'xcell'); c.appendChild(el('label', null, esc(d.label))); c.appendChild(textInput(d)); row.appendChild(c); });
    wrap.appendChild(row);
    return wrap;
  }
  function internalBox(p, info) {
    const box = el('div', 'ibox');
    const f = byRole(info.fields);
    const lab = el('div', 'plabel'); lab.appendChild(document.createTextNode(PLABEL[p]));
    let hint = null;
    if (f.code) { hint = rhint(f.code.code); lab.appendChild(codeChip(f.code, hint)); }
    box.appendChild(lab);
    if (hint) box.appendChild(hint);
    return box;
  }
  function refStrip(defs) {
    const card = el('div', 'refcard'); card.appendChild(el('h3', null, 'Bill references'));
    const grid = el('div', 'refgrid');
    defs.forEach(d => {
      const chip = el('div', 'refchip');
      chip.appendChild(el('label', null, esc(d.label)));
      const rc = el('div', 'rc lookup');
      const inp = el('input'); inp.type = 'text'; inp.dataset.code = d.code; inp.value = strv(SEED[d.code]); inp.spellcheck = false;
      if (!d.writeKey) inp.disabled = true;
      const hint = rhint(d.code);
      wireChange(inp, d.code, () => { hint.textContent = ''; });
      rc.appendChild(inp);
      if (d.writeKey && d.lookup) { const fb = el('button', 'findbtn', '🔍'); fb.type = 'button'; fb.title = 'Search the master'; fb.onclick = () => openLookup(d, rc, inp, hint); rc.appendChild(fb); }
      chip.appendChild(rc); chip.appendChild(hint); grid.appendChild(chip);
    });
    card.appendChild(grid);
    return card;
  }
  function cargoCard(def) {
    const card = el('div', 'cargocard'); card.appendChild(el('h3', null, 'Containers'));
    card.appendChild(containerTable(def));
    return card;
  }
  function containerTable(def) {
    const wrap = el('div');
    const tab = el('table', 'ctab'); tab._def = def;
    const hr = el('tr'); def.columns.forEach(c => hr.appendChild(el('th', null, esc(c.label)))); hr.appendChild(el('th', null, ''));
    const th = el('thead'); th.appendChild(hr); tab.appendChild(th);
    const tb = el('tbody'); tab.appendChild(tb);
    const rows = arr(SEED[def.code]);
    (rows.length ? rows : [{}]).forEach(r => tb.appendChild(contRow(def, r)));
    wrap.appendChild(tab);
    const add = el('button', '', '+ Add row'); add.type = 'button'; add.style.cssText = 'font-size:12px;padding:4px 9px;margin-top:6px';
    add.onclick = () => tb.appendChild(contRow(def, {}));
    wrap.appendChild(add);
    return wrap;
  }
  function contRow(def, r) {
    const tr = el('tr');
    def.columns.forEach(c => { const td = el('td'); const i = el('input'); i.type = 'text'; i.dataset.col = c.code; i.value = strv(r[c.code]); td.appendChild(i); tr.appendChild(td); });
    const td = el('td'); const x = el('button', '', '×'); x.type = 'button'; x.title = 'Remove row'; x.style.cssText = 'font-size:12px;padding:2px 8px'; x.onclick = () => tr.remove(); td.appendChild(x); tr.appendChild(td);
    return tr;
  }

  function openLookup(def, anchorEl, inp, hintEl) {
    const ex = anchorEl.querySelector('.lookbox'); if (ex) { ex.remove(); return; }   // toggle
    const box = el('div', 'lookbox');
    const q = el('input', 'lq'); q.type = 'text'; q.placeholder = 'code or name...'; q.spellcheck = false; box.appendChild(q);
    const list = el('div'); box.appendChild(list);
    anchorEl.appendChild(box); q.focus();
    let t = null;
    const run = async () => {
      list.innerHTML = '<div class="li note">searching...</div>';
      const d = await api('/api-ops/erp-master?job=' + encodeURIComponent(job) + '&kind=' + encodeURIComponent(def.lookup) + '&q=' + encodeURIComponent(q.value.trim()));
      list.innerHTML = '';
      if (d.error) { list.innerHTML = '<div class="li note">' + esc(d.error) + '</div>'; return; }
      const res = arr(d.results);
      if (!res.length) { list.innerHTML = '<div class="li note">no matches</div>'; return; }
      res.forEach(r => {
        const li = el('div', 'li', '<b>' + esc(r.code) + '</b> ' + esc(r.name || ''));
        li.onclick = () => {
          inp.value = r.code;
          if (norm(SEED[def.code]) !== norm(r.code)) inp.classList.add('chg'); else inp.classList.remove('chg');
          if (hintEl) hintEl.textContent = r.name ? ('→ ' + r.name) : '';
          box.remove();
        };
        list.appendChild(li);
      });
    };
    q.oninput = () => { clearTimeout(t); t = setTimeout(run, 220); };
    run();
    setTimeout(() => { document.addEventListener('click', function h(e) { if (!anchorEl.contains(e.target)) { box.remove(); document.removeEventListener('click', h); } }); }, 0);
  }

  function render() {
    const root = $('#sections'); root.innerHTML = '';
    const parties = {}, routing = [], cargo = [];
    DICT.forEach(d => {
      const s = d.section || '';
      if (s.indexOf('Cargo') >= 0) cargo.push(d);
      else if (s.indexOf('Routing') >= 0) routing.push(d);
      else { const p = partyOf(d.code); (parties[p] || (parties[p] = { internal: !!d.internal, fields: [] })).fields.push(d); }
    });
    const billwrap = el('div', 'billwrap');
    const bill = el('div', 'bill'); const side = el('div', 'side');
    ['shipper', 'consignee', 'notify', 'agent'].forEach(p => { if (parties[p]) bill.appendChild(partyBox(p, parties[p])); });
    if (routing.length) bill.appendChild(refStrip(routing));
    cargo.forEach(d => bill.appendChild(cargoCard(d)));
    let anyInternal = false;
    side.appendChild(el('div', 'sidehead', 'Internal - not printed on the bill'));
    ['liner', 'ctrl'].forEach(p => { if (parties[p]) { anyInternal = true; side.appendChild(internalBox(p, parties[p])); } });
    side.appendChild(el('div', 'sidenote', 'These identify the shipment for reporting and accounting. They are corrected here but never appear on the customer’s House Bill.'));
    billwrap.appendChild(bill);
    if (anyInternal) billwrap.appendChild(side);
    root.appendChild(billwrap);
  }

  function collect() {
    const out = JSON.parse(JSON.stringify(SEED || {}));   // keep untouched/hidden fields at their seeded value
    document.querySelectorAll('#sections input[data-code], #sections textarea[data-code]').forEach(i => { out[i.dataset.code] = i.value; });
    document.querySelectorAll('#sections table.ctab').forEach(tab => {
      const def = tab._def; const rows = [];
      tab.querySelectorAll('tbody tr').forEach(tr => {
        const row = {}; let any = false;
        tr.querySelectorAll('input[data-col]').forEach(i => { row[i.dataset.col] = i.value; if (i.value.trim()) any = true; });
        if (any) rows.push(row);
      });
      out[def.code] = rows;
    });
    return out;
  }

  async function save() {
    const btn = $('#saveBtn'); const old = btn.textContent; btn.disabled = true; btn.textContent = 'Saving...';
    $('#msg').innerHTML = '';
    let r; try { r = await api('/api-ops/erp-edit-save', { job_no: job, fields: collect() }); } catch (e) { r = { error: 'network error' }; }
    btn.disabled = false; btn.textContent = old;
    if (r.error) { fail(r.error); return; }
    const erp = r.erp || {}; const changed = (r.changed || []).join(', ');
    const okClass = (erp.ok && !erp.rejected) ? 'ok' : 'err';
    const head = erp.mock ? ('Saved (MOCK - nothing sent to the live ERP). Changed: ' + changed)
      : erp.rejected ? ('Sent, but the ERP rejected the update (recorded in the audit log). Changed: ' + changed)
      : erp.ok ? ('Saved to the ERP. Changed: ' + changed)
      : ('Save failed. ' + (erp.error || ''));
    let html = '<div class="' + okClass + '">' + esc(head) + '</div>';
    if (arr(erp.steps).length || erp.error) html += '<div class="steps">' + esc(arr(erp.steps).join('\n') + (erp.error ? ('\n' + erp.error) : '')) + '</div>';
    $('#msg').innerHTML = html;
    await load();   // re-seed: the new values become the baseline, resolved names refresh
  }

  $('#saveBtn').onclick = save;
  $('#hideBtn').onclick = () => { document.body.classList.toggle('hidenp'); $('#hideBtn').classList.toggle('on'); };
  load();
})();
