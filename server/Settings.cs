using Microsoft.Data.SqlClient;

namespace Ops;

// Runtime-editable settings stored in dbo.app_setting (ops DB) that OVERRIDE the read-only ops.config.json, so a
// customer-site admin can correct the ERP connection (Base URL / bearer token / mock toggle) from the admin
// "ERP API" tab WITHOUT editing a file or restarting - and no secret sits in a file on the box. SQL is the source
// of truth; a key absent (or blank) here falls back to the config value. Loaded once at startup (Program.cs) and
// reloaded after an admin save. An immutable snapshot is swapped under a lock, so readers are lock-free.
public static class Settings
{
    public const string ErpBaseUrlKey = "erpBaseUrl";
    public const string ErpTokenKey = "erpToken";
    public const string ErpMockKey = "erpMock";
    public const string BookRefFormatKey = "bookRefFormat";
    // Book Now outbound-reference template. Tokens: {station} {m}(A/S) {mode}(AIR/SEA) {yymmdd} {yy} {seqN}(running
    // number, N-wide) / {seq}(=4-wide). The running number resets per day only when the format carries {yymmdd}/{yy};
    // otherwise it is a continuous per-(station,mode) sequence. Default keeps the dated form e.g. HKGA2606260001.
    public const string BookRefFormatDefault = "{station}{m}{yymmdd}{seq4}";

    static readonly object _lock = new();
    static volatile IReadOnlyDictionary<string, string> _snap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public static void Load()
    {
        try
        {
            var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using var cn = new SqlConnection(Config.ConnStr); cn.Open();
            using var cmd = cn.CreateCommand(); cmd.CommandText = "SELECT name, value FROM dbo.app_setting"; cmd.CommandTimeout = 15;
            using var r = cmd.ExecuteReader();
            while (r.Read()) d[r.GetString(0)] = r.IsDBNull(1) ? "" : r.GetString(1);
            lock (_lock) _snap = d;
        }
        catch (Exception ex) { Log.Error("Settings.Load", ex); }   // keep the last good snapshot; effective values fall back to Config
    }

    static string? Raw(string key) => _snap.TryGetValue(key, out var v) ? v : null;
    static bool Has(string key) => !string.IsNullOrWhiteSpace(Raw(key));

    // ---- effective ERP connection: the SQL override when set (non-blank), else the config file ----
    public static string ErpBaseUrl => Has(ErpBaseUrlKey) ? Raw(ErpBaseUrlKey)!.Trim() : Config.ErpBaseUrl;
    public static string ErpToken => Has(ErpTokenKey) ? Raw(ErpTokenKey)!.Trim() : Config.ErpToken;
    public static bool ErpMock => Has(ErpMockKey)
        ? Raw(ErpMockKey)!.Trim().ToLowerInvariant() is "true" or "1" or "yes" or "on"
        : Config.ErpMock;

    public static string BookRefFormat => Has(BookRefFormatKey) ? Raw(BookRefFormatKey)!.Trim() : BookRefFormatDefault;
    public static bool BookRefFormatFromDb => Has(BookRefFormatKey);

    // whether each value currently comes from SQL (for the admin UI to show "from SQL" vs "from config file")
    public static bool ErpBaseUrlFromDb => Has(ErpBaseUrlKey);
    public static bool ErpTokenFromDb => Has(ErpTokenKey);
    public static bool ErpMockFromDb => Has(ErpMockKey);

    // Upsert name/value pairs, then reload the snapshot. A null value DELETEs the key (revert to the config fallback).
    public static void Set(IDictionary<string, string?> kv)
    {
        using (var cn = new SqlConnection(Config.ConnStr))
        {
            cn.Open();
            foreach (var p in kv)
            {
                using var cmd = cn.CreateCommand(); cmd.CommandTimeout = 15;
                if (p.Value == null)
                {
                    cmd.CommandText = "DELETE FROM dbo.app_setting WHERE name=@n";
                    cmd.Parameters.AddWithValue("@n", p.Key);
                }
                else
                {
                    cmd.CommandText = "MERGE dbo.app_setting AS t USING (SELECT @n n) s ON t.name=s.n " +
                        "WHEN MATCHED THEN UPDATE SET value=@v, updated_at=GETDATE() " +
                        "WHEN NOT MATCHED THEN INSERT(name,value) VALUES(@n,@v);";
                    cmd.Parameters.AddWithValue("@n", p.Key);
                    cmd.Parameters.AddWithValue("@v", (object?)p.Value ?? DBNull.Value);
                }
                cmd.ExecuteNonQuery();
            }
        }
        Load();
    }
}
