using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

// Draft-document review helpers (serve-ops.ps1 doc-* subsystem). Status machine:
//   DRAFT -send-> SENT -submit-> CUSTOMER_SUBMITTED -staff save-> DRAFT (resend v+1)
//                   \-approve-> CUSTOMER_APPROVED -agree-> AGREED -issue-> ISSUED
//   ISSUED -amend(amend_count++, fee)-> AMEND_DRAFT -> (cycle repeats) -> ISSUED
// All state in pgsops doc_* tables; every action appended to doc_event_log. Raw tokens never stored (SHA-256).
public static partial class Doc
{
    // ---- tokens ----
    public static string NewRawToken()
    {
        var b = new byte[32];
        using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(b);
        return Convert.ToBase64String(b).Replace('+', '-').Replace('/', '_').TrimEnd('=');   // base64url, 43 chars
    }
    public static string TokenHash(string raw)
    {
        using var sha = SHA256.Create();
        return Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(raw ?? ""))).ToLowerInvariant();
    }

    // ---- event log ----
    public static void Event(SqlConnection cn, string docId, int? ver, string evt, string actor, string? tokenHash, string ip, string? detail)
        => Db.Exec(cn, "INSERT INTO dbo.doc_event_log(doc_id,version_no,event,actor,token_hash,ip,detail,occurred_at) VALUES(@d,@v,@e,@a,@t,@i,@x,SYSDATETIME())",
            new Dictionary<string, object?> { ["d"] = docId, ["v"] = ver, ["e"] = evt, ["a"] = actor, ["t"] = tokenHash, ["i"] = ip, ["x"] = detail });

    // ---- head read (scope-gated: out-of-scope = not found) ----
    public const string HeadCols = "doc_id,job_no,doc_type,station,mode,bound,status,current_version,customer_email,customer_name,erp_doc_no,CONVERT(varchar(19),issued_at,120) issued_at,amend_count,created_by,CONVERT(varchar(19),created_at,120) created_at,CONVERT(varchar(19),updated_at,120) updated_at";
    public static Row? GetHead(SqlConnection cn, string docId, ReqState rs)
    {
        var r = Db.RunQ(cn, $"SELECT TOP 1 {HeadCols} FROM dbo.doc_draft WHERE doc_id=@d", new Dictionary<string, object?> { ["d"] = docId });
        if (r.Count == 0) return null;
        if (!Scope.TestJobScope(rs, r[0])) return null;
        return r[0];
    }

    public static object HeadProj(SqlConnection cn, Row h)
    {
        var tok = Db.RunQ(cn, "SELECT TOP 1 customer_email,customer_name,CONVERT(varchar(16),expires_at,120) expires_at,view_count,CONVERT(varchar(16),last_view_at,120) last_view_at FROM dbo.doc_review_token WHERE doc_id=@d AND revoked=0 AND expires_at>SYSDATETIME() ORDER BY created_at DESC",
            new Dictionary<string, object?> { ["d"] = Db.Str(Db.G(h, "doc_id")) });
        object? t = null;
        if (tok.Count > 0)
            t = new { customerEmail = Db.Str(Db.G(tok[0], "customer_email")), customerName = Db.Str(Db.G(tok[0], "customer_name")), expiresAt = Db.Str(Db.G(tok[0], "expires_at")), viewCount = Db.IntOf(Db.G(tok[0], "view_count")), lastViewAt = Db.Str(Db.G(tok[0], "last_view_at")) };
        return new
        {
            docId = Db.Str(Db.G(h, "doc_id")), jobNo = Db.Str(Db.G(h, "job_no")), docType = Db.Str(Db.G(h, "doc_type")), station = Db.Str(Db.G(h, "station")),
            status = Db.Str(Db.G(h, "status")), currentVersion = Db.IntOf(Db.G(h, "current_version")), customerEmail = Db.Str(Db.G(h, "customer_email")), customerName = Db.Str(Db.G(h, "customer_name")),
            erpDocNo = Db.Str(Db.G(h, "erp_doc_no")), issuedAt = Db.Str(Db.G(h, "issued_at")), amendCount = Db.IntOf(Db.G(h, "amend_count")),
            createdBy = Db.Str(Db.G(h, "created_by")), createdAt = Db.Str(Db.G(h, "created_at")), updatedAt = Db.Str(Db.G(h, "updated_at")), activeToken = t,
        };
    }

    // the 'back to editing' status: plain DRAFT before first issue, AMEND_DRAFT once an amendment cycle started
    public static string DraftState(Row h) => Db.IntOf(Db.G(h, "amend_count")) > 0 ? "AMEND_DRAFT" : "DRAFT";

    // attachment projection (rider docs uploaded by staff OR customer)
    public static object[] AttachList(SqlConnection cn, string docId)
    {
        var rows = Db.RunQ(cn, "SELECT att_id,file_name,content_type,size_bytes,uploaded_side,uploaded_by,CONVERT(varchar(19),uploaded_at,120) uploaded_at FROM dbo.doc_attachment WHERE doc_id=@d AND deleted=0 ORDER BY uploaded_at", new Dictionary<string, object?> { ["d"] = docId });
        return rows.Select(r => (object)new { id = Db.Str(Db.G(r, "att_id")), name = Db.Str(Db.G(r, "file_name")), contentType = Db.Str(Db.G(r, "content_type")), size = Db.IntOf(Db.G(r, "size_bytes")), side = Db.Str(Db.G(r, "uploaded_side")), by = Db.Str(Db.G(r, "uploaded_by")), at = Db.Str(Db.G(r, "uploaded_at")) }).ToArray();
    }

    // ---- field cleaning (whitelist + clamp against the doc dictionary; table/riders = array-of-rows) ----
    // src is either an IDictionary (server seed) or a JsonElement (client JSON). Returns code -> string | List<rowdict>.
    public static Dictionary<string, object?> CleanFields(string type, object src)
    {
        var o = new Dictionary<string, object?>();
        foreach (var f in DocFields.Defs(type))
        {
            if (f.Kind is "table" or "riders")
            {
                var maxR = f.MaxRows > 0 ? f.MaxRows : 10;
                var rows = new List<Dictionary<string, object?>>();
                foreach (var r in RowsOf(src, f.Code))
                {
                    var rd = new Dictionary<string, object?>();
                    foreach (var col in f.Columns) rd[col.Code] = DocUtil.CleanStr(Cell(r, col.Code), col.MaxLen);
                    if (rd.Values.Any(v => (v as string ?? "").Trim() != "")) rows.Add(rd);
                    if (rows.Count >= maxR) break;
                }
                o[f.Code] = rows;
            }
            else o[f.Code] = DocUtil.CleanStr(ScalarOf(src, f.Code), f.MaxLen);
        }
        return o;
    }

    static object? ScalarOf(object src, string code)
    {
        if (src is IDictionary<string, object?> d) return d.TryGetValue(code, out var v) ? v : null;
        if (src is JsonElement je && je.ValueKind == JsonValueKind.Object && je.TryGetProperty(code, out var p)) return JeScalar(p);
        return null;
    }
    static IEnumerable<object> RowsOf(object src, string code)
    {
        if (src is IDictionary<string, object?> d && d.TryGetValue(code, out var v) && v is System.Collections.IEnumerable en && v is not string)
        { foreach (var r in en) if (r != null && r is not string) yield return r; }
        else if (src is JsonElement je && je.ValueKind == JsonValueKind.Object && je.TryGetProperty(code, out var p) && p.ValueKind == JsonValueKind.Array)
        { foreach (var r in p.EnumerateArray()) if (r.ValueKind == JsonValueKind.Object) yield return r; }
    }
    static object? Cell(object row, string col)
    {
        if (row is IDictionary<string, object?> d) return d.TryGetValue(col, out var v) ? v : null;
        if (row is JsonElement je && je.ValueKind == JsonValueKind.Object && je.TryGetProperty(col, out var p)) return JeScalar(p);
        return null;
    }
    static object? JeScalar(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString(),
        JsonValueKind.Number => v.ToString(),
        JsonValueKind.True => "true",
        JsonValueKind.False => "false",
        _ => null,
    };

    // ---- snapshot seed (always available; no ERP touch) ----
    public static Dictionary<string, object?> SaSeed(Row a, string type)
    {
        var f = new Dictionary<string, object?>();
        string S(string c) => Db.Str(Db.G(a, c));
        if (type == "HBL")
        {
            f["hbl_no"] = S("house_bill"); f["shipper"] = S("shipper_name"); f["consignee"] = S("consignee_name");
            f["export_refs"] = S("cust_ref"); f["vessel_voyage"] = S("vessel_voyage");
            f["port_of_loading"] = S("pol"); f["port_of_discharge"] = S("pod");
            f["freight_terms"] = S("incoterm"); f["date_of_issue"] = Config.TodayStr();
            if (S("total_weight").Trim() != "") f["gross_weight"] = S("total_weight").Trim() + " KGS";
            if (S("total_cbm").Trim() != "") f["measurement"] = S("total_cbm").Trim() + " CBM";
            if (S("container_no").Trim() != "") f["containers"] = new List<Dictionary<string, object?>> { new() { ["container_no"] = S("container_no").Trim() } };
            if (S("commodity").Trim() != "") f["description"] = S("commodity").Trim();
        }
        else
        {
            f["hawb_no"] = S("house_bill"); f["mawb_no"] = S("master_bill");
            f["shipper"] = S("shipper_name"); f["consignee"] = S("consignee_name");
            f["airport_departure"] = S("pol"); f["airport_destination"] = S("pod");
            f["routing_to1"] = S("pod"); f["executed_date"] = Config.TodayStr();
            if (S("total_weight").Trim() != "") f["gross_weight"] = S("total_weight").Trim();
            if (S("commodity").Trim() != "") f["nature_quantity_goods"] = S("commodity").Trim();
        }
        return f;
    }

    // party box text: name on the first line, then address lines (Split-PartyBox reads it back the same way).
    public static string PartyText(object? name, params object?[] adds)
    {
        var ls = new List<string>();
        var nv = (name?.ToString() ?? "").Trim(); if (nv != "") ls.Add(nv);
        foreach (var x in adds) { var xv = (x?.ToString() ?? "").Trim(); if (xv != "" && xv != nv) ls.Add(xv); }
        return string.Join("\n", ls);
    }

    // parse a stored doc_version.fields JSON string back into the same shape CleanFields produces (scalar ->
    // string, table/riders -> List<row dict of string cells>), so DocUtil.Changed compares symmetrically.
    public static Dictionary<string, object?> ParseFields(string json)
    {
        var o = new Dictionary<string, object?>();
        System.Text.Json.Nodes.JsonObject? root = null;
        try { root = System.Text.Json.Nodes.JsonNode.Parse(json ?? "")?.AsObject(); } catch { }
        if (root == null) return o;
        foreach (var kv in root)
        {
            if (kv.Value is System.Text.Json.Nodes.JsonArray a)
            {
                var rows = new List<Dictionary<string, object?>>();
                foreach (var r in a)
                    if (r is System.Text.Json.Nodes.JsonObject ro)
                    {
                        var rd = new Dictionary<string, object?>();
                        foreach (var c in ro) rd[c.Key] = c.Value?.ToString();
                        rows.Add(rd);
                    }
                o[kv.Key] = rows;
            }
            else o[kv.Key] = kv.Value is System.Text.Json.Nodes.JsonValue jv ? jv.ToString() : null;
        }
        return o;
    }

    // carrier code from a flight number: the leading alpha prefix (e.g. 'SQ' from 'SQ7861').
    public static string AwbCarrierFromFlight(object? flight)
    {
        var fl = (flight?.ToString() ?? "").Trim(); if (fl == "") return "";
        var m = System.Text.RegularExpressions.Regex.Match(fl, "^[A-Za-z]+");
        return m.Success ? m.Value.ToUpperInvariant() : "";
    }
}
