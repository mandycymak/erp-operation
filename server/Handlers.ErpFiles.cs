using System.Text.Json;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    // ordered identifier candidates (ops rule): Air HAWB -> Booking -> MAWB ; Sea Booking(sono) -> HBL.
    static List<(string Kind, string Val)> FileCandidates(bool isAir, string sono, string hbl, string mbl) => isAir
        ? new() { ("HAWB", hbl), ("Booking", sono), ("MAWB", mbl) }
        : new() { ("Booking", sono), ("HBL", hbl) };

    // ---- /api-ops/erp-files (serve-ops.ps1 Handle-ErpFiles 725-741) ----
    // List the files the Swivel ERP holds for this shipment + which doctypes, if uploaded, would clear a milestone.
    public static object ErpFiles(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, al[0])) return new { error = "not found" };
        var a = al[0];
        var isAir = Db.Str(Db.G(a, "mode")) == "Air"; var module = isAir ? "AIR" : "SEA";
        var bound = Db.Str(Db.G(a, "bound"));
        var cands = FileCandidates(isAir, Db.Str(Db.G(a, "sono")).Trim(), Db.Str(Db.G(a, "house_bill")).Trim(), Db.Str(Db.G(a, "master_bill")).Trim());
        if (!cands.Any(c => c.Val.Trim() != "")) return new { error = "no booking / bill number on this shipment to query the ERP" };

        var r = Erp.FileEnquiry(module, cands, Source.ForwarderCode(Db.Str(Db.G(a, "station"))));
        // doctypes whose upload would clear a milestone on THIS shipment (derived from the evidence map, cached)
        var dmap = DoctypeMap.Get(cn);
        var clearable = new List<string>();
        foreach (var kv in dmap)
            if (kv.Value.Any(ms => ms.Bound == bound && (ms.Module == "" || ms.Module == module)))
                clearable.Add(kv.Key);
        // ALL configured ERP document types (admin Documents tab) - so an operator can upload any document,
        // not only one that clears an alert. The upload handler accepts any doctype; clearing is a bonus.
        var allDoctypes = dmap.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase).ToArray();

        return new
        {
            keyUsed = r.KeyUsed, keyKind = r.KeyKind, keyField = r.KeyField, mock = r.Mock,
            files = r.Files, error = r.Error, clearableDoctypes = clearable.Distinct().ToArray(),
            uploadDoctypes = allDoctypes,
        };
    }

    // ---- POST /api-ops/erp-file-upload (serve-ops.ps1 Handle-ErpFileUpload 746-781) ----
    // Upload a missing document to the ERP and, on success, clear the milestone(s) that document satisfies. The
    // successful upload IS the proof. On ERP failure nothing clears. Body: { job, doctype, fileName, content_type, base64 }.
    public static object ErpFileUpload(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("job")) return new { error = "invalid payload" };
        var job = j.Str("job").Trim();
        var doctype = j.Str("doctype").Trim();
        if (doctype == "") return new { error = "choose a document type" };
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, al[0])) return new { error = "not found" };
        var a = al[0];
        var isAir = Db.Str(Db.G(a, "mode")) == "Air"; var module = isAir ? "AIR" : "SEA";
        var bound = Db.Str(Db.G(a, "bound"));
        // validate the file (pdf/png/jpeg, magic-byte, <=5MB) - same rules as draft-doc attachments
        var v = DocUtil.AttachValidate(j.Str("fileName"), j.Str("content_type"), j.Str("base64"));
        if (!v.Ok) return new { error = v.Err };
        // which milestones would this doctype clear for this shipment? (derived, cached)
        var dmap = DoctypeMap.Get(cn);
        var codes = dmap.TryGetValue(doctype, out var links)
            ? links.Where(ms => ms.Bound == bound && (ms.Module == "" || ms.Module == module)).Select(ms => ms.Code).Distinct().ToArray()
            : Array.Empty<string>();
        // the doctype IS the ERP Document Type code (admin-maintained to match the ERP) - send it verbatim.
        var houseNo = Db.Str(Db.G(a, "house_bill")).Trim();
        var bookingNo = Db.Str(Db.G(a, "sono")).Trim(); if (bookingNo == "") bookingNo = Db.Str(Db.G(a, "master_bill")).Trim();
        var remark = $"Uploaded via Control Tower by {me} to clear '{doctype}'";
        var up = Erp.FileUpload(module, houseNo, bookingNo, doctype, v.Name, Convert.ToBase64String(v.Bytes), remark, Source.ForwarderCode(Db.Str(Db.G(a, "station"))));
        if (!up.Ok) { Auth.Audit(me, $"erp-file-upload {job} '{doctype}' FAILED: {up.Error}"); return new { error = "ERP upload failed: " + up.Error }; }
        // success: the upload is the proof - clear the milestone(s) locally
        var cleared = Array.Empty<string>();
        if (codes.Length > 0)
        {
            var cr = Milestones.CloseFor(cn, job, codes, $"document: {doctype} ({v.Name}) uploaded to ERP", me);
            if (cr.Ok) cleared = cr.Cleared;
        }
        Auth.Audit(me, $"erp-file-upload {job} '{doctype}' ({v.Bytes.Length} bytes){(up.Mock ? " [mock]" : "")} -> cleared [{string.Join(",", cleared)}]");
        return new { ok = true, mock = up.Mock, doctype, fileName = v.Name, cleared };
    }

    public sealed record BlobResult(byte[] Bytes, string Ctype, string Name);

    // ---- GET /api-ops/erp-file-download (serve-ops.ps1 Handle-ErpFileDownload 784-806) ----
    // Resolve + stream one ERP-held file's bytes. Returns null (-> 404) on mock / not-found, matching the PS path
    // that returns $false so the router sends no JSON.
    public static BlobResult? ErpFileDownload(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim(); var file = (q["file"] ?? "").Trim();
        if (job == "") return null;
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,sono,house_bill,master_bill FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return null;
        if (!Scope.TestJobScope(rs, al[0])) return null;
        var a = al[0];
        var isAir = Db.Str(Db.G(a, "mode")) == "Air"; var module = isAir ? "AIR" : "SEA";
        var cands = FileCandidates(isAir, Db.Str(Db.G(a, "sono")).Trim(), Db.Str(Db.G(a, "house_bill")).Trim(), Db.Str(Db.G(a, "master_bill")).Trim());
        if (!cands.Any(c => c.Val.Trim() != "")) return null;
        var r = Erp.FileDownload(module, cands, file, Source.ForwarderCode(Db.Str(Db.G(a, "station"))));
        if (r.Mock || r.Bytes == null) return null;
        var name = r.FileName.Trim() != "" ? r.FileName.Trim() : (file != "" ? file : "erp-file");
        var ct = (Path.GetExtension(name).ToLowerInvariant()) switch
        {
            ".pdf" => "application/pdf", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
            ".txt" => "text/plain; charset=utf-8", ".csv" => "text/csv; charset=utf-8", ".xml" => "application/xml",
            ".doc" => "application/msword", ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".xls" => "application/vnd.ms-excel", ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            _ => "application/octet-stream",
        };
        return new BlobResult(r.Bytes, ct, name);
    }
}
