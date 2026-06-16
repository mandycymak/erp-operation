using System.Collections.Concurrent;
using System.Globalization;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Doc
{
    // customer-master lookup (custsub): code -> "name\naddress" using the documentation English block, falling
    // back to the mailing block. '' when the code/table is absent. Mirrors Doc-CustLookup.
    static string CustLookup(SqlConnection src, string db, object? codeObj)
    {
        var code = (codeObj?.ToString() ?? "").Trim(); if (code == "") return "";
        var cols = Source.ErpCols(db, "custsub", "code,doc_e_name,doc_e_add1,doc_e_add2,doc_e_add3,doc_e_add4,doc_e_add5,mal_e_name,mal_e_add1,mal_e_add2,mal_e_add3,mal_e_add4,mal_e_add5");
        if (cols == "") return "";
        var r = Db.RunQ(src, $"SELECT TOP 1 {cols} FROM dbo.custsub WHERE code=@c", new Dictionary<string, object?> { ["c"] = code }, 8);
        if (r.Count == 0) return "";
        var b = r[0];
        var t = PartyText(Db.G(b, "doc_e_name"), Db.G(b, "doc_e_add1"), Db.G(b, "doc_e_add2"), Db.G(b, "doc_e_add3"), Db.G(b, "doc_e_add4"), Db.G(b, "doc_e_add5"));
        if (t == "") t = PartyText(Db.G(b, "mal_e_name"), Db.G(b, "mal_e_add1"), Db.G(b, "mal_e_add2"), Db.G(b, "mal_e_add3"), Db.G(b, "mal_e_add4"), Db.G(b, "mal_e_add5"));
        return t;
    }

    // Own issuing/forwarding office for a station = fm3kco.site dbname->owncode -> custsub, falling back to a
    // latest blhead agnt_* of the own office. Cached per db (stable per station; empty cached too). Mirrors
    // Get-OwnOfficeAgent.
    static readonly ConcurrentDictionary<string, string> _ownAgent = new();
    static string OwnOfficeAgent(SqlConnection src, string db) => _ownAgent.GetOrAdd(db, _ =>
    {
        var own = "";
        try
        {
            var oc = Db.RunQ(src, "SELECT TOP 1 owncode FROM fm3kco.dbo.site WHERE dbname=@d", new Dictionary<string, object?> { ["d"] = db }, 8);
            if (oc.Count > 0 && Db.Str(Db.G(oc[0], "owncode")).Trim() != "")
            {
                var ocv = Db.Str(Db.G(oc[0], "owncode")).Trim();
                own = CustLookup(src, db, ocv);
                if (own == "")
                {
                    var ob = Db.RunQ(src, "SELECT TOP 1 agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5 FROM dbo.blhead WHERE agn2_code=@c AND LTRIM(RTRIM(ISNULL(agnt_name,'')))<>'' ORDER BY ref DESC", new Dictionary<string, object?> { ["c"] = ocv }, 8);
                    if (ob.Count > 0) own = PartyText(Db.G(ob[0], "agnt_name"), Db.G(ob[0], "agnt_add1"), Db.G(ob[0], "agnt_add2"), Db.G(ob[0], "agnt_add3"), Db.G(ob[0], "agnt_add4"), Db.G(ob[0], "agnt_add5"));
                }
            }
        }
        catch { }
        return own;
    });

    // Best-effort ERP enrichment at DRAFT-CREATION time only (staff click). Bounded keyed seek (Connect Timeout=15,
    // CommandTimeout=8). Mutates f in place; returns '' on success or a note string. A missing column throws the one
    // keyed SELECT and the outer catch degrades to the snapshot seed. Mirrors Doc-ErpSeed.
    public static string ErpSeed(Row a, Dictionary<string, object?> f)
    {
        var db = Source.DbFor(Db.Str(Db.G(a, "station")));
        if (db == null) return $"no ERP database mapped for station {Db.Str(Db.G(a, "station"))}";
        var key = Db.Str(Db.G(a, "erp_ref")).Trim();
        if (key == "") return "no erp_ref on the snapshot";
        var isAir = Db.Str(Db.G(a, "mode")) == "Air";

        SqlConnection? src = null;
        try
        {
            src = Source.Open(db);
            if (isAir) ErpSeedAir(src, db, key, f);
            else ErpSeedSea(src, db, key, a, f);
            return "";
        }
        catch (Exception ex) { return "ERP enrichment skipped: " + ex.Message; }
        finally { try { src?.Close(); } catch { } }
    }

    static string T(Row b, string c) => Db.Str(Db.G(b, c)).Trim();
    static string DateIso(object? v) { if (v is DateTime dt) return dt.ToString("yyyy-MM-dd"); if (v != null && DateTime.TryParse(v.ToString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) return d.ToString("yyyy-MM-dd"); return ""; }

    static void ErpSeedAir(SqlConnection src, string db, string key, Dictionary<string, object?> f)
    {
        var cols = Source.ErpCols(db, "awbhead", "pol_name,pod_name,pod,dest,dest_name,to1,to1_name,deli,deli_name,to3,to3_name,flight1,flight2,flight3,f_date1,f_date2,f_date3,carr,iatacode,currency,frt_terms,oth_terms,v_carriage,v_customs,v_insurance,t_book_qty,t_rece_qty,t_book_wgt,ttl_cwt,wgt_unit,not_show_dim,commodity,handling,special_remark,shpr_name,shpr_add1,shpr_add2,shpr_add3,shpr_add4,shpr_add5,cgne_name,cgne_add1,cgne_add2,cgne_add3,cgne_add4,cgne_add5,agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5,not1_name,not1_add1,not1_add2,not1_add3,not1_add4,not1_add5,issu_at", "special_remark", "commodity", "handling");
        Row? b = null;
        var hdr = cols != "" ? Db.RunQ(src, $"SELECT TOP 1 {cols} FROM dbo.awbhead WHERE ref=@k", new Dictionary<string, object?> { ["k"] = key }, 8) : new List<Row>();
        if (hdr.Count > 0)
        {
            b = hdr[0];
            if (T(b, "pol_name") != "") f["airport_departure"] = T(b, "pol_name");
            var adest = T(b, "dest_name"); if (adest == "") adest = T(b, "pod_name");
            if (adest != "") f["airport_destination"] = adest;
            var stx = PartyText(Db.G(b, "shpr_name"), Db.G(b, "shpr_add1"), Db.G(b, "shpr_add2"), Db.G(b, "shpr_add3"), Db.G(b, "shpr_add4"), Db.G(b, "shpr_add5")); if (stx != "") f["shipper"] = stx;
            var ctx = PartyText(Db.G(b, "cgne_name"), Db.G(b, "cgne_add1"), Db.G(b, "cgne_add2"), Db.G(b, "cgne_add3"), Db.G(b, "cgne_add4"), Db.G(b, "cgne_add5")); if (ctx != "") f["consignee"] = ctx;
            var atx = PartyText(Db.G(b, "agnt_name"), Db.G(b, "agnt_add1"), Db.G(b, "agnt_add2"), Db.G(b, "agnt_add3"), Db.G(b, "agnt_add4"), Db.G(b, "agnt_add5"));
            if (T(b, "issu_at") != "") f["executed_place"] = T(b, "issu_at");
            var ntx = PartyText(Db.G(b, "not1_name"), Db.G(b, "not1_add1"), Db.G(b, "not1_add2"), Db.G(b, "not1_add3"), Db.G(b, "not1_add4"), Db.G(b, "not1_add5")); if (ntx != "") f["notify"] = ntx;
            var ftv = T(b, "frt_terms").ToUpperInvariant();
            var acc = new List<string>(); if (ftv != "") acc.Add(ftv == "PP" ? "FREIGHT PREPAID" : "FREIGHT COLLECT");
            if (atx != "") { if (acc.Count > 0) acc.Add(""); acc.Add("DESTINATION AGENT:"); acc.Add(atx); }
            if (acc.Count > 0) f["accounting_info"] = string.Join("\n", acc);
            if (T(b, "iatacode") != "") f["agent_iata_code"] = T(b, "iatacode");
            if (T(b, "currency") != "") f["currency"] = T(b, "currency");
            if (ftv != "") { f["chgs_code"] = ftv; if (ftv == "PP") f["wtval_ppd"] = "X"; else f["wtval_coll"] = "X"; }
            var otv = T(b, "oth_terms").ToUpperInvariant();
            if (otv == "PP") f["other_ppd"] = "X"; else if (otv != "") f["other_coll"] = "X";
            if (T(b, "v_carriage") != "") f["declared_value_carriage"] = T(b, "v_carriage");
            if (T(b, "v_customs") != "") f["declared_value_customs"] = T(b, "v_customs");
            var vi = T(b, "v_insurance"); f["amount_of_insurance"] = (vi != "" && vi != "0") ? vi : "NIL";
            var to1 = T(b, "to1"); if (to1 == "") to1 = T(b, "pod"); if (to1 != "") f["routing_to1"] = to1;
            var deliC = T(b, "deli"); if (deliC != "" && deliC.ToUpperInvariant() is not ("NUL" or "NULL")) f["routing_to2"] = deliC;
            var to3 = T(b, "to3"); if (to3 != "" && to3.ToUpperInvariant() is not ("NUL" or "NULL")) f["routing_to3"] = to3;
            var carr1 = T(b, "carr"); if (carr1 == "") carr1 = AwbCarrierFromFlight(Db.G(b, "flight1")); if (carr1 != "") f["routing_by1"] = carr1;
            var c2 = AwbCarrierFromFlight(Db.G(b, "flight2")); if (c2 != "") f["routing_by2"] = c2;
            var c3 = AwbCarrierFromFlight(Db.G(b, "flight3")); if (c3 != "") f["routing_by3"] = c3;
            var fld = new List<string>();
            foreach (var (fn0, dt0) in new[] { (Db.G(b, "flight1"), Db.G(b, "f_date1")), (Db.G(b, "flight2"), Db.G(b, "f_date2")), (Db.G(b, "flight3"), Db.G(b, "f_date3")) })
            {
                var fn = (fn0?.ToString() ?? "").Trim(); if (fn == "") continue;
                var dt = DateIso(dt0);
                fld.Add(dt != "" ? $"{fn} / {dt}" : fn);
            }
            if (fld.Count > 0) f["flight_date"] = string.Join("\n", fld);
            var pcs = T(b, "t_book_qty"); if (pcs == "" || pcs == "0") pcs = T(b, "t_rece_qty");
            if (pcs != "" && pcs != "0") f["pieces"] = pcs;
            if (T(b, "t_book_wgt") != "") f["gross_weight"] = T(b, "t_book_wgt");
            if (T(b, "ttl_cwt") != "") f["chargeable_weight"] = T(b, "ttl_cwt");
            var wu = T(b, "wgt_unit").ToUpperInvariant(); if (wu != "") f["kg_lb"] = wu.Substring(0, 1);
            var hand = T(b, "handling"); if (hand == "") hand = T(b, "special_remark"); if (hand != "") f["handling_info"] = hand;
            var own = OwnOfficeAgent(src, db); if (own != "") f["issuing_carrier_agent"] = own;
        }
        // line items: marks = mark2; goods = full desc2 (good_desc2 = short summary); dimensions unless suppressed
        var items = Db.RunQ(src, "SELECT TOP 20 item_seq, CONVERT(nvarchar(2000),mark2) AS mk, CONVERT(nvarchar(2000),desc2) AS d2, CONVERT(nvarchar(2000),good_desc2) AS gd2, CONVERT(nvarchar(400),dimension) AS dim FROM dbo.awbdetl WHERE blh=@r ORDER BY item_seq", new Dictionary<string, object?> { ["r"] = key }, 8);
        var marks = new List<string>(); var goods = new List<string>(); var dims = new List<string>();
        foreach (var it in items)
        {
            var mv = T(it, "mk"); if (mv != "" && !marks.Contains(mv)) marks.Add(mv);
            var gv = T(it, "d2"); if (gv == "") gv = T(it, "gd2"); if (gv != "" && !goods.Contains(gv)) goods.Add(gv);
            var dv = T(it, "dim"); if (dv != "" && !dims.Contains(dv)) dims.Add(dv);
        }
        if (marks.Count > 0) f["marks_numbers"] = string.Join("\n", marks);
        if (goods.Count == 0 && b != null && T(b, "commodity") != "") goods.Add(T(b, "commodity"));
        if (goods.Count > 0) f["nature_quantity_goods"] = string.Join("\n", goods);
        var showDim = true; if (b != null) { try { showDim = !Truthy(Db.G(b, "not_show_dim")); } catch { } }
        if (showDim && dims.Count > 0) f["dimensions"] = string.Join("\n", dims);
    }

    static void ErpSeedSea(SqlConnection src, string db, string key, Row a, Dictionary<string, object?> f)
    {
        var cols = Source.ErpCols(db, "blhead", "pol_name,pod_name,deli_name,dest_name,t_book_qty,t_book_wgt,t_book_cbm,no_orig,telex_rel,frt_terms,shpr_name,shpr_add1,shpr_add2,shpr_add3,shpr_add4,shpr_add5,cgne_name,cgne_add1,cgne_add2,cgne_add3,cgne_add4,cgne_add5,not1_name,not1_add1,not1_add2,not1_add3,not1_add4,not1_add5,carr_name,rece_name,issu_at,payable_at,agn2_code,agnt_name,agnt_add1,agnt_add2,agnt_add3,agnt_add4,agnt_add5");
        var hdr = cols != "" ? Db.RunQ(src, $"SELECT TOP 1 {cols} FROM dbo.blhead WHERE ref=@k", new Dictionary<string, object?> { ["k"] = key }, 8) : new List<Row>();
        if (hdr.Count > 0)
        {
            var b = hdr[0];
            if (T(b, "pol_name") != "") f["port_of_loading"] = T(b, "pol_name");
            if (T(b, "pod_name") != "") f["port_of_discharge"] = T(b, "pod_name");
            if (T(b, "deli_name") != "") f["place_of_delivery"] = T(b, "deli_name");
            if (T(b, "dest_name") != "") f["final_destination"] = T(b, "dest_name");
            if (T(b, "t_book_qty") != "") f["num_pkgs"] = T(b, "t_book_qty");
            if (T(b, "t_book_wgt") != "") f["gross_weight"] = T(b, "t_book_wgt") + " KGS";
            if (T(b, "t_book_cbm") != "") f["measurement"] = T(b, "t_book_cbm") + " CBM";
            var telex = false; try { telex = Truthy(Db.G(b, "telex_rel")); } catch { }
            if (telex) f["num_originals"] = "0";
            else if (T(b, "no_orig") != "") f["num_originals"] = T(b, "no_orig");
            var ftv = T(b, "frt_terms").ToUpperInvariant();
            if (ftv != "")
            {
                var ft = ftv == "PP" ? "FREIGHT PREPAID" : "FREIGHT COLLECT";
                var inco = Db.Str(Db.G(a, "incoterm")).Trim();
                f["freight_terms"] = inco != "" ? $"{ft} ({inco})" : ft;
            }
            var stx = PartyText(Db.G(b, "shpr_name"), Db.G(b, "shpr_add1"), Db.G(b, "shpr_add2"), Db.G(b, "shpr_add3"), Db.G(b, "shpr_add4"), Db.G(b, "shpr_add5")); if (stx != "") f["shipper"] = stx;
            var ctx = PartyText(Db.G(b, "cgne_name"), Db.G(b, "cgne_add1"), Db.G(b, "cgne_add2"), Db.G(b, "cgne_add3"), Db.G(b, "cgne_add4"), Db.G(b, "cgne_add5")); if (ctx != "") f["consignee"] = ctx;
            var ntx = PartyText(Db.G(b, "not1_name"), Db.G(b, "not1_add1"), Db.G(b, "not1_add2"), Db.G(b, "not1_add3"), Db.G(b, "not1_add4"), Db.G(b, "not1_add5")); if (ntx != "") f["notify"] = ntx;
            if (T(b, "carr_name") != "") f["precarriage_by"] = T(b, "carr_name");
            if (T(b, "rece_name") != "") f["place_of_receipt"] = T(b, "rece_name");
            if (T(b, "issu_at") != "") f["place_of_issue"] = T(b, "issu_at");
            if (T(b, "payable_at") != "") f["freight_payable_at"] = T(b, "payable_at");
            var datx = PartyText(Db.G(b, "agnt_name"), Db.G(b, "agnt_add1"), Db.G(b, "agnt_add2"), Db.G(b, "agnt_add3"), Db.G(b, "agnt_add4"), Db.G(b, "agnt_add5"));
            if (datx == "") datx = CustLookup(src, db, Db.G(b, "agn2_code"));
            if (datx != "") f["delivery_agent"] = datx;
        }
        var own = OwnOfficeAgent(src, db); if (own != "") f["forwarding_agent"] = own;
        // marks + description from the ntext pair mark2/desc2 (mark3/desc3 = continuation); overflow -> rider page 1
        var icols = Source.ErpCols(db, "blitem", "item_seq,good_desc1,mark2,desc2,mark3,desc3", "mark2", "desc2", "mark3", "desc3");
        var items = icols != "" ? Db.RunQ(src, $"SELECT TOP 10 {icols} FROM dbo.blitem WHERE blh=@r ORDER BY item_seq", new Dictionary<string, object?> { ["r"] = key }, 8) : new List<Row>();
        var marks = new List<string>(); var descs = new List<string>();
        foreach (var it in items)
        {
            var mv = (T(it, "mark2") + "\n" + T(it, "mark3")).Trim(); if (mv != "" && !marks.Contains(mv)) marks.Add(mv);
            var dv = T(it, "good_desc1"); if (dv == "") dv = T(it, "desc2");
            var d3 = T(it, "desc3"); if (d3 != "") dv = (dv + "\n" + d3).Trim();
            if (dv != "" && !descs.Contains(dv)) descs.Add(dv);
        }
        var mtx = string.Join("\n", marks); var dtx = string.Join("\n", descs);
        int mMax = 1000, dMax = 2000;
        foreach (var dd in DocFields.Defs("HBL")) { if (dd.Code == "marks_numbers" && dd.MaxLen > 0) mMax = dd.MaxLen; if (dd.Code == "description" && dd.MaxLen > 0) dMax = dd.MaxLen; }
        if ((mtx != "" && mtx.Length > mMax) || (dtx != "" && dtx.Length > dMax))
        {
            var pg = new Dictionary<string, object?>();
            if (mtx != "") pg["marks"] = mtx;
            if (dtx != "") pg["description"] = dtx;
            f["marks_numbers"] = "";
            f["description"] = "AS PER ATTACHED SHEET";
            f["rider_pages"] = new List<Dictionary<string, object?>> { pg };
        }
        else
        {
            if (mtx != "") f["marks_numbers"] = mtx;
            if (dtx != "") f["description"] = dtx;
        }
        // structured container particulars (table field 'containers'); columns guarded per station schema
        var ccols = Source.ErpCols(db, "blcont", "container,seal,cont_type,load_qty,pkgs_unit,load_wgt,load_cbm");
        var cont = ccols != "" ? Db.RunQ(src, $"SELECT TOP 50 {ccols} FROM dbo.blcont WHERE blh=@r ORDER BY container", new Dictionary<string, object?> { ["r"] = key }, 8) : new List<Row>();
        var crows = new List<Dictionary<string, object?>>();
        foreach (var cr in cont)
        {
            var rd = new Dictionary<string, object?>
            {
                ["container_no"] = T(cr, "container"), ["seal_no"] = T(cr, "seal"), ["cont_type"] = T(cr, "cont_type"),
                ["qty"] = T(cr, "load_qty"), ["qty_unit"] = T(cr, "pkgs_unit"), ["weight_kgs"] = T(cr, "load_wgt"), ["cbm"] = T(cr, "load_cbm"),
            };
            if (rd.Values.Any(v => (v as string ?? "") != "")) crows.Add(rd);
        }
        if (crows.Count > 0) f["containers"] = crows;
    }

    static bool Truthy(object? v) => v switch
    {
        null => false,
        bool b => b,
        sbyte or byte or short or int or long => Convert.ToInt64(v) != 0,
        float or double or decimal => Convert.ToDouble(v) != 0,
        string s => s.Trim() is "1" or "true" or "True" or "Y" or "y",
        _ => false,
    };
}
