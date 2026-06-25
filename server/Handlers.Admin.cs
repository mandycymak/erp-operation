using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    static readonly string[] AccessPairs = { "Air-Export", "Air-Import", "Sea-Export", "Sea-Import" };

    // ---- /api-ops/admin/* (admin-gated; serve-ops.ps1 2008-2196) ----
    public static Resp Admin(string path, string method, JsonElement j, Qs qs, Session sess)
    {
        if (!sess.Admin) return new Resp(new { error = "Admin only" }, 403);
        bool post = method == "POST";
        switch (path)
        {
            case "/api-ops/admin/users": return post ? AdminUserUpsert(j, sess) : AdminUserList();
            case "/api-ops/admin/user-delete": return AdminUserDelete(j, sess);
            case "/api-ops/admin/milestones": return AdminMilestones(j, sess, post);
            case "/api-ops/admin/milestone-delete": return AdminMilestoneDelete(j, sess);
            case "/api-ops/admin/evidence": return AdminEvidence(j, sess, post);
            case "/api-ops/admin/evidence-delete": return AdminEvidenceDelete(j, sess);
            case "/api-ops/admin/erp-settings": return AdminErpSettings(j, sess, post);
            // ---- IT-Admin "Audit & Health" tab: read-only views so support can see audit/health/storage/errors
            //      WITHOUT database access (all GET; admin-gated by the check above). ----
            case "/api-ops/admin/health": return AdminHealth();
            case "/api-ops/admin/storage": return AdminStorage();
            case "/api-ops/admin/audit": return AdminAudit(qs);
            case "/api-ops/admin/errors": return AdminErrors(qs);
            case "/api-ops/admin/erp-api": return AdminErpApi(qs);
            default: return new Resp(new { error = "unknown admin endpoint" }, 404);
        }
    }

    static UserRec Clone(UserRec u) => new()
    {
        Username = u.Username, DisplayName = u.DisplayName, Email = u.Email, Salt = u.Salt, PwdHash = u.PwdHash,
        Role = u.Role, Admin = u.Admin, AuthProvider = u.AuthProvider, Language = u.Language,
        Teams = (string[])u.Teams.Clone(), Stations = (string[])u.Stations.Clone(),
        PrimaryStation = u.PrimaryStation, Access = (string[])u.Access.Clone(), ErpUsers = (string[])u.ErpUsers.Clone(),
    };

    static Resp AdminUserList() => new(new
    {
        users = Auth.Snap.Users.Select(u => new
        {
            username = u.Username, displayName = u.DisplayName, email = u.Email, role = u.Role, admin = u.Admin,
            authProvider = string.IsNullOrWhiteSpace(u.AuthProvider) ? "local" : u.AuthProvider.Trim().ToLowerInvariant(),
            language = u.Language,
            teams = u.Teams, stations = u.Stations, primaryStation = u.PrimaryStation,
            access = u.Access, erpUsers = u.ErpUsers, hasPwd = u.PwdHash != "",
        }).ToArray()
    });

    static Resp AdminUserUpsert(JsonElement j, Session sess)
    {
        var un = j.Str("username").Trim();
        // username may be an email (the house convention is username == email); allow @ and + alongside the handle set.
        if (!System.Text.RegularExpressions.Regex.IsMatch(un, "^[A-Za-z0-9_.@+-]+$"))
            return new Resp(new { error = "Invalid username (use letters, digits and . _ - @ +)" }, 400);
        var role = j.Str("role").Trim().ToLowerInvariant();
        if (role is not ("admin" or "manager" or "operator")) return new Resp(new { error = "Role must be admin, manager or operator" }, 400);
        var em = j.Str("email").Trim();
        if (em == "") return new Resp(new { error = "Email is required (it is the login / L!NK sign-in key)" }, 400);
        if (!System.Text.RegularExpressions.Regex.IsMatch(em, @"^[^@\s]+@[^@\s]+\.[^@\s]+$")) return new Resp(new { error = "Enter a valid email address" }, 400);
        if (Auth.Snap.Users.Any(u => u.Username != un && u.Email.Trim().ToLowerInvariant() == em.ToLowerInvariant()))
            return new Resp(new { error = "Email already assigned to another user" }, 400);
        var authProvider = j.Str("authProvider").Trim().ToLowerInvariant();
        if (authProvider is not ("local" or "swivel" or "both")) authProvider = "local";
        var language = j.Str("language").Trim();              // UI language preference; "" = follow browser/English
        if (language is not ("" or "en" or "zh-Hans" or "ja")) language = "";
        var isAdmin = j.Bool("admin") == true;
        if (un == sess.Username && !isAdmin) return new Resp(new { error = "You cannot remove your own admin rights" }, 400);

        var stations = j.Arr("stations");
        var validSts = Config.Stations.Select(s => s.Code).ToHashSet(StringComparer.Ordinal);
        var badSts = stations.Where(s => !validSts.Contains(s)).ToArray();
        if (badSts.Length > 0) return new Resp(new { error = "Unknown station(s): " + string.Join(", ", badSts) }, 400);
        var prim = j.Str("primaryStation").Trim();
        if (stations.Length > 0) { if (prim == "" || !stations.Contains(prim)) prim = stations[0]; } else prim = "";
        var access = j.Arr("access");
        var badAcc = access.Where(a => !AccessPairs.Contains(a)).ToArray();
        if (badAcc.Length > 0) return new Resp(new { error = "Unknown access pair(s): " + string.Join(", ", badAcc) }, 400);
        var teams = j.Arr("teams"); var erpUsers = j.Arr("erpUsers");
        var dn = j.Str("displayName").Trim();
        var pwd = j.Str("password");

        var users = Auth.Snap.Users.Select(Clone).ToList();
        var idx = users.FindIndex(u => u.Username == un);
        if (idx >= 0)
        {
            var rec = users[idx];
            rec.DisplayName = dn; rec.Email = em; rec.Role = role; rec.Admin = isAdmin; rec.AuthProvider = authProvider; rec.Language = language;
            rec.Teams = teams; rec.Stations = stations; rec.PrimaryStation = prim; rec.Access = access; rec.ErpUsers = erpUsers;
            if (pwd != "") { rec.Salt = Auth.NewSalt(); rec.PwdHash = Auth.HashPwd(rec.Salt, pwd); }
            Auth.Audit(sess.Username, $"update user {un} (role={role}, admin={isAdmin}, stations={string.Join("/", stations)}, primary={prim}, access={string.Join("/", access)}, erp={string.Join("/", erpUsers)}{(pwd != "" ? ", password reset" : "")})");
        }
        else
        {
            if (pwd == "" && authProvider != "swivel") return new Resp(new { error = "A password is required for a new user (or set Sign-in to SWIVEL L!NK)" }, 400);
            var salt = ""; var hash = "";
            if (pwd != "") { salt = Auth.NewSalt(); hash = Auth.HashPwd(salt, pwd); }
            users.Add(new UserRec
            {
                Username = un, DisplayName = dn, Email = em, Salt = salt, PwdHash = hash, Role = role, Admin = isAdmin,
                AuthProvider = authProvider, Language = language, Teams = teams, Stations = stations, PrimaryStation = prim, Access = access, ErpUsers = erpUsers,
            });
            Auth.Audit(sess.Username, $"create user {un} (role={role}, admin={isAdmin}, stations={string.Join("/", stations)}, primary={prim}, access={string.Join("/", access)}, erp={string.Join("/", erpUsers)})");
        }
        Auth.SaveUsers(users);
        return new Resp(new { ok = true });
    }

    static Resp AdminUserDelete(JsonElement j, Session sess)
    {
        var un = j.Str("username").Trim();
        if (un == sess.Username) return new Resp(new { error = "You cannot delete your own account" }, 400);
        var users = Auth.Snap.Users.Select(Clone).ToList();
        var idx = users.FindIndex(u => u.Username == un);
        if (idx < 0) return new Resp(new { error = "No such user" }, 404);
        users.RemoveAt(idx);
        Auth.SaveUsers(users);
        Auth.Audit(sess.Username, $"delete user {un}");
        return new Resp(new { ok = true });
    }

    static int ActiveFlag(JsonElement j) => !j.Has("active") ? 1 : (j.Bool("active") == false ? 0 : 1);

    static Resp AdminMilestones(JsonElement j, Session sess, bool post)
    {
        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        if (!post)
        {
            var rows = Db.RunQ(cn, "SELECT milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode,active FROM dbo.milestone_def ORDER BY mode,bound,seq", new Dictionary<string, object?>());
            return new Resp(new { milestones = rows.Select(RawRow).ToArray() });
        }
        var code = j.Str("code").Trim().ToUpperInvariant(); var bound = j.Str("bound").Trim();
        if (!System.Text.RegularExpressions.Regex.IsMatch(code, "^[A-Z0-9]{1,12}$")) return new Resp(new { error = "Code: 1-12 letters/digits (e.g. M5, A3)" }, 400);
        if (bound is not ("Export" or "Import")) return new Resp(new { error = "Bound must be Export or Import" }, 400);
        var mmode = j.Str("mode").Trim(); if (mmode is not ("Sea" or "Air" or "Both")) return new Resp(new { error = "Mode must be Sea, Air or Both" }, 400);
        var name = j.Str("name").Trim(); if (name == "" || name.Length > 60) return new Resp(new { error = "Name required (max 60 chars)" }, 400);
        if (!int.TryParse(j.Str("seq"), out var seq) || seq < 1) return new Resp(new { error = "Seq must be a positive number" }, 400);
        var anchor = j.Str("anchor").Trim(); if (anchor is not ("booking" or "etd" or "atd" or "eta" or "delivery")) return new Resp(new { error = "Phase anchor must be booking, etd, atd, eta or delivery" }, 400);
        var slatype = j.Str("slaType").Trim(); if (slatype is not ("baseline" or "fixed" or "none")) return new Resp(new { error = "Alert timing must be baseline, fixed or none" }, 400);
        object? offval = null, offunit = null, dir = null, slaanchor = null;
        if (slatype == "fixed")
        {
            if (!int.TryParse(j.Str("slaOffsetVal"), out var ov) || ov < 1) return new Resp(new { error = "Fixed alert needs an offset (e.g. 3)" }, 400);
            offval = ov;
            var ou = j.Str("slaOffsetUnit").Trim(); if (ou is not ("day" or "hour")) return new Resp(new { error = "Offset unit must be day or hour" }, 400); offunit = ou;
            var dr = j.Str("slaDirection").Trim(); if (dr is not ("before" or "after")) return new Resp(new { error = "Direction must be before or after" }, 400); dir = dr;
            var sa = j.Str("slaAnchor").Trim(); if (!System.Text.RegularExpressions.Regex.IsMatch(sa, "^[A-Za-z0-9_]{1,12}$")) return new Resp(new { error = "Fixed alert needs an anchor field (e.g. atd_date)" }, 400); slaanchor = sa;
        }
        var qual = j.Str("qualifyRule"); if (qual.Trim() == "") qual = "{\"op\":\"AND\",\"conds\":[]}";
        var comp = j.Str("completeRule"); if (comp.Trim() == "") comp = "{\"op\":\"OR\",\"conds\":[{\"kind\":\"evidence\"}]}";
        foreach (var (label, rule) in new[] { ("Qualify rule", qual), ("Complete rule", comp) })
            try { var op = (string?)JsonNode.Parse(rule)?["op"]; if (op is not ("AND" or "OR")) throw new Exception("op must be AND or OR"); }
            catch (Exception ex) { return new Resp(new { error = $"{label}: invalid rule JSON - {ex.Message}" }, 400); }
        var active = ActiveFlag(j);
        Db.Exec(cn,
            "MERGE dbo.milestone_def AS t USING (SELECT @code code,@bound bound) s ON t.milestone_code=s.code AND t.bound=s.bound " +
            "WHEN MATCHED THEN UPDATE SET name=@name,seq=@seq,phase_anchor=@anchor,qualify_rule=@qual,complete_rule=@comp," +
            "sla_type=@slatype,sla_offset_val=@offval,sla_offset_unit=@offunit,sla_direction=@dir,sla_anchor=@slaanchor,mode=@mmode,active=@active " +
            "WHEN NOT MATCHED THEN INSERT(milestone_code,bound,name,seq,phase_anchor,qualify_rule,complete_rule,sla_type,sla_offset_val,sla_offset_unit,sla_direction,sla_anchor,mode,active) " +
            "VALUES(@code,@bound,@name,@seq,@anchor,@qual,@comp,@slatype,@offval,@offunit,@dir,@slaanchor,@mmode,@active);",
            new Dictionary<string, object?> { ["code"] = code, ["bound"] = bound, ["name"] = name, ["seq"] = seq, ["anchor"] = anchor, ["qual"] = qual, ["comp"] = comp, ["slatype"] = slatype, ["offval"] = offval, ["offunit"] = offunit, ["dir"] = dir, ["slaanchor"] = slaanchor, ["mmode"] = mmode, ["active"] = active });
        DoctypeMap.Reset();
        Auth.Audit(sess.Username, $"upsert milestone {code}/{bound} (mode={mmode}, sla={slatype}, active={active})");
        return new Resp(new { ok = true });
    }

    static Resp AdminMilestoneDelete(JsonElement j, Session sess)
    {
        var code = j.Str("code").Trim(); var bound = j.Str("bound").Trim();
        if (code == "" || bound == "") return new Resp(new { error = "code + bound required" }, 400);
        using (var cn = new SqlConnection(Config.ConnStr)) { cn.Open(); Db.Exec(cn, "DELETE FROM dbo.milestone_def WHERE milestone_code=@code AND bound=@bound", new Dictionary<string, object?> { ["code"] = code, ["bound"] = bound }); }
        DoctypeMap.Reset();
        Auth.Audit(sess.Username, $"delete milestone {code}/{bound}");
        return new Resp(new { ok = true });
    }

    static Resp AdminEvidence(JsonElement j, Session sess, bool post)
    {
        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        if (!post)
        {
            var rows = Db.RunQ(cn, "SELECT id,milestone_code,bound,match_value,module_match,active FROM dbo.milestone_evidence_map WHERE source_kind='pic_doctype' ORDER BY bound,match_value", new Dictionary<string, object?>());
            var defs = Db.RunQ(cn, "SELECT milestone_code,bound,name,mode FROM dbo.milestone_def WHERE active=1 ORDER BY mode,bound,seq", new Dictionary<string, object?>());
            return new Resp(new { docs = rows.Select(RawRow).ToArray(), milestones = defs.Select(RawRow).ToArray() });
        }
        var doctype = j.Str("doctype").Trim();
        if (doctype == "" || doctype.Length > 64) return new Resp(new { error = "Document type required (max 64 chars) - must match the ERP Document Type code exactly" }, 400);
        var code = j.Str("milestone_code").Trim().ToUpperInvariant(); var bound = j.Str("bound").Trim();
        if (bound is not ("Export" or "Import")) return new Resp(new { error = "Bound must be Export or Import" }, 400);
        var mod = j.Str("module").Trim().ToUpperInvariant(); if (mod != "" && mod is not ("SEA" or "AIR")) return new Resp(new { error = "Module must be SEA, AIR or blank (any)" }, 400);
        object? modVal = mod == "" ? null : mod;
        if (Db.RunQ(cn, "SELECT TOP 1 1 ok FROM dbo.milestone_def WHERE milestone_code=@c AND bound=@b", new Dictionary<string, object?> { ["c"] = code, ["b"] = bound }).Count == 0)
            return new Resp(new { error = $"No milestone {code} ({bound}) - pick one from the list" }, 400);
        var active = ActiveFlag(j);
        int.TryParse(j.Str("id"), out var id);
        if (id > 0)
            Db.Exec(cn, "UPDATE dbo.milestone_evidence_map SET milestone_code=@c,bound=@b,match_value=@v,module_match=@m,active=@a WHERE id=@id AND source_kind='pic_doctype'",
                new Dictionary<string, object?> { ["c"] = code, ["b"] = bound, ["v"] = doctype, ["m"] = modVal, ["a"] = active, ["id"] = id });
        else
            Db.Exec(cn, "INSERT INTO dbo.milestone_evidence_map(milestone_code,bound,source_kind,source_table,source_field,match_value,module_match,active) VALUES(@c,@b,'pic_doctype','PIC','doctype',@v,@m,@a)",
                new Dictionary<string, object?> { ["c"] = code, ["b"] = bound, ["v"] = doctype, ["m"] = modVal, ["a"] = active });
        DoctypeMap.Reset();
        Auth.Audit(sess.Username, $"upsert evidence doc '{doctype}' -> {code}/{bound} (mod={(mod == "" ? "any" : mod)}, active={active})");
        return new Resp(new { ok = true });
    }

    static Resp AdminEvidenceDelete(JsonElement j, Session sess)
    {
        if (!int.TryParse(j.Str("id"), out var id) || id <= 0) return new Resp(new { error = "id required" }, 400);
        using (var cn = new SqlConnection(Config.ConnStr)) { cn.Open(); Db.Exec(cn, "DELETE FROM dbo.milestone_evidence_map WHERE id=@id AND source_kind='pic_doctype'", new Dictionary<string, object?> { ["id"] = id }); }
        DoctypeMap.Reset();
        Auth.Audit(sess.Username, $"delete evidence doc id={id}");
        return new Resp(new { ok = true });
    }

    static Resp AdminErpSettings(JsonElement j, Session sess, bool post)
    {
        if (!post)
            return new Resp(new
            {
                partyGroupCode = ErpMap.Str("partyGroupCode").Trim(),
                forwarderCode = ErpMap.Str("forwarderCode").Trim(),
                // ERP connection (effective value = SQL override else config); the token is NEVER returned, only whether one is set.
                erpBaseUrl = Settings.ErpBaseUrl.Trim(),
                erpMock = Settings.ErpMock,
                erpTokenSet = Settings.ErpToken.Trim() != "",
                erpFromDb = new { baseUrl = Settings.ErpBaseUrlFromDb, token = Settings.ErpTokenFromDb, mock = Settings.ErpMockFromDb },
                live = !Erp.MockMode(),   // are real ERP calls actually happening now (url+token set AND mock off)
            });
        var pg = j.Str("partyGroupCode").Trim();
        if (pg == "" || pg.Length > 32) return new Resp(new { error = "Party group code required (max 32 chars) - the company code, e.g. DEV" }, 400);
        var upd = new Dictionary<string, string> { ["partyGroupCode"] = pg };
        if (j.Has("forwarderCode"))
        {
            var fc = j.Str("forwarderCode").Trim();
            if (fc.Length > 32) return new Resp(new { error = "Forwarder code too long (max 32 chars)" }, 400);
            upd["forwarderCode"] = fc;
        }
        ErpMap.Set(upd);

        // ---- ERP connection (stored in dbo.app_setting, overriding the config; applies immediately, no restart) ----
        var sset = new Dictionary<string, string?>();
        if (j.Has("erpBaseUrl"))
        {
            var url = j.Str("erpBaseUrl").Trim();
            if (url != "" && !(url.StartsWith("http://") || url.StartsWith("https://"))) return new Resp(new { error = "ERP Base URL must start with http:// or https://" }, 400);
            if (url.Length > 400) return new Resp(new { error = "ERP Base URL too long" }, 400);
            sset[Settings.ErpBaseUrlKey] = url == "" ? null : url;   // blank -> delete -> fall back to config
        }
        if (j.Has("erpMock")) sset[Settings.ErpMockKey] = (j.Bool("erpMock") == true) ? "true" : "false";
        // token: only changed when a non-blank value is supplied (the field is masked / write-only). An explicit
        // clearToken=true reverts to the config token.
        if (j.Has("clearToken") && j.Bool("clearToken") == true) sset[Settings.ErpTokenKey] = null;
        else { var tok = j.Str("erpToken"); if (tok.Trim() != "") sset[Settings.ErpTokenKey] = tok.Trim(); }
        if (sset.Count > 0) Settings.Set(sset);

        var tokNote = sset.ContainsKey(Settings.ErpTokenKey) ? (sset[Settings.ErpTokenKey] == null ? " token=cleared" : " token=updated") : "";
        Auth.Audit(sess.Username, $"erp-settings partyGroupCode={pg}{(upd.ContainsKey("forwarderCode") ? " forwarderCode=" + upd["forwarderCode"] : "")}" +
            $"{(sset.ContainsKey(Settings.ErpBaseUrlKey) ? " baseUrl=" + (sset[Settings.ErpBaseUrlKey] ?? "(config)") : "")}" +
            $"{(sset.ContainsKey(Settings.ErpMockKey) ? " mock=" + sset[Settings.ErpMockKey] : "")}{tokNote}");
        return new Resp(new { ok = true, live = !Erp.MockMode() });
    }

    // ===================== IT-Admin: Audit & Health views (read-only, admin-gated) =====================
    // These back the in-app "Audit & Health" tab so customer-site support can see audit / process health /
    // storage / errors WITHOUT opening the database. No writes; no scope (admin sees the whole instance).

    // Health board: current state per watchdog check (latest row), its "last OK" time, + a live DB flag and the
    // 24 h application-error count. Empty `checks` => ops-healthcheck.ps1 has not run yet.
    static Resp AdminHealth()
    {
        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        var checks = Db.RunQ(cn,
            "SELECT h.check_name, h.status, h.detail, h.metric_num, " +
            "CONVERT(varchar(19), h.occurred_at, 120) AS occurred_at, " +
            "CONVERT(varchar(19), (SELECT MAX(o.occurred_at) FROM dbo.health_check_log o WHERE o.check_name=h.check_name AND o.status='ok'), 120) AS last_ok " +
            "FROM dbo.health_check_log h " +
            "JOIN (SELECT check_name, MAX(id) mid FROM dbo.health_check_log GROUP BY check_name) m ON m.mid=h.id " +
            "ORDER BY h.check_name", new Dictionary<string, object?>());
        return new Resp(new
        {
            app = new { version = typeof(Config).Assembly.GetName().Version?.ToString() ?? "", instance = Config.InstanceName, utc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") },
            db = new { up = true },   // we are holding an open connection, so the ops DB is reachable
            checks = checks.Select(RawRow).ToArray(),
            errorCount24h = CountErrorsSince(DateTime.Now.AddHours(-24)),
        });
    }

    // Storage & growth: ops DB size (data + log), the biggest tables, document-attachment bytes, on-disk log-file
    // sizes, and free disk. Answers "is storage a problem / how do we know" straight in the browser.
    static Resp AdminStorage()
    {
        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        double dataMb = 0, logMb = 0;
        foreach (var f in Db.RunQ(cn, "SELECT type_desc, CAST(size*8.0/1024 AS decimal(18,1)) AS mb FROM sys.database_files", new Dictionary<string, object?>()))
        { if (Db.Str(Db.G(f, "type_desc")) == "LOG") logMb += Db.Num(Db.G(f, "mb")); else dataMb += Db.Num(Db.G(f, "mb")); }

        var tables = Db.RunQ(cn,
            "SELECT TOP 15 t.name AS table_name, " +
            "SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS [rows], " +
            "CAST(SUM(ps.reserved_page_count)*8.0/1024 AS decimal(18,1)) AS reserved_mb " +
            "FROM sys.tables t JOIN sys.dm_db_partition_stats ps ON ps.object_id=t.object_id " +
            "GROUP BY t.name ORDER BY reserved_mb DESC", new Dictionary<string, object?>());

        var att = Db.RunQ(cn,
            "SELECT COUNT(*) AS n, ISNULL(SUM(CAST(size_bytes AS bigint)),0) AS bytes, " +
            "SUM(CASE WHEN deleted=1 THEN 1 ELSE 0 END) AS deleted_n, " +
            "ISNULL(SUM(CASE WHEN deleted=1 THEN CAST(size_bytes AS bigint) ELSE 0 END),0) AS deleted_bytes " +
            "FROM dbo.doc_attachment", new Dictionary<string, object?>());
        var a = att.Count > 0 ? att[0] : null;

        double freeMb = 0, diskTotalMb = 0;
        try { var di = new DriveInfo(Path.GetPathRoot(Config.RepoRoot) ?? "C:\\"); freeMb = di.AvailableFreeSpace / 1024.0 / 1024; diskTotalMb = di.TotalSize / 1024.0 / 1024; } catch { }

        return new Resp(new
        {
            db = new { dataMb, logMb, totalMb = dataMb + logMb },
            tables = tables.Select(RawRow).ToArray(),
            attachments = a == null ? null : new
            {
                count = Db.IntOf(Db.G(a, "n")),
                mb = Math.Round(Db.Num(Db.G(a, "bytes")) / 1024 / 1024, 1),
                deletedCount = Db.IntOf(Db.G(a, "deleted_n")),
                deletedMb = Math.Round(Db.Num(Db.G(a, "deleted_bytes")) / 1024 / 1024, 1),
            },
            logs = LogFileSizes(),
            disk = new { freeMb = Math.Round(freeMb, 1), totalMb = Math.Round(diskTotalMb, 1) },
        });
    }

    // Change & access audit: `source` selects the store. "changes" reads the admin-audit.log tail (user CRUD,
    // milestone/ERP-settings edits, logins/failed-logins, doc lifecycle); the others read the rich SQL audit
    // tables. Bounded by a DATE RANGE (from/to, default today) + a row CAP so a high-volume audit can never swamp
    // the UI: `truncated=true` tells the client to narrow the range. Optional `q` filters by free text.
    static Resp AdminAudit(Qs qs)
    {
        var source = (qs["source"] ?? "changes").Trim().ToLowerInvariant();
        int.TryParse(qs["limit"], out var limit); if (limit <= 0 || limit > 2000) limit = 500;
        var q = (qs["q"] ?? "").Trim();
        var (fromDt, toDt, fromS, toS) = DateRange(qs);

        if (source == "changes")
        {
            var matched = new List<object>(); int total = 0;
            foreach (var ln in TailLines("admin-audit.log", 200000))
            {
                var parts = ln.Split('\t');
                if (parts.Length < 3) continue;
                if (!DateTime.TryParseExact(parts[0], "yyyy-MM-dd HH:mm:ss", null, System.Globalization.DateTimeStyles.None, out var ts)) continue;
                if (ts < fromDt || ts >= toDt) continue;
                if (q != "" && ln.IndexOf(q, StringComparison.OrdinalIgnoreCase) < 0) continue;
                total++;
                matched.Add(new { when = parts[0], who = parts[1], action = string.Join("\t", parts.Skip(2)) });
            }
            matched.Reverse();   // newest first
            return new Resp(new { source, from = fromS, to = toS, count = total, truncated = total > limit, items = matched.Take(limit).ToArray() });
        }

        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        // TOP (limit+1): if we get one more than the cap, there are more rows in range -> truncated.
        var p = new Dictionary<string, object?> { ["n"] = limit + 1, ["from"] = fromDt, ["to"] = toDt };
        var where = "WHERE occurred_at >= @from AND occurred_at < @to";
        List<Row> rows;
        switch (source)
        {
            case "erp":
                rows = Db.RunQ(cn, $"SELECT TOP (@n) CONVERT(varchar(19),occurred_at,120) AS occurred_at, actor, job_no, station, mode, bound, erp_status, erp_error, changed_json, ip FROM dbo.erp_edit_log {where} ORDER BY occurred_at DESC", p);
                break;
            case "docs":
                rows = Db.RunQ(cn, $"SELECT TOP (@n) CONVERT(varchar(19),occurred_at,120) AS occurred_at, actor, event, doc_id, version_no, ip, detail FROM dbo.doc_event_log {where} ORDER BY occurred_at DESC", p);
                break;
            case "milestones":
                rows = Db.RunQ(cn, $"SELECT TOP (@n) CONVERT(varchar(19),occurred_at,120) AS occurred_at, done_by, job_no, milestone_code, from_state, to_state, from_light, to_light, reason FROM dbo.milestone_event_log {where} ORDER BY occurred_at DESC", p);
                break;
            default:
                return new Resp(new { error = "source must be changes, erp, docs or milestones" }, 400);
        }
        bool truncated = rows.Count > limit;
        if (truncated) rows = rows.Take(limit).ToList();
        return new Resp(new { source, from = fromS, to = toS, count = rows.Count, truncated, items = rows.Select(RawRow).ToArray() });
    }

    // Application errors: parse the ops-error.log tail into records (header + indented stack), bounded by the same
    // DATE RANGE (default today) + free-text `q` + a row CAP. When the log suddenly grows (a fault storm), the
    // range + cap keep the UI correct; `truncated=true` signals there is more in range than the cap shows.
    static Resp AdminErrors(Qs qs)
    {
        int.TryParse(qs["limit"], out var limit); if (limit <= 0 || limit > 2000) limit = 300;
        var q = (qs["q"] ?? "").Trim();
        var (fromDt, toDt, fromS, toS) = DateRange(qs);

        var all = new List<(DateTime ts, object rec, string text)>();
        string? when = null, id = null, where = null, msg = null; DateTime wts = default; var stack = new List<string>();
        void Flush() { if (when != null) all.Add((wts, new { when, id, where, message = msg, stack = string.Join("\n", stack) }, (where + " " + msg))); }
        foreach (var ln in TailLines("ops-error.log", 200000))
        {
            if (IsLogHeader(ln))
            {
                Flush(); stack.Clear();
                var p = ln.Split('\t');
                when = p.Length > 0 ? p[0] : ""; id = p.Length > 1 ? p[1] : ""; where = p.Length > 2 ? p[2] : ""; msg = p.Length > 3 ? string.Join("\t", p.Skip(3)) : "";
                DateTime.TryParseExact(when, "yyyy-MM-dd HH:mm:ss", null, System.Globalization.DateTimeStyles.None, out wts);
            }
            else if (when != null) stack.Add(ln.TrimStart());
        }
        Flush();
        var hit = all.Where(x => x.ts >= fromDt && x.ts < toDt && (q == "" || x.text.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0)).ToList();
        int total = hit.Count;
        hit.Reverse();   // newest first
        return new Resp(new { from = fromS, to = toS, count = total, truncated = total > limit, items = hit.Take(limit).Select(x => x.rec).ToArray() });
    }

    // ERP API call log: every Swivel ERP call (read + write) from dbo.erp_api_log, so support can answer "which ERP
    // API errored and why" in one place. Same DATE RANGE (default today) + row CAP + truncated signal as the other
    // audit views. `fail=1` shows only failures (the usual diagnostic lens); optional `q` filters endpoint/ref/actor/
    // error free-text. corr_id links the calls of one operation (a doc agree = booking/get + booking/update).
    static Resp AdminErpApi(Qs qs)
    {
        int.TryParse(qs["limit"], out var limit); if (limit <= 0 || limit > 2000) limit = 500;
        var q = (qs["q"] ?? "").Trim();
        var failOnly = (qs["fail"] ?? "").Trim() is "1" or "true";
        var (fromDt, toDt, fromS, toS) = DateRange(qs);

        using var cn = new SqlConnection(Config.ConnStr); cn.Open();
        var p = new Dictionary<string, object?> { ["n"] = limit + 1, ["from"] = fromDt, ["to"] = toDt };
        var where = "WHERE occurred_at >= @from AND occurred_at < @to";
        if (failOnly) where += " AND ok = 0";
        if (q != "")
        {
            where += " AND (endpoint LIKE @q OR [ref] LIKE @q OR actor LIKE @q OR error LIKE @q OR corr_id LIKE @q)";
            p["q"] = "%" + q + "%";
        }
        var rows = Db.RunQ(cn,
            $"SELECT TOP (@n) CONVERT(varchar(19),occurred_at,120) AS occurred_at, corr_id, actor, station, direction, endpoint, [ref] AS ref, ok, http_status, duration_ms, error, req_summary, resp_summary " +
            $"FROM dbo.erp_api_log {where} ORDER BY occurred_at DESC, id DESC", p);
        bool truncated = rows.Count > limit;
        if (truncated) rows = rows.Take(limit).ToList();
        return new Resp(new { source = "erp-api", from = fromS, to = toS, failOnly, count = rows.Count, truncated, items = rows.Select(RawRow).ToArray() });
    }

    // from/to (yyyy-mm-dd) inclusive day range -> [fromDt 00:00, toDt+1day). Defaults to today when absent/invalid.
    // Uses wall-clock DateTime.Now (the logs are stamped in real time, not the asOf testing clock).
    static (DateTime fromDt, DateTime toDt, string fromS, string toS) DateRange(Qs qs)
    {
        var rx = new System.Text.RegularExpressions.Regex(@"^\d{4}-\d{2}-\d{2}$");
        var today = DateTime.Now.Date;
        var fs = (qs["from"] ?? "").Trim(); var tsr = (qs["to"] ?? "").Trim();
        var fromDt = rx.IsMatch(fs) ? DateTime.ParseExact(fs, "yyyy-MM-dd", null) : today;
        var toDt = rx.IsMatch(tsr) ? DateTime.ParseExact(tsr, "yyyy-MM-dd", null) : today;
        if (toDt < fromDt) toDt = fromDt;
        return (fromDt, toDt.AddDays(1), fromDt.ToString("yyyy-MM-dd"), toDt.ToString("yyyy-MM-dd"));
    }

    // --- small helpers for the file-backed views ---
    static bool IsLogHeader(string ln) =>
        ln.Length >= 19 && DateTime.TryParseExact(ln.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", null, System.Globalization.DateTimeStyles.None, out _);

    static int CountErrorsSince(DateTime since)
    {
        try
        {
            var path = Path.Combine(Config.RepoRoot, "ops-error.log");
            if (!File.Exists(path)) return 0;
            int n = 0;
            foreach (var ln in File.ReadLines(path))
                if (IsLogHeader(ln) && DateTime.TryParseExact(ln.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", null, System.Globalization.DateTimeStyles.None, out var ts) && ts >= since) n++;
            return n;
        }
        catch { return 0; }
    }

    static string[] TailLines(string fileName, int max)
    {
        try
        {
            var path = Path.Combine(Config.RepoRoot, fileName);
            if (!File.Exists(path)) return Array.Empty<string>();
            var all = File.ReadAllLines(path);
            return all.Length <= max ? all : all.Skip(all.Length - max).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }

    static object[] LogFileSizes()
    {
        var list = new List<object>();
        foreach (var n in new[] { "admin-audit.log", "ops-error.log", "ops-health.log", "ops-backup.log" })
        {
            try { var fi = new FileInfo(Path.Combine(Config.RepoRoot, n)); list.Add(new { name = n, mb = fi.Exists ? Math.Round(fi.Length / 1024.0 / 1024, 2) : 0.0, exists = fi.Exists }); }
            catch { list.Add(new { name = n, mb = 0.0, exists = false }); }
        }
        return list.ToArray();
    }

    // project a SQL row to a plain string/number map for admin JSON lists (keys = column names, verbatim).
    static Dictionary<string, object?> RawRow(Row r)
    {
        var o = new Dictionary<string, object?>();
        foreach (var kv in r) o[kv.Key] = kv.Value;
        return o;
    }
}
