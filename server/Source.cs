using System.Collections.Concurrent;
using Microsoft.Data.SqlClient;

namespace Ops;

// Bounded, read-only access to a station's SOURCE ERP database (the ONE sanctioned ERP-on-request-path
// exception: erp-detail / erp-edit-seed / erp-master). Connection is Connect Timeout=15 / Packet Size=512;
// callers pass CommandTimeout=8 so a slow ERP read can't hold a dbGate slot. NEVER written to.
public static class Source
{
    public static string? DbFor(string station) => Config.StationByCode((station ?? "").Trim())?.Database is { Length: > 0 } d ? d : null;

    public static SqlConnection Open(string db)
    {
        var cn = new SqlConnection(Config.SourceConnStr(db));
        cn.Open();
        return cn;
    }

    // Get-ErpCols: we do NOT probe INFORMATION_SCHEMA (catastrophically slow for the read-only login on the
    // ERP's very wide tables — 40-70s and drops the connection). Trust the curated want-list; if a schema-variant
    // office lacks a column, that one keyed SELECT throws and the caller degrades. ntext columns are wrapped in
    // CONVERT(nvarchar(4000),col) AS col. Cached per (db|table|want-list).
    static readonly ConcurrentDictionary<string, string> _cols = new();
    public static string ErpCols(string db, string table, string wantCsv, params string[] ntextCols)
    {
        var key = $"{db}|{table}|{wantCsv}";
        return _cols.GetOrAdd(key, _ =>
        {
            var keep = wantCsv.Split(',').Select(x => x.Trim()).Where(x => x != "");
            return string.Join(",", keep.Select(c => ntextCols.Contains(c) ? $"CONVERT(nvarchar(4000),{c}) AS {c}" : c));
        });
    }

    // owncode = the office that owns a booking (e.g. S0001 = HKG), from fm3kco.site dbname->owncode. This is the
    // ERP's forwarderPartyCode / forwarderCode: the "where the data goes" routing key for every /file/* and
    // /booking/* call (serve-ops.ps1 Get-StationOwnCode / Resolve-ForwarderCode). Cached per db (stable per
    // station); empty cached too (a deployment-stable "fm3kco absent / not set up"). Shared by the edit-seed path
    // (which already holds an open source connection) and the file endpoints (which resolve standalone).
    static readonly ConcurrentDictionary<string, string> _own = new();
    public static string OwnCode(SqlConnection src, string db) => _own.GetOrAdd(db, _ =>
    {
        try { var r = Db.RunQ(src, "SELECT TOP 1 owncode FROM fm3kco.dbo.site WHERE dbname=@d", new Dictionary<string, object?> { ["d"] = db }, 8); return r.Count > 0 ? Db.Str(Db.G(r[0], "owncode")).Trim() : ""; }
        catch { return ""; }
    });

    // The ERP forwarderCode for a station, NOT hard-coded: resolve the station's owncode from fm3kco.site
    // (cache-first; opens one short source connection only on a cache miss). Falls back to erp-api-map.json
    // forwarderCode when the owncode can't be resolved (fm3kco absent / station not mapped).
    public static string ForwarderCode(string station)
    {
        var fallback = ErpMap.Str("forwarderCode").Trim();
        var db = DbFor(station);
        if (db == null) return fallback;
        if (!_own.TryGetValue(db, out var oc))
        {
            SqlConnection? src = null;
            try { src = Open(db); oc = OwnCode(src, db); } catch { oc = ""; } finally { try { src?.Close(); } catch { } }
        }
        return string.IsNullOrEmpty(oc) ? fallback : oc;
    }
}
