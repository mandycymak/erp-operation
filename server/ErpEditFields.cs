using System.Text.Json.Nodes;

namespace Ops;

// erp-edit-fields.json — the ERP master-code correction editor dictionary (one entry per correctable field,
// grouped by section). Loaded once. The client needs the ORIGINAL lowercase-keyed field objects (it drives the
// editor layout), so Raw() returns the verbatim JSON array; Defs() is the typed view the seed/save logic reads.
public sealed class FieldCol
{
    public string Code = "";
    public int MaxLen = 0;
}

public sealed class FieldDef
{
    public string Code = "", Kind = "", Lookup = "", WriteKey = "", ReadFrom = "";
    public int MaxRows = 50;
    public int MaxLen = 0;
    public List<FieldCol> Columns = new();   // for kind=table (code + maxlen per column)
}

public static class ErpEditFields
{
    static readonly object _lock = new();
    static JsonArray? _seaRaw, _airRaw;
    static List<FieldDef>? _seaDefs, _airDefs;

    static void EnsureLoaded()
    {
        if (_seaRaw != null) return;
        lock (_lock)
        {
            if (_seaRaw != null) return;
            var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Config.RepoRoot, "erp-edit-fields.json")))!.AsObject();
            _seaRaw = (root["SEA"] as JsonArray) ?? new JsonArray();
            _airRaw = (root["AIR"] as JsonArray) ?? new JsonArray();
            _seaDefs = Parse(_seaRaw);
            _airDefs = Parse(_airRaw);
        }
    }

    static List<FieldDef> Parse(JsonArray arr)
    {
        var list = new List<FieldDef>();
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var d = new FieldDef
            {
                Code = (string?)o["code"] ?? "",
                Kind = (string?)o["kind"] ?? "",
                Lookup = (string?)o["lookup"] ?? "",
                WriteKey = (string?)o["writeKey"] ?? "",
                ReadFrom = (string?)o["readFrom"] ?? "",
                MaxRows = (int?)o["maxRows"] ?? 50,
                MaxLen = (int?)o["maxlen"] ?? 0,
            };
            if (o["columns"] is JsonArray cols)
                foreach (var c in cols) if (c is JsonObject co) d.Columns.Add(new FieldCol { Code = (string?)co["code"] ?? "", MaxLen = (int?)co["maxlen"] ?? 0 });
            list.Add(d);
        }
        return list;
    }

    public static JsonArray Raw(string modeKey) { EnsureLoaded(); return modeKey == "AIR" ? _airRaw! : _seaRaw!; }
    public static List<FieldDef> Defs(string modeKey) { EnsureLoaded(); return modeKey == "AIR" ? _airDefs! : _seaDefs!; }
}
