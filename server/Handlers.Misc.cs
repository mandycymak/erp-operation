using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ---- /api-ops/roster (serve-ops.ps1 386-402) ----
    // auth mode: the app's credential list (operators see only colleagues sharing >=1 team; admin/manager see
    // everyone). open mode: distinct ERP pic_user/created_by + note authors.
    public static object Roster(SqlConnection cn, Qs q, ReqState rs)
    {
        if (Auth.Snap.AuthOn)
        {
            var me = rs.User!.Username;
            var myTeams = Scope.CurTeams(rs);
            var tier = rs.Tier;
            bool seesAll = tier is "admin" or "manager";
            var vis = Auth.Snap.Users.Where(u =>
                u.Username == me || seesAll || u.Teams.Any(t => myTeams.Contains(t.Trim())));
            return new
            {
                users = vis.OrderBy(u => u.Username, StringComparer.InvariantCulture).Select(u => new
                {
                    username = u.Username,
                    displayName = string.IsNullOrWhiteSpace(u.DisplayName) ? u.Username : u.DisplayName.Trim(),
                    email = u.Email,
                }).ToArray()
            };
        }
        var ops = Db.RunQ(cn,
            "SELECT DISTINCT pic_user u FROM dbo.shipment_alerts WHERE NULLIF(pic_user,'') IS NOT NULL " +
            "UNION SELECT DISTINCT created_by FROM dbo.shipment_alerts WHERE NULLIF(created_by,'') IS NOT NULL",
            new Dictionary<string, object?>()).Select(r => Db.Str(Db.G(r, "u")).Trim());
        IEnumerable<string> noteUsers = Array.Empty<string>();
        try { noteUsers = Notes.Read().SelectMany(n => new[] { n.User }.Concat(n.Mentions)).Select(s => s.Trim()).Where(s => s != ""); } catch { }
        // Match PS exactly: Select-Object -Unique dedups case-insensitively, then Sort-Object orders culture-aware
        // (case-sensitive) — so the @-mention roster lists identically (punctuation/case ordering included).
        var all = ops.Concat(noteUsers).Where(s => s != "" && s != "(open)").Distinct(StringComparer.InvariantCultureIgnoreCase).OrderBy(s => s, StringComparer.InvariantCulture);
        return new { users = all.Select(u => new { username = u, displayName = u, email = "" }).ToArray() };
    }

    // ---- /api-ops/companies (serve-ops.ps1 404-409) ----
    // every company on an active shipment (any role), resolved to its name; scoped to the user's stations.
    public static object Companies(SqlConnection cn, Qs q, ReqState rs)
    {
        var p = new Dictionary<string, object?>();
        var sc = Scope.StationClause(rs, p, "a.station", "cst");
        var rows = Db.RunQ(cn,
            "SELECT c.code, c.name FROM dbo.company_dim c WHERE EXISTS (SELECT 1 FROM dbo.shipment_alerts a " +
            "WHERE a.job_status='active' AND c.code IN (a.cust_code,a.shipper_code,a.consignee_code,a.agent_code,a.ctrl_code) " + sc +
            ") ORDER BY CASE WHEN NULLIF(c.name,'') IS NULL THEN 1 ELSE 0 END, c.name, c.code", p);
        return new
        {
            companies = rows.Select(r => new
            {
                code = Db.Str(Db.G(r, "code")),
                name = Db.Str(Db.G(r, "name")).Trim() is var nm && nm != "" ? nm : Db.Str(Db.G(r, "code")),
            }).ToArray()
        };
    }

    // ---- /api-ops/ports (serve-ops.ps1 414-437) ----
    // the FULL port master + the active pol/pod codes. Cached 15 min (it's the same for everyone, ~5k rows).
    static object? _portsCache;
    static DateTime _portsAt;
    static readonly object _portsLock = new();
    public static object Ports(SqlConnection cn, Qs q, ReqState rs)
    {
        lock (_portsLock)
            if (_portsCache != null && (DateTime.Now - _portsAt).TotalMinutes < 15) return _portsCache;

        var all = Db.RunQ(cn, "SELECT code,module,name,country FROM dbo.port_dim", new Dictionary<string, object?>());
        var pol = Db.RunQ(cn, "SELECT DISTINCT pol code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pol,'') IS NOT NULL", new Dictionary<string, object?>());
        var pod = Db.RunQ(cn, "SELECT DISTINCT pod code, mode FROM dbo.shipment_alerts WHERE job_status='active' AND NULLIF(pod,'') IS NOT NULL", new Dictionary<string, object?>());
        var payload = new
        {
            ports = all.Select(r => new { code = Db.Str(Db.G(r, "code")), module = Db.Str(Db.G(r, "module")), name = Db.Str(Db.G(r, "name")), country = Db.Str(Db.G(r, "country")) }).ToArray(),
            activePol = pol.Select(r => new { code = Db.Str(Db.G(r, "code")), mode = Db.Str(Db.G(r, "mode")) }).ToArray(),
            activePod = pod.Select(r => new { code = Db.Str(Db.G(r, "code")), mode = Db.Str(Db.G(r, "mode")) }).ToArray(),
        };
        lock (_portsLock) { _portsCache = payload; _portsAt = DateTime.Now; }
        return payload;
    }
}
