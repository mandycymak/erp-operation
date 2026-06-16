using System.Diagnostics;
using System.Text;

namespace Ops;

// Headless print-to-PDF of the agreed bill, reusing the on-screen print layout (bl-review.css @media print +
// bl-form.js). Used by doc-issue only; returns null on any failure (the issue then proceeds with no attachment).
// Mirrors Resolve-PdfEngine / Doc-RenderPdf.
public static class Pdf
{
    static readonly object _lock = new();
    static bool _resolved;
    static string? _engine;

    public static string? ResolveEngine()
    {
        if (_resolved) return _engine;
        lock (_lock)
        {
            if (_resolved) return _engine;
            _resolved = true;
            var pf = Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";
            var pfx86 = Environment.GetEnvironmentVariable("ProgramFiles(x86)") ?? @"C:\Program Files (x86)";
            var cands = new List<string?>
            {
                string.IsNullOrWhiteSpace(Config.PdfEngine) ? null : Config.PdfEngine!.Trim(),
                Path.Combine(pf, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(pfx86, @"Microsoft\Edge\Application\msedge.exe"),
                Path.Combine(pf, @"Google\Chrome\Application\chrome.exe"),
                Path.Combine(pfx86, @"Google\Chrome\Application\chrome.exe"),
            };
            _engine = cands.FirstOrDefault(c => !string.IsNullOrWhiteSpace(c) && File.Exists(c));
            return _engine;
        }
    }

    // Render the agreed bill to a PDF (base64). docType = "HBL"|"HAWB"; fieldsJson = the stored doc_version.fields
    // JSON. Returns null when no engine is installed or anything fails.
    public static string? Render(string docType, string fieldsJson)
    {
        var eng = ResolveEngine();
        if (eng == null) return null;
        string? htmlPath = null, pdfPath = null;
        try
        {
            var root = Config.RepoRoot;
            var css = File.ReadAllText(Path.Combine(root, "bl-review.css"));
            var js = File.ReadAllText(Path.Combine(root, "bl-form.js"));
            var dictJson = File.ReadAllText(Path.Combine(root, "doc-fields.json"));
            // neutralize any '</script>' breakout inside the injected JSON (valid JSON/JS unicode escapes)
            dictJson = dictJson.Replace("<", "\\u003c").Replace(">", "\\u003e");
            var fj = (fieldsJson ?? "{}").Replace("<", "\\u003c").Replace(">", "\\u003e");
            var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>" + css +
                       "</style></head><body><div class=\"page\"><div id=\"doc\"></div></div><script>" + js +
                       "</script><script>BLForm.setDict(" + dictJson + ");BLForm.render(document.getElementById(\"doc\"),\"" + docType + "\"," + fj + ",{editable:false});BLForm.setPrintSize(\"A4\");</script></body></html>";
            var baseName = Path.Combine(Path.GetTempPath(), "docpdf-" + Guid.NewGuid().ToString("N"));
            htmlPath = baseName + ".html"; pdfPath = baseName + ".pdf";
            File.WriteAllText(htmlPath, html, new UTF8Encoding(false));
            var uri = new Uri(htmlPath).AbsoluteUri;
            var psi = new ProcessStartInfo { FileName = eng, UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "--headless=new", "--disable-gpu", "--no-sandbox", "--no-pdf-header-footer", "--virtual-time-budget=3000", $"--print-to-pdf={pdfPath}", uri })
                psi.ArgumentList.Add(arg);
            using (var p = Process.Start(psi)) { p?.WaitForExit(); }
            if (File.Exists(pdfPath)) { var bytes = File.ReadAllBytes(pdfPath); if (bytes.Length > 100) return Convert.ToBase64String(bytes); }
            return null;
        }
        catch { return null; }
        finally { foreach (var fp in new[] { htmlPath, pdfPath }) { if (fp != null) try { File.Delete(fp); } catch { } } }
    }
}
