using System.Text.Json;
using System.Text.RegularExpressions;

namespace Ops;

// Shared field-cleaning + change-diff + attachment-validation helpers (serve-ops.ps1 Doc-CleanStr / Doc-ValStr /
// Doc-Changed / Doc-AttachValidate). Used by the ERP master-code editor (Stage 4b) and the draft-doc workflow
// (Stage 5). Values flowing through here are either strings or structured rows (List<Dictionary<string,object?>>).
public static class DocUtil
{
    static readonly JsonSerializerOptions _compact = new() { PropertyNamingPolicy = null, WriteIndented = false };

    // normalize CRLF/CR -> LF and clamp to maxlen (0 = no clamp). No trim (mirrors Doc-CleanStr exactly).
    public static string CleanStr(object? v, int maxlen)
    {
        var s = v?.ToString() ?? "";
        s = s.Replace("\r\n", "\n").Replace("\r", "\n");
        if (maxlen > 0 && s.Length > maxlen) s = s.Substring(0, maxlen);
        return s;
    }

    // canonical comparable string for a field value: strings as-is, structured values as compact JSON.
    public static string ValStr(object? v)
    {
        if (v == null) return "";
        if (v is string s) return s;
        return JsonSerializer.Serialize(v, _compact);
    }

    // field codes whose value differs between the current snapshot and the cleaned new object (iterate the new
    // object's keys, in dict order). Mirrors Doc-Changed.
    public static List<string> Changed(IDictionary<string, object?> current, IDictionary<string, object?> clean)
    {
        var outl = new List<string>();
        foreach (var kv in clean)
        {
            current.TryGetValue(kv.Key, out var ov);
            if (ValStr(ov) != ValStr(kv.Value)) outl.Add(kv.Key);
        }
        return outl;
    }

    // PDF/PNG/JPEG only, magic-byte checked, 16 bytes .. 5 MB. Mirrors Doc-AttachValidate (same rules as the
    // draft-doc attachments + the milestone-clearing ERP upload).
    static readonly Dictionary<string, byte[]> _magic = new()
    {
        ["application/pdf"] = new byte[] { 0x25, 0x50, 0x44, 0x46 },
        ["image/png"] = new byte[] { 0x89, 0x50, 0x4E, 0x47 },
        ["image/jpeg"] = new byte[] { 0xFF, 0xD8 },
    };

    public sealed record Attach(bool Ok, string Err, string Name, string Ctype, byte[] Bytes);

    public static Attach AttachValidate(string? fileName, string? contentType, string? b64)
    {
        var name = Regex.Replace((fileName ?? "").Trim(), @"[^\w.\- ]", "");
        if (name == "") return new(false, "file name required", "", "", Array.Empty<byte>());
        var ct = (contentType ?? "").Trim().ToLowerInvariant();
        if (!_magic.TryGetValue(ct, out var magic)) return new(false, "only PDF, PNG or JPEG files are accepted", "", "", Array.Empty<byte>());
        byte[] bytes;
        try { bytes = Convert.FromBase64String(b64 ?? ""); } catch { return new(false, "invalid file data", "", "", Array.Empty<byte>()); }
        if (bytes.Length < 16) return new(false, "file is empty", "", "", Array.Empty<byte>());
        if (bytes.Length > 5242880) return new(false, "file too large (max 5 MB)", "", "", Array.Empty<byte>());
        for (int i = 0; i < magic.Length; i++) if (bytes[i] != magic[i]) return new(false, "file content does not match its type", "", "", Array.Empty<byte>());
        return new(true, "", name, ct, bytes);
    }
}
