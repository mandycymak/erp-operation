using System.Text.Json.Nodes;

namespace Ops;

// Loaded ONCE at startup (mirrors serve-ops.ps1 lines 13-53). Immutable for the process lifetime, so it is
// safe to read concurrently from every request thread. Everything deployment-specific comes from
// ops.config.json (or ops.config.<tenant>.json); DB_*/OPS_*/SWIVEL_* env vars override it for headless deploys.
// Each customer/tenant runs its own instance pointed at its own config + its own erpops DB (see the plan).
public static class Config
{
    public static string RepoRoot { get; private set; } = "";

    // ---- ops (erpops) connection: the web tier reads/writes ONLY erpops (two-server: may differ from the ERP) ----
    public static string OpsServer { get; private set; } = "";
    public static string OpsDb { get; private set; } = "";
    public static string ConnStr { get; private set; } = "";

    // ---- source ERP connection: per-station, READ-ONLY, used only by the ERP request handlers (Stage 4) ----
    static string _srcServer = "";
    static string _srcAuthClause = "";

    public static string AppName { get; private set; } = "Control Tower";
    public static string AppSubtitle { get; private set; } = "";
    public static string InstanceName { get; private set; } = "";
    public static int Port { get; private set; } = 8078;

    public static string StationCode { get; private set; } = "";   // which station THIS instance serves (inbound feed)

    public sealed record Station(string Code, string Name, string Country, string Database);
    public static IReadOnlyList<Station> Stations { get; private set; } = Array.Empty<Station>();
    static IReadOnlyDictionary<string, Station> _stationByCode = new Dictionary<string, Station>();

    // system identities (ERP pic_user values written by integrations, not people) — their shipments broadcast
    // to everyone's "My work" until a real user takes over (used by the scope builder, Stage 2).
    public static IReadOnlyList<string> SystemUsers { get; private set; } = Array.Empty<string>();
    public static IReadOnlyList<string> SystemUserPrefixes { get; private set; } = Array.Empty<string>();

    // Testing clock: ops.config asOfDate (yyyy-mm-dd) is treated as "today" for all operational date logic so a
    // frozen snapshot behaves like a live day. Empty/absent = LIVE (real today).
    public static string AsOfDate { get; private set; } = "";
    public static string TodayStr() =>
        string.IsNullOrEmpty(AsOfDate) ? DateTime.Now.ToString("yyyy-MM-dd") : AsOfDate;
    public static DateTime TodayDate() =>
        string.IsNullOrEmpty(AsOfDate) ? DateTime.Now.Date : DateTime.ParseExact(AsOfDate, "yyyy-MM-dd", null);

    // ---- SWIVEL L!NK OAuth (serve-ops.ps1 lines 41-50) ----
    public static string LinkProfileUrl { get; private set; } = "";
    public static string? LinkXSystem { get; private set; }
    public static bool LinkEnabled { get; private set; }
    public static bool LinkAutoProvision { get; private set; } = true;
    public static string LinkDefaultRole { get; private set; } = "operator";

    // ---- Swivel ERP write API (serve-ops.ps1 erpApi block; consumed by Erp.cs in Stage 4) ----
    public static string ErpBaseUrl { get; private set; } = "";
    public static string ErpToken { get; private set; } = "";
    public static bool ErpMock { get; private set; } = true;

    public static string PublicBaseUrl { get; private set; } = "";   // customer-review link prefix (doc-send, Stage 5)
    public static string? PdfEngine { get; private set; }            // headless Edge/Chrome override (Stage 5)

    // In a cross-site L!NK iframe the session cookie must be SameSite=None; Secure. Set OPS_IFRAME=1 there.
    public static bool IframeCookie { get; private set; }
    public static bool Https { get; private set; }

    static string EnvOrConfig(string name, string? cfgVal)
    {
        var v = Environment.GetEnvironmentVariable(name);
        return !string.IsNullOrWhiteSpace(v) ? v : (cfgVal ?? "");
    }
    static string NonEmpty(string? v, string fallback) => string.IsNullOrWhiteSpace(v) ? fallback : v;

    public static void Load()
    {
        var cfgFile = NonEmpty(Environment.GetEnvironmentVariable("OPS_CONFIG"), "ops.config.json");
        RepoRoot = FindRepoRoot(cfgFile);
        var cfg = JsonNode.Parse(File.ReadAllText(Path.Combine(RepoRoot, cfgFile)))!.AsObject();

        // source ERP server (read-only) — also the fallback for the ops server when opsServer is unset
        var server = EnvOrConfig("DB_SERVER", (string?)cfg["server"]);
        var auth = EnvOrConfig("DB_AUTH", (string?)cfg["auth"]);
        var user = EnvOrConfig("DB_USER", (string?)cfg["user"]);
        var password = EnvOrConfig("DB_PASSWORD", (string?)cfg["password"]);
        _srcServer = server;
        _srcAuthClause = auth == "sql" ? $"User ID={user};Password={password}" : "Integrated Security=True";

        // ops (erpops) server may differ from the source ERP (two-server mode); falls back to the source.
        OpsDb = EnvOrConfig("DB_OPS_DB", (string?)cfg["opsDb"]);
        OpsServer = NonEmpty(EnvOrConfig("DB_OPS_SERVER", (string?)cfg["opsServer"]), server);
        var opsAuth = NonEmpty(EnvOrConfig("DB_OPS_AUTH", (string?)cfg["opsAuth"]), auth);
        var opsUser = NonEmpty(EnvOrConfig("DB_OPS_USER", (string?)cfg["opsUser"]), user);
        var opsPassword = NonEmpty(EnvOrConfig("DB_OPS_PASSWORD", (string?)cfg["opsPassword"]), password);
        var opsAuthClause = opsAuth == "sql" ? $"User ID={opsUser};Password={opsPassword}" : "Integrated Security=True";
        // Packet Size=512: the VPN tunnel's small MTU black-holes default 8 KB TDS packets ("semaphore timeout").
        // Max Pool Size bounds concurrent DB work so 500 app users can't stampede the single SQL box.
        ConnStr = $"Server={OpsServer};Database={OpsDb};{opsAuthClause};TrustServerCertificate=True;Connect Timeout=30;Packet Size=512;Max Pool Size=50";

        AppName = NonEmpty((string?)cfg["appName"], "Control Tower");
        AppSubtitle = (string?)cfg["appSubtitle"] ?? "";
        InstanceName = (string?)cfg["instanceName"] ?? "";

        var envPort = Environment.GetEnvironmentVariable("DB_PORT");
        Port = !string.IsNullOrWhiteSpace(envPort) ? int.Parse(envPort) : ((int?)cfg["port"] ?? 8078);

        StationCode = ((string?)cfg["stationCode"] ?? "").Trim();

        var asOf = ((string?)cfg["asOfDate"] ?? "").Trim();
        AsOfDate = System.Text.RegularExpressions.Regex.IsMatch(asOf, @"^\d{4}-\d{2}-\d{2}$") ? asOf : "";

        SystemUsers = StrArray(cfg["systemUsers"]);
        SystemUserPrefixes = StrArray(cfg["systemUserPrefixes"]);

        var stations = new List<Station>();
        var byCode = new Dictionary<string, Station>(StringComparer.OrdinalIgnoreCase);
        if (cfg["stations"] is JsonArray sarr)
            foreach (var s in sarr)
            {
                if (s is not JsonObject so) continue;
                var code = ((string?)so["code"] ?? "").Trim();
                if (code == "") continue;
                var st = new Station(code, ((string?)so["name"] ?? "").Trim(),
                    ((string?)so["country"] ?? "").Trim(), ((string?)so["database"] ?? "").Trim());
                stations.Add(st);
                byCode[code] = st;
            }
        Stations = stations;
        _stationByCode = byCode;

        var link = cfg["swivelLink"]?.AsObject();
        LinkProfileUrl = EnvOrConfig("SWIVEL_OAUTH_PROFILE_URL", (string?)link?["profileUrl"]).Trim();
        LinkXSystem = NonEmpty(Environment.GetEnvironmentVariable("SWIVEL_OAUTH_XSYSTEM"), (string?)link?["xSystem"] ?? "");
        LinkEnabled = LinkProfileUrl != "";
        LinkAutoProvision = (bool?)link?["autoProvision"] ?? true;
        LinkDefaultRole = NonEmpty(((string?)link?["defaultRole"] ?? "").Trim().ToLowerInvariant(), "operator");

        var erp = cfg["erpApi"]?.AsObject();
        ErpBaseUrl = ((string?)erp?["baseUrl"] ?? "").Trim();
        ErpToken = ((string?)erp?["token"] ?? "").Trim();
        ErpMock = (bool?)erp?["mock"] ?? true;

        PublicBaseUrl = ((string?)cfg["publicBaseUrl"] ?? "").Trim();
        PdfEngine = (string?)cfg["pdfEngine"];

        IframeCookie = Environment.GetEnvironmentVariable("OPS_IFRAME") == "1";
        Https = Environment.GetEnvironmentVariable("OPS_HTTPS") == "1" || IframeCookie;
    }

    // The source ERP DB for a station code (READ-ONLY; Connect Timeout=15 — the VPN SSL pre-login runs ~4 s).
    // CommandTimeout is bounded tight by the caller so a slow ERP read can't hog a dbGate slot.
    public static Station? StationByCode(string code) =>
        _stationByCode.TryGetValue(code, out var s) ? s : null;
    public static string SourceConnStr(string db) =>
        $"Server={_srcServer};Database={db};{_srcAuthClause};TrustServerCertificate=True;Connect Timeout=15;Packet Size=512;Max Pool Size=50";

    static string[] StrArray(JsonNode? n)
    {
        if (n is not JsonArray a) return Array.Empty<string>();
        return a.Select(x => (string?)x ?? "").Where(s => s.Trim() != "").Select(s => s.Trim()).ToArray();
    }

    // The .NET app lives in server/; the client files + ops.config.json live in the repo root. Walk up from the
    // working dir / binary dir until we find the config file. OPS_ROOT overrides (for an IIS deploy).
    static string FindRepoRoot(string cfgFile)
    {
        var fromEnv = Environment.GetEnvironmentVariable("OPS_ROOT");
        if (!string.IsNullOrWhiteSpace(fromEnv)) return Path.GetFullPath(fromEnv);
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var dir = new DirectoryInfo(start);
            while (dir != null)
            {
                if (File.Exists(Path.Combine(dir.FullName, cfgFile))) return dir.FullName;
                dir = dir.Parent;
            }
        }
        throw new FileNotFoundException($"Could not locate {cfgFile} by walking up from the working directory. Set OPS_ROOT to the repo root.");
    }
}
