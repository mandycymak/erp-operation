using Microsoft.Data.SqlClient;

namespace Ops;

// The job_no-keyed note/arrangement/reminder store. Originally a shared JSON file (ops-lists/job-notes.json);
// migrated into the erpops table dbo.job_note (setup-ops.ps1 §2.9) so the natural-language Find can search
// authors/body/mentions with a scoped EXISTS and notes are queryable like every other entity. The NoteRec shape
// and every method signature are unchanged, so the note-add / note-done / my-tasks / worklist callers are
// untouched — they still just call Read()/Write()/MyNoteJobs(). The store opens its own pooled connection
// (Config.ConnStr; ADO.NET pools by connection string, so this is cheap) — callers need not pass one.
public sealed class NoteRec
{
    public string Id = "", Created = "", User = "", JobNo = "", MilestoneCode = "", Kind = "note", Note = "";
    public string Status = "open", DoneBy = "", DoneAt = "";
    public string ArrType = "", Party = "", Contact = "", ArrStatus = "", RemindOn = "";
    public string[] Mentions = Array.Empty<string>();
    public bool? Silent;   // null = the "silent" column was NULL (property absent in the old file)

    public bool IsMilestone => Kind == "bypass" || Kind == "reopen";
    public bool IsOpen => Status == "" || Status == "open";
    // back-compat: a milestone tick whose note text has no ':' carried no remark -> a quiet update, not chat.
    public bool EffectiveSilent => Silent ?? (IsMilestone && !Note.Contains(':'));
}

public static class Notes
{
    // serialises whole-store writes within the process (the .NET parity for serve-ops.ps1's single-thread
    // read-modify-write guarantee). Reads are lock-free snapshots. NB: like the old file store, callers Read()
    // outside the lock then Write() — the (accepted, low-volume) last-writer-wins race is unchanged by this move.
    static readonly object _writeLock = new();

    const string Cols = "id,job_no,[user],milestone_code,kind,note,mentions,status,done_by,done_at,arr_type,party,contact,arr_status,remind_on,silent,created";

    static SqlConnection Open() { var cn = new SqlConnection(Config.ConnStr); cn.Open(); return cn; }
    static string NonEmpty(string? v, string fallback) => string.IsNullOrWhiteSpace(v) ? fallback : v;
    static object NullIfEmpty(string? v) => string.IsNullOrWhiteSpace(v) ? DBNull.Value : v!;
    // mentions persist as a comma-delimited username list (clean ',+mentions+,' LIKE for @-mention search).
    static string[] SplitMentions(string? csv) =>
        (csv ?? "").Split(',').Select(s => s.Trim()).Where(s => s != "").ToArray();

    public static List<NoteRec> Read()
    {
        var list = new List<NoteRec>();
        try
        {
            using var cn = Open();
            var rows = Db.RunQ(cn, $"SELECT {Cols} FROM dbo.job_note", new Dictionary<string, object?>());
            foreach (var r in rows)
            {
                var id = Db.Str(Db.G(r, "id"));
                if (id == "") continue;
                var sil = Db.G(r, "silent");
                list.Add(new NoteRec
                {
                    Id = id,
                    Created = Db.Str(Db.G(r, "created")),
                    User = Db.Str(Db.G(r, "user")),
                    JobNo = Db.Str(Db.G(r, "job_no")),
                    MilestoneCode = Db.Str(Db.G(r, "milestone_code")),
                    Kind = NonEmpty(Db.Str(Db.G(r, "kind")), "note"),
                    Note = Db.Str(Db.G(r, "note")),
                    Status = NonEmpty(Db.Str(Db.G(r, "status")), "open"),
                    DoneBy = Db.Str(Db.G(r, "done_by")),
                    DoneAt = Db.Str(Db.G(r, "done_at")),
                    ArrType = Db.Str(Db.G(r, "arr_type")),
                    Party = Db.Str(Db.G(r, "party")),
                    Contact = Db.Str(Db.G(r, "contact")),
                    ArrStatus = Db.Str(Db.G(r, "arr_status")),
                    RemindOn = Db.Str(Db.G(r, "remind_on")),
                    Mentions = SplitMentions(Db.Str(Db.G(r, "mentions"))),
                    Silent = sil == null ? (bool?)null : Convert.ToBoolean(sil),
                });
            }
        }
        catch { return new List<NoteRec>(); }   // never throw on the read path (parity with the old file parse)
        return list;
    }

    // Whole-store rewrite (parity with the old file overwrite): delete-all + re-insert the supplied set in one
    // transaction. Low volume; the callers always pass the full list (Read().Append(...) / the mutated list).
    public static void Write(IEnumerable<NoteRec> notes)
    {
        var recs = notes.Where(r => r != null && r.Id != "").ToList();
        lock (_writeLock)
        {
            using var cn = Open();
            using var tx = cn.BeginTransaction();
            try
            {
                using (var del = cn.CreateCommand()) { del.Transaction = tx; del.CommandText = "DELETE FROM dbo.job_note"; del.ExecuteNonQuery(); }
                foreach (var r in recs)
                {
                    using var ins = cn.CreateCommand();
                    ins.Transaction = tx;
                    ins.CommandText = $"INSERT INTO dbo.job_note ({Cols}) VALUES " +
                        "(@id,@job,@usr,@ms,@kind,@note,@ment,@st,@db,@da,@at,@pty,@ct,@as,@ro,@sil,@cr)";
                    var ps = ins.Parameters;
                    ps.AddWithValue("@id", r.Id);
                    ps.AddWithValue("@job", NullIfEmpty(r.JobNo));
                    ps.AddWithValue("@usr", NullIfEmpty(r.User));
                    ps.AddWithValue("@ms", NullIfEmpty(r.MilestoneCode));
                    ps.AddWithValue("@kind", NonEmpty(r.Kind, "note"));
                    ps.AddWithValue("@note", NullIfEmpty(r.Note));
                    ps.AddWithValue("@ment", NullIfEmpty(string.Join(",", r.Mentions ?? Array.Empty<string>())));
                    ps.AddWithValue("@st", NonEmpty(r.Status, "open"));
                    ps.AddWithValue("@db", NullIfEmpty(r.DoneBy));
                    ps.AddWithValue("@da", NullIfEmpty(r.DoneAt));
                    ps.AddWithValue("@at", NullIfEmpty(r.ArrType));
                    ps.AddWithValue("@pty", NullIfEmpty(r.Party));
                    ps.AddWithValue("@ct", NullIfEmpty(r.Contact));
                    ps.AddWithValue("@as", NullIfEmpty(r.ArrStatus));
                    ps.AddWithValue("@ro", NullIfEmpty(r.RemindOn));
                    ps.AddWithValue("@sil", r.Silent.HasValue ? r.Silent.Value : (object)DBNull.Value);
                    ps.AddWithValue("@cr", string.IsNullOrEmpty(r.Created) ? DateTime.Now.ToString("o") : r.Created);
                    ins.ExecuteNonQuery();
                }
                tx.Commit();
            }
            catch { try { tx.Rollback(); } catch { } throw; }
        }
    }

    // Note-Proj: the wire shape the client reads (note the mixed snake/camel keys — kept verbatim).
    public static object Proj(NoteRec r) => new
    {
        id = r.Id, created = r.Created, user = r.User, job_no = r.JobNo, milestone_code = r.MilestoneCode,
        kind = r.Kind, note = r.Note, mentions = r.Mentions, status = r.Status, doneBy = r.DoneBy, doneAt = r.DoneAt,
        arrType = r.ArrType, party = r.Party, contact = r.Contact, arrStatus = r.ArrStatus, remindOn = r.RemindOn,
    };

    // /api-ops/notes (GET): records for one job (or all), newest first.
    public static object ListByJob(string? job)
    {
        var j = (job ?? "").Trim();
        var rows = Read().Where(r => j == "" || r.JobNo.Trim() == j).OrderByDescending(r => r.Created).ToList();
        return new { records = rows.Select(Proj).ToArray() };
    }

    // jobs the user is involved in via notes (authored or @-mentioned) — folds into the worklist "mine" lens.
    public static string[] MyNoteJobs(string me) =>
        Read().Where(r => r.User == me || r.Mentions.Contains(me))
              .Select(r => r.JobNo).Where(j => j != "").Distinct().ToArray();

    // jobs where I have an OPEN, real remark/reminder (mine or @-mentioning me) — backs the "My notes" filter and
    // the worklist chat dot. A silent milestone-tick doesn't count.
    public static string[] MyOpenNoteJobs(string me) =>
        Read().Where(r => (r.User == me || r.Mentions.Contains(me)) && r.IsOpen && !(r.IsMilestone && r.EffectiveSilent))
              .Select(r => r.JobNo).Where(j => j != "").Distinct().ToArray();
}
