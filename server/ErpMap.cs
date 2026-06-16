using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Ops;

// erp-api-map.json — the TRACKED, non-secret ERP API identity codes (partyGroupCode, forwarderCode, event /
// document type codes, ...). The bearer token is NOT here (it's in the gitignored config). Read-modify-write so
// comments + nested blocks survive an admin edit (serve-ops.ps1 erp-doc-api.ps1 Get-/Set-ErpApiMap).
public static class ErpMap
{
    static string Path_ => System.IO.Path.Combine(Config.RepoRoot, "erp-api-map.json");
    static readonly object _lock = new();
    static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    static JsonObject? _cache;

    public static JsonObject Get()
    {
        lock (_lock)
        {
            if (_cache == null)
            {
                if (File.Exists(Path_)) { try { _cache = JsonNode.Parse(File.ReadAllText(Path_))?.AsObject() ?? new JsonObject(); } catch { _cache = new JsonObject(); } }
                else _cache = new JsonObject();
            }
            return _cache;
        }
    }

    public static string Str(string key) => (string?)Get()[key] ?? "";

    // Persist scalar settings (read-modify-write so other keys/blocks survive), then reset the cache.
    public static void Set(IDictionary<string, string> updates)
    {
        lock (_lock)
        {
            JsonObject obj;
            if (File.Exists(Path_)) { try { obj = JsonNode.Parse(File.ReadAllText(Path_))?.AsObject() ?? new JsonObject(); } catch { obj = new JsonObject(); } }
            else obj = new JsonObject();
            foreach (var kv in updates) obj[kv.Key] = kv.Value;
            File.WriteAllText(Path_, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), Utf8NoBom);
            _cache = obj;
        }
    }

    public static void ResetCache() { lock (_lock) _cache = null; }
}
