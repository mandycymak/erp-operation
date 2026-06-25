using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // GET /api-ops/new-bookings - newly-received bookings (dbo.booking_alert) for the caller's STATION(S). Operator-
    // facing and row-level scoped: Scope.StationClause limits to the user's station scope, so each user sees "my/our
    // station's new bookings"; an unrestricted user (admin) sees all. Date range defaults to the last 7 days; from/to
    // (yyyy-mm-dd) + free-text q optional. Bounded by a row cap with a `truncated` signal.
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

        var p = new Dictionary<string, object?> { ["n"] = limit + 1, ["from"] = fromDt, ["to"] = toDt };
        var w = " WHERE detected_at >= @from AND detected_at < @to ";
        w += Scope.StationClause(rs, p);   // <-- the scope boundary: the caller's station(s); "" when unrestricted
        if (qf != "")
        {
            w += " AND (booking_no LIKE @q OR shipper_name LIKE @q OR pol LIKE @q OR pod LIKE @q OR job_no LIKE @q) ";
            p["q"] = "%" + Db.LikeEsc(qf) + "%";
        }
        var rows = Db.RunQ(cn,
            "SELECT TOP (@n) CONVERT(varchar(19),detected_at,120) detected_at, station, mode, booking_no, job_no, shipper_name, " +
            "factory_contact, factory_email, pol, pod, CONVERT(varchar(19),src_created,120) src_created, status, channel " +
            "FROM dbo.booking_alert " + w + " ORDER BY detected_at DESC, id DESC", p);
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
            }).ToArray()
        };
    }
}
