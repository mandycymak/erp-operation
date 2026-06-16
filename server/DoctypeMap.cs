using Microsoft.Data.SqlClient;

namespace Ops;

// Cached doctype -> milestone map, derived from milestone_evidence_map (admin-editable). An uploaded document of
// type X clears every milestone whose pic_doctype evidence rule matches X for the shipment's bound/module. Built
// once; reset to null on any admin milestone/evidence edit so changes take effect with no restart
// (serve-ops.ps1 Get-MilestoneDoctypeMap). Consumed by the ERP upload-to-clear flow (Stage 4).
public static class DoctypeMap
{
    public sealed record Link(string Code, string Name, string Bound, string Module);

    static volatile Dictionary<string, List<Link>>? _cache;
    static readonly object _lock = new();

    public static void Reset() => _cache = null;

    public static Dictionary<string, List<Link>> Get(SqlConnection cn)
    {
        var c = _cache;
        if (c != null) return c;
        lock (_lock)
        {
            if (_cache != null) return _cache;
            var m = new Dictionary<string, List<Link>>(StringComparer.Ordinal);
            var rows = Db.RunQ(cn,
                "SELECT em.match_value doctype, em.milestone_code, em.bound, em.module_match, d.name " +
                "FROM dbo.milestone_evidence_map em LEFT JOIN dbo.milestone_def d ON d.milestone_code=em.milestone_code AND d.bound=em.bound " +
                "WHERE em.active=1 AND em.source_kind='pic_doctype' AND NULLIF(em.match_value,'') IS NOT NULL", new Dictionary<string, object?>());
            foreach (var r in rows)
            {
                var dt = Db.Str(Db.G(r, "doctype")).Trim();
                if (dt == "") continue;
                if (!m.TryGetValue(dt, out var list)) { list = new List<Link>(); m[dt] = list; }
                list.Add(new Link(Db.Str(Db.G(r, "milestone_code")).Trim(), Db.Str(Db.G(r, "name")).Trim(),
                    Db.Str(Db.G(r, "bound")).Trim(), Db.Str(Db.G(r, "module_match")).Trim()));
            }
            _cache = m;
            return m;
        }
    }
}
