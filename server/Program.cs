using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.FileProviders;
using Ops;

Config.Load();
Auth.LoadAll();
Settings.Load();   // runtime ERP-connection overrides from dbo.app_setting (admin "ERP API" tab); falls back to Config

var builder = WebApplication.CreateBuilder(args);

// Bind the configured port (ops.config.json `port`, default 8078) so the .NET app is a drop-in for the
// PowerShell server. OPS_HTTP_PORT overrides (e.g. 5079 to run beside serve-ops.ps1 during the migration);
// OPS_HOST overrides the host (+ / 0.0.0.0 for LAN). Behind IIS (Stage 6) ANCM sets the URL, ignoring this.
var httpPort = Environment.GetEnvironmentVariable("OPS_HTTP_PORT");
var port = !string.IsNullOrWhiteSpace(httpPort) ? int.Parse(httpPort) : Config.Port;
var host = Environment.GetEnvironmentVariable("OPS_HOST");
host = string.IsNullOrWhiteSpace(host) ? "localhost" : (host == "+" ? "0.0.0.0" : host);
builder.WebHost.UseUrls($"http://{host}:{port}");

// Book Now async push: drains dbo.book_pending off the request path (the ERP /booking/update takes ~10s, so the
// operator never waits) and notifies the creator via My Tasks once the ERP confirms. Survives restarts.
builder.Services.AddHostedService<BookingPusher>();

var app = builder.Build();

// Exact JSON shape parity with PS ConvertTo-Json: emit property names verbatim (no camelCase transform),
// compact. The client depends on the exact keys (ok, worst, checklist, route_json, stationCode, ...).
var jsonOpts = new JsonSerializerOptions { PropertyNamingPolicy = null, WriteIndented = false };

// ---- concurrency lever: the single SQL server over a small-MTU VPN is the real ceiling, so bound the number of
// in-flight DB ops (Kestrel is multi-threaded; 500 users must not stampede the box). OPS_DB_GATE tunes it.
// NOTE on response caching: unlike the read-mostly dashboard (which caches unrestricted reads in a shared
// MemoryCache), erp-operation deliberately has NO generic cross-user response cache. Almost every ops read is
// per-user (worklist/my-tasks/roster key off rs.Me even for admins) or write-volatile (the worklist changes on
// every milestone tick), so a shared cache would risk serving one user's scope/identity to another - the exact
// cross-scope leak this migration exists to remove. The one large reference read (ports, ~5k rows, identical for
// everyone) self-caches inside Handlers.Ports (15 min). Everything else computes live behind the dbGate.
var dbGate = new SemaphoreSlim(int.TryParse(Environment.GetEnvironmentVariable("OPS_DB_GATE"), out var g) && g > 0 ? g : 16);

// shared outbound HttpClient (SWIVEL L!NK OAuth redeem; ERP API client lives in Erp.cs, Stage 4)
var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };

// Stage 6 (HTTPS via IIS): honor X-Forwarded-Proto/For so Request.IsHttps + client IP are correct behind the
// reverse proxy. IIS is the single trusted front, so clear the proxy allow-lists.
var fwd = new ForwardedHeadersOptions { ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto };
fwd.KnownIPNetworks.Clear(); fwd.KnownProxies.Clear();
app.UseForwardedHeaders(fwd);
if (Config.Https) app.UseHsts();

// Every response (API + static) is no-store; API responses also carry the permissive CORS header. Mirrors
// Send-Json / Send-File. Set via OnStarting so it applies even when a later handler writes the body.
app.Use(async (ctx, next) =>
{
    var p = ctx.Request.Path;
    var isApi = p.StartsWithSegments("/api-ops") || p.StartsWithSegments("/api-doc");
    ctx.Response.OnStarting(() =>
    {
        var h = ctx.Response.Headers;
        h["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0";
        h["Pragma"] = "no-cache";
        h["Expires"] = "0";
        if (isApi)
        {
            // permissive CORS for third-party callers (bearer-token, no cookies -> '*' is safe). The preflight
            // needs Allow-Methods/Headers too, else a cross-origin POST with Authorization+JSON is blocked.
            h["Access-Control-Allow-Origin"] = "*";
            h["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS";
            h["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-Ops-User";
            h["Access-Control-Max-Age"] = "600";
        }
        return Task.CompletedTask;
    });
    // answer the CORS preflight directly (no auth / no body) so browser clients can call the API cross-origin.
    if (isApi && HttpMethods.IsOptions(ctx.Request.Method)) { ctx.Response.StatusCode = 204; return; }
    await next();
});

async Task Json(HttpContext ctx, object obj, int code = 200)
{
    ctx.Response.StatusCode = code;
    ctx.Response.ContentType = "application/json; charset=utf-8";
    await ctx.Response.WriteAsync(JsonSerializer.Serialize(obj, jsonOpts), Encoding.UTF8);
}

async Task<JsonElement> ReadBody(HttpContext ctx)
{ try { return await JsonSerializer.DeserializeAsync<JsonElement>(ctx.Request.Body); } catch { return default; } }

// open-mode identity source (X-Ops-User header / ?as= / '(open)') — mirrors Me-User. NOT a security boundary.
string OpenMeUser(HttpContext ctx)
{
    var h = ctx.Request.Headers["X-Ops-User"].ToString().Trim();
    if (h != "") return h;
    var q = ctx.Request.Query["as"].ToString().Trim();
    return q != "" ? q : "(open)";
}

// Get-OpsSession: no users.json -> open mode (pseudo-session from the header identity). Else cookie -> session
// -> sliding 12h. Returns null when auth is on but no valid session cookie is present.
Session? GetSession(HttpContext ctx)
{
    if (!Auth.Snap.AuthOn)
    {
        var u = OpenMeUser(ctx);
        return new Session { Username = u, Role = "admin", Admin = true, DisplayName = u, Expires = DateTime.Now.AddHours(12) };
    }
    var sid = ctx.Request.Cookies["ops_sid"];
    if (sid != null && Auth.Sessions.TryGetValue(sid, out var s))
    {
        if (s.Expires < DateTime.Now) { Auth.Sessions.TryRemove(sid, out _); return null; }
        s.Expires = DateTime.Now.AddHours(12);
        return s;
    }
    // No cookie session -> try a JWT bearer (third-party API callers: Swivel L!NK / Cargoclip). The token's
    // email federates to a user; the returned Session is transient (NOT persisted to Auth.Sessions — JWT is
    // stateless, validated fresh each request). Resolve() then re-reads the UserRec and builds scope as usual.
    return JwtSession(ctx);
}

// Build a transient Session from a validated "Authorization: Bearer <jwt>". Returns null (no token / invalid /
// unknown email with no auto-provision) so the caller emits 401. Fails closed.
Session? JwtSession(HttpContext ctx)
{
    if (!Config.JwtEnabled) return null;
    var hdr = ctx.Request.Headers["Authorization"].ToString().Trim();
    if (!hdr.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) return null;
    var id = Jwt.ValidateEmail(hdr.Substring(7).Trim());
    if (id == null) return null;
    var u = Auth.FindUserByEmail(id.Value.Email);
    if (u == null)
    {
        if (!Config.JwtAutoProvision) return null;
        u = Auth.ProvisionLinkUser(id.Value.Email, id.Value.DisplayName);
    }
    var dn = string.IsNullOrWhiteSpace(u.DisplayName) ? u.Username : u.DisplayName.Trim();
    return new Session { Username = u.Username, Role = u.Role, Admin = u.Admin, DisplayName = dn, Expires = DateTime.Now.AddHours(12) };
}

// Build the per-request ReqState (the migration's core: scope lives here, never in shared state). In auth mode
// the user is re-read live so admin edits apply now and a deleted user's session is killed. Returns null AFTER
// writing 401 if the session's user vanished mid-flight.
async Task<ReqState?> Resolve(HttpContext ctx, Session sess)
{
    if (!Auth.Snap.AuthOn) return new ReqState { User = null, Me = sess.Username };
    var cu = Auth.FindUser(sess.Username);
    if (cu == null)
    {
        var sid = ctx.Request.Cookies["ops_sid"]; if (sid != null) Auth.Sessions.TryRemove(sid, out _);
        await Json(ctx, new { error = "Authentication required" }, 401); return null;
    }
    return new ReqState { User = cu, Me = sess.Username };
}

object NewSessionPayload(HttpContext ctx, UserRec u)
{
    var dn = string.IsNullOrWhiteSpace(u.DisplayName) ? u.Username : u.DisplayName.Trim();
    var sid = Guid.NewGuid().ToString("N");
    Auth.Sessions[sid] = new Session { Username = u.Username, Role = u.Role, Admin = u.Admin, DisplayName = dn, Expires = DateTime.Now.AddHours(12) };
    ctx.Response.Headers.Append("Set-Cookie", Auth.SessionCookie(sid));
    return new { username = u.Username, displayName = dn, role = u.Role, admin = u.Admin };
}

// ================= public (SQL-free) endpoints =================

app.MapGet("/api-ops/config", (HttpContext ctx) => Json(ctx, new
{
    appName = Config.AppName,
    instanceName = Config.InstanceName,
    appSubtitle = Config.AppSubtitle,
    stationCode = Config.StationCode,
    stations = Config.Stations.Select(s => new { code = s.Code, name = s.Name }).ToArray(),
    linkEnabled = Config.LinkEnabled,
}));

// Liveness/readiness probe for the watchdog (ops-healthcheck.ps1) and any external uptime monitor. Unauthenticated
// (same exposure class as /config — only instance/version are revealed, no secrets). Opens ONE ops-DB connection
// with a SHORT connect timeout so a down DB trips quickly, runs SELECT 1, and returns 200 ok / 503 db:down. The
// RICH admin view (history, storage, audit) is /api-ops/admin/health — this one stays tiny and dependency-light.
app.MapGet("/api-ops/health", async (HttpContext ctx) =>
{
    var version = typeof(Config).Assembly.GetName().Version?.ToString() ?? "";
    var utc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
    try
    {
        // 5 s connect timeout so an unreachable DB doesn't hang the probe for the default 30 s.
        var probeConn = Config.ConnStr.Replace("Connect Timeout=30", "Connect Timeout=5");
        using var cn = new SqlConnection(probeConn);
        await cn.OpenAsync();
        using var cmd = cn.CreateCommand();
        cmd.CommandText = "SELECT 1"; cmd.CommandTimeout = 5;
        await cmd.ExecuteScalarAsync();
        await Json(ctx, new { ok = true, db = "up", opsDb = Config.OpsDb, instance = Config.InstanceName, version, utc });
    }
    catch (Exception ex)
    {
        await Json(ctx, new { ok = false, db = "down", error = ex.Message, instance = Config.InstanceName, version, utc }, 503);
    }
});

// email is the login key; accept the legacy 'username' field too, and fall back to a username match so no one
// is locked out during the email-login switch (serve-ops.ps1 Handle-OpsLogin).
app.MapPost("/api-ops/login", async (HttpContext ctx) =>
{
    var j = await ReadBody(ctx);
    var email = j.ValueKind == JsonValueKind.Object && j.TryGetProperty("email", out var em) ? em.GetString() : null;
    var username = j.ValueKind == JsonValueKind.Object && j.TryGetProperty("username", out var un) ? un.GetString() : null;
    var password = j.ValueKind == JsonValueKind.Object && j.TryGetProperty("password", out var pw) ? pw.GetString() : null;
    var id = !string.IsNullOrWhiteSpace(email) ? email!.Trim() : (username ?? "").Trim();
    var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "";
    var u = Auth.FindUserByEmail(id) ?? Auth.FindUser(id);
    if (u == null || string.IsNullOrEmpty(u.PwdHash) || Auth.HashPwd(u.Salt, password ?? "") != u.PwdHash)
    {
        // record the failed attempt (access-control evidence / brute-force visibility) — surfaced in the IT-Admin tab.
        Auth.Audit(id == "" ? "(blank)" : id, $"login FAILED ip={ip}");
        await Json(ctx, new { error = "Invalid email or password" }, 401); return;
    }
    Auth.Audit(u.Username, $"login ok (local) ip={ip}");
    await Json(ctx, NewSessionPayload(ctx, u));
});

app.MapMethods("/api-ops/logout", new[] { "GET", "POST", "DELETE" }, async (HttpContext ctx) =>
{
    var sid = ctx.Request.Cookies["ops_sid"];
    if (sid != null && Auth.Sessions.TryGetValue(sid, out var s)) Auth.Audit(s.Username, "logout");
    if (sid != null) Auth.Sessions.TryRemove(sid, out _);
    ctx.Response.Headers.Append("Set-Cookie", "ops_sid=; Path=/; Max-Age=0");
    await Json(ctx, new { ok = true });
});

// SWIVEL L!NK OAuth code-flow sign-in: redeem the one-time code server-side at the profile URL (no
// client_id/secret — the code self-authenticates), verify the echoed state, match profile.email to a user
// (auto-provisioning when enabled), then mint our own session. Inert (501) until configured.
app.MapPost("/api-ops/link-oauth-login", async (HttpContext ctx) =>
{
    if (!Auth.Snap.AuthOn) { await Json(ctx, new { error = "L!NK sign-in needs auth mode (users.json present)" }, 400); return; }
    if (!Config.LinkEnabled) { await Json(ctx, new { error = "SWIVEL L!NK sign-in is not enabled on this instance" }, 501); return; }
    var j = await ReadBody(ctx);
    var code = j.ValueKind == JsonValueKind.Object && j.TryGetProperty("code", out var c) ? (c.GetString() ?? "").Trim() : "";
    var state = j.ValueKind == JsonValueKind.Object && j.TryGetProperty("state", out var st) ? (st.GetString() ?? "").Trim() : "";
    if (code == "" || state == "") { await Json(ctx, new { error = "Missing OAuth code or state" }, 400); return; }

    JsonElement resp;
    try
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, Config.LinkProfileUrl)
        {
            Content = new StringContent(JsonSerializer.Serialize(new { code }), Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrWhiteSpace(Config.LinkXSystem)) req.Headers.TryAddWithoutValidation("x-system", Config.LinkXSystem);
        var r = await http.SendAsync(req);
        r.EnsureSuccessStatusCode();
        resp = JsonSerializer.Deserialize<JsonElement>(await r.Content.ReadAsStringAsync());
    }
    catch { await Json(ctx, new { error = "Invalid or expired L!NK sign-in" }, 401); return; }

    var echoedState = resp.TryGetProperty("state", out var se) ? (se.GetString() ?? "").Trim() : "";
    if (echoedState != state) { await Json(ctx, new { error = "Invalid or expired L!NK sign-in" }, 401); return; }
    var prof = resp.TryGetProperty("profile", out var pe) ? pe : default;
    var email = prof.ValueKind == JsonValueKind.Object && prof.TryGetProperty("email", out var ee) ? (ee.GetString() ?? "").Trim() : "";
    if (email == "" && prof.ValueKind == JsonValueKind.Object && prof.TryGetProperty("userName", out var ue)) email = (ue.GetString() ?? "").Trim();
    if (email == "") { await Json(ctx, new { error = "L!NK profile has no email to match" }, 401); return; }

    var u = Auth.FindUserByEmail(email);
    if (u == null)
    {
        if (!Config.LinkAutoProvision) { await Json(ctx, new { error = $"No account for {email} - ask an admin to add you" }, 403); return; }
        var dn = prof.ValueKind == JsonValueKind.Object && prof.TryGetProperty("displayName", out var de) ? (de.GetString() ?? "") : "";
        u = Auth.ProvisionLinkUser(email, dn);
    }
    Auth.Audit(u.Username, $"L!NK sign-in ({email})");
    await Json(ctx, NewSessionPayload(ctx, u));
});

// ================= authenticated endpoints =================

// authenticated endpoint that needs NO DB connection (me / notes / my-tasks read off the file store).
void MapAuthed(string path, string[] methods, Func<HttpContext, Session, ReqState, Task> h)
{
    app.MapMethods(path, methods, async (HttpContext ctx) =>
    {
        var sess = GetSession(ctx);
        if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
        var rs = await Resolve(ctx, sess); if (rs == null) return;
        await h(ctx, sess, rs);
    });
}

// data endpoint (auth required, opens ONE connection per request, gated for scale). Scope-aware caching is
// added in Stage 6; Stage 2+ register handlers here.
void MapData(string path, Func<SqlConnection, Qs, ReqState, object> handler)
{
    app.MapGet(path, async (HttpContext ctx) =>
    {
        var sess = GetSession(ctx);
        if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
        var rs = await Resolve(ctx, sess); if (rs == null) return;
        var qs = new Qs(ctx.Request.Query);
        await dbGate.WaitAsync();
        try
        {
            using var cn = new SqlConnection(Config.ConnStr);
            cn.Open();
            await Json(ctx, handler(cn, qs, rs));
        }
        catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
        finally { dbGate.Release(); }
    });
}

// write endpoint that needs a DB connection + the JSON body (POST). Auth + per-request ReqState + dbGate.
void MapDataPost(string path, Func<SqlConnection, JsonElement, ReqState, object> handler)
{
    app.MapPost(path, async (HttpContext ctx) =>
    {
        var sess = GetSession(ctx);
        if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
        var rs = await Resolve(ctx, sess); if (rs == null) return;
        var body = await ReadBody(ctx);
        await dbGate.WaitAsync();
        try
        {
            using var cn = new SqlConnection(Config.ConnStr);
            cn.Open();
            await Json(ctx, handler(cn, body, rs));
        }
        catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
        finally { dbGate.Release(); }
    });
}

// /api-ops/me — current user profile (Me-PayloadOps). No DB.
MapAuthed("/api-ops/me", new[] { "GET" }, (ctx, sess, rs) =>
{
    if (!Auth.Snap.AuthOn)
        return Json(ctx, new { user = sess.Username, username = sess.Username, authOn = false, today = Config.TodayStr() });
    var u = rs.User!;
    return Json(ctx, new
    {
        user = sess.Username,
        username = sess.Username,
        authOn = true,
        today = Config.TodayStr(),
        displayName = sess.DisplayName,
        role = sess.Role,
        admin = sess.Admin,
        language = u.Language,
        teams = u.Teams,
        stations = u.Stations,
        primaryStation = u.PrimaryStation,
        access = u.Access,
        erpUsers = u.ErpUsers,
    });
});

// ---- Stage 2: core reads ----
MapData("/api-ops/roster", Handlers.Roster);
MapData("/api-ops/companies", Handlers.Companies);
MapData("/api-ops/ports", Handlers.Ports);
MapData("/api-ops/inbound", Handlers.Inbound);
MapData("/api-ops/new-bookings", Handlers.NewBookings);   // newly-received bookings, scoped to the caller's station(s)
MapData("/api-ops/booking-job", Handlers.BookingJob);     // resolve a booking number -> its worklist job_no (Book Now note edit)
MapData("/api-ops/my-tasks", Handlers.MyTasks);
MapData("/api-ops/worklist", Handlers.Worklist);
MapData("/api-ops/find", Handlers.Find);
MapData("/api-ops/shipment", Handlers.Shipment);

// POST /api-ops/parse-find — OPTIONAL LLM fallback for Find (Part 4). Inert (501) unless Config.LlmEnabled
// (the `llm.enabled` flag + an API key). Auth required; NO DB. Returns the LLM-suggested clue object (same shape
// as the client rule parser) so the client can re-run /api-ops/find with it. The LLM never touches the DB or
// scope — all security stays in the find SQL + Scope.* clauses.
app.MapPost("/api-ops/parse-find", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    if (!Config.LlmEnabled) { await Json(ctx, new { error = "LLM fallback is not enabled on this instance", enabled = false }, 501); return; }
    var body = await ReadBody(ctx);
    var text = body.ValueKind == JsonValueKind.Object && body.TryGetProperty("text", out var t) ? (t.GetString() ?? "") : "";
    var clue = await Llm.ParseFind(text, http);
    if (clue == null) { await Json(ctx, new { error = "parse failed", provider = Config.LlmProvider }, 502); return; }
    await Json(ctx, new { clue, provider = Config.LlmProvider, source = "llm" });
});

// POST /api-ops/find-text — natural-language Find for third-party API callers (and any client that prefers to
// send raw text instead of pre-parsed clues). Parses server-side (OpsQuery.Parse), runs the SHARED FindCore
// under the caller's scope (so data restriction is identical to the worklist), and — when the rule parse finds
// nothing AND the LLM is enabled — falls back to the LLM parser, exactly like the browser. Auth via GetSession,
// which now also accepts an "Authorization: Bearer <jwt>" carrying the user's email. Needs a DB connection + the
// shared HttpClient for the optional LLM. Body: { "text": "...", "useLlm": true|false }.
app.MapPost("/api-ops/find-text", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    var body = await ReadBody(ctx);
    var text = body.ValueKind == JsonValueKind.Object && body.TryGetProperty("text", out var t) ? (t.GetString() ?? "") : "";
    var useLlm = !(body.ValueKind == JsonValueKind.Object && body.TryGetProperty("useLlm", out var ul) && ul.ValueKind == JsonValueKind.False);
    await dbGate.WaitAsync();
    try
    {
        using var cn = new SqlConnection(Config.ConnStr);
        cn.Open();
        // API default: search everything the user is allowed to see (scope still applies), not just shipments they
        // personally handle. The caller opts back into the involvement lens by saying "my"/"mine". (The browser
        // worklist keeps "mine" as its default via the client.)
        var wantMine = System.Text.RegularExpressions.Regex.IsMatch(text ?? "", @"\b(my|mine)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        var clue = OpsQuery.Parse(text);
        clue.Mine = wantMine && clue.Ref == "";
        var r = Handlers.FindCore(cn, clue, rs);
        var source = "rule";
        if (r.Items.Length == 0 && useLlm && Config.LlmEnabled)
        {
            var llm = await Llm.ParseFind(text, http);
            if (llm != null)
            {
                var lclue = Handlers.ClueFromJson(llm);
                lclue.Mine = wantMine && lclue.Ref == "";
                var lr = Handlers.FindCore(cn, lclue, rs);
                if (lr.Items.Length > 0) { r = lr; source = "llm"; }
            }
        }
        await Json(ctx, new { query = text, source, items = r.Items, resolved = r.Resolved });
    }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
    finally { dbGate.Release(); }
});
// ---- Stage 3: writes + admin + feed-assign ----
// notes: GET = file-store list; POST = save (both file-only, no DB).
MapAuthed("/api-ops/notes", new[] { "GET", "POST" }, async (ctx, sess, rs) =>
{
    if (ctx.Request.Method == "POST") await Json(ctx, Handlers.SaveNote(await ReadBody(ctx), rs.Me));
    else await Json(ctx, Handlers.NoteList(new Qs(ctx.Request.Query)));
});
MapAuthed("/api-ops/note-done", new[] { "POST" }, async (ctx, sess, rs) => await Json(ctx, Handlers.SaveNoteDone(await ReadBody(ctx), rs.Me)));
MapDataPost("/api-ops/milestone-close", Handlers.MilestoneClose);
MapDataPost("/api-ops/inbound-assign", Handlers.InboundAssign);

// admin CRUD (admin-gated inside Handlers.Admin) — users / milestones / evidence / erp-settings.
MapAuthed("/api-ops/admin/{*rest}", new[] { "GET", "POST" }, async (ctx, sess, rs) =>
{
    var r = Handlers.Admin(ctx.Request.Path, ctx.Request.Method, await ReadBody(ctx), new Qs(ctx.Request.Query), sess);
    await Json(ctx, r.Body, r.Code);
});

// ---- Stage 4: ERP integration ----
MapData("/api-ops/erp-detail", Handlers.ErpDetail);   // source-ERP read (the one sanctioned ERP-on-request exception)
MapData("/api-ops/erp-edit", Handlers.ErpEditSeed);   // seed the ERP-correction editor (source-ERP read)
MapData("/api-ops/erp-master", Handlers.ErpMaster);   // master code type-ahead (source-ERP read)
MapData("/api-ops/erp-master-detail", Handlers.ErpMasterDetail);   // full party master record (fill-from-master)
MapData("/api-ops/book-now-seed", Handlers.BookNowSeed);     // Book Now: station + default POL/service per mode
MapData("/api-ops/book-now-master", Handlers.BookNowMaster); // Book Now: station-scoped master type-ahead (no job)
// ---- Stage 4b: Swivel ERP HTTP write client ----
MapData("/api-ops/erp-files", Handlers.ErpFiles);                 // list ERP-held files (+ clearable doctypes)
MapDataPost("/api-ops/erp-file-upload", Handlers.ErpFileUpload);  // upload a doc -> clear the milestone(s) it proves

// erp-file-download streams bytes (not JSON), and erp-edit-save needs the client IP for erp_edit_log, so both are
// registered as custom routes here rather than via MapData/MapDataPost.
app.MapGet("/api-ops/erp-file-download", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    var qs = new Qs(ctx.Request.Query);
    await dbGate.WaitAsync();
    try
    {
        using var cn = new SqlConnection(Config.ConnStr);
        cn.Open();
        var res = Handlers.ErpFileDownload(cn, qs, rs);
        if (res == null) { ctx.Response.StatusCode = 404; await ctx.Response.CompleteAsync(); return; }
        ctx.Response.StatusCode = 200;
        ctx.Response.ContentType = res.Ctype;
        ctx.Response.Headers["Content-Disposition"] = $"inline; filename=\"{res.Name.Replace("\"", "")}\"";
        await ctx.Response.Body.WriteAsync(res.Bytes);
    }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); ctx.Response.StatusCode = 404; try { await ctx.Response.CompleteAsync(); } catch { } }
    finally { dbGate.Release(); }
});

app.MapPost("/api-ops/erp-edit-save", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    var body = await ReadBody(ctx);
    var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "";
    await dbGate.WaitAsync();
    try
    {
        using var cn = new SqlConnection(Config.ConnStr);
        cn.Open();
        await Json(ctx, Handlers.ErpEditSave(cn, body, rs, ip));
    }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
    finally { dbGate.Release(); }
});

// POST /api-ops/book-now — quick-create a NEW booking in the ERP (auto bookingNo). Needs the client IP for the
// erp_edit_log audit row, so it's a custom route like erp-edit-save rather than MapDataPost.
app.MapPost("/api-ops/book-now", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    var body = await ReadBody(ctx);
    var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "";
    await dbGate.WaitAsync();
    try
    {
        using var cn = new SqlConnection(Config.ConnStr);
        cn.Open();
        await Json(ctx, Handlers.BookNowCreate(cn, body, rs, ip));
    }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
    finally { dbGate.Release(); }
});

// ---- Stage 5: draft-doc review (staff, /api-ops/doc*) ----
MapData("/api-ops/docs", Handlers.DocList);
MapData("/api-ops/doc", Handlers.DocGet);
MapData("/api-ops/doc-events", Handlers.DocEvents);
MapData("/api-ops/doc-attach-list", Handlers.DocAttachListQ);
MapDataPost("/api-ops/doc-create", Handlers.DocCreate);
MapDataPost("/api-ops/doc-save", Handlers.DocSave);
MapDataPost("/api-ops/doc-send", Handlers.DocSend);
MapDataPost("/api-ops/doc-token-revoke", Handlers.DocTokenRevoke);
MapDataPost("/api-ops/doc-agree", Handlers.DocAgree);
MapDataPost("/api-ops/doc-issue", Handlers.DocIssue);
MapDataPost("/api-ops/doc-amend", Handlers.DocAmend);
MapDataPost("/api-ops/doc-attach", Handlers.DocAttachSave);
MapDataPost("/api-ops/doc-attach-delete", Handlers.DocAttachDelete);

// blob sender shared by the staff + public attachment-file routes (no-store already set by middleware)
async Task SendBlob(HttpContext ctx, Handlers.BlobResult? res)
{
    if (res == null) { ctx.Response.StatusCode = 404; await ctx.Response.CompleteAsync(); return; }
    ctx.Response.StatusCode = 200;
    ctx.Response.ContentType = res.Ctype;
    ctx.Response.Headers["Content-Disposition"] = $"inline; filename=\"{res.Name.Replace("\"", "")}\"";
    await ctx.Response.Body.WriteAsync(res.Bytes);
}

// staff attachment blob (auth + DB)
app.MapGet("/api-ops/doc-attach-file", async (HttpContext ctx) =>
{
    var sess = GetSession(ctx);
    if (sess == null) { await Json(ctx, new { error = "Authentication required" }, 401); return; }
    var rs = await Resolve(ctx, sess); if (rs == null) return;
    var qs = new Qs(ctx.Request.Query);
    await dbGate.WaitAsync();
    try { using var cn = new SqlConnection(Config.ConnStr); cn.Open(); await SendBlob(ctx, Handlers.DocAttachFile(cn, qs, rs)); }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); ctx.Response.StatusCode = 404; try { await ctx.Response.CompleteAsync(); } catch { } }
    finally { dbGate.Release(); }
});

// ---- Stage 5: public customer review (/api-doc/*: the token IS the authority - no session) ----
async Task PublicJson(HttpContext ctx, Func<SqlConnection, string, object> h)
{
    var raw = ctx.Request.Query["t"].ToString().Trim();
    await dbGate.WaitAsync();
    try { using var cn = new SqlConnection(Config.ConnStr); cn.Open(); await Json(ctx, h(cn, raw)); }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
    finally { dbGate.Release(); }
}
async Task PublicPost(HttpContext ctx, long cap, Func<SqlConnection, System.Text.Json.JsonElement, string, object> h)
{
    if (ctx.Request.ContentLength > cap) { await Json(ctx, new { error = "request too large" }); return; }   // cap BEFORE reading body
    var body = await ReadBody(ctx);
    var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "";
    await dbGate.WaitAsync();
    try { using var cn = new SqlConnection(Config.ConnStr); cn.Open(); await Json(ctx, h(cn, body, ip)); }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); await Json(ctx, new { error = ex.Message }, 500); }
    finally { dbGate.Release(); }
}

app.MapGet("/api-doc/view", (HttpContext ctx) => PublicJson(ctx, (cn, raw) => Handlers.PublicDocView(cn, raw, ctx.Connection.RemoteIpAddress?.ToString() ?? "")));
app.MapPost("/api-doc/submit", (HttpContext ctx) => PublicPost(ctx, 1048576, (cn, b, ip) => Handlers.PublicDocSubmit(cn, b, ip, false)));
app.MapPost("/api-doc/approve", (HttpContext ctx) => PublicPost(ctx, 1048576, (cn, b, ip) => Handlers.PublicDocSubmit(cn, b, ip, true)));
app.MapPost("/api-doc/attach", (HttpContext ctx) => PublicPost(ctx, 7340032, (cn, b, ip) => Handlers.PublicDocAttach(cn, b, ip)));
app.MapGet("/api-doc/attach-list", (HttpContext ctx) => PublicJson(ctx, (cn, raw) => Handlers.PublicDocAttachList(cn, raw)));
app.MapPost("/api-doc/attach-delete", (HttpContext ctx) => PublicPost(ctx, 7340032, (cn, b, ip) => Handlers.PublicDocAttachDelete(cn, b, ip)));
app.MapGet("/api-doc/attach-file", async (HttpContext ctx) =>
{
    var raw = ctx.Request.Query["t"].ToString().Trim();
    var att = ctx.Request.Query["id"].ToString().Trim();
    await dbGate.WaitAsync();
    try { using var cn = new SqlConnection(Config.ConnStr); cn.Open(); await SendBlob(ctx, Handlers.PublicDocAttachFile(cn, raw, att)); }
    catch (Exception ex) { Log.Error(ctx.Request.Method + " " + ctx.Request.Path, ex); ctx.Response.StatusCode = 404; try { await ctx.Response.CompleteAsync(); } catch { } }
    finally { dbGate.Release(); }
});

// /bl-review/<token> -> the SQL-free review page (page JS reads the token from the URL). Kept separate from
// /api-ops/* so a reverse proxy can expose ONLY /bl-review/* + /api-doc/* + the review assets.
app.MapGet("/bl-review/{*rest}", async (HttpContext ctx) =>
{
    var path = System.IO.Path.Combine(Config.RepoRoot, "bl-review.html");
    if (!File.Exists(path)) { ctx.Response.StatusCode = 404; await ctx.Response.CompleteAsync(); return; }
    ctx.Response.ContentType = "text/html; charset=utf-8";
    await ctx.Response.SendFileAsync(path);
});

// NOTE: an authenticated /api-ops/* call not handled above falls through to the static handler (404).

// ================= static files (client UI) served from the repo root, no-store =================
// SECURITY: the static root also holds secrets (ops.config*.json, users.json, erp-api-map.json,
// erp-edit-fields.json, *.log, the .ps1 scripts) and static serving bypasses auth. The client only fetches
// .html/.js/.css/.svg/.png and talks data over /api-ops/* + /api-doc/*, so deny everything else.
// (serve-ops.ps1 served any file under $Root unguarded — this closes that exposure.)
app.Use(async (ctx, next) =>
{
    var p = (ctx.Request.Path.Value ?? "").ToLowerInvariant();
    var ext = System.IO.Path.GetExtension(p);
    bool sensitive = ext is ".json" or ".ps1" or ".bat" or ".log" or ".config" or ".cs" or ".csproj"
        || p.Contains("/ops-lists/") || p.Contains("/server/") || p.Contains("/erp-mock/") || p.Contains("/.git");
    // doc-fields.json is the one .json the client legitimately fetches (the bill renderer needs it).
    if (p == "/doc-fields.json") sensitive = false;
    // lang/<code>.json are the UI translation dictionaries the client loads (no secrets in them).
    if (p.StartsWith("/lang/") && ext == ".json") sensitive = false;
    if (sensitive && !p.StartsWith("/api-ops") && !p.StartsWith("/api-doc"))
    { ctx.Response.StatusCode = 404; await ctx.Response.CompleteAsync(); return; }
    await next();
});
var files = new PhysicalFileProvider(Config.RepoRoot);
app.UseDefaultFiles(new DefaultFilesOptions { FileProvider = files });   // "/" -> index.html
app.UseStaticFiles(new StaticFileOptions { FileProvider = files, ServeUnknownFileTypes = false });

app.Run();
