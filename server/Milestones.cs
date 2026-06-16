using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;

namespace Ops;

// Milestone checklist rollup + evidence-close (serve-ops.ps1 1098-1149). The checklist is JSON stored on
// shipment_alerts.milestone_checklist: { milestones:[{code,state,light,due,done_by,done_at,basis}], rollup:{...} }.
public static class Milestones
{
    public sealed record Rollup(string Worst, int Amber, int Red, string? NextDue, int Man);

    // recompute the rollup from the milestone items and write it back into chk.rollup (mutates chk).
    public static Rollup UpdateRollup(JsonObject chk)
    {
        int amber = 0, red = 0, auto = 0, man = 0;
        DateTime? nextDue = null;
        if (chk["milestones"] is JsonArray ms)
            foreach (var mn in ms)
            {
                if (mn is not JsonObject m) continue;
                var st = (string?)m["state"] ?? "";
                if (st == "bypassed") man++;
                else if (st == "done") auto++;
                else if (st == "pending")
                {
                    var light = (string?)m["light"] ?? "";
                    if (light == "A") amber++; else if (light == "R") red++;
                    var due = (string?)m["due"];
                    if (!string.IsNullOrWhiteSpace(due) && DateTime.TryParse(due, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                        if (nextDue == null || d < nextDue) nextDue = d;
                }
            }
        var worst = red > 0 ? "R" : amber > 0 ? "A" : "G";
        var nd = nextDue?.ToString("yyyy-MM-dd");

        var rollup = chk["rollup"] as JsonObject;
        if (rollup == null) { rollup = new JsonObject(); chk["rollup"] = rollup; }
        rollup["worst_light"] = worst; rollup["open_amber"] = amber; rollup["open_red"] = red;
        rollup["next_due"] = nd;
        var autom = rollup["automation"] as JsonObject;
        if (autom == null) { autom = new JsonObject(); rollup["automation"] = autom; }
        autom["manual"] = man;
        return new Rollup(worst, amber, red, nd, man);
    }

    // Mark one or more milestones DONE because the operator supplied real proof (a doc uploaded to the ERP).
    // Mirrors the Tick write path; threads a silent evidence note. Returns (ok, cleared[], rollup?).
    public static (bool Ok, string? Error, string[] Cleared, Rollup? Roll) CloseFor(SqlConnection cn, string job, IEnumerable<string> codes, string basis, string by)
    {
        var want = codes.Select(c => c.Trim()).Where(c => c != "").Distinct().ToArray();
        if (want.Length == 0) return (true, null, Array.Empty<string>(), null);
        var row = Db.RunQ(cn, "SELECT TOP 1 milestone_checklist FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (row.Count == 0) return (false, "shipment not found", Array.Empty<string>(), null);
        JsonObject? chk; try { chk = JsonNode.Parse(Db.Str(Db.G(row[0], "milestone_checklist")))?.AsObject(); } catch { chk = null; }
        if (chk == null) return (false, "no checklist on this shipment", Array.Empty<string>(), null);

        var cleared = new List<string>();
        if (chk["milestones"] is JsonArray ms)
            foreach (var mn in ms)
            {
                if (mn is not JsonObject m) continue;
                var code = (string?)m["code"] ?? "";
                if (want.Contains(code) && (string?)m["state"] != "done")
                {
                    m["state"] = "done"; m["done_by"] = by; m["done_at"] = DateTime.Now.ToString("o"); m["light"] = "G"; m["basis"] = basis;
                    cleared.Add(code);
                }
            }
        if (cleared.Count == 0) return (true, null, Array.Empty<string>(), null);
        var rr = UpdateRollup(chk);
        Db.Exec(cn, "UPDATE dbo.shipment_alerts SET milestone_checklist=@chk,worst_light=@w,open_amber=@a,open_red=@r,next_due=@nd,manual_done=@m,updated_at=SYSDATETIME() WHERE job_no=@j",
            new Dictionary<string, object?> { ["chk"] = chk.ToJsonString(), ["w"] = rr.Worst, ["a"] = rr.Amber, ["r"] = rr.Red, ["nd"] = rr.NextDue, ["m"] = rr.Man, ["j"] = job });
        Notes.Write(Notes.Read().Append(new NoteRec
        {
            Id = Guid.NewGuid().ToString(), Created = DateTime.Now.ToString("o"), User = by, JobNo = job,
            MilestoneCode = string.Join(",", cleared), Kind = "evidence", Note = basis, Status = "open", Silent = true,
        }));
        return (true, null, cleared.ToArray(), rr);
    }
}
