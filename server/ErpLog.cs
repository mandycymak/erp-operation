using System.Threading;
using Microsoft.Data.SqlClient;

namespace Ops;

// Append-only log of EVERY Swivel ERP API call into dbo.erp_api_log, so support can answer "which API errored and
// why" from ONE place (the admin "ERP API" tab) instead of hunting across erp_edit_log / doc_event_log / the flat
// ops-error.log. Written at the single Erp.Call choke point (so every push AND the previously-silent reads land
// here). Ambient context (actor / station / ref / correlation id) is set per logical operation via Begin(): a
// multi-call operation - a doc agree = /booking/get + /booking/update, an issue = uploads + event + generate -
// shares ONE corr id, so the whole operation is one trail. Logging NEVER throws (Log.Error fallback) so a logging
// failure can never turn a working ERP call into a 500.
public static class ErpLog
{
    public sealed class Ctx { public string CorrId = ""; public string Actor = ""; public string Station = ""; public string Ref = ""; }
    static readonly AsyncLocal<Ctx?> _ctx = new();

    sealed class Scope : IDisposable { public Ctx? Prev; public void Dispose() => _ctx.Value = Prev; }

    // Open a correlation scope. A nested Begin inherits the parent's corr id (so the whole operation links), and
    // fills any field it doesn't override from the parent. Returns an IDisposable that restores the previous scope.
    public static IDisposable Begin(string actor, string station = "", string refv = "")
    {
        var prev = _ctx.Value;
        var c = new Ctx
        {
            CorrId = prev?.CorrId is { Length: > 0 } pc ? pc : Log.NewCorrId(),
            Actor = string.IsNullOrEmpty(actor) ? (prev?.Actor ?? "") : actor,
            Station = string.IsNullOrEmpty(station) ? (prev?.Station ?? "") : station,
            Ref = string.IsNullOrEmpty(refv) ? (prev?.Ref ?? "") : refv,
        };
        _ctx.Value = c;
        return new Scope { Prev = prev };
    }

    static string Trunc(string? s, int max) { s ??= ""; return s.Length <= max ? s : s.Substring(0, max); }
    static object NV(string? s) => string.IsNullOrEmpty(s) ? DBNull.Value : s;

    // Best-effort: the payload JSON (no secret - the bearer token rides in a header, never in the body). Truncated
    // by Write so a large business document never bloats the log.
    public static string Summarize(System.Text.Json.Nodes.JsonObject payload)
    {
        try { return payload.ToJsonString(); } catch { return ""; }
    }

    public static void Write(string endpoint, bool ok, int? httpStatus, int durationMs, string? error, string? reqSummary, string? respSummary)
    {
        try
        {
            var c = _ctx.Value;
            var corr = c?.CorrId is { Length: > 0 } id ? id : Log.NewCorrId();
            // /get, /enquiry, /download are reads; everything else (update, upload, event, generate) is a write.
            var dir = (endpoint.Contains("/get") || endpoint.Contains("/enquiry") || endpoint.Contains("/download")) ? "read" : "write";
            using var cn = new SqlConnection(Config.ConnStr); cn.Open();
            using var cmd = cn.CreateCommand(); cmd.CommandTimeout = 10;
            cmd.CommandText = "INSERT INTO dbo.erp_api_log(corr_id,actor,station,direction,endpoint,[ref],ok,http_status,duration_ms,error,req_summary,resp_summary) " +
                "VALUES(@corr,@actor,@station,@dir,@ep,@ref,@ok,@st,@ms,@err,@req,@resp)";
            var p = cmd.Parameters;
            p.AddWithValue("@corr", Trunc(corr, 16));
            p.AddWithValue("@actor", NV(c?.Actor));
            p.AddWithValue("@station", NV(Trunc(c?.Station, 10)));
            p.AddWithValue("@dir", dir);
            p.AddWithValue("@ep", Trunc(endpoint, 64));
            p.AddWithValue("@ref", NV(Trunc(c?.Ref, 60)));
            p.AddWithValue("@ok", ok);
            p.AddWithValue("@st", (object?)httpStatus ?? DBNull.Value);
            p.AddWithValue("@ms", durationMs);
            p.AddWithValue("@err", NV(Trunc(error, 4000)));
            p.AddWithValue("@req", NV(Trunc(reqSummary, 2000)));
            p.AddWithValue("@resp", NV(Trunc(respSummary, 2000)));
            cmd.ExecuteNonQuery();
        }
        catch (Exception ex) { Log.Error("erp_api_log write", ex); }
    }
}
