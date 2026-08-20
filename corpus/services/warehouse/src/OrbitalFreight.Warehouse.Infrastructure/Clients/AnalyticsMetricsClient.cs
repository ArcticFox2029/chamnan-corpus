using System.Net.Http.Json;
using System.Text.Json.Serialization;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Klient analytics-pipeline, wyłącznie do klasyfikacji ABC w inwentaryzacji ciągłej.
/// Rotację czytamy z <c>GET /v1/metrics/container-utilisation</c>, czyli z widoku
/// <c>analytics.mv_container_utilisation_weekly</c> podanego przez API — sięgnięcie po ten widok
/// zapytaniem SQL byłoby złamaniem §7 pkt 2, mimo że stoi w tym samym klastrze.
/// </summary>
/// <remarks>
/// Krawędź warehouse-service → analytics-pipeline jest bezpieczna dla §7 pkt 8: analytics-pipeline
/// woła synchronicznie tylko identity-service, container-registry i geo-service, więc cyklu nie
/// domykamy. Widok odświeża się raz na dobę o 03:15 UTC, dlatego odpowiedź buforujemy na godzinę
/// i awaria tej usługi degraduje plan do metody <c>random</c>, a nie zatrzymuje inwentaryzacji.
/// </remarks>
/// <param name="http">Klient wskazujący na <c>OF_ANALYTICS_BASE_URL</c>.</param>
public sealed class AnalyticsMetricsClient(HttpClient http) : IUtilisationSnapshotPort
{
    private readonly HttpClient _http = http;

    /// <inheritdoc />
    public async Task<IReadOnlyDictionary<string, int>> GetWeeklyTripsAsync(
        string tenantId,
        DateOnly weekStart,
        CancellationToken ct)
    {
        var trips = new Dictionary<string, int>(StringComparer.Ordinal);
        string? cursor = null;

        do
        {
            var url = $"/v1/metrics/container-utilisation?tenant_id={tenantId}&week_start={weekStart:yyyy-MM-dd}&limit=200"
                      + (cursor is null ? string.Empty : $"&cursor={cursor}");

            var page = await _http.GetFromJsonAsync<UtilisationPageDto>(url, ct)
                       ?? throw new InvalidOperationException("analytics-pipeline returned an empty page");

            foreach (var row in page.Items)
            {
                trips[row.ContainerId] = row.Trips;
            }

            cursor = page.NextCursor;
        }
        while (cursor is not null);

        return trips;
    }

    private sealed record UtilisationPageDto(
        [property: JsonPropertyName("items")] IReadOnlyList<UtilisationRowDto> Items,
        [property: JsonPropertyName("next_cursor")] string? NextCursor);

    private sealed record UtilisationRowDto(
        [property: JsonPropertyName("container_id")] string ContainerId,
        [property: JsonPropertyName("iso_size_type")] string IsoSizeType,
        [property: JsonPropertyName("trips")] int Trips,
        [property: JsonPropertyName("fill_rate_pct")] decimal FillRatePct);
}
