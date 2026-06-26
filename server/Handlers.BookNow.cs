using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Ops;

public static partial class Handlers
{
    // ============================================================================================================
    // BOOK NOW - quick create a brand-new booking in the Swivel ERP from minimal operator input. Three endpoints:
    //   GET  /api-ops/book-now-seed    - station + default POL/service for the form (per mode)
    //   GET  /api-ops/book-now-master  - master type-ahead, station-scoped (a job-less twin of ErpMaster)
    //   POST /api-ops/book-now         - build a minimal /booking/update payload with NO bookingNo (ERP auto-
    //                                    generates it) and push it directly (no /booking/get guard -> a real create)
    // Scope: the create + lookups are bound to a station the caller is scoped to (ResolveBookStation). Reuses the
    // SAME ERP-API plumbing as Edit ERP (Erp.Call / ErpLog / mock mode) and the SAME master lookup SQL (MasterResults).
    // ============================================================================================================

    // The station this Book Now acts on: an explicit (in-scope) station, else the caller's first scoped station,
    // else the instance's configured station. Out-of-scope requests are refused.
    static (string Station, string? Err) ResolveBookStation(ReqState rs, string requested)
    {
        var cur = Scope.CurStations(rs);
        if (requested != "")
        {
            if (rs.Open || cur.Contains(requested)) return (requested, null);
            return ("", "station not in your scope");
        }
        if (cur.Length > 0) return (cur[0], null);
        var def = Config.StationCode;
        if (def == "") def = Config.Stations.FirstOrDefault()?.Code ?? "";
        return def == "" ? ("", "no station configured") : (def, null);
    }

    static string BookServiceDefault(bool isAir)
    {
        if (isAir) { var a = ErpMap.Str("serviceCodeAirDefault").Trim(); if (a != "") return a; }
        return ErpMap.Str("serviceCodeDefault").Trim();
    }

    // ---- GET /api-ops/book-now-seed?mode=Sea|Air[&station=] ----
    public static object BookNowSeed(SqlConnection cn, Qs q, ReqState rs)
    {
        var mode = (q["mode"] ?? "").Trim(); if (mode != "Air" && mode != "Sea") mode = "Sea";
        var isAir = mode == "Air";
        var (station, sErr) = ResolveBookStation(rs, (q["station"] ?? "").Trim());
        if (sErr != null) return new { error = sErr };
        var db = Source.DbFor(station);
        if (db == null) return new { error = $"station '{station}' has no ERP database mapped in config stations[]" };

        var st = Config.StationByCode(station);
        // Air POL = the IATA station code; Sea POL = the 5-letter UN/LOCODE (country + station), e.g. HK+HKG=HKHKG.
        var polCode = isAir ? station : ((st?.Country ?? "") + station);
        var svcCode = BookServiceDefault(isAir);

        string polName = "", svcName = "";
        SqlConnection? src = null;
        try { src = Source.Open(db); polName = MasterName(src, db, "port", polCode); svcName = MasterName(src, db, "service", svcCode); }
        catch { }
        finally { try { src?.Close(); } catch { } }

        var stations = rs.Open ? Config.Stations.Select(s => s.Code).ToArray() : Scope.CurStations(rs);
        return new
        {
            station,
            mode,
            stations,
            today = Config.TodayStr(),           // ETD defaults to today on the client
            ownCode = Source.ForwarderCode(station),
            defaultPol = new { code = polCode, name = polName },
            defaultService = new { code = svcCode, name = svcName },
            quantityUnit = "CTN",
        };
    }

    // ---- GET /api-ops/book-now-master?kind=&q=&mode=[&station=] - station-scoped master lookup (no job) ----
    public static object BookNowMaster(SqlConnection cn, Qs q, ReqState rs)
    {
        var kind = (q["kind"] ?? "").Trim().ToLowerInvariant();
        var term = (q["q"] ?? "").Trim();
        var isAir = (q["mode"] ?? "").Trim() == "Air";
        if (kind == "incoterm") return new { kind = "incoterm", results = IncotermResults(term) };
        var (station, sErr) = ResolveBookStation(rs, (q["station"] ?? "").Trim());
        if (sErr != null) return new { error = sErr };
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

    static string Clamp(string s, int max) { s = (s ?? "").Trim(); return s.Length > max ? s.Substring(0, max) : s; }

    // Resolve a port the operator may have entered as EITHER a code OR a name (we don't force a code - "people may
    // type the name, the ERP resolves it"). If a code is known (picked from the lookup) we just backfill its name;
    // otherwise we seek portmstr by exact code first, then by name LIKE (mode-filtered). If nothing matches we keep
    // the typed text as the name and send name-only, letting the ERP resolve the code. Returns (code, name).
    static (string Code, string Name) ResolvePort(SqlConnection src, string code, string name, bool isAir)
    {
        if (code != "") { var n = MasterName(src, "", "port", code); return (code, n != "" ? n : name); }
        if (name == "") return ("", "");
        try
        {
            var r = Db.RunQ(src,
                "SELECT TOP 1 code, port_ldes1 nm FROM dbo.portmstr WHERE NULLIF(code,'') IS NOT NULL AND (NULLIF(module,'') IS NULL OR module=@m) " +
                "AND (code=@t OR port_ldes1 LIKE @lk) ORDER BY CASE WHEN code=@t THEN 0 ELSE 1 END, code",
                new Dictionary<string, object?> { ["m"] = isAir ? "AIR" : "SEA", ["t"] = name, ["lk"] = "%" + name.Replace("%", "").Replace("_", "") + "%" }, 8);
            if (r.Count > 0) return (Db.Str(Db.G(r[0], "code")).Trim(), Db.Str(Db.G(r[0], "nm")).Trim());
        }
        catch { }
        return ("", name);   // unresolved -> send the name only; the ERP resolves the code
    }

    // Clean party name for a custsub code (doc_e_name only - no city/country suffix, unlike MasterName).
    static string PartyName(SqlConnection src, string code)
    {
        code = code.Trim(); if (code == "") return "";
        try
        {
            var r = Db.RunQ(src, "SELECT TOP 1 doc_e_name,mal_e_name FROM dbo.custsub WHERE code2=@c AND ISNULL(isdel,0)=0", new Dictionary<string, object?> { ["c"] = code }, 8);
            if (r.Count > 0) { var n = Db.Str(Db.G(r[0], "doc_e_name")).Trim(); return n != "" ? n : Db.Str(Db.G(r[0], "mal_e_name")).Trim(); }
        }
        catch { }
        return "";
    }

    // Build the next outbound reference from the configurable template (Settings.BookRefFormat; admin-editable).
    // Tokens: {station} {m}(A/S) {mode}(AIR/SEA) {yymmdd} {yy} {seqN}(running no., N-wide) / {seq}(=4-wide). The
    // running number is atomic per (station, mode, period) - period = the date token's value (resets daily) or "" (a
    // CONTINUOUS running number when the format carries no date, e.g. "{station}{m}{seq5}" -> HKGA00001). Concurrent
    // submits never collide: UPDATE...OUTPUT the bumped seq; INSERT the period's first row on a miss.
    static string NextBookRef(SqlConnection cn, string station, bool isAir)
    {
        var fmt = Settings.BookRefFormat; if (string.IsNullOrWhiteSpace(fmt)) fmt = Settings.BookRefFormatDefault;
        var now = Config.TodayDate();
        var period = fmt.Contains("{yymmdd}") ? now.ToString("yyMMdd") : (fmt.Contains("{yy}") ? now.ToString("yy") : "");
        var mode = isAir ? "AIR" : "SEA";
        var p = new Dictionary<string, object?> { ["s"] = station, ["m"] = mode, ["d"] = period };
        int seq;
        var bumped = Db.RunQ(cn, "UPDATE dbo.book_ref_seq SET seq=seq+1 OUTPUT inserted.seq seq WHERE station=@s AND mode=@m AND day_key=@d", p);
        if (bumped.Count > 0) seq = Db.IntOf(Db.G(bumped[0], "seq"));
        else
        {
            try { Db.Exec(cn, "INSERT INTO dbo.book_ref_seq(station,mode,day_key,seq) VALUES(@s,@m,@d,1)", p); seq = 1; }
            catch
            {
                var r2 = Db.RunQ(cn, "UPDATE dbo.book_ref_seq SET seq=seq+1 OUTPUT inserted.seq seq WHERE station=@s AND mode=@m AND day_key=@d", p);
                seq = r2.Count > 0 ? Db.IntOf(Db.G(r2[0], "seq")) : 1;
            }
        }
        int width = 4; var mw = Regex.Match(fmt, @"\{seq(\d+)\}"); if (mw.Success) width = int.Parse(mw.Groups[1].Value);
        var outp = fmt.Replace("{station}", station).Replace("{mode}", mode).Replace("{m}", isAir ? "A" : "S")
                      .Replace("{yymmdd}", now.ToString("yyMMdd")).Replace("{yy}", now.ToString("yy"));
        outp = Regex.Replace(outp, @"\{seq\d+\}", seq.ToString("D" + width)).Replace("{seq}", seq.ToString("D4"));
        return outp;
    }

    // ---- POST /api-ops/book-now - create the booking in the ERP (auto bookingNo) ----
    public static object BookNowCreate(SqlConnection cn, JsonElement j, ReqState rs, string ip)
    {
        var me = rs.Me;
        if (j.ValueKind != JsonValueKind.Object) return new { error = "invalid payload" };
        var mode = j.Str("mode").Trim();
        if (mode != "Air" && mode != "Sea") return new { error = "mode must be Air or Sea" };
        var isAir = mode == "Air";
        var bound = j.Str("bound").Trim() == "Import" ? "Import" : "Export";
        var (station, sErr) = ResolveBookStation(rs, j.Str("station").Trim());
        if (sErr != null) return new { error = sErr };
        var db = Source.DbFor(station);
        if (db == null) return new { error = $"station '{station}' has no ERP database mapped in config stations[]" };

        // form fields (trimmed + clamped to the ERP column limits)
        var polCode = Clamp(j.Str("polCode"), 5);
        var polName = Clamp(j.Str("polName"), 100);
        var podCode = Clamp(j.Str("podCode"), 5);
        var podName = Clamp(j.Str("podName"), 100);
        var serviceCode = Clamp(j.Str("serviceCode"), 10); if (serviceCode == "") serviceCode = BookServiceDefault(isAir);
        var incoterm = Clamp(j.Str("incoterm"), 15);
        var commodity = Clamp(j.Str("commodity"), 21);
        var quantity = j.Str("quantity").Trim();
        var quantityUnit = Clamp(j.Str("quantityUnit"), 10); if (quantityUnit == "") quantityUnit = "CTN";
        var grossWeight = j.Str("grossWeight").Trim();
        var cbm = j.Str("cbm").Trim();
        var shipperCode = Clamp(j.Str("shipperCode"), 8);
        var shipperName = Clamp(j.Str("shipperName"), 100);
        var consigneeCode = Clamp(j.Str("consigneeCode"), 8);
        var consigneeName = Clamp(j.Str("consigneeName"), 100);
        var remark = Clamp(j.Str("remark"), 2000);
        var refNo = Clamp(j.Str("refNo"), 40);

        // backfill any missing port name server-side (the name is part of the NewBooking-required set) + resolve owncode;
        // also resolve a clean party name (doc_e_name only, no city/country) when a code is given without one.
        var fwd = "";
        SqlConnection? src = null;
        try
        {
            src = Source.Open(db);
            fwd = Source.OwnCode(src, db);
            // ports may arrive as a code (picked) OR a name (typed) - resolve both, name-only is acceptable
            var rp = ResolvePort(src, polCode, polName, isAir); polCode = rp.Code; polName = rp.Name;
            var rd = ResolvePort(src, podCode, podName, isAir); podCode = rd.Code; podName = rd.Name;
            if (shipperCode != "" && shipperName == "") shipperName = PartyName(src, shipperCode);
            if (consigneeCode != "" && consigneeName == "") consigneeName = PartyName(src, consigneeCode);
        }
        catch { }
        finally { try { src?.Close(); } catch { } }
        if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();

        // NewBooking-required set: commodity + POL + POD (each as a code OR a name; serviceCode auto-defaults per mode).
        var missing = new List<string>();
        if (commodity == "") missing.Add("commodity");
        if (polCode == "" && polName == "") missing.Add("port of loading");
        if (podCode == "" && podName == "") missing.Add("port of discharge");
        if (missing.Count > 0) return new { error = "please fill: " + string.Join(", ", missing) };

        if (refNo == "") refNo = NextBookRef(cn, station, isAir);

        var input = new Erp.NewBookingInput(
            isAir ? "AIR" : "SEA", bound, fwd,
            polCode, polName, podCode, podName,
            serviceCode, incoterm, commodity,
            j.Str("cargoReady").Trim(), j.Str("etd").Trim(),
            quantity, quantityUnit, grossWeight, cbm,
            j.Str("container20").Trim(), j.Str("container40").Trim(), j.Str("containerHQ").Trim(), j.Str("containerOthers").Trim(),
            shipperCode, shipperName, consigneeCode, consigneeName,
            remark, refNo);
        var payload = Erp.BuildNewBookingPayload(input);

        // ASYNC: register the booking now (our reference) and ENQUEUE the ERP push so the operator never waits for the
        // ~10s /booking/update. We (1) surface it in the New-bookings panel immediately with status 'erp-pending' and
        // (2) queue the payload in book_pending; the BookingPusher background service drains it, stamps the ERP
        // booking number onto booking_alert + erp_edit_log and notifies the creator via My Tasks. job_no carries our
        // refNo throughout; booking_no fills in with the ERP number once confirmed (also the watch-bookings dedup key).
        try
        {
            Db.Exec(cn,
                "IF NOT EXISTS(SELECT 1 FROM dbo.booking_alert WHERE station=@s AND mode=@m AND erp_ref=@r) " +
                "INSERT INTO dbo.booking_alert(station,mode,erp_ref,job_no,booking_no,shipper_code,shipper_name,pol,pod,src_created,detected_at,status,channel) " +
                "VALUES(@s,@m,@r,@r,NULL,@sc,@sn,@pol,@pod,SYSDATETIME(),SYSDATETIME(),'erp-pending','book-now')",
                new Dictionary<string, object?>
                {
                    ["s"] = station, ["m"] = mode, ["r"] = Clamp(refNo, 40),
                    ["sc"] = shipperCode == "" ? null : shipperCode, ["sn"] = shipperName == "" ? null : shipperName,
                    ["pol"] = polCode, ["pod"] = podCode,
                });
            Db.Exec(cn,
                "INSERT INTO dbo.book_pending(ref_no,station,mode,actor,payload,status) VALUES(@r,@s,@m,@a,@p,'pending')",
                new Dictionary<string, object?> { ["r"] = refNo, ["s"] = station, ["m"] = mode, ["a"] = me, ["p"] = payload.ToJsonString() });
        }
        catch (Exception ex)
        {
            Log.Error("book-now enqueue", ex);
            return new { error = "could not register the booking: " + ex.Message };
        }
        Auth.Audit(me, $"book-now {station} {mode}/{bound} ref={refNo} -> queued for ERP push");

        return new { ok = true, refNo, pending = true, status = "registered", mock = Erp.MockMode() };
    }
}
