using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Ops;

// The job_no-keyed note/arrangement/reminder store (serve-ops.ps1 lines 222-334). A shared JSON file, not a DB
// table (low volume; keeps SQL off the hot path). serve-ops.ps1 was single-threaded so read-modify-write was
// safe; under Kestrel it is NOT — every write goes through _fileLock (the .NET parity for the PS single-thread
// guarantee). Reads are lock-free snapshots of the file.
public sealed class NoteRec
{
    public string Id = "", Created = "", User = "", JobNo = "", MilestoneCode = "", Kind = "note", Note = "";
    public string Status = "open", DoneBy = "", DoneAt = "";
    public string ArrType = "", Party = "", Contact = "", ArrStatus = "", RemindOn = "";
    public string[] Mentions = Array.Empty<string>();
    public bool? Silent;   // null = the "silent" property was absent on the stored record

    public bool IsMilestone => Kind == "bypass" || Kind == "reopen";
    public bool IsOpen => Status == "" || Status == "open";
    // back-compat: a milestone tick whose note text has no ':' carried no remark -> a quiet update, not chat.
    public bool EffectiveSilent => Silent ?? (IsMilestone && !Note.Contains(':'));
}

public static class Notes
{
    static string NotesPath => Path.Combine(Config.RepoRoot, "ops-lists", "job-notes.json");
    static readonly object _fileLock = new();
    static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    public static List<NoteRec> Read()
    {
        var list = new List<NoteRec>();
        if (!File.Exists(NotesPath)) return list;
        JsonNode? root;
        try { root = JsonNode.Parse(File.ReadAllText(NotesPath)); } catch { return list; }
        if (root is not JsonArray arr) return list;
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var id = (string?)o["id"] ?? "";
            if (id == "") continue;   // filtering by .id self-heals legacy wrapper junk
            list.Add(new NoteRec
            {
                Id = id,
                Created = (string?)o["created"] ?? "",
                User = (string?)o["user"] ?? "",
                JobNo = (string?)o["job_no"] ?? "",
                MilestoneCode = (string?)o["milestone_code"] ?? "",
                Kind = NonEmpty((string?)o["kind"], "note"),
                Note = (string?)o["note"] ?? "",
                Status = NonEmpty((string?)o["status"], "open"),
                DoneBy = (string?)o["doneBy"] ?? "",
                DoneAt = (string?)o["doneAt"] ?? "",
                ArrType = (string?)o["arr_type"] ?? "",
                Party = (string?)o["party"] ?? "",
                Contact = (string?)o["contact"] ?? "",
                ArrStatus = (string?)o["arr_status"] ?? "",
                RemindOn = (string?)o["remind_on"] ?? "",
                Mentions = StrArray(o["mentions"]),
                Silent = o.ContainsKey("silent") ? (bool?)o["silent"] : null,
            });
        }
        return list;
    }

    public static void Write(IEnumerable<NoteRec> notes)
    {
        var arr = new JsonArray(notes.Where(r => r != null && r.Id != "").Select(ToJson).ToArray());
        lock (_fileLock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(NotesPath)!);
            File.WriteAllText(NotesPath, arr.ToJsonString(new JsonSerializerOptions { WriteIndented = false }), Utf8NoBom);
        }
    }

    static JsonObject ToJson(NoteRec r)
    {
        var o = new JsonObject
        {
            ["id"] = r.Id, ["created"] = r.Created, ["user"] = r.User, ["job_no"] = r.JobNo,
            ["milestone_code"] = r.MilestoneCode, ["kind"] = r.Kind, ["note"] = r.Note,
            ["mentions"] = new JsonArray(r.Mentions.Select(s => (JsonNode)s!).ToArray()),
            ["status"] = r.Status, ["doneBy"] = r.DoneBy, ["doneAt"] = r.DoneAt,
            ["arr_type"] = r.ArrType, ["party"] = r.Party, ["contact"] = r.Contact,
            ["arr_status"] = r.ArrStatus, ["remind_on"] = r.RemindOn,
        };
        if (r.Silent.HasValue) o["silent"] = r.Silent.Value;
        return o;
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

    static string NonEmpty(string? v, string fallback) => string.IsNullOrWhiteSpace(v) ? fallback : v;
    static string[] StrArray(JsonNode? n)
    {
        if (n is not JsonArray a) return Array.Empty<string>();
        return a.Select(x => (string?)x ?? "").Where(s => s.Trim() != "").Select(s => s.Trim()).ToArray();
    }
}
