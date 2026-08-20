using System.Net.Http.Headers;
using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Dokłada do każdego wywołania wychodzącego cztery nagłówki wymagane w §0.3 oraz token
/// serwisowy wystawiony przez identity-service. Bez tego handlera każdy klient musiałby
/// pamiętać o tym sam, a wystarczy jedno przeoczenie, żeby container-registry odrzucił
/// żądanie kodem 403 z powodu niezgodności <c>X-OF-Tenant</c> z roszczeniem <c>tid</c>.
/// </summary>
/// <param name="context">Kontekst bieżącego żądania albo obsługiwanej wiadomości.</param>
/// <param name="tokens">Źródło tokenu serwisowego.</param>
/// <param name="logger">Dziennik.</param>
public sealed class PlatformHeadersHandler(
    IRequestContext context,
    IServiceTokenProvider tokens,
    ILogger<PlatformHeadersHandler> logger) : DelegatingHandler
{
    private readonly IRequestContext _context = context;
    private readonly IServiceTokenProvider _tokens = tokens;
    private readonly ILogger<PlatformHeadersHandler> _logger = logger;

    /// <inheritdoc />
    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            await _tokens.GetServiceTokenAsync(cancellationToken));

        request.Headers.TryAddWithoutValidation("X-OF-Tenant", _context.TenantId);
        request.Headers.TryAddWithoutValidation("X-OF-Trace-Id", _context.TraceId);
        request.Headers.TryAddWithoutValidation("X-OF-Actor-Kind", "service");

        // Klucz idempotencji dokładamy tylko tam, gdzie żądanie coś tworzy albo obciąża.
        // Na GET-cie byłby ignorowany, ale zaśmiecałby dzienniki dostępowe.
        if (request.Method != HttpMethod.Get && !request.Headers.Contains("X-OF-Idempotency-Key"))
        {
            request.Headers.TryAddWithoutValidation("X-OF-Idempotency-Key", Guid.NewGuid().ToString("N"));
        }

        var response = await base.SendAsync(request, cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            // Ciała nie logujemy — może zawierać dane przesyłki, a te podlegają rezydencji
            // regionalnej (§7 pkt 7). Wystarczy status, ślad i adres.
            _logger.LogWarning(
                "outbound call failed: {Method} {Uri} -> {Status} (trace {TraceId})",
                request.Method,
                request.RequestUri,
                (int)response.StatusCode,
                _context.TraceId);
        }

        return response;
    }
}

/// <summary>
/// Dostawca tokenu serwisowego. Token jest wystawiany przez <c>POST /v1/auth/token</c>
/// w identity-service na podstawie pary z <c>identity.api_credentials</c> i żyje 15 minut,
/// więc implementacja odnawia go z zapasem, a nie po pierwszym błędzie 401.
/// </summary>
public interface IServiceTokenProvider
{
    /// <summary>Zwraca ważny token dostępowy, w razie potrzeby odświeżając go w tle.</summary>
    Task<string> GetServiceTokenAsync(CancellationToken ct);
}
