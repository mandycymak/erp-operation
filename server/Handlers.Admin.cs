using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.SqlClient;
using Row = System.Collections.Generic.IDictionary<string, object>;

namespace Ops;

public static partial class Handlers
{
    static readonly string[] AccessPairs = { "Air-Export", "Air-Import", "Sea-Export", "Sea-Import" };

    // ---- /api-ops/admin/* (admin-gated; serve-ops.ps1 2008-2196) ----
    public static Resp Admin(string path, string method, JsonElement j, Session sess)
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
            return new Resp(new { partyGroupCode = ErpMap.Str("partyGroupCode").Trim(), forwarderCode = ErpMap.Str("forwarderCode").Trim() });
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
        Auth.Audit(sess.Username, $"erp-settings partyGroupCode={pg}{(upd.ContainsKey("forwarderCode") ? " forwarderCode=" + upd["forwarderCode"] : "")}");
        return new Resp(new { ok = true });
    }

    // project a SQL row to a plain string/number map for admin JSON lists (keys = column names, verbatim).
    static Dictionary<string, object?> RawRow(Row r)
    {
        var o = new Dictionary<string, object?>();
        foreach (var kv in r) o[kv.Key] = kv.Value;
        return o;
    }
}
