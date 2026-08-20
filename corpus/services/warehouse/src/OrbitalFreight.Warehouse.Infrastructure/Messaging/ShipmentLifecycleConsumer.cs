using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.Picking;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Nasłuchuje <c>shipment.status.changed</c> na <c>of.freight.v1</c> i sprząta po przesyłkach,
/// które przestały być pracą magazynu: <c>cancelled</c> anuluje fale i zwalnia gniazda,
/// <c>delivered</c> zamyka rozstawienia, a <c>held_at_customs</c> zatrzymuje wydania, żeby
/// nikt nie wywiózł towaru spod dozoru celnego.
/// </summary>
/// <param name="waves">Usługa fal kompletacyjnych.</param>
/// <param name="options">Konfiguracja.</param>
/// <param name="deduplication">Pamięć obsłużonych zdarzeń.</param>
/// <param name="logger">Dziennik.</param>
public sealed class ShipmentLifecycleConsumer(
    PickWaveService waves,
    IOptions<WarehouseOptions> options,
    IEventDeduplicationStore deduplication,
    ILogger<ShipmentLifecycleConsumer> logger)
    : EventConsumerBase<ShipmentStatusChangedPayload>(
        "of.freight.v1",
        "shipment.status.changed",
        deduplication,
        logger)
{
    private readonly PickWaveService _waves = waves;
    private readonly WarehouseOptions _options = options.Value;

    /// <inheritdoc />
    protected override async Task HandleAsync(
        EventEnvelope<ShipmentStatusChangedPayload> envelope,
        CancellationToken ct)
    {
        var payload = envelope.Payload;

        switch (payload.ToStatus)
        {
            case "cancelled":
                var cancelled = await _waves.CancelForShipmentAsync(
                    payload.ShipmentId,
                    payload.ReasonCode ?? "shipment_cancelled",
                    ct);

                Logger.LogInformation(
                    "shipment {ShipmentId} cancelled, {Count} wave(s) withdrawn",
                    payload.ShipmentId,
                    cancelled);
                break;

            case "held_at_customs":
                // Wstrzymanie celne nie zmienia rozstawienia — towar stoi tam, gdzie stoi — ale
                // odwołujemy zaplanowane wydania. Zwolnienie przyjdzie zdarzeniem
                // customs.declaration.cleared, którego słucha CustomsClearanceConsumer.
                await _waves.CancelForShipmentAsync(payload.ShipmentId, "held_at_customs", ct);
                break;

            case "at_risk":
                // Stan nadany przez container-registry po telemetry.alert.raised. Sam alarm
                // obsługuje TelemetryAlertRaisedConsumer, tutaj wystarczy ślad w dzienniku —
                // podwójna reakcja przeadresowałaby kontener dwa razy.
                Logger.LogInformation(
                    "shipment {ShipmentId} flagged at_risk (reason {ReasonCode})",
                    payload.ShipmentId,
                    payload.ReasonCode);
                break;

            case "delivered":
                Logger.LogDebug("shipment {ShipmentId} delivered, nothing left in the hall", payload.ShipmentId);
                break;
        }
    }

    /// <inheritdoc />
    protected override async IAsyncEnumerable<string> ReadAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var message in KafkaSubscription.ReadAsync(_options, Topic, ct))
        {
            yield return message;
        }
    }

    /// <inheritdoc />
    protected override Task SendToDeadLetterAsync(string raw, Exception cause, CancellationToken ct) =>
        KafkaSubscription.PublishAsync(_options, $"{Topic}.dlq", raw, cause, ct);
}
