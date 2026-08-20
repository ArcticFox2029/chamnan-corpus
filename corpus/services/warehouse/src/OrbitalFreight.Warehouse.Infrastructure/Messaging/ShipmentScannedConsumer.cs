using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Nasłuchuje <c>shipment.scanned</c> na <c>of.freight.v1</c> i zamienia skan na pracę
/// w magazynie: <c>gate_in</c> w obiekcie typu <c>warehouse</c> uruchamia przyjęcie i wskazanie
/// gniazda, <c>gate_out</c> zdejmuje kontener z ewidencji, a <c>damage_report</c> przenosi go
/// do strefy kwarantanny.
/// </summary>
/// <remarks>
/// Skany własnego autorstwa odsiewamy po <c>device_serial</c>. Bez tego potwierdzenie zadania
/// kompletacji — które sami zapisujemy w container-registry — wracałoby tu jako nowe zdarzenie
/// i próbowało zdjąć z gniazda kontener już zdjęty.
/// </remarks>
/// <param name="putaway">Usługa przyjęć.</param>
/// <param name="options">Konfiguracja; źródło numeru seryjnego naszego „urządzenia”.</param>
/// <param name="deduplication">Pamięć obsłużonych zdarzeń.</param>
/// <param name="logger">Dziennik.</param>
public sealed class ShipmentScannedConsumer(
    PutawayService putaway,
    IOptions<WarehouseOptions> options,
    IEventDeduplicationStore deduplication,
    ILogger<ShipmentScannedConsumer> logger)
    : EventConsumerBase<ShipmentScannedPayload>("of.freight.v1", "shipment.scanned", deduplication, logger)
{
    private readonly PutawayService _putaway = putaway;
    private readonly WarehouseOptions _options = options.Value;

    /// <inheritdoc />
    protected override async Task HandleAsync(EventEnvelope<ShipmentScannedPayload> envelope, CancellationToken ct)
    {
        var payload = envelope.Payload;

        if (string.Equals(payload.DeviceSerial, _options.ScanDeviceSerial, StringComparison.Ordinal))
        {
            return;
        }

        if (payload.ContainerId is null || payload.FacilityId is null)
        {
            // Skan całej przesyłki albo skan bez obiektu nie dotyczy pracy magazynowej.
            return;
        }

        switch (payload.ScanType)
        {
            case "gate_in":
                await OnGateInAsync(payload, ct);
                break;

            case "gate_out":
            case "load":
                await _putaway.RemoveAsync(payload.ContainerId, $"scan_{payload.ScanType}", ct);
                break;

            case "damage_report":
                // Uszkodzony kontener schodzi z gniazda i czeka w kwarantannie na decyzję —
                // ponownego adresowania nie robimy automatycznie, bo strefę wybiera brygadzista.
                await _putaway.RemoveAsync(payload.ContainerId, "damage_reported", ct);
                Logger.LogWarning(
                    "container {ContainerId} reported damaged at {FacilityId}, removed from its slot",
                    payload.ContainerId,
                    payload.FacilityId);
                break;

            case "unload":
            case "seal_check":
            case "customs_inspection":
            case "proof_of_delivery":
                // Te rodzaje skanu nie zmieniają obłożenia gniazd. Wymieniamy je jawnie, żeby
                // dołożenie nowej wartości do CHECK-a w container-registry rzuciło się w oczy
                // przy przeglądzie, zamiast wpaść w cichy default.
                break;

            default:
                Logger.LogInformation("ignoring unknown scan type {ScanType}", payload.ScanType);
                break;
        }
    }

    private async Task OnGateInAsync(ShipmentScannedPayload payload, CancellationToken ct)
    {
        var command = new PutawayCommand(
            payload.FacilityId!,
            payload.ContainerId!,
            payload.ShipmentId,
            GrossKg: 0, // masa przyjdzie z container-registry razem z kontenerem
            IsUnderCustomsControl: false,
            RegionCode: _options.RegionCode,
            HazardRadiusBays: _options.HazardSegregationRadiusBays,
            AislesWithSameShipment: new HashSet<short>());

        try
        {
            var result = await _putaway.PlaceAsync(command, ct);
            Logger.LogInformation(
                "gate_in of {ContainerId} resolved to slot {SlotId}",
                payload.ContainerId,
                result.Placement.SlotId);
        }
        catch (PutawayFailedException ex) when (ex.Code == "container_already_placed")
        {
            // Podwójny skan na bramie zdarza się codziennie: kierowca zjeżdża i wraca. Kontener
            // już stoi, więc nie ma czego robić.
            Logger.LogDebug("container {ContainerId} is already placed, gate_in ignored", payload.ContainerId);
        }
        catch (PutawayFailedException ex) when (ex.Code == "no_eligible_slot")
        {
            // To jest sytuacja dla człowieka, nie do ponawiania w nieskończoność: hala jest pełna
            // albo ładunek nie mieści się w żadnej dopuszczalnej strefie.
            Logger.LogError(
                "no eligible slot for container {ContainerId} at facility {FacilityId}",
                payload.ContainerId,
                payload.FacilityId);
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
