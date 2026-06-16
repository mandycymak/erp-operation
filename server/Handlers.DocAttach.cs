using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // rider documents uploaded by staff (pushed to ERP /file/upload at issue). pdf/png/jpeg, <=5MB, max 20/doc.
    // ---- POST /api-ops/doc-attach (Save-DocAttach) ----
    public static object DocAttachSave(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        if (Db.Str(Db.G(h, "status")) == "ISSUED") return new { error = "document is issued - open an amendment first" };
        var docId = Db.Str(Db.G(h, "doc_id"));
        var cnt = Db.RunQ(cn, "SELECT COUNT(*) n FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0", new Dictionary<string, object?> { ["d"] = docId });
        if (Db.IntOf(Db.G(cnt[0], "n")) >= 20) return new { error = "attachment limit reached (20)" };
        var v = DocUtil.AttachValidate(j.Str("file_name"), j.Str("content_type"), j.Str("base64"));
        if (!v.Ok) return new { error = v.Err };
        var attId = Guid.NewGuid().ToString();
        Db.Exec(cn, "INSERT INTO dbo.doc_attachment(att_id,doc_id,file_name,content_type,bytes,size_bytes,uploaded_side,uploaded_by,uploaded_at,deleted) VALUES(@a,@d,@n,@c,@b,@s,'staff',@u,SYSDATETIME(),0)",
            new Dictionary<string, object?> { ["a"] = attId, ["d"] = docId, ["n"] = v.Name, ["c"] = v.Ctype, ["b"] = v.Bytes, ["s"] = v.Bytes.Length, ["u"] = me });
        Doc.Event(cn, docId, null, "attach_added", me, null, "", JsonSerializer.Serialize(new { name = v.Name, size = v.Bytes.Length }, DocJson));
        Auth.Audit(me, $"doc-attach {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))}: {v.Name} ({v.Bytes.Length} bytes)");
        return new { ok = true, id = attId, attachments = Doc.AttachList(cn, docId) };
    }

    // ---- GET /api-ops/doc-attach-list (Handle-DocAttachListQ) ----
    public static object DocAttachListQ(SqlConnection cn, Qs q, ReqState rs)
    {
        var id = (q["id"] ?? "").Trim();
        if (id == "") return new { error = "id required" };
        var h = Doc.GetHead(cn, id, rs); if (h == null) return new { error = "not found" };
        return new { attachments = Doc.AttachList(cn, id) };
    }

    // ---- GET /api-ops/doc-attach-file (Handle-DocAttachFile) -> blob ----
    public static BlobResult? DocAttachFile(SqlConnection cn, Qs q, ReqState rs)
    {
        var id = (q["id"] ?? "").Trim(); var att = (q["att"] ?? "").Trim();
        if (id == "" || att == "") return null;
        var h = Doc.GetHead(cn, id, rs); if (h == null) return null;
        var r = Db.RunQ(cn, "SELECT TOP 1 file_name,content_type,bytes FROM dbo.doc_attachment WHERE att_id=@a AND doc_id=@d AND deleted=0", new Dictionary<string, object?> { ["a"] = att, ["d"] = id });
        if (r.Count == 0) return null;
        return new BlobResult((byte[])Db.G(r[0], "bytes")!, Db.Str(Db.G(r[0], "content_type")), Db.Str(Db.G(r[0], "file_name")));
    }

    // ---- POST /api-ops/doc-attach-delete (Save-DocAttachDelete) ----
    public static object DocAttachDelete(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("doc_id") || !j.Has("att_id")) return new { error = "invalid payload" };
        var h = Doc.GetHead(cn, j.Str("doc_id"), rs); if (h == null) return new { error = "not found" };
        if (Db.Str(Db.G(h, "status")) == "ISSUED") return new { error = "document is issued - attachments are locked" };
        var docId = Db.Str(Db.G(h, "doc_id"));
        var old = Db.RunQ(cn, "UPDATE dbo.doc_attachment SET deleted=1 OUTPUT INSERTED.file_name WHERE att_id=@a AND doc_id=@d AND deleted=0", new Dictionary<string, object?> { ["a"] = j.Str("att_id"), ["d"] = docId });
        if (old.Count == 0) return new { error = "not found" };
        Doc.Event(cn, docId, null, "attach_removed", me, null, "", JsonSerializer.Serialize(new { name = Db.Str(Db.G(old[0], "file_name")) }, DocJson));
        Auth.Audit(me, $"doc-attach-delete {Db.Str(Db.G(h, "doc_type"))} {Db.Str(Db.G(h, "job_no"))}: {Db.Str(Db.G(old[0], "file_name"))}");
        return new { ok = true, attachments = Doc.AttachList(cn, docId) };
    }
}
