using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    static readonly JsonSerializerOptions DocJson = new() { PropertyNamingPolicy = null, WriteIndented = false };
    static string FieldsJson(Dictionary<string, object?> clean) => JsonSerializer.Serialize(clean, DocJson);

    // ---- GET /api-ops/docs (Handle-DocList) ----
    public static object DocList(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var rows = Db.RunQ(cn, $"SELECT {Doc.HeadCols} FROM dbo.doc_draft WHERE job_no=@j ORDER BY doc_type", new Dictionary<string, object?> { ["j"] = job });
        var scoped = rows.Where(r => Scope.TestJobScope(rs, r)).ToList();
        return new { jobNo = job, docs = scoped.Select(r => Doc.HeadProj(cn, r)).ToArray() };
    }

    // ---- POST /api-ops/doc-create (Save-DocCreate) ----
    public static object DocCreate(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("job_no")) return new { error = "invalid payload" };
        var job = j.Str("job_no").Trim();
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,erp_ref,house_bill,master_bill,shipper_name,consignee_name,vessel_voyage,incoterm,cust_ref,pol,pod,CONVERT(varchar(20),total_weight) total_weight,CONVERT(varchar(20),total_cbm) total_cbm,container_no,route_summary,commodity FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, al[0])) return new { error = "not found" };
        var a = al[0];
        var type = Db.Str(Db.G(a, "mode")) == "Air" ? "HAWB" : "HBL";
        if (j.Has("doc_type") && j.Str("doc_type") != "" && j.Str("doc_type") != type) return new { error = $"this {Db.Str(Db.G(a, "mode"))} shipment takes a {type} document" };
        var dup = Db.RunQ(cn, "SELECT TOP 1 doc_id FROM dbo.doc_draft WHERE job_no=@j AND doc_type=@t", new Dictionary<string, object?> { ["j"] = job, ["t"] = type });
        if (dup.Count > 0) return new { error = "document already exists for this shipment", docId = Db.Str(Db.G(dup[0], "doc_id")) };
        var f = Doc.SaSeed(a, type);
        var seedNote = Doc.ErpSeed(a, f);
        var clean = Doc.CleanFields(type, f);
        var fjson = FieldsJson(clean);
        var docId = Guid.NewGuid().ToString();
        Db.Exec(cn, "INSERT INTO dbo.doc_draft(doc_id,job_no,doc_type,station,mode,bound,status,current_version,created_by,created_at,updated_at) VALUES(@d,@j,@t,@s,@m,@b,'DRAFT',1,@u,SYSDATETIME(),SYSDATETIME())",
            new Dictionary<string, object?> { ["d"] = docId, ["j"] = job, ["t"] = type, ["s"] = Db.Str(Db.G(a, "station")), ["m"] = Db.Str(Db.G(a, "mode")), ["b"] = Db.Str(Db.G(a, "bound")), ["u"] = me });
        Db.Exec(cn, "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,1,'staff',NULL,@f,@c,@u,SYSDATETIME())",
            new Dictionary<string, object?> { ["d"] = docId, ["f"] = fjson, ["c"] = seedNote != "" ? $"seeded from shipment snapshot ({seedNote})" : "seeded from shipment + ERP", ["u"] = me });
        Doc.Event(cn, docId, 1, "created", me, null, "", JsonSerializer.Serialize(new { seedNote }, DocJson));
        Auth.Audit(me, $"doc-create {type} for {job} ({docId})" + (seedNote != "" ? " - " + seedNote : ""));
        return new { ok = true, docId, docType = type, status = "DRAFT", version = 1, seedNote };
    }

    // ---- GET /api-ops/doc (Handle-DocGet) ----
    public static object DocGet(SqlConnection cn, Qs q, ReqState rs)
    {
        var id = (q["id"] ?? "").Trim();
        if (id == "") return new { error = "id required" };
        var h = Doc.GetHead(cn, id, rs); if (h == null) return new { error = "not found" };
        var vno = Db.IntOf(Db.G(h, "current_version"));
        if (System.Text.RegularExpressions.Regex.IsMatch((q["v"] ?? "").Trim(), @"^\d+$")) vno = int.Parse((q["v"] ?? "").Trim());
        var ver = Db.RunQ(cn, "SELECT TOP 1 version_no,side,base_version,fields,comment,created_by,CONVERT(varchar(19),created_at,120) created_at FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = id, ["v"] = vno });
        if (ver.Count == 0) return new { error = "version not found" };
        var flds = ParseNode(Db.Str(Db.G(ver[0], "fields")));
        int? baseNo = null;
        if (System.Text.RegularExpressions.Regex.IsMatch((q["base"] ?? "").Trim(), @"^\d+$")) baseNo = int.Parse((q["base"] ?? "").Trim());
        else if (Db.G(ver[0], "base_version") != null) baseNo = Db.IntOf(Db.G(ver[0], "base_version"));
        JsonNode? baseFlds = null;
        if (baseNo != null && baseNo != vno)
        {
            var bv = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = id, ["v"] = baseNo });
            if (bv.Count > 0) baseFlds = ParseNode(Db.Str(Db.G(bv[0], "fields")));
        }
        var vers = Db.RunQ(cn, "SELECT version_no,side,base_version,comment,created_by,CONVERT(varchar(19),created_at,120) created_at FROM dbo.doc_version WHERE doc_id=@d ORDER BY version_no", new Dictionary<string, object?> { ["d"] = id });
        return new
        {
            head = Doc.HeadProj(cn, h),
            version = new { no = Db.IntOf(Db.G(ver[0], "version_no")), side = Db.Str(Db.G(ver[0], "side")), baseVersion = baseNo, fields = flds, comment = Db.Str(Db.G(ver[0], "comment")), createdBy = Db.Str(Db.G(ver[0], "created_by")), createdAt = Db.Str(Db.G(ver[0], "created_at")) },
            baseFields = baseFlds,
            versions = vers.Select(v => new { no = Db.IntOf(Db.G(v, "version_no")), side = Db.Str(Db.G(v, "side")), @base = Db.G(v, "base_version") == null ? (int?)null : Db.IntOf(Db.G(v, "base_version")), comment = Db.Str(Db.G(v, "comment")), createdBy = Db.Str(Db.G(v, "created_by")), createdAt = Db.Str(Db.G(v, "created_at")) }).ToArray(),
        };
    }

    // ---- GET /api-ops/doc-events (Handle-DocEvents) ----
    public static object DocEvents(SqlConnection cn, Qs q, ReqState rs)
    {
        var id = (q["id"] ?? "").Trim();
        if (id == "") return new { error = "id required" };
        var h = Doc.GetHead(cn, id, rs); if (h == null) return new { error = "not found" };
        var rows = Db.RunQ(cn, "SELECT version_no,event,actor,ip,detail,CONVERT(varchar(19),occurred_at,120) occurred_at FROM dbo.doc_event_log WHERE doc_id=@d ORDER BY occurred_at,id", new Dictionary<string, object?> { ["d"] = id });
        return new { docId = id, events = rows.Select(r => new { version = Db.G(r, "version_no"), @event = Db.Str(Db.G(r, "event")), actor = Db.Str(Db.G(r, "actor")), ip = Db.Str(Db.G(r, "ip")), detail = ParseNode(Db.Str(Db.G(r, "detail"))), at = Db.Str(Db.G(r, "occurred_at")) }).ToArray() };
    }

    // ---- POST /api-ops/doc-save (Save-DocSave) ----
    public static object DocSave(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        var status = Db.Str(Db.G(h, "status"));
        if (status is not ("DRAFT" or "CUSTOMER_SUBMITTED" or "CUSTOMER_APPROVED" or "AMEND_DRAFT"))
            return new { error = $"cannot edit while status is {status}" + (status == "SENT" ? " - revoke the customer link first" : "") };
        var docId = Db.Str(Db.G(h, "doc_id"));
        var clean = Doc.CleanFields(Db.Str(Db.G(h, "doc_type")), j.Has("fields") ? j.GetProperty("fields") : default);
        var cur = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = docId, ["v"] = Db.IntOf(Db.G(h, "current_version")) });
        var changed = DocUtil.Changed(Doc.ParseFields(cur.Count > 0 ? Db.Str(Db.G(cur[0], "fields")) : ""), clean);
        if (changed.Count == 0) return new { error = "no changes to save" };
        var newVer = Db.IntOf(Db.G(h, "current_version")) + 1;
        var cmt = j.Str("comment").Trim(); if (cmt.Length > 1000) cmt = cmt.Substring(0, 1000);
        var newStatus = Doc.DraftState(h);
        Db.Exec(cn, "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,@v,'staff',@b,@f,@c,@u,SYSDATETIME())",
            new Dictionary<string, object?> { ["d"] = docId, ["v"] = newVer, ["b"] = Db.IntOf(Db.G(h, "current_version")), ["f"] = FieldsJson(clean), ["c"] = cmt, ["u"] = me });
        Db.Exec(cn, "UPDATE dbo.doc_draft SET current_version=@v,status=@s,updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["v"] = newVer, ["s"] = newStatus, ["d"] = docId });
        Doc.Event(cn, docId, newVer, "edited", me, null, "", JsonSerializer.Serialize(new { changed, comment = cmt }, DocJson));
        Auth.Audit(me, $"doc-save {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))} v{newVer} (changed: {string.Join(",", changed)})");
        return new { ok = true, version = newVer, status = newStatus, changed };
    }

    // ---- POST /api-ops/doc-send (Save-DocSend) ----
    public static object DocSend(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        var status = Db.Str(Db.G(h, "status"));
        if (status is not ("DRAFT" or "AMEND_DRAFT" or "SENT" or "CUSTOMER_SUBMITTED" or "CUSTOMER_APPROVED")) return new { error = $"cannot send while status is {status}" };
        var docId = Db.Str(Db.G(h, "doc_id"));
        var email = j.Str("customer_email").Trim(); var cname = j.Str("customer_name").Trim();
        if (email != "" && !System.Text.RegularExpressions.Regex.IsMatch(email, @"^[^@\s]+@[^@\s]+\.[^@\s]+$")) return new { error = "invalid customer email" };
        var days = 14; if (int.TryParse(j.Str("expires_days"), out var pd) && pd >= 1 && pd <= 90) days = pd;
        var old = Db.RunQ(cn, "UPDATE dbo.doc_review_token SET revoked=1 OUTPUT INSERTED.token_hash WHERE doc_id=@d AND revoked=0", new Dictionary<string, object?> { ["d"] = docId });
        var raw = Doc.NewRawToken(); var hash = Doc.TokenHash(raw);
        var sentVer = Db.IntOf(Db.G(h, "current_version"));
        Db.Exec(cn, "INSERT INTO dbo.doc_review_token(token_hash,doc_id,sent_version,customer_email,customer_name,expires_at,revoked,created_by,created_at,view_count) VALUES(@h,@d,@v,@e,@n,DATEADD(day,@days,SYSDATETIME()),0,@u,SYSDATETIME(),0)",
            new Dictionary<string, object?> { ["h"] = hash, ["d"] = docId, ["v"] = sentVer, ["e"] = email != "" ? email : null, ["n"] = cname != "" ? cname : null, ["days"] = days, ["u"] = me });
        Db.Exec(cn, "UPDATE dbo.doc_draft SET status='SENT',customer_email=COALESCE(NULLIF(@e,''),customer_email),customer_name=COALESCE(NULLIF(@n,''),customer_name),updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["e"] = email, ["n"] = cname, ["d"] = docId });
        Doc.Event(cn, docId, sentVer, "sent", me, hash, "", JsonSerializer.Serialize(new { to = email, expiresDays = days, revokedPrior = old.Count }, DocJson));
        var basePrefix = Settings.PublicBaseUrl.Trim() != "" ? Settings.PublicBaseUrl.Trim().TrimEnd('/') : $"http://localhost:{Config.Port}";
        Auth.Audit(me, $"doc-send {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))} v{sentVer} to '{email}' (expires {days}d)");
        return new { ok = true, link = $"{basePrefix}/bl-review/{raw}", expiresDays = days, sentVersion = sentVer, status = "SENT" };
    }

    // ---- POST /api-ops/doc-token-revoke (Save-DocTokenRevoke) ----
    public static object DocTokenRevoke(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        var docId = Db.Str(Db.G(h, "doc_id"));
        var old = Db.RunQ(cn, "UPDATE dbo.doc_review_token SET revoked=1 OUTPUT INSERTED.token_hash WHERE doc_id=@d AND revoked=0", new Dictionary<string, object?> { ["d"] = docId });
        var newStatus = Db.Str(Db.G(h, "status"));
        if (newStatus == "SENT") { newStatus = Doc.DraftState(h); Db.Exec(cn, "UPDATE dbo.doc_draft SET status=@s,updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["s"] = newStatus, ["d"] = docId }); }
        Doc.Event(cn, docId, null, "token_revoked", me, null, "", JsonSerializer.Serialize(new { revoked = old.Count }, DocJson));
        Auth.Audit(me, $"doc-token-revoke {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))} ({old.Count} link(s))");
        return new { ok = true, revoked = old.Count, status = newStatus };
    }

    static Row? DocSaRow(SqlConnection cn, string job)
    {
        var sa = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,sono,carrier,pol,pod,commodity,master_bill,incoterm FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        return sa.Count > 0 ? sa[0] : null;
    }

    // ---- POST /api-ops/doc-agree (Save-DocAgree) ----
    public static object DocAgree(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        if (Db.Str(Db.G(h, "status")) != "CUSTOMER_APPROVED") return new { error = $"agree requires CUSTOMER_APPROVED (now {Db.Str(Db.G(h, "status"))})" };
        var docId = Db.Str(Db.G(h, "doc_id")); var ver = Db.IntOf(Db.G(h, "current_version"));
        var vrow = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = docId, ["v"] = ver });
        var flds = vrow.Count > 0 ? ParseNode(Db.Str(Db.G(vrow[0], "fields"))) : null;
        var erp = Erp.DocAgree(h, flds, DocSaRow(cn, Db.Str(Db.G(h, "job_no"))), me);
        Db.Exec(cn, "UPDATE dbo.doc_draft SET status='AGREED',updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["d"] = docId });
        Doc.Event(cn, docId, ver, "agreed", me, null, "", null);
        if (erp.Ok && !erp.Rejected) Doc.Event(cn, docId, ver, "erp_booking_saved", me, null, "", JsonSerializer.Serialize(new { mock = erp.Mock, steps = erp.Steps }, DocJson));
        else Doc.Event(cn, docId, ver, "erp_error", me, null, "", JsonSerializer.Serialize(new { step = "booking/update", error = erp.Error != "" ? erp.Error : (erp.Steps.Count > 0 ? erp.Steps[^1] : "") }, DocJson));
        Auth.Audit(me, $"doc-agree {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))} v{ver} [erp: {string.Join("; ", erp.Steps)}{(erp.Error != "" ? " ERR " + erp.Error : "")}]");
        return new { ok = true, status = "AGREED", erp = new { ok = erp.Ok, mock = erp.Mock, rejected = erp.Rejected, steps = erp.Steps, error = erp.Error } };
    }

    // ---- POST /api-ops/doc-issue (Save-DocIssue) ----
    public static object DocIssue(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        if (Db.Str(Db.G(h, "status")) != "AGREED") return new { error = $"issue requires AGREED (now {Db.Str(Db.G(h, "status"))})" };
        var docId = Db.Str(Db.G(h, "doc_id")); var ver = Db.IntOf(Db.G(h, "current_version"));
        var docType = Db.Str(Db.G(h, "doc_type")); var job = Db.Str(Db.G(h, "job_no"));
        var vrow = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = docId, ["v"] = ver });
        var fieldsJson = vrow.Count > 0 ? Db.Str(Db.G(vrow[0], "fields")) : "{}";
        var flds = ParseNode(fieldsJson);
        // optional operator-attached agreed PDF, else auto-generate (headless print-to-PDF)
        Erp.DocFile? att = null;
        if (j.Str("pdf_base64").Trim() != "")
        {
            var nm = System.Text.RegularExpressions.Regex.Replace(j.Str("pdf_name").Trim(), @"[^\w.\- ]", "");
            if (nm == "") nm = $"agreed-{docType}-{job}.pdf";
            att = new Erp.DocFile(nm, j.Str("pdf_base64").Trim());
        }
        if (att == null)
        {
            var gen = Pdf.Render(docType, fieldsJson);
            if (gen != null) att = new Erp.DocFile($"agreed-{docType}-{job}.pdf", gen);
        }
        var riders = new List<Erp.DocFile>();
        foreach (var ar in Db.RunQ(cn, "SELECT file_name,bytes FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 ORDER BY uploaded_at", new Dictionary<string, object?> { ["d"] = docId }))
            riders.Add(new Erp.DocFile(Db.Str(Db.G(ar, "file_name")), Convert.ToBase64String((byte[])Db.G(ar, "bytes")!)));
        var r = Erp.DocIssue(h, flds, DocSaRow(cn, job), me, att, riders);
        if (!r.Ok)
        {
            Doc.Event(cn, docId, ver, "erp_error", me, null, "", JsonSerializer.Serialize(new { error = r.Error }, DocJson));
            return new { error = r.Error };
        }
        Db.Exec(cn, "UPDATE dbo.doc_draft SET status='ISSUED',erp_doc_no=@no,issued_at=SYSDATETIME(),updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["no"] = r.DocNo, ["d"] = docId });
        Db.Exec(cn, "UPDATE dbo.doc_review_token SET revoked=1 WHERE doc_id=@d AND revoked=0", new Dictionary<string, object?> { ["d"] = docId });
        Doc.Event(cn, docId, ver, "issued", me, null, "", JsonSerializer.Serialize(new { erpDocNo = r.DocNo, mock = r.Mock, steps = r.Steps, pdfAttached = att != null }, DocJson));
        Auth.Audit(me, $"doc-issue {docType} {job} v{ver} -> {r.DocNo}{(r.Mock ? " (MOCK)" : "")} [{string.Join("; ", r.Steps)}]");
        return new { ok = true, status = "ISSUED", erpDocNo = r.DocNo, mock = r.Mock, steps = r.Steps };
    }

    // ---- POST /api-ops/doc-amend (Save-DocAmend) ----
    public static object DocAmend(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        if (Db.Str(Db.G(h, "status")) != "ISSUED") return new { error = $"amend requires ISSUED (now {Db.Str(Db.G(h, "status"))})" };
        var docId = Db.Str(Db.G(h, "doc_id")); var ver = Db.IntOf(Db.G(h, "current_version"));
        var reason = j.Str("reason").Trim();
        var amendNo = Db.IntOf(Db.G(h, "amend_count")) + 1;
        Db.Exec(cn, "UPDATE dbo.doc_draft SET status='AMEND_DRAFT',amend_count=amend_count+1,updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["d"] = docId });
        Doc.Event(cn, docId, ver, "amend_opened", me, null, "", JsonSerializer.Serialize(new { reason, feeApplies = true, amendNo }, DocJson));
        Auth.Audit(me, $"doc-amend {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))} (amend #{amendNo}, fee applies)" + (reason != "" ? ": " + reason : ""));
        return new { ok = true, status = "AMEND_DRAFT", amendCount = amendNo, feeApplies = true };
    }
}
