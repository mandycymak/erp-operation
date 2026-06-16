using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/notes (POST) — Save-Note (file store, no DB) (serve-ops.ps1 237-245) ----
    public static object SaveNote(JsonElement j, string me)
    {
        if (j.Str("job_no") == "") return new { error = "invalid payload" };
        var rec = new NoteRec
        {
            Id = Guid.NewGuid().ToString(), Created = DateTime.Now.ToString("o"), User = me,
            JobNo = j.Str("job_no"), MilestoneCode = j.Str("milestone_code"),
            Kind = j.Str("kind") is var k && k != "" ? k : "note", Note = j.Str("note"),
            Mentions = j.Arr("mentions"), Status = "open",
            ArrType = j.Str("arr_type"), Party = j.Str("party"), Contact = j.Str("contact"),
            ArrStatus = j.Str("arr_status"), RemindOn = j.Str("remind_on"),
        };
        Notes.Write(Notes.Read().Append(rec));
        return new { ok = true, record = Notes.Proj(rec) };
    }

    // ---- /api-ops/note-done (POST) — Save-NoteDone (serve-ops.ps1 251-265) ----
    public static object SaveNoteDone(JsonElement j, string me)
    {
        var id = j.Str("id");
        if (id == "") return new { error = "invalid payload" };
        var done = j.Bool("done") != false;   // absent/true => done; explicit false => reopen
        var all = Notes.Read();
        var found = false;
        foreach (var r in all)
            if (r.Id == id)
            {
                found = true;
                r.Status = done ? "done" : "open";
                r.DoneBy = done ? me : "";
                r.DoneAt = done ? DateTime.Now.ToString("o") : "";
            }
        if (!found) return new { error = "not found" };
        Notes.Write(all);
        return new { ok = true, id, status = done ? "done" : "open" };
    }

    // ---- /api-ops/milestone-close (POST) — Save-MilestoneClose (serve-ops.ps1 1152-1183) ----
    public static object MilestoneClose(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        var job = j.Str("job_no"); var code = j.Str("milestone_code");
        if (job == "" || code == "") return new { error = "invalid payload" };
        var reopen = j.Bool("done") == false;
        var rows = Db.RunQ(cn, "SELECT TOP 1 milestone_checklist,station,mode,bound FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (rows.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, rows[0])) return new { error = "not found" };
        JsonObject? chk; try { chk = JsonNode.Parse(Db.Str(Db.G(rows[0], "milestone_checklist")))?.AsObject(); } catch { chk = null; }
        if (chk == null) return new { error = "no checklist on this shipment" };

        var reason = j.Str("reason");
        var found = false;
        if (chk["milestones"] is JsonArray ms)
            foreach (var mn in ms)
            {
                if (mn is not JsonObject m || (string?)m["code"] != code) continue;
                found = true;
                if (reopen) { m["state"] = "pending"; m["done_by"] = ""; m["done_at"] = ""; m["basis"] = "reopened"; }
                else { m["state"] = "bypassed"; m["done_by"] = me; m["done_at"] = DateTime.Now.ToString("o"); m["basis"] = "manual: " + reason; }
            }
        if (!found) return new { error = "milestone not in checklist" };
        var rr = Milestones.UpdateRollup(chk);
        Db.Exec(cn, "UPDATE dbo.shipment_alerts SET milestone_checklist=@chk,worst_light=@w,open_amber=@a,open_red=@r,next_due=@nd,manual_done=@m,updated_at=SYSDATETIME() WHERE job_no=@j",
            new Dictionary<string, object?> { ["chk"] = chk.ToJsonString(), ["w"] = rr.Worst, ["a"] = rr.Amber, ["r"] = rr.Red, ["nd"] = rr.NextDue, ["m"] = rr.Man, ["j"] = job });

        var silent = reason.Trim() == "";
        var kind = reopen ? "reopen" : "bypass";
        var txt = reopen ? $"Re-opened {code}" : ("Ticked " + code + " complete" + (reason != "" ? ": " + reason : ""));
        Notes.Write(Notes.Read().Append(new NoteRec
        {
            Id = Guid.NewGuid().ToString(), Created = DateTime.Now.ToString("o"), User = me, JobNo = job,
            MilestoneCode = code, Kind = kind, Note = txt, Mentions = j.Arr("mentions"), Status = "open", Silent = silent,
        }));
        return new { ok = true, jobNo = job, milestone_code = code, state = reopen ? "pending" : "bypassed", worst = rr.Worst, openAmber = rr.Amber, openRed = rr.Red, nextDue = rr.NextDue };
    }

    // ---- /api-ops/inbound-assign (POST) — Save-InboundAssign (serve-ops.ps1 498-517) ----
    public static object InboundAssign(SqlConnection cn, JsonElement j, ReqState rs)
    {
        var me = rs.Me;
        var ss = j.Str("source_station"); var md = j.Str("mode"); var bn = j.Str("booking_no");
        if (ss == "" || md == "" || bn == "") return new { error = "invalid payload" };
        if (!rs.Open)
        {
            var fr = Db.RunQ(cn, "SELECT TOP 1 dest_station,mode FROM dbo.inbound_booking_feed WHERE source_station=@ss AND mode=@md AND booking_no=@bn",
                new Dictionary<string, object?> { ["ss"] = ss, ["md"] = md, ["bn"] = bn });
            if (fr.Count == 0) return new { error = "not found" };
            var sts = Scope.CurStations(rs);
            if (sts.Length > 0 && !sts.Contains(Db.Str(Db.G(fr[0], "dest_station")))) return new { error = "not found" };
            var prs = Scope.CurPairs(rs);
            if (prs.Length > 0 && !prs.Contains($"{Db.Str(Db.G(fr[0], "mode"))}-Import")) return new { error = "not found" };
        }
        var assignee = j.Str("assignee").Trim();
        Db.Exec(cn, "UPDATE dbo.inbound_booking_feed SET assigned_to=@a,updated_at=SYSDATETIME() WHERE source_station=@ss AND mode=@md AND booking_no=@bn",
            new Dictionary<string, object?> { ["a"] = assignee == "" ? null : assignee, ["ss"] = ss, ["md"] = md, ["bn"] = bn });
        var job = $"FEED:{ss}:{bn}";
        var ment = j.Arr("mentions").Concat(assignee == "" ? Array.Empty<string>() : new[] { assignee }).Where(x => x.Trim() != "").Select(x => x.Trim()).Distinct().ToArray();
        var txt = assignee != "" ? $"Assigned inbound booking to @{assignee}" : "Unassigned inbound booking";
        if (j.Str("note").Trim() != "") txt += ": " + j.Str("note").Trim();
        Notes.Write(Notes.Read().Append(new NoteRec
        {
            Id = Guid.NewGuid().ToString(), Created = DateTime.Now.ToString("o"), User = me, JobNo = job,
            Kind = "inbound", Note = txt, Mentions = ment, Status = "open",
        }));
        return new { ok = true, assignedTo = assignee };
    }
}
