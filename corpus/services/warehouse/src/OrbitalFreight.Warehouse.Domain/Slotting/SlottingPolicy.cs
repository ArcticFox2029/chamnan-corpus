using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Slotting;

/// <summary>
/// Serce adresowania towaru: z listy wolnych gniazd wybiera to, w którym kontener ma stanąć.
/// Reguły twarde (nośność, zasilanie, koperta temperaturowa, separacja ADR, skład celny)
/// odrzucają gniazdo z jawnym kodem przyczyny, reguły miękkie tylko przesuwają je w rankingu.
/// Klasa jest czysta — nie dotyka bazy ani zegara, dlatego testy w
/// <c>tests/OrbitalFreight.Warehouse.Tests</c> mogą wołać ją wprost.
/// </summary>
public sealed class SlottingPolicy(SlottingWeights weights)
{
    private readonly SlottingWeights _weights = weights;

    /// <summary>
    /// Buduje ranking gniazd dla jednego kontenera.
    /// </summary>
    /// <param name="request">Kontener, jego ładunek i kontekst przesyłki.</param>
    /// <param name="candidates">Wolne gniazda wraz ze strefą i sąsiedztwem ADR.</param>
    /// <returns>
    /// Oceny wszystkich kandydatów, malejąco po punktacji. Gniazda odrzucone też są w wyniku —
    /// z <see cref="SlotScore.IsEligible"/> równym <see langword="false"/> — bo ekran dyspozytora
    /// pokazuje, dlaczego „oczywiste” miejsce zostało pominięte.
    /// </returns>
    public IReadOnlyList<SlotScore> Rank(SlottingRequest request, IReadOnlyList<SlotCandidate> candidates)
    {
        var scored = new List<SlotScore>(candidates.Count);

        foreach (var candidate in candidates)
        {
            var rejection = Reject(request, candidate);
            if (rejection is not null)
            {
                scored.Add(new SlotScore(candidate.Slot.SlotId, 0d, false, rejection));
                continue;
            }

            scored.Add(new SlotScore(candidate.Slot.SlotId, Score(request, candidate), true, null));
        }

        // Sortowanie stabilne po malejącej punktacji, a przy remisie po kodzie gniazda — dzięki temu
        // dwa przebiegi na tych samych danych dają tę samą rekomendację i da się ją odtworzyć z logu.
        return scored
            .OrderByDescending(s => s.Score)
            .ThenBy(s => s.SlotId, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>
    /// Zwraca pierwszy dopuszczalny wybór albo <see langword="null"/>, gdy żadne gniazdo nie przeszło
    /// reguł twardych. Warstwa aplikacji zamienia to <see langword="null"/> na kod błędu
    /// <c>no_eligible_slot</c> ze statusem 409.
    /// </summary>
    public SlotScore? Choose(SlottingRequest request, IReadOnlyList<SlotCandidate> candidates) =>
        Rank(request, candidates).FirstOrDefault(s => s.IsEligible);

    /// <summary>Reguły twarde. Zwraca kod przyczyny odrzucenia albo <see langword="null"/>.</summary>
    private static string? Reject(SlottingRequest request, SlotCandidate candidate)
    {
        var slot = candidate.Slot;

        if (!slot.IsUsable)
        {
            return slot.IsBlocked ? "slot_blocked" : "slot_retired";
        }

        if (request.GrossKg > slot.MaxWeightKg)
        {
            return "slot_capacity_exceeded";
        }

        if (request.RequiresPower && !slot.IsPowered)
        {
            return "power_required";
        }

        if (!candidate.Zone.AcceptsSetpoint(request.SetpointC))
        {
            return "temperature_envelope_mismatch";
        }

        // Towar pod dozorem celnym stoi w strefie 'bonded' do czasu, aż customs-service opublikuje
        // 'customs.declaration.cleared'. Konsument tego zdarzenia zdejmuje flagę i dopiero wtedy
        // kontener wolno przeadresować — sami nie pytamy customs-service o nic synchronicznie.
        if (request.IsUnderCustomsControl && candidate.Zone.Kind != ZoneKind.Bonded)
        {
            return "bonded_zone_required";
        }

        if (!request.IsUnderCustomsControl && candidate.Zone.Kind == ZoneKind.Bonded)
        {
            return "bonded_zone_reserved";
        }

        if (candidate.Zone.Kind == ZoneKind.Quarantine)
        {
            return "quarantine_zone";
        }

        if (request.HazardClassCode is { } hazard
            && HazardSegregation.ConflictsWithAny(hazard, candidate.NeighbourHazardClassCodes) is { } conflicting)
        {
            // Kod przyczyny jest stały, a szczegół (z czym konkretnie kolizja) idzie do logu i do
            // pola 'fields' koperty błędu — patrz §0.4.
            _ = conflicting;
            return "hazard_segregation_conflict";
        }

        if (!string.Equals(candidate.Zone.RegionCode, request.RegionCode, StringComparison.Ordinal))
        {
            // §7 pkt 7: region to rezydencja danych. Nie przekładamy ładunku z 'latam-br' na regał
            // opisany w innym regionie, nawet jeśli fizycznie stoją obok siebie.
            return "region_mismatch";
        }

        return null;
    }

    /// <summary>Reguły miękkie — im wyżej, tym lepszy adres.</summary>
    private double Score(SlottingRequest request, SlotCandidate candidate)
    {
        var slot = candidate.Slot;
        double score = 0d;

        // 1. Bliskość rampy wydań. Normalizujemy do najdłuższego marszu w hali, żeby waga
        //    zachowywała się tak samo w magazynie 60-metrowym i 400-metrowym.
        var travelRatio = candidate.MaxTravelCostM <= 0
            ? 0d
            : Math.Clamp(slot.TravelCostM / (double)candidate.MaxTravelCostM, 0d, 1d);
        score += _weights.Proximity * (1d - travelRatio) * request.UrgencyFactor;

        // 2. Ciężkie kontenery na posadzkę — regał wyżej to i ryzyko, i wolniejszy wózek.
        if (request.GrossKg > _weights.HeavyThresholdKg)
        {
            score += slot.Level == 0 ? _weights.GroundLevelForHeavy : -_weights.GroundLevelForHeavy;
        }

        // 3. Nie zajmujemy gniazd z zasilaniem towarem suchym, dopóki wolnych zasilanych jest mniej
        //    niż rezerwa OF_WAREHOUSE_REEFER_SLOT_RESERVE_PCT. Chłodnia przyjeżdża bez zapowiedzi.
        if (!request.RequiresPower && slot.IsPowered)
        {
            score -= candidate.PoweredSlotsFreeRatio < _weights.PoweredReserveRatio
                ? _weights.PoweredReservePenalty
                : _weights.PoweredReservePenalty / 4d;
        }

        // 4. Zwartość: trzymamy kontenery jednej przesyłki blisko siebie, bo cała fala kompletacji
        //    idzie potem po tej samej alejce. To najsilniejsza z reguł miękkich.
        if (candidate.SameShipmentInAisle)
        {
            score += _weights.ShipmentAffinity;
        }

        // 5. Dopasowanie rozmiaru gniazda do kontenera; luz 40-stopowca w gnieździe 45-stopowym
        //    to zmarnowana zatoka.
        score += _weights.SizeFit * candidate.SizeFitRatio;

        return score;
    }
}

/// <summary>
/// Wagi reguł miękkich. Ładowane z konfiguracji, żeby magazyn w Rotterdamie (wąskie alejki,
/// duża rotacja) i skład celny w Dubaju (mało ruchu, dużo separacji ADR) mogły mieć inne.
/// </summary>
/// <param name="Proximity">Waga bliskości rampy wydań.</param>
/// <param name="ShipmentAffinity">Premia za kontener tej samej przesyłki w alejce.</param>
/// <param name="SizeFit">Waga dopasowania rozmiaru.</param>
/// <param name="GroundLevelForHeavy">Premia/kara za poziom posadzki przy ciężkim ładunku.</param>
/// <param name="HeavyThresholdKg">Od ilu kilogramów ładunek uznajemy za ciężki.</param>
/// <param name="PoweredReserveRatio">Udział wolnych gniazd zasilanych, poniżej którego chronimy rezerwę.</param>
/// <param name="PoweredReservePenalty">Kara za zajęcie gniazda zasilanego towarem suchym.</param>
public sealed record SlottingWeights(
    double Proximity,
    double ShipmentAffinity,
    double SizeFit,
    double GroundLevelForHeavy,
    int HeavyThresholdKg,
    double PoweredReserveRatio,
    double PoweredReservePenalty)
{
    /// <summary>Ustawienia domyślne, wyznaczone na danych z magazynu w Hamburgu z I kwartału.</summary>
    public static SlottingWeights Default { get; } = new(
        Proximity: 4.0,
        ShipmentAffinity: 2.5,
        SizeFit: 1.5,
        GroundLevelForHeavy: 1.0,
        HeavyThresholdKg: 18_000,
        PoweredReserveRatio: 0.15,
        PoweredReservePenalty: 3.0);
}

/// <summary>Wejście decyzji adresowej dla jednego kontenera.</summary>
/// <param name="ContainerId">Kontener, prefiks <c>cnt_</c>.</param>
/// <param name="ShipmentId">Przesyłka, prefiks <c>shp_</c>; pusta dla kontenera pustego.</param>
/// <param name="GrossKg">Masa brutto z <c>freight.shipment_containers.gross_kg</c>.</param>
/// <param name="IsoSizeType">Typ ISO kontenera.</param>
/// <param name="RequiresPower">Wynik <c>freight.containers.is_reefer</c>.</param>
/// <param name="SetpointC">Zadana temperatura z <c>freight.containers.setpoint_c</c>.</param>
/// <param name="HazardClassCode">Wiodąca klasa ADR albo <see langword="null"/>.</param>
/// <param name="IsUnderCustomsControl">Czy przesyłka czeka na <c>customs.declaration.cleared</c>.</param>
/// <param name="RegionCode">Kod regionu przesyłki.</param>
/// <param name="UrgencyFactor">1,0 przy odległym SLA, rośnie do 2,0 przy terminie w ciągu doby.</param>
public sealed record SlottingRequest(
    string ContainerId,
    string? ShipmentId,
    int GrossKg,
    string IsoSizeType,
    bool RequiresPower,
    decimal? SetpointC,
    string? HazardClassCode,
    bool IsUnderCustomsControl,
    string RegionCode,
    double UrgencyFactor)
{
    /// <summary>
    /// Przelicza termin SLA na współczynnik pilności. Poniżej 24 godzin rośnie liniowo do 2,0;
    /// brak terminu to 1,0, bo przesyłka bez SLA nie ma prawa wypychać tej z terminem.
    /// </summary>
    public static double UrgencyFrom(DateTimeOffset? slaDeadlineAt, DateTimeOffset now)
    {
        if (slaDeadlineAt is null)
        {
            return 1.0;
        }

        var hoursLeft = (slaDeadlineAt.Value - now).TotalHours;
        return hoursLeft switch
        {
            <= 0 => 2.0,
            >= 24 => 1.0,
            _ => 1.0 + (24 - hoursLeft) / 24.0
        };
    }
}

/// <summary>Gniazdo wraz z kontekstem, którego sama tabela <c>warehouse.slots</c> nie zawiera.</summary>
/// <param name="Slot">Gniazdo.</param>
/// <param name="Zone">Strefa nadrzędna.</param>
/// <param name="NeighbourHazardClassCodes">Klasy ADR z sąsiednich zatok.</param>
/// <param name="MaxTravelCostM">Najdłuższy marsz w tej strefie — mianownik normalizacji.</param>
/// <param name="PoweredSlotsFreeRatio">Udział wolnych gniazd zasilanych w strefie.</param>
/// <param name="SameShipmentInAisle">Czy w alejce stoi już kontener tej samej przesyłki.</param>
/// <param name="SizeFitRatio">Dopasowanie rozmiaru w przedziale 0–1.</param>
public sealed record SlotCandidate(
    Slot Slot,
    WarehouseZone Zone,
    IReadOnlyList<string> NeighbourHazardClassCodes,
    int MaxTravelCostM,
    double PoweredSlotsFreeRatio,
    bool SameShipmentInAisle,
    double SizeFitRatio);

/// <summary>Wynik oceny jednego gniazda.</summary>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="Score">Punktacja reguł miękkich; bez znaczenia, gdy <paramref name="IsEligible"/> jest fałszem.</param>
/// <param name="IsEligible">Czy gniazdo przeszło reguły twarde.</param>
/// <param name="ReasonCode">Kod odrzucenia w <c>snake_case</c>.</param>
public sealed record SlotScore(string SlotId, double Score, bool IsEligible, string? ReasonCode);

/// <summary>
/// Tablica separacji ładunków niebezpiecznych. Grupy są uproszczone względem IMDG i celowo
/// bardziej restrykcyjne — magazyn nie jest ładownią statku i nie ma tu przegród.
/// </summary>
internal static class HazardSegregation
{
    // Klucz: klasa z freight.hazard_classes.hazard_class_code, wartość: klasy, których nie wolno
    // postawić w sąsiedniej zatoce. Relacja jest symetryczna i sprawdzana w obie strony.
    private static readonly IReadOnlyDictionary<string, string[]> Incompatible =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["1"] = ["2", "3", "4.1", "4.2", "4.3", "5.1", "5.2", "6.1", "8"],
            ["2"] = ["1", "3", "5.1"],
            ["3"] = ["1", "2", "5.1", "5.2", "8"],
            ["4.1"] = ["1", "5.1", "5.2"],
            ["4.2"] = ["1", "5.1", "5.2", "8"],
            ["4.3"] = ["1", "8"],
            ["5.1"] = ["1", "2", "3", "4.1", "4.2", "8"],
            ["5.2"] = ["1", "3", "4.1", "4.2"],
            ["6.1"] = ["1"],
            ["8"] = ["1", "3", "4.2", "4.3", "5.1"]
        };

    /// <summary>
    /// Zwraca pierwszą kolidującą klasę z sąsiedztwa albo <see langword="null"/>, gdy sąsiedztwo
    /// jest bezpieczne.
    /// </summary>
    public static string? ConflictsWithAny(string hazardClassCode, IReadOnlyList<string> neighbours)
    {
        if (neighbours.Count == 0)
        {
            return null;
        }

        Incompatible.TryGetValue(hazardClassCode, out var forbidden);

        foreach (var neighbour in neighbours)
        {
            if (forbidden is not null && Array.IndexOf(forbidden, neighbour) >= 0)
            {
                return neighbour;
            }

            if (Incompatible.TryGetValue(neighbour, out var reverse)
                && Array.IndexOf(reverse, hazardClassCode) >= 0)
            {
                return neighbour;
            }
        }

        return null;
    }
}
