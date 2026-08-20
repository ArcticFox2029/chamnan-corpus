using System.Security.Cryptography;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Api.Middleware;

/// <summary>
/// Sprawdza nagłówki obowiązkowe z §0.3 i ustawia kontekst żądania na czas jego obsługi.
/// Brak <c>X-OF-Tenant</c> albo niezgodność z roszczeniem <c>tid</c> w tokenie kończy się
/// odmową 403 — nie dlatego, że tak jest wygodniej, tylko dlatego, że najemcy dzielą fizycznie
/// tę samą bazę i to ten nagłówek odpowiada za rozdzielenie ich danych.
/// </summary>
/// <param name="next">Kolejny element potoku.</param>
/// <param name="options">Konfiguracja usługi; źródło <c>OF_REGION_CODE</c>.</param>
/// <param name="logger">Dziennik.</param>
public sealed class RequestContextMiddleware(
    RequestDelegate next,
    IOptions<WarehouseOptions> options,
    ILogger<RequestContextMiddleware> logger)
{
    private static readonly string[] ActorKinds = ["user", "service", "device", "partner"];

    private readonly RequestDelegate _next = next;
    private readonly WarehouseOptions _options = options.Value;
    private readonly ILogger<RequestContextMiddleware> _logger = logger;

    /// <summary>Wykonuje sprawdzenia i przekazuje żądanie dalej.</summary>
    /// <param name="httpContext">Kontekst żądania.</param>
    public async Task InvokeAsync(HttpContext httpContext)
    {
        // Sondy i metryki nie mają najemcy i nie mogą go mieć — Kubernetes odpytuje je bez tokenu.
        if (IsOperationalPath(httpContext.Request.Path))
        {
            await _next(httpContext);
            return;
        }

        var traceId = httpContext.Request.Headers["X-OF-Trace-Id"].FirstOrDefault() ?? NewTraceId();
        var tenantId = httpContext.Request.Headers["X-OF-Tenant"].FirstOrDefault();
        var actorKind = httpContext.Request.Headers["X-OF-Actor-Kind"].FirstOrDefault() ?? "user";

        if (string.IsNullOrWhiteSpace(tenantId))
        {
            await WriteErrorAsync(httpContext, "tenant_header_missing", StatusCodes.Status400BadRequest, traceId);
            return;
        }

        if (Array.IndexOf(ActorKinds, actorKind) < 0)
        {
            await WriteErrorAsync(httpContext, "invalid_actor_kind", StatusCodes.Status400BadRequest, traceId);
            return;
        }

        var claimedTenant = httpContext.User.FindFirst("tid")?.Value;
        if (claimedTenant is not null && !string.Equals(claimedTenant, tenantId, StringComparison.Ordinal))
        {
            _logger.LogWarning(
                "tenant mismatch: header {HeaderTenant} vs token {TokenTenant} (trace {TraceId})",
                tenantId,
                claimedTenant,
                traceId);

            await WriteErrorAsync(httpContext, "tenant_mismatch", StatusCodes.Status403Forbidden, traceId);
            return;
        }

        var actorId = httpContext.User.FindFirst("sub")?.Value ?? $"svc:{_options.ServiceName}";

        // Ślad zwracamy zawsze, także gdy sami go wygenerowaliśmy — klient ma czym zgłosić
        // problem, a my mamy po czym połączyć logi wszystkich usług w jednym łańcuchu.
        httpContext.Response.Headers["X-OF-Trace-Id"] = traceId;

        using var scope = AmbientRequestContext.Enter(
            tenantId,
            traceId,
            _options.RegionCode,
            actorKind,
            actorId);

        using var logScope = _logger.BeginScope(new Dictionary<string, object>
        {
            ["trace_id"] = traceId,
            ["tenant_id"] = tenantId,
            ["actor_kind"] = actorKind
        });

        await _next(httpContext);
    }

    private static bool IsOperationalPath(PathString path) =>
        path.StartsWithSegments("/healthz")
        || path.StartsWithSegments("/readyz")
        || path.StartsWithSegments("/metrics")
        || path.StartsWithSegments("/version");

    /// <summary>Nowy identyfikator śladu W3C: 32 znaki szesnastkowe z generatora kryptograficznego.</summary>
    private static string NewTraceId()
    {
        Span<byte> bytes = stackalloc byte[16];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    private static async Task WriteErrorAsync(HttpContext httpContext, string code, int status, string traceId)
    {
        httpContext.Response.StatusCode = status;
        httpContext.Response.ContentType = "application/json";

        var envelope = new ErrorEnvelope(new ErrorBody(
            code,
            status,
            $"request rejected by warehouse-service: {code}",
            traceId,
            Retryable: false,
            Fields: null));

        await httpContext.Response.WriteAsJsonAsync(envelope);
    }
}
