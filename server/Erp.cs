using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Ops;

// Swivel 3rd-party ERP API client (port of erp-doc-api.ps1, file-enquiry/download/upload + the master-code patch
// push). Spec: https://documents.swivelsoftware.com/3rd-erpapi.html (bearer auth, POST JSON).
//
// Live-call rules learned on demoerp (DO NOT REGRESS):
//   - 3rdBookingID is a shipment LOOKUP key (our booking number = the ERP's external reference), never our ids.
//   - read-merge-write: /booking/update is "New Booking / Update Booking" - a key mismatch CREATES a duplicate,
//     so EditPush does /booking/get first and ABORTS if the booking is absent.
//   - serviceCode/commodity/POL/POD are NewBooking-required; the operator rarely edits them, so read-merge them
//     from the live booking for any key the patch doesn't already carry (so editing one field never blanks the rest).
//   - bookingParty.forwarderPartyCode (= owncode) is REQUIRED and routes the write to the right office.
//   - Invoke-RestMethod returns a JSON array as ONE object - mirrored here by AsArray over the parsed node.
//
// MOCK MODE (default when no baseUrl/token, or erpApi.mock=true): builds the same payloads and writes
// erp-mock/*.json instead of calling out. The bearer token lives in ops.config.json (gitignored); the non-secret
// deployment codes (partyGroupCode/forwarderCode/...) live in erp-api-map.json (ErpMap).
public static partial class Erp
{
    // dedicated client: 60s timeout like the PS Invoke-RestMethod calls (longer than the shared 30s L!NK client).
    static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(60) };

    public sealed class ErpException : Exception { public ErpException(string m) : base(m) { } }

    // effective ERP connection comes from Settings (SQL app_setting override, else ops.config.json) so a customer-site
    // admin can correct the URL/token/mock from the admin "ERP API" tab without a restart.
    public static bool MockMode() => Settings.ErpBaseUrl.Trim() == "" || Settings.ErpToken.Trim() == "" || Settings.ErpMock;

    // ---- low-level POST: bearer auth, JSON body, parsed JsonNode back; throws ErpException carrying the ERP's
    // own validation message on a non-2xx (ErpErr - so "Invalid carrier code" reaches the user, not just "(422)"). ----
    public static JsonNode? Call(string path, JsonObject payload)
    {
        var baseUrl = Settings.ErpBaseUrl.Trim().TrimEnd('/');
        var tok = Regex.Replace(Settings.ErpToken.Trim(), @"^(?i:Bearer\s+)", "").Trim();   // tolerate a pasted 'Bearer ' prefix
        // EVERY call is logged to dbo.erp_api_log (success + failure) so a customer-site admin can see which ERP API
        // errored and why (ErpLog.Write never throws). The bearer token is a header, never in reqSummary.
        var reqSummary = ErpLog.Summarize(payload);
        var sw = System.Diagnostics.Stopwatch.StartNew();
        int? status = null;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + path);
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + tok);
            req.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
            using var r = _http.Send(req);
            status = (int)r.StatusCode;
            string body;
            using (var sr = new StreamReader(r.Content.ReadAsStream(), Encoding.UTF8)) body = sr.ReadToEnd();
            if (!r.IsSuccessStatusCode)
            {
                var err = BuildErr((int)r.StatusCode, r.ReasonPhrase, body);
                ErpLog.Write(path, false, status, (int)sw.ElapsedMilliseconds, err, reqSummary, body);
                throw new ErpException(err);
            }
            ErpLog.Write(path, true, status, (int)sw.ElapsedMilliseconds, null, reqSummary, body);
            if (string.IsNullOrWhiteSpace(body)) return null;
            try { return JsonNode.Parse(body); } catch { return null; }
        }
        catch (ErpException) { throw; }   // already logged above
        catch (Exception ex)              // transport failure (timeout, DNS, connection reset) - no HTTP status
        {
            ErpLog.Write(path, false, status, (int)sw.ElapsedMilliseconds, ex.Message, reqSummary, null);
            throw new ErpException(ex.Message);
        }
    }

    static string BuildErr(int code, string? reason, string body)
    {
        var msg = $"({code}) {reason}";
        if (!string.IsNullOrWhiteSpace(body))
        {
            try { var ee = PropCI(PropCI(JsonNode.Parse(body), "error"), "error"); if (ee != null && ee.ToString() != "") return $"{msg} - {ee}"; } catch { }
            return $"{msg} - {body}";
        }
        return msg;
    }

    static void MockWrite(string name, JsonObject obj)
    {
        var dir = Path.Combine(Config.RepoRoot, "erp-mock");
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, name), obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
    }

    // ---- helpers over a parsed JSON response (PSCustomObject access is case-insensitive; mirror that) ----
    static JsonNode? PropCI(JsonNode? n, string name)
    {
        if (n is not JsonObject o) return null;
        foreach (var kv in o) if (string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase)) return kv.Value;
        return null;
    }
    static string StrProp(JsonNode? n, string name) => PropCI(n, name)?.ToString() ?? "";
    static IEnumerable<JsonNode?> AsArray(JsonNode? n) => n switch { JsonArray a => a, null => Array.Empty<JsonNode?>(), _ => new[] { n } };
    static List<JsonObject> ObjItems(JsonNode? c)
    {
        var list = new List<JsonObject>();
        if (c is JsonArray a) { foreach (var x in a) if (x is JsonObject xo) list.Add(xo); }
        else if (c is JsonObject o) list.Add(o);
        return list;
    }

    // Fetch the current booking (POST /booking/get). The same bookingNo can exist once per module, so filter by
    // moduleTypeCode. Returns null on any error / no hit (the existence guard then aborts the update).
    public static JsonNode? BookingGet(string bookingNo, string module, string forwarderCode)
    {
        try
        {
            var fwd = forwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
            var resp = Call("/booking/get", new JsonObject { ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(), ["forwarderCode"] = fwd, ["bookingNo"] = bookingNo });
            foreach (var el in AsArray(resp)) if (el is JsonObject && StrProp(el, "moduleTypeCode") == module) return el;
            return null;
        }
        catch { return null; }
    }

    // Normalize a /file/enquiry response (bare array or enveloped {message:{message:[...]}}) into projected file
    // rows {fileName,documentTypeCode,remark}. Mirrors Erp-FileArray.
    static List<object> FileArray(JsonNode? resp)
    {
        var outl = new List<object>();
        if (resp == null) return outl;
        List<JsonObject>? arr = null;
        foreach (var c in new[] { resp, PropCI(PropCI(resp, "message"), "message"), PropCI(resp, "message"), PropCI(resp, "data") })
        {
            if (c == null) continue;
            var items = ObjItems(c);
            if (items.Count > 0 && PropCI(items[0], "fileName") != null) { arr = items; break; }
        }
        if (arr == null) return outl;
        foreach (var it in arr)
            outl.Add(new { fileName = StrProp(it, "fileName").Trim(), documentTypeCode = StrProp(it, "documentTypeCode").Trim(), remark = StrProp(it, "remark").Trim() });
        return outl;
    }

    public sealed record FileEnquiryResult(List<object> Files, string KeyUsed, string KeyKind, string KeyField, bool Mock, string Error);

    // List the files the ERP holds for a shipment. /file/enquiry filters by 3rdBookingID OR bookingNo only; try
    // each candidate identifier as 3rdBookingID first, then bookingNo, returning the first hit. Mirrors
    // Invoke-ErpFileEnquiry. candidates = ordered (kind,val) identifier list (Air HAWB->Booking->MAWB, Sea Booking->HBL).
    public static FileEnquiryResult FileEnquiry(string module, List<(string Kind, string Val)> candidates, string forwarderCode)
    {
        if (MockMode()) return new(new(), "", "", "", true, "");
        var cands = candidates.Where(c => c.Val.Trim() != "").ToList();
        if (cands.Count == 0) return new(new(), "", "", "", false, "no booking/bill number on this shipment");
        var fwd = forwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        var pg = ErpMap.Str("partyGroupCode").Trim();
        var lastErr = "";
        foreach (var field in new[] { "3rdBookingID", "bookingNo" })
            foreach (var c in cands)
            {
                var val = c.Val.Trim();
                try
                {
                    var files = FileArray(Call("/file/enquiry", new JsonObject { ["partyGroupCode"] = pg, ["forwarderCode"] = fwd, ["moduleTypeCode"] = module, [field] = val }));
                    if (files.Count > 0) return new(files, val, c.Kind, field, false, "");
                }
                catch (Exception ex) { if (!ex.Message.Contains("No corresponding data")) lastErr = ex.Message; }   // "No corresponding data" = ERP has no files here, not an error
            }
        return new(new(), cands[0].Val.Trim(), cands[0].Kind, "", false, lastErr);
    }

    public sealed record FileDownloadResult(byte[]? Bytes, string FileName, bool Mock, string Error);

    // Download one ERP-held file's bytes. Same candidate/field order as enquiry; picks the item matching fileName
    // (or the first with content) and decodes its base64. Mirrors Invoke-ErpFileDownload.
    public static FileDownloadResult FileDownload(string module, List<(string Kind, string Val)> candidates, string fileName, string forwarderCode)
    {
        if (MockMode()) return new(null, fileName, true, "");
        var cands = candidates.Where(c => c.Val.Trim() != "").ToList();
        if (cands.Count == 0) return new(null, fileName, false, "no booking/bill number on this shipment");
        var want = fileName.Trim();
        var fwd = forwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        var pg = ErpMap.Str("partyGroupCode").Trim();
        var lastErr = "";
        foreach (var field in new[] { "3rdBookingID", "bookingNo" })
            foreach (var c in cands)
            {
                var val = c.Val.Trim();
                try
                {
                    var payload = new JsonObject { ["partyGroupCode"] = pg, ["forwarderCode"] = fwd, ["moduleTypeCode"] = module, [field] = val };
                    if (want != "") payload["fileName"] = want;
                    var resp = Call("/file/download", payload);
                    List<JsonObject>? items = null;
                    foreach (var cc in new[] { resp, PropCI(PropCI(resp, "message"), "message"), PropCI(resp, "message"), PropCI(resp, "data") })
                    {
                        if (cc == null) continue;
                        var lst = ObjItems(cc);
                        if (lst.Count > 0 && PropCI(lst[0], "base64") != null) { items = lst; break; }
                    }
                    if (items != null)
                    {
                        var pick = want != "" ? items.FirstOrDefault(it => StrProp(it, "fileName").Trim() == want) : null;
                        pick ??= items[0];
                        var b64 = StrProp(pick, "base64").Trim();
                        if (b64 != "") return new(Convert.FromBase64String(b64), StrProp(pick, "fileName").Trim(), false, "");
                    }
                }
                catch (Exception ex) { if (!ex.Message.Contains("No corresponding data")) lastErr = ex.Message; }
            }
        return new(null, want, false, lastErr != "" ? lastErr : "file not found in the ERP");
    }

    public sealed record UploadResult(bool Ok, bool Mock, string Error);

    // Upload ONE file via /file/upload (one attachment per call: bounded body, attributable failure). Keyed by
    // houseNo+bookingNo. Mirrors Invoke-ErpFileUpload.
    public static UploadResult FileUpload(string module, string houseNo, string bookingNo, string doctype, string fileName, string base64, string remark, string forwarderCode)
    {
        if (MockMode())
        {
            try
            {
                MockWrite($"upload-{Guid.NewGuid():N}.json", new JsonObject
                {
                    ["at"] = DateTime.Now.ToString("o"), ["module"] = module, ["houseNo"] = houseNo, ["bookingNo"] = bookingNo,
                    ["documentTypeCode"] = doctype, ["fileName"] = fileName, ["bytes"] = (int)Math.Ceiling(base64.Length * 0.75), ["remark"] = remark,
                });
            }
            catch { }
            return new(true, true, "");
        }
        var fwd = forwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        var up = new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(), ["forwarderCode"] = fwd, ["moduleTypeCode"] = module,
            ["houseNo"] = houseNo, ["bookingNo"] = bookingNo,
            ["attachments"] = new JsonArray(new JsonObject { ["documentTypeCode"] = doctype, ["fileName"] = fileName, ["base64"] = base64, ["remark"] = remark }),
        };
        try { Call("/file/upload", up); return new(true, false, ""); }
        catch (Exception ex) { return new(false, false, ex.Message); }
    }

    public sealed record DocGenResult(bool Ok, bool Mock, string FileName, byte[]? Bytes, string Error);

    // Generate a document in the ERP via /document/generate (the drawer "Generate document" feature). The booking/
    // bill key is chosen by priority houseBillNo -> bookingNo -> masterBillNo, EXCEPT a master-level document
    // (useMasterBill) keys on masterBillNo; 3rdBookingID is the last-resort fallback. includeFile=true asks the ERP
    // to return the file inline - parsed defensively here (the ERP may instead just store it, fetched via
    // /file/enquiry+/file/download). Distinct from ErpDoc.DocIssue's generate side-effect, which is left untouched.
    public static DocGenResult DocGenerate(string module, string documentTypeCode, string houseTypeCode,
        string houseBillNo, string bookingNo, string masterBillNo, string thirdBookingId, bool useMasterBill,
        string invoiceNumber, string forwarderCode)
    {
        var hbl = (houseBillNo ?? "").Trim(); var bk = (bookingNo ?? "").Trim();
        var mbl = (masterBillNo ?? "").Trim(); var third = (thirdBookingId ?? "").Trim();
        // priority-ordered identifier candidates (each is one payload key): houseBillNo -> bookingNo -> masterBillNo
        // -> 3rdBookingID, EXCEPT a master-level doc leads with masterBillNo. The ERP keys on ONE field; a stale/
        // dummy bill yields 422 "No corresponding shipment", so we fall through to the next candidate (mirrors how
        // FileEnquiry/FileDownload iterate candidates) - e.g. a typed-but-not-issued HAWB falls back to the bookingNo.
        var cands = new List<(string Field, string Val)>();
        void Add(string f, string v) { if (v != "" && !cands.Any(c => c.Field == f)) cands.Add((f, v)); }
        if (useMasterBill) { Add("masterBillNo", mbl); Add("bookingNo", bk); Add("houseBillNo", hbl); }
        else { Add("houseBillNo", hbl); Add("bookingNo", bk); Add("masterBillNo", mbl); }
        Add("3rdBookingID", third);
        if (cands.Count == 0) return new(false, MockMode(), "", null, "no booking / bill number on this shipment to generate the document");
        var fwd = forwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        var inv = (invoiceNumber ?? "").Trim();
        JsonObject Build(string field, string val) => new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(), ["forwarderCode"] = fwd, ["moduleTypeCode"] = module,
            ["documentTypeCode"] = documentTypeCode,
            ["bookingNo"] = field == "bookingNo" ? val : "", ["houseBillNo"] = field == "houseBillNo" ? val : "",
            ["masterBillNo"] = field == "masterBillNo" ? val : "", ["3rdBookingID"] = field == "3rdBookingID" ? val : "",
            ["houseTypeCode"] = houseTypeCode, ["invoiceNumber"] = inv, ["includeFile"] = true,
        };
        if (MockMode())
        {
            try { MockWrite($"generate-{Guid.NewGuid():N}.json", new JsonObject { ["at"] = DateTime.Now.ToString("o"), ["payload"] = Build(cands[0].Field, cands[0].Val).DeepClone() }); } catch { }
            return new(true, true, "", null, "");
        }
        var lastErr = "";
        foreach (var (field, val) in cands)
        {
            try
            {
                var resp = Call("/document/generate", Build(field, val));
                // includeFile=true returns the PDF inline (verified live: under the top-level "file" array; the ERP
                // does NOT store it). Walk the likely containers and extract the first base64 item.
                List<JsonObject>? items = null;
                foreach (var cc in new[] { PropCI(resp, "file"), resp, PropCI(PropCI(resp, "message"), "message"), PropCI(resp, "message"), PropCI(resp, "data") })
                {
                    if (cc == null) continue;
                    var lst = ObjItems(cc);
                    if (lst.Count > 0 && PropCI(lst[0], "base64") != null) { items = lst; break; }
                }
                if (items != null && items.Count > 0)
                {
                    var b64 = StrProp(items[0], "base64").Trim();
                    if (b64 != "") return new(true, false, StrProp(items[0], "fileName").Trim(), Convert.FromBase64String(b64), "");
                }
                return new(true, false, "", null, "");   // generated but no inline file returned (defensive)
            }
            catch (Exception ex)
            {
                lastErr = ex.Message;
                // only fall through to the next identifier when THIS one didn't match a shipment; any other error
                // (bad documentType/houseType, auth, etc.) won't be fixed by another key, so stop.
                if (!ex.Message.Contains("No corresponding")) return new(false, false, "", null, lastErr);
            }
        }
        return new(false, false, "", null, lastErr != "" ? lastErr : "no corresponding shipment in the ERP for this booking / bill");
    }

    // ============================================================================================================
    // ERP MASTER-CODE CORRECTION patch build + push (staff-internal). Build a MINIMAL /booking/update payload that
    // carries the booking identity keys + ONLY the fields the operator changed (mapped by each dict field's
    // writeKey). Party-prefixed writeKeys nest inside bookingParty; flexData.* nest inside flexData; everything
    // else is top-level. Mirrors Build-ErpPatchPayload + Invoke-ErpEditPush.
    // ============================================================================================================
    public sealed record PatchIdent(string BookingNo, string Module, string Bound, string ForwarderCode);

    static string RowV(IDictionary<string, object?> r, string k) => r.TryGetValue(k, out var v) ? (v?.ToString() ?? "") : "";
    static IEnumerable<IDictionary<string, object?>> AsRows(object? v)
    {
        if (v is System.Collections.IEnumerable en && v is not string)
            foreach (var x in en) if (x is IDictionary<string, object?> d) yield return d;
    }

    public static (JsonObject Payload, List<object> Sent) BuildPatchPayload(IDictionary<string, object?> changed, List<FieldDef> defs, PatchIdent ident, IDictionary<string, object?> all)
    {
        var p = new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(),
            ["bookingNo"] = ident.BookingNo.Trim(),
            ["moduleTypeCode"] = ident.Module,
            ["boundTypeCode"] = ident.Bound == "Import" ? "I" : "O",
        };
        var defByCode = new Dictionary<string, FieldDef>(); foreach (var d in defs) defByCode[d.Code] = d;
        var party = new JsonObject(); var flex = new JsonObject(); var sent = new List<object>();
        foreach (var code in changed.Keys)
        {
            if (!defByCode.TryGetValue(code, out var d)) continue;
            var wk = d.WriteKey.Trim(); if (wk == "") continue;   // read-only field (no write key) - never pushed
            var val = changed[code];
            if (d.Kind == "table")
            {
                var bc = new JsonArray();
                foreach (var r in AsRows(val))
                {
                    var cno = RowV(r, "container_no").Trim(); var tp = RowV(r, "cont_type").Trim();
                    if (cno == "" && tp == "") continue;   // need a container no. OR a type (booking-stage count row)
                    var item = new JsonObject();
                    if (cno != "") item["containerNo"] = cno;
                    if (tp != "") item["containerTypeCode"] = tp;
                    var sl = RowV(r, "seal_no").Trim(); if (sl != "") item["sealNo"] = sl;
                    if (int.TryParse(RowV(r, "qty").Trim(), out var q) && q > 0) item["quantity"] = q;
                    var u = RowV(r, "qty_unit").Trim(); if (u != "") item["quantityUnit"] = u;
                    if (double.TryParse(RowV(r, "weight").Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out var w) && w > 0) item["weight"] = w;
                    if (double.TryParse(RowV(r, "cbm").Trim(), NumberStyles.Any, CultureInfo.InvariantCulture, out var cb) && cb > 0) item["cbm"] = cb;
                    bc.Add(item);
                }
                p[wk] = bc;
                sent.Add(new { field = code, writeKey = wk, value = $"{bc.Count} container row(s)" });
                continue;
            }
            // ETD + flight time fold into one departureDateEstimated datetime "<yyyy-mm-dd>T<hh:mm>"
            if (wk == "departureDateEstimated")
            {
                if (p.ContainsKey("departureDateEstimated")) continue;
                string dt = "", tm = "";
                if (all != null) { if (all.TryGetValue("etd", out var ev)) dt = (ev?.ToString() ?? "").Trim(); if (all.TryGetValue("flight_time", out var fv)) tm = (fv?.ToString() ?? "").Trim(); }
                if (dt == "") dt = (val?.ToString() ?? "").Trim();
                var dval = dt != "" && tm != "" ? $"{dt}T{tm}" : dt;
                p["departureDateEstimated"] = dval;
                sent.Add(new { field = code, writeKey = wk, value = dval });
                continue;
            }
            if (d.Kind == "bool")
            {
                var bv = new[] { "true", "1", "y", "yes" }.Contains((val?.ToString() ?? "").Trim().ToLowerInvariant());
                if (Regex.IsMatch(wk, "Party")) party[wk] = bv; else p[wk] = bv;
                sent.Add(new { field = code, writeKey = wk, value = bv ? "True" : "False" });
                continue;
            }
            if (d.Kind == "number")
            {
                var sv = (val?.ToString() ?? "").Trim(); JsonNode? num = null;
                if (sv != "" && double.TryParse(sv, NumberStyles.Any, CultureInfo.InvariantCulture, out var dd))
                    num = dd == Math.Floor(dd) ? (JsonNode)(long)dd : (JsonNode)dd;
                if (Regex.IsMatch(wk, "Party")) party[wk] = num; else p[wk] = num;
                sent.Add(new { field = code, writeKey = wk, value = num?.ToString() ?? "" });
                continue;
            }
            if (wk.StartsWith("bookingReference#"))
            {
                var refName = wk.Substring("bookingReference#".Length);
                p["bookingReference"] = new JsonArray(new JsonObject { ["refName"] = refName, ["refDescription"] = val?.ToString() ?? "" });
                sent.Add(new { field = code, writeKey = wk, value = val?.ToString() ?? "" });
                continue;
            }
            var svs = val?.ToString() ?? "";
            var fm = Regex.Match(wk, @"^flexData\.(.+)$");
            if (fm.Success) { flex[fm.Groups[1].Value] = svs; sent.Add(new { field = code, writeKey = wk, value = svs }); continue; }
            if (Regex.IsMatch(wk, "Party")) party[wk] = svs; else p[wk] = svs;
            sent.Add(new { field = code, writeKey = wk, value = svs });
        }
        // AIR ONLY: the ERP keys the AWB on houseNo + masterNo as a PAIR. Submitting only one (e.g. a MAWB change
        // with the HAWB omitted) makes it treat the write as a different job -> "job duplicate" error. So when EITHER
        // is being changed, send BOTH - the unchanged one at its current value (from `all`, the live-seeded form set).
        if (ident.Module == "AIR" && (changed.ContainsKey("bl_no") || changed.ContainsKey("master_no")) && all != null)
        {
            if (!p.ContainsKey("houseNo")) { var hv = (all.TryGetValue("bl_no", out var h) ? h?.ToString() : "")?.Trim() ?? ""; if (hv != "") { p["houseNo"] = hv; sent.Add(new { field = "bl_no", writeKey = "houseNo", value = hv + " (paired)" }); } }
            if (!p.ContainsKey("masterNo")) { var mv = (all.TryGetValue("master_no", out var m) ? m?.ToString() : "")?.Trim() ?? ""; if (mv != "") { p["masterNo"] = mv; sent.Add(new { field = "master_no", writeKey = "masterNo", value = mv + " (paired)" }); } }
        }
        // forwarderPartyCode (owncode) is REQUIRED by the NewBooking schema and routes the write to the right
        // office - always send it, even when no party field was edited.
        var fwd = ident.ForwarderCode.Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        if (fwd != "") { party["forwarderPartyCode"] = fwd; sent.Add(new { field = "_forwarder", writeKey = "bookingParty.forwarderPartyCode", value = fwd }); }
        if (party.Count > 0) p["bookingParty"] = party;
        if (flex.Count > 0) p["flexData"] = flex;
        return (p, sent);
    }

    public sealed record PushResult(bool Ok, bool Mock, bool Rejected, List<string> Steps, string Error);

    // Push the prebuilt patch payload. Read-merge-write existence guard (/booking/get first, abort if absent so the
    // update can never CREATE a duplicate), read-merge the NewBooking-required keys the patch omits, then update.
    // Honors bookingUpdateMode (best-effort logs an ERP rejection; strict reports it). Mirrors Invoke-ErpEditPush.
    public static PushResult EditPush(JsonObject payload, string bookingNo, string module, string by, string forwarderCode)
    {
        if (MockMode())
        {
            try
            {
                MockWrite($"erp-edit-{Regex.Replace(bookingNo, @"[^A-Za-z0-9_-]", "_")}-{DateTime.Now:yyyyMMddHHmmss}.json",
                    new JsonObject { ["at"] = DateTime.Now.ToString("o"), ["editedBy"] = by, ["booking"] = payload.DeepClone() });
                return new(true, true, false, new() { "booking/update (mock)" }, "");
            }
            catch (Exception ex) { return new(false, true, false, new(), "mock edit failed: " + ex.Message); }
        }
        // one correlation scope: the /booking/get + /booking/update of this edit share a corr id, attributed to the
        // editor + booking, so the admin ERP API tab shows them as one operation.
        using var _erpScope = ErpLog.Begin(by, "", bookingNo);
        var cur = BookingGet(bookingNo, module, forwarderCode);
        if (cur == null) return new(false, false, false, new(), $"booking '{bookingNo}' ({module}) not found via /booking/get - aborting so the update cannot create a new booking. Check partyGroupCode/forwarderCode (owncode) in erp-api-map.json and the booking number.");
        var bestEffort = ErpMap.Str("bookingUpdateMode").Trim().ToLowerInvariant() == "best-effort";
        var steps = new List<string> { "booking/get ok (exists)" };
        var mergeKeys = new List<string> { "serviceCode", "commodity", "portOfLoadingCode", "portOfLoadingName", "portOfDischargeCode", "portOfDischargeName" };
        // SEA ONLY: a Sea booking carrying container lines must also carry its Liner (carrier). If bookingContainers
        // is sent but carrierCode is omitted, the ERP blanks the carrier and rejects with (500) "Liner cannot be
        // blank". Read-merge the EXISTING carrier (already an accepted value on this booking) ONLY in the Sea
        // container case, so non-container edits stay on the proven path and we never push a fresh/raw carrier code
        // the carrier master would reject. Air has no container table (bookingContainers is never present) and must
        // not get this merge - gate on the module explicitly.
        if (module == "SEA" && payload.ContainsKey("bookingContainers")) { mergeKeys.Add("carrierCode"); mergeKeys.Add("carrierName"); }
        foreach (var k in mergeKeys)
            if (!payload.ContainsKey(k)) { var v = StrProp(cur, k).Trim(); if (v != "") payload[k] = v; }
        // AIR ONLY: the ERP writes the air detail line (awbdetl: mark2/desc2/good_desc2/rece_cbm) as a UNIT - it
        // persists shipMarks/goodsDescription/commodity/cbm ONLY when the FULL cargo block is present in the payload.
        // A minimal patch that omits qty/unit/weight is silently dropped on the detail line (verified live: the same
        // marks/desc that vanished on a partial push persisted once quantity/quantityUnit/grossWeight/weightUnit were
        // included). Read-merge the whole cargo block from the current booking, preserving JSON number types (a
        // DeepClone is required - PropCI returns a node still parented to `cur`). Gate on module: Sea writes its
        // detail via bookingContainers, not this block.
        if (module == "AIR")
            foreach (var k in new[] { "quantity", "quantityUnit", "grossWeight", "weightUnit", "cbm", "shipMarks", "goodsDescription", "isConsole" })
                if (!payload.ContainsKey(k)) { var node = PropCI(cur, k); if (node != null) payload[k] = node.DeepClone(); }
        try { Call("/booking/update", payload); steps.Add("booking/update ok"); return new(true, false, false, steps, ""); }
        catch (Exception ex)
        {
            var msg = ex.Message;
            if (bestEffort) { steps.Add("booking/update REJECTED by ERP validation (best-effort): " + msg); return new(true, false, true, steps, ""); }
            return new(false, false, false, steps, "booking/update failed: " + msg);
        }
    }

    // ============================================================================================================
    // BOOK NOW - create a brand-new booking from minimal operator input. Same /booking/update endpoint ("New
    // Booking / Update Booking"), but DELIBERATELY omits bookingNo so the ERP AUTO-GENERATES it, and skips the
    // /booking/get existence guard EditPush uses (here we WANT a create, not a merge). forwarderPartyCode (owncode)
    // routes it to the right office; partyGroupCode + serviceCode + commodity + POL/POD are the NewBooking-required
    // set, supplied by the form (no live booking to read-merge from).
    // ============================================================================================================
    public sealed record NewBookingInput(
        string Module, string Bound, string ForwarderCode,
        string PolCode, string PolName, string PodCode, string PodName,
        string ServiceCode, string Incoterm, string Commodity,
        string CargoReady, string Etd,
        string Quantity, string QuantityUnit, string GrossWeight, string Cbm,
        string Container20, string Container40, string ContainerHQ, string ContainerOthers,
        string ShipperCode, string ShipperName, string ConsigneeCode, string ConsigneeName,
        string Remark, string RefNo);

    public static JsonObject BuildNewBookingPayload(NewBookingInput b)
    {
        var p = new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(),
            ["moduleTypeCode"] = b.Module,
            ["boundTypeCode"] = b.Bound == "Import" ? "I" : "O",
        };
        void Str(string k, string? v) { if (!string.IsNullOrWhiteSpace(v)) p[k] = v!.Trim(); }
        JsonNode? Numv(string? v)
        {
            var s = (v ?? "").Trim();
            if (s != "" && double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out var d))
                return d == Math.Floor(d) ? (JsonNode)(long)d : (JsonNode)d;
            return null;
        }
        void Num(string k, string? v) { var n = Numv(v); if (n != null) p[k] = n; }
        void Count(string k, string? v)   // container counts: skip blanks AND zeros (keep the payload minimal)
        {
            var s = (v ?? "").Trim();
            if (s != "" && double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out var d) && d != 0)
                p[k] = d == Math.Floor(d) ? (JsonNode)(long)d : (JsonNode)d;
        }

        Str("serviceCode", b.ServiceCode);
        Str("incoTermsCode", b.Incoterm);
        Str("commodity", b.Commodity);
        Str("portOfLoadingCode", b.PolCode);
        Str("portOfLoadingName", b.PolName);
        Str("portOfDischargeCode", b.PodCode);
        Str("portOfDischargeName", b.PodName);
        Str("cargoReadyDateEstimated", b.CargoReady);
        Str("departureDateEstimated", b.Etd);
        Num("quantity", b.Quantity);
        Str("quantityUnit", b.QuantityUnit);
        Num("grossWeight", b.GrossWeight);
        Num("cbm", b.Cbm);
        if (b.Module == "SEA")
        {
            Count("container20", b.Container20);
            Count("container40", b.Container40);
            Count("containerHQ", b.ContainerHQ);
            Count("containerOthers", b.ContainerOthers);
        }
        Str("remark", b.Remark);
        if (!string.IsNullOrWhiteSpace(b.RefNo))
            p["bookingReference"] = new JsonArray(new JsonObject { ["refName"] = "Shipment Reference ID", ["refDescription"] = b.RefNo.Trim() });

        var party = new JsonObject();
        var fwd = (b.ForwarderCode ?? "").Trim(); if (fwd == "") fwd = ErpMap.Str("forwarderCode").Trim();
        if (fwd != "") party["forwarderPartyCode"] = fwd;
        if (!string.IsNullOrWhiteSpace(b.ShipperCode)) party["shipperPartyCode"] = b.ShipperCode!.Trim();
        if (!string.IsNullOrWhiteSpace(b.ShipperName)) party["shipperPartyName"] = b.ShipperName!.Trim();
        if (!string.IsNullOrWhiteSpace(b.ConsigneeCode)) party["consigneePartyCode"] = b.ConsigneeCode!.Trim();
        if (!string.IsNullOrWhiteSpace(b.ConsigneeName)) party["consigneePartyName"] = b.ConsigneeName!.Trim();
        if (party.Count > 0) p["bookingParty"] = party;
        return p;
    }

    public sealed record CreateResult(bool Ok, bool Mock, string BookingNo, string Error, List<string> Steps);

    // Push a new-booking create. NO /booking/get guard (the point is to create). Returns the ERP-assigned bookingNo
    // when the response echoes one. Mock mode writes erp-mock/book-now-*.json and returns a synthetic number.
    public static CreateResult CreateBookingPush(JsonObject payload, string refNo, string by, string station)
    {
        if (MockMode())
        {
            try
            {
                var bn = "MOCK-" + (refNo != "" ? refNo : DateTime.Now.ToString("yyyyMMddHHmmss"));
                MockWrite($"book-now-{Regex.Replace(refNo != "" ? refNo : bn, @"[^A-Za-z0-9_-]", "_")}-{DateTime.Now:yyyyMMddHHmmss}.json",
                    new JsonObject { ["at"] = DateTime.Now.ToString("o"), ["createdBy"] = by, ["station"] = station, ["mockBookingNo"] = bn, ["booking"] = payload.DeepClone() });
                return new(true, true, bn, "", new() { "booking/update (mock create)" });
            }
            catch (Exception ex) { return new(false, true, "", "mock create failed: " + ex.Message, new()); }
        }
        using var _erpScope = ErpLog.Begin(by, station, refNo);
        try
        {
            var resp = Call("/booking/update", payload);
            return new(true, false, ExtractBookingNo(resp), "", new() { "booking/update ok (created)" });
        }
        catch (Exception ex) { return new(false, false, "", "booking/update failed: " + ex.Message, new()); }
    }

    // Pull the ERP-assigned bookingNo out of a /booking/update response (bare object/array, or nested under
    // message/data). Returns "" when the ERP doesn't echo one (the caller then reports "created, number pending").
    static string ExtractBookingNo(JsonNode? resp)
    {
        foreach (var el in AsArray(resp))
        {
            var v = StrProp(el, "bookingNo").Trim(); if (v != "") return v;
            foreach (var c in new[] { PropCI(el, "message"), PropCI(el, "data") })
                foreach (var x in AsArray(c)) { var w = StrProp(x, "bookingNo").Trim(); if (w != "") return w; }
        }
        return "";
    }
}
