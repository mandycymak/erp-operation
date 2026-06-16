using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/inbound (serve-ops.ps1 440-495) ----
    // cross-station bookings destined to THIS station (reads only the small pgsops feed; no ERP/cross-DB).
    public static object Inbound(SqlConnection cn, Qs q, ReqState rs)
    {
        var p = new Dictionary<string, object?>();
        var userSts = Scope.CurStations(rs);
        string st, w;
        if (userSts.Length > 0)
        {
            // AUTH mode with station scope: pre-arrival is always "what is coming to MY station(s)" (?station= ignored).
            var pairs = Scope.CurPairs(rs);
            var impModes = pairs.Where(x => x.EndsWith("-Import")).Select(x => x.Split('-')[0]).Distinct().ToArray();
            if (pairs.Length > 0 && impModes.Length == 0)
                return new { station = string.Join(",", userSts), rows = Array.Empty<object>(), note = "no import access" };
            var ins = new List<string>();
            for (int i = 0; i < userSts.Length; i++) { ins.Add($"@ist{i}"); p[$"ist{i}"] = userSts[i]; }
            w = $" WHERE f.dest_station IN ({string.Join(",", ins)}) AND f.feed_status<>'void' ";
            if (impModes.Length > 0)
            {
                var mins = new List<string>();
                for (int i = 0; i < impModes.Length; i++) { mins.Add($"@ibm{i}"); p[$"ibm{i}"] = impModes[i]; }
                w += $" AND f.mode IN ({string.Join(",", mins)}) ";
            }
            st = string.Join(",", userSts);
        }
        else
        {
            st = q["station"]?.Trim() ?? Config.StationCode;
            if (st == "") return new { station = "", rows = Array.Empty<object>(), note = "no stationCode configured" };
            p["st"] = st; w = " WHERE f.dest_station=@st AND f.feed_status<>'void' ";
        }

        if (q["mode"] != null) { w += " AND f.mode=@md "; p["md"] = q["mode"]; }
        if (q["from"] != null) { w += " AND (f.etd IS NULL OR f.etd>=@from) "; p["from"] = q["from"]; }
        if (q["to"] != null) { w += " AND (f.etd IS NULL OR f.etd<=@to) "; p["to"] = q["to"]; }
        if (q["status"] != null) { w += " AND f.feed_status=@fs "; p["fs"] = q["status"]; }

        var origins = Db.ParseList(q["origin"]);
        if (origins.Length > 0) { var ins = new List<string>(); for (int i = 0; i < origins.Length; i++) { ins.Add($"@og{i}"); p[$"og{i}"] = origins[i]; } w += $" AND f.source_station IN ({string.Join(",", ins)}) "; }
        var fpols = Db.ParseList(q["pol"]);
        if (fpols.Length > 0) { var ins = new List<string>(); for (int i = 0; i < fpols.Length; i++) { ins.Add($"@fpl{i}"); p[$"fpl{i}"] = fpols[i]; } w += $" AND f.pol IN ({string.Join(",", ins)}) "; }
        var fpods = Db.ParseList(q["pod"]);
        if (fpods.Length > 0) { var ins = new List<string>(); for (int i = 0; i < fpods.Length; i++) { ins.Add($"@fpd{i}"); p[$"fpd{i}"] = fpods[i]; } w += $" AND f.pod IN ({string.Join(",", ins)}) "; }

        if (!string.IsNullOrWhiteSpace(q["party"]))
        {
            p["pty"] = "%" + Db.LikeEsc(q["party"]!.Trim()) + "%";
            w += " AND (f.shipper_name LIKE @pty OR f.shipper_code LIKE @pty OR f.consignee_name LIKE @pty OR f.consignee_code LIKE @pty OR f.ctrl_name LIKE @pty OR f.ctrl_code LIKE @pty) ";
        }
        if (!string.IsNullOrWhiteSpace(q["q"]))
        {
            p["q"] = "%" + Db.LikeEsc(q["q"]!.Trim()) + "%";
            w += " AND (f.booking_no LIKE @q OR f.spot_id LIKE @q OR f.po_no LIKE @q OR f.house_bill LIKE @q OR f.master_bill LIKE @q OR f.container_no LIKE @q) ";
        }

        // default recency window: keep upcoming departures (ETD today+) and recently-booked (last 90d). showAll=1 reveals all.
        if (q["showAll"] == null)
        {
            var today = Config.TodayDate().ToString("yyyy-MM-dd");
            var cut90 = Config.TodayDate().AddDays(-90).ToString("yyyy-MM-dd");
            w += " AND ( (f.etd IS NOT NULL AND f.etd>=@today) OR (f.etd IS NULL AND (f.booking_date IS NULL OR f.booking_date>=@cut90)) ) ";
            p["today"] = today; p["cut90"] = cut90;
        }

        // dedup vs Arrivals: if this origin HBL already exists as a local import job, show it under arrivals, not here.
        w += " AND NOT EXISTS (SELECT 1 FROM dbo.shipment_alerts sa WHERE sa.station=f.dest_station AND sa.bound='Import' AND NULLIF(LTRIM(RTRIM(f.house_bill)),'') IS NOT NULL AND sa.house_bill=f.house_bill) ";

        var sel = "SELECT source_station,mode,booking_no,dest_station,source_jobn,master_bill,house_bill,shipper_code,shipper_name," +
            "ctrl_code,ctrl_name,agent_code,agent_name,consignee_code,consignee_name,cargo_type,service,container_no,po_no,spot_id,booking_qty,booking_wgt," +
            "pol,pod,carrier,vessel_flight,CONVERT(varchar(10),etd,23) etd," +
            "CONVERT(varchar(10),cargo_ready,23) cargo_ready,incoterm,cargo_summary,CONVERT(varchar(10),booking_date,23) booking_date," +
            "feed_status,assigned_to,linked_job_no,light FROM dbo.inbound_booking_feed f " + w +
            "ORDER BY CASE light WHEN 'R' THEN 0 WHEN 'A' THEN 1 ELSE 2 END, etd, source_station, source_jobn, booking_no";
        var rows = Db.RunQ(cn, sel, p);

        return new
        {
            station = st,
            rows = rows.Select(r => new
            {
                sourceStation = Db.Str(Db.G(r, "source_station")),
                mode = Db.Str(Db.G(r, "mode")),
                bookingNo = Db.Str(Db.G(r, "booking_no")),
                destStation = Db.Str(Db.G(r, "dest_station")),
                sourceJobn = Db.Str(Db.G(r, "source_jobn")),
                masterBill = Db.Str(Db.G(r, "master_bill")),
                houseBill = Db.Str(Db.G(r, "house_bill")),
                shipperCode = Db.Str(Db.G(r, "shipper_code")),
                shipperName = Db.Str(Db.G(r, "shipper_name")),
                ctrlCode = Db.Str(Db.G(r, "ctrl_code")),
                ctrlName = Db.Str(Db.G(r, "ctrl_name")),
                agentCode = Db.Str(Db.G(r, "agent_code")),
                agentName = Db.Str(Db.G(r, "agent_name")),
                consigneeCode = Db.Str(Db.G(r, "consignee_code")),
                consigneeName = Db.Str(Db.G(r, "consignee_name")),
                cargoType = Db.Str(Db.G(r, "cargo_type")),
                service = Db.Str(Db.G(r, "service")),
                containerNo = Db.Str(Db.G(r, "container_no")),
                poNo = Db.Str(Db.G(r, "po_no")),
                spotId = Db.Str(Db.G(r, "spot_id")),
                bookingQty = Db.Str(Db.G(r, "booking_qty")),
                bookingWgt = Db.Str(Db.G(r, "booking_wgt")),
                pol = Db.Str(Db.G(r, "pol")),
                pod = Db.Str(Db.G(r, "pod")),
                carrier = Db.Str(Db.G(r, "carrier")),
                vesselFlight = Db.Str(Db.G(r, "vessel_flight")),
                etd = Db.Str(Db.G(r, "etd")),
                cargoReady = Db.Str(Db.G(r, "cargo_ready")),
                incoterm = Db.Str(Db.G(r, "incoterm")),
                cargoSummary = Db.Str(Db.G(r, "cargo_summary")),
                bookingDate = Db.Str(Db.G(r, "booking_date")),
                feedStatus = Db.Str(Db.G(r, "feed_status")),
                assignedTo = Db.Str(Db.G(r, "assigned_to")),
                linkedJobNo = Db.Str(Db.G(r, "linked_job_no")),
                light = Db.Str(Db.G(r, "light")),
            }).ToArray()
        };
    }
}
