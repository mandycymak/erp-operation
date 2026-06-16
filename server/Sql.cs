using System.Collections.Concurrent;
using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Ops;

// Row type: every query row is a case-insensitive name->value map (DBNull mapped to null), mirroring the
// [pscustomobject] rows RunQ/RunMulti returned in serve-ops.ps1. Handlers read r["job_no"], r["light"], etc.
using Row = System.Collections.Generic.IDictionary<string, object>;

// Per-request state — the heart of the migration. serve-ops.ps1 kept the current user in the shared
// $script:CurUser; here a fresh ReqState is built per request and passed to every handler, so two concurrent
// requests can never read each other's scope. User == null means OPEN / unrestricted (the '(open)' no-auth
// path, tier 'admin'); an authenticated user with empty stations/access is also unrestricted on those dims.
public sealed class ReqState
{
    public UserRec? User;                       // null = open mode (unrestricted)
    public string Me = "(open)";                // session username (notes / @-mentions / "my work")
    public bool Open => User == null;
    public string Tier => User?.Role ?? "admin";
}

// A handler result carrying an explicit HTTP status (admin/auth endpoints return 400/401/403/404).
public sealed record Resp(object Body, int Code = 200);

// Query-string wrapper: q["x"] returns the value, or null when absent/empty — so handler code reads like the
// PowerShell `if ($qs["x"])` truthiness (null/empty = falsey).
public sealed class Qs
{
    readonly IQueryCollection _q;
    public Qs(IQueryCollection q) { _q = q; }
    public string? this[string k] { get { var v = _q[k].ToString(); return string.IsNullOrEmpty(v) ? null : v; } }
}

public static class Db
{
    // --- value coercion helpers (port of the [string]/[int]/[double] casts) ---
    public static double Num(object? v) => v == null ? 0 : Convert.ToDouble(v);
    public static int IntOf(object? v) => v == null ? 0 : Convert.ToInt32(v);
    public static string Str(object? v) => v?.ToString() ?? "";
    public static object? G(Row r, string k) => r.TryGetValue(k, out var v) ? v : null;

    static void AddParams(SqlCommand cmd, IDictionary<string, object?> p)
    {
        foreach (var kv in p) cmd.Parameters.AddWithValue("@" + kv.Key, kv.Value ?? DBNull.Value);
    }

    static Row ReadRow(SqlDataReader r)
    {
        var o = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < r.FieldCount; i++) { var v = r.GetValue(i); o[r.GetName(i)] = v is DBNull ? null! : v; }
        return o;
    }

    // serve-ops.ps1 lines 207-219: VPN drops are transient; one fresh-connection retry. A query TIMEOUT is NOT
    // retried (it would only hold a slot longer on the single SQL box).
    static bool IsTransient(Exception ex) =>
        Regex.IsMatch(ex.Message, "semaphore timeout|transport-level|network-related|forcibly closed|not currently available|timeout period elapsed|pre-login", RegexOptions.IgnoreCase);
    static bool IsTimeout(Exception ex) =>
        Regex.IsMatch(ex.Message, "Timeout expired|Execution Timeout|timeout period elapsed", RegexOptions.IgnoreCase);
    static void ResetConn(SqlConnection cn) { try { if (cn.State != ConnectionState.Open) { cn.Close(); cn.Open(); } } catch { try { cn.Open(); } catch { } } }

    // Raw ADO (not Dapper): mirrors the PowerShell RunQ reader loop exactly — DBNull -> null, only real SELECTs
    // yield a result set — so the handlers' row-shape assumptions carry over unchanged.
    public static List<Row> RunQ(SqlConnection cn, string sql, IDictionary<string, object?> p, int timeoutSec = 45)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var cmd = cn.CreateCommand();
                cmd.CommandText = sql; cmd.CommandTimeout = timeoutSec; AddParams(cmd, p);
                using var r = cmd.ExecuteReader();
                var rows = new List<Row>();
                while (r.Read()) rows.Add(ReadRow(r));
                return rows;
            }
            catch (Exception ex)
            {
                if (attempt >= 2 || IsTimeout(ex) || !IsTransient(ex)) throw;
                ResetConn(cn); Thread.Sleep(300 * attempt);
            }
        }
    }

    public static List<List<Row>> RunMulti(SqlConnection cn, string sql, IDictionary<string, object?> p, int timeoutSec = 45)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var cmd = cn.CreateCommand();
                cmd.CommandText = sql; cmd.CommandTimeout = timeoutSec; AddParams(cmd, p);
                using var r = cmd.ExecuteReader();
                var sets = new List<List<Row>>();
                do
                {
                    var rows = new List<Row>();
                    while (r.Read()) rows.Add(ReadRow(r));
                    sets.Add(rows);
                } while (r.NextResult());
                return sets;
            }
            catch (Exception ex)
            {
                if (attempt >= 2 || IsTimeout(ex) || !IsTransient(ex)) throw;
                ResetConn(cn); Thread.Sleep(300 * attempt);
            }
        }
    }

    // Execute a non-query (INSERT/UPDATE/MERGE) with the same transient retry; returns rows affected.
    public static int Exec(SqlConnection cn, string sql, IDictionary<string, object?> p, int timeoutSec = 45)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                using var cmd = cn.CreateCommand();
                cmd.CommandText = sql; cmd.CommandTimeout = timeoutSec; AddParams(cmd, p);
                return cmd.ExecuteNonQuery();
            }
            catch (Exception ex)
            {
                if (attempt >= 2 || IsTimeout(ex) || !IsTransient(ex)) throw;
                ResetConn(cn); Thread.Sleep(300 * attempt);
            }
        }
    }

    // does a column exist? cached per process per (db.table.col) — used for schema-drift guards.
    static readonly ConcurrentDictionary<string, bool> _colCache = new();
    public static bool ColExists(SqlConnection cn, string table, string col)
    {
        var key = $"{cn.Database}.{table}.{col}";
        return _colCache.GetOrAdd(key, _ =>
        {
            try
            {
                var r = RunQ(cn, "SELECT 1 hit FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME=@t AND COLUMN_NAME=@c",
                    new Dictionary<string, object?> { ["t"] = table, ["c"] = col }, 6);
                return r.Count > 0;
            }
            catch { return false; }
        });
    }

    // --- small SQL-text helpers ported from serve-ops.ps1 ---
    // escape user text for a parameterised LIKE (bracket-escape the wildcards; no ESCAPE clause needed)
    public static string LikeEsc(string s) => s.Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]");
    // comma-separated query param -> trimmed, deduped, capped list (multi-select filters)
    public static string[] ParseList(string? s, int max = 50) =>
        (s ?? "").Split(',').Select(x => x.Trim()).Where(x => x != "").Distinct().Take(max).ToArray();
}
