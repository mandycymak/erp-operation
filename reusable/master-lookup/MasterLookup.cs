// MasterLookup.cs - drop-in master code-lookup search (port / customer / liner / service / incoterm).
// Extracted from server/Handlers.Erp.cs (ErpMaster) with the row-level-scope / ReqState / shipment_alerts
// coupling REMOVED, so it lifts into any project. Sole dependency: Microsoft.Data.SqlClient (raw ADO, no Dapper,
// no Db helper). Bounded live LIKE seek - TOP 20, CommandTimeout 8s.
//
// Usage (minimal-API / Kestrel):
//   app.MapGet("/api-ops/erp-master", (string kind, string? q, bool air) => {
//       using var src = OpenSourceErp(/* the read-only station ERP db for this request */);
//       return Results.Json(MasterLookup.Search(src, kind, q, air), MasterLookup.JsonOpts);
//   });
//
// `air` selects the SEA/AIR variant of the port master (portmstr.module). Pass false if your app is sea-only.
// `kind` is one of: custsub | port | liner | service | incoterm. Table/column names match the Swivel fm3k* ERP -
// adjust the SQL strings if your source schema differs.
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace MasterLookupKit;

public static class MasterLookup
{
    // The client reads exact keys ("code"/"name"/"loc") - keep verbatim casing, no camelCase policy.
    public static readonly JsonSerializerOptions JsonOpts = new() { PropertyNamingPolicy = null };

    public sealed record Item(string code, string name, string? loc = null);

    // Incoterms 2020 - the fixed master for the incoterm lookup (there is NO incoterm table in the ERP).
    static readonly (string Code, string Name)[] Incoterms =
    {
        ("EXW", "Ex Works"), ("FCA", "Free Carrier"), ("FAS", "Free Alongside Ship"), ("FOB", "Free On Board"),
        ("CFR", "Cost and Freight"), ("CIF", "Cost, Insurance and Freight"), ("CPT", "Carriage Paid To"),
        ("CIP", "Carriage and Insurance Paid To"), ("DAP", "Delivered At Place"), ("DPU", "Delivered At Place Unloaded"),
        ("DDP", "Delivered Duty Paid"),
    };

    /// <summary>Search a master. `src` is an OPEN connection to the (read-only) source ERP db; the caller owns it.</summary>
    public static object Search(SqlConnection src, string? kind, string? term, bool isAir = false)
    {
        kind = (kind ?? "").Trim().ToLowerInvariant();
        term = (term ?? "").Trim();

        if (kind == "incoterm")
        {
            var ql = term.ToLowerInvariant();
            var res = Incoterms
                .Where(x => ql == "" || x.Code.ToLowerInvariant().Contains(ql) || x.Name.ToLowerInvariant().Contains(ql))
                .Select(x => new Item(x.Code, x.Name)).ToArray();
            return new { kind = "incoterm", results = res };
        }

        // escape LIKE metacharacters, then wrap in %...%
        var like = "%" + System.Text.RegularExpressions.Regex.Replace(term, @"[%_\[\]]", "") + "%";
        try
        {
            Item[] results = kind switch
            {
                // customer master
                "custsub" => Query(src,
                    "SELECT TOP 20 code2 code, doc_e_name name, city, country FROM dbo.custsub " +
                    "WHERE ISNULL(isdel,0)=0 AND NULLIF(code2,'') IS NOT NULL AND (code2 LIKE @q OR doc_e_name LIKE @q) ORDER BY code2",
                    like, withLoc: true),

                // liner / carrier master
                "liner" => Query(src,
                    "SELECT TOP 20 code, name FROM dbo.linermstr " +
                    "WHERE NULLIF(code,'') IS NOT NULL AND (code LIKE @q OR name LIKE @q) ORDER BY code",
                    like),

                // port master (SEA/AIR split by module; rows with no module match either)
                "port" => Query(src,
                    "SELECT TOP 20 code, port_ldes1 name FROM dbo.portmstr " +
                    "WHERE NULLIF(code,'') IS NOT NULL AND (NULLIF(module,'') IS NULL OR module=@m) AND (code LIKE @q OR port_ldes1 LIKE @q) ORDER BY code",
                    like, mod: isAir ? "AIR" : "SEA"),

                // service-type master
                "service" => Query(src,
                    "SELECT TOP 20 service code, desc1 name FROM dbo.servmstr " +
                    "WHERE NULLIF(service,'') IS NOT NULL AND (service LIKE @q OR desc1 LIKE @q) ORDER BY service",
                    like),

                _ => throw new ArgumentException($"unknown lookup kind '{kind}'"),
            };
            return new { kind, results };
        }
        catch (ArgumentException ex) { return new { error = ex.Message }; }
        catch (Exception ex) { return new { error = "master lookup failed: " + ex.Message }; }
    }

    // tiny raw-ADO reader so this file has zero dependency on the host app's data layer.
    static Item[] Query(SqlConnection src, string sql, string like, string? mod = null, bool withLoc = false)
    {
        using var cmd = src.CreateCommand();
        cmd.CommandText = sql;
        cmd.CommandTimeout = 8;                       // bound it - the source ERP is shared / over a VPN
        cmd.Parameters.AddWithValue("@q", like);
        if (mod != null) cmd.Parameters.AddWithValue("@m", mod);

        var list = new List<Item>();
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var code = Str(r, "code").Trim();
            var name = Str(r, "name").Trim();
            string? loc = null;
            if (withLoc)
            {
                var parts = new[] { Str(r, "city").Trim(), Str(r, "country").Trim() }.Where(s => s.Length > 0);
                var joined = string.Join(", ", parts);
                if (joined.Length > 0) loc = joined;
            }
            list.Add(new Item(code, name, loc));
        }
        return list.ToArray();
    }

    static string Str(SqlDataReader r, string col)
    {
        int i; try { i = r.GetOrdinal(col); } catch { return ""; }
        return r.IsDBNull(i) ? "" : (r.GetValue(i)?.ToString() ?? "");
    }
}
