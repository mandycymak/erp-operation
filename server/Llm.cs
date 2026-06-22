using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Ops;

// Optional LLM fallback for natural-language Find (Part 4 of the Find design). Provider-pluggable adapter —
// Claude (Anthropic Messages API), OpenAI (Chat Completions), or DeepSeek (OpenAI-compatible) — selected by
// Config.LlmProvider. It re-interprets a free-text query into the SAME clue object the rule parser produces
// (parseOpsQuery in ops.js); it never queries the DB and never bypasses scope — the server SQL + Scope.* clauses
// remain the only security boundary. Fails OPEN: any error returns null and the client falls back to the rule parse.
//
// Status: this is the wired seam. It is INERT unless Config.LlmEnabled (the `llm.enabled` flag + an API key).
// The shared system prompt + clue schema below are intentionally identical in shape to erp-quotation's
// /api-quote/parse-shipment seam so both apps parse to one contract.
public static class Llm
{
    // the clue keys the client expects back (mirror parseOpsQuery's output object).
    static readonly string[] StrKeys = { "who", "pol", "pod", "commodity", "mode", "bound", "ref", "refField", "noteAuthor", "noteText", "from", "to" };
    static readonly string[] BoolKeys = { "tome", "mine" };

    const string SystemPrompt =
        "You convert a freight operator's free-text search into a strict JSON clue object for a shipment search. " +
        "Extract only what the text states; leave any field you are unsure about as an empty string. Do NOT invent " +
        "port codes, booking numbers, or company names. Fields: who (company/contact/carrier name), pol (origin " +
        "place or code, as typed), pod (destination), commodity, mode ('Air'|'Sea'|''), bound ('Import'|'Export'|''), " +
        "ref (an explicit booking/HBL/MBL/PO/container/job identifier value, else ''), refField " +
        "('booking'|'po'|'house'|'master'|'container'|'job'|''), noteAuthor (who wrote a message), noteText (message " +
        "body being searched for), tome (true if the message was sent to/mentions the searcher), mine (true unless the " +
        "operator asked for anyone/all/everyone — default true), from/to (yyyy-mm-dd if a date window is stated, else ''). " +
        "Respond with JSON only.";

    static readonly JsonObject ClueSchema = BuildSchema();
    static JsonObject BuildSchema()
    {
        var props = new JsonObject();
        foreach (var k in StrKeys) props[k] = new JsonObject { ["type"] = "string" };
        foreach (var k in BoolKeys) props[k] = new JsonObject { ["type"] = "boolean" };
        return new JsonObject { ["type"] = "object", ["properties"] = props, ["additionalProperties"] = false };
    }

    // Re-interpret `text` into a clue object. Returns null on disabled / any error (caller falls back to the rule parse).
    public static async Task<JsonObject?> ParseFind(string text, HttpClient http)
    {
        if (!Config.LlmEnabled || string.IsNullOrWhiteSpace(text)) return null;
        try
        {
            using var cts = new System.Threading.CancellationTokenSource(Config.LlmTimeoutMs);
            var raw = Config.LlmProvider switch
            {
                "openai" => await CallOpenAiCompatible(text, http, DefaultBase("https://api.openai.com"), DefaultModel("gpt-4o-mini"), strictSchema: true, cts.Token),
                "deepseek" => await CallOpenAiCompatible(text, http, DefaultBase("https://api.deepseek.com"), DefaultModel("deepseek-chat"), strictSchema: false, cts.Token),
                _ => await CallClaude(text, http, DefaultBase("https://api.anthropic.com"), DefaultModel("claude-haiku-4-5"), cts.Token),
            };
            return Coerce(raw);
        }
        catch { return null; }
    }

    static string DefaultBase(string fallback) => string.IsNullOrWhiteSpace(Config.LlmBaseUrl) ? fallback : Config.LlmBaseUrl.TrimEnd('/');
    static string DefaultModel(string fallback) => string.IsNullOrWhiteSpace(Config.LlmModel) ? fallback : Config.LlmModel;

    // ---- Claude (Anthropic Messages API): x-api-key + anthropic-version; structured JSON via output_config.format ----
    static async Task<string?> CallClaude(string text, HttpClient http, string baseUrl, string model, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = Config.LlmMaxTokens,
            ["system"] = SystemPrompt,
            ["messages"] = new JsonArray { new JsonObject { ["role"] = "user", ["content"] = text } },
            ["output_config"] = new JsonObject { ["format"] = new JsonObject { ["type"] = "json_schema", ["schema"] = ClueSchema.DeepClone() } },
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/v1/messages")
        { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        req.Headers.TryAddWithoutValidation("x-api-key", Config.LlmApiKey);
        req.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        var resp = await http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) return null;
        var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct));
        // content is an array of blocks; the first text block holds the JSON string.
        if (json?["content"] is JsonArray arr)
            foreach (var b in arr)
                if ((string?)b?["type"] == "text") return (string?)b?["text"];
        return null;
    }

    // ---- OpenAI / DeepSeek (OpenAI-compatible Chat Completions). OpenAI supports json_schema; DeepSeek uses json_object. ----
    static async Task<string?> CallOpenAiCompatible(string text, HttpClient http, string baseUrl, string model, bool strictSchema, CancellationToken ct)
    {
        var responseFormat = strictSchema
            ? new JsonObject { ["type"] = "json_schema", ["json_schema"] = new JsonObject { ["name"] = "find_clues", ["strict"] = true, ["schema"] = ClueSchema.DeepClone() } }
            : new JsonObject { ["type"] = "json_object" };
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = Config.LlmMaxTokens,
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = SystemPrompt },
                new JsonObject { ["role"] = "user", ["content"] = text },
            },
            ["response_format"] = responseFormat,
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/v1/chat/completions")
        { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Config.LlmApiKey);
        var resp = await http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) return null;
        var json = JsonNode.Parse(await resp.Content.ReadAsStringAsync(ct));
        return (string?)json?["choices"]?[0]?["message"]?["content"];
    }

    // Validate the model's JSON against the clue schema: keep only known keys, coerce types, drop everything else.
    static JsonObject? Coerce(string? rawJson)
    {
        if (string.IsNullOrWhiteSpace(rawJson)) return null;
        JsonObject? o;
        try { o = JsonNode.Parse(rawJson) as JsonObject; } catch { return null; }
        if (o == null) return null;
        var clue = new JsonObject();
        foreach (var k in StrKeys) clue[k] = ((string?)o[k] ?? "").Trim();
        foreach (var k in BoolKeys)
        {
            var v = o[k];
            clue[k] = v switch
            {
                null => k == "mine",   // default mine=true, tome=false
                _ => (bool?)TryBool(v) ?? (k == "mine"),
            };
        }
        return clue;
    }
    static bool? TryBool(JsonNode n)
    {
        try { return (bool)n!; } catch { }
        var s = ((string?)n ?? "").Trim().ToLowerInvariant();
        return s is "true" or "1" or "yes" ? true : s is "false" or "0" or "no" ? false : (bool?)null;
    }
}
