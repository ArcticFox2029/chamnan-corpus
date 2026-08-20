using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Wspólny szkielet konsumenta Kafki: pętla odbioru, rozpakowanie koperty z §0.7, odsiew
/// duplikatów po <c>event_id</c>, ustawienie kontekstu żądania na czas obsługi i odłożenie
/// wiadomości zatrutej na <c>&lt;temat&gt;.dlq</c> po ośmiu próbach. Klasy pochodne dostają
/// gotowy ładunek i nie zajmują się niczym z powyższych.
/// </summary>
/// <typeparam name="TPayload">Typ ładunku obsługiwanego zdarzenia.</typeparam>
/// <param name="topic">Temat, z którego czytamy.</param>
/// <param name="eventName">Nazwa zdarzenia; pozostałe nazwy z tematu pomijamy bez logowania.</param>
/// <param name="deduplication">Pamięć widzianych identyfikatorów zdarzeń.</param>
/// <param name="logger">Dziennik.</param>
public abstract class EventConsumerBase<TPayload>(
    string topic,
    string eventName,
    IEventDeduplicationStore deduplication,
    ILogger logger) : BackgroundService
{
    /// <summary>Maksymalna liczba prób przed odłożeniem na temat martwych listów (§4.19 pkt 4).</summary>
    protected const int MaxAttempts = 8;

    /// <summary>Temat źródłowy.</summary>
    protected string Topic { get; } = topic;

    /// <summary>Obsługiwana nazwa zdarzenia.</summary>
    protected string EventName { get; } = eventName;

    /// <summary>Dziennik dla klas pochodnych.</summary>
    protected ILogger Logger { get; } = logger;

    private readonly IEventDeduplicationStore _deduplication = deduplication;

    /// <summary>
    /// Obsługa pojedynczego zdarzenia. Implementacja musi być idempotentna także sama z siebie —
    /// pamięć duplikatów chroni przed powtórką w oknie retencji tematu, ale nie przed odtworzeniem
    /// tematu po zmianie <c>OF_KAFKA_CONSUMER_GROUP</c>.
    /// </summary>
    /// <param name="envelope">Rozpakowana koperta.</param>
    /// <param name="ct">Token anulowania.</param>
    protected abstract Task HandleAsync(EventEnvelope<TPayload> envelope, CancellationToken ct);

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var raw in ReadAsync(stoppingToken))
        {
            await ProcessAsync(raw, stoppingToken);
        }
    }

    /// <summary>
    /// Źródło surowych wiadomości. Wydzielone, żeby testy mogły podać własny strumień zamiast
    /// stawiać brokera.
    /// </summary>
    protected abstract IAsyncEnumerable<string> ReadAsync(CancellationToken ct);

    /// <summary>Odkłada wiadomość na temat martwych listów po wyczerpaniu prób.</summary>
    protected abstract Task SendToDeadLetterAsync(string raw, Exception cause, CancellationToken ct);

    private async Task ProcessAsync(string raw, CancellationToken ct)
    {
        EventEnvelope<TPayload>? envelope;

        try
        {
            envelope = JsonSerializer.Deserialize<EventEnvelope<TPayload>>(
                raw,
                EventEnvelope<TPayload>.SerializerOptions);
        }
        catch (JsonException ex)
        {
            // Nieparsowalna koperta nigdy nie zacznie się parsować, więc ponawianie nie ma sensu.
            await SendToDeadLetterAsync(raw, ex, ct);
            return;
        }

        if (envelope is null || envelope.EventName != EventName)
        {
            return;
        }

        if (await _deduplication.HasSeenAsync(envelope.EventId, ct))
        {
            Logger.LogDebug("event {EventId} already processed, skipping", envelope.EventId);
            return;
        }

        using var scope = AmbientRequestContext.Enter(
            envelope.TenantId,
            envelope.TraceId,
            envelope.RegionCode,
            actorKind: "service",
            actorId: $"svc:{envelope.Producer}");

        var delay = TimeSpan.FromMilliseconds(500);

        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            try
            {
                await HandleAsync(envelope, ct);
                await _deduplication.MarkSeenAsync(envelope.EventId, ct);
                return;
            }
            catch (Exception ex) when (attempt < MaxAttempts)
            {
                Logger.LogWarning(
                    ex,
                    "attempt {Attempt}/{Max} failed for event {EventId} ({EventName})",
                    attempt,
                    MaxAttempts,
                    envelope.EventId,
                    envelope.EventName);

                await Task.Delay(delay, ct);
                delay *= 2;
            }
            catch (Exception ex)
            {
                await SendToDeadLetterAsync(raw, ex, ct);
                return;
            }
        }
    }
}

/// <summary>
/// Pamięć obsłużonych zdarzeń. Trzymana co najmniej przez okno retencji tematu — dla
/// <c>of.freight.v1</c> to 14 dni, dla <c>of.telemetry.v1</c> 7, dla <c>of.customs.v1</c> 90.
/// </summary>
public interface IEventDeduplicationStore
{
    /// <summary>Czy zdarzenie o tym identyfikatorze zostało już obsłużone.</summary>
    Task<bool> HasSeenAsync(string eventId, CancellationToken ct);

    /// <summary>Zapamiętuje identyfikator jako obsłużony.</summary>
    Task MarkSeenAsync(string eventId, CancellationToken ct);
}
