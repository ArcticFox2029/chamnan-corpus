using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Nasłuchuje <c>customs.declaration.cleared</c> na <c>of.customs.v1</c>. Do chwili zwolnienia
/// przez organ celny towar stoi w strefie <c>bonded</c> i polityka adresowania nie wypuści go
/// dalej; to zdarzenie jest jedynym sygnałem, po którym wolno przenieść kontener do zwykłej
/// strefy składowej i dopuścić go do kompletacji.
/// </summary>
/// <remarks>
/// customs-service niczego do nas nie woła, my do niego też nie — nie mamy klienta HTTP tej
/// usługi i nie wolno go dodać. Kierunek jest wyłącznie zdarzeniowy, dokładnie tak jak w parze
/// billing-service ↔ customs-service opisanej w §1.2.
/// </remarks>
/// <param name="slots">Repozytorium gniazd.</param>
/// <param name="putaway">Usługa przyjęć.</param>
/// <param name="options">Konfiguracja.</param>
/// <param name="deduplication">Pamięć obsłużonych zdarzeń.</param>
/// <param name="logger">Dziennik.</param>
public sealed class CustomsClearanceConsumer(
    ISlotRepository slots,
    PutawayService putaway,
    IOptions<WarehouseOptions> options,
    IEventDeduplicationStore deduplication,
    ILogger<CustomsClearanceConsumer> logger)
    : EventConsumerBase<DeclarationClearedPayload>(
        "of.customs.v1",
        "customs.declaration.cleared",
        deduplication,
        logger)
{
    private readonly ISlotRepository _slots = slots;
    private readonly PutawayService _putaway = putaway;
    private readonly WarehouseOptions _options = options.Value;

    /// <inheritdoc />
    protected override async Task HandleAsync(EventEnvelope<DeclarationClearedPayload> envelope, CancellationToken ct)
    {
        var payload = envelope.Payload;

        var zones = await _slots.GetZonesAsync(string.Empty, ct);
        var bondedZoneIds = zones
            .Where(z => z.Kind == Domain.Model.ZoneKind.Bonded)
            .Select(z => z.ZoneId)
            .ToHashSet(StringComparer.Ordinal);

        if (bondedZoneIds.Count == 0)
        {
            return;
        }

        // Przesyłka może mieć kilka kontenerów i tylko część z nich stoi w składzie celnym.
        // Przechodzimy po rozstawieniach, a nie po zgłoszeniu — zgłoszenie zna pozycje towarowe,
        // nie kontenery w naszej hali.
        var moved = 0;

        foreach (var zoneId in bondedZoneIds)
        {
            var free = await _slots.GetFreeSlotsAsync([zoneId], DateTimeOffset.UtcNow, limit: 1, ct);
            _ = free; // odczyt kontrolny: strefa musi istnieć, zanim zaczniemy przenosiny

            var placements = await FindPlacementsForShipmentAsync(payload.ShipmentId, zoneId, ct);

            foreach (var placement in placements)
            {
                await _putaway.RemoveAsync(placement.ContainerId, "customs_cleared", ct);

                var command = new PutawayCommand(
                    await ResolveFacilityAsync(placement.SlotId, ct) ?? string.Empty,
                    placement.ContainerId,
                    payload.ShipmentId,
                    placement.GrossKg,
                    IsUnderCustomsControl: false,
                    RegionCode: _options.RegionCode,
                    HazardRadiusBays: _options.HazardSegregationRadiusBays,
                    AislesWithSameShipment: new HashSet<short>());

                try
                {
                    await _putaway.PlaceAsync(command, ct);
                    moved++;
                }
                catch (PutawayFailedException ex)
                {
                    Logger.LogError(
                        "container {ContainerId} cleared under MRN {Mrn} but could not leave the bonded zone: {Code}",
                        placement.ContainerId,
                        payload.Mrn,
                        ex.Code);
                }
            }
        }

        Logger.LogInformation(
            "declaration {DeclarationId} cleared at {ClearedAt}: {Moved} container(s) released from bonded storage",
            payload.DeclarationId,
            payload.ClearedAt,
            moved);
    }

    private async Task<IReadOnlyList<Domain.Model.SlotPlacement>> FindPlacementsForShipmentAsync(
        string shipmentId,
        string zoneId,
        CancellationToken ct)
    {
        var page = await _slots.ListSlotsAsync(string.Empty, cursor: null, limit: 200, ct);
        var result = new List<Domain.Model.SlotPlacement>();

        foreach (var slot in page.Items.Where(s => s.ZoneId == zoneId))
        {
            var placement = await _slots.GetActivePlacementAsync(slot.SlotId, ct);
            if (placement is not null && placement.ShipmentId == shipmentId)
            {
                result.Add(placement);
            }
        }

        return result;
    }

    private async Task<string?> ResolveFacilityAsync(string slotId, CancellationToken ct)
    {
        var slot = await _slots.FindSlotAsync(slotId, ct);
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
