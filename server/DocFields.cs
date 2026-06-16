using System.Text.Json.Nodes;

namespace Ops;

// doc-fields.json — the draft HBL/HAWB field dictionary (the edit WHITELIST + maxlen clamp shared by server and
// client). Same shape as erp-edit-fields.json: code/maxlen/kind('table'|'riders' = array-of-rows)/maxRows/columns.
// The client (bl-form.js) renders the on-screen bill from Raw(); the server clamps saves with Defs().
public static class DocFields
{
    static readonly object _lock = new();
    static JsonArray? _hblRaw, _hawbRaw;
    static List<FieldDef>? _hblDefs, _hawbDefs;

    static void EnsureLoaded()
    {
        if (_hblRaw != null) return;
        lock (_lock)
        {
            if (_hblRaw != null) return;
            var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Config.RepoRoot, "doc-fields.json")))!.AsObject();
            _hblRaw = (root["HBL"] as JsonArray) ?? new JsonArray();
            _hawbRaw = (root["HAWB"] as JsonArray) ?? new JsonArray();
            _hblDefs = Parse(_hblRaw);
            _hawbDefs = Parse(_hawbRaw);
        }
    }

    static List<FieldDef> Parse(JsonArray arr)
    {
        var list = new List<FieldDef>();
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            if (o["code"] is null) continue;   // skip the _comment string entries
            var d = new FieldDef
            {
                Code = (string?)o["code"] ?? "",
                Kind = (string?)o["kind"] ?? "",
                MaxRows = (int?)o["maxRows"] ?? 10,
                MaxLen = (int?)o["maxlen"] ?? 0,
            };
            if (o["columns"] is JsonArray cols)
                foreach (var c in cols) if (c is JsonObject co) d.Columns.Add(new FieldCol { Code = (string?)co["code"] ?? "", MaxLen = (int?)co["maxlen"] ?? 0 });
            list.Add(d);
        }
        return list;
    }

    // type = "HBL" | "HAWB"
    public static JsonArray Raw(string type) { EnsureLoaded(); return type == "HAWB" ? _hawbRaw! : _hblRaw!; }
    public static List<FieldDef> Defs(string type) { EnsureLoaded(); return type == "HAWB" ? _hawbDefs! : _hblDefs!; }
}
