// bl-review.js - public customer review page. The token in the URL (/bl-review/<token>) is the only
// credential: no login, no cookies. Reads /api-doc/view, lets the customer edit the bill boxes in place,
// and posts back via /api-doc/submit (corrections -> new customer version) or /api-doc/approve.
'use strict';
(function () {
  const $ = s => document.querySelector(s);
  const token = (location.pathname.split('/bl-review/')[1] || '').trim();
  let DOC = null;          // /api-doc/view payload
  let SENT = null;         // the fields exactly as staff sent them (diff base + undo target)

  function fail(msg) {
    $('#msg').innerHTML = '<div class="err">' + msg + '</div>';
    $('#howto').style.display = 'none'; $('#actions').style.display = 'none';
  }
  async function api(path, body) {
    const r = await fetch(path, body
      ? { method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
      : { cache: 'no-store' });
    return r.json();
  }

  async function init() {
    if (!token) { fail('No review token in the link.'); return; }
    await BLForm.load();
    const d = await api('/api-doc/view?t=' + encodeURIComponent(token));
    if (d.error) { fail(d.error); return; }
    DOC = d;
    SENT = Object.assign({}, d.fields || {});
    $('#title').textContent = (d.docType === 'HAWB' ? 'House Air Waybill' : 'House Bill of Lading') + ' - draft for your review';
    const st = $('#status'); st.style.display = ''; st.className = 'badge ' + d.status;
    st.textContent = d.status === 'SENT' ? 'AWAITING YOUR REVIEW'
      : d.status === 'CUSTOMER_SUBMITTED' ? 'CORRECTIONS SENT - UNDER REVIEW'
      : d.status === 'CUSTOMER_APPROVED' ? 'APPROVED BY YOU' : d.status;
    $('#printBtn').style.display = ''; $('#printBtn').onclick = () => window.print();
    const sz = $('#sizeBtn'); sz.style.display = '';
    sz.textContent = 'Paper: ' + BLForm.setPrintSize(BLForm.getPrintSize());
    sz.onclick = () => { sz.textContent = 'Paper: ' + BLForm.setPrintSize(BLForm.getPrintSize() === 'A4' ? 'F4' : 'A4'); };
    BLForm.render($('#doc'), d.docType, d.fields, { editable: !!d.editable });
    loadAttachments();
    if (d.editable) {
      $('#howto').style.display = ''; $('#actions').style.display = '';
      $('#submitBtn').onclick = submit;
      $('#approveBtn').onclick = approve;
      $('#resetBtn').onclick = () => BLForm.render($('#doc'), DOC.docType, SENT, { editable: true });
    } else {
      $('#msg').innerHTML = '<div class="note">This document is now read-only' +
        (d.status === 'CUSTOMER_SUBMITTED' ? ' - your corrections were sent to the forwarder. You will receive a new link if a revised draft is issued.' : '.') + '</div>';
    }
  }

  // attachment files (supporting documents): list/download always; upload + delete-own only while SENT
  const escA = s => ('' + (s == null ? '' : s)).replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  async function loadAttachments() {
    const d = await api('/api-doc/attach-list?t=' + encodeURIComponent(token));
    if (d.error) { $('#attCard').style.display = 'none'; return; }
    const list = d.attachments || [];
    const canEdit = !!d.editable;
    $('#attCard').style.display = (list.length || canEdit) ? '' : 'none';
    const host = $('#attList'); host.innerHTML = '';
    if (!list.length) host.innerHTML = '<div class="mut">No attachment files.</div>';
    list.forEach(a => {
      const row = document.createElement('div'); row.className = 'attrow';
      row.innerHTML = '<a href="/api-doc/attach-file?t=' + encodeURIComponent(token) + '&id=' + encodeURIComponent(a.id) + '" target="_blank">' + escA(a.name) + '</a>' +
        ' <span class="mut">' + Math.round(a.size / 1024) + ' KB · ' + (a.side === 'customer' ? 'uploaded by you' : 'from forwarder') + '</span>';
      if (canEdit && a.side === 'customer') {
        const del = document.createElement('button'); del.textContent = '✕'; del.title = 'Remove';
        del.onclick = async () => {
          if (!confirm('Remove ' + a.name + '?')) return;
          const r = await api('/api-doc/attach-delete', { t: token, id: a.id });
          if (r.error) { alert(r.error); return; }
          loadAttachments();
        };
        row.appendChild(del);
      }
      host.appendChild(row);
    });
    $('#attUpload').style.display = canEdit ? '' : 'none';
    if (canEdit) $('#attFile').onchange = uploadAttachment;
  }
  async function uploadAttachment() {
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
    const r = await api('/api-doc/attach', { t: token, file_name: f.name, content_type: f.type, base64 });
    $('#attFile').value = '';
    if (r.error) { alert(r.error); return; }
    loadAttachments();
  }

  async function submit() {
    const fields = BLForm.collect($('#doc'));
    const changed = BLForm.diff(DOC.docType, SENT, fields);
    const comment = $('#comment').value.trim();
    if (!changed.length && !comment) { alert('You have not changed anything. If the document is correct, press Approve instead.'); return; }
    if (!confirm('Send ' + (changed.length ? changed.length + ' correction(s)' : 'your message') + ' to the forwarder?')) return;
    $('#submitBtn').disabled = true;
    const r = await api('/api-doc/submit', { t: token, fields, comment });
    $('#submitBtn').disabled = false;
    if (r.error) { alert(r.error); return; }
    $('#msg').innerHTML = '<div class="note"><b>Thank you.</b> Your corrections were sent to the forwarder for review.</div>';
    $('#howto').style.display = 'none'; $('#actions').style.display = 'none';
    BLForm.render($('#doc'), DOC.docType, fields, { editable: false, diffFrom: SENT });
    $('#status').className = 'badge CUSTOMER_SUBMITTED'; $('#status').textContent = 'CORRECTIONS SENT - UNDER REVIEW';
  }

  async function approve() {
    const fields = BLForm.collect($('#doc'));
    if (BLForm.diff(DOC.docType, SENT, fields).length) {
      alert('You have edited some boxes. Please use "Send corrections" instead (or undo your edits first).'); return;
    }
    if (!confirm('Approve this document as correct? The official document will then be issued.')) return;
    $('#approveBtn').disabled = true;
    const r = await api('/api-doc/approve', { t: token, comment: $('#comment').value.trim() });
    $('#approveBtn').disabled = false;
    if (r.error) { alert(r.error); return; }
    $('#msg').innerHTML = '<div class="note"><b>Thank you.</b> Your approval was recorded. The official document will be issued by your forwarder.</div>';
    $('#howto').style.display = 'none'; $('#actions').style.display = 'none';
    BLForm.render($('#doc'), DOC.docType, SENT, { editable: false });
    $('#status').className = 'badge CUSTOMER_APPROVED'; $('#status').textContent = 'APPROVED BY YOU';
  }

  init().catch(e => fail('Could not load the document: ' + e.message));
})();
