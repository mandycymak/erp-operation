using System.Text.Json;

namespace Ops;

// Small JsonElement read helpers so handler code reads like the PowerShell `$j.field` access (absent -> "").
public static class JE
{
    public static bool Has(this JsonElement j, string key) =>
        j.ValueKind == JsonValueKind.Object && j.TryGetProperty(key, out _);

    public static string Str(this JsonElement j, string key)
    {
        if (j.ValueKind == JsonValueKind.Object && j.TryGetProperty(key, out var v))
            return v.ValueKind switch
            {
                JsonValueKind.String => v.GetString() ?? "",
                JsonValueKind.Number => v.ToString(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => "",
            };
        return "";
    }

    public static bool? Bool(this JsonElement j, string key)
    {
        if (j.ValueKind == JsonValueKind.Object && j.TryGetProperty(key, out var v))
        {
            if (v.ValueKind == JsonValueKind.True) return true;
            if (v.ValueKind == JsonValueKind.False) return false;
            if (v.ValueKind == JsonValueKind.String && bool.TryParse(v.GetString(), out var b)) return b;
        }
        return null;
    }

    public static string[] Arr(this JsonElement j, string key)
    {
        if (j.ValueKind == JsonValueKind.Object && j.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Array)
            return v.EnumerateArray()
                    .Select(x => x.ValueKind == JsonValueKind.String ? (x.GetString() ?? "") : x.ToString())
                    .Select(s => s.Trim()).Where(s => s != "").Distinct().ToArray();
        return Array.Empty<string>();
    }
}
