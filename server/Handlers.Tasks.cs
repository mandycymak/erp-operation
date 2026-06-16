using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/notes (GET) — file store, no DB (serve-ops.ps1 Handle-NoteList) ----
    public static object NoteList(Qs q) => Notes.ListByJob(q["job"]);

    // ---- /api-ops/my-tasks (serve-ops.ps1 300-320) ----
    public static object MyTasks(SqlConnection cn, Qs q, ReqState rs)
    {
        var me = rs.Me;
        var all = Notes.Read();
        var open = all.Where(n => n.IsOpen && n.Kind != "bypass" && n.Kind != "reopen").ToList();
        var assigned = open.Where(n => n.Mentions.Contains(me) && n.User != me).ToList();
        var mine = open.Where(n => n.User == me).ToList();

        var jobs = assigned.Concat(mine).Select(n => n.JobNo).Where(j => j != "").Distinct().ToArray();
        var info = new Dictionary<string, Row>(StringComparer.Ordinal);
        if (jobs.Length > 0)
        {
            var p = new Dictionary<string, object?>(); var ins = new List<string>();
            for (int i = 0; i < jobs.Length; i++) { ins.Add($"@j{i}"); p[$"j{i}"] = jobs[i]; }
            var rows = Db.RunQ(cn,
                "SELECT job_no,bound,consignee_name,shipper_name,lane,vessel_voyage,arrival_state,cargo_type," +
                "CONVERT(varchar(20),total_weight) total_weight,container_summary FROM dbo.shipment_alerts WHERE job_no IN (" + string.Join(",", ins) + ")", p);
            foreach (var r in rows) info[Db.Str(Db.G(r, "job_no"))] = r;
        }

        // sort: items with a due date first (ascending), undated last; tiebreak newest-created first.
        IEnumerable<object> SortProj(IEnumerable<NoteRec> src) => src
            .OrderBy(n => n.RemindOn == "" ? 1 : 0)
            .ThenBy(n => n.RemindOn, StringComparer.Ordinal)
            .ThenByDescending(n => n.Created, StringComparer.Ordinal)
            .Select(n => TaskProj(n, info));

        var assignedT = SortProj(assigned).ToArray();
        var mineT = SortProj(mine).ToArray();
        var today = Config.TodayStr();
        var dueNow = mine.Count(n => n.RemindOn != "" && string.CompareOrdinal(n.RemindOn, today) <= 0);
        object[] draftAlerts = Array.Empty<object>();
        try { draftAlerts = DraftAlerts(cn, rs, me); } catch { }

        return new { assigned = assignedT, mine = mineT, drafts = draftAlerts, assignedOpen = assignedT.Length, dueNow, draftCount = draftAlerts.Length, today };
    }

    // project a note + its shipment context into a My-Tasks card.
    static object TaskProj(NoteRec n, Dictionary<string, Row> info)
    {
        string who = "", lane = "", vv = "", astate = "", cargo = "", bound = "";
        if (info.TryGetValue(n.JobNo, out var s))
        {
            bound = Db.Str(Db.G(s, "bound"));
            who = bound == "Import" ? Db.Str(Db.G(s, "consignee_name")) : Db.Str(Db.G(s, "shipper_name"));
            lane = Db.Str(Db.G(s, "lane"));
            vv = Db.Str(Db.G(s, "vessel_voyage"));
            astate = Db.Str(Db.G(s, "arrival_state"));
            var tw = Db.Str(Db.G(s, "total_weight"));
            cargo = Db.Str(Db.G(s, "cargo_type")) == "LCL" ? (tw != "" ? $"{tw} kg" : "") : Db.Str(Db.G(s, "container_summary"));
        }
        return new
        {
            id = n.Id, job_no = n.JobNo, user = n.User, kind = n.Kind, note = n.Note, mentions = n.Mentions,
            created = n.Created, remindOn = n.RemindOn, arrType = n.ArrType,
            consignee = who, lane, vesselVoyage = vv, arrivalState = astate, cargo, bound,
        };
    }

    // draft-review alerts for the inbox: drafts a customer has acted on, awaiting the operator. Self-clearing.
    static object[] DraftAlerts(SqlConnection cn, ReqState rs, string me)
    {
        var p = new Dictionary<string, object?>();
        var where = "d.status IN ('CUSTOMER_SUBMITTED','CUSTOMER_APPROVED')";
        if (rs.Tier is not ("admin" or "manager")) { where += " AND d.created_by=@dme"; p["dme"] = me; }
        var rows = Db.RunQ(cn,
            "SELECT d.doc_id,d.job_no,d.doc_type,d.status,d.customer_name,d.current_version," +
            "CONVERT(varchar(19),d.updated_at,120) updated_at,a.consignee_name FROM dbo.doc_draft d " +
            "LEFT JOIN dbo.shipment_alerts a ON a.job_no=d.job_no WHERE " + where + " ORDER BY d.updated_at DESC", p);
        var outp = new List<object>();
        foreach (var r in rows)
        {
            var comment = "";
            var ev = Db.RunQ(cn, "SELECT TOP 1 detail FROM dbo.doc_event_log WHERE doc_id=@d AND actor LIKE 'customer%' AND event IN ('submitted','approved') ORDER BY occurred_at DESC",
                new Dictionary<string, object?> { ["d"] = Db.Str(Db.G(r, "doc_id")) });
            if (ev.Count > 0)
                try { comment = (string?)JsonNode.Parse(Db.Str(Db.G(ev[0], "detail")))?["comment"] ?? ""; comment = comment.Trim(); } catch { }
            outp.Add(new
            {
                docId = Db.Str(Db.G(r, "doc_id")),
                jobNo = Db.Str(Db.G(r, "job_no")),
                docType = Db.Str(Db.G(r, "doc_type")),
                status = Db.Str(Db.G(r, "status")),
                customerName = Db.Str(Db.G(r, "customer_name")),
                consignee = Db.Str(Db.G(r, "consignee_name")),
                version = Db.IntOf(Db.G(r, "current_version")),
                comment,
                updatedAt = Db.Str(Db.G(r, "updated_at")),
            });
        }
        return outp.ToArray();
    }
}
