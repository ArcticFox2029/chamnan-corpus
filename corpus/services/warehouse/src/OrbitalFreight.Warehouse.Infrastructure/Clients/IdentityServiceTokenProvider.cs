using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Trzyma ważny token serwisowy wystawiony przez identity-service przez
/// <c>POST /v1/auth/token</c> na podstawie pary z <c>identity.api_credentials</c>.
/// Odnawiamy go na minutę przed wygaśnięciem, bo token żyje 15 minut i czekanie na pierwsze
/// 401 oznaczałoby, że co kwadrans jedno żądanie magazynowe kończy się błędem.
/// </summary>
/// <param name="http">Klient wskazujący na identity-service.</param>
/// <param name="options">Konfiguracja usługi.</param>
/// <param name="logger">Dziennik.</param>
public sealed class IdentityServiceTokenProvider(
    HttpClient http,
    IOptions<WarehouseOptions> options,
    ILogger<IdentityServiceTokenProvider> logger) : IServiceTokenProvider
{
    private static readonly TimeSpan RenewalMargin = TimeSpan.FromMinutes(1);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly HttpClient _http = http;
    private readonly WarehouseOptions _options = options.Value;
    private readonly ILogger<IdentityServiceTokenProvider> _logger = logger;

    private string? _token;
    private DateTimeOffset _expiresAt = DateTimeOffset.MinValue;

    /// <inheritdoc />
    public async Task<string> GetServiceTokenAsync(CancellationToken ct)
    {
        if (_token is not null && DateTimeOffset.UtcNow + RenewalMargin < _expiresAt)
        {
            return _token;
        }

        await _gate.WaitAsync(ct);

        try
        {
            // Drugie sprawdzenie pod zamkiem: przy starcie poda o token prosi kilkanaście wątków
            // naraz i bez tego każdy z nich wystawiłby własny.
            if (_token is not null && DateTimeOffset.UtcNow + RenewalMargin < _expiresAt)
            {
                return _token;
            }

            var body = new TokenRequestDto("client_credentials", _options.ServiceName);
            using var response = await _http.PostAsJsonAsync("/v1/auth/token", body, ct);
            response.EnsureSuccessStatusCode();

            var dto = await response.Content.ReadFromJsonAsync<TokenResponseDto>(cancellationToken: ct)
                      ?? throw new InvalidOperationException("identity-service returned an empty token response");

            _token = dto.AccessToken;
            _expiresAt = DateTimeOffset.UtcNow.AddSeconds(dto.ExpiresIn);

            _logger.LogInformation("service token renewed, valid until {ExpiresAt:O}", _expiresAt);
            return _token;
        }
        finally
        {
            _gate.Release();
        }
    }

    private sealed record TokenRequestDto(
        [property: JsonPropertyName("grant_type")] string GrantType,
        [property: JsonPropertyName("client_id")] string ClientId);

    private sealed record TokenResponseDto(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("token_type")] string TokenType,
        [property: JsonPropertyName("expires_in")] int ExpiresIn);
}
