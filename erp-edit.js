// erp-edit.js - staff-internal ERP data correction editor, laid out like the House Bill / Air Waybill.
// Opened from the worklist drawer as erp-edit.html?job=<job_no>. Boxes sit in their bill positions; each master
// code is a short chip IN the caption - SHIPPER ( DUMMY ) - that you click (🔍) to search/fix, or type. Party
// name/address/tel/tax edit in the box. The B/L-No box lists the reference numbers; the Export-References box
// holds controlling-customer + liner-agent (internal, not printed); the Originals box shows telex release.
// Only the changed fields are sent to /booking/update; the client sends the FULL seeded set overlaid with edits.
'use strict';
(function () {
  const $ = s => document.querySelector(s);
  const esc = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);
  const strv = v => ('' + (v == null ? '' : v));
  const norm = v => (typeof v === 'string' || v == null) ? strv(v) : JSON.stringify(v);
  const job = (new URLSearchParams(location.search).get('job') || '').trim();

  let SEED = {}, DICT = [], RESOLVED = {}, DEF = {}, MODE = 'Sea';
  const PLABEL = { shipper: 'Shipper', consignee: 'Consignee', notify: 'Notify party', agent: 'Delivery agent', liner: 'Liner agent', ctrl: 'Controlling customer' };

  // bill-grid templates (w = columns out of 12). Cells reference field codes from the dictionary.
  const GRID = {
    Sea: [
      [{ box: 'party', code: 'shipper', cap: 'Shipper', w: 6 }, { box: 'refs', cap: 'B/L No.', codes: ['bl_no', 'booking_no', 'po_no', 'job_disp', 'master_no'], w: 3 }, { box: 'originals', cap: 'No. of Original B(s)/L', w: 3 }],
      [{ box: 'party', code: 'consignee', cap: 'Consignee', w: 6 }, { box: 'internal', cap: 'Export References', w: 6 }],
      [{ box: 'party', code: 'notify', cap: 'Notify Party', w: 6 }, { box: 'party', code: 'agent', cap: 'Delivery Agent', w: 6 }],
      [{ box: 'chip', code: 'pol_code', cap: 'Port of Loading', w: 3 }, { box: 'chip', code: 'pod_code', cap: 'Port of Discharge', w: 3 }, { box: 'chip', code: 'incoterm', cap: 'Incoterm', w: 3 }, { box: 'chip', code: 'service_code', cap: 'Service Type', w: 3 }],
      [{ box: 'containers', code: 'containers', cap: 'Container Particulars', w: 12 }]
    ],
    Air: [
      [{ box: 'party', code: 'shipper', cap: "Shipper's Name and Address", w: 6 }, { box: 'refs', cap: 'AWB / Ref. No.', codes: ['bl_no', 'master_no', 'booking_no', 'po_no', 'job_disp'], w: 3 }, { box: 'chip', code: 'service_code', cap: 'Service Type', w: 3 }],
      [{ box: 'party', code: 'consignee', cap: "Consignee's Name and Address", w: 6 }, { box: 'internal', cap: 'Accounting / Internal', w: 6 }],
      [{ box: 'party', code: 'notify', cap: 'Notify Party', w: 6 }, { box: 'party', code: 'agent', cap: 'Delivery Agent', w: 6 }],
      [{ box: 'chip', code: 'pol_code', cap: 'Airport of Departure', w: 4 }, { box: 'chip', code: 'pod_code', cap: 'Airport of Destination', w: 4 }, { box: 'chip', code: 'incoterm', cap: 'Incoterm (Routing)', w: 4 }]
    ]
  };

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
    SEED = d.fields || {}; DICT = arr(d.dict); RESOLVED = d.resolved || {}; MODE = (d.mode === 'Air') ? 'Air' : 'Sea';
    DEF = {}; DICT.forEach(x => DEF[x.code] = x);
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
  // the short editable master-code chip "( CODE ) 🔍"; hintEl shows the resolved master name and clears on typing
  function codeChip(def, hintEl) {
    const wrap = el('span', 'codechip lookup');
    wrap.appendChild(document.createTextNode('('));
    const inp = el('input'); inp.type = 'text'; inp.dataset.code = def.code; inp.value = strv(SEED[def.code]); inp.spellcheck = false;
    if (!def.writeKey) inp.disabled = true;
    wireChange(inp, def.code, () => { if (hintEl) hintEl.textContent = ''; });
    wrap.appendChild(inp);
    wrap.appendChild(document.createTextNode(')'));
    if (def.writeKey && def.lookup) { const fb = el('button', 'findbtn', '🔍'); fb.type = 'button'; fb.title = 'Search the master'; fb.onclick = () => openLookup(def, wrap, inp, hintEl); wrap.appendChild(fb); }
    return wrap;
  }
  function pInput(def, multiline) {
    const i = multiline ? el('textarea', 'pin') : (() => { const x = el('input', 'pin'); x.type = 'text'; return x; })();
    i.dataset.code = def.code; i.value = strv(SEED[def.code]); i.placeholder = def.label; i.spellcheck = false;
    if (!def.writeKey) i.disabled = true;
    wireChange(i, def.code);
    return i;
  }

  // --- cell renderers ---
  function partyCell(box, prefix, capText) {
    const codeDef = DEF[prefix + '_code'];
    const hint = el('div', 'rhint');
    if (codeDef) hint.textContent = RESOLVED[codeDef.code] ? ('master: ' + RESOLVED[codeDef.code]) : '';
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText));
    if (codeDef) cap.appendChild(codeChip(codeDef, hint));
    box.appendChild(cap); box.appendChild(hint);
    if (DEF[prefix + '_name']) box.appendChild(pInput(DEF[prefix + '_name']));
    if (DEF[prefix + '_address']) box.appendChild(pInput(DEF[prefix + '_address'], true));
    const ex = [DEF[prefix + '_phone'], DEF[prefix + '_tax']].filter(Boolean);
    if (ex.length) {
      const row = el('div', 'telrow np');
      ex.forEach(d => { const c = el('div', 'telcell'); c.appendChild(el('span', 'tl', esc(d.label) + ' (not printed)')); c.appendChild(pInput(d)); row.appendChild(c); });
      box.appendChild(row);
    }
  }
  function chipCell(box, code, capText) {
    const def = DEF[code]; if (!def) return;
    const val = el('div', 'boxval'); val.textContent = RESOLVED[code] || (def.lookup === 'incoterm' ? '' : '');
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText)); cap.appendChild(codeChip(def, val));
    box.appendChild(cap); box.appendChild(val);
  }
  function refsCell(box, capText, codes) {
    box.appendChild(el('div', 'cap', esc(capText)));
    let any = false;
    codes.forEach(c => { const d = DEF[c]; if (!d) return; const v = strv(SEED[c]).trim(); if (!v) return; any = true; const line = el('div', 'refline'); line.innerHTML = '<span class="rl">' + esc(d.label) + ':</span> ' + esc(v); box.appendChild(line); });
    if (!any) box.appendChild(el('div', 'refline muted', '-'));
  }
  function originalsCell(box, capText) {
    box.appendChild(el('div', 'cap', esc(capText)));
    const telex = /^(true|1|y)/i.test(strv(SEED['telex_release']));
    const no = strv(SEED['num_originals']).trim();
    box.appendChild(el('div', 'refline', (telex ? '☑' : '☐') + ' Telex release'));
    box.appendChild(el('div', 'refline', '<span class="rl">Originals:</span> ' + esc(telex ? '0 (telex)' : (no || '-'))));
  }
  function internalCell(box, capText) {
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText)); cap.appendChild(el('span', 'tag', 'not printed'));
    box.appendChild(cap);
    const inner = el('div', 'np');
    ['ctrl', 'liner'].forEach(p => {
      const d = DEF[p + '_code']; if (!d) return;
      const mini = el('div', 'minip');
      const lab = el('div', 'minilab'); lab.appendChild(document.createTextNode(PLABEL[p]));
      const nm = el('div', 'rhint'); nm.textContent = RESOLVED[d.code] ? ('→ ' + RESOLVED[d.code]) : '';
      lab.appendChild(codeChip(d, nm));
      mini.appendChild(lab); mini.appendChild(nm);
      inner.appendChild(mini);
    });
    box.appendChild(inner);
  }
  function containersCell(box, code, capText) {
    const def = DEF[code]; box.appendChild(el('div', 'cap', esc(capText)));
    if (!def) return;
    const tab = el('table', 'ctab'); tab._def = def;
    const hr = el('tr'); def.columns.forEach(c => hr.appendChild(el('th', null, esc(c.label)))); hr.appendChild(el('th', null, ''));
    const th = el('thead'); th.appendChild(hr); tab.appendChild(th);
    const tb = el('tbody'); tab.appendChild(tb);
    const rows = arr(SEED[code]);
    (rows.length ? rows : [{}]).forEach(r => tb.appendChild(contRow(def, r)));
    box.appendChild(tab);
    const add = el('button', '', '+ Add row'); add.type = 'button'; add.style.cssText = 'font-size:12px;padding:4px 9px;margin-top:6px';
    add.onclick = () => tb.appendChild(contRow(def, {}));
    box.appendChild(add);
  }
  function contRow(def, r) {
    const tr = el('tr');
    def.columns.forEach(c => { const td = el('td'); const i = el('input'); i.type = 'text'; i.dataset.col = c.code; i.value = strv(r[c.code]); td.appendChild(i); tr.appendChild(td); });
    const td = el('td'); const x = el('button', '', '×'); x.type = 'button'; x.title = 'Remove row'; x.style.cssText = 'font-size:12px;padding:2px 8px'; x.onclick = () => tr.remove(); td.appendChild(x); tr.appendChild(td);
    return tr;
  }

  function openLookup(def, anchorEl, inp, hintEl) {
    const ex = anchorEl.querySelector('.lookbox'); if (ex) { ex.remove(); return; }
    const box = el('div', 'lookbox');
    const q = el('input', 'lq'); q.type = 'text'; q.placeholder = 'code or name...'; q.spellcheck = false; box.appendChild(q);
    const list = el('div'); box.appendChild(list);
    anchorEl.appendChild(box); q.focus();
    let t = null;
    const run = async () => {
      list.innerHTML = '<div class="li">searching...</div>';
      const d = await api('/api-ops/erp-master?job=' + encodeURIComponent(job) + '&kind=' + encodeURIComponent(def.lookup) + '&q=' + encodeURIComponent(q.value.trim()));
      list.innerHTML = '';
      if (d.error) { list.innerHTML = '<div class="li">' + esc(d.error) + '</div>'; return; }
      const res = arr(d.results);
      if (!res.length) { list.innerHTML = '<div class="li">no matches</div>'; return; }
      res.forEach(r => {
        const li = el('div', 'li', '<b>' + esc(r.code) + '</b> ' + esc(r.name || ''));
        li.onclick = () => {
          inp.value = r.code;
          if (norm(SEED[def.code]) !== norm(r.code)) inp.classList.add('chg'); else inp.classList.remove('chg');
          if (hintEl) hintEl.textContent = r.name ? ((hintEl.className.indexOf('boxval') >= 0 ? '' : '→ ') + r.name) : '';
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
    root.appendChild(el('div', 'billtitle', MODE === 'Air' ? 'HOUSE AIR WAYBILL - ERP DATA' : 'HOUSE BILL OF LADING - ERP DATA'));
    const bill = el('div', 'gbill');
    (GRID[MODE] || GRID.Sea).forEach(rowSpec => {
      const row = el('div', 'grow');
      rowSpec.forEach(cell => {
        const box = el('div', 'gbox'); const pct = (cell.w / 12 * 100); box.style.flex = '0 0 ' + pct + '%'; box.style.maxWidth = pct + '%';
        if (cell.box === 'party') partyCell(box, cell.code, cell.cap);
        else if (cell.box === 'chip') chipCell(box, cell.code, cell.cap);
        else if (cell.box === 'refs') refsCell(box, cell.cap, cell.codes);
        else if (cell.box === 'originals') originalsCell(box, cell.cap);
        else if (cell.box === 'internal') internalCell(box, cell.cap);
        else if (cell.box === 'containers') containersCell(box, cell.code, cell.cap);
        row.appendChild(box);
      });
      bill.appendChild(row);
    });
    root.appendChild(bill);
    root.appendChild(extraSections());
  }

  // Space beneath the bill for additional, non-bill sections. Billing is planned but not yet wired (the ERP
  // charge tables + Swivel billing endpoint are not yet mapped), so it shows as a disabled preview for now.
  function extraSections() {
    const wrap = el('div', 'extra-sect');
    const add = el('button', '', '＋ Add section'); add.type = 'button';
    const card = el('div', 'seccard'); card.style.display = 'none';
    card.innerHTML = '<b>Billing &amp; charges</b> — planned. Charge lines (code · description · amount · currency) will be ' +
      'editable here once the ERP charge tables and the Swivel billing endpoint are mapped. Not available yet.';
    add.onclick = () => { card.style.display = card.style.display === 'none' ? 'block' : 'none'; };
    wrap.appendChild(add); wrap.appendChild(card);
    return wrap;
  }

  function collect() {
    const out = JSON.parse(JSON.stringify(SEED || {}));   // keep untouched/display fields at their seeded value
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
    await load();
  }

  $('#saveBtn').onclick = save;
  $('#hideBtn').onclick = () => { document.body.classList.toggle('hidenp'); $('#hideBtn').classList.toggle('on'); };
  load();
})();
