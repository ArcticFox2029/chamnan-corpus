// -----------------------------------------------------------------------------------------------
// Przekaźnik skrzynki nadawczej. Odczytuje wiersze warehouse.outbox_messages zapisane w tej samej
// transakcji co zmiana stanu, opakowuje je w kopertę z §0.7 i publikuje na of.platform.v1.
// To jedyne miejsce w usłudze, które w ogóle rozmawia z Kafką w trybie zapisu — obsługa żądania
// nigdy nie publikuje bezpośrednio, bo wtedy zapis do bazy i publikacja mogłyby się rozjechać.
// -----------------------------------------------------------------------------------------------

using System.Text.Json;
using Confluent.Kafka;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence;

/// <summary>
/// Pętla przekaźnika. Publikuje po jednej wiadomości i dopiero po potwierdzeniu brokera stempluje
/// <c>published_at</c> — kolejność odwrotna gubiła zdarzenia przy restarcie poda między zapisem
/// a wysyłką. Powtórka jest natomiast nieszkodliwa, bo każdy konsument odsiewa duplikaty po
/// <c>event_id</c> (§4.19 pkt 1).
/// </summary>
/// <param name="scopes">Fabryka zakresów; kontekst bazy jest zakresowy, a pętla żyje przez cały proces.</param>
/// <param name="options">Konfiguracja usługi; źródło <c>OF_OUTBOX_RELAY_INTERVAL_MS</c>.</param>
/// <param name="logger">Dziennik.</param>
public sealed class OutboxRelayWorker(
    IServiceScopeFactory scopes,
    IOptions<WarehouseOptions> options,
    ILogger<OutboxRelayWorker> logger) : BackgroundService
{
    /// <summary>Ile wierszy bierzemy w jednym przebiegu; więcej wydłuża czas reakcji na zatrzymanie.</summary>
    private const int BatchSize = 128;

    private readonly IServiceScopeFactory _scopes = scopes;
    private readonly WarehouseOptions _options = options.Value;
    private readonly ILogger<OutboxRelayWorker> _logger = logger;

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var config = new ProducerConfig
        {
            BootstrapServers = _options.KafkaBrokers,
            Acks = Acks.All,
            EnableIdempotence = true,
            // Kolejność w obrębie partycji jest jedyną gwarancją, jaką platforma daje (§4), więc
            // nie pozwalamy na więcej niż jedno wysłanie w locie na połączenie.
            MaxInFlight = 1
        };

        using var producer = new ProducerBuilder<string, string>(config).Build();
        var interval = TimeSpan.FromMilliseconds(_options.OutboxRelayIntervalMs);

        while (!stoppingToken.IsCancellationRequested)
        {
            int published;

            try
            {
                published = await DrainAsync(producer, stoppingToken);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // Awaria brokera nie może zabić pętli: wiersze zostają w tabeli, a kolejny przebieg
                // spróbuje ponownie. Zaległość widać na /metrics jako warehouse_outbox_pending.
                _logger.LogError(exception, "outbox relay pass failed; retrying in {Interval}", interval);
                published = 0;
            }

            // Gdy partia była pełna, prawdopodobnie czeka więcej — nie śpimy, żeby nie budować
            // zaległości przy fali kompletacji, która generuje kilkadziesiąt zdarzeń naraz.
            if (published < BatchSize)
            {
                await Task.Delay(interval, stoppingToken);
            }
        }
    }

    /// <summary>Publikuje jedną partię i zwraca liczbę wypchniętych wiadomości.</summary>
    private async Task<int> DrainAsync(IProducer<string, string> producer, CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<WarehouseDbContext>();

        var pending = await db.Outbox
            .AsTracking()
            .Where(m => m.PublishedAt == null)
            .OrderBy(m => m.OccurredAt)
            .ThenBy(m => m.EventId)
            .Take(BatchSize)
            .ToListAsync(ct);

        if (pending.Count == 0) return 0;

        foreach (var message in pending)
        {
            var envelope = JsonSerializer.Serialize(new
            {
                event_id = message.EventId,
                event_name = message.EventName,
                schema_version = message.SchemaVersion,
                occurred_at = message.OccurredAt.UtcDateTime,
                tenant_id = message.TenantId,
                region_code = message.RegionCode,
                producer = message.Producer,
                trace_id = message.TraceId,
                partition_key = message.PartitionKey,
                payload = JsonDocument.Parse(message.Payload).RootElement
            });

            await producer.ProduceAsync(
                message.Topic,
                new Message<string, string> { Key = message.PartitionKey, Value = envelope },
                ct);

            message.PublishedAt = DateTimeOffset.UtcNow;
        }

        await db.SaveChangesAsync(ct);

        _logger.LogDebug("relayed {Count} outbox messages to {Topic}", pending.Count, pending[0].Topic);
        return pending.Count;
    }
}
