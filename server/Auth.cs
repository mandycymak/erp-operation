using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Ops;

// Ports serve-ops.ps1's identity + auth layer (lines 55-165). The single-threaded PS server kept the current
// user in $script:CurUser; here the user is resolved per request into ReqState (Sql.cs / Program.cs), never in
// shared mutable state — that is the whole point of the migration. Scope dims (stations/access/teams/erpUsers)
// live INLINE on the user record (ops has no separate roles.json); the scope WHERE-builders are in Filter.cs.

public sealed class Session
{
    public required string Username { get; init; }
    public required string Role { get; init; }
    public bool Admin { get; init; }
    public required string DisplayName { get; init; }
    public DateTime Expires { get; set; }
}

public sealed class UserRec
{
    public string Username = "";
    public string DisplayName = "";
    public string Email = "";
    public string Salt = "";
    public string PwdHash = "";
    public string Role = "";
    public bool Admin;
    public string AuthProvider = "local";
    public string Language = "";                          // UI language preference (e.g. "zh-Hans"); "" = follow browser/English
    public string[] Teams = Array.Empty<string>();
    public string[] Stations = Array.Empty<string>();
    public string PrimaryStation = "";
    public string[] Access = Array.Empty<string>();      // mode-bound pairs: Air-Export, Sea-Import, ...
    public string[] ErpUsers = Array.Empty<string>();    // ERP pic_user/created_by names this person owns
}

// Immutable snapshot of users. Admin writes build a NEW snapshot and swap the reference under a lock, so readers
// (every request) see a consistent set with no locking. Mirrors Reload-Users.
public sealed record AuthSnapshot(IReadOnlyList<UserRec> Users, bool AuthOn);

public static class Auth
{
    public static readonly ConcurrentDictionary<string, Session> Sessions = new();

    static readonly object _writeLock = new();
    static volatile AuthSnapshot _snap = new(Array.Empty<UserRec>(), false);
    public static AuthSnapshot Snap => _snap;

    static string UsersPath => Path.Combine(Config.RepoRoot, "users.json");

    public static void LoadAll()
    {
        lock (_writeLock)
        {
            var users = ParseUsers();
            _snap = new AuthSnapshot(users, users.Count > 0);
        }
    }

    static List<UserRec> ParseUsers()
    {
        var list = new List<UserRec>();
        if (!File.Exists(UsersPath)) return list;
        JsonNode? root;
        try { root = JsonNode.Parse(File.ReadAllText(UsersPath)); } catch { return list; }
        var arr = root?["users"]?.AsArray();
        if (arr == null) return list;
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            list.Add(new UserRec
            {
                Username = (string?)o["username"] ?? "",
                DisplayName = (string?)o["displayName"] ?? "",
                Email = (string?)o["email"] ?? "",
                Salt = (string?)o["salt"] ?? "",
                PwdHash = (string?)o["pwdHash"] ?? "",
                Role = (string?)o["role"] ?? "",
                Admin = (bool?)o["admin"] ?? false,
                AuthProvider = NonEmpty((string?)o["authProvider"], "local"),
                Language = ((string?)o["language"] ?? "").Trim(),
                Teams = StrArray(o["teams"]),
                Stations = StrArray(o["stations"]),
                PrimaryStation = ((string?)o["primaryStation"] ?? "").Trim(),
                Access = StrArray(o["access"]),
                ErpUsers = StrArray(o["erpUsers"]),
            });
        }
        return list;
    }

    static string NonEmpty(string? v, string fallback) => string.IsNullOrWhiteSpace(v) ? fallback : v;
    static string[] StrArray(JsonNode? n)
    {
        if (n is not JsonArray a) return Array.Empty<string>();
        return a.Select(x => (string?)x ?? "").Where(s => s.Trim() != "").Select(s => s.Trim()).ToArray();
    }

    // SHA256 of "salt:pwd" as lowercase hex (serve-ops.ps1 lines 67-70).
    public static string HashPwd(string salt, string pwd) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{salt}:{pwd}")));

    public static UserRec? FindUser(string? username) =>
        username == null ? null : _snap.Users.FirstOrDefault(u => u.Username == username);

    // Email is the login / federation key (local password login AND SWIVEL L!NK both match on it).
    public static UserRec? FindUserByEmail(string? email)
    {
        var e = (email ?? "").Trim().ToLowerInvariant();
        return e == "" ? null : _snap.Users.FirstOrDefault(u => u.Email.Trim().ToLowerInvariant() == e);
    }

    // serve-ops.ps1 line 73-77: ops_sid; Path=/; HttpOnly. Cross-site L!NK iframe -> SameSite=None; Secure.
    public static string SessionCookie(string sid)
    {
        var b = $"ops_sid={sid}; Path=/; HttpOnly";
        if (Config.IframeCookie) return $"{b}; SameSite=None; Secure; Partitioned";   // CHIPS: cross-site L!NK iframe
        return Config.Https ? $"{b}; SameSite=Lax; Secure" : $"{b}; SameSite=Lax";
    }

    // ---- mutations (admin CRUD + L!NK auto-provision): write the JSON then reload the snapshot ----
    static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    static readonly object _fileLock = new();

    public static string NewSalt() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));

    public static void Audit(string who, string msg)
    {
        try { File.AppendAllText(Path.Combine(Config.RepoRoot, "admin-audit.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}\t{who}\t{msg}\r\n", Utf8NoBom); } catch { }
    }

    // New username for a first-time L!NK sign-in: email local-part, sanitized + deduped (serve-ops.ps1 line 147-150).
    static string NewUsername(string email)
    {
        var local = Regex.Replace(email.Split('@')[0], "[^A-Za-z0-9_.-]", "").ToLowerInvariant();
        if (local == "") local = "user";
        var cand = local; var n = 1;
        while (_snap.Users.Any(u => u.Username == cand)) { n++; cand = $"{local}{n}"; }
        return cand;
    }

    // L!NK auto-provision: a minimal swivel-only user on the default role, no local password. Persist, return it.
    public static UserRec ProvisionLinkUser(string email, string displayName)
    {
        var un = NewUsername(email);
        var dn = string.IsNullOrWhiteSpace(displayName) ? email.Split('@')[0] : displayName.Trim();
        var rec = new UserRec
        {
            Username = un, DisplayName = dn, Email = email.Trim(), Salt = "", PwdHash = "",
            Role = Config.LinkDefaultRole, Admin = false, AuthProvider = "swivel",
        };
        var users = _snap.Users.ToList(); users.Add(rec);
        SaveUsers(users);
        Audit(un, $"L!NK auto-provisioned for {email} (role={Config.LinkDefaultRole})");
        return FindUser(un)!;
    }

    static JsonObject UserToJson(UserRec u) => new()
    {
        ["username"] = u.Username,
        ["displayName"] = u.DisplayName,
        ["email"] = u.Email,
        ["salt"] = u.Salt,
        ["pwdHash"] = u.PwdHash,
        ["role"] = u.Role,
        ["admin"] = u.Admin,
        ["authProvider"] = u.AuthProvider,
        ["language"] = u.Language,
        ["teams"] = JArr(u.Teams),
        ["stations"] = JArr(u.Stations),
        ["primaryStation"] = u.PrimaryStation,
        ["access"] = JArr(u.Access),
        ["erpUsers"] = JArr(u.ErpUsers),
    };
    static JsonArray JArr(string[] xs) => new(xs.Select(s => (JsonNode)s!).ToArray());

    public static void SaveUsers(IReadOnlyList<UserRec> users)
    {
        lock (_fileLock)
        {
            var root = new JsonObject
            {
                ["_comment"] = "Control Tower logins. Gitignored. Email is the sign-in key; username is the internal identity.",
                ["users"] = new JsonArray(users.Select(UserToJson).ToArray())
            };
            File.WriteAllText(UsersPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), Utf8NoBom);
        }
        LoadAll();
    }
}
