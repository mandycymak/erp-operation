// erp-edit.js - staff-internal ERP data correction editor, laid out like the House Bill / Air Waybill.
// Opened from the worklist drawer as erp-edit.html?job=<job_no>. The upper bill is two columns: the parties
// (shipper / consignee / notify / delivery agent) stack on the LEFT; the references + stakeholders, the SERVICE
// DETAIL grid and the INTERNAL REMARK stack on the RIGHT. Each master code is a chip IN the caption -
// SHIPPER ( DUMMY ) - click ... to search/fix it, or type it. Party name + address share one box (line 1 = name).
// Below the bill: the routing row (receipt / loading / discharge / final destination), a one-line Cargo
// Information row, the sea container-size counts, Marks | Description side by side, then the container table.
// Only changed fields are pushed to /booking/update (the client sends the full seeded set overlaid with edits).
'use strict';
(function () {
  const $ = s => document.querySelector(s);
  const esc = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);
  const strv = v => ('' + (v == null ? '' : v));
  const norm = v => (typeof v === 'string' || v == null) ? strv(v) : JSON.stringify(v);
  const isTrue = v => /^(true|1|y)/i.test(strv(v));
  const job = (new URLSearchParams(location.search).get('job') || '').trim();

  let SEED = {}, DICT = [], RESOLVED = {}, DEF = {}, MODE = 'Sea';

  const PARTY = {
    Sea: { shipper: 'Shipper', consignee: 'Consignee', notify: 'Notify Party', agent: 'Delivery Agent' },
    Air: { shipper: "Shipper's Name and Address", consignee: "Consignee's Name and Address", notify: 'Notify Party', agent: 'Delivery Agent' }
  };
  const REFS = {
    Sea: ['bl_no', 'booking_no', 'po_no', 'job_disp', 'master_no', 'vessel_name', 'voyage_no'],
    Air: ['bl_no', 'master_no', 'booking_no', 'po_no', 'job_disp']
  };
  const ROUTING = {
    Sea: [['receipt_code', 'Place of Receipt'], ['pol_code', 'Port of Loading'], ['pod_code', 'Port of Discharge'], ['dest_code', 'Final Destination']],
    Air: [['receipt_code', 'Place of Receipt'], ['pol_code', 'Port of Loading'], ['pod_code', 'Port of Discharge'], ['dest_code', 'Final Destination']]
  };
  // Air IATA flight legs (flight number + that leg's discharge). Leg 1 = main flight/discharge; legs 2-3 push
  // via flexData. Rendered beneath the routing row for Air only.
  const FLIGHTLEGS = [['flight_no', 'to1'], ['flight2', 'deli'], ['flight3', 'to3']];
  // SERVICE DETAIL groups (4-col grid so the rows line up). Codes absent for the mode are skipped silently
  // (telex is Sea-only, direct is Air-only, eta is Sea-only).
  const SVC = [
    ['', ['incoterm', 'service_code', 'telex_release', 'direct', 'dg']],
    ['Shipping window', ['cargo_ready', 'cargo_receipt', 'etd', 'eta', 'flight_time']],
    ['Internal', ['division', 'team', 'pic_id', 'pic_email']]
  ];
  const CARGO = ['commodity', 'cargo_qty', 'cargo_unit', 'cargo_wgt', 'cargo_wunit', 'cargo_cwt', 'cargo_cbm'];
  const CARGOW = { commodity: '2 1 180px', cargo_qty: '0 0 66px', cargo_unit: '0 0 58px', cargo_wgt: '0 0 96px', cargo_wunit: '0 0 58px', cargo_cwt: '0 0 96px', cargo_cbm: '0 0 66px' };
  const CCOUNT = [['container20', "20'"], ['container40', "40'"], ['container_hq', 'HQ'], ['container_other', 'Other']];

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
    if (d.error) { $('#sections').innerHTML = ''; fail(d.error); return; }
    SEED = d.fields || {}; DICT = arr(d.dict); RESOLVED = d.resolved || {}; MODE = (d.mode === 'Air') ? 'Air' : 'Sea';
    DEF = {}; DICT.forEach(x => DEF[x.code] = x);
    $('#status').textContent = ((d.mode || '') + ' ' + (d.bound || '')).trim() || 'Edit ERP data';
    $('#sub').textContent = 'Job ' + job;
    render();
  }

  function wireChange(inp, code, after) {
    inp.addEventListener('input', () => {
      if (norm(SEED[code]) !== norm(inp.value)) inp.classList.add('chg'); else inp.classList.remove('chg');
      if (after) after();
    });
  }
  // standardized master display: "NAME (CODE) - city, country"
  const fmtMaster = r => (((r.name ? r.name + ' ' : '') + '(' + r.code + ')') + (r.loc ? ' - ' + r.loc : '')).trim();

  // the short editable master-code chip "( CODE ) ..."; hintEl shows the resolved master name and clears on typing
  function codeChip(def, hintEl) {
    const wrap = el('span', 'codechip lookup');
    wrap.appendChild(document.createTextNode('('));
    const inp = el('input'); inp.type = 'text'; inp.dataset.code = def.code; inp.value = strv(SEED[def.code]); inp.spellcheck = false;
    if (!def.writeKey) inp.disabled = true;
    wireChange(inp, def.code, () => { if (hintEl) hintEl.textContent = ''; });
    wrap.appendChild(inp);
    wrap.appendChild(document.createTextNode(')'));
    if (def.writeKey && def.lookup) { const fb = el('button', 'findbtn', '...'); fb.type = 'button'; fb.title = 'Search the master'; fb.onclick = () => openLookup(def, wrap, inp, hintEl); wrap.appendChild(fb); }
    return wrap;
  }
  function pInput(def, multiline) {
    const i = multiline ? el('textarea', 'pin') : (() => { const x = el('input', 'pin'); x.type = 'text'; return x; })();
    i.dataset.code = def.code; i.value = strv(SEED[def.code]); i.placeholder = def.label; i.spellcheck = false;
    if (!def.writeKey) i.disabled = true;
    wireChange(i, def.code);
    return i;
  }
  const gbox = (w) => { const b = el('div', 'gbox'); if (w != null) { b.style.flex = '0 0 ' + w + '%'; b.style.maxWidth = w + '%'; } return b; };

  // --- cell renderers ---
  // party: one combined box - first line = company NAME, the rest = ADDRESS (the on-screen bill convention)
  function combineSeed(prefix) {
    const nm = strv(SEED[prefix + '_name']).trim(), ad = strv(SEED[prefix + '_address']).trim();
    return ad ? (nm + '\n' + ad) : nm;
  }
  function partyCell(box, prefix, capText) {
    const codeDef = DEF[prefix + '_code'];
    const hint = el('div', 'rhint');
    if (codeDef) hint.textContent = RESOLVED[codeDef.code] || '';
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText));
    if (codeDef) cap.appendChild(codeChip(codeDef, hint));
    box.appendChild(cap); box.appendChild(hint);
    const nameDef = DEF[prefix + '_name'], addrDef = DEF[prefix + '_address'];
    if (nameDef) {
      const ta = el('textarea', 'pin partybox'); ta.dataset.combine = prefix; ta.spellcheck = false; ta.rows = addrDef ? 3 : 1;
      const sv = combineSeed(prefix); ta.value = sv; ta._seed = sv;
      ta.placeholder = addrDef ? 'Company name\nAddress line 1\nAddress line 2' : 'Company name';
      if (!nameDef.writeKey && (!addrDef || !addrDef.writeKey)) ta.disabled = true;
      ta.addEventListener('input', () => { if (norm(ta._seed) !== norm(ta.value)) ta.classList.add('chg'); else ta.classList.remove('chg'); });
      box.appendChild(ta);
    }
    // contact rows: phone + tax, then contact name + email (each row a two-cell telrow)
    [[prefix + '_phone', prefix + '_tax'], [prefix + '_contact', prefix + '_email']].forEach(codes => {
      const cells = codes.map(c => DEF[c]).filter(Boolean);
      if (!cells.length) return;
      const row = el('div', 'telrow');
      cells.forEach(d => { const c = el('div', 'telcell'); c.appendChild(el('span', 'tl', esc(d.label))); c.appendChild(pInput(d)); row.appendChild(c); });
      box.appendChild(row);
    });
  }
  function chipCell(box, code, capText) {
    const def = DEF[code]; if (!def) return;
    const val = el('div', 'boxval'); val.textContent = RESOLVED[code] || '';
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText)); cap.appendChild(codeChip(def, val));
    box.appendChild(cap); box.appendChild(val);
  }
  // references box: most are read-only; a ref WITH a write key (PO, vessel, voyage, flight) is an editable input
  function refsCell(box, capText, codes) {
    box.appendChild(el('div', 'cap', esc(capText)));
    codes.forEach(c => {
      const d = DEF[c]; if (!d) return;
      if (d.writeKey) {
        const line = el('div', 'refedit'); line.appendChild(el('span', 'rl', esc(d.label) + ': '));
        const i = el('input', 'refin'); i.type = 'text'; i.dataset.code = d.code; i.value = strv(SEED[c]); i.spellcheck = false; wireChange(i, d.code);
        line.appendChild(i); box.appendChild(line);
      } else {
        const v = strv(SEED[c]).trim();
        box.appendChild(el('div', 'refline', '<span class="rl">' + esc(d.label) + ':</span> ' + esc(v || '-')));
      }
    });
  }

  // one labelled mini control, rendered by kind (code chip / bool tick / date / number / text / read-only)
  function fieldMini(def) {
    const w = el('label', 'svc-f');
    if (def.kind === 'code') {
      w.classList.add('svc-code');
      w.appendChild(el('span', 'svc-l', esc(def.label)));
      const hint = el('span', 'svc-hint'); hint.textContent = RESOLVED[def.code] || '';
      w.appendChild(codeChip(def, hint)); w.appendChild(hint);
      return w;
    }
    w.appendChild(el('span', 'svc-l', esc(def.label)));
    if (def.kind === 'bool') {   // label on top, checkbox beneath (so it lines up in the grid columns)
      const cb = el('input'); cb.type = 'checkbox'; cb.dataset.code = def.code; cb.checked = isTrue(SEED[def.code]);
      if (!def.writeKey) cb.disabled = true;
      cb.addEventListener('change', () => { const now = cb.checked ? 'true' : 'false'; if (norm(SEED[def.code]) !== norm(now)) cb.classList.add('chg'); else cb.classList.remove('chg'); });
      w.appendChild(cb);
    } else if (def.kind === 'ref' || (def.kind === 'date' && !def.writeKey)) {
      w.appendChild(el('span', 'svc-v', esc(strv(SEED[def.code]) || '-')));
    } else { // text / number / editable date
      const i = el('input', 'svc-in'); i.type = 'text'; i.dataset.code = def.code; i.value = strv(SEED[def.code]); i.spellcheck = false;
      if (def.kind === 'date') i.placeholder = 'yyyy-mm-dd';
      if (!def.writeKey) i.disabled = true;
      wireChange(i, def.code); w.appendChild(i);
    }
    return w;
  }
  function serviceCell(box, capText) {
    box.appendChild(el('div', 'cap', esc(capText)));
    SVC.forEach(([title, codes]) => {
      const present = codes.filter(c => DEF[c]); if (!present.length) return;
      if (title) box.appendChild(el('div', 'svc-sub', esc(title)));
      const g = el('div', 'svc-grid g4'); present.forEach(c => g.appendChild(fieldMini(DEF[c]))); box.appendChild(g);
    });
  }
  function cargoCell(box, capText) {
    box.appendChild(el('div', 'cap', esc(capText)));
    const g = el('div', 'svc-grid cargo-row');
    CARGO.forEach(c => { const d = DEF[c]; if (!d) return; const f = fieldMini(d); if (CARGOW[c]) f.style.flex = CARGOW[c]; g.appendChild(f); });
    box.appendChild(g);
  }
  // Air flight routing, compact: one small line per leg - flight number then that leg's discharge port chip.
  // Tucked under the References (beneath Job No.) since multi-leg is infrequent. Leg 1 is editable
  // (voyageFlightNumber + portOfDischargeCode); legs 2-3 push via flexData.
  function flightLegsCompact(box) {
    if (!FLIGHTLEGS.some(([f, d]) => DEF[f] || DEF[d])) return;
    const wrap = el('div', 'fleg');
    wrap.appendChild(el('div', 'fleg-cap', 'Flights / IATA legs'));
    FLIGHTLEGS.forEach(([fcode, dcode], idx) => {
      const fdef = DEF[fcode], ddef = DEF[dcode];
      if (!fdef && !ddef) return;
      const row = el('div', 'fleg-row');
      row.appendChild(el('span', 'fleg-n', 'F' + (idx + 1)));
      if (fdef) {
        const i = el('input', 'fleg-fin'); i.type = 'text'; i.dataset.code = fdef.code; i.value = strv(SEED[fdef.code]);
        i.placeholder = 'flight'; i.spellcheck = false; if (!fdef.writeKey) i.disabled = true; wireChange(i, fdef.code);
        row.appendChild(i);
      }
      row.appendChild(el('span', 'fleg-arr', '→'));
      if (ddef) { const hint = el('span', 'fleg-hint'); hint.textContent = RESOLVED[ddef.code] || ''; row.appendChild(codeChip(ddef, hint)); row.appendChild(hint); }
      wrap.appendChild(row);
    });
    box.appendChild(wrap);
  }
  function containerCountCell(box, capText) {
    box.appendChild(el('div', 'cap', esc(capText)));
    const g = el('div', 'svc-grid g4'); CCOUNT.forEach(([c]) => { if (DEF[c]) g.appendChild(fieldMini(DEF[c])); }); box.appendChild(g);
  }
  function singleField(box, capText, code) {
    box.appendChild(el('div', 'cap', esc(capText)));
    const d = DEF[code]; if (d) { const t = pInput(d, true); t.classList.add('fill'); box.appendChild(t); }
  }

  // stakeholders: controlling customer + liner agent + carrier (all editable). Trucker / broker / warehouse were
  // dropped - the booking API has no field for them.
  function stakeholdersCell(box, capText) {
    const cap = el('div', 'cap'); cap.appendChild(document.createTextNode(capText)); cap.appendChild(el('span', 'tag', 'internal')); box.appendChild(cap);
    [['ctrl', 'Controlling cust.'], ['liner', 'Liner agent']].forEach(([p, lab]) => {
      const d = DEF[p + '_code']; if (!d) return;
      const mini = el('div', 'minip'); const l = el('div', 'minilab'); l.appendChild(document.createTextNode(lab));
      const nm = el('div', 'rhint'); nm.textContent = RESOLVED[d.code] ? ('-> ' + RESOLVED[d.code]) : '';
      l.appendChild(codeChip(d, nm)); mini.appendChild(l); mini.appendChild(nm); box.appendChild(mini);
    });
    if (DEF['carrier_code'] || DEF['carrier_name']) {
      const mini = el('div', 'minip'); mini.appendChild(el('div', 'minilab', 'Carrier'));
      const row = el('div', 'carrow');
      if (DEF['carrier_code']) { const i = el('input', 'refin code'); i.type = 'text'; i.dataset.code = 'carrier_code'; i.value = strv(SEED['carrier_code']); i.placeholder = 'code'; i.spellcheck = false; wireChange(i, 'carrier_code'); row.appendChild(i); }
      if (DEF['carrier_name']) { const i = el('input', 'refin'); i.type = 'text'; i.dataset.code = 'carrier_name'; i.value = strv(SEED['carrier_name']); i.placeholder = 'name'; i.spellcheck = false; wireChange(i, 'carrier_name'); row.appendChild(i); }
      mini.appendChild(row); box.appendChild(mini);
    }
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
    const td = el('td'); const x = el('button', '', 'x'); x.type = 'button'; x.title = 'Remove row'; x.style.cssText = 'font-size:12px;padding:2px 8px'; x.onclick = () => tr.remove(); td.appendChild(x); tr.appendChild(td);
    return tr;
  }

  function openLookup(def, anchorEl, inp, hintEl) {
    const ex = anchorEl.querySelector('.lookbox'); if (ex) { ex.remove(); return; }
    const box = el('div', 'lookbox');
    const q = el('input', 'lq'); q.type = 'text'; q.placeholder = 'code or name...'; q.spellcheck = false; box.appendChild(q);
    const list = el('div'); box.appendChild(list);
    anchorEl.appendChild(box);
    // Pin the dropdown to the viewport (position:fixed) and clamp it fully on-screen, so it is always
    // visible whichever field opened it. (Anchor-relative absolute positioning spilled off the RIGHT for
    // right-side fields like controlling cust / liner agent; a naive leftward flip then spilled off the
    // LEFT.) Fixed also escapes the form's overflow:clip, and we focus without auto-scrolling the page.
    const ar = anchorEl.getBoundingClientRect();
    const vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
    const bw = box.offsetWidth || 230;
    const left = Math.max(8, Math.min(ar.left, vw - 8 - bw));
    const spaceBelow = vh - ar.bottom - 10, spaceAbove = ar.top - 10;
    box.style.position = 'fixed'; box.style.left = left + 'px'; box.style.right = 'auto';
    if (spaceBelow >= 160 || spaceBelow >= spaceAbove) {
      box.style.top = (ar.bottom + 3) + 'px'; box.style.bottom = 'auto'; box.style.maxHeight = Math.max(120, spaceBelow) + 'px';
    } else {
      box.style.bottom = (vh - ar.top + 3) + 'px'; box.style.top = 'auto'; box.style.maxHeight = Math.max(120, spaceAbove) + 'px';
    }
    try { q.focus({ preventScroll: true }); } catch (e) { q.focus(); }
    let t = null;
    const run = async () => {
      list.innerHTML = '<div class="li">searching...</div>';
      const d = await api('/api-ops/erp-master?job=' + encodeURIComponent(job) + '&kind=' + encodeURIComponent(def.lookup) + '&q=' + encodeURIComponent(q.value.trim()));
      list.innerHTML = '';
      if (d.error) { list.innerHTML = '<div class="li">' + esc(d.error) + '</div>'; return; }
      const res = arr(d.results);
      if (!res.length) { list.innerHTML = '<div class="li">no matches</div>'; return; }
      res.forEach(r => {
        const li = el('div', 'li', esc(fmtMaster(r)));
        li.onclick = () => {
          inp.value = r.code;
          if (norm(SEED[def.code]) !== norm(r.code)) inp.classList.add('chg'); else inp.classList.remove('chg');
          if (hintEl) { const disp = (r.name || '') + (r.loc ? ' - ' + r.loc : ''); hintEl.textContent = disp ? ((hintEl.className.indexOf('boxval') >= 0 ? '' : '-> ') + disp) : ''; }
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

    // upper: two columns - parties on the left, refs/stakeholders + service detail + internal remark on the right
    const upper = el('div', 'upper');
    const left = el('div', 'col col-left'), right = el('div', 'col col-right');
    ['shipper', 'consignee', 'notify', 'agent'].forEach(p => { if (DEF[p + '_code'] || DEF[p + '_name']) { const b = gbox(); partyCell(b, p, (PARTY[MODE] || {})[p] || p); left.appendChild(b); } });
    const rs = el('div', 'grow');
    const rb = gbox(50); refsCell(rb, MODE === 'Air' ? 'AWB / Ref. No.' : 'B/L No.', REFS[MODE]); if (MODE === 'Air') flightLegsCompact(rb); rs.appendChild(rb);
    const sb = gbox(50); stakeholdersCell(sb, 'Stakeholders'); rs.appendChild(sb);
    right.appendChild(rs);
    const svc = gbox(); serviceCell(svc, 'Service Detail'); right.appendChild(svc);
    const rem = gbox(); rem.classList.add('remarkbox'); singleField(rem, 'Internal Remark', 'int_remark'); right.appendChild(rem);
    upper.appendChild(left); upper.appendChild(right); bill.appendChild(upper);

    // routing row (chips)
    const rr = el('div', 'grow'); ROUTING[MODE].forEach(([code, cap]) => { const b = gbox(25); chipCell(b, code, cap); rr.appendChild(b); }); bill.appendChild(rr);

    // cargo information (one row)
    const cr = el('div', 'grow'); const cb = gbox(); cb.style.flex = '1'; cargoCell(cb, 'Cargo Information'); cr.appendChild(cb); bill.appendChild(cr);

    // container counts by size (sea only)
    if (CCOUNT.some(([c]) => DEF[c])) { const r2 = el('div', 'grow'); const b2 = gbox(); b2.style.flex = '1'; containerCountCell(b2, 'Container Count (by size)'); r2.appendChild(b2); bill.appendChild(r2); }

    // marks | description side by side
    const mr = el('div', 'grow');
    const mb = gbox(50); singleField(mb, 'Marks & Numbers', 'ship_marks'); mr.appendChild(mb);
    const db = gbox(50); singleField(db, 'Description of Goods', 'goods_desc'); mr.appendChild(db);
    bill.appendChild(mr);

    // container table (sea only)
    if (DEF['containers']) { const conr = el('div', 'grow'); const conb = gbox(); conb.style.flex = '1'; containersCell(conb, 'containers', 'Container Particulars'); conr.appendChild(conb); bill.appendChild(conr); }

    root.appendChild(bill);
    root.appendChild(extraSections());
  }

  // Space beneath the bill for additional, non-bill sections. Billing is planned but not yet wired (the ERP
  // charge tables + Swivel billing endpoint are not yet mapped), so it shows as a disabled preview for now.
  function extraSections() {
    const wrap = el('div', 'extra-sect');
    const add = el('button', '', '+ Add section'); add.type = 'button';
    const card = el('div', 'seccard'); card.style.display = 'none';
    card.innerHTML = '<b>Billing &amp; charges</b> - planned. Charge lines (code . description . amount . currency) will be ' +
      'editable here once the ERP charge tables and the Swivel billing endpoint are mapped. Not available yet.';
    add.onclick = () => { card.style.display = card.style.display === 'none' ? 'block' : 'none'; };
    wrap.appendChild(add); wrap.appendChild(card);
    return wrap;
  }

  function collect() {
    const out = JSON.parse(JSON.stringify(SEED || {}));   // keep untouched/display fields at their seeded value
    // combined party boxes -> split line 1 (name) / rest (address) back into the dict codes
    document.querySelectorAll('#sections [data-combine]').forEach(ta => {
      const p = ta.dataset.combine; const lines = ta.value.replace(/\r/g, '').split('\n');
      if (DEF[p + '_name']) out[p + '_name'] = (lines[0] || '').trim();
      if (DEF[p + '_address']) out[p + '_address'] = lines.slice(1).join('\n').trim();
    });
    document.querySelectorAll('#sections input[data-code], #sections textarea[data-code]').forEach(i => {
      out[i.dataset.code] = (i.type === 'checkbox') ? (i.checked ? 'true' : 'false') : i.value;
    });
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
  load();
})();
