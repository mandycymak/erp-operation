using Microsoft.Data.SqlClient;

namespace Ops;

// Cached documentTypeCode + houseTypeCode options for the drawer "Generate document" feature, derived from the
// admin-editable dbo.doc_generate_map. One documentTypeCode can carry many houseTypeCodes (per module). Built once;
// reset to null on any admin docgen edit so changes take effect with no restart (mirrors DoctypeMap). Consumed by
// Handlers.ErpFiles (panel options) and Handlers.ErpDocGenerate (validate a chosen combo before calling the ERP).
public static class DocGenMap
{
    public sealed record Option(string Module, string DocumentTypeCode, string HouseTypeCode, bool UseMasterBill, bool InvoiceRequired);

    static volatile List<Option>? _cache;
    static readonly object _lock = new();

    public static void Reset() => _cache = null;

    public static List<Option> Get(SqlConnection cn)
    {
        var c = _cache;
        if (c != null) return c;
        lock (_lock)
        {
            if (_cache != null) return _cache;
            var list = new List<Option>();
            var rows = Db.RunQ(cn,
                "SELECT module,document_type_code,house_type_code,use_master_bill,invoice_required " +
                "FROM dbo.doc_generate_map WHERE active=1 ORDER BY module,document_type_code,house_type_code",
                new Dictionary<string, object?>());
            foreach (var r in rows)
                list.Add(new Option(
                    Db.Str(Db.G(r, "module")).Trim().ToUpperInvariant(),
                    Db.Str(Db.G(r, "document_type_code")).Trim(),
                    Db.Str(Db.G(r, "house_type_code")).Trim(),
                    Db.IntOf(Db.G(r, "use_master_bill")) != 0,
                    Db.IntOf(Db.G(r, "invoice_required")) != 0));
            _cache = list;
            return list;
        }
    }

    // active options for one module (AIR/SEA), ordered for display.
    public static List<Option> ForModule(SqlConnection cn, string module)
    {
        var m = (module ?? "").Trim().ToUpperInvariant();
        return Get(cn).Where(o => o.Module == m).ToList();
    }

    // validate a chosen (module, documentTypeCode, houseTypeCode) combo; returns the matching option or null
    // (null => not configured, so the generate request is refused). houseTypeCode "" matches a no-house-type config.
    public static Option? Lookup(SqlConnection cn, string module, string doc, string house)
    {
        var m = (module ?? "").Trim().ToUpperInvariant();
        var d = (doc ?? "").Trim();
        var h = (house ?? "").Trim();
        return Get(cn).FirstOrDefault(o => o.Module == m
            && string.Equals(o.DocumentTypeCode, d, StringComparison.Ordinal)
            && string.Equals(o.HouseTypeCode, h, StringComparison.Ordinal));
    }
}
