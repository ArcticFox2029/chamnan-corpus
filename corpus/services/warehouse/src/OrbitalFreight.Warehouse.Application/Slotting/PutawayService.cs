using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Domain.Slotting;

namespace OrbitalFreight.Warehouse.Application.Slotting;

/// <summary>
/// Scenariusz „przyjmij kontener i wskaż mu miejsce”: pobiera dane z container-registry,
/// dopasowuje regułę adresowania, każe <see cref="SlottingPolicy"/> ocenić wolne gniazda,
/// zapisuje rozstawienie i w tej samej transakcji wkłada zdarzenie do skrzynki nadawczej.
/// Cała reszta usługi (końcówki HTTP, konsumenci zdarzeń) korzysta z tego jednego przebiegu,
/// żeby nie powstały dwie różne definicje tego, co znaczy „przyjęty”.
/// </summary>
/// <param name="slots">Repozytorium gniazd i rozstawień.</param>
/// <param name="registry">Port do container-registry.</param>
/// <param name="outbox">Skrzynka nadawcza.</param>
/// <param name="uow">Granica transakcji.</param>
/// <param name="policy">Reguły doboru gniazda.</param>
/// <param name="ids">Wytwórnia identyfikatorów.</param>
/// <param name="clock">Zegar; wstrzykiwany, żeby testy nie zależały od <c>DateTimeOffset.UtcNow</c>.</param>
/// <param name="logger">Dziennik.</param>
public sealed class PutawayService(
    ISlotRepository slots,
    IContainerRegistryPort registry,
    IOutboxWriter outbox,
    IWarehouseUnitOfWork uow,
    SlottingPolicy policy,
    IIdentifierFactory ids,
    TimeProvider clock,
    ILogger<PutawayService> logger)
{
    private readonly ISlotRepository _slots = slots;
    private readonly IContainerRegistryPort _registry = registry;
    private readonly IOutboxWriter _outbox = outbox;
    private readonly IWarehouseUnitOfWork _uow = uow;
    private readonly SlottingPolicy _policy = policy;
    private readonly IIdentifierFactory _ids = ids;
    private readonly TimeProvider _clock = clock;
    private readonly ILogger<PutawayService> _logger = logger;

    /// <summary>
    /// Adresuje kontener i zapisuje rozstawienie.
    /// </summary>
    /// <param name="command">Polecenie przyjęcia.</param>
    /// <param name="ct">Token anulowania.</param>
    /// <returns>Zapisane rozstawienie wraz z uzasadnieniem wyboru.</returns>
    /// <exception cref="PutawayFailedException">
    /// Gdy kontener albo przesyłka nie istnieją, gdy żadne gniazdo nie przeszło reguł twardych
    /// albo gdy kontener już gdzieś stoi.
    /// </exception>
    public async Task<PutawayResult> PlaceAsync(PutawayCommand command, CancellationToken ct)
    {
        var container = await _registry.GetContainerAsync(command.ContainerId, ct)
            ?? throw new PutawayFailedException("container_not_found", command.ContainerId);

        var existing = await _slots.FindActivePlacementByContainerAsync(command.ContainerId, ct);
        if (existing is not null)
        {
            throw new PutawayFailedException("container_already_placed", existing.SlotId);
        }

        var shipment = command.ShipmentId is null
            ? null
            : await _registry.GetShipmentAsync(command.ShipmentId, ct)
              ?? throw new PutawayFailedException("shipment_not_found", command.ShipmentId);

        var now = _clock.GetUtcNow();
        var candidates = await BuildCandidatesAsync(command, container, shipment, now, ct);

        var request = new SlottingRequest(
            container.ContainerId,
            command.ShipmentId,
            command.GrossKg,
            container.IsoSizeType,
            container.IsReefer,
            container.SetpointC,
            container.PrimaryHazardClassCode,
            command.IsUnderCustomsControl,
            shipment?.RegionCode ?? command.RegionCode,
            SlottingRequest.UrgencyFrom(shipment?.SlaDeadlineAt, now));

        var choice = _policy.Choose(request, candidates)
            ?? throw new PutawayFailedException("no_eligible_slot", command.FacilityId);

        var placement = new SlotPlacement(
            _ids.NewId(PrefixedId.Placement),
            choice.SlotId,
            container.ContainerId,
            command.ShipmentId,
            command.GrossKg,
            container.PrimaryHazardClassCode,
            container.IsReefer,
            now,
            RemovedAt: null);

        await using var tx = await _uow.BeginAsync(ct);

        await _slots.AddPlacementAsync(placement, ct);
        await _outbox.EnqueueAsync(
            "warehouse.container.slotted",
            "of.platform.v1",
            command.ShipmentId ?? command.FacilityId,
            new Dictionary<string, object?>
            {
                ["placement_id"] = placement.PlacementId,
                ["slot_id"] = placement.SlotId,
                ["container_id"] = placement.ContainerId,
                ["shipment_id"] = placement.ShipmentId,
                ["facility_id"] = command.FacilityId,
                ["gross_kg"] = placement.GrossKg,
                ["placed_at"] = placement.PlacedAt
            },
            ct);

        await _uow.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        _logger.LogInformation(
            "container {ContainerId} slotted into {SlotId} (score {Score:F2})",
            placement.ContainerId,
            placement.SlotId,
            choice.Score);

        return new PutawayResult(placement, choice.Score);
    }

    /// <summary>
    /// Zdejmuje kontener z gniazda. Wywoływane przy wydaniu, przy przeadresowaniu i przez
    /// konsumenta <c>shipment.status.changed</c>, gdy przesyłka zostaje anulowana.
    /// </summary>
    /// <returns><see langword="true"/>, gdy było co zdejmować.</returns>
    public async Task<bool> RemoveAsync(string containerId, string reasonCode, CancellationToken ct)
    {
        var placement = await _slots.FindActivePlacementByContainerAsync(containerId, ct);
        if (placement is null)
        {
            return false;
        }

        var now = _clock.GetUtcNow();

        await using var tx = await _uow.BeginAsync(ct);

        await _slots.ClosePlacementAsync(placement.PlacementId, now, ct);
        await _outbox.EnqueueAsync(
            "warehouse.container.removed",
            "of.platform.v1",
            placement.ShipmentId ?? placement.SlotId,
            new Dictionary<string, object?>
            {
                ["placement_id"] = placement.PlacementId,
                ["slot_id"] = placement.SlotId,
                ["container_id"] = placement.ContainerId,
                ["shipment_id"] = placement.ShipmentId,
                ["reason_code"] = reasonCode,
                ["removed_at"] = now
            },
            ct);

        await _uow.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        return true;
    }

    /// <summary>
    /// Zwraca ranking bez zapisywania czegokolwiek — ekran dyspozytora pokazuje w nim także
    /// gniazda odrzucone wraz z kodem przyczyny.
    /// </summary>
    public async Task<IReadOnlyList<SlotScore>> RecommendAsync(PutawayCommand command, CancellationToken ct)
    {
        var container = await _registry.GetContainerAsync(command.ContainerId, ct)
            ?? throw new PutawayFailedException("container_not_found", command.ContainerId);

        var now = _clock.GetUtcNow();
        var candidates = await BuildCandidatesAsync(command, container, shipment: null, now, ct);

        var request = new SlottingRequest(
            container.ContainerId,
            command.ShipmentId,
            command.GrossKg,
            container.IsoSizeType,
            container.IsReefer,
            container.SetpointC,
            container.PrimaryHazardClassCode,
            command.IsUnderCustomsControl,
            command.RegionCode,
            UrgencyFactor: 1.0);

        return _policy.Rank(request, candidates);
    }

    /// <summary>
    /// Buduje kandydatów: wybiera strefy zgodne z regułą adresowania, pobiera wolne gniazda
    /// i dokłada do nich kontekst, którego sama tabela gniazd nie zawiera.
    /// </summary>
    private async Task<IReadOnlyList<SlotCandidate>> BuildCandidatesAsync(
        PutawayCommand command,
        ContainerSnapshot container,
        ShipmentSnapshot? shipment,
        DateTimeOffset now,
        CancellationToken ct)
    {
        var zones = await _slots.GetZonesAsync(command.FacilityId, ct);
        var rules = await _slots.GetPutawayRulesAsync(command.FacilityId, ct);

        var rule = rules.FirstOrDefault(r =>
            r.Matches(container.IsoSizeType, container.IsReefer, container.PrimaryHazardClassCode));

        // Brak dopasowanej reguły nie jest błędem — wtedy dopuszczamy wszystkie strefy składowe
        // i o wyborze decydują same reguły twarde polityki.
        var eligibleZones = rule is null
            ? zones.Where(z => z.Kind is ZoneKind.Rack or ZoneKind.Bulk or ZoneKind.Reefer or ZoneKind.Bonded).ToList()
            : zones.Where(z => z.Kind == rule.TargetZoneKind).ToList();

        if (eligibleZones.Count == 0)
        {
            return [];
        }

        var zoneById = eligibleZones.ToDictionary(z => z.ZoneId, StringComparer.Ordinal);
        var free = await _slots.GetFreeSlotsAsync(zoneById.Keys, now, limit: 400, ct);

        if (free.Count == 0)
        {
            return [];
        }

        var maxTravel = free.Max(s => s.TravelCostM);
        var poweredFreeRatio = free.Count(s => s.IsPowered) / (double)free.Count;

        var candidates = new List<SlotCandidate>(free.Count);

        foreach (var slot in free)
        {
            var neighbours = container.PrimaryHazardClassCode is null
                ? []
                : await _slots.GetNeighbourHazardClassesAsync(slot.SlotId, command.HazardRadiusBays, ct);

            candidates.Add(new SlotCandidate(
                slot,
                zoneById[slot.ZoneId],
                neighbours,
                maxTravel,
                poweredFreeRatio,
                SameShipmentInAisle: shipment is not null && command.AislesWithSameShipment.Contains(slot.Aisle),
                SizeFitRatio: SizeFit(container.IsoSizeType, slot)));
        }

        return candidates;
    }

    /// <summary>
    /// Dopasowanie rozmiaru w przedziale 0–1. Pierwszy znak <c>iso_size_type</c> koduje długość
    /// kontenera (2 = 20 stóp, 4 = 40, L = 45), a nośność gniazda jest tu przybliżeniem jego
    /// wielkości fizycznej — magazyn nie prowadzi wymiarów gniazd w centymetrach.
    /// </summary>
    private static double SizeFit(string isoSizeType, Slot slot)
    {
        var lengthClass = isoSizeType.Length > 0 ? isoSizeType[0] : '4';
        var expectedKg = lengthClass switch
        {
            '2' => 24_000,
            '4' => 30_480,
            'L' => 34_000,
            _ => 30_480
        };

        var ratio = expectedKg / (double)Math.Max(slot.MaxWeightKg, 1);
        return ratio > 1 ? 0d : ratio;
    }
}

/// <summary>Polecenie przyjęcia kontenera do magazynu.</summary>
/// <param name="FacilityId">Obiekt z <c>freight.facilities</c>, prefiks <c>fac_</c>.</param>
/// <param name="ContainerId">Kontener, prefiks <c>cnt_</c>.</param>
/// <param name="ShipmentId">Przesyłka albo <see langword="null"/> dla pustego kontenera.</param>
/// <param name="GrossKg">Masa brutto.</param>
/// <param name="IsUnderCustomsControl">Czy towar czeka na <c>customs.declaration.cleared</c>.</param>
/// <param name="RegionCode">Region z §0.6, gdy nie ma przesyłki, z której dałoby się go wziąć.</param>
/// <param name="HazardRadiusBays">Promień sprawdzania separacji ADR w zatokach.</param>
/// <param name="AislesWithSameShipment">Alejki, w których stoją już kontenery tej przesyłki.</param>
public sealed record PutawayCommand(
    string FacilityId,
    string ContainerId,
    string? ShipmentId,
    int GrossKg,
    bool IsUnderCustomsControl,
    string RegionCode,
    int HazardRadiusBays,
    IReadOnlySet<short> AislesWithSameShipment);

/// <summary>Wynik przyjęcia.</summary>
/// <param name="Placement">Zapisane rozstawienie.</param>
/// <param name="Score">Punktacja wybranego gniazda; trafia do dziennika i na ekran dyspozytora.</param>
public sealed record PutawayResult(SlotPlacement Placement, double Score);

/// <summary>
/// Niepowodzenie przyjęcia z kodem przyczyny gotowym do wstawienia w kopertę błędu (§0.4).
/// </summary>
/// <param name="code">Kod w <c>snake_case</c>, np. <c>no_eligible_slot</c>.</param>
/// <param name="subject">Czego dotyczy — identyfikator kontenera, gniazda albo obiektu.</param>
public sealed class PutawayFailedException(string code, string subject)
    : InvalidOperationException($"{code}: {subject}")
{
    /// <summary>Kod przyczyny.</summary>
    public string Code { get; } = code;

    /// <summary>Podmiot, którego dotyczy odmowa.</summary>
    public string Subject { get; } = subject;
}

/// <summary>
/// Wytwórnia identyfikatorów w formacie z §0.1. Osobny interfejs, bo testy muszą móc
/// przewidzieć wygenerowany klucz, a produkcja potrzebuje ULID-a rosnącego w czasie.
/// </summary>
public interface IIdentifierFactory
{
    /// <summary>Zwraca nowy identyfikator z zadanym prefiksem.</summary>
    string NewId(string prefix);
}
