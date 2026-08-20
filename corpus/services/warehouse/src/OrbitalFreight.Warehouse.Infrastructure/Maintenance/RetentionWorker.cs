// -----------------------------------------------------------------------------------------------
// Sprzątanie danych o ograniczonym czasie życia: kluczy idempotencji z §7 pkt 5, pamięci widzianych
// event_id z §4.19 pkt 1 oraz opublikowanych wierszy skrzynki nadawczej. Bez tego trzy tabele rosną
// liniowo z ruchem, a to one, a nie gniazda, jako pierwsze zapełniły wolumen w Rotterdamie.
// -----------------------------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Infrastructure.Maintenance;

/// <summary>
/// Zadanie retencyjne. Chodzi co godzinę i kasuje w małych partiach — jedno duże DELETE na tabeli
/// kluczy idempotencji potrafiło zablokować zapis na kilkanaście sekund, co terminale w hali
/// odczytywały jako awarię i ponawiały żądania, powiększając problem.
/// </summary>
/// <param name="scopes">Fabryka zakresów.</param>
/// <param name="options">Konfiguracja usługi.</param>
/// <param name="clock">Zegar.</param>
/// <param name="logger">Dziennik.</param>
public sealed class RetentionWorker(
    IServiceScopeFactory scopes,
    IOptions<WarehouseOptions> options,
    TimeProvider clock,
    ILogger<RetentionWorker> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromHours(1);

    /// <summary>
    /// Ile trzymamy widziane <c>event_id</c>. Wartość odpowiada najdłuższej retencji tematu, który
    /// czytamy: <c>of.customs.v1</c> ma 90 dni, więc krótsze okno pozwoliłoby na powtórne
    /// przetworzenie zdarzenia po odtworzeniu tematu.
    /// </summary>
    private static readonly TimeSpan DeduplicationWindow = TimeSpan.FromDays(90);

    /// <summary>Opublikowane wiersze skrzynki zostawiamy na tydzień — tyle wystarcza na dochodzenie.</summary>
    private static readonly TimeSpan PublishedOutboxWindow = TimeSpan.FromDays(7);

    private const int BatchSize = 500;

    private readonly IServiceScopeFactory _scopes = scopes;
    private readonly WarehouseOptions _options = options.Value;
    private readonly TimeProvider _clock = clock;
    private readonly ILogger<RetentionWorker> _logger = logger;

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var removed = await SweepAsync(stoppingToken);
                if (removed > 0)
                {
                    _logger.LogInformation("retention sweep removed {Removed} row(s)", removed);
                }
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                _logger.LogError(exception, "retention sweep failed");
            }

            await Task.Delay(Interval, _clock, stoppingToken);
        }
    }

    /// <summary>Jeden przebieg sprzątania; zwraca liczbę usuniętych wierszy.</summary>
    private async Task<int> SweepAsync(CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<WarehouseDbContext>();

        var now = _clock.GetUtcNow();
        var removed = 0;

        var idempotencyCutoff = now - TimeSpan.FromHours(_options.IdempotencyTtlHours);
        var staleKeys = await db.IdempotencyRecords
            .Where(r => r.CreatedAt < idempotencyCutoff)
            .OrderBy(r => r.CreatedAt)
            .Select(r => new { r.TenantId, r.Key })
            .Take(BatchSize)
            .ToListAsync(ct);

        foreach (var key in staleKeys)
        {
            removed += await db.IdempotencyRecords
                .Where(r => r.TenantId == key.TenantId && r.Key == key.Key)
                .ExecuteDeleteAsync(ct);
        }

        var outboxCutoff = now - PublishedOutboxWindow;
        var publishedIds = await db.Outbox
            .Where(m => m.PublishedAt != null && m.PublishedAt < outboxCutoff)
            .OrderBy(m => m.PublishedAt)
            .Select(m => m.EventId)
            .Take(BatchSize)
            .ToListAsync(ct);

        removed += await db.Outbox
            .Where(m => publishedIds.Contains(m.EventId))
            .ExecuteDeleteAsync(ct);

        // Pamięć duplikatów żyje w tej samej bazie, ale kasujemy ją ostatnią: gdyby przebieg
        // przerwał się w połowie, lepiej mieć nadmiarowe wpisy niż stracić ochronę przed powtórką.
        // DELETE ... LIMIT nie istnieje w PostgreSQL, więc partię wycinamy przez ctid.
        var dedupeCutoff = now - DeduplicationWindow;
        removed += await db.Database.ExecuteSqlInterpolatedAsync(
            $"""
             DELETE FROM warehouse.processed_events
             WHERE ctid IN (
                 SELECT ctid FROM warehouse.processed_events
                 WHERE processed_at < {dedupeCutoff}
                 LIMIT {BatchSize}
             )
             """,
            ct);

        return removed;
    }
}
