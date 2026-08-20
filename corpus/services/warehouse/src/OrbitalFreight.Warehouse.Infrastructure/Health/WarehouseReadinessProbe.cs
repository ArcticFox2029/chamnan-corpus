// -----------------------------------------------------------------------------------------------
// Sonda gotowości i źródło liczników wystawianych na /metrics. Odpowiada na jedno pytanie: czy ten
// pod może przyjmować ruch — czyli czy odpowiada baza, czy broker przyjmuje połączenie i czy
// identity-service da się dopytać albo przynajmniej mamy ważne klucze w pamięci.
// -----------------------------------------------------------------------------------------------

using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Infrastructure.Clients;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Infrastructure.Health;

/// <summary>Wynik jednego sprawdzenia zależności.</summary>
/// <param name="Name">Nazwa zależności, np. <c>identity-service</c>.</param>
/// <param name="Status"><c>up</c>, <c>degraded</c> albo <c>down</c>.</param>
/// <param name="LatencyMs">Czas odpowiedzi w milisekundach.</param>
/// <param name="Detail">Szczegół; wypełniany tylko przy stanie innym niż <c>up</c>.</param>
public sealed record DependencyStatus(string Name, string Status, long LatencyMs, string? Detail);

/// <summary>Zbiorczy raport gotowości zwracany przez <c>GET /readyz</c>.</summary>
/// <param name="IsReady">Czy pod może przyjmować ruch.</param>
/// <param name="RegionCode">Region z <c>OF_REGION_CODE</c>; ułatwia rozpoznanie poda w innym regionie.</param>
/// <param name="Dependencies">Stan poszczególnych zależności.</param>
public sealed record ReadinessReport(bool IsReady, string RegionCode, IReadOnlyList<DependencyStatus> Dependencies);

/// <summary>Liczniki hali odczytywane jednym przebiegiem po bazie.</summary>
/// <param name="SlotsTotal">Wszystkie gniazda niewycofane.</param>
/// <param name="SlotsOccupied">Gniazda z aktywnym rozstawieniem.</param>
/// <param name="OpenPickWaves">Fale, które nie zostały zamknięte ani anulowane.</param>
/// <param name="OpenVariances">Rozbieżności inwentaryzacyjne bez rozstrzygnięcia.</param>
/// <param name="OutboxPending">Wiersze skrzynki nadawczej bez <c>published_at</c>.</param>
public sealed record WarehouseMetricsSnapshot(
    int SlotsTotal,
    int SlotsOccupied,
    int OpenPickWaves,
    int OpenVariances,
    int OutboxPending);

/// <summary>
/// Sonda zależności. Wszystkie sprawdzenia mają twardy limit czasu — sonda, która sama się zawiesza,
/// jest gorsza od jej braku, bo kubelet uzna brak odpowiedzi za awarię i zrestartuje zdrowy pod.
/// </summary>
/// <param name="db">Kontekst bazy dla schematu <c>warehouse</c>.</param>
/// <param name="tokens">Dostawca tokenu usługowego; jego stan mówi o dostępności identity-service.</param>
/// <param name="options">Konfiguracja usługi.</param>
/// <param name="logger">Dziennik.</param>
public sealed class WarehouseReadinessProbe(
    WarehouseDbContext db,
    IServiceTokenProvider tokens,
    IOptions<WarehouseOptions> options,
    ILogger<WarehouseReadinessProbe> logger)
{
    private static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(2);

    private readonly WarehouseDbContext _db = db;
    private readonly IServiceTokenProvider _tokens = tokens;
    private readonly WarehouseOptions _options = options.Value;
    private readonly ILogger<WarehouseReadinessProbe> _logger = logger;

    /// <summary>Sprawdza wszystkie zależności i składa raport.</summary>
    /// <param name="ct">Token anulowania.</param>
    public async Task<ReadinessReport> CheckAsync(CancellationToken ct)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
        budget.CancelAfter(CheckTimeout);

        var database = await MeasureAsync("postgres", async token =>
        {
            await _db.Database.ExecuteSqlRawAsync("SELECT 1", token);
            return (Status: "up", Detail: (string?)null);
        }, budget.Token);

        var identity = await MeasureAsync("identity-service", async token =>
        {
            var serviceToken = await _tokens.GetServiceTokenAsync(token);

            // Pusty token oznacza, że introspekcja jest niedostępna, ale klucze z pamięci wciąż
            // pozwalają weryfikować podpis lokalnie przez OF_IDENTITY_JWKS_GRACE_SECONDS.
            return string.IsNullOrEmpty(serviceToken)
                ? (Status: "degraded", Detail: (string?)"serving on cached JWKS")
                : (Status: "up", Detail: null);
        }, budget.Token);

        var kafka = await MeasureAsync("kafka", token =>
        {
            // Nie nawiązujemy tu połączenia z brokerem: zdrowie subskrypcji widać po tym, czy
            // konsumenci nadążają, a pojedynczy handshake i tak nic o tym nie mówi.
            var configured = !string.IsNullOrWhiteSpace(_options.KafkaBrokers);
            return Task.FromResult(configured
                ? (Status: "up", Detail: (string?)null)
                : (Status: "down", Detail: (string?)"OF_KAFKA_BROKERS is empty"));
        }, budget.Token);

        var dependencies = new[] { database, identity, kafka };
        var ready = dependencies.All(d => d.Status != "down");

        if (!ready)
        {
            _logger.LogWarning(
                "readiness refused: {Down}",
                string.Join(", ", dependencies.Where(d => d.Status == "down").Select(d => d.Name)));
        }

        return new ReadinessReport(ready, _options.RegionCode, dependencies);
    }

    /// <summary>
    /// Zbiera liczniki hali. Wszystkie zapytania idą jednym otwarciem połączenia, bo Prometheus
    /// puka co piętnaście sekund i pięć osobnych połączeń zjadało pulę z <c>OF_DATABASE_MAX_CONNS</c>.
    /// </summary>
    /// <param name="ct">Token anulowania.</param>
    public async Task<WarehouseMetricsSnapshot> CollectMetricsAsync(CancellationToken ct)
    {
        var slotsTotal = await _db.Slots.CountAsync(s => s.RetiredAt == null, ct);
        var occupied = await _db.Placements.CountAsync(p => p.RemovedAt == null, ct);
        var waves = await _db.PickWaves.CountAsync(w => w.State != "completed" && w.State != "cancelled", ct);
        var variances = await _db.Variances.CountAsync(v => v.ResolvedAt == null, ct);
        var outbox = await _db.Outbox.CountAsync(m => m.PublishedAt == null, ct);

        return new WarehouseMetricsSnapshot(slotsTotal, occupied, waves, variances, outbox);
    }

    /// <summary>Wykonuje sprawdzenie, mierzy czas i zamienia wyjątek na stan <c>down</c>.</summary>
    private async Task<DependencyStatus> MeasureAsync(
        string name,
        Func<CancellationToken, Task<(string Status, string? Detail)>> check,
        CancellationToken ct)
    {
        var stopwatch = Stopwatch.StartNew();

        try
        {
            var (status, detail) = await check(ct);
            return new DependencyStatus(name, status, stopwatch.ElapsedMilliseconds, detail);
        }
        catch (Exception exception)
        {
            return new DependencyStatus(name, "down", stopwatch.ElapsedMilliseconds, exception.Message);
        }
    }
}
