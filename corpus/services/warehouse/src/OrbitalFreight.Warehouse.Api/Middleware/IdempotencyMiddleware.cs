using System.Security.Cryptography;
using Microsoft.AspNetCore.Http;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Api.Middleware;

/// <summary>
/// Realizuje §7 pkt 5: każde żądanie mutujące jest idempotentne po nagłówku
/// <c>X-OF-Idempotency-Key</c> przez 24 godziny. Powtórka z tym samym kluczem i tą samą treścią
/// dostaje zapamiętaną odpowiedź, a powtórka z tym samym kluczem i inną treścią — odmowę 409,
/// bo to zawsze błąd po stronie klienta, nigdy zamierzone działanie.
/// </summary>
/// <remarks>
/// Terminale magazynowe pracują w hali z dziurawym zasięgiem i ponawiają wysyłkę agresywnie.
/// Bez tego pośrednika jedno potwierdzenie kompletacji potrafiło zapisać trzy skany w
/// container-registry i trzy razy zdjąć kontener z gniazda.
/// </remarks>
/// <param name="next">Kolejny element potoku.</param>
/// <param name="options">Konfiguracja; źródło czasu życia klucza.</param>
public sealed class IdempotencyMiddleware(RequestDelegate next, IOptions<WarehouseOptions> options)
{
    private readonly RequestDelegate _next = next;
    private readonly WarehouseOptions _options = options.Value;

    /// <summary>Sprawdza klucz, obsługuje żądanie i zapamiętuje odpowiedź.</summary>
    /// <param name="httpContext">Kontekst żądania.</param>
    /// <param name="db">Kontekst bazy; tabela <c>warehouse.idempotency_keys</c>.</param>
    /// <param name="context">Kontekst żądania — źródło najemcy i śladu.</param>
    public async Task InvokeAsync(HttpContext httpContext, WarehouseDbContext db, IRequestContext context)
    {
        if (HttpMethods.IsGet(httpContext.Request.Method) || HttpMethods.IsHead(httpContext.Request.Method))
        {
            await _next(httpContext);
            return;
        }

        var key = httpContext.Request.Headers["X-OF-Idempotency-Key"].FirstOrDefault();

        if (string.IsNullOrWhiteSpace(key))
        {
            var error = ErrorMapper.Build(
                "idempotency_key_required",
                StatusCodes.Status400BadRequest,
                "every mutating request must carry X-OF-Idempotency-Key",
                context.TraceId,
                retryable: false);

            await error.ExecuteAsync(httpContext);
            return;
        }

        httpContext.Request.EnableBuffering();
        var bodyHash = await HashBodyAsync(httpContext.Request);
        var endpoint = $"{httpContext.Request.Method} {httpContext.Request.Path}";

        var existing = await db.IdempotencyRecords
            .AsNoTracking()
            .FirstOrDefaultAsync(r => r.TenantId == context.TenantId && r.Key == key, httpContext.RequestAborted);

        if (existing is not null)
        {
            if (!string.Equals(existing.RequestSha256, bodyHash, StringComparison.Ordinal))
            {
                var conflict = ErrorMapper.Build(
                    "idempotency_key_reuse",
                    StatusCodes.Status409Conflict,
                    "this idempotency key was already used with a different request body",
                    context.TraceId,
                    retryable: false);

                await conflict.ExecuteAsync(httpContext);
                return;
            }

            httpContext.Response.StatusCode = existing.StatusCode;
            httpContext.Response.ContentType = "application/json";
            await httpContext.Response.WriteAsync(existing.ResponseBody, httpContext.RequestAborted);
            return;
        }

        // Odpowiedź przechwytujemy do bufora w pamięci; ciała są tu małe (kilkaset bajtów),
        // a jedyną alternatywą byłoby ponowne wykonanie operacji przy powtórce.
        var originalBody = httpContext.Response.Body;
        using var buffer = new MemoryStream();
        httpContext.Response.Body = buffer;

        try
        {
            await _next(httpContext);

            buffer.Position = 0;
            var responseBody = await new StreamReader(buffer).ReadToEndAsync(httpContext.RequestAborted);

            // Zapamiętujemy wyłącznie odpowiedzi udane. Błąd 5xx bywa chwilowy i klient ma prawo
            // ponowić żądanie z tym samym kluczem, licząc na inny wynik.
            if (httpContext.Response.StatusCode is >= 200 and < 300)
            {
                var now = DateTimeOffset.UtcNow;

                db.IdempotencyRecords.Add(new IdempotencyRecordEntity
                {
                    Key = key,
                    TenantId = context.TenantId,
                    Endpoint = endpoint,
                    RequestSha256 = bodyHash,
                    StatusCode = httpContext.Response.StatusCode,
                    ResponseBody = responseBody,
                    CreatedAt = now,
                    ExpiresAt = now.AddHours(_options.IdempotencyTtlHours)
                });

                await db.SaveChangesAsync(httpContext.RequestAborted);
            }

            buffer.Position = 0;
            await buffer.CopyToAsync(originalBody, httpContext.RequestAborted);
        }
        finally
        {
            httpContext.Response.Body = originalBody;
        }
    }

    private static async Task<string> HashBodyAsync(HttpRequest request)
    {
        request.Body.Position = 0;
        using var sha = SHA256.Create();
        var hash = await sha.ComputeHashAsync(request.Body);
        request.Body.Position = 0;

        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
