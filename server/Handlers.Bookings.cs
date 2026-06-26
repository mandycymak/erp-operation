using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // GET /api-ops/new-bookings - newly-received bookings (dbo.booking_alert) for the caller's STATION(S). Operator-
    // facing and row-level scoped: Scope.StationClause limits to the user's station scope, so each user sees "my/our
    // station's new bookings"; an unrestricted user (admin) sees all. Date range defaults to the last 7 days; from/to
    // (yyyy-mm-dd) + free-text q + mode (Air|Sea) optional. Bounded by a row cap with a `truncated` signal.
    // Each booking is enriched (OUTER APPLY) from dbo.shipment_alerts on the stable (station,mode,erp_ref) key so the
    // card can show cargo/parties/incoterm AND deep-link via the synthetic shipment_alerts.job_no (ship_job) - the raw
    // ERP job_no on booking_alert does NOT match the /api-ops/shipment key, so opening had to go through ship_job.
    public static object NewBookings(SqlConnection cn, Qs q, ReqState rs)
    {
        var rx = new Regex(@"^\d{4}-\d{2}-\d{2}$");
        var today = DateTime.Now.Date;
        var fs = (q["from"] ?? "").Trim(); var ts = (q["to"] ?? "").Trim();
        var fromDt = rx.IsMatch(fs) ? DateTime.ParseExact(fs, "yyyy-MM-dd", null) : today.AddDays(-7);
        var toDt = (rx.IsMatch(ts) ? DateTime.ParseExact(ts, "yyyy-MM-dd", null) : today).AddDays(1);
        if (toDt <= fromDt) toDt = fromDt.AddDays(1);
        int.TryParse(q["limit"], out var limit); if (limit <= 0 || limit > 500) limit = 200;
        var qf = (q["q"] ?? "").Trim();
        var mode = (q["mode"] ?? "").Trim();   // Air | Sea (the panel's Air/Sea selector); empty = both

        var p = new Dictionary<string, object?> { ["n"] = limit + 1, ["from"] = fromDt, ["to"] = toDt };
        var w = " WHERE ba.detected_at >= @from AND ba.detected_at < @to ";
        w += Scope.StationClause(rs, p, "ba.station");   // <-- the scope boundary: the caller's station(s); "" when unrestricted
        if (mode is "Air" or "Sea") { w += " AND ba.mode=@md "; p["md"] = mode; }
        if (qf != "")
        {
            w += " AND (ba.booking_no LIKE @q OR ba.shipper_name LIKE @q OR ba.pol LIKE @q OR ba.pod LIKE @q OR ba.job_no LIKE @q) ";
            p["q"] = "%" + Db.LikeEsc(qf) + "%";
        }
        var rows = Db.RunQ(cn,
            "SELECT TOP (@n) CONVERT(varchar(19),ba.detected_at,120) detected_at, ba.station, ba.mode, ba.booking_no, ba.job_no, ba.shipper_name, " +
            "ba.factory_contact, ba.factory_email, ba.pol, ba.pod, CONVERT(varchar(19),ba.src_created,120) src_created, ba.status, ba.channel, " +
            "sa.job_no ship_job, sa.cargo_type, sa.incoterm, sa.commodity, sa.container_summary, sa.total_weight, sa.total_cbm, " +
            "sa.consignee_name, sa.shipper_code, sa.consignee_code, sa.agent_code, sa.ctrl_code, sa.cust_code, " +
            "sa.house_bill, sa.master_bill, sa.container_no, sa.container_count, sa.liner_so, sa.cust_ref " +
            "FROM dbo.booking_alert ba " +
            "OUTER APPLY (SELECT TOP 1 s.job_no, s.cargo_type, s.incoterm, s.commodity, s.container_summary, s.total_weight, s.total_cbm, " +
            "  s.consignee_name, s.shipper_code, s.consignee_code, s.agent_code, s.ctrl_code, s.cust_code, " +
            "  s.house_bill, s.master_bill, s.container_no, s.container_count, s.liner_so, s.cust_ref " +
            "  FROM dbo.shipment_alerts s WHERE s.station=ba.station AND s.mode=ba.mode AND s.erp_ref=ba.erp_ref AND s.job_status='active' " +
            "  ORDER BY CASE WHEN s.bill_stage='booking' THEN 0 ELSE 1 END) sa " +
            w + " ORDER BY ba.detected_at DESC, ba.id DESC", p);
        bool truncated = rows.Count > limit;
        if (truncated) rows = rows.Take(limit).ToList();
        return new
        {
            from = fromDt.ToString("yyyy-MM-dd"), to = toDt.AddDays(-1).ToString("yyyy-MM-dd"),
            count = rows.Count, truncated,
            rows = rows.Select(r => new
            {
                detectedAt = Db.Str(Db.G(r, "detected_at")),
                station = Db.Str(Db.G(r, "station")),
                mode = Db.Str(Db.G(r, "mode")),
                bookingNo = Db.Str(Db.G(r, "booking_no")),
                jobNo = Db.Str(Db.G(r, "job_no")),
                shipperName = Db.Str(Db.G(r, "shipper_name")),
                factoryContact = Db.Str(Db.G(r, "factory_contact")),
                factoryEmail = Db.Str(Db.G(r, "factory_email")),
                pol = Db.Str(Db.G(r, "pol")),
                pod = Db.Str(Db.G(r, "pod")),
                srcCreated = Db.Str(Db.G(r, "src_created")),
                status = Db.Str(Db.G(r, "status")),
                channel = Db.Str(Db.G(r, "channel")),
                // enrichment from shipment_alerts (empty when this booking isn't yet in the worklist set)
                shipJobNo = Db.Str(Db.G(r, "ship_job")),       // synthetic key -> the clickable /api-ops/shipment id
                cargoType = Db.Str(Db.G(r, "cargo_type")),
                incoterm = Db.Str(Db.G(r, "incoterm")),
                commodity = Db.Str(Db.G(r, "commodity")),
                containerSummary = Db.Str(Db.G(r, "container_summary")),
                totalWeight = Db.Str(Db.G(r, "total_weight")),
                totalCbm = Db.Str(Db.G(r, "total_cbm")),
                consigneeName = Db.Str(Db.G(r, "consignee_name")),
                shipperCode = Db.Str(Db.G(r, "shipper_code")),
                consigneeCode = Db.Str(Db.G(r, "consignee_code")),
                agentCode = Db.Str(Db.G(r, "agent_code")),
                ctrlCode = Db.Str(Db.G(r, "ctrl_code")),
                custCode = Db.Str(Db.G(r, "cust_code")),
                // identifiers that appear once the booking progresses (blank at pure booking stage)
                houseBill = Db.Str(Db.G(r, "house_bill")),
                masterBill = Db.Str(Db.G(r, "master_bill")),
                containerNo = Db.Str(Db.G(r, "container_no")),
                containerCount = Db.IntOf(Db.G(r, "container_count")),
                linerSo = Db.Str(Db.G(r, "liner_so")),
                custRef = Db.Str(Db.G(r, "cust_ref")),
            }).ToArray()
        };
    }
}
