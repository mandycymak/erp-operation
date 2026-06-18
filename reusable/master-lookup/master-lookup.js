// master-lookup.js - drop-in master code-lookup widget (port master / customer master / liner / service / incoterm).
// Extracted from erp-edit.js (codeChip + openLookup). No framework, no build step, no dependency on the host app.
//
// It renders the short editable code chip  ( CODE ) ...  and, on clicking the "..." button, a viewport-pinned,
// fully-clamped dropdown that type-ahead-searches a master and writes the picked code back into the chip.
//
// Transport-agnostic: YOU supply a `search(kind, q)` async fn that returns { results:[{code,name,loc?}] } or
// { error }. Use MasterLookup.httpSearch(...) for the standard GET endpoint, or write your own.
//
// Usage:
//   const search = MasterLookup.httpSearch({ url: '/api-ops/erp-master', params: { job }, headers: {...} });
//   const c = MasterLookup.chip({ kind: 'custsub', value: 'DUMMY', search, onSelect: (code,row)=>{...} });
//   captionEl.appendChild(c.el);     // the ( CODE ) ... chip
//   captionEl.appendChild(c.hintEl); // optional resolved-name line (place where you like)
//   ... c.value            -> current code
//   ... c.changed          -> true once edited away from the seeded value
//
// kinds: 'custsub' (customer), 'port', 'liner', 'service', 'incoterm' - must match the server handler.
(function (root) {
  'use strict';
  const esc = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const arr = v => Array.isArray(v) ? v : (v == null ? [] : [v]);
  const strv = v => ('' + (v == null ? '' : v));
  const norm = v => strv(v).trim();

  // standardized display of one master row: "NAME (CODE) - city, country"
  const fmtMaster = r => (((r.name ? r.name + ' ' : '') + '(' + r.code + ')') + (r.loc ? ' - ' + r.loc : '')).trim();
  const fmtHint = r => { const d = (r.name || '') + (r.loc ? ' - ' + r.loc : ''); return d ? ('-> ' + d) : ''; };

  // Pin the dropdown to the viewport (position:fixed) and clamp it fully on-screen, so it is always visible
  // whichever field opened it. (Anchor-relative absolute positioning spilled off the RIGHT for right-side fields;
  // a naive leftward flip then spilled off the LEFT.) Fixed also escapes any overflow:clip on the form.
  function position(box, anchorEl) {
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
  }

  // open the type-ahead dropdown anchored to `o.anchor`; calls o.onPick(row) on selection.
  function open(o) {
    const ex = o.anchor.querySelector('.lookbox'); if (ex) { ex.remove(); return; } // toggle off
    const box = el('div', 'lookbox');
    const q = el('input', 'lq'); q.type = 'text'; q.placeholder = 'code or name...'; q.spellcheck = false; box.appendChild(q);
    const list = el('div'); box.appendChild(list);
    o.anchor.appendChild(box);
    position(box, o.anchor);
    try { q.focus({ preventScroll: true }); } catch (e) { q.focus(); }
    let t = null;
    const run = async () => {
      list.innerHTML = '<div class="li">searching...</div>';
      let d; try { d = await o.search(o.kind, q.value.trim()); } catch (e) { d = { error: String((e && e.message) || e) }; }
      list.innerHTML = '';
      if (!d || d.error) { list.innerHTML = '<div class="li">' + esc((d && d.error) || 'lookup failed') + '</div>'; return; }
      const res = arr(d.results);
      if (!res.length) { list.innerHTML = '<div class="li">no matches</div>'; return; }
      res.forEach(r => {
        const li = el('div', 'li', esc(fmtMaster(r)));
        li.onclick = () => { o.onPick(r); box.remove(); };
        list.appendChild(li);
      });
    };
    q.oninput = () => { clearTimeout(t); t = setTimeout(run, 220); };
    run();
    setTimeout(() => { document.addEventListener('click', function h(e) { if (!o.anchor.contains(e.target)) { box.remove(); document.removeEventListener('click', h); } }); }, 0);
  }

  // build the editable "( CODE ) ..." chip. Returns { el, hintEl, input, value, changed }.
  function chip(opts) {
    opts = opts || {};
    const seed = strv(opts.value);
    const wrap = el('span', 'codechip lookup');
    wrap.appendChild(document.createTextNode('('));
    const inp = el('input'); inp.type = 'text'; inp.value = seed; inp.spellcheck = false;
    if (opts.disabled) inp.disabled = true;
    const hint = el('span', 'ml-hint'); hint.textContent = opts.hint || '';
    const sync = () => { if (norm(seed) !== norm(inp.value)) inp.classList.add('chg'); else inp.classList.remove('chg'); };
    inp.addEventListener('input', () => { hint.textContent = ''; sync(); if (opts.onChange) opts.onChange(inp.value); });
    wrap.appendChild(inp);
    wrap.appendChild(document.createTextNode(')'));
    if (!opts.disabled && opts.search) {
      const fb = el('button', 'findbtn', '...'); fb.type = 'button'; fb.title = 'Search the master';
      fb.onclick = () => open({
        anchor: wrap, kind: opts.kind, search: opts.search,
        onPick: r => { inp.value = r.code; sync(); hint.textContent = fmtHint(r); if (opts.onSelect) opts.onSelect(r.code, r); if (opts.onChange) opts.onChange(r.code); }
      });
      wrap.appendChild(fb);
    }
    return {
      el: wrap, hintEl: hint, input: inp,
      get value() { return inp.value; }, set value(v) { inp.value = strv(v); sync(); },
      get changed() { return norm(seed) !== norm(inp.value); }
    };
  }

  // convenience: a search() backed by a GET endpoint of shape  ?<params>&kind=<kind>&q=<term>  -> JSON {results}.
  function httpSearch(cfg) {
    cfg = cfg || {};
    return async (kind, q) => {
      const u = new URL(cfg.url, location.href);
      Object.keys(cfg.params || {}).forEach(k => u.searchParams.set(k, cfg.params[k]));
      u.searchParams.set('kind', kind); u.searchParams.set('q', q);
      const r = await fetch(u.toString(), { cache: 'no-store', headers: cfg.headers || {} });
      if (r.status === 401 && cfg.on401) { cfg.on401(); return new Promise(() => {}); }
      return r.json();
    };
  }

  root.MasterLookup = { chip, open, httpSearch, fmtMaster };
})(window);
