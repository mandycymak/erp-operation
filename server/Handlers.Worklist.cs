using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/worklist (serve-ops.ps1 518-635) ----
    public static object Worklist(SqlConnection cn, Qs q, ReqState rs)
    {
        var me = rs.Me;
        var lens = q["lens"] ?? "mine";
        var who = (lens == "user" && q["user"] != null) ? q["user"]!.Trim() : me;

        // teammate lens (auth): operators may only view users sharing >=1 team; admin/manager see anyone.
        if (Auth.Snap.AuthOn && lens == "user" && who != me && rs.Tier is not ("admin" or "manager"))
        {
            var tu = Auth.FindUser(who);
            var myTeams = Scope.CurTeams(rs);
            var shared = tu?.Teams.Where(t => myTeams.Contains(t.Trim())).ToArray() ?? Array.Empty<string>();
            if (tu == null || shared.Length == 0)
                return new { lens, who, rows = Array.Empty<object>(), error = "not a teammate" };
        }

        var p = new Dictionary<string, object?>();
        var w = " WHERE job_status='active' ";
        var refq = (q["ref"] ?? "").Trim();
        var refField = q["refField"] ?? "";
        bool flagNotes = (q["flag"] ?? "").Contains("notes");
        var myNoteJobs = flagNotes ? Notes.MyOpenNoteJobs(who) : Array.Empty<string>();

        // ownership lens: admin / 'all' / ?ref= / "My notes" all bypass the pic-ownership filter.
        if (refq != "" || flagNotes || lens == "all" || (lens != "user" && rs.Tier == "admin")) { }
        else
        {
            var als = Scope.ErpAliases(rs, who);
            var ains = new List<string>();
            for (int i = 0; i < als.Length; i++) { ains.Add($"@eu{i}"); p[$"eu{i}"] = als[i]; }
            var ainl = string.Join(",", ains);
            var clauses = new List<string> { $"pic_user IN ({ainl})", $"created_by IN ({ainl})", $"last_updated_by IN ({ainl})" };
            var jobs = Notes.MyNoteJobs(who);
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

        if (q["station"] != null) { w += " AND station=@st "; p["st"] = q["station"]; }
        if (q["mode"] != null) { w += " AND mode=@md "; p["md"] = q["mode"]; }

        // date window = "needs my attention in this range" (moving/work-due/created), plus overdue <=30d.
        if (refq == "" && !flagNotes && (q["from"] != null || q["to"] != null))
        {
            p["dlo"] = q["from"] ?? "0001-01-01";
            p["dhi"] = q["to"] ?? "9999-12-31";
            p["dtoday"] = Config.TodayDate().ToString("yyyy-MM-dd");
            w += " AND ( (sort_key IS NULL AND next_due IS NULL AND anchor_date IS NULL) " +
                 "OR sort_key BETWEEN @dlo AND @dhi OR next_due BETWEEN @dlo AND @dhi " +
                 "OR (next_due<@dtoday AND next_due>=DATEADD(day,-30,CONVERT(date,@dtoday))) " +
                 "OR anchor_date BETWEEN @dlo AND @dhi ) ";
        }

        // identifier search: one column (when a field is picked) or the whole identifier set (Any).
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

        if (flagNotes)
        {
            if (myNoteJobs.Length > 0)
            {
                var ins = new List<string>();
                for (int i = 0; i < myNoteJobs.Length; i++) { ins.Add($"@nf{i}"); p[$"nf{i}"] = myNoteJobs[i]; }
                w += " AND job_no IN (" + string.Join(",", ins) + ") ";
            }
            else w += " AND 1=0 ";
        }

        if (q["company"] != null) { w += " AND @co IN (cust_code,shipper_code,consignee_code,agent_code,ctrl_code) "; p["co"] = q["company"]; }

        var pols = Db.ParseList(q["pol"]);
        if (pols.Length > 0) { var ins = new List<string>(); for (int i = 0; i < pols.Length; i++) { ins.Add($"@pol{i}"); p[$"pol{i}"] = pols[i]; } w += $" AND pol IN ({string.Join(",", ins)}) "; }
        var pods = Db.ParseList(q["pod"]);
        if (pods.Length > 0) { var ins = new List<string>(); for (int i = 0; i < pods.Length; i++) { ins.Add($"@pod{i}"); p[$"pod{i}"] = pods[i]; } w += $" AND pod IN ({string.Join(",", ins)}) "; }

        w += Scope.StationClause(rs, p);
        w += Scope.PairClause(rs, p);

        var sel = "SELECT job_no,erp_job_no,station,mode,cargo_type,bound,lane,carrier,cust_code,salesman,pic_user,created_by,last_updated_by," +
            "CONVERT(varchar(10),anchor_date,23) anchor_date,CONVERT(varchar(10),etd,23) etd,CONVERT(varchar(10),eta,23) eta," +
            "CONVERT(varchar(10),atd,23) atd,CONVERT(varchar(10),ata,23) ata,worst_light,open_amber,open_red," +
            "CONVERT(varchar(10),next_due,23) next_due,auto_done,manual_done,consignee_name,shipper_name,cust_contact,cust_phone," +
            "cust_email,vessel_voyage,container_summary,container_count,total_weight,total_cbm,arrival_state," +
            "house_bill,master_bill,incoterm,cust_ref,container_no,liner_so,CONVERT(varchar(10),cargo_ready,23) cargo_ready," +
            "shipper_code,consignee_code,agent_code,ctrl_code," +
            "commodity,sono,bill_stage,route_summary,CONVERT(varchar(10),available_date,23) available_date," +
            "CONVERT(varchar(10),eta_delivery,23) eta_delivery,CONVERT(varchar(10),goods_delivery,23) goods_delivery," +
            "CONVERT(varchar(10),sort_key,23) sort_key FROM dbo.shipment_alerts " + w +
            "ORDER BY bound, CASE arrival_state WHEN 'arrived' THEN 0 WHEN 'no_space' THEN 0 WHEN 'arriving' THEN 1 WHEN 'customs_window' THEN 1 WHEN 'planning' THEN 2 WHEN 'cargo_pending' THEN 2 WHEN 'on_track' THEN 3 ELSE 9 END, sort_key, CASE worst_light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END";
        var rows = Db.RunQ(cn, sel, p);

        // split open notes into chat (a real remark) vs status-update (a milestone ticked with no remark).
        var chatJobs = new Dictionary<string, (string text, string code, string created)>();
        var updJobs = new Dictionary<string, (string code, string created)>();
        try
        {
            foreach (var nt in Notes.Read())
            {
                if (!nt.IsOpen) continue;
                var jk = nt.JobNo; if (jk == "") continue;
                if (nt.IsMilestone && nt.EffectiveSilent)
                {
                    if (!updJobs.TryGetValue(jk, out var cur) || string.CompareOrdinal(nt.Created, cur.created) > 0)
                        updJobs[jk] = (nt.MilestoneCode, nt.Created);
                }
                else
                {
                    if (!chatJobs.TryGetValue(jk, out var cur) || string.CompareOrdinal(nt.Created, cur.created) > 0)
                    {
                        var txt = nt.Note; if (txt.Length > 160) txt = txt.Substring(0, 160) + "...";
                        chatJobs[jk] = (txt, nt.MilestoneCode, nt.Created);
                    }
                }
            }
        }
        catch { }

        // milestone code -> human name (keyed mode|bound|code).
        var msName = new Dictionary<string, string>();
        try
        {
            foreach (var md in Db.RunQ(cn, "SELECT mode,bound,milestone_code,name FROM dbo.milestone_def", new Dictionary<string, object?>()))
                msName[$"{Db.Str(Db.G(md, "mode"))}|{Db.Str(Db.G(md, "bound"))}|{Db.Str(Db.G(md, "milestone_code"))}".ToUpperInvariant()] = Db.Str(Db.G(md, "name")).Trim();
        }
        catch { }

        var outRows = rows.Select(r =>
        {
            var jk = Db.Str(Db.G(r, "job_no"));
            chatJobs.TryGetValue(jk, out var chat); var hasChat = chatJobs.ContainsKey(jk);
            updJobs.TryGetValue(jk, out var upd); var hasUpd = updJobs.ContainsKey(jk);
            var updName = "";
            if (hasUpd) msName.TryGetValue($"{Db.Str(Db.G(r, "mode"))}|{Db.Str(Db.G(r, "bound"))}|{upd.code}".ToUpperInvariant(), out updName!);
            return new
            {
                jobNo = jk,
                erpJobNo = Db.Str(Db.G(r, "erp_job_no")),
                station = Db.Str(Db.G(r, "station")),
                mode = Db.Str(Db.G(r, "mode")),
                cargoType = Db.Str(Db.G(r, "cargo_type")),
                bound = Db.Str(Db.G(r, "bound")),
                lane = Db.Str(Db.G(r, "lane")),
                carrier = Db.Str(Db.G(r, "carrier")),
                custCode = Db.Str(Db.G(r, "cust_code")),
                salesman = Db.Str(Db.G(r, "salesman")),
                picUser = Db.Str(Db.G(r, "pic_user")),
                createdBy = Db.Str(Db.G(r, "created_by")),
                anchor = Db.Str(Db.G(r, "anchor_date")),
                etd = Db.Str(Db.G(r, "etd")),
                eta = Db.Str(Db.G(r, "eta")),
                atd = Db.Str(Db.G(r, "atd")),
                ata = Db.Str(Db.G(r, "ata")),
                worst = Db.Str(Db.G(r, "worst_light")),
                openAmber = Db.IntOf(Db.G(r, "open_amber")),
                openRed = Db.IntOf(Db.G(r, "open_red")),
                nextDue = Db.Str(Db.G(r, "next_due")),
                autoDone = Db.IntOf(Db.G(r, "auto_done")),
                manualDone = Db.IntOf(Db.G(r, "manual_done")),
                consigneeName = Db.Str(Db.G(r, "consignee_name")),
                shipperName = Db.Str(Db.G(r, "shipper_name")),
                custContact = Db.Str(Db.G(r, "cust_contact")),
                custPhone = Db.Str(Db.G(r, "cust_phone")),
                custEmail = Db.Str(Db.G(r, "cust_email")),
                vesselVoyage = Db.Str(Db.G(r, "vessel_voyage")),
                containerSummary = Db.Str(Db.G(r, "container_summary")),
                containerCount = Db.IntOf(Db.G(r, "container_count")),
                totalWeight = Db.Str(Db.G(r, "total_weight")),
                totalCbm = Db.Str(Db.G(r, "total_cbm")),
                arrivalState = Db.Str(Db.G(r, "arrival_state")),
                houseBill = Db.Str(Db.G(r, "house_bill")),
                masterBill = Db.Str(Db.G(r, "master_bill")),
                incoterm = Db.Str(Db.G(r, "incoterm")),
                custRef = Db.Str(Db.G(r, "cust_ref")),
                containerNo = Db.Str(Db.G(r, "container_no")),
                linerSo = Db.Str(Db.G(r, "liner_so")),
                cargoReady = Db.Str(Db.G(r, "cargo_ready")),
                sortKey = Db.Str(Db.G(r, "sort_key")),
                shipperCode = Db.Str(Db.G(r, "shipper_code")),
                consigneeCode = Db.Str(Db.G(r, "consignee_code")),
                agentCode = Db.Str(Db.G(r, "agent_code")),
                ctrlCode = Db.Str(Db.G(r, "ctrl_code")),
                commodity = Db.Str(Db.G(r, "commodity")),
                sono = Db.Str(Db.G(r, "sono")),
                billStage = Db.Str(Db.G(r, "bill_stage")),   // 'booking' (pre-house) vs 'house'; UI shows a Booking badge

                routeSummary = Db.Str(Db.G(r, "route_summary")),
                availableDate = Db.Str(Db.G(r, "available_date")),
                etaDelivery = Db.Str(Db.G(r, "eta_delivery")),
                goodsDelivery = Db.Str(Db.G(r, "goods_delivery")),
                hasNotes = hasChat,
                noteText = hasChat ? chat.text : "",
                noteMilestone = hasChat ? chat.code : "",
                hasUpdate = hasUpd,
                updateMilestone = hasUpd ? upd.code : "",
                updateMilestoneName = updName ?? "",
            };
        }).ToArray();

        return new { lens, who, rows = outRows };
    }
}
