using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    static readonly Regex _baseRange = new(@"^(.+?)(\d+)\.\.(\d+)$", RegexOptions.Compiled);

    // The seed result reused by both the editor (GET /api-ops/erp-edit) and the save path (POST erp-edit-save).
    // Fields values are either a string or a List<Dictionary<string,object?>> (kind=table). The save path re-reads
    // this live so the 'before' baseline is always the authoritative ERP state, never a client-sent value.
    public sealed record SeedResult(string JobNo, string Mode, string Bound, string ModeKey, bool IsAir,
        string Station, string Db, string ErpRef, Dictionary<string, object?> Fields,
        Dictionary<string, string> Resolved, string OwnCode);

    // numeric column -> clean string (drop trailing .000 so "150.000"->"150", "2.500"->"2.5"); blank for null.
    static string NumStr(object? v)
    {
        if (v == null) return "";
        var s = v.ToString()!.Trim();
        if (Regex.IsMatch(s, @"^-?\d+(\.\d+)?$")) { s = Regex.Replace(s, @"(\.\d*?)0+$", "$1"); s = Regex.Replace(s, @"\.$", ""); }
        return s;
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

    // single keyed master-name lookup for a code (used to label the current code in the seed).
    static string MasterName(SqlConnection src, string db, string kind, string code)
    {
        code = code.Trim(); if (code == "") return "";
        try
        {
            switch (kind)
            {
                case "custsub":
                    var c = Db.RunQ(src, "SELECT TOP 1 doc_e_name,mal_e_name,city,country FROM dbo.custsub WHERE code2=@c AND ISNULL(isdel,0)=0", new Dictionary<string, object?> { ["c"] = code }, 8);
                    if (c.Count > 0)
                    {
                        var n = Db.Str(Db.G(c[0], "doc_e_name")).Trim(); if (n == "") n = Db.Str(Db.G(c[0], "mal_e_name")).Trim();
                        var loc = string.Join(", ", new[] { Db.Str(Db.G(c[0], "city")).Trim(), Db.Str(Db.G(c[0], "country")).Trim() }.Where(x => x != ""));
                        return loc != "" ? $"{n} - {loc}" : n;
                    }
                    break;
                case "liner":
                    var l = Db.RunQ(src, "SELECT TOP 1 name FROM dbo.linermstr WHERE code=@c", new Dictionary<string, object?> { ["c"] = code }, 8);
                    if (l.Count > 0) return Db.Str(Db.G(l[0], "name")).Trim();
                    break;
                case "port":
                    var p = Db.RunQ(src, "SELECT TOP 1 port_ldes1 FROM dbo.portmstr WHERE code=@c", new Dictionary<string, object?> { ["c"] = code }, 8);
                    if (p.Count > 0) return Db.Str(Db.G(p[0], "port_ldes1")).Trim();
                    break;
                case "service":
                    var s = Db.RunQ(src, "SELECT TOP 1 desc1 FROM dbo.servmstr WHERE service=@c", new Dictionary<string, object?> { ["c"] = code }, 8);
                    if (s.Count > 0) return Db.Str(Db.G(s[0], "desc1")).Trim();
                    break;
            }
        }
        catch { }
        return "";
    }

    static string DateStr(object? v) => v is DateTime dt ? dt.ToString("yyyy-MM-dd") : "";

    // ---- /api-ops/erp-edit (serve-ops.ps1 Handle-ErpEditSeed 881-1008) ----
    // seed the editor: current ERP value + resolved master name for every dict field on this shipment.
    public static object ErpEditSeed(SqlConnection cn, Qs q, ReqState rs)
    {
        var job = (q["job"] ?? "").Trim();
        if (job == "") return new { error = "job required" };
        var (seed, err) = ErpEditSeedCore(cn, job, rs);
        if (err != null) return err;
        return new { jobNo = seed!.JobNo, mode = seed.Mode, bound = seed.Bound, dict = ErpEditFields.Raw(seed.ModeKey), fields = seed.Fields, resolved = seed.Resolved, ownCode = seed.OwnCode };
    }

    // The seed itself (no HTTP projection). Returns (SeedResult, null) on success or (null, {error}) on failure,
    // so both the GET editor and the POST save path can consume it.
    static (SeedResult? Seed, object? Err) ErpEditSeedCore(SqlConnection cn, string job, ReqState rs)
    {
        var al = Db.RunQ(cn, "SELECT TOP 1 job_no,station,mode,bound,erp_ref,sono FROM dbo.shipment_alerts WHERE job_no=@j", new Dictionary<string, object?> { ["j"] = job });
        if (al.Count == 0) return (null, new { error = "not found" });
        if (!Scope.TestJobScope(rs, al[0])) return (null, new { error = "not found" });
        var a = al[0];
        var isAir = Db.Str(Db.G(a, "mode")) == "Air";
        var modeKey = isAir ? "AIR" : "SEA";
        var station = Db.Str(Db.G(a, "station"));
        var db = Source.DbFor(station);
        if (db == null) return (null, new { error = $"station '{station}' has no ERP database mapped in config stations[]" });
        var defs = ErpEditFields.Defs(modeKey);

        // column set to read from the header (skip the container table; expand 'base1..5' into the 5 cols)
        var cols = new List<string> { "ref" };
        foreach (var d in defs)
        {
            if (d.Kind == "table") continue;
            var rf = d.ReadFrom.Trim(); if (rf == "") continue;
            var m = _baseRange.Match(rf);
            if (m.Success) { var pre = m.Groups[1].Value; for (int i = int.Parse(m.Groups[2].Value); i <= int.Parse(m.Groups[3].Value); i++) cols.Add(pre + i); }
            else cols.Add(rf);
        }
        if (isAir) cols.Add("f_date1");
        else cols.AddRange(new[] { "departure1", "departure2", "arrival1", "arrival2", "vessel_1", "vessel_2", "voyage_1", "voyage_2", "deli" });
        var csv = string.Join(",", cols.Distinct());

        SqlConnection? src = null;
        try
        {
            src = Source.Open(db);
            var ownCode = Source.OwnCode(src, db);
            var tbl = isAir ? "awbhead" : "blhead";
            var key = Db.Str(Db.G(a, "erp_ref")).Trim();
            var hdr = key != ""
                ? Db.RunQ(src, $"SELECT TOP 1 {csv} FROM dbo.{tbl} WHERE ref=@k", new Dictionary<string, object?> { ["k"] = key }, 8)
                : Db.RunQ(src, $"SELECT TOP 1 {csv} FROM dbo.{tbl} WHERE jobn=@k ORDER BY ref DESC", new Dictionary<string, object?> { ["k"] = job }, 8);
            if (hdr.Count == 0) return (null, new { error = $"shipment not found in the ERP [{db}.{tbl} {(key != "" ? "ref=" + key : "jobn=" + job)}]" });
            var b = hdr[0];

            var fields = new Dictionary<string, object?>();
            var resolved = new Dictionary<string, string>();
            foreach (var d in defs)
            {
                var code = d.Code;
                if (d.Kind == "table")
                {
                    var clist = new List<Dictionary<string, object?>>();
                    try
                    {
                        var crows = Db.RunQ(src, "SELECT container,cont_type,seal,load_qty,pkgs_unit,load_wgt,load_cbm FROM dbo.blcont WHERE blh=@r ORDER BY ref", new Dictionary<string, object?> { ["r"] = Db.G(b, "ref") }, 8);
                        foreach (var cr in crows)
                            clist.Add(new Dictionary<string, object?>
                            {
                                ["container_no"] = Db.Str(Db.G(cr, "container")).Trim(), ["cont_type"] = Db.Str(Db.G(cr, "cont_type")).Trim(),
                                ["seal_no"] = Db.Str(Db.G(cr, "seal")).Trim(), ["qty"] = NumStr(Db.G(cr, "load_qty")), ["qty_unit"] = Db.Str(Db.G(cr, "pkgs_unit")).Trim(),
                                ["weight"] = NumStr(Db.G(cr, "load_wgt")), ["cbm"] = NumStr(Db.G(cr, "load_cbm")),
                            });
                    }
                    catch { }
                    fields[code] = clist;
                    continue;
                }
                var rf2 = d.ReadFrom.Trim();
                var m = _baseRange.Match(rf2);
                if (m.Success)
                {
                    var pre = m.Groups[1].Value; var parts = new List<string>();
                    for (int i = int.Parse(m.Groups[2].Value); i <= int.Parse(m.Groups[3].Value); i++) { var v = Db.Str(Db.G(b, pre + i)).Trim(); if (v != "" && !parts.Contains(v)) parts.Add(v); }
                    fields[code] = string.Join("\n", parts);
                }
                else if (rf2 == "") fields[code] = "";
                else if (d.Kind == "bool") fields[code] = Truthy(Db.G(b, rf2)) ? "true" : "false";
                else if (d.Kind == "date") fields[code] = DateStr(Db.G(b, rf2));
                else if (d.Kind == "number") fields[code] = NumStr(Db.G(b, rf2));
                else fields[code] = Db.Str(Db.G(b, rf2)).Trim();

                if (d.Kind == "code")
                {
                    var lk = d.Lookup.Trim(); var cv = Db.Str(fields[code]).Trim();
                    if (cv != "" && lk != "incoterm") { var nm = MasterName(src, db, lk, cv); if (nm != "") resolved[code] = nm; }
                }
            }

            // bound-aware shipping window (read-only display)
            var isImport = Db.Str(Db.G(a, "bound")) == "Import";
            if (fields.ContainsKey("etd")) fields["etd"] = DateStr(Db.G(b, isAir ? "f_date1" : isImport ? "departure1" : "departure2"));
            if (fields.ContainsKey("eta")) fields["eta"] = DateStr(Db.G(b, isImport ? "arrival1" : "arrival2"));

            if (!isAir && fields.ContainsKey("vessel_name"))
            {
                var vcode = Db.Str(Db.G(b, isImport ? "vessel_1" : "vessel_2")).Trim(); var vname = vcode;
                if (vcode != "") try { var vr = Db.RunQ(src, "SELECT TOP 1 short_name FROM dbo.veslmstr WHERE code=@c", new Dictionary<string, object?> { ["c"] = vcode }, 8); if (vr.Count > 0) { var sn = Db.Str(Db.G(vr[0], "short_name")).Trim(); if (sn != "") vname = sn; } } catch { }
                fields["vessel_name"] = vname;
            }
            if (!isAir && fields.ContainsKey("voyage_no")) fields["voyage_no"] = Db.Str(Db.G(b, isImport ? "voyage_1" : "voyage_2")).Trim();

            if (isAir)
            {
                try
                {
                    var adr = Db.RunQ(src, "SELECT TOP 1 mark2, desc2, good_desc1 FROM dbo.awbdetl WHERE blh=@r ORDER BY ref", new Dictionary<string, object?> { ["r"] = Db.G(b, "ref") }, 8);
                    if (adr.Count > 0)
                    {
                        if (fields.ContainsKey("ship_marks")) fields["ship_marks"] = Db.Str(Db.G(adr[0], "mark2")).Trim();
                        if (fields.ContainsKey("goods_desc")) { var gd = Db.Str(Db.G(adr[0], "desc2")).Trim(); if (gd == "") gd = Db.Str(Db.G(adr[0], "good_desc1")).Trim(); fields["goods_desc"] = gd; }
                    }
                }
                catch { }
            }
            else
            {
                try
                {
                    var bir = Db.RunQ(src, "SELECT TOP 1 commodity, c20, c40, cq, c45, mark2, mark3, good_desc1, desc2, desc3 FROM dbo.blitem WHERE blh=@r ORDER BY ref", new Dictionary<string, object?> { ["r"] = Db.G(b, "ref") }, 8);
                    if (bir.Count > 0)
                    {
                        var bi = bir[0];
                        if (fields.ContainsKey("commodity")) fields["commodity"] = Db.Str(Db.G(bi, "commodity")).Trim();
                        if (fields.ContainsKey("container20")) fields["container20"] = NumStr(Db.G(bi, "c20"));
                        if (fields.ContainsKey("container40")) fields["container40"] = NumStr(Db.G(bi, "c40"));
                        if (fields.ContainsKey("container_hq")) fields["container_hq"] = NumStr(Db.G(bi, "cq"));
                        if (fields.ContainsKey("container_other")) fields["container_other"] = NumStr(Db.G(bi, "c45"));
                        if (fields.ContainsKey("ship_marks")) fields["ship_marks"] = string.Join("\n", new[] { Db.Str(Db.G(bi, "mark2")).Trim(), Db.Str(Db.G(bi, "mark3")).Trim() }.Where(x => x != ""));
                        if (fields.ContainsKey("goods_desc")) { var gd = Db.Str(Db.G(bi, "good_desc1")).Trim(); if (gd == "") gd = string.Join("\n", new[] { Db.Str(Db.G(bi, "desc2")).Trim(), Db.Str(Db.G(bi, "desc3")).Trim() }.Where(x => x != "")); fields["goods_desc"] = gd; }
                    }
                }
                catch { }
                if (fields.ContainsKey("liner_code"))
                {
                    var lc = "";
                    try { var lcr = Db.RunQ(src, "SELECT TOP 1 lagent FROM dbo.blcont WHERE blh=@r AND NULLIF(lagent,'') IS NOT NULL ORDER BY ref", new Dictionary<string, object?> { ["r"] = Db.G(b, "ref") }, 8); if (lcr.Count > 0) lc = Db.Str(Db.G(lcr[0], "lagent")).Trim(); } catch { }
                    fields["liner_code"] = lc;
                    if (lc != "") { var nm = MasterName(src, db, "custsub", lc); if (nm != "") resolved["liner_code"] = nm; }
                }
                if (fields.ContainsKey("dest_code") && Db.Str(fields["dest_code"]).Trim() == "")
                {
                    var dv = Db.Str(Db.G(b, "deli")).Trim();
                    if (dv != "") { fields["dest_code"] = dv; var nm = MasterName(src, db, "port", dv); if (nm != "") resolved["dest_code"] = nm; }
                }
                if (fields.ContainsKey("cargo_wunit") && Db.Str(fields["cargo_wunit"]).Trim() == "") fields["cargo_wunit"] = "KGS";
            }

            var seed = new SeedResult(job, Db.Str(Db.G(a, "mode")), Db.Str(Db.G(a, "bound")), modeKey, isAir,
                station, db, Db.Str(Db.G(a, "erp_ref")).Trim(), fields, resolved, ownCode);
            return (seed, null);
        }
        catch (Exception ex) { return (null, new { error = "ERP lookup failed: " + ex.Message }); }
        finally { try { src?.Close(); } catch { } }
    }

    // Clean + clamp incoming corrections against the erp-edit dictionary (mirror of serve-ops.ps1
    // ErpEdit-CleanFields). Returns code -> string (scalar) or List<row dict> (kind=table), in dict order so the
    // change-diff against the freshly-read seed is order-stable.
    static Dictionary<string, object?> ErpEditCleanFields(string modeKey, JsonElement src)
    {
        var o = new Dictionary<string, object?>();
        foreach (var f in ErpEditFields.Defs(modeKey))
        {
            var c = f.Code;
            JsonElement raw = default;
            bool has = src.ValueKind == JsonValueKind.Object && src.TryGetProperty(c, out raw);
            if (f.Kind == "table")
            {
                var maxR = f.MaxRows > 0 ? f.MaxRows : 50;
                var rows = new List<Dictionary<string, object?>>();
                if (has && raw.ValueKind == JsonValueKind.Array)
                    foreach (var r in raw.EnumerateArray())
                    {
                        if (r.ValueKind != JsonValueKind.Object) continue;   // legacy/garbage value -> skipped
                        var row = new Dictionary<string, object?>();
                        foreach (var col in f.Columns)
                        {
                            JsonElement cv = default; var cvHas = r.TryGetProperty(col.Code, out cv);
                            row[col.Code] = DocUtil.CleanStr(cvHas ? JeVal(cv) : null, col.MaxLen);
                        }
                        if (row.Values.Any(v => (v as string ?? "").Trim() != "")) rows.Add(row);
                        if (rows.Count >= maxR) break;
                    }
                o[c] = rows;
            }
            else o[c] = DocUtil.CleanStr(has ? JeVal(raw) : null, f.MaxLen);
        }
        return o;
    }

    // a JsonElement's scalar value as a CLR object for cleaning (string/number/bool -> string-friendly; null/other -> null)
    static object? JeVal(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString(),
        JsonValueKind.Number => v.ToString(),
        JsonValueKind.True => "true",
        JsonValueKind.False => "false",
        _ => null,
    };

    // ---- POST /api-ops/erp-edit-save (serve-ops.ps1 Save-ErpEdit 1050-1094) ----
    // Diff the corrected fields against a fresh live read of the ERP, push ONLY the changed ones via
    // /booking/update, and audit before->after in erp_edit_log. The client sends the FULL field set (seed overlaid
    // with edits) so a field the operator never touched is never seen as cleared.
    public static object ErpEditSave(SqlConnection cn, JsonElement j, ReqState rs, string ip)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object || !j.Has("job_no")) return new { error = "invalid payload" };
        var job = j.Str("job_no").Trim();
        if (job == "") return new { error = "invalid payload" };
        // authoritative 'before' = re-read the live ERP values right now (never trust a client-sent baseline)
        var (seed, err) = ErpEditSeedCore(cn, job, rs);
        if (err != null) return err;
        var s = seed!;
        var defs = ErpEditFields.Defs(s.ModeKey);
        var current = s.Fields;
        var jfields = j.TryGetProperty("fields", out var fe) ? fe : default;
        var clean = ErpEditCleanFields(s.ModeKey, jfields);
        var changedCodes = DocUtil.Changed(current, clean);
        if (changedCodes.Count == 0) return new { error = "no changes to save" };
        var defByCode = new Dictionary<string, FieldDef>(); foreach (var d in defs) defByCode[d.Code] = d;
        // block a change to a read-only field (no writeKey) up front, with a clear message
        var blocked = changedCodes.Where(c => (defByCode.TryGetValue(c, out var dd) ? dd.WriteKey.Trim() : "") == "").ToList();
        if (blocked.Count > 0) return new { error = $"these fields cannot be written to the ERP (no write key): {string.Join(", ", blocked)}" };
        var changed = new Dictionary<string, object?>(); foreach (var c in changedCodes) changed[c] = clean[c];
        // Booking key for /booking/update - house-level (one jobn = many houses). Field name differs by mode; chains
        // last-resort to jobn. Read from the fresh seed (codes are mode-mapped to the right ERP column).
        var chain = s.IsAir ? new[] { "booking_no", "bl_no", "master_no", "job_disp" } : new[] { "booking_no", "bl_no", "job_disp" };
        var bookingNo = "";
        foreach (var code in chain) { var v = (s.Fields.TryGetValue(code, out var vv) ? vv as string : "") ?? ""; v = v.Trim(); if (v != "") { bookingNo = v; break; } }
        if (bookingNo == "") bookingNo = job;
        var fwd = s.OwnCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        var ident = new Erp.PatchIdent(bookingNo, s.ModeKey, s.Bound, fwd);
        var (payload, sent) = Erp.BuildPatchPayload(changed, defs, ident, clean);
        var erp = Erp.EditPush(payload, bookingNo, s.ModeKey, me, fwd);
        var changeRecs = changedCodes.Select(c => (object)new
        {
            field = c, writeKey = defByCode[c].WriteKey,
            before = DocUtil.ValStr(current.TryGetValue(c, out var cv) ? cv : null),
            after = DocUtil.ValStr(clean.TryGetValue(c, out var nv) ? nv : null),
        }).ToList();
        var status = erp.Mock ? "mock" : erp.Error != "" ? "error" : erp.Rejected ? "rejected" : "saved";
        var jsonc = new JsonSerializerOptions { PropertyNamingPolicy = null };
        Db.Exec(cn, "INSERT INTO dbo.erp_edit_log(job_no,erp_ref,station,mode,bound,actor,ip,changed_json,erp_status,erp_steps,erp_error,occurred_at) VALUES(@j,@r,@s,@m,@b,@a,@ip,@cj,@st,@stp,@err,SYSDATETIME())",
            new Dictionary<string, object?>
            {
                ["j"] = job, ["r"] = s.ErpRef, ["s"] = s.Station, ["m"] = s.Mode, ["b"] = s.Bound, ["a"] = me, ["ip"] = ip,
                ["cj"] = JsonSerializer.Serialize(changeRecs, jsonc), ["st"] = status,
                ["stp"] = JsonSerializer.Serialize(erp.Steps, jsonc), ["err"] = erp.Error,
            });
        Auth.Audit(me, $"erp-edit {job} [{string.Join(",", changedCodes)}] -> erp:{status}{(erp.Error != "" ? " ERR " + erp.Error : "")}");
        return new
        {
            ok = true, changed = changedCodes, sent, status,
            erp = new { ok = erp.Ok, mock = erp.Mock, rejected = erp.Rejected, steps = erp.Steps, error = erp.Error },
        };
    }
}
