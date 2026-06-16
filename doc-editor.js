// doc-editor.js - staff-side draft document editor (session-gated /api-ops/doc* endpoints).
// Opened from the worklist drawer as doc-editor.html?id=<docId>. Drives the whole agreement loop:
// edit/save versions, send the customer a tokenized link, review the customer's field-by-field changes,
// agree, issue via the ERP API, and open amendment cycles (fee applies after issue).
'use strict';
(function () {
  const $ = s => document.querySelector(s);
  const esc = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  const el = (t, c, h) => { const e = document.createElement(t); if (c) e.className = c; if (h != null) e.innerHTML = h; return e; };
  const docId = new URLSearchParams(location.search).get('id') || '';
  let D = null;            // /api-ops/doc payload (head, version, baseFields, versions)
  let viewVer = null;      // version currently displayed (null = head.currentVersion)

  async function api(path, body) {
    const opts = { cache: 'no-store', headers: { 'X-Ops-User': localStorage.getItem('opsUser') || '(open)' } };
    if (body) { opts.method = 'POST'; opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const r = await fetch(path, opts);
    if (r.status === 401) { location.href = 'login.html'; return new Promise(() => {}); }
    return r.json();
  }
  function fail(m) { $('#msg').innerHTML = '<div class="err">' + esc(m) + '</div>'; }
  function flash(m) { $('#msg').innerHTML = '<div class="note">' + m + '</div>'; }

  const EDITABLE = { DRAFT: 1, AMEND_DRAFT: 1, CUSTOMER_SUBMITTED: 1, CUSTOMER_APPROVED: 1 };

  async function load(ver) {
    const q = '/api-ops/doc?id=' + encodeURIComponent(docId) + (ver ? '&v=' + ver : '');
    const d = await api(q);
    if (d.error) { fail(d.error); return; }
    D = d; viewVer = d.version.no;
    render();
    loadEvents();
  }

  function render() {
    const h = D.head, v = D.version;
    const isCurrent = v.no === h.currentVersion;
    $('#title').textContent = (h.docType === 'HAWB' ? 'House Air Waybill' : 'House Bill of Lading') + ' - ' + h.jobNo;
    const st = $('#status'); st.className = 'badge ' + h.status; st.textContent = h.status + (h.amendCount ? ' (amend #' + h.amendCount + ', fee applies)' : '');
    $('#meta').textContent = 'v' + v.no + ' by ' + (v.createdBy || '?') + ' at ' + (v.createdAt || '') +
      (h.erpDocNo ? ' | official no. ' + h.erpDocNo : '') +
      (h.activeToken ? ' | link live for ' + (h.activeToken.customerEmail || 'customer') + ', viewed ' + h.activeToken.viewCount + 'x, expires ' + h.activeToken.expiresAt : '');
    $('#printBtn').onclick = () => window.print();
    const sz = $('#sizeBtn');
    sz.textContent = 'Paper: ' + BLForm.setPrintSize(BLForm.getPrintSize());
    sz.onclick = () => { sz.textContent = 'Paper: ' + BLForm.setPrintSize(BLForm.getPrintSize() === 'A4' ? 'F4' : 'A4'); };
    loadAttachments();

    // version pills
    const vl = $('#verList'); vl.innerHTML = '';
    (D.versions || []).forEach(x => {
      const p = el('span', 'verpill' + (x.side === 'customer' ? ' customer' : '') + (x.no === viewVer ? ' on' : ''),
        'v' + x.no + ' ' + (x.side === 'customer' ? 'customer' : 'staff'));
      p.title = (x.createdBy || '') + ' ' + (x.createdAt || '') + (x.comment ? '\n' + x.comment : '');
      p.onclick = () => load(x.no);
      vl.appendChild(p);
    });

    // diff vs the version this one was edited from
    const dc = $('#diffCard');
    if (D.baseFields && v.baseVersion) {
      dc.style.display = '';
      $('#diffTitle').textContent = 'Changes in v' + v.no + ' (' + v.side + ') vs v' + v.baseVersion +
        (v.comment ? ' - "' + v.comment + '"' : '');
      BLForm.renderDiff($('#diffBody'), h.docType, D.baseFields, v.fields || {});
    } else { dc.style.display = 'none'; }

    // the bill: editable only when looking at the CURRENT version in an editable status
    const editable = isCurrent && !!EDITABLE[h.status];
    BLForm.render($('#doc'), h.docType, v.fields || {}, { editable, diffFrom: D.baseFields || null });
    renderActions(editable, isCurrent);
  }

  function renderActions(editable, isCurrent) {
    const h = D.head;
    const a = $('#actions'); a.innerHTML = '';
    if (!isCurrent) { a.appendChild(el('div', 'muted', 'Viewing an old version (read-only). Click the latest version pill to act.')); return; }
    const row = el('div'); row.style.cssText = 'display:flex;gap:10px;flex-wrap:wrap;align-items:center';

    if (editable) {
      const cmt = el('input', 'line'); cmt.placeholder = 'comment for this revision (optional, goes in the history)'; cmt.style.flex = '1 1 260px';
      row.appendChild(cmt);
      const save = el('button', 'primary', 'Save as v' + (h.currentVersion + 1));
      save.onclick = async () => {
        const r = await api('/api-ops/doc-save', { doc_id: docId, fields: BLForm.collect($('#doc')), comment: cmt.value.trim() });
        if (r.error) { alert(r.error); return; }
        flash('Saved v' + r.version + ' (changed: ' + (r.changed || []).join(', ') + ')'); load();
      };
      row.appendChild(save);
    }
    if (['DRAFT', 'AMEND_DRAFT', 'CUSTOMER_SUBMITTED', 'SENT'].includes(h.status)) {
      const send = el('button', h.status === 'SENT' ? '' : 'good', h.status === 'SENT' ? 'Resend (new link)' : 'Send to customer');
      send.onclick = () => sendDialog();
      row.appendChild(send);
    }
    if (h.status === 'SENT') {
      const rv = el('button', 'warn', 'Revoke link');
      rv.onclick = async () => {
        if (!confirm('Revoke the customer link? They will no longer be able to open it.')) return;
        const r = await api('/api-ops/doc-token-revoke', { doc_id: docId });
        if (r.error) { alert(r.error); return; }
        flash('Link revoked. Status back to ' + r.status + '.'); load();
      };
      row.appendChild(rv);
    }
    if (h.status === 'CUSTOMER_APPROVED') {
      const ag = el('button', 'good', 'Agree - save data to ERP');
      ag.onclick = async () => {
        if (!confirm('Confirm both sides agree on v' + h.currentVersion + '? The agreed data is saved to the ERP booking now; the official document is issued in the next step.')) return;
        const r = await api('/api-ops/doc-agree', { doc_id: docId });
        if (r.error) { alert(r.error); return; }
        flash('Agreed. Ready to issue.' + (r.erp && r.erp.steps && r.erp.steps.length
          ? '<br><span class="muted">ERP: ' + esc(r.erp.steps.join(' · ')) + (r.erp.mock ? ' (MOCK)' : '') + '</span>' : '')); load();
      };
      row.appendChild(ag);
    }
    if (h.status === 'AGREED') {
      // optional: attach the agreed PDF (browser print-to-PDF of this page) - forwarded to ERP /file/upload
      const pdf = el('input'); pdf.type = 'file'; pdf.accept = 'application/pdf'; pdf.title = 'Optional override: by default the agreed bill is auto-generated to PDF and uploaded to the ERP. Pick a file here only to upload your own PDF instead.';
      row.appendChild(pdf);
      const is = el('button', 'good', 'Issue official document (ERP)');
      is.onclick = async () => {
        if (!confirm('Issue the OFFICIAL ' + h.docType + ' via the ERP now? After this, changes incur an amendment fee.')) return;
        const body = { doc_id: docId };
        const f = pdf.files && pdf.files[0];
        if (f) {
          if (f.size > 5 * 1024 * 1024) { alert('PDF too large (max 5 MB).'); return; }
          body.pdf_name = f.name;
          body.pdf_base64 = await new Promise((res, rej) => {
            const rd = new FileReader();
            rd.onload = () => res(('' + rd.result).split(',')[1] || '');
            rd.onerror = rej;
            rd.readAsDataURL(f);
          });
        }
        is.disabled = true;
        const r = await api('/api-ops/doc-issue', body);
        is.disabled = false;
        if (r.error) { alert(r.error); return; }
        flash('Issued. Official no. <b>' + esc(r.erpDocNo) + '</b>' + (r.mock ? ' (MOCK mode - not a real ERP call)' : '') +
          (r.steps && r.steps.length ? '<br><span class="muted">' + esc(r.steps.join(' · ')) + '</span>' : '')); load();
      };
      row.appendChild(is);
    }
    if (h.status === 'ISSUED') {
      const am = el('button', 'warn', 'Open amendment (fee applies)');
      am.onclick = async () => {
        const reason = prompt('Reason for the amendment (the customer-facing fee applies):');
        if (reason == null) return;
        const r = await api('/api-ops/doc-amend', { doc_id: docId, reason });
        if (r.error) { alert(r.error); return; }
        flash('Amendment #' + r.amendCount + ' opened - edit and send the revised draft.'); load();
      };
      row.appendChild(am);
    }
    a.appendChild(row);

    if (h.status === 'CUSTOMER_SUBMITTED') {
      a.appendChild(el('div', 'muted', 'The customer sent corrections (highlighted above). Adjust anything that is not acceptable, Save, then resend - or Send as-is if their version is fine.'));
    }
  }

  // attachment files (rider documents): staff may upload/delete in any pre-ISSUED status
  async function loadAttachments() {
    const d = await api('/api-ops/doc-attach-list?id=' + encodeURIComponent(docId));
    const host = $('#attList'); host.innerHTML = '';
    if (d.error) { host.innerHTML = '<div class="mut">' + esc(d.error) + '</div>'; return; }
    const list = d.attachments || [];
    const locked = D && D.head.status === 'ISSUED';
    if (!list.length) host.innerHTML = '<div class="mut">No attachment files.</div>';
    list.forEach(a => {
      const row = document.createElement('div'); row.className = 'attrow';
      row.innerHTML = '<a href="/api-ops/doc-attach-file?id=' + encodeURIComponent(docId) + '&att=' + encodeURIComponent(a.id) + '" target="_blank">' + esc(a.name) + '</a>' +
        ' <span class="mut">' + Math.round(a.size / 1024) + ' KB · ' + esc(a.side) + (a.by ? ' (' + esc(a.by) + ')' : '') + ' · ' + esc(a.at) + '</span>';
      if (!locked) {
        const del = document.createElement('button'); del.textContent = '✕'; del.title = 'Remove'; del.style.fontSize = '11px';
        del.onclick = async () => {
          if (!confirm('Remove ' + a.name + '?')) return;
          const r = await api('/api-ops/doc-attach-delete', { doc_id: docId, att_id: a.id });
          if (r.error) { alert(r.error); return; }
          loadAttachments(); loadEvents();
        };
        row.appendChild(del);
      }
      host.appendChild(row);
    });
    $('#attUpload').style.display = locked ? 'none' : '';
    $('#attFile').onchange = async () => {
      const f = $('#attFile').files && $('#attFile').files[0];
      if (!f) return;
      if (f.size > 5 * 1024 * 1024) { alert('File too large (max 5 MB).'); $('#attFile').value = ''; return; }
      if (!['application/pdf', 'image/png', 'image/jpeg'].includes(f.type)) { alert('Only PDF, PNG or JPEG files are accepted.'); $('#attFile').value = ''; return; }
      const base64 = await new Promise((res, rej) => {
        const rd = new FileReader();
        rd.onload = () => res(('' + rd.result).split(',')[1] || '');
        rd.onerror = rej;
        rd.readAsDataURL(f);
      });
      const r = await api('/api-ops/doc-attach', { doc_id: docId, file_name: f.name, content_type: f.type, base64 });
      $('#attFile').value = '';
      if (r.error) { alert(r.error); return; }
      loadAttachments(); loadEvents();
    };
  }

  function sendDialog() {
    const h = D.head;
    const email = prompt('Customer email for the review link:', h.customerEmail || '');
    if (email == null) return;
    const name = prompt('Customer / contact name (optional):', h.customerName || '') || '';
    const days = prompt('Link valid for how many days?', '14') || '14';
    api('/api-ops/doc-send', { doc_id: docId, customer_email: email.trim(), customer_name: name.trim(), expires_days: days.trim() })
      .then(r => {
        if (r.error) { alert(r.error); return; }
        const mailto = 'mailto:' + encodeURIComponent(email.trim()) +
          '?subject=' + encodeURIComponent('Draft ' + h.docType + ' for your review - ' + h.jobNo) +
          '&body=' + encodeURIComponent('Dear ' + (name.trim() || 'customer') + ',\n\nPlease review the draft document at the secure link below. You can correct the text directly on screen and send it back to us.\n\n' + r.link + '\n\nThe link is valid for ' + r.expiresDays + ' days.\n\nBest regards');
        flash('Link created (v' + r.sentVersion + ', valid ' + r.expiresDays + ' days). Any earlier link is now dead.<br>' +
          '<span style="display:inline-flex;align-items:center;gap:6px;margin:6px 0;max-width:100%">' +
          '<input id="lnkBox" class="line" style="margin:0;flex:1;min-width:240px" value="' + esc(r.link) + '" readonly onclick="this.select()">' +
          '<button id="lnkCopy" type="button" title="Copy link" aria-label="Copy link" ' +
          'style="display:inline-flex;align-items:center;justify-content:center;padding:5px 7px;cursor:pointer">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" ' +
          'stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"></rect>' +
          '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg></button>' +
          '<span id="lnkCopied" class="muted" style="display:none">Copied</span></span><br>' +
          '<a href="' + esc(mailto) + '">Open in email</a> or copy the link above into your own message.');
        const cb = $('#lnkCopy');
        if (cb) cb.onclick = () => {
          const inp = $('#lnkBox'); if (inp) { inp.focus(); inp.select(); }
          const ok = $('#lnkCopied');
          const done = () => { if (ok) { ok.style.display = 'inline'; setTimeout(() => { ok.style.display = 'none'; }, 1600); } };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(r.link).then(done, () => { try { document.execCommand('copy'); } catch (e) {} done(); });
          } else { try { document.execCommand('copy'); } catch (e) {} done(); }
        };
        load();
      });
  }

  async function loadEvents() {
    const d = await api('/api-ops/doc-events?id=' + encodeURIComponent(docId));
    const b = $('#evtBody'); b.innerHTML = '';
    if (d.error) { b.innerHTML = '<div class="empty">' + esc(d.error) + '</div>'; return; }
    const evts = (d.events || []);
    if (!evts.length) { b.innerHTML = '<div class="empty">No history yet.</div>'; return; }
    evts.slice().reverse().forEach(e => {
      let extra = '';
      if (e.detail) {
        if (e.detail.changed && e.detail.changed.length) extra += ' changed: ' + e.detail.changed.join(', ');
        if (e.detail.comment) extra += ' "' + e.detail.comment + '"';
        if (e.detail.to) extra += ' to ' + e.detail.to;
        if (e.detail.erpDocNo) extra += ' no. ' + e.detail.erpDocNo + (e.detail.mock ? ' (mock)' : '');
        if (e.detail.reason) extra += ' reason: ' + e.detail.reason;
        if (e.detail.name) extra += ' ' + e.detail.name + (e.detail.size ? ' (' + Math.round(e.detail.size / 1024) + ' KB)' : '');
        if (e.detail.steps && e.detail.steps.length) extra += ' [' + e.detail.steps.join('; ') + ']';
        if (e.detail.error) extra += ' ' + e.detail.error;
      }
      b.appendChild(el('div', 'evt', '<span class="when">' + esc(e.at) + '</span><span class="what">' + esc(e.event) + '</span>' +
        '<span>' + (e.version ? 'v' + e.version + ' ' : '') + esc(e.actor || '') + (e.ip ? ' (' + esc(e.ip) + ')' : '') + esc(extra) + '</span>'));
    });
  }

  if (!docId) { fail('No document id. Open this page from the shipment drawer.'); }
  else { BLForm.load().then(() => load()).catch(e => fail(e.message)); }
})();
