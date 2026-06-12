// bl-form.js - shared draft-document form renderer (no framework, no build step).
// Used by BOTH the staff editor (doc-editor.html) and the public customer review page (bl-review.html),
// so the two sides always see the identical bill layout. The layout comes from doc-fields.json
// (order = layout order, w = grid span of 12, multiline = tall box). Values are a flat {code: value} map;
// plain fields hold strings, kind 'table' fields hold an array of row objects (container particulars) and
// kind 'riders' fields hold an array of attachment/rider page objects - both render as editable structures
// and print properly (riders on their own pages after the bill).
'use strict';
(function () {
  const escF = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  // canonical comparable string: strings as-is, structured values as JSON (mirrors the server's Doc-ValStr)
  const norm = v => (typeof v === 'string' || v == null) ? ('' + (v == null ? '' : v)) : JSON.stringify(v);
  const rowsOf = v => Array.isArray(v) ? v : [];
  const cellVal = (row, code) => (row && row[code] != null) ? '' + row[code] : '';

  let DICT = null;
  async function load() {
    if (!DICT) {
      const r = await fetch('/doc-fields.json', { cache: 'no-store' });
      DICT = await r.json();
    }
    return DICT;
  }
  function defs(type) { return (DICT && DICT[type]) ? DICT[type] : []; }

  // ---- structured renderers ----
  function renderTable(host, d, rows, oldRows, editable) {
    const tbl = document.createElement('table');
    tbl.className = 'blf-table'; tbl.dataset.code = d.code;
    const thead = document.createElement('tr');
    d.columns.forEach(col => { const th = document.createElement('th'); th.textContent = col.label; thead.appendChild(th); });
    if (editable) thead.appendChild(document.createElement('th'));
    tbl.appendChild(thead);
    const maxRows = d.maxRows || 10;
    function addRow(r, idx) {
      const tr = document.createElement('tr');
      d.columns.forEach(col => {
        const td = document.createElement('td');
        const v = cellVal(r, col.code);
        if (oldRows && cellVal(oldRows[idx], col.code) !== v) { td.classList.add('blf-cell-chg'); td.title = 'Was: ' + (cellVal(oldRows[idx], col.code) || '(empty)'); }
        if (editable) {
          const inp = document.createElement('input');
          inp.type = 'text'; inp.dataset.col = col.code; inp.value = v;
          if (col.maxlen) inp.maxLength = col.maxlen;
          td.appendChild(inp);
        } else td.textContent = v;
        tr.appendChild(td);
      });
      if (editable) {
        const td = document.createElement('td'); td.className = 'noprint blf-rowbtn';
        const x = document.createElement('button'); x.type = 'button'; x.textContent = '✕'; x.title = 'Remove row';
        x.onclick = () => { tr.remove(); };
        td.appendChild(x); tr.appendChild(td);
      }
      tbl.appendChild(tr);
    }
    rows.forEach((r, i) => addRow(r, i));
    if (!rows.length && editable) addRow({}, 0);
    host.appendChild(tbl);
    if (!rows.length && !editable) host.appendChild(Object.assign(document.createElement('div'), { className: 'mut', textContent: '(none)' }));
    if (editable) {
      const add = document.createElement('button');
      add.type = 'button'; add.className = 'noprint blf-add'; add.textContent = '+ Add row';
      add.onclick = () => { if (tbl.querySelectorAll('tr').length - 1 >= maxRows) { alert('Maximum ' + maxRows + ' rows.'); return; } addRow({}, -1); };
      host.appendChild(add);
    }
  }

  const POINTER = 'AS PER ATTACHED SHEET';
  function renderRiders(root, d, pages, oldPages, editable, billNo) {
    const wrap = document.createElement('div');
    wrap.className = 'riders'; wrap.dataset.code = d.code;
    const maxRows = d.maxRows || 10;
    function headText(n) { return 'ATTACHMENT TO B/L NO. ' + (billNo || '') + ' - PAGE ' + n; }
    function renumber() { wrap.querySelectorAll('.rider-page .rider-head').forEach((h, i) => { h.textContent = headText(i + 1); }); }
    function addPage(p, idx, moved) {
      const pg = document.createElement('div');
      pg.className = 'rider-page';
      if (moved) pg.dataset.moved = '1';
      const head = document.createElement('div'); head.className = 'rider-head'; head.textContent = headText(wrap.querySelectorAll('.rider-page').length + 1);
      pg.appendChild(head);
      if (editable) {
        const rm = document.createElement('button'); rm.type = 'button'; rm.className = 'noprint rider-rm'; rm.textContent = '✕ Remove this page';
        rm.onclick = () => {
          // a page filled by "move to attachment" puts its content BACK into the on-bill boxes on
          // removal (the boxes still hold only the blank/pointer left behind, so nothing is overwritten)
          if (pg.dataset.moved && d.moveFrom) {
            Object.keys(d.moveFrom).forEach(col => {
              const box = root.querySelector('.blf-input[data-code="' + d.moveFrom[col] + '"]');
              const ta = pg.querySelector('textarea[data-col="' + col + '"]');
              if (box && ta && (!box.value.trim() || box.value.trim() === POINTER)) box.value = ta.value;
            });
          }
          pg.remove(); renumber();
        };
        pg.appendChild(rm);
      }
      const grid = document.createElement('div'); grid.className = 'rider-grid';
      if (d.columns.some(c => c.w)) grid.style.gridTemplateColumns = d.columns.map(c => (c.w || 1) + 'fr').join(' ');
      d.columns.forEach(col => {
        const cell = document.createElement('div'); cell.className = 'rider-col';
        const lab = document.createElement('div'); lab.className = 'blf-label'; lab.textContent = col.label; cell.appendChild(lab);
        const v = cellVal(p, col.code);
        const chg = oldPages && cellVal(oldPages[idx], col.code) !== v;
        if (chg) cell.classList.add('blf-cell-chg');
        if (editable) {
          const ta = document.createElement('textarea');
          ta.dataset.col = col.code; ta.value = v;
          if (col.maxlen) ta.maxLength = col.maxlen;
          if (col.mono) ta.classList.add('mono');
          cell.appendChild(ta);
        } else {
          const div = document.createElement('div'); div.className = 'blf-val' + (col.mono ? ' mono' : ''); div.textContent = v; cell.appendChild(div);
        }
        grid.appendChild(cell);
      });
      pg.appendChild(grid);
      wrap.appendChild(pg);
    }
    pages.forEach((p, i) => addPage(p, i));
    if (editable) {
      const add = document.createElement('button');
      add.type = 'button'; add.className = 'noprint blf-add'; add.textContent = '+ Add attachment / rider page';
      add.onclick = () => {
        if (wrap.querySelectorAll('.rider-page').length >= maxRows) { alert('Maximum ' + maxRows + ' pages.'); return; }
        // first page + a moveFrom map in the dictionary: MOVE the main-box text (marks/qty/description)
        // onto the attachment page - nobody retypes anything. Only the Description box keeps the
        // standard pointer; the other boxes go blank so "AS PER ATTACHED SHEET" never prints twice.
        const seed = {}; let movedAny = false;
        if (!wrap.querySelectorAll('.rider-page').length && d.moveFrom) {
          Object.keys(d.moveFrom).forEach(col => {
            const box = root.querySelector('.blf-input[data-code="' + d.moveFrom[col] + '"]');
            const t = box ? box.value.trim() : '';
            if (t && t !== POINTER) {
              seed[col] = box.value; movedAny = true;
              box.value = (col === 'description') ? POINTER : '';
            } else if (box && t === POINTER && col !== 'description') box.value = '';
          });
        }
        addPage(seed, -1, movedAny); wrap.appendChild(add);
      };
      wrap.appendChild(add);
    }
    if (pages.length || editable) root.appendChild(wrap);
  }

  // Render the bill into `root`. opts: { editable: bool, diffFrom: {code:value}|null }.
  // diffFrom marks boxes/cells whose value differs from the given base snapshot.
  function render(root, type, fields, opts) {
    opts = opts || {};
    fields = fields || {};
    root.innerHTML = '';
    root.classList.add('blform');
    const title = document.createElement('div');
    title.className = 'blf-title';
    title.textContent = type === 'HAWB' ? 'HOUSE AIR WAYBILL' : 'HOUSE BILL OF LADING';
    root.appendChild(title);
    const grid = document.createElement('div');
    grid.className = 'blf-grid';
    const riderDefs = [];
    defs(type).forEach(d => {
      if (d.kind === 'riders') { riderDefs.push(d); return; }   // riders print AFTER the bill, not inside it
      const box = document.createElement('div');
      box.className = 'blf-box' + (d.multiline ? ' ml' : '') + (d.kind === 'table' ? ' tbl' : '');
      box.style.gridColumn = 'span ' + (d.w || 3);
      const lab = document.createElement('div');
      lab.className = 'blf-label';
      lab.textContent = d.label;
      box.appendChild(lab);
      if (d.kind === 'table') {
        const rows = rowsOf(fields[d.code]);
        const oldRows = opts.diffFrom ? rowsOf(opts.diffFrom[d.code]) : null;
        if (oldRows && norm(rows) !== norm(oldRows)) box.classList.add('blf-changed');
        renderTable(box, d, rows, oldRows, !!opts.editable);
      } else {
        const v = fields[d.code] == null ? '' : '' + fields[d.code];
        let changed = false, oldV = '';
        if (opts.diffFrom) {
          oldV = opts.diffFrom[d.code] == null ? '' : '' + opts.diffFrom[d.code];
          changed = oldV !== v;
        }
        if (changed) { box.classList.add('blf-changed'); box.title = 'Changed. Was:\n' + (oldV || '(empty)'); }
        if (opts.editable) {
          const inp = document.createElement(d.multiline ? 'textarea' : 'input');
          if (!d.multiline) inp.type = 'text';
          inp.className = 'blf-input' + (d.mono ? ' mono' : '');
          inp.dataset.code = d.code;
          if (d.maxlen) inp.maxLength = d.maxlen;
          inp.value = v;
          if (d.multiline) inp.rows = Math.min(8, Math.max(3, (v.split('\n').length + 1)));
          box.appendChild(inp);
        } else {
          const val = document.createElement('div');
          val.className = 'blf-val' + (d.mono ? ' mono' : '');
          val.textContent = v;
          box.appendChild(val);
        }
      }
      grid.appendChild(box);
    });
    root.appendChild(grid);
    const billNo = '' + (fields.hbl_no || fields.hawb_no || '');
    riderDefs.forEach(d => {
      const pages = rowsOf(fields[d.code]);
      const oldPages = opts.diffFrom ? rowsOf(opts.diffFrom[d.code]) : null;
      renderRiders(root, d, pages, oldPages, !!opts.editable, billNo);
    });
  }

  // Read the edited values back out of a rendered (editable) form. Structured fields come back as arrays
  // of row objects in dictionary column order; rows/pages where every cell is blank are dropped.
  function collect(root) {
    const out = {};
    root.querySelectorAll('.blf-input').forEach(i => { out[i.dataset.code] = i.value; });
    root.querySelectorAll('table.blf-table[data-code]').forEach(tbl => {
      const rows = [];
      tbl.querySelectorAll('tr').forEach(tr => {
        const inputs = tr.querySelectorAll('input[data-col]');
        if (!inputs.length) return;   // header row
        const row = {}; let any = false;
        inputs.forEach(inp => { row[inp.dataset.col] = inp.value; if (inp.value.trim()) any = true; });
        if (any) rows.push(row);
      });
      out[tbl.dataset.code] = rows;
    });
    root.querySelectorAll('.riders[data-code]').forEach(wrap => {
      const pages = [];
      wrap.querySelectorAll('.rider-page').forEach(pg => {
        const page = {}; let any = false;
        pg.querySelectorAll('textarea[data-col]').forEach(ta => { page[ta.dataset.col] = ta.value; if (ta.value.trim()) any = true; });
        if (any) pages.push(page);
      });
      out[wrap.dataset.code] = pages;
    });
    return out;
  }

  // Field codes whose value differs between two snapshots (dictionary order). Structured values compare
  // via canonical JSON.
  function diff(type, a, b) {
    a = a || {}; b = b || {};
    return defs(type).filter(d => norm(a[d.code]) !== norm(b[d.code])).map(d => d.code);
  }

  function miniTable(rows, otherRows, cols) {
    let h = '<table class="blf-mini"><tr>' + cols.map(c => '<th>' + escF(c.label) + '</th>').join('') + '</tr>';
    rows.forEach((r, i) => {
      h += '<tr>' + cols.map(c => {
        const v = cellVal(r, c.code), o = cellVal((otherRows || [])[i], c.code);
        return '<td' + (v !== o ? ' class="blf-cell-chg"' : '') + '>' + (v ? escF(v) : '<span class="mut">-</span>') + '</td>';
      }).join('') + '</tr>';
    });
    return h + '</table>';
  }

  // Side-by-side "was -> now" table of only the changed fields (staff review of a customer submission).
  function renderDiff(root, type, oldF, newF) {
    root.innerHTML = '';
    oldF = oldF || {}; newF = newF || {};
    const changed = diff(type, oldF, newF);
    if (!changed.length) { root.innerHTML = '<div class="empty">No field changes between these versions.</div>'; return; }
    const byCode = {}; defs(type).forEach(d => byCode[d.code] = d);
    let html = '<table class="blf-diff"><tr><th>Field</th><th>Was</th><th>Now</th></tr>';
    changed.forEach(c => {
      const d = byCode[c] || {};
      let was, now;
      if (d.kind === 'table' || d.kind === 'riders') {
        was = rowsOf(oldF[c]).length ? miniTable(rowsOf(oldF[c]), rowsOf(newF[c]), d.columns) : '<span class="mut">(empty)</span>';
        now = rowsOf(newF[c]).length ? miniTable(rowsOf(newF[c]), rowsOf(oldF[c]), d.columns) : '<span class="mut">(empty)</span>';
      } else {
        const o = oldF[c] != null ? '' + oldF[c] : '', n = newF[c] != null ? '' + newF[c] : '';
        was = o ? escF(o) : '<span class="mut">(empty)</span>';
        now = n ? escF(n) : '<span class="mut">(empty)</span>';
      }
      html += '<tr><td class="fld">' + escF(d.label || c) + '</td><td class="was">' + was + '</td><td class="now">' + now + '</td></tr>';
    });
    html += '</table>';
    root.innerHTML = html;
  }

  // Print page size: documents go out on A4 or F4 (folio, 210x330mm) paper.
  function setPrintSize(size) {
    let st = document.getElementById('blfPage');
    if (!st) { st = document.createElement('style'); st.id = 'blfPage'; document.head.appendChild(st); }
    st.textContent = '@page { size: ' + (size === 'F4' ? '210mm 330mm' : 'A4') + '; margin: 12mm; }';
    try { localStorage.setItem('blfPrintSize', size); } catch (e) {}
    return size;
  }
  function getPrintSize() { try { return localStorage.getItem('blfPrintSize') || 'A4'; } catch (e) { return 'A4'; } }

  window.BLForm = { load, defs, render, collect, diff, renderDiff, norm, setPrintSize, getPrintSize };
})();
