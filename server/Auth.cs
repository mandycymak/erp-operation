using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Ops;

// Ports serve-ops.ps1's identity + auth layer (lines 55-165). The single-threaded PS server kept the current
// user in $script:CurUser; here the user is resolved per request into ReqState (Sql.cs / Program.cs), never in
// shared mutable state — that is the whole point of the migration. Scope dims (stations/access/teams/erpUsers)
// live INLINE on the user record (ops has no separate roles.json); the scope WHERE-builders are in Filter.cs.
//
// STORE: credentials/roles/scope now live in SQL (dbo.app_user + dbo.app_user_scope), ported from the sibling
// erp-dashboard (server/Auth.cs). They USED to sit in the gitignored users.json file; SQL is now the source of
// truth so the customer maintains logins in their MSSQL environment and no credential file sits on the IIS box.
// On first run (empty table) SeedOrImport imports any existing users.json (kept afterwards only as a backup) OR
// seeds a default admin/admin123 — so the app is secure-by-default and usable out of the box.
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

    // Legacy file path — read ONLY for the one-time migration into SQL (SeedOrImport). The live store is now SQL.
    static string UsersPath => Path.Combine(Config.RepoRoot, "users.json");

    // The four row-level scope dimensions, mapped to the UserRec array fields. (dim name in app_user_scope.)
    static readonly string[] ScopeDims = { "team", "station", "access", "erpuser" };

    // Load users from SQL into the immutable snapshot. Resilience mirrors the sibling: a DB outage must NEVER fall
    // back to "no users -> auth off" (that would re-open the auto-admin hole). On the first load with no prior
    // snapshot we fail loudly (the DB must be up to start); on a later reload we keep serving the last good snapshot.
    // The tables are self-created (best-effort) and seeded with a default admin on first run.
    public static void LoadAll()
    {
        lock (_writeLock)
        {
            try
            {
                EnsureTables();
                if (TableEmpty()) SeedOrImport();
                var users = ReadUsersFromDb();
                // Fail CLOSED: a successful load that yields zero users must never become "auth off / open app".
                // SeedOrImport guarantees >=1 user when the table was empty, so zero here means something is wrong.
                if (users.Count == 0) throw new InvalidOperationException("dbo.app_user is empty after load/seed — refusing to start with no credential store.");
                _snap = new AuthSnapshot(users, true);
            }
            catch (Exception ex)
            {
                if (_snap.Users.Count == 0)
                    throw new InvalidOperationException(
                        "Cannot load users from SQL and have no cached snapshot. Is the ops DB up, and have the " +
                        "dbo.app_user / dbo.app_user_scope tables been created (run setup-ops.ps1 / setup-database.bat)? " +
                        "Inner: " + ex.Message, ex);
                Console.Error.WriteLine("[Auth] users reload failed; keeping previous snapshot: " + ex.Message);
            }
        }
    }

    // ---- SQL store (dbo.app_user + dbo.app_user_scope) ----

    static SqlConnection Open() { var cn = new SqlConnection(Config.ConnStr); cn.Open(); return cn; }

    // Best-effort create: the canonical, privileged creator is setup-ops.ps1. The serve login may lack DDL, in which
    // case these CREATEs are denied and ignored (the tables already exist); if they DON'T exist and can't be created,
    // the read in LoadAll fails loudly telling the operator to run setup-ops.ps1. NEVER drops/alters a table.
    static void EnsureTables()
    {
        try
        {
            using var cn = Open();
            ExecNonQuery(cn, null,
                "IF OBJECT_ID('dbo.app_user') IS NULL CREATE TABLE dbo.app_user(username nvarchar(128) NOT NULL CONSTRAINT PK_app_user PRIMARY KEY, display_name nvarchar(256) NULL, email nvarchar(256) NULL, [role] nvarchar(128) NULL, is_admin bit NOT NULL CONSTRAINT DF_app_user_admin DEFAULT 0, salt varchar(64) NULL, pwd_hash varchar(128) NULL, auth_provider nvarchar(16) NOT NULL CONSTRAINT DF_app_user_authp DEFAULT 'local', language nvarchar(16) NULL, primary_station nvarchar(128) NULL, updated_at datetime NOT NULL CONSTRAINT DF_app_user_upd DEFAULT GETDATE());" +
                "IF OBJECT_ID('dbo.app_user_scope') IS NULL CREATE TABLE dbo.app_user_scope(username nvarchar(128) NOT NULL, dim varchar(20) NOT NULL, code nvarchar(128) NOT NULL, CONSTRAINT PK_app_user_scope PRIMARY KEY(username, dim, code));");
        }
        catch (SqlException) { /* low-priv serve login: rely on setup-ops.ps1 having created the tables */ }
    }

    static bool TableEmpty()
    {
        using var cn = Open();
        using var cmd = cn.CreateCommand(); cmd.CommandText = "SELECT COUNT(*) FROM dbo.app_user"; cmd.CommandTimeout = 30;
        return Convert.ToInt32(cmd.ExecuteScalar()) == 0;
    }

    static List<UserRec> ReadUsersFromDb()
    {
        using var cn = Open();
        var byName = new Dictionary<string, UserRec>(StringComparer.Ordinal);
        using (var cmd = cn.CreateCommand())
        {
            cmd.CommandText = "SELECT username, display_name, email, [role], is_admin, salt, pwd_hash, auth_provider, language, primary_station FROM dbo.app_user"; cmd.CommandTimeout = 30;
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                var u = new UserRec
                {
                    Username = r.GetString(0),
                    DisplayName = r.IsDBNull(1) ? "" : r.GetString(1),
                    Email = r.IsDBNull(2) ? "" : r.GetString(2),
                    Role = r.IsDBNull(3) ? "" : r.GetString(3),
                    Admin = !r.IsDBNull(4) && r.GetBoolean(4),
                    Salt = r.IsDBNull(5) ? "" : r.GetString(5),
                    PwdHash = r.IsDBNull(6) ? "" : r.GetString(6),
                    AuthProvider = NonEmpty(r.IsDBNull(7) ? "" : r.GetString(7), "local"),
                    Language = (r.IsDBNull(8) ? "" : r.GetString(8)).Trim(),
                    PrimaryStation = (r.IsDBNull(9) ? "" : r.GetString(9)).Trim(),
                };
                byName[u.Username] = u;
            }
        }
        // gather scope rows into per-user lists, then assign back to the array fields.
        var dims = new Dictionary<string, Dictionary<string, List<string>>>(StringComparer.Ordinal);
        using (var cmd = cn.CreateCommand())
        {
            cmd.CommandText = "SELECT username, dim, code FROM dbo.app_user_scope"; cmd.CommandTimeout = 30;
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                var un = r.GetString(0); var dim = r.GetString(1); var code = r.GetString(2);
                if (string.IsNullOrWhiteSpace(code)) continue;
                if (!dims.TryGetValue(un, out var d)) dims[un] = d = new(StringComparer.Ordinal);
                if (!d.TryGetValue(dim, out var l)) d[dim] = l = new();
                l.Add(code.Trim());
            }
        }
        foreach (var u in byName.Values)
        {
            if (!dims.TryGetValue(u.Username, out var d)) continue;
            u.Teams = Take(d, "team"); u.Stations = Take(d, "station"); u.Access = Take(d, "access"); u.ErpUsers = Take(d, "erpuser");
        }
        return byName.Values.ToList();
    }

    static string[] Take(Dictionary<string, List<string>> d, string dim) => d.TryGetValue(dim, out var l) ? l.ToArray() : Array.Empty<string>();

    // Rewrite the whole store (delete-all + insert-all in one transaction), parity with the old "rewrite the file".
    static readonly object _fileLock = new();
    static void WriteUsers(IReadOnlyList<UserRec> users)
    {
        using var cn = Open();
        using var tx = cn.BeginTransaction();
        try
        {
            ExecNonQuery(cn, tx, "DELETE FROM dbo.app_user_scope"); ExecNonQuery(cn, tx, "DELETE FROM dbo.app_user");
            foreach (var u in users)
            {
                if (string.IsNullOrWhiteSpace(u.Username)) continue;
                using (var cmd = cn.CreateCommand())
                {
                    cmd.Transaction = tx; cmd.CommandTimeout = 30;
                    cmd.CommandText = "INSERT INTO dbo.app_user(username,display_name,email,[role],is_admin,salt,pwd_hash,auth_provider,language,primary_station,updated_at) " +
                                      "VALUES(@u,@dn,@em,@ro,@ad,@sa,@ph,@ap,@lg,@ps,GETDATE())";
                    var p = cmd.Parameters;
                    p.AddWithValue("@u", u.Username);
                    p.AddWithValue("@dn", NV(u.DisplayName)); p.AddWithValue("@em", NV(u.Email)); p.AddWithValue("@ro", NV(u.Role));
                    p.AddWithValue("@ad", u.Admin); p.AddWithValue("@sa", NV(u.Salt)); p.AddWithValue("@ph", NV(u.PwdHash));
                    p.AddWithValue("@ap", NonEmpty(u.AuthProvider, "local")); p.AddWithValue("@lg", NV(u.Language)); p.AddWithValue("@ps", NV(u.PrimaryStation));
                    cmd.ExecuteNonQuery();
                }
                InsertScope(cn, tx, u.Username, "team", u.Teams);
                InsertScope(cn, tx, u.Username, "station", u.Stations);
                InsertScope(cn, tx, u.Username, "access", u.Access);
                InsertScope(cn, tx, u.Username, "erpuser", u.ErpUsers);
            }
            tx.Commit();
        }
        catch { try { tx.Rollback(); } catch { } throw; }
    }

    static void InsertScope(SqlConnection cn, SqlTransaction tx, string username, string dim, string[] codes)
    {
        if (codes == null) return;
        foreach (var code in codes.Where(c => !string.IsNullOrWhiteSpace(c)).Select(c => c.Trim()).Distinct(StringComparer.Ordinal))
        {
            using var cmd = cn.CreateCommand(); cmd.Transaction = tx; cmd.CommandTimeout = 30;
            cmd.CommandText = "INSERT INTO dbo.app_user_scope(username,dim,code) VALUES(@u,@d,@c)";
            cmd.Parameters.AddWithValue("@u", username); cmd.Parameters.AddWithValue("@d", dim); cmd.Parameters.AddWithValue("@c", code);
            cmd.ExecuteNonQuery();
        }
    }

    static object NV(string? s) => string.IsNullOrEmpty(s) ? DBNull.Value : s;
    static void ExecNonQuery(SqlConnection cn, SqlTransaction? tx, string sql)
    {
        using var cmd = cn.CreateCommand(); cmd.Transaction = tx; cmd.CommandText = sql; cmd.CommandTimeout = 30;
        cmd.ExecuteNonQuery();
    }

    // First run: import the legacy users.json if present (no account loss on migration; the file is kept as a
    // backup), else seed a single default admin/admin123 so the app is secure-and-usable out of the box. Writes
    // straight to the tables (no LoadAll re-entry). Ported from erp-dashboard\server\Auth.cs SeedOrImport.
    static void SeedOrImport()
    {
        var users = ParseUsersFile();
        bool imported = users.Count > 0;
        if (users.Count == 0)
        {
            var salt = NewSalt();
            users.Add(new UserRec { Username = "admin", DisplayName = "Administrator", Role = "admin", Admin = true, AuthProvider = "local", Salt = salt, PwdHash = HashPwd(salt, "admin123") });
        }
        WriteUsers(users);
        if (imported)
        {
            Audit("system", $"imported users.json ({users.Count} users) into dbo.app_user — the file is kept only as a backup; SQL is now the source of truth");
            Console.Error.WriteLine("[Auth] imported users.json into SQL (dbo.app_user); SQL is now the source of truth (file kept as backup).");
        }
        else
        {
            Audit("system", "seeded default admin (admin/admin123) into dbo.app_user — change this password immediately");
            Console.Error.WriteLine("[Auth] seeded a default admin (admin/admin123) into dbo.app_user — change this password immediately.");
        }
    }

    // Legacy users.json reader — used ONLY by the one-time SeedOrImport migration.
    static List<UserRec> ParseUsersFile()
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
            var un = (string?)o["username"] ?? "";
            if (string.IsNullOrWhiteSpace(un)) continue;
            list.Add(new UserRec
            {
                Username = un,
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

    // SHA256 of "salt:pwd" as lowercase hex (serve-ops.ps1 lines 67-70; identical to erp-dashboard so legacy
    // users.json hashes import and verify with no lockout).
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

    // ---- mutations (admin CRUD + L!NK auto-provision): write SQL then reload the snapshot ----
    static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

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

    public static void SaveUsers(IReadOnlyList<UserRec> users)
    {
        lock (_fileLock) { WriteUsers(users); }
        LoadAll();
    }
}
