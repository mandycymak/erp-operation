using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// Row-level access scope (serve-ops.ps1 lines 336-383). In serve-ops.ps1 these read the shared $script:CurUser;
// here every builder takes the per-request ReqState, so concurrent requests can never read each other's scope —
// the whole point of the migration. Every builder is a no-op when the user is open/unrestricted on that dim.
public static class Scope
{
    static string[] Trimmed(string[] xs) => xs.Select(x => x.Trim()).Where(x => x != "").ToArray();

    public static string[] CurStations(ReqState rs) => rs.Open ? Array.Empty<string>() : Trimmed(rs.User!.Stations);
    public static string[] CurPairs(ReqState rs) => rs.Open ? Array.Empty<string>()
        : Trimmed(rs.User!.Access).Where(a => System.Text.RegularExpressions.Regex.IsMatch(a, "^(Air|Sea)-(Export|Import)$")).ToArray();
    public static string[] CurTeams(ReqState rs) => rs.Open ? Array.Empty<string>() : Trimmed(rs.User!.Teams);
    public static string Tier(ReqState rs) => rs.Tier;

    // The login name is the APP identity; the ERP pic_user/created_by values are free text and often different.
    // Each credential carries the ERP usernames it owns; "my work" matches the WHOLE alias list. Empty/unknown ->
    // the login name itself. NB: looks up the named user (the worklist 'who' may be a teammate, not the caller).
    public static string[] ErpAliases(ReqState rs, string username)
    {
        if (rs.Open) return new[] { username };
        var u = Auth.FindUser(username);
        var al = u == null ? Array.Empty<string>() : Trimmed(u.ErpUsers).Distinct().ToArray();
        return al.Length > 0 ? al : new[] { username };
    }

    // " AND <col> IN (@sst0,@sst1,...) " or "" when unrestricted. Registers the params into p.
    public static string StationClause(ReqState rs, Dictionary<string, object?> p, string col = "station", string prefix = "sst")
    {
        var sts = CurStations(rs);
        if (sts.Length == 0) return "";
        var ins = new List<string>();
        for (int i = 0; i < sts.Length; i++) { ins.Add($"@{prefix}{i}"); p[$"{prefix}{i}"] = sts[i]; }
        return $" AND {col} IN ({string.Join(",", ins)}) ";
    }

    // " AND ((mode=@scpm0 AND bound=@scpb0) OR ...) " over the user's mode-bound pairs, or "". The column names
    // are overridable so the clause can be aliased inside a correlated subquery (e.g. s.mode/s.bound in Find's
    // note EXISTS); defaults keep every existing caller unchanged.
    public static string PairClause(ReqState rs, Dictionary<string, object?> p, string modeCol = "mode", string boundCol = "bound")
    {
        var prs = CurPairs(rs);
        if (prs.Length == 0) return "";
        var ors = new List<string>();
        for (int i = 0; i < prs.Length; i++)
        {
            var parts = prs[i].Split('-');
            ors.Add($"({modeCol}=@scpm{i} AND {boundCol}=@scpb{i})");
            p[$"scpm{i}"] = parts[0]; p[$"scpb{i}"] = parts[1];
        }
        return $" AND ({string.Join(" OR ", ors)}) ";
    }

    // System-identity expressions for pic_user / last_updated_by (rows written by API/EDI*/QUOTATION etc.
    // broadcast to everyone's "My work" until a real user takes over). Registers @su*/@sup* params. Null = none.
    public static (string Pic, string Lub)? SysExprs(Dictionary<string, object?> p)
    {
        var sysUsers = Config.SystemUsers; var sysPrefixes = Config.SystemUserPrefixes;
        if (sysUsers.Count == 0 && sysPrefixes.Count == 0) return null;
        var ins = new List<string>();
        for (int i = 0; i < sysUsers.Count; i++) { ins.Add($"@su{i}"); p[$"su{i}"] = sysUsers[i]; }
        for (int j = 0; j < sysPrefixes.Count; j++) p[$"sup{j}"] = Db.LikeEsc(sysPrefixes[j]) + "%";
        string Mk(string col)
        {
            var t = new List<string>();
            if (ins.Count > 0) t.Add($"{col} IN ({string.Join(",", ins)})");
            for (int k = 0; k < sysPrefixes.Count; k++) t.Add($"{col} LIKE @sup{k}");
            return "(" + string.Join(" OR ", t) + ")";
        }
        return (Mk("pic_user"), Mk("last_updated_by"));
    }

    // Per-job scope check for the by-job endpoints (drawer, erp-detail, milestone-close): out-of-scope rows are
    // reported 'not found' — indistinguishable from absent, no existence oracle.
    public static bool TestJobScope(ReqState rs, Row row)
    {
        if (rs.Open) return true;
        var sts = CurStations(rs);
        if (sts.Length > 0 && !sts.Contains(Db.Str(Db.G(row, "station")))) return false;
        var prs = CurPairs(rs);
        if (prs.Length > 0 && !prs.Contains($"{Db.Str(Db.G(row, "mode"))}-{Db.Str(Db.G(row, "bound"))}")) return false;
        return true;
    }
}
