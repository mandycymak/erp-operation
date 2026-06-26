using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Hosting;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// Drains the Book Now async push queue (dbo.book_pending). The create endpoint registers the booking instantly +
// enqueues the /booking/update payload; this background service performs the ~10s ERP call OFF the request path, then
// stamps the ERP booking number onto booking_alert + erp_edit_log and drops a My Tasks note to the creator. It
// survives a restart (re-picks pending/retry rows on boot). Rows are CLAIMED atomically (UPDATE...OUTPUT) so even a
// web-garden can't double-push. Transient failures retry with backoff; a terminal failure is recorded + notified.
public sealed class BookingPusher : BackgroundService
{
    const int MaxAttempts = 6;
    static readonly int[] BackoffSec = { 15, 30, 60, 120, 300 };

    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        try { await Task.Delay(2000, stop); } catch { }
        while (!stop.IsCancellationRequested)
        {
            try { DrainOnce(); } catch (Exception ex) { Log.Error("booking-pusher loop", ex); }
            try { await Task.Delay(3000, stop); } catch { }
        }
    }

    static void DrainOnce()
    {
        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        for (int i = 0; i < 5; i++)   // up to 5 per tick
        {
            // claim the oldest due row atomically (so concurrent workers can't grab the same one)
            var claimed = Db.RunQ(cn,
                "UPDATE dbo.book_pending SET status='processing', attempts=attempts+1, updated_at=SYSDATETIME() " +
                "OUTPUT inserted.ref_no, inserted.station, inserted.mode, inserted.actor, inserted.payload, inserted.attempts " +
                "WHERE ref_no = (SELECT TOP 1 ref_no FROM dbo.book_pending " +
                "  WHERE status='pending' OR (status='retry' AND (next_at IS NULL OR next_at<=SYSDATETIME())) ORDER BY created_at)",
                new Dictionary<string, object?>());
            if (claimed.Count == 0) break;
            try { ProcessOne(cn, claimed[0]); } catch (Exception ex) { Log.Error("booking-pusher process", ex); }
        }
    }

    static void ProcessOne(SqlConnection cn, Row row)
    {
        var refNo = Db.Str(Db.G(row, "ref_no"));
        var station = Db.Str(Db.G(row, "station"));
        var mode = Db.Str(Db.G(row, "mode"));
        var actor = Db.Str(Db.G(row, "actor"));
        var attempts = Db.IntOf(Db.G(row, "attempts"));
        JsonObject payload;
        try { payload = JsonNode.Parse(Db.Str(Db.G(row, "payload")))!.AsObject(); }
        catch (Exception ex) { Fail(cn, refNo, station, mode, actor, "bad queued payload: " + ex.Message, terminal: true); return; }

        var erp = Erp.CreateBookingPush(payload, refNo, actor, station);
        if (erp.Ok)
        {
            var bn = erp.BookingNo != "" ? erp.BookingNo : refNo;   // some ERPs don't echo a number; keep our ref then
            Db.Exec(cn, "UPDATE dbo.book_pending SET status='done', booking_no=@b, last_error=NULL, updated_at=SYSDATETIME() WHERE ref_no=@r",
                new Dictionary<string, object?> { ["b"] = bn, ["r"] = refNo });
            Db.Exec(cn, "UPDATE dbo.booking_alert SET booking_no=@b, status='created' WHERE station=@s AND mode=@m AND erp_ref=@r",
                new Dictionary<string, object?> { ["b"] = bn, ["s"] = station, ["m"] = mode, ["r"] = refNo });
            LogEdit(cn, refNo, station, mode, actor, bn, erp.Mock ? "mock" : "created", "", erp.Steps);
            var lane = Lane(payload);
            Notify(actor, refNo, $"Book Now: booking confirmed in the ERP {(erp.Mock ? "(mock) " : "")}as {bn} - ref {refNo}{(lane != "" ? " - " + lane : "")}.");
        }
        else
        {
            Fail(cn, refNo, station, mode, actor, erp.Error, terminal: attempts >= MaxAttempts);
        }
    }

    static void Fail(SqlConnection cn, string refNo, string station, string mode, string actor, string err, bool terminal)
    {
        try
        {
            if (terminal)
            {
                Db.Exec(cn, "UPDATE dbo.book_pending SET status='failed', last_error=@e, updated_at=SYSDATETIME() WHERE ref_no=@r",
                    new Dictionary<string, object?> { ["e"] = err, ["r"] = refNo });
                Db.Exec(cn, "UPDATE dbo.booking_alert SET status='erp-failed', note=@e WHERE station=@s AND mode=@m AND erp_ref=@r",
                    new Dictionary<string, object?> { ["e"] = err.Length > 400 ? err.Substring(0, 400) : err, ["s"] = station, ["m"] = mode, ["r"] = refNo });
                LogEdit(cn, refNo, station, mode, actor, "", "error", err, new List<string>());
                Notify(actor, refNo, $"Book Now: booking ref {refNo} FAILED in the ERP - {err}. Please re-enter it or contact support.");
            }
            else
            {
                var rows = Db.RunQ(cn, "SELECT attempts FROM dbo.book_pending WHERE ref_no=@r", new Dictionary<string, object?> { ["r"] = refNo });
                var a = rows.Count > 0 ? Db.IntOf(Db.G(rows[0], "attempts")) : 1;
                var backoff = BackoffSec[Math.Min(Math.Max(a - 1, 0), BackoffSec.Length - 1)];
                Db.Exec(cn, "UPDATE dbo.book_pending SET status='retry', last_error=@e, next_at=DATEADD(second,@bo,SYSDATETIME()), updated_at=SYSDATETIME() WHERE ref_no=@r",
                    new Dictionary<string, object?> { ["e"] = err, ["bo"] = backoff, ["r"] = refNo });
            }
        }
        catch (Exception ex) { Log.Error("booking-pusher fail-update", ex); }
    }

    static string Lane(JsonObject p)
    {
        string S(string k) => (p[k]?.ToString() ?? "").Trim();
        var a = S("portOfLoadingName") != "" ? S("portOfLoadingName") : S("portOfLoadingCode");
        var b = S("portOfDischargeName") != "" ? S("portOfDischargeName") : S("portOfDischargeCode");
        return a != "" || b != "" ? $"{a} -> {b}" : "";
    }

    static void LogEdit(SqlConnection cn, string refNo, string station, string mode, string actor, string bookingNo, string status, string err, List<string> steps)
    {
        try
        {
            var jsonc = new JsonSerializerOptions { PropertyNamingPolicy = null };
            Db.Exec(cn, "INSERT INTO dbo.erp_edit_log(job_no,erp_ref,station,mode,bound,actor,ip,changed_json,erp_status,erp_steps,erp_error,occurred_at) VALUES(@j,@r,@s,@m,@b,@a,@ip,@cj,@st,@stp,@err,SYSDATETIME())",
                new Dictionary<string, object?>
                {
                    ["j"] = refNo, ["r"] = bookingNo, ["s"] = station, ["m"] = mode, ["b"] = "", ["a"] = actor, ["ip"] = "",
                    ["cj"] = new JsonObject { ["refNo"] = refNo, ["bookingNo"] = bookingNo, ["channel"] = "book-now" }.ToJsonString(),
                    ["st"] = status, ["stp"] = JsonSerializer.Serialize(steps, jsonc), ["err"] = err,
                });
        }
        catch (Exception ex) { Log.Error("booking-pusher log", ex); }
    }

    // Append a My Tasks note for the creator (authored by them -> shows in "mine"). Keyed by our refNo so it stands
    // alone even before the booking is in the worklist. Notes.Write rewrites the store under a lock; low frequency.
    static void Notify(string actor, string jobKey, string text)
    {
        if (string.IsNullOrWhiteSpace(actor) || actor == "(open)") return;
        try
        {
            var all = Notes.Read();
            // Kind 'booking' = an informational Book Now confirmation, NOT tied to a worklist shipment (its job_no is
            // our Ref No, which has no shipment_alerts row). The client renders it as info-only so it never opens the
            // shipment drawer / Edit-ERP editor (which would fail to find the job).
            all.Add(new NoteRec { Id = Guid.NewGuid().ToString("N"), Created = DateTime.Now.ToString("o"), User = actor, JobNo = jobKey, Kind = "booking", Note = text, Status = "open" });
            Notes.Write(all);
        }
        catch (Exception ex) { Log.Error("booking-pusher notify", ex); }
    }
}
