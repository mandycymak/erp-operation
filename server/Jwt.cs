using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Ops;

// JWT bearer validation for third-party API callers (Swivel L!NK / Cargoclip). The caller presents a signed JWT
// whose email claim identifies the user; we validate signature + issuer/audience/lifetime, then the email is
// federated to a UserRec (Auth.FindUserByEmail) and every query runs under that user's scope. This file ONLY
// answers "is this token valid, and whose email is it?" — it never touches the DB or scope. It fails CLOSED:
// any validation error returns null, which the caller turns into 401 (unlike Llm.cs, which fails open).
//
// Verification material is config-driven so we don't have to know the provider's scheme up front:
//   - HS256/384/512: a shared secret (Config.JwtSigningKey)
//   - RS*/ES*/PS*: a JWKS URL (Config.JwtJwksUrl, fetched + cached) or an inline PEM public key (Config.JwtPublicKey)
public static class Jwt
{
    static readonly JsonWebTokenHandler Handler = new();

    // JWKS keys are fetched once and cached for the process; on a validation miss (key rotation) we refresh once.
    static volatile IList<SecurityKey>? _jwksKeys;
    static readonly object _jwksLock = new();
    static readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(8) };

    public readonly record struct Identity(string Email, string DisplayName);

    // Validate `bearer` (the raw token, no "Bearer " prefix). Returns the email + display name, or null on any
    // failure. Synchronous wrapper over the async core (GetSession is sync).
    public static Identity? ValidateEmail(string bearer)
    {
        if (!Config.JwtEnabled || string.IsNullOrWhiteSpace(bearer)) return null;
        try { return ValidateAsync(bearer, allowJwksRefresh: true).GetAwaiter().GetResult(); }
        catch { return null; }
    }

    static async Task<Identity?> ValidateAsync(string bearer, bool allowJwksRefresh)
    {
        var keys = await ResolveKeysAsync(forceRefresh: false);
        if (keys.Count == 0) return null;

        var pars = new TokenValidationParameters
        {
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = keys,
            ValidateIssuer = Config.JwtIssuer != "",
            ValidIssuer = Config.JwtIssuer == "" ? null : Config.JwtIssuer,
            ValidateAudience = Config.JwtAudience != "",
            ValidAudience = Config.JwtAudience == "" ? null : Config.JwtAudience,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(Config.JwtClockSkewSec),
        };

        var result = await Handler.ValidateTokenAsync(bearer, pars);
        if (!result.IsValid)
        {
            // a signing-key mismatch can mean the JWKS rotated — refresh once and retry.
            if (allowJwksRefresh && Config.JwtJwksUrl != "" && result.Exception is SecurityTokenSignatureKeyNotFoundException)
            {
                await ResolveKeysAsync(forceRefresh: true);
                return await ValidateAsync(bearer, allowJwksRefresh: false);
            }
            return null;
        }

        var email = ClaimStr(result.Claims, Config.JwtEmailClaim);
        // common fallbacks if the configured claim isn't present
        if (email == "") email = ClaimStr(result.Claims, "email");
        if (email == "") email = ClaimStr(result.Claims, "upn");
        if (email == "") email = ClaimStr(result.Claims, "preferred_username");
        if (email == "" || !email.Contains('@')) return null;

        var name = ClaimStr(result.Claims, "name");
        if (name == "") name = ClaimStr(result.Claims, "displayName");
        return new Identity(email.Trim(), name.Trim());
    }

    static string ClaimStr(IDictionary<string, object> claims, string key) =>
        claims.TryGetValue(key, out var v) ? (v?.ToString() ?? "").Trim() : "";

    // ---- signing-key resolution (HS secret / inline PEM / JWKS) ----
    static async Task<IList<SecurityKey>> ResolveKeysAsync(bool forceRefresh)
    {
        if (Config.JwtSigningKey != "")
            return new List<SecurityKey> { new SymmetricSecurityKey(Encoding.UTF8.GetBytes(Config.JwtSigningKey)) };

        if (Config.JwtPublicKey != "")
            return PemKeys(Config.JwtPublicKey);

        if (Config.JwtJwksUrl != "")
        {
            if (!forceRefresh && _jwksKeys != null) return _jwksKeys;
            var fetched = await FetchJwksAsync(Config.JwtJwksUrl);
            if (fetched.Count > 0) lock (_jwksLock) _jwksKeys = fetched;
            return _jwksKeys ?? fetched;
        }
        return Array.Empty<SecurityKey>();
    }

    static List<SecurityKey> PemKeys(string pem)
    {
        var keys = new List<SecurityKey>();
        try { var rsa = RSA.Create(); rsa.ImportFromPem(pem); keys.Add(new RsaSecurityKey(rsa)); return keys; }
        catch { }
        try { var ec = ECDsa.Create(); ec.ImportFromPem(pem); keys.Add(new ECDsaSecurityKey(ec)); }
        catch { }
        return keys;
    }

    static async Task<IList<SecurityKey>> FetchJwksAsync(string url)
    {
        try
        {
            var json = await _http.GetStringAsync(url);
            var jwks = new JsonWebKeySet(json);
            return jwks.GetSigningKeys();
        }
        catch { return Array.Empty<SecurityKey>(); }
    }
}
