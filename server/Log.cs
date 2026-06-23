using System.Text;

namespace Ops;

// Application error log. The .NET app previously discarded every handler exception (the catch sites returned
// { error = ex.Message } to the client and kept NO server-side record), so there was nothing to diagnose from at
// a customer site. Log.Error appends one record per failure to ops-error.log under the repo root; the IT-Admin
// "Audit & Health" tab reads the tail so support can see errors WITHOUT database/file-share access.
//
// Defensive like Auth.Audit: logging must NEVER throw (a failed write must not turn a handled 500 into a crash).
public static class Log
{
    static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    static readonly object _lock = new();

    // A short correlation id so a user-reported 500 can be matched to its log line. Time-seeded + a GUID tail;
    // uniqueness, not secrecy, is the goal.
    public static string NewCorrId() => Guid.NewGuid().ToString("N").Substring(0, 8);

    // Record a handled exception. `where` is the route/handler context (e.g. "GET /api-ops/worklist").
    // Returns the correlation id so the caller may echo it to the client.
    public static string Error(string where, Exception ex, string? corrId = null)
    {
        var id = corrId ?? NewCorrId();
        try
        {
            // tab-separated header line + indented stack, matching the readable shape of admin-audit.log.
            var sb = new StringBuilder();
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")).Append('\t')
              .Append(id).Append('\t')
              .Append(where).Append('\t')
              .Append(ex.GetType().Name).Append(": ")
              .Append((ex.Message ?? "").Replace("\r", " ").Replace("\n", " "))
              .Append("\r\n");
            var st = ex.StackTrace;
            if (!string.IsNullOrEmpty(st)) sb.Append("    ").Append(st.Replace("\r\n", "\n").Replace("\n", "\n    ")).Append("\r\n");
            lock (_lock)
                File.AppendAllText(Path.Combine(Config.RepoRoot, "ops-error.log"), sb.ToString(), Utf8NoBom);
        }
        catch { /* never let logging break the request */ }
        return id;
    }
}
