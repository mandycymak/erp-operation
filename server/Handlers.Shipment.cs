using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/shipment (serve-ops.ps1 636-651) ----
    public static object Shipment(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var rows = Db.RunQ(cn,
            "SELECT TOP 1 job_no,station,mode,bound,milestone_checklist,route_json,detail_json,commodity,sono,route_summary," +
            "CONVERT(varchar(10),available_date,23) available_date,CONVERT(varchar(10),eta_delivery,23) eta_delivery," +
            "CONVERT(varchar(10),goods_delivery,23) goods_delivery,CONVERT(varchar(16),updated_at,120) updated_at " +
            "FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (rows.Count == 0) return new { error = "not found" };
        var r = rows[0];
        if (!Scope.TestJobScope(rs, r)) return new { error = "not found" };

        var chk = ParseNode(Db.Str(Db.G(r, "milestone_checklist")));
        var route = ParseArray(Db.Str(Db.G(r, "route_json")));
        var detail = ParseNode(Db.Str(Db.G(r, "detail_json")));
        var notes = Notes.Read().Where(n => n.JobNo.Trim() == job).OrderByDescending(n => n.Created).Select(Notes.Proj).ToArray();
        var extra = new
        {
            commodity = Db.Str(Db.G(r, "commodity")),
            sono = Db.Str(Db.G(r, "sono")),
            routeSummary = Db.Str(Db.G(r, "route_summary")),
            availableDate = Db.Str(Db.G(r, "available_date")),
            etaDelivery = Db.Str(Db.G(r, "eta_delivery")),
            goodsDelivery = Db.Str(Db.G(r, "goods_delivery")),
            snapshotAt = Db.Str(Db.G(r, "updated_at")),
        };
        return new { jobNo = job, checklist = chk, notes, route, detail, extra };
    }

    // parse a stored JSON blob to a node (null on empty/invalid) — System.Text.Json serializes it back verbatim.
    static JsonNode? ParseNode(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        try { return JsonNode.Parse(s); } catch { return null; }
    }
    // parse a stored JSON array; coerce a bare object to a 1-element array; empty array on empty/invalid.
    static JsonArray ParseArray(string s)
    {
        if (string.IsNullOrWhiteSpace(s)) return new JsonArray();
        try
        {
            var n = JsonNode.Parse(s);
            if (n is JsonArray a) return a;
            return n == null ? new JsonArray() : new JsonArray(n);
        }
        catch { return new JsonArray(); }
    }
}
