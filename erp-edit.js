// erp-edit.js - staff-internal ERP data correction editor (session-gated /api-ops/erp-edit* endpoints).
// Opened from the worklist drawer as erp-edit.html?job=<job_no>. Shows each shipment's current ERP master
// codes + values, lets the operator pick the correct code from the live master (custsub/linermstr/portmstr/
// servmstr) or type a correction, and pushes ONLY the changed fields to /booking/update. The client always
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

  let SEED = {};            // full seeded fields (the authoritative baseline)
  let DICT = [];            // field defs for this shipment's mode
  let RESOLVED = {};        // code field -> current master name
  const shown = new Set();  // field codes currently rendered (default + added optional)

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
    shown.clear();
    $('#status').textContent = (d.mode || '') + ' ' + (d.bound || '');
    $('#sub').textContent = 'Job ' + job;
    render();
  }

  function hasValue(def) { const v = SEED[def.code]; if (def.kind === 'table') return arr(v).length > 0; return strv(v).trim() !== ''; }
  function markChanged(row, code, val) { if (norm(SEED[code]) !== norm(val)) row.classList.add('changed'); else row.classList.remove('changed'); }

  function render() {
    const root = $('#sections'); root.innerHTML = '';
    const order = []; const bySec = {};
    DICT.forEach(d => { if (!bySec[d.section]) { bySec[d.section] = []; order.push(d.section); } bySec[d.section].push(d); });
    order.forEach(sec => {
      const card = el('div', 'card sect'); card.appendChild(el('h2', null, esc(sec)));
      const defs = bySec[sec];
      defs.forEach(def => {
        // optional fields stay hidden until "Add field" picks them - unless the ERP already holds a value there
        if (def.show === 'optional' && !shown.has(def.code) && !hasValue(def)) return;
        shown.add(def.code);
        card.appendChild(fieldRow(def));
      });
      const opt = defs.filter(d => d.show === 'optional' && !shown.has(d.code));
      if (opt.length) {
        const wrap = el('div', 'addfield');
        const sel = el('select'); sel.appendChild(el('option', null, '+ Add field...'));
        opt.forEach(d => { const o = el('option'); o.value = d.code; o.textContent = d.label; sel.appendChild(o); });
        sel.onchange = () => { if (sel.value) { shown.add(sel.value); render(); } };
        wrap.appendChild(sel); card.appendChild(wrap);
      }
      root.appendChild(card);
    });
  }

  function fieldRow(def) {
    const row = el('div', 'row' + (def.internal ? ' internal' : ''));
    row.appendChild(el('label', null, esc(def.label) +
      (def.internal ? ' <span class="tag">internal</span>' : '') +
      (def.writeKey ? '' : ' <span class="tag">read-only</span>')));
    const ctl = el('div', 'ctl'); row.appendChild(ctl);
    if (def.kind === 'table') { ctl.appendChild(containerTable(def)); return row; }
    if (def.kind === 'code') { ctl.appendChild(codeField(def, row)); return row; }
    const inp = def.multiline ? el('textarea') : (() => { const i = el('input'); i.type = 'text'; return i; })();
    inp.dataset.code = def.code; inp.value = strv(SEED[def.code]);
    if (!def.writeKey) inp.disabled = true;
    inp.oninput = () => markChanged(row, def.code, inp.value);
    ctl.appendChild(inp);
    return row;
  }

  function codeField(def, row) {
    const wrap = el('div', 'lookup');
    const cw = el('div', 'codewrap');
    const inp = el('input'); inp.type = 'text'; inp.dataset.code = def.code; inp.value = strv(SEED[def.code]);
    if (!def.writeKey) inp.disabled = true;
    cw.appendChild(inp);
    const findBtn = el('button', 'ghost', 'Find'); findBtn.type = 'button';
    if (def.writeKey) cw.appendChild(findBtn);
    wrap.appendChild(cw);
    const hint = el('div', 'hint'); hint.textContent = RESOLVED[def.code] ? ('→ ' + RESOLVED[def.code]) : '';
    wrap.appendChild(hint);
    inp.oninput = () => { markChanged(row, def.code, inp.value); hint.textContent = ''; };  // name unknown until picked/re-seeded
    findBtn.onclick = () => openLookup(def, wrap, inp, hint, row);
    return wrap;
  }

  function openLookup(def, wrap, inp, hint, row) {
    const ex = wrap.querySelector('.lookbox'); if (ex) { ex.remove(); return; }   // toggle
    const box = el('div', 'lookbox');
    const q = el('input'); q.type = 'text'; q.placeholder = 'type a code or name...';
    q.style.cssText = 'width:100%;border:0;border-bottom:1px solid var(--line);border-radius:6px 6px 0 0';
    box.appendChild(q);
    const list = el('div'); box.appendChild(list);
    wrap.appendChild(box); q.focus();
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
        li.onclick = () => { inp.value = r.code; hint.textContent = r.name ? ('→ ' + r.name) : ''; markChanged(row, def.code, r.code); box.remove(); };
        list.appendChild(li);
      });
    };
    q.oninput = () => { clearTimeout(t); t = setTimeout(run, 220); };
    run();   // initial fill (incoterm = full fixed list; masters = broad match)
    setTimeout(() => { document.addEventListener('click', function h(e) { if (!wrap.contains(e.target)) { box.remove(); document.removeEventListener('click', h); } }); }, 0);
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
    const add = el('button', 'ghost', '+ Add row'); add.type = 'button'; add.style.marginTop = '6px';
    add.onclick = () => tb.appendChild(contRow(def, {}));
    wrap.appendChild(add);
    return wrap;
  }
  function contRow(def, r) {
    const tr = el('tr');
    def.columns.forEach(c => { const td = el('td'); const i = el('input'); i.type = 'text'; i.dataset.col = c.code; i.value = strv(r[c.code]); td.appendChild(i); tr.appendChild(td); });
    const td = el('td'); const x = el('button', 'ghost', '×'); x.type = 'button'; x.title = 'Remove row'; x.onclick = () => tr.remove(); td.appendChild(x); tr.appendChild(td);
    return tr;
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
  load();
})();
