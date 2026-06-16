using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// Pure route/cargo builders ported from ops-eval.ps1 (the dot-sourced helper library). No DB calls — callers
// pass an ERP header row. Used by the /api-ops/erp-detail deep-dive (Stage 4).
public static class OpsEval
{
    // _RS: string-or-null (trim; null if empty). _RD: date -> yyyy-MM-dd or null. _RN: number rounded 2 or null.
    public static string? RS(object? x) { var s = (x?.ToString() ?? "").Trim(); return s == "" ? null : s; }
    public static string? RD(object? x)
    {
        if (x == null) return null;
        if (x is DateTime dt) return dt.ToString("yyyy-MM-dd");
        var s = x.ToString() ?? "";
        if (s == "") return null;
        return DateTime.TryParse(s, out var d) ? d.ToString("yyyy-MM-dd") : null;
    }
    public static double? RN(object? x)
    {
        if (x == null) return null;
        var s = x.ToString() ?? ""; if (s == "") return null;
        try { return Math.Round(Convert.ToDouble(x), 2); } catch { return null; }
    }

    static object? G(Row b, string k) => b.TryGetValue(k, out var v) ? v : null;

    static Dictionary<string, object?> Pt(string role, string? code, string? name,
        string? dep = null, string? time = null, string? arr = null, string? flight = null, string? vessel = null)
    {
        var d = new Dictionary<string, object?> { ["role"] = role, ["code"] = code, ["name"] = name };
        if (dep != null) d["dep"] = dep;
        if (time != null) d["time"] = time;
        if (arr != null) d["arr"] = arr;
        if (flight != null) d["flight"] = flight;
        if (vessel != null) d["vessel"] = vessel;
        return d;
    }

    // drop blank codes; merge consecutive duplicates (later non-null fills the kept one; role always overwrites);
    // strip null-valued keys so the stored JSON stays compact.
    static readonly string[] _keys = { "role", "code", "name", "dep", "time", "arr", "flight", "vessel" };
    static List<Dictionary<string, object?>> RoutePack(IEnumerable<Dictionary<string, object?>> pts)
    {
        var outl = new List<Dictionary<string, object?>>();
        foreach (var p in pts)
        {
            var code = p.TryGetValue("code", out var cv) ? cv as string : null;
            if (string.IsNullOrEmpty(code)) continue;
            var prev = outl.Count > 0 ? outl[^1] : null;
            if (prev != null && (prev.TryGetValue("code", out var pc) ? pc as string : null) == code)
            {
                foreach (var k in _keys)
                    if (p.TryGetValue(k, out var v) && v != null)
                    {
                        var prevHas = prev.TryGetValue(k, out var pv) && pv != null;
                        if (!prevHas || k == "role") prev[k] = v;
                    }
                continue;
            }
            var q = new Dictionary<string, object?>();
            foreach (var k in _keys) if (p.TryGetValue(k, out var v) && v != null) q[k] = v;
            outl.Add(q);
        }
        return outl;
    }

    // Sea: Export rides leg-2 (departure2/arrival2/arrival2d/arrival3); Import rides leg-1. vesselDisplay = the
    // resolved "NAME / VOY" from the caller (falls back to raw vessel_2/voyage_2 or _1).
    public static List<Dictionary<string, object?>> SeaRoutePoints(Row b, string bound, string? vesselDisplay)
    {
        var exp = bound == "Export";
        var vsl = RS(vesselDisplay);
        if (vsl == null)
        {
            var vc = exp ? RS(G(b, "vessel_2")) : RS(G(b, "vessel_1"));
            var vy = exp ? RS(G(b, "voyage_2")) : RS(G(b, "voyage_1"));
            if (vc != null) vsl = string.Join(" / ", new[] { vc, vy }.Where(x => !string.IsNullOrEmpty(x)));
        }
        var pts = new[]
        {
            Pt("POL", RS(G(b,"pol")),  RS(G(b,"pol_name")),  dep: RD(G(b, exp?"departure2":"departure1")), vessel: vsl),
            Pt("POD", RS(G(b,"pod")),  RS(G(b,"pod_name")),  arr: RD(G(b, exp?"arrival2":"arrival1"))),
            Pt("DELI",RS(G(b,"deli")), RS(G(b,"deli_name")), arr: RD(G(b, exp?"arrival2d":"arrival1d"))),
            Pt("DEST",RS(G(b,"dest")), RS(G(b,"dest_name")), arr: RD(G(b,"arrival3"))),
        };
        return RoutePack(pts);
    }

    // Air: stops pol -> to1 -> deli -> to3/dest; flightN/f_dateN/f_timeN depart the (N-1)th point.
    public static List<Dictionary<string, object?>> AirRoutePoints(Row b)
    {
        var to3 = RS(G(b, "to3")); var dest = RS(G(b, "dest"));
        var destCode = to3 ?? dest ?? RS(G(b, "pod"));
        var destName = to3 != null ? RS(G(b, "to3_name")) : dest != null ? RS(G(b, "dest_name")) : RS(G(b, "pod_name"));
        var rawDestArr = RS(G(b, "fa_date3")) != null ? G(b, "fa_date3") : G(b, "ata_date");
        var pts = new[]
        {
            Pt("POL", RS(G(b,"pol")),  RS(G(b,"pol_name")),  flight: RS(G(b,"flight1")), dep: RD(G(b,"f_date1")), time: RS(G(b,"f_time1"))),
            Pt("VIA", RS(G(b,"to1")),  RS(G(b,"to1_name")),  arr: RD(G(b,"fa_date1")), flight: RS(G(b,"flight2")), dep: RD(G(b,"f_date2")), time: RS(G(b,"f_time2"))),
            Pt("VIA", RS(G(b,"deli")), RS(G(b,"deli_name")), arr: RD(G(b,"fa_date2")), flight: RS(G(b,"flight3")), dep: RD(G(b,"f_date3")), time: RS(G(b,"f_time3"))),
            Pt("DEST",destCode, destName, arr: RD(rawDestArr)),
        };
        return RoutePack(pts);
    }

    // Booked-vs-received cargo block: {book:{qty,wgt,cbm,cwt}, rece:{...}} (nulls dropped).
    public static Dictionary<string, object?> CargoBlock(Row b, string mode)
    {
        Dictionary<string, object?> Pack(params (string k, object? v)[] pairs)
        {
            var h = new Dictionary<string, object?>();
            foreach (var (k, v) in pairs) { var n = RN(v); if (n != null) h[k] = n; }
            return h;
        }
        var book = Pack(("qty", G(b, "t_book_qty")), ("wgt", G(b, "t_book_wgt")), ("cbm", G(b, "t_book_cbm")), ("cwt", G(b, "t_book_cwt")));
        var rece = Pack(("qty", G(b, "t_rece_qty")), ("wgt", G(b, "t_rece_wgt")), ("cbm", G(b, "t_rece_cbm")), ("cwt", G(b, "ttl_cwt")));
        var outd = new Dictionary<string, object?>();
        if (book.Count > 0) outd["book"] = book;
        if (rece.Count > 0) outd["rece"] = rece;
        return outd;
    }
}
