using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Nasłuchuje <c>telemetry.alert.raised</c> na <c>of.telemetry.v1</c>. Alarm o wybiegu
/// temperatury dla kontenera stojącego w naszym magazynie oznacza jedno z dwojga: albo agregat
/// stoi w gnieździe bez zasilania, albo zasilanie padło. W pierwszym przypadku przeadresowujemy
/// kontener do gniazda zasilanego, w drugim blokujemy gniazdo i zostawiamy sprawę ludziom.
/// </summary>
/// <remarks>
/// To jest ta sama krawędź, którą §1.2 opisuje dla container-registry: telemetry-ingest niczego
/// do nas nie woła, my do telemetry-ingest też nie — informacja płynie wyłącznie tematem.
/// Alarmu nie potwierdzamy przez <c>POST /v1/alerts/{alert_id}/acknowledge</c>, bo to należy
/// do operatora, który faktycznie sprawdził kontener.
/// </remarks>
/// <param name="slots">Repozytorium gniazd.</param>
/// <param name="putaway">Usługa przyjęć — przez nią wykonujemy przeadresowanie.</param>
/// <param name="options">Konfiguracja.</param>
/// <param name="deduplication">Pamięć obsłużonych zdarzeń.</param>
/// <param name="logger">Dziennik.</param>
public sealed class TelemetryAlertRaisedConsumer(
    ISlotRepository slots,
    PutawayService putaway,
    IOptions<WarehouseOptions> options,
    IEventDeduplicationStore deduplication,
    ILogger<TelemetryAlertRaisedConsumer> logger)
    : EventConsumerBase<TelemetryAlertRaisedPayload>(
        "of.telemetry.v1",
        "telemetry.alert.raised",
        deduplication,
        logger)
{
    private readonly ISlotRepository _slots = slots;
    private readonly PutawayService _putaway = putaway;
    private readonly WarehouseOptions _options = options.Value;

    // Reguły progowe pochodzą z OF_TELEMETRY_RULES_PATH po stronie telemetry-ingest; nas
    // interesują wyłącznie te dotyczące łańcucha chłodniczego i otwartych drzwi.
    private static readonly string[] ActionableRules =
    [
        "temp_above_setpoint",
        "temp_below_setpoint",
        "reefer_power_loss",
        "door_open_while_stationary"
    ];

    /// <inheritdoc />
    protected override async Task HandleAsync(
        EventEnvelope<TelemetryAlertRaisedPayload> envelope,
        CancellationToken ct)
    {
        var payload = envelope.Payload;

        if (Array.IndexOf(ActionableRules, payload.RuleCode) < 0)
        {
            return;
        }

        var placement = await _slots.FindActivePlacementByContainerAsync(payload.ContainerId, ct);
        if (placement is null)
        {
            // Kontener nie stoi u nas — alarm dotyczy trasy albo innego obiektu.
            return;
        }

        var slot = await _slots.FindSlotAsync(placement.SlotId, ct);
        if (slot is null)
        {
            return;
        }

        if (placement.RequiresPower && !slot.IsPowered)
        {
            Logger.LogWarning(
                "alert {AlertId} ({RuleCode}): reefer {ContainerId} sits in unpowered slot {SlotId}, re-slotting",
                payload.AlertId,
                payload.RuleCode,
                payload.ContainerId,
                slot.SlotId);

            await ReslotAsync(payload, placement.ShipmentId, ct);
            return;
        }

        if (payload.RuleCode == "reefer_power_loss")
        {
            // Zasilanie w gnieździe padło. Blokujemy je, żeby kolejna chłodnia tam nie trafiła,
            // i przenosimy kontener gdzie indziej.
            await _slots.SetSlotBlockedAsync(slot.SlotId, isBlocked: true, "power_fault", ct);
            await ReslotAsync(payload, placement.ShipmentId, ct);
            return;
        }

        Logger.LogInformation(
            "alert {AlertId} ({RuleCode}) on container {ContainerId} needs no slot change (peak {Peak}, threshold {Threshold})",
            payload.AlertId,
            payload.RuleCode,
            payload.ContainerId,
            payload.PeakValue,
            payload.ThresholdValue);
    }

    /// <summary>Zdejmuje kontener z bieżącego gniazda i adresuje go ponownie.</summary>
    private async Task ReslotAsync(TelemetryAlertRaisedPayload payload, string? shipmentId, CancellationToken ct)
    {
        await _putaway.RemoveAsync(payload.ContainerId, $"alert_{payload.RuleCode}", ct);

        var facilityId = await ResolveFacilityAsync(payload.ContainerId, ct);
        if (facilityId is null)
        {
            return;
        }

        var command = new PutawayCommand(
            facilityId,
            payload.ContainerId,
            shipmentId,
            GrossKg: 0,
            IsUnderCustomsControl: false,
            RegionCode: _options.RegionCode,
            HazardRadiusBays: _options.HazardSegregationRadiusBays,
            AislesWithSameShipment: new HashSet<short>());

        try
        {
            var result = await _putaway.PlaceAsync(command, ct);
            Logger.LogInformation(
                "container {ContainerId} moved to powered slot {SlotId} after alert {AlertId}",
                payload.ContainerId,
                result.Placement.SlotId,
                payload.AlertId);
        }
        catch (PutawayFailedException ex)
        {
            // Brak wolnego gniazda zasilanego to sytuacja alarmowa dla brygady, nie do ponawiania:
            // kontener stoi bez zasilania i liczy się czas, a nie kolejna próba za 30 sekund.
            Logger.LogError(
                "re-slotting {ContainerId} failed with {Code}; manual intervention required",
                payload.ContainerId,
                ex.Code);
        }
    }

    /// <summary>
    /// Ustala obiekt, w którym stoi kontener, na podstawie strefy jego gniazda. Nie pytamy o to
    /// container-registry, bo to my jesteśmy źródłem prawdy o tym, gdzie w hali coś stoi.
    /// </summary>
    private async Task<string?> ResolveFacilityAsync(string containerId, CancellationToken ct)
    {
        var placement = await _slots.FindActivePlacementByContainerAsync(containerId, ct);
        if (placement is null)
        {
            return null;
        }

        var slot = await _slots.FindSlotAsync(placement.SlotId, ct);
        if (slot is null)
        {
            return null;
        }

        var zones = await _slots.GetZonesAsync(string.Empty, ct);
        return zones.FirstOrDefault(z => z.ZoneId == slot.ZoneId)?.FacilityId;
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
