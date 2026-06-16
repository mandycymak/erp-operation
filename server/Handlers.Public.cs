using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// public customer handlers (/api-doc/*: the token IS the authority - no session, no cookies). Each validates the
// token SHAPE before any SQL, reads only doc_* tables (8s timeouts), logs every access with IP. All failure modes
// return ONE generic message. Mirrors the serve-ops.ps1 Handle-PublicDoc* family.
public static partial class Handlers
{
    public static readonly object DocLinkErr = new { error = "This review link is invalid, expired, or already closed. Please contact your forwarder for a fresh link." };
    static readonly Regex TokenShape = new(@"^[A-Za-z0-9_-]{40,64}$", RegexOptions.Compiled);

    static Row? GetDocByToken(SqlConnection cn, string raw)
    {
        if (!TokenShape.IsMatch(raw)) return null;
        var r = Db.RunQ(cn, "SELECT TOP 1 t.token_hash,t.doc_id,t.sent_version,t.customer_email,t.customer_name,CONVERT(varchar(19),t.expires_at,120) expires_at,t.revoked,d.status,d.doc_type,d.job_no,d.current_version FROM dbo.doc_review_token t JOIN dbo.doc_draft d ON d.doc_id=t.doc_id WHERE t.token_hash=@h",
            new Dictionary<string, object?> { ["h"] = Doc.TokenHash(raw) }, 8);
        if (r.Count == 0) return null;
        var t = r[0];
        if (Convert.ToInt32(Db.G(t, "revoked")) != 0) return null;
        if (DateTime.TryParse(Db.Str(Db.G(t, "expires_at")), out var exp) && exp < DateTime.Now) return null;
        return t;
    }

    static string CustBy(Row t) { var e = Db.Str(Db.G(t, "customer_email")).Trim(); return "customer" + (e != "" ? ":" + e : ""); }

    // ---- GET /api-doc/view ----
    public static object PublicDocView(SqlConnection cn, string raw, string ip)
    {
        if (!TokenShape.IsMatch(raw)) return DocLinkErr;
        var t = GetDocByToken(cn, raw); if (t == null) return DocLinkErr;
        var status = Db.Str(Db.G(t, "status"));
        if (status is not ("SENT" or "CUSTOMER_SUBMITTED" or "CUSTOMER_APPROVED")) return DocLinkErr;
        var editable = status == "SENT";
        var vno = editable ? Db.IntOf(Db.G(t, "sent_version")) : Db.IntOf(Db.G(t, "current_version"));
        var ver = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = Db.Str(Db.G(t, "doc_id")), ["v"] = vno }, 8);
        if (ver.Count == 0) return DocLinkErr;
        var flds = ParseNode(Db.Str(Db.G(ver[0], "fields")));
        Db.Exec(cn, "UPDATE dbo.doc_review_token SET view_count=view_count+1,last_view_at=SYSDATETIME() WHERE token_hash=@h", new Dictionary<string, object?> { ["h"] = Db.Str(Db.G(t, "token_hash")) }, 8);
        Doc.Event(cn, Db.Str(Db.G(t, "doc_id")), vno, "viewed", "customer", Db.Str(Db.G(t, "token_hash")), ip, null);
        return new { docType = Db.Str(Db.G(t, "doc_type")), jobNo = Db.Str(Db.G(t, "job_no")), status, editable, versionNo = vno, fields = flds, customerName = Db.Str(Db.G(t, "customer_name")) };
    }

    // ---- POST /api-doc/submit  &  /api-doc/approve (approveOnly) ----
    public static object PublicDocSubmit(SqlConnection cn, JsonElement j, string ip, bool approveOnly)
    {
        var raw = j.Str("t").Trim();
        if (!TokenShape.IsMatch(raw)) return DocLinkErr;
        var t = GetDocByToken(cn, raw); if (t == null) return DocLinkErr;
        if (Db.Str(Db.G(t, "status")) != "SENT") return DocLinkErr;   // customer can act only while SENT
        var docId = Db.Str(Db.G(t, "doc_id"));
        var cmt = j.Str("comment").Trim(); if (cmt.Length > 1000) cmt = cmt.Substring(0, 1000);
        var by = CustBy(t);
        if (approveOnly)
        {
            Db.Exec(cn, "UPDATE dbo.doc_draft SET status='CUSTOMER_APPROVED',updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["d"] = docId }, 8);
            Doc.Event(cn, docId, Db.IntOf(Db.G(t, "sent_version")), "approved", by, Db.Str(Db.G(t, "token_hash")), ip, JsonSerializer.Serialize(new { comment = cmt }, DocJson));
            return new { ok = true, status = "CUSTOMER_APPROVED" };
        }
        var clean = Doc.CleanFields(Db.Str(Db.G(t, "doc_type")), j.Has("fields") ? j.GetProperty("fields") : default);
        var sent = Db.RunQ(cn, "SELECT TOP 1 fields FROM dbo.doc_version WHERE doc_id=@d AND version_no=@v", new Dictionary<string, object?> { ["d"] = docId, ["v"] = Db.IntOf(Db.G(t, "sent_version")) }, 8);
        var changed = DocUtil.Changed(Doc.ParseFields(sent.Count > 0 ? Db.Str(Db.G(sent[0], "fields")) : ""), clean);
        if (changed.Count == 0 && cmt == "") return new { error = "No changes were made. If the document is correct, use Approve instead." };
        var newVer = Db.IntOf(Db.G(t, "current_version")) + 1;
        Db.Exec(cn, "INSERT INTO dbo.doc_version(doc_id,version_no,side,base_version,fields,comment,created_by,created_at) VALUES(@d,@v,'customer',@b,@f,@c,@u,SYSDATETIME())",
            new Dictionary<string, object?> { ["d"] = docId, ["v"] = newVer, ["b"] = Db.IntOf(Db.G(t, "sent_version")), ["f"] = FieldsJson(clean), ["c"] = cmt, ["u"] = by }, 8);
        Db.Exec(cn, "UPDATE dbo.doc_draft SET status='CUSTOMER_SUBMITTED',current_version=@v,updated_at=SYSDATETIME() WHERE doc_id=@d", new Dictionary<string, object?> { ["v"] = newVer, ["d"] = docId }, 8);
        Doc.Event(cn, docId, newVer, "submitted", by, Db.Str(Db.G(t, "token_hash")), ip, JsonSerializer.Serialize(new { changed, comment = cmt }, DocJson));
        return new { ok = true, status = "CUSTOMER_SUBMITTED", version = newVer, changed };
    }

    // ---- POST /api-doc/attach (customer upload; only while SENT; max 10 customer files) ----
    public static object PublicDocAttach(SqlConnection cn, JsonElement j, string ip)
    {
        var raw = j.Str("t").Trim();
        if (!TokenShape.IsMatch(raw)) return DocLinkErr;
        var t = GetDocByToken(cn, raw); if (t == null) return DocLinkErr;
        if (Db.Str(Db.G(t, "status")) != "SENT") return DocLinkErr;
        var docId = Db.Str(Db.G(t, "doc_id"));
        var cnt = Db.RunQ(cn, "SELECT COUNT(*) n FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 AND uploaded_side='customer'", new Dictionary<string, object?> { ["d"] = docId }, 8);
        if (Db.IntOf(Db.G(cnt[0], "n")) >= 10) return new { error = "attachment limit reached (10)" };
        var v = DocUtil.AttachValidate(j.Str("file_name"), j.Str("content_type"), j.Str("base64"));
        if (!v.Ok) return new { error = v.Err };
        var by = CustBy(t);
        var attId = Guid.NewGuid().ToString();
        Db.Exec(cn, "INSERT INTO dbo.doc_attachment(att_id,doc_id,file_name,content_type,bytes,size_bytes,uploaded_side,uploaded_by,uploaded_at,deleted) VALUES(@a,@d,@n,@c,@b,@s,'customer',@u,SYSDATETIME(),0)",
            new Dictionary<string, object?> { ["a"] = attId, ["d"] = docId, ["n"] = v.Name, ["c"] = v.Ctype, ["b"] = v.Bytes, ["s"] = v.Bytes.Length, ["u"] = by }, 8);
        Doc.Event(cn, docId, null, "attach_added", by, Db.Str(Db.G(t, "token_hash")), ip, JsonSerializer.Serialize(new { name = v.Name, size = v.Bytes.Length }, DocJson));
        return new { ok = true, id = attId, attachments = Doc.AttachList(cn, docId) };
    }

    // ---- GET /api-doc/attach-list ----
    public static object PublicDocAttachList(SqlConnection cn, string raw)
    {
        if (!TokenShape.IsMatch(raw)) return DocLinkErr;
        var t = GetDocByToken(cn, raw); if (t == null) return DocLinkErr;
        if (Db.Str(Db.G(t, "status")) is not ("SENT" or "CUSTOMER_SUBMITTED" or "CUSTOMER_APPROVED")) return DocLinkErr;
        return new { editable = Db.Str(Db.G(t, "status")) == "SENT", attachments = Doc.AttachList(cn, Db.Str(Db.G(t, "doc_id"))) };
    }

    // ---- GET /api-doc/attach-file -> blob ----
    public static BlobResult? PublicDocAttachFile(SqlConnection cn, string raw, string att)
    {
        if (!TokenShape.IsMatch(raw) || att == "") return null;
        var t = GetDocByToken(cn, raw); if (t == null) return null;
        if (Db.Str(Db.G(t, "status")) is not ("SENT" or "CUSTOMER_SUBMITTED" or "CUSTOMER_APPROVED")) return null;
        var r = Db.RunQ(cn, "SELECT TOP 1 file_name,content_type,bytes FROM dbo.doc_attachment WHERE att_id=@a AND doc_id=@d AND deleted=0", new Dictionary<string, object?> { ["a"] = att, ["d"] = Db.Str(Db.G(t, "doc_id")) }, 8);
        if (r.Count == 0) return null;
        return new BlobResult((byte[])Db.G(r[0], "bytes")!, Db.Str(Db.G(r[0], "content_type")), Db.Str(Db.G(r[0], "file_name")));
    }

    // ---- POST /api-doc/attach-delete (customer removes ONLY their own uploads, only while SENT) ----
    public static object PublicDocAttachDelete(SqlConnection cn, JsonElement j, string ip)
    {
        var raw = j.Str("t").Trim();
        if (!TokenShape.IsMatch(raw)) return DocLinkErr;
        var t = GetDocByToken(cn, raw); if (t == null) return DocLinkErr;
        if (Db.Str(Db.G(t, "status")) != "SENT") return DocLinkErr;
        var docId = Db.Str(Db.G(t, "doc_id"));
        var old = Db.RunQ(cn, "UPDATE dbo.doc_attachment SET deleted=1 OUTPUT INSERTED.file_name WHERE att_id=@a AND doc_id=@d AND deleted=0 AND uploaded_side='customer'", new Dictionary<string, object?> { ["a"] = j.Str("id"), ["d"] = docId }, 8);
        if (old.Count == 0) return new { error = "not found" };
        Doc.Event(cn, docId, null, "attach_removed", CustBy(t), Db.Str(Db.G(t, "token_hash")), ip, JsonSerializer.Serialize(new { name = Db.Str(Db.G(old[0], "file_name")) }, DocJson));
        return new { ok = true, attachments = Doc.AttachList(cn, docId) };
    }
}
