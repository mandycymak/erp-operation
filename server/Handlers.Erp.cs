using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    const string SeaDetailCols = "jobn,ref,blno,mobl,bound,routing,pol,pod,deli,dest,pol_name,pod_name,deli_name,dest_name,vessel_1,voyage_1,vessel_2,voyage_2,departure1,departure2,arrival1,arrival1d,arrival2,arrival2d,arrival3,available_date,eta_delivery,goods_delivery,cargoready,spotid,sono,t_book_qty,t_book_wgt,t_book_cbm,t_rece_qty,t_rece_wgt,t_rece_cbm,remark";
    const string AirDetailCols = "jobn,ref,hawb,mawb,bound,routing,booking,po_no,pol,pod,to1,to3,dest,deli,pol_name,pod_name,to1_name,to3_name,dest_name,deli_name,flight1,flight2,flight3,f_date1,f_date2,f_date3,f_time1,f_time2,f_time3,fa_date1,fa_date2,fa_date3,rout_by_1,atd_date,ata_date,cargoready,goods_delivery,t_book_qty,t_book_wgt,t_book_cwt,t_book_cbm,t_rece_qty,t_rece_cbm,ttl_cwt,remark,special_remark";

    // ---- /api-ops/erp-detail (serve-ops.ps1 680-720) ----
    // user-clicked deep-dive: one keyed header SELECT (PK ref / indexed jobn) + a TOP-10 child read on the
    // station ERP, bounded by Connect Timeout=15 / CommandTimeout=8. Display-only; nothing written back.
    public static object ErpDetail(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,erp_ref,vessel_voyage FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, al[0])) return new { error = "not found" };
        var a = al[0];
        var station = Db.Str(Db.G(a, "station"));
        var db = Source.DbFor(station);
        if (db == null) return new { error = $"station '{station}' has no ERP database mapped in config stations[]" };
        var isAir = Db.Str(Db.G(a, "mode")) == "Air";

        SqlConnection? src = null;
        try
        {
            src = Source.Open(db);
            var tbl = isAir ? "awbhead" : "blhead";
            var cols = Source.ErpCols(db, tbl, isAir ? AirDetailCols : SeaDetailCols, "remark", "special_remark");
            var key = Db.Str(Db.G(a, "erp_ref")).Trim();
            var hdr = key != ""
                ? Db.RunQ(src, $"SELECT TOP 1 {cols} FROM dbo.{tbl} WHERE ref=@k", new Dictionary<string, object?> { ["k"] = key }, 8)
                : Db.RunQ(src, $"SELECT TOP 1 {cols} FROM dbo.{tbl} WHERE jobn=@k ORDER BY ref DESC", new Dictionary<string, object?> { ["k"] = job }, 8);
            if (hdr.Count == 0) return new { error = $"shipment not found in the ERP (may have been archived) [{db}.{tbl} {(key != "" ? "ref=" + key : "jobn=" + job)}]" };
            var b = hdr[0];

            var itemTbl = isAir ? "awbdetl" : "blitem";
            var items = new List<Row>();
            try { items = Db.RunQ(src, $"SELECT TOP 10 item_seq, CONVERT(nvarchar(400),good_desc1) AS good_desc1, CONVERT(nvarchar(400),good_desc2) AS good_desc2 FROM dbo.{itemTbl} WHERE blh=@r ORDER BY item_seq", new Dictionary<string, object?> { ["r"] = Db.G(b, "ref") }, 8); } catch { }
            var descField = isAir ? "good_desc2" : "good_desc1";
            var descs = new List<string>();
            foreach (var it in items) { var dv = Db.Str(Db.G(it, descField)).Trim(); if (dv != "" && !descs.Contains(dv)) descs.Add(dv); }

            var boundRaw = Db.Str(Db.G(b, "bound"));
            var bound = boundRaw == "O" ? "Export" : boundRaw == "I" ? "Import" : Db.Str(Db.G(a, "bound"));
            var route = isAir ? OpsEval.AirRoutePoints(b) : OpsEval.SeaRoutePoints(b, bound, Db.Str(Db.G(a, "vessel_voyage")));
            var cargo = OpsEval.CargoBlock(b, isAir ? "Air" : "Sea");
            var remark = OpsEval.RS(Db.G(b, "remark"));
            var spec = isAir ? OpsEval.RS(Db.G(b, "special_remark")) : null;

            return new
            {
                jobNo = job,
                live = true,
                fetchedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm"),
                remark,
                specialRemark = spec,
                commodity = descs.Take(5).ToArray(),
                route,
                cargo,
                cargoReady = OpsEval.RD(Db.G(b, "cargoready")),
                availableDate = isAir ? null : OpsEval.RD(Db.G(b, "available_date")),
                etaDelivery = isAir ? null : OpsEval.RD(Db.G(b, "eta_delivery")),
                goodsDelivery = OpsEval.RD(Db.G(b, "goods_delivery")),
            };
        }
        catch (Exception ex) { return new { error = "ERP lookup failed: " + ex.Message }; }
        finally { try { src?.Close(); } catch { } }
    }

    // Incoterms 2020 — the fixed master for the incoterm lookup (there is NO incoterm table in the ERP; the code
    // lives free-text in blhead/awbhead.routing). Served by /api-ops/erp-master?kind=incoterm.
    static readonly (string Code, string Name)[] Incoterms =
    {
        ("EXW", "Ex Works"), ("FCA", "Free Carrier"), ("FAS", "Free Alongside Ship"), ("FOB", "Free On Board"),
        ("CFR", "Cost and Freight"), ("CIF", "Cost, Insurance and Freight"), ("CPT", "Carriage Paid To"),
        ("CIP", "Carriage and Insurance Paid To"), ("DAP", "Delivered At Place"), ("DPU", "Delivered At Place Unloaded"),
        ("DDP", "Delivered Duty Paid"),
    };

    // ---- /api-ops/erp-master (serve-ops.ps1 1011-1046) ----
    // master type-ahead so the operator can find the CORRECT code. Bounded live LIKE seek (TOP 20, 8s).
    public static object ErpMaster(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        var kind = (q["kind"] ?? "").Trim().ToLowerInvariant();
        var term = (q["q"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return new { error = "not found" };
        if (!Scope.TestJobScope(rs, al[0])) return new { error = "not found" };
        var a = al[0];
        var isAir = Db.Str(Db.G(a, "mode")) == "Air";

        if (kind == "incoterm") return new { kind = "incoterm", results = IncotermResults(term) };

        var station = Db.Str(Db.G(a, "station"));
        var db = Source.DbFor(station);
        if (db == null) return new { error = $"station '{station}' has no ERP database mapped" };

        SqlConnection? src = null;
        try
        {
            src = Source.Open(db);
            var (results, mErr) = MasterResults(src, kind, term, isAir);
            if (mErr != null) return new { error = mErr };
            return new { kind, results };
        }
        catch (Exception ex) { return new { error = "master lookup failed: " + ex.Message }; }
        finally { try { src?.Close(); } catch { } }
    }

    // Incoterms 2020 filtered to the term (no DB). Shared by /api-ops/erp-master + /api-ops/book-now-master.
    static object[] IncotermResults(string term)
    {
        var ql = term.ToLowerInvariant();
        return Incoterms.Where(x => ql == "" || x.Code.ToLowerInvariant().Contains(ql) || x.Name.ToLowerInvariant().Contains(ql))
                        .Select(x => (object)new { code = x.Code, name = x.Name }).ToArray();
    }

    // The bounded live LIKE seek over the source-ERP masters (custsub / liner / port / service). Shared by the
    // job-scoped editor lookup (ErpMaster) and the station-scoped Book Now lookup (BookNowMaster); the caller owns
    // the open source connection + auth/scope. Returns (results, null) or (empty, error) for an unknown kind.
    static (object[] Results, string? Error) MasterResults(SqlConnection src, string kind, string term, bool isAir)
    {
        var like = "%" + System.Text.RegularExpressions.Regex.Replace(term, @"[%_\[\]]", "") + "%";
        List<Row> rows;
        bool hasLoc = false;
        switch (kind)
        {
            case "custsub":
                rows = Db.RunQ(src, "SELECT TOP 20 code2 code, doc_e_name name, city, country FROM dbo.custsub WHERE ISNULL(isdel,0)=0 AND NULLIF(code2,'') IS NOT NULL AND (code2 LIKE @q OR doc_e_name LIKE @q) ORDER BY code2", new Dictionary<string, object?> { ["q"] = like }, 8); hasLoc = true; break;
            case "liner":
                rows = Db.RunQ(src, "SELECT TOP 20 code, name FROM dbo.linermstr WHERE NULLIF(code,'') IS NOT NULL AND (code LIKE @q OR name LIKE @q) ORDER BY code", new Dictionary<string, object?> { ["q"] = like }, 8); break;
            case "port":
                rows = Db.RunQ(src, "SELECT TOP 20 code, port_ldes1 name FROM dbo.portmstr WHERE NULLIF(code,'') IS NOT NULL AND (NULLIF(module,'') IS NULL OR module=@m) AND (code LIKE @q OR port_ldes1 LIKE @q) ORDER BY code", new Dictionary<string, object?> { ["q"] = like, ["m"] = isAir ? "AIR" : "SEA" }, 8); break;
            case "service":
                rows = Db.RunQ(src, "SELECT TOP 20 service code, desc1 name FROM dbo.servmstr WHERE NULLIF(service,'') IS NOT NULL AND (service LIKE @q OR desc1 LIKE @q) ORDER BY service", new Dictionary<string, object?> { ["q"] = like }, 8); break;
            default: return (Array.Empty<object>(), $"unknown lookup kind '{kind}'");
        }
        var results = rows.Select(r =>
        {
            var o = new Dictionary<string, object?> { ["code"] = Db.Str(Db.G(r, "code")).Trim(), ["name"] = Db.Str(Db.G(r, "name")).Trim() };
            if (hasLoc)
            {
                var loc = string.Join(", ", new[] { Db.Str(Db.G(r, "city")).Trim(), Db.Str(Db.G(r, "country")).Trim() }.Where(x => x != ""));
                if (loc != "") o["loc"] = loc;
            }
            return (object)o;
        }).ToArray();
        return (results, null);
    }
}
