using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/find — natural-language operator search (the rule parser lives client-side in ops.js; this
    // endpoint receives the already-extracted clues). Searches shipment_alerts (parties / lane / commodity /
    // carrier / arrangement-contact / identifiers) merged with a job_note search (author / body / @-mention),
    // every path gated by the SAME Scope.StationClause + Scope.PairClause that the worklist uses — that scope is
    // the whole security boundary, and notes inherit it via an EXISTS on their parent shipment. Recency-sorted,
    // deduped by job_no (a job that also has a matching note is shown once, flagged hasNote). ----
    public static object Find(SqlConnection cn, Qs q, ReqState rs)
    {
        var me = rs.Me;
        var who = (q["who"] ?? "").Trim();
        var pol = (q["pol"] ?? "").Trim();
        var pod = (q["pod"] ?? "").Trim();
        var commodity = (q["commodity"] ?? "").Trim();
        var mode = (q["mode"] ?? "").Trim();
        var bound = (q["bound"] ?? "").Trim();
        var refq = (q["ref"] ?? "").Trim();
        var refField = q["refField"] ?? "";
        var noteAuthor = (q["noteauthor"] ?? "").Trim();
        var noteText = (q["notetext"] ?? "").Trim();
        var tome = (q["tome"] ?? "") != "";
        // involvement default ("mine"); an explicit identifier lookup finds any file, so it bypasses the lens.
        var mine = (q["mine"] ?? "") != "" && refq == "";
        var from = (q["from"] ?? "").Trim();
        var to = (q["to"] ?? "").Trim();
        var hasNoteClue = noteAuthor != "" || noteText != "" || tome;
        var hasShipmentClue = who != "" || pol != "" || pod != "" || commodity != "" || refq != "" || mode != "" || bound != "";
        // a purely note-centric query ("Leo messaged me about X") is anchored by the NOTE search — running the
        // worklist involvement lens here would broadcast every system-created (API/EDI/QUOTATION) row into "mine"
        // and drown the actual message. So skip the shipment query entirely and let the note hits drive results.
        var noteOnly = hasNoteClue && !hasShipmentClue;

        // ===================== (a) shipment query =====================
        var p = new Dictionary<string, object?>();
        var w = " WHERE job_status IN ('active','closed') ";

        if (who != "")
        {
            p["who"] = "%" + Db.LikeEsc(who) + "%";
            w += " AND (shipper_name LIKE @who OR consignee_name LIKE @who OR shipper_code LIKE @who OR consignee_code LIKE @who " +
                 "OR agent_code LIKE @who OR ctrl_code LIKE @who OR cust_code LIKE @who OR cust_contact LIKE @who OR carrier LIKE @who " +
                 "OR EXISTS (SELECT 1 FROM dbo.job_note n WHERE n.job_no = shipment_alerts.job_no AND (n.party LIKE @who OR n.contact LIKE @who))) ";
        }
        if (pol != "") { p["pol"] = "%" + Db.LikeEsc(pol) + "%"; w += " AND (pol LIKE @pol OR lane LIKE @pol OR route_summary LIKE @pol) "; }
        if (pod != "") { p["pod"] = "%" + Db.LikeEsc(pod) + "%"; w += " AND (pod LIKE @pod OR lane LIKE @pod OR route_summary LIKE @pod) "; }
        if (commodity != "") { p["com"] = "%" + Db.LikeEsc(commodity) + "%"; w += " AND commodity LIKE @com "; }
        if (mode != "") { p["md"] = mode; w += " AND mode=@md "; }
        if (bound != "") { p["bnd"] = bound; w += " AND bound=@bnd "; }

        if (refq != "")
        {
            p["ref"] = "%" + Db.LikeEsc(refq) + "%";
            if (refField == "job") w += " AND (job_no LIKE @ref OR erp_job_no LIKE @ref) ";
            else
            {
                var map = new Dictionary<string, string> { ["booking"] = "sono", ["po"] = "cust_ref", ["house"] = "house_bill", ["master"] = "master_bill", ["liner"] = "liner_so", ["container"] = "container_no", ["conv"] = "vessel_voyage" };
                if (map.TryGetValue(refField, out var col)) w += $" AND {col} LIKE @ref ";
                else w += " AND (job_no LIKE @ref OR erp_job_no LIKE @ref OR sono LIKE @ref OR house_bill LIKE @ref OR master_bill LIKE @ref OR cust_ref LIKE @ref OR container_no LIKE @ref OR liner_so LIKE @ref) ";
            }
        }

        // involvement default — reuse the worklist "my work" lens (pic / created / updated / noted + system broadcast).
        if (mine)
        {
            var als = Scope.ErpAliases(rs, me);
            var ains = new List<string>();
            for (int i = 0; i < als.Length; i++) { ains.Add($"@eu{i}"); p[$"eu{i}"] = als[i]; }
            var ainl = string.Join(",", ains);
            var clauses = new List<string> { $"pic_user IN ({ainl})", $"created_by IN ({ainl})", $"last_updated_by IN ({ainl})" };
            var jobs = Notes.MyNoteJobs(me);
            if (jobs.Length > 0)
            {
                var ins = new List<string>();
                for (int i = 0; i < jobs.Length; i++) { ins.Add($"@nj{i}"); p[$"nj{i}"] = jobs[i]; }
                clauses.Add($"job_no IN ({string.Join(",", ins)})");
            }
            var sx = Scope.SysExprs(p);
            if (sx != null) clauses.Add($"({sx.Value.Pic} AND (NULLIF(last_updated_by,'') IS NULL OR {sx.Value.Lub}))");
            w += " AND (" + string.Join(" OR ", clauses) + ") ";
        }

        // date window: a shipment that booked / departed / arrived in range. No window -> keep closed files to a
        // recent horizon (so a forgotten-booking recall still finds a delivered shipment, without the whole archive).
        if (from != "" || to != "")
        {
            p["dlo"] = from != "" ? from : "0001-01-01";
            p["dhi"] = to != "" ? to : "9999-12-31";
            w += " AND (anchor_date BETWEEN @dlo AND @dhi OR etd BETWEEN @dlo AND @dhi OR eta BETWEEN @dlo AND @dhi OR ata BETWEEN @dlo AND @dhi) ";
        }
        else
        {
            p["recent"] = Config.TodayDate().AddMonths(-6).ToString("yyyy-MM-dd");
            w += " AND (job_status='active' OR anchor_date >= @recent OR ata >= @recent) ";
        }

        // scope — the security boundary (identical to the worklist).
        w += Scope.StationClause(rs, p);
        w += Scope.PairClause(rs, p);

        var cols = "job_no,erp_job_no,station,mode,bound,cargo_type,lane,carrier,pol,pod,route_summary,commodity," +
            "shipper_name,consignee_name,shipper_code,consignee_code,agent_code,ctrl_code,cust_code,cust_contact," +
            "sono,house_bill,master_bill,cust_ref,container_no,liner_so,vessel_voyage,pic_user,created_by,last_updated_by," +
            "worst_light,arrival_state,job_status," +
            "CONVERT(varchar(10),anchor_date,23) anchor_date,CONVERT(varchar(10),etd,23) etd," +
            "CONVERT(varchar(10),eta,23) eta,CONVERT(varchar(10),ata,23) ata";
        var rows = noteOnly
            ? new List<Row>()
            : Db.RunQ(cn, $"SELECT TOP 60 {cols} FROM dbo.shipment_alerts {w} ORDER BY COALESCE(anchor_date, eta, sort_key) DESC", p);

        var jobMap = new Dictionary<string, Row>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows) jobMap[Db.Str(Db.G(r, "job_no"))] = r;

        // ===================== (b) note search (only when there's a note clue) =====================
        var nrows = new List<Row>();
        if (hasNoteClue)
        {
            var np = new Dictionary<string, object?>();
            var nw = " WHERE 1=1 ";
            if (noteAuthor != "") { np["na"] = "%" + Db.LikeEsc(noteAuthor) + "%"; nw += " AND n.[user] LIKE @na "; }
            if (noteText != "") { np["nb"] = "%" + Db.LikeEsc(noteText) + "%"; nw += " AND n.note LIKE @nb "; }
            if (tome) { np["nme"] = "%," + Db.LikeEsc(me) + ",%"; nw += " AND (','+ISNULL(n.mentions,'')+',') LIKE @nme "; }
            // involvement default on notes: authored by me OR @-mentioning me (narrows within scope; "anyone" omits it).
            if (mine && !tome) { np["nau"] = me; np["nmm"] = "%," + Db.LikeEsc(me) + ",%"; nw += " AND (n.[user]=@nau OR (','+ISNULL(n.mentions,'')+',') LIKE @nmm) "; }
            if (from != "" || to != "")
            {
                np["nlo"] = from != "" ? from : "0001-01-01";
                np["nhi"] = (to != "" ? to : "9999-12-31") + "z";   // 'z' > 'T...' so same-day ISO timestamps fall inside
                nw += " AND n.created >= @nlo AND n.created <= @nhi ";
            }
            // scope via the parent shipment — the entire note security boundary (out-of-scope jobs vanish).
            var sc = Scope.StationClause(rs, np, "s.station", "nsst") + Scope.PairClause(rs, np, "s.mode", "s.bound");
            nw += " AND EXISTS (SELECT 1 FROM dbo.shipment_alerts s WHERE s.job_no = n.job_no AND s.job_status IN ('active','closed') " + sc + ") ";
            nrows = Db.RunQ(cn, $"SELECT TOP 60 n.id,n.job_no,n.[user],n.note,n.mentions,n.kind,n.created FROM dbo.job_note n {nw} ORDER BY n.created DESC", np);
        }
        var noteJobs = new HashSet<string>(nrows.Select(nr => Db.Str(Db.G(nr, "job_no"))), StringComparer.OrdinalIgnoreCase);

        // hydrate shipment context for note-only jobs (so the note card can show the lane/parties + deep-link).
        var missing = noteJobs.Where(j => j != "" && !jobMap.ContainsKey(j)).Distinct().ToArray();
        if (missing.Length > 0)
        {
            var hp = new Dictionary<string, object?>(); var ins = new List<string>();
            for (int i = 0; i < missing.Length; i++) { ins.Add($"@hj{i}"); hp[$"hj{i}"] = missing[i]; }
            var hw = " WHERE job_no IN (" + string.Join(",", ins) + ") ";
            hw += Scope.StationClause(rs, hp); hw += Scope.PairClause(rs, hp);
            foreach (var r in Db.RunQ(cn, $"SELECT {cols} FROM dbo.shipment_alerts {hw}", hp)) jobMap[Db.Str(Db.G(r, "job_no"))] = r;
        }

        // ===================== (c) merge + dedupe + sort + cap =====================
        var merged = new List<(string sort, object item)>();
        foreach (var r in rows)
        {
            var jk = Db.Str(Db.G(r, "job_no"));
            merged.Add((ShipSort(r), ShipItem(r, noteJobs.Contains(jk))));
        }
        foreach (var nr in nrows)
        {
            var jk = Db.Str(Db.G(nr, "job_no"));
            if (jobMap.ContainsKey(jk) && rows.Any(r => Db.Str(Db.G(r, "job_no")).Equals(jk, StringComparison.OrdinalIgnoreCase)))
                continue;   // folded into the shipment card (hasNote=true)
            merged.Add((Db.Str(Db.G(nr, "created")), NoteItem(nr, jobMap.TryGetValue(jk, out var ctx) ? ctx : null)));
        }
        var items = merged.OrderByDescending(x => x.sort, StringComparer.Ordinal).Take(60).Select(x => x.item).ToArray();

        return new { items, resolved = new { who, pol, pod, commodity, mode, bound, mine, noteAuthor, noteText, tome, from, to } };
    }

    // sort key for a shipment hit: anchor date, falling back to eta then ata (all yyyy-mm-dd strings).
    static string ShipSort(Row r)
    {
        var a = Db.Str(Db.G(r, "anchor_date")); if (a != "") return a;
        var e = Db.Str(Db.G(r, "eta")); if (e != "") return e;
        return Db.Str(Db.G(r, "ata"));
    }

    // the document an operator/customer recognises (My-Tasks/worklist use the same precedence).
    static string HumanId(Row r)
    {
        foreach (var k in new[] { "house_bill", "sono", "erp_job_no", "master_bill", "job_no" })
        {
            var v = Db.Str(Db.G(r, k)); if (v != "") return v;
        }
        return Db.Str(Db.G(r, "job_no"));
    }

    static object ShipItem(Row r, bool hasNote) => new
    {
        type = "shipment",
        jobNo = Db.Str(Db.G(r, "job_no")),
        humanId = HumanId(r),
        station = Db.Str(Db.G(r, "station")),
        mode = Db.Str(Db.G(r, "mode")),
        bound = Db.Str(Db.G(r, "bound")),
        cargoType = Db.Str(Db.G(r, "cargo_type")),
        lane = Db.Str(Db.G(r, "lane")),
        routeSummary = Db.Str(Db.G(r, "route_summary")),
        carrier = Db.Str(Db.G(r, "carrier")),
        commodity = Db.Str(Db.G(r, "commodity")),
        shipperName = Db.Str(Db.G(r, "shipper_name")),
        consigneeName = Db.Str(Db.G(r, "consignee_name")),
        ctrlCode = Db.Str(Db.G(r, "ctrl_code")),
        custContact = Db.Str(Db.G(r, "cust_contact")),
        sono = Db.Str(Db.G(r, "sono")),
        houseBill = Db.Str(Db.G(r, "house_bill")),
        masterBill = Db.Str(Db.G(r, "master_bill")),
        custRef = Db.Str(Db.G(r, "cust_ref")),
        containerNo = Db.Str(Db.G(r, "container_no")),
        vesselVoyage = Db.Str(Db.G(r, "vessel_voyage")),
        picUser = Db.Str(Db.G(r, "pic_user")),
        createdBy = Db.Str(Db.G(r, "created_by")),
        worst = Db.Str(Db.G(r, "worst_light")),
        arrivalState = Db.Str(Db.G(r, "arrival_state")),
        jobStatus = Db.Str(Db.G(r, "job_status")),
        anchor = Db.Str(Db.G(r, "anchor_date")),
        etd = Db.Str(Db.G(r, "etd")),
        eta = Db.Str(Db.G(r, "eta")),
        ata = Db.Str(Db.G(r, "ata")),
        hasNote,
    };

    static object NoteItem(Row n, Row? ctx) => new
    {
        type = "note",
        id = Db.Str(Db.G(n, "id")),
        jobNo = Db.Str(Db.G(n, "job_no")),
        humanId = ctx != null ? HumanId(ctx) : Db.Str(Db.G(n, "job_no")),
        author = Db.Str(Db.G(n, "user")),
        note = Db.Str(Db.G(n, "note")),
        mentions = Db.Str(Db.G(n, "mentions")).Split(',').Where(s => s.Trim() != "").ToArray(),
        kind = Db.Str(Db.G(n, "kind")),
        created = Db.Str(Db.G(n, "created")),
        // shipment context for the card (blank when the parent is out of scope / absent — which also means it won't show)
        lane = ctx != null ? Db.Str(Db.G(ctx, "lane")) : "",
        mode = ctx != null ? Db.Str(Db.G(ctx, "mode")) : "",
        bound = ctx != null ? Db.Str(Db.G(ctx, "bound")) : "",
        shipperName = ctx != null ? Db.Str(Db.G(ctx, "shipper_name")) : "",
        consigneeName = ctx != null ? Db.Str(Db.G(ctx, "consignee_name")) : "",
    };
}
