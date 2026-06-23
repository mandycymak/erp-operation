using System.Text.RegularExpressions;

namespace Ops;

// Server-side port of the natural-language Find parser that ships in ops.js (parseOpsQuery / parseDateWindow,
// lines 1411-1488). A faithful behavioural copy so the two parsers stay in contract: subtract the known clues
// (date / mode / bound / identifiers / lane / note author+body+mention / "who"), the significant leftover is the
// company/contact. It produces the SAME FindClue the structured /api-ops/find params map to, so a parsed query
// runs the identical FindCore SQL + scope. Relative dates use Config.TodayDate() so the testing clock is honored.
public static class OpsQuery
{
    const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    // drop noise words but KEEP unknown words (a place name or a commodity) so the server LIKE can try them.
    static readonly Regex PlaceNoise = new(@"\b(by|air|airfreight|sea|seafreight|ocean|oceanfreight|freight|fcl|lcl|vessel|liner|carrier|flight|booking|bookings|shipment|shipments|file|files|job|jobs|cargo|container|containers|please|pls|thanks|thank|you|find|me|get|got|want|need|needed|looking|look|check|show|ship|shipped|shipping|send|sent|only|just|with|via|on|the|some|for|of|to|from|that|this|about|customs|cleared|ready|arrived|arriving|delivered|pickup)\b", I);
    // command / grammar / ops-vocabulary stop-words: whatever survives is the company/contact name.
    static readonly Regex FindStop = new(@"\b(find|search|show|tell|give|get|got|list|fetch|pull|look|looking|lookup|locate|check|want|wanted|need|needed|see|view|just|only|kindly|what|whats|who|whose|which|when|where|me|us|my|mine|our|own|team|teams|the|a|an|any|all|recent|recently|latest|last|new|old|message|messages|note|notes|msg|chat|activity|activities|history|anything|everything|something|about|re|regarding|saying|says|said|with|for|to|from|of|on|by|at|in|and|or|please|pls|do|does|did|you|know|i|we|remember|recall|forgot|forget|forgotten|help|that|this|these|those|has|have|had|is|was|are|were|been|be|prepared|made|create|created|raise|raised|handle|handled|arrange|arranged|arranging|contact|contacted|contacting|update|updated|name|air|sea|ocean|freight|fcl|lcl|vessel|liner|flight|booking|bookings|shipment|shipments|shipped|shipping|ship|file|files|job|jobs|cargo|but|anyone|everyone|everybody|customer|client|account|consignee|shipper|agent|carrier|today|yesterday|week|weeks|month|months|day|days|year|years|ago|few|couple|previous|since|import|imports|export|exports|inbound|outbound|customs|cleared|clearance|ready|arrived|arriving|delivered|delivery|pickup|hbl|hawb|house|mbl|mawb|master|container|containers|po|so|sono|id|number|no|ref)\b", I);

    static readonly Regex RxArrow = new(@"\s*(->|→|—>|-->)\s*", RegexOptions.CultureInvariant);
    static readonly Regex RxWs = new(@"\s+", RegexOptions.CultureInvariant);
    static readonly Regex RxPunct = new(@"[?.,;!]", RegexOptions.CultureInvariant);

    static readonly Regex RxAir = new(@"\bby air\b|\bair\s?freight\b|\bairfreight\b|\bawb\b|\bmawb\b|\bhawb\b|\bflight\b|\bflew\b|\bair\b", I);
    static readonly Regex RxSea = new(@"\bby sea\b|\bsea\s?freight\b|\bocean\b|\bfcl\b|\blcl\b|\bvessel\b|\bsea\b", I);
    static readonly Regex RxImport = new(@"\bimport\b|\binbound\b|\bincoming\b|\barriv\w*\b", I);
    static readonly Regex RxExport = new(@"\bexport\b|\boutbound\b|\boutgoing\b", I);
    static readonly Regex RxAnyone = new(@"\banyone\b|\beveryone\b|\beverybody\b|\bany (?:operator|one|user|colleague)\b|\ball (?:shipments|files|jobs|operators?)\b|\bentire (?:team|office)\b|\bwhole (?:team|office)\b", I);

    static readonly Regex RxBooking = new(@"\b(?:booking|bkg|so|sono)\s*#?\s*([a-z0-9][a-z0-9\-/]{2,})\b", I);
    static readonly Regex RxPo = new(@"\b(?:po|p/o|order)\s*#?\s*([a-z0-9][a-z0-9\-/]{2,})\b", I);
    static readonly Regex RxHouse = new(@"\b(?:hbl|hawb|house\s*(?:bill|b/l|bl|awb)?)\s*#?\s*([a-z0-9][a-z0-9\-/]{3,})\b", I);
    static readonly Regex RxMaster = new(@"\b(?:mbl|mawb|master\s*(?:bill|b/l|bl|awb)?)\s*#?\s*([a-z0-9][a-z0-9\-/]{3,})\b", I);
    static readonly Regex RxShipId = new(@"\b(?:ship-?\s?id|shipid|spot-?\s?id|spotid|spot)\s*#?\s*([a-z0-9][a-z0-9\-/:_]{1,})\b", I);
    static readonly Regex RxConv = new(@"\b(?:vessel|vsl|m/?v|voyage)\s+(?:(?:named?|called|under|is|name\s+of)\s+)?#?\s*([a-z0-9][\w\-/]*(?:\s+(?!to\b|from\b|about\b|last\b|this\b|please\b)[a-z0-9][\w\-/]*){0,3})", I);
    static readonly Regex RxContainer = new(@"\b([A-Z]{4}\d{7})\b", RegexOptions.CultureInvariant);   // NOT case-insensitive
    static readonly Regex RxJob = new(@"\b(?:job|file)\s*(?:no\.?|number|#)?\s*([a-z]{2,}[a-z0-9\-]{3,})\b", I);

    static readonly Regex RxRole = new(@"\b(?:shipper|consignee|cnee|customer|client|account)\s+([a-z0-9][\w&.\- ]*?)(?=\s+(?:shipped|shipping|sent|ship|to|from|about|by|last|this|please|,|\?)|\s*$)", I);
    static readonly Regex RxLane = new(@"\bfrom\s+([^,?]+?)\s+to\s+([^,?]+?)(?=\s+(?:about|re|regarding|with|for|by|last|this|please|\?)|,|\s*$)", I);
    static readonly Regex RxLaneOnly = new(@"\bfrom\s+([^,?]+?)(?=\s+(?:about|re|regarding|with|for|by|last|this|please|\?)|,|\s*$)", I);
    static readonly Regex RxToMe = new(@"\b(?:to|told|sent\s+to|messaged|texted|emailed|dropped|pinged)\s+me\b|\bme\s+(?:about|regarding|a message|a note)\b|\bdropped me\b", I);
    static readonly Regex RxAuthor = new(@"\b([a-z][\w.'-]*)\s+(?:told|said|messaged|texted|emailed|wrote|mentioned|replied|sent|dropped|pinged|noted)\b", I);
    static readonly Regex RxAbout = new(@"\b(?:about|re|regarding|saying|mentioning)\s+([^,?]+?)(?=\s+(?:from|to|with|for|by|last|this|please|\?)|,|\s*$)", I);

    static readonly Regex RxAposS = new(@"'s\b", I);
    static readonly Regex RxLeftPunct = new(@"[?.,;!']", RegexOptions.CultureInvariant);

    public static FindClue Parse(string? text)
    {
        var raw = RxWs.Replace((text ?? ""), " ").Trim();
        var work = " " + RxArrow.Replace(raw, " to ") + " ";
        var o = new FindClue();

        var dw = ParseDateWindow(raw);
        if (dw != null) { o.From = dw.Value.From; o.To = dw.Value.To; o.DateLabel = dw.Value.Label; }

        if (RxAir.IsMatch(work)) o.Mode = "Air";
        else if (RxSea.IsMatch(work)) o.Mode = "Sea";
        if (RxImport.IsMatch(work)) o.Bound = "Import";
        else if (RxExport.IsMatch(work)) o.Bound = "Export";
        // ownership: default "mine"; widen on "anyone/everyone/all".
        o.Mine = true;
        if (RxAnyone.IsMatch(work)) o.Mine = false;

        // explicit identifier (field + value).
        Match m;
        if ((m = RxBooking.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "booking"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxPo.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "po"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxHouse.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "house"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxMaster.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "master"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxShipId.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "shipid"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxConv.Match(work)).Success) { o.Ref = m.Groups[1].Value.Trim(); o.RefField = "conv"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxContainer.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "container"; work = ReplaceFirst(work, m.Value, " "); }
        else if ((m = RxJob.Match(work)).Success) { o.Ref = m.Groups[1].Value; o.RefField = "job"; work = ReplaceFirst(work, m.Value, " "); }

        // an explicit role word pins the company: "shipper ABC", "consignee X", "customer Y".
        var role = RxRole.Match(work);
        if (role.Success)
        {
            var rw = RxWs.Replace(RxPunct.Replace(role.Groups[1].Value, " "), " ").Trim();
            if (rw != "") { o.Who = rw; work = ReplaceFirst(work, role.Value, " "); }
        }

        // lane: "from X to Y"; else "from X" (origin only).
        var lane = RxLane.Match(work);
        if (lane.Success) { o.Pol = StripNoise(lane.Groups[1].Value); o.Pod = StripNoise(lane.Groups[2].Value); work = ReplaceFirst(work, lane.Value, " "); }
        else { var only = RxLaneOnly.Match(work); if (only.Success) { o.Pol = StripNoise(only.Groups[1].Value); work = ReplaceFirst(work, only.Value, " "); } }

        // note clues: who it's to (me), who wrote it, what it says.
        if (RxToMe.IsMatch(work)) o.Tome = true;
        var av = RxAuthor.Match(work);
        if (av.Success && !FindStop.IsMatch(" " + av.Groups[1].Value + " ")) { o.NoteAuthor = av.Groups[1].Value; work = ReplaceFirst(work, av.Value, " "); }
        var noteCentric = o.NoteAuthor != "" || o.Tome;
        var cm = RxAbout.Match(work);
        if (cm.Success)
        {
            var capt = RxWs.Replace(FindStop.Replace(cm.Groups[1].Value, " "), " ").Trim();
            if (noteCentric) o.NoteText = capt; else o.Commodity = capt;
            work = ReplaceFirst(work, cm.Value, " ");
        }

        // the significant leftover: a company/contact, or (short, when a lane is already set, or a bare token) a commodity.
        var leftover = RxLeftPunct.Replace(RxAposS.Replace(work, " "), " ");
        leftover = RxWs.Replace(FindStop.Replace(leftover, " "), " ").Trim();
        if (leftover != "")
        {
            var words = leftover.Split(' ').Length;
            if (o.Who == "" && !((o.Pol != "" || o.Pod != "") && words <= 2)) o.Who = leftover;
            else if (o.Commodity == "") o.Commodity = leftover;
            else if (o.Who == "") o.Who = leftover;
        }
        if (o.Ref != "") o.Mine = false;   // an explicit identifier finds any file (server bypasses the lens)
        return o;
    }

    static string StripNoise(string s)
    {
        var x = " " + (s ?? "").ToLowerInvariant() + " ";
        x = RxPunct.Replace(x, " ");
        x = PlaceNoise.Replace(x, " ");
        return RxWs.Replace(x, " ").Trim();
    }

    static string ReplaceFirst(string s, string find, string repl)
    {
        if (string.IsNullOrEmpty(find)) return s;
        var i = s.IndexOf(find, StringComparison.Ordinal);
        return i < 0 ? s : s.Substring(0, i) + repl + s.Substring(i + find.Length);
    }

    // ---- relative date phrases -> {from,to,label}. Ported verbatim from ops.js (Monday-based ISO weeks). ----
    readonly record struct DateWindow(string From, string To, string Label);

    static string Iso(DateTime d) => d.ToString("yyyy-MM-dd");
    static DateTime StartOfWeek(DateTime d) => d.AddDays(-(((int)d.DayOfWeek + 6) % 7)).Date;

    static DateWindow? ParseDateWindow(string? text)
    {
        var t = " " + (text ?? "").ToLowerInvariant() + " ";
        var now = Config.TodayDate();
        Match m;
        if ((m = Regex.Match(t, @"\b(?:last|past|previous|recent)\s+(\d+)\s+(day|days|week|weeks|month|months)\b")).Success)
        {
            var n = int.Parse(m.Groups[1].Value); var u = m.Groups[2].Value;
            var days = u.StartsWith("day") ? n : u.StartsWith("week") ? n * 7 : n * 30;
            var unit = u.TrimEnd('s');
            return new DateWindow(Iso(now.AddDays(-days)), Iso(now), "last " + n + " " + unit + (n > 1 ? "s" : ""));
        }
        if (Regex.IsMatch(t, @"\btoday\b")) return new DateWindow(Iso(now), Iso(now), "today");
        if (Regex.IsMatch(t, @"\byesterday\b")) { var y = now.AddDays(-1); return new DateWindow(Iso(y), Iso(y), "yesterday"); }
        if (Regex.IsMatch(t, @"\bthis week\b")) return new DateWindow(Iso(StartOfWeek(now)), Iso(now), "this week");
        if (Regex.IsMatch(t, @"\b(?:last|past|previous) week\b")) { var sow = StartOfWeek(now); return new DateWindow(Iso(sow.AddDays(-7)), Iso(sow.AddDays(-1)), "last week"); }
        if (Regex.IsMatch(t, @"\bthis month\b")) return new DateWindow(Iso(new DateTime(now.Year, now.Month, 1)), Iso(now), "this month");
        if (Regex.IsMatch(t, @"\b(?:last|past|previous) month\b")) { var ft = new DateTime(now.Year, now.Month, 1); var lme = ft.AddDays(-1); return new DateWindow(Iso(new DateTime(lme.Year, lme.Month, 1)), Iso(lme), "last month"); }
        if (Regex.IsMatch(t, @"\bthis year\b")) return new DateWindow(Iso(new DateTime(now.Year, 1, 1)), Iso(now), "this year");
        if (Regex.IsMatch(t, @"\b(?:last|past|previous) year\b")) return new DateWindow(Iso(new DateTime(now.Year - 1, 1, 1)), Iso(new DateTime(now.Year - 1, 12, 31)), "last year");
        if (Regex.IsMatch(t, @"\b(?:last|past)\s+(?:few|couple of?)\s+(?:days|weeks)\b")) return new DateWindow(Iso(now.AddDays(-7)), Iso(now), "last few days");
        return null;
    }
}
