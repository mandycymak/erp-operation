using System.Text.Json.Nodes;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// Draft-document ERP push (port of erp-doc-api.ps1 agree/issue path). AGREE writes the agreed booking data
// (read-merge-write /booking/update); ISSUE uploads the agreed PDF + rider files (/file/upload), stamps the
// event (/event/update), optionally generates the official document. Mock mode writes erp-mock/*.json instead.
public static partial class Erp
{
    // ---- field accessors over the doc_version.fields object (or a rider-page row object) ----
    static string FV(JsonNode? obj, string code)
    {
        var v = (obj as JsonObject)?[code];
        return v is JsonValue ? v.ToString() : "";
    }
    static IEnumerable<JsonObject> FRows(JsonNode? fields, string code)
    {
        if ((fields as JsonObject)?[code] is JsonArray a)
            foreach (var x in a) if (x is JsonObject o) yield return o;
    }

    // first line of a multi-line box = the party NAME, the rest = the ADDRESS
    static (string Name, string Addr) SplitParty(string text)
    {
        var t = (text ?? "").Replace("\r", "").Trim();
        if (t == "") return ("", "");
        var lines = t.Split('\n');
        return (lines[0].Trim(), string.Join("\n", lines.Skip(1)).Trim());
    }

    // merge the Qty column into the description, line by line (packing-list style); column-aligned
    static string MergeQtyDesc(string qty, string desc)
    {
        var dt = (desc ?? "").Replace("\r", "");
        if ((qty ?? "").Trim() == "") return dt.Trim();
        var q = (qty ?? "").Replace("\r", "").Split('\n'); var d = dt.Split('\n');
        int w = 0; foreach (var x in q) { var L = x.TrimEnd().Length; if (L > w) w = L; }
        int n = Math.Max(q.Length, d.Length); var outl = new List<string>();
        for (int i = 0; i < n; i++)
        {
            var qv = i < q.Length ? q[i].TrimEnd() : "";
            var dv = i < d.Length ? d[i].TrimEnd() : "";
            outl.Add((qv.PadRight(w + 1) + dv).TrimEnd());
        }
        return string.Join("\n", outl).Trim();
    }

    // shipMarks / goodsDescription: the on-bill boxes (when real text, not the pointer) + every rider page
    static (string Marks, string Goods) BuildMarksGoods(JsonNode? fields)
    {
        const string ptr = "AS PER ATTACHED SHEET";
        var units = new List<(string m, string q, string d)>();
        var bm = FV(fields, "marks_numbers"); var bq = FV(fields, "qty_detail"); var bd = FV(fields, "description");
        if (bm.Trim() == ptr) bm = "";
        if (bd.Trim() == ptr) bd = "";
        if (bm.Trim() != "" || bq.Trim() != "" || bd.Trim() != "") units.Add((bm, bq, bd));
        foreach (var pg in FRows(fields, "rider_pages")) units.Add((FV(pg, "marks"), FV(pg, "qty"), FV(pg, "description")));
        var marks = new List<string>(); var goods = new List<string>();
        foreach (var u in units)
        {
            var mv = u.m.Replace("\r", "").Trim(); if (mv != "") marks.Add(mv);
            var gv = MergeQtyDesc(u.q, u.d); if (gv != "") goods.Add(gv);
        }
        return (string.Join("\n", marks), string.Join("\n", goods));
    }

    static string SA(Row sa, string c) => Db.Str(Db.G(sa, c)).Trim();

    // Build the /booking/update payload from the doc head + agreed fields + the shipment snapshot row.
    static JsonObject BuildBookingPayload(Row head, JsonNode? fields, Row sa)
    {
        var isAir = Db.Str(Db.G(head, "doc_type")) == "HAWB";
        var houseNo = isAir ? FV(fields, "hawb_no") : FV(fields, "hbl_no");
        var (mMarks, mGoods) = isAir ? ("", "") : BuildMarksGoods(fields);
        var goods = isAir ? FV(fields, "nature_quantity_goods") : mGoods;
        var commodity = SA(sa, "commodity");
        if (commodity == "" && goods.Trim() != "") commodity = goods.Replace("\r", "").Split('\n')[0].Trim();
        if (commodity == "") commodity = ErpMap.Str("commodityFallback").Trim();
        if (commodity.Length > 21) commodity = commodity.Substring(0, 21);   // spec maxLength=21
        var p = new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(),
            ["bookingNo"] = SA(sa, "sono") != "" ? SA(sa, "sono") : Db.Str(Db.G(head, "job_no")),
            ["houseNo"] = houseNo,
            ["masterNo"] = isAir ? FV(fields, "mawb_no") : SA(sa, "master_bill"),
            ["moduleTypeCode"] = isAir ? "AIR" : "SEA",
            ["boundTypeCode"] = Db.Str(Db.G(head, "bound")) == "Import" ? "I" : "O",
            ["serviceCode"] = ErpMap.Str("serviceCodeDefault").Trim(),
            ["commodity"] = commodity,
            ["shipMarks"] = isAir ? FV(fields, "marks_numbers") : mMarks,
            ["goodsDescription"] = goods,
            ["portOfLoadingCode"] = SA(sa, "pol"),
            ["portOfLoadingName"] = isAir ? FV(fields, "airport_departure") : FV(fields, "port_of_loading"),
            ["portOfDischargeCode"] = SA(sa, "pod"),
            ["portOfDischargeName"] = isAir ? FV(fields, "airport_destination") : FV(fields, "port_of_discharge"),
        };
        // container particulars -> bookingContainers
        var bc = new JsonArray();
        foreach (var r in FRows(fields, "containers"))
        {
            var cno = FV(r, "container_no").Trim(); if (cno == "") continue;
            var item = new JsonObject { ["containerNo"] = cno };
            var sl = FV(r, "seal_no").Trim(); if (sl != "") item["sealNo"] = sl;
            var tp = FV(r, "cont_type").Trim(); if (tp != "") item["containerTypeCode"] = tp;
            if (int.TryParse(FV(r, "qty").Trim(), out var q) && q > 0) item["quantity"] = q;
            bc.Add(item);
        }
        if (bc.Count > 0) p["bookingContainers"] = bc;
        // address blocks: bookingParty uses FLAT prefixed keys (shipperPartyName/-Address, notifyPartyParty...)
        var party = new JsonObject();
        var pairs = new[] { ("shipper", "shipperParty"), ("consignee", "consigneeParty"), ("notify", "notifyPartyParty") };
        foreach (var (box, prefix) in pairs)
        {
            if (isAir && box == "notify") continue;   // HAWB layout has no notify box
            var (name, addr) = SplitParty(FV(fields, box));
            if (name != "") { party[prefix + "Name"] = name; if (addr != "") party[prefix + "Address"] = addr; }
        }
        if (party.Count > 0) p["bookingParty"] = party;
        ApplyOverrides(p, fields, sa, null);
        return p;
    }

    // declarative last-step overrides from erp-api-map.json: 'field:<code>' | 'sa:<col>' | 'const:<literal>'.
    // onlyTerms (non-null) restricts to serviceCode/incoTermsCode/freightTermsCode (the agree post-echo re-apply).
    static void ApplyOverrides(JsonObject p, JsonNode? fields, Row sa, string[]? onlyTerms)
    {
        if (ErpMap.Get()["bookingOverrides"] is not JsonObject ov) return;
        foreach (var kv in ov)
        {
            if (onlyTerms != null && !onlyTerms.Contains(kv.Key)) continue;
            var spec = kv.Value?.ToString() ?? "";
            string v = spec.StartsWith("field:") ? FV(fields, spec.Substring(6))
                     : spec.StartsWith("sa:") ? SA(sa, spec.Substring(3))
                     : spec.StartsWith("const:") ? spec.Substring(6)
                     : spec;
            p[kv.Key] = v;
        }
    }

    public sealed record AgreeResult(bool Ok, bool Mock, bool Rejected, List<string> Steps, string Error);

    // AGREE: save the agreed booking data (read-merge-write). Mirrors Invoke-ErpDocAgree.
    public static AgreeResult DocAgree(Row head, JsonNode? fields, Row? sa, string by)
    {
        var mock = MockMode();
        if (sa == null) return new(false, mock, false, new(), "shipment snapshot row not found - cannot build the booking payload");
        var isAir = Db.Str(Db.G(head, "doc_type")) == "HAWB";
        var houseNo = isAir ? FV(fields, "hawb_no") : FV(fields, "hbl_no");
        if (houseNo.Trim() == "") return new(false, mock, false, new(), $"the {Db.Str(Db.G(head, "doc_type"))} number box is empty - fill it in before agreeing");
        var booking = BuildBookingPayload(head, fields, sa);
        if (mock)
        {
            try
            {
                MockWrite($"agree-{Db.Str(Db.G(head, "doc_id"))}.json", new JsonObject { ["at"] = DateTime.Now.ToString("o"), ["agreedBy"] = by, ["docId"] = Db.Str(Db.G(head, "doc_id")), ["jobNo"] = Db.Str(Db.G(head, "job_no")), ["booking"] = booking.DeepClone(), ["fields"] = fields?.DeepClone() });
                return new(true, true, false, new() { "booking/update (mock)" }, "");
            }
            catch (Exception ex) { return new(false, true, false, new(), "mock agree failed: " + ex.Message); }
        }
        // one correlation scope: the /booking/get + /booking/update of this agree share a corr id, attributed to the
        // agreeing user + booking, so the admin ERP API tab shows them as one operation.
        using var _erpScope = ErpLog.Begin(by, SA(sa, "station"), booking["bookingNo"]?.ToString() ?? "");
        // READ-MERGE-WRITE: fetch the live booking first; abort if absent (no duplicate create). Echo serviceCode +
        // the terms codes from the live booking (presentation-only draft boxes must never change them).
        var cur = BookingGet(booking["bookingNo"]!.ToString(), booking["moduleTypeCode"]!.ToString(), "");
        if (cur == null) return new(false, false, false, new(), $"booking '{booking["bookingNo"]}' ({booking["moduleTypeCode"]}) not found via /booking/get - aborting so the update cannot create a new booking. Check partyGroupCode/forwarderCode in erp-api-map.json and the booking number.");
        if (StrProp(cur, "serviceCode").Trim() != "") booking["serviceCode"] = StrProp(cur, "serviceCode").Trim();
        if (StrProp(cur, "incoTermsCode").Trim() != "") booking["incoTermsCode"] = StrProp(cur, "incoTermsCode").Trim();
        if (StrProp(cur, "freightTermsCode").Trim() != "") booking["freightTermsCode"] = StrProp(cur, "freightTermsCode").Trim();
        ApplyOverrides(booking, fields, sa, new[] { "serviceCode", "incoTermsCode", "freightTermsCode" });
        // AIR: the ERP writes the detail line (awbdetl: mark2/desc2/good_desc2/rece_cbm) only when the FULL cargo
        // block is present - the doc boxes carry marks/desc/commodity but not the cargo numbers, so read-merge
        // qty/unit/weight/cbm from the live booking (same fix as EditPush). Preserve JSON number types (DeepClone -
        // PropCI returns a node parented to `cur`).
        if (booking["moduleTypeCode"]?.ToString() == "AIR")
            foreach (var k in new[] { "quantity", "quantityUnit", "grossWeight", "weightUnit", "cbm", "isConsole" })
                if (!booking.ContainsKey(k)) { var node = PropCI(cur, k); if (node != null) booking[k] = node.DeepClone(); }
        var missing = new[] { "partyGroupCode", "bookingNo", "serviceCode", "commodity", "portOfLoadingCode", "portOfLoadingName", "portOfDischargeCode", "portOfDischargeName" }
            .Where(k => (booking[k]?.ToString() ?? "").Trim() == "").ToList();
        if (missing.Count > 0) return new(false, false, false, new() { "booking/get ok" }, $"booking/update payload incomplete: {string.Join(", ", missing)} - check erp-api-map.json (partyGroupCode/serviceCodeDefault) and the shipment data");
        var bestEffort = ErpMap.Str("bookingUpdateMode").Trim().ToLowerInvariant() == "best-effort";
        var steps = new List<string> { "booking/get ok (exists, serviceCode + terms echoed)" };
        try { Call("/booking/update", booking); steps.Add("booking/update ok"); return new(true, false, false, steps, ""); }
        catch (Exception ex)
        {
            var msg = ex.Message;
            if (bestEffort) { steps.Add("booking/update REJECTED by ERP validation (best-effort): " + msg); return new(true, false, true, steps, ""); }
            return new(false, false, false, steps, "booking/update failed: " + msg);
        }
    }

    public sealed record IssueResult(bool Ok, string DocNo, bool Mock, List<string> Steps, string Error);
    public sealed record DocFile(string Name, string Base64);

    // ISSUE: upload files (agreed PDF + rider attachments) + stamp the event (+ optional generate).
    // Mirrors Invoke-ErpDocIssue. attachment = optional operator-attached agreed PDF; riders = live doc_attachment rows.
    public static IssueResult DocIssue(Row head, JsonNode? fields, Row? sa, string by, DocFile? attachment, List<DocFile> riders)
    {
        var mock = MockMode();
        if (sa == null) return new(false, "", mock, new(), "shipment snapshot row not found");
        var docType = Db.Str(Db.G(head, "doc_type"));
        var isAir = docType == "HAWB";
        var houseNo = isAir ? FV(fields, "hawb_no") : FV(fields, "hbl_no");
        if (houseNo.Trim() == "") return new(false, "", mock, new(), $"the {docType} number box is empty - fill it in before issuing");
        var bookingNo = SA(sa, "sono") != "" ? SA(sa, "sono") : Db.Str(Db.G(head, "job_no"));
        var module = isAir ? "AIR" : "SEA";
        var fwd = Source.ForwarderCode(Db.Str(Db.G(sa, "station")));
        var dtc = ((ErpMap.Get()["documentTypeCode"] as JsonObject)?[docType]?.ToString() ?? "").Trim();
        var evStatus = ((ErpMap.Get()["event"] as JsonObject)?["status"]?.ToString() ?? "").Trim(); if (evStatus == "") evStatus = "transportBill";
        var ver = Db.IntOf(Db.G(head, "current_version"));
        var amend = Db.IntOf(Db.G(head, "amend_count"));
        var files = new List<DocFile>();
        if (attachment != null && attachment.Base64.Trim() != "") files.Add(attachment);
        foreach (var ra in riders) if (ra != null && ra.Base64.Trim() != "") files.Add(ra);
        var evPayload = new JsonObject
        {
            ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(),
            ["moduleTypeCode"] = module,
            ["houseNo"] = houseNo,
            ["bookingNo"] = bookingNo,
            ["status"] = evStatus,
            ["isEstimated"] = false,
            ["statusDate"] = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            ["statusDescription"] = (ErpMap.Get()["event"] as JsonObject)?["description"]?.ToString() ?? "",
            ["remark"] = $"Customer-agreed draft v{ver} issued by {by}" + (amend > 0 ? $" (amendment #{amend}, fee applies)" : ""),
        };
        JsonObject? generate = null;
        if (Truthy(ErpMap.Get()["generateDocument"]))
            generate = new JsonObject { ["partyGroupCode"] = ErpMap.Str("partyGroupCode").Trim(), ["forwarderCode"] = fwd, ["moduleTypeCode"] = module, ["documentTypeCode"] = dtc, ["bookingNo"] = bookingNo, ["houseBillNo"] = houseNo };
        if (mock)
        {
            try
            {
                var fmock = new JsonArray();
                foreach (var fl in files) fmock.Add(new JsonObject { ["name"] = fl.Name, ["bytes"] = (int)Math.Ceiling(fl.Base64.Length * 0.75), ["remark"] = fl.Name });
                MockWrite($"issue-{Db.Str(Db.G(head, "doc_id"))}.json", new JsonObject { ["at"] = DateTime.Now.ToString("o"), ["issuedBy"] = by, ["docId"] = Db.Str(Db.G(head, "doc_id")), ["jobNo"] = Db.Str(Db.G(head, "job_no")), ["files"] = fmock, ["event"] = evPayload.DeepClone(), ["generate"] = generate?.DeepClone(), ["fields"] = fields?.DeepClone() });
                var st = new List<string>(); foreach (var fl in files) st.Add($"file/upload (mock): {fl.Name}"); st.Add("event/update (mock)"); if (generate != null) st.Add("document/generate (mock)");
                return new(true, houseNo, true, st, "");
            }
            catch (Exception ex) { return new(false, "", true, new(), "mock issue failed: " + ex.Message); }
        }
        // one correlation scope for the whole issue (uploads + event + optional generate), attributed to the issuer.
        using var _erpScope = ErpLog.Begin(by, SA(sa, "station"), bookingNo);
        var steps = new List<string>();
        foreach (var fl in files)
        {
            var remark = fl == attachment ? $"Customer-agreed {docType} v{ver}" : $"Rider attachment for {docType} v{ver}";
            var up = FileUpload(module, houseNo, bookingNo, dtc, fl.Name, fl.Base64, remark, fwd);
            if (!up.Ok) return new(false, "", false, steps, $"file/upload failed for {fl.Name}: {up.Error}");
            steps.Add($"file/upload ok: {fl.Name}");
        }
        try { Call("/event/update", evPayload); steps.Add($"event/update ok ({evStatus})"); }
        catch (Exception ex) { return new(false, "", false, steps, "event/update failed: " + ex.Message); }
        if (generate != null)
        {
            try { Call("/document/generate", generate); steps.Add("document/generate ok"); }
            catch (Exception ex) { return new(false, "", false, steps, "document/generate failed (files + event were saved): " + ex.Message); }
        }
        return new(true, houseNo, false, steps, "");
    }

    static bool Truthy(JsonNode? v)
    {
        if (v is not JsonValue jv) return false;
        if (jv.TryGetValue<bool>(out var b)) return b;
        var s = jv.ToString().Trim().ToLowerInvariant();
        return s is "true" or "1" or "y" or "yes";
    }
}
