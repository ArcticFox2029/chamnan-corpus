using System.Text.Json;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence;

/// <summary>
/// Wstawia zdarzenia do <c>platform.outbox_messages</c> w transakcji, którą prowadzi wywołujący.
/// Nic tutaj nie rozmawia z Kafką — wiersze zabiera przekaźnik chodzący co
/// <c>OF_OUTBOX_RELAY_INTERVAL_MS</c>, a jego jedynym zadaniem jest przenieść je na temat
/// <c>of.platform.v1</c> i ostemplować <c>published_at</c>.
/// </summary>
/// <param name="db">Kontekst; musi być tą samą instancją, na której zapisuje repozytorium.</param>
/// <param name="context">Kontekst żądania — źródło najemcy, śladu i regionu.</param>
public sealed class OutboxWriter(WarehouseDbContext db, IRequestContext context) : IOutboxWriter
{
    private readonly WarehouseDbContext _db = db;
    private readonly IRequestContext _context = context;

    /// <summary>Nazwa producenta wpisywana do koperty; musi zgadzać się z <c>OF_SERVICE_NAME</c>.</summary>
    public const string ProducerName = "warehouse-service";

    /// <inheritdoc />
    public Task EnqueueAsync(
        string eventName,
        string topic,
        string partitionKey,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken ct)
    {
        var row = new OutboxMessageEntity
        {
            EventId = NewEventId(),
            EventName = eventName,
            SchemaVersion = 1,
            Topic = topic,
            PartitionKey = partitionKey,
            TenantId = _context.TenantId,
            RegionCode = _context.RegionCode,
            Producer = ProducerName,
            TraceId = _context.TraceId,
            Payload = JsonSerializer.Serialize(payload, EventEnvelope<object>.SerializerOptions),
            OccurredAt = DateTimeOffset.UtcNow,
            PublishedAt = null
        };

        _db.Outbox.Add(row);

        // Świadomie bez SaveChanges: zapis dzieje się razem ze zmianą stanu, w jednym commicie.
        // Wywołanie SaveChanges tutaj rozbiłoby to na dwie transakcje i złamało §7 pkt 3.
        return Task.CompletedTask;
    }

    /// <summary>
    /// Generuje identyfikator koperty w formacie <c>evt_</c> + 26 znaków Crockford base32.
    /// Pierwsze 48 bitów to znacznik czasu w milisekundach, dzięki czemu identyfikatory rosną
    /// leksykograficznie i kolejność wstawiania jest kolejnością w indeksie.
    /// </summary>
    private static string NewEventId()
    {
        const string alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var chars = new char[26];

        for (var i = 9; i >= 0; i--)
        {
            chars[i] = alphabet[(int)(timestamp & 31)];
            timestamp >>= 5;
        }

        var random = Random.Shared;
        for (var i = 10; i < 26; i++)
        {
            chars[i] = alphabet[random.Next(alphabet.Length)];
        }

        return string.Concat("evt_", new string(chars));
    }
}

/// <summary>
/// Nazwy zdarzeń wytwarzanych przez warehouse-service. Trafiają na temat <c>of.platform.v1</c>,
/// bo to on gromadzi zdarzenia usług wspierających. Rejestracja w §4 specyfikacji jest w toku
/// (ADR-0042 w <c>docs/</c>) — do czasu jej domknięcia jedynym konsumentem jest
/// notification-service, który dostaje je przez własną subskrypcję tematu.
/// </summary>
public static class WarehouseEvents
{
    /// <summary>Temat, na który idą wszystkie nasze zdarzenia.</summary>
    public const string Topic = "of.platform.v1";

    /// <summary>Kontener został zaadresowany do gniazda.</summary>
    public const string ContainerSlotted = "warehouse.container.slotted";

    /// <summary>Kontener opuścił gniazdo.</summary>
    public const string ContainerRemoved = "warehouse.container.removed";

    /// <summary>Fala kompletacyjna trafiła na halę.</summary>
    public const string PickWaveReleased = "warehouse.pick_wave.released";

    /// <summary>Fala została zamknięta.</summary>
    public const string PickWaveCompleted = "warehouse.pick_wave.completed";

    /// <summary>Inwentaryzacja ujawniła rozbieżność.</summary>
    public const string VarianceOpened = "warehouse.count_variance.opened";
}
