using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Picking;

/// <summary>
/// Układa kolejność obejścia gniazd w jednej fali kompletacyjnej. Punktem startowym i końcowym
/// jest rampa wydań, więc problem to zwykły cykl komiwojażera na kilkudziesięciu punktach —
/// rozwiązywany serpentyną jako rozwiązaniem początkowym i domykany 2-opt, bo dokładny optimum
/// przy 40 gniazdach nie jest wart trzech sekund procesora na falę.
/// </summary>
public sealed class PickPathPlanner(PickPathSettings settings)
{
    private readonly PickPathSettings _settings = settings;

    /// <summary>
    /// Planuje trasę.
    /// </summary>
    /// <param name="stops">Przystanki fali; kolejność wejściowa jest bez znaczenia.</param>
    /// <returns>Trasa z policzonym dystansem i czasem przejścia.</returns>
    /// <exception cref="ArgumentException">Gdy lista przystanków jest pusta.</exception>
    public PickPath Plan(IReadOnlyList<PickStop> stops)
    {
        if (stops.Count == 0)
        {
            throw new ArgumentException("a pick wave needs at least one stop", nameof(stops));
        }

        if (stops.Count == 1)
        {
            var only = stops[0];
            var there = DistanceFromDock(only);
            return Build([only], there * 2);
        }

        var order = SerpentineSeed(stops);
        var improved = TwoOpt(order);
        return Build(improved, TourLength(improved));
    }

    /// <summary>
    /// Rozwiązanie początkowe: alejki po kolei, zatoki w alejce raz rosnąco, raz malejąco.
    /// Tak właśnie chodzi się po hali i taka trasa bywa lepsza od naiwnego najbliższego sąsiada,
    /// który potrafi zostawić jeden przystanek na końcu alejki i kazać po niego wracać.
    /// </summary>
    private static List<PickStop> SerpentineSeed(IReadOnlyList<PickStop> stops)
    {
        var byAisle = stops
            .GroupBy(s => s.Aisle)
            .OrderBy(g => g.Key)
            .ToList();

        var ordered = new List<PickStop>(stops.Count);
        var descending = false;

        foreach (var aisle in byAisle)
        {
            var within = descending
                ? aisle.OrderByDescending(s => s.Bay).ThenBy(s => s.Level)
                : aisle.OrderBy(s => s.Bay).ThenBy(s => s.Level);

            ordered.AddRange(within);
            descending = !descending;
        }

        return ordered;
    }

    /// <summary>
    /// Klasyczny 2-opt na trasie zamkniętej: odwracamy odcinek, jeśli skraca to sumę.
    /// Liczba przebiegów jest ograniczona (<c>OF_WAREHOUSE_TWO_OPT_ITERATIONS</c>), bo planer
    /// stoi na ścieżce żądania HTTP i nie ma prawa myśleć dłużej niż ułamek sekundy.
    /// </summary>
    private List<PickStop> TwoOpt(List<PickStop> route)
    {
        var best = new List<PickStop>(route);
        var bestLength = TourLength(best);

        for (var iteration = 0; iteration < _settings.TwoOptIterations; iteration++)
        {
            var improvedInPass = false;

            for (var i = 0; i < best.Count - 1; i++)
            {
                for (var k = i + 1; k < best.Count; k++)
                {
                    var candidate = Reverse(best, i, k);
                    var candidateLength = TourLength(candidate);

                    // Próg 1 metra: bez niego trasa „poprawia się” o zaokrąglenia i pętla kręci
                    // się aż do wyczerpania iteracji.
                    if (candidateLength + 1 < bestLength)
                    {
                        best = candidate;
                        bestLength = candidateLength;
                        improvedInPass = true;
                    }
                }
            }

            if (!improvedInPass)
            {
                break;
            }
        }

        return best;
    }

    private static List<PickStop> Reverse(List<PickStop> route, int from, int to)
    {
        var copy = new List<PickStop>(route);
        copy.Reverse(from, to - from + 1);
        return copy;
    }

    /// <summary>Długość trasy zamkniętej: rampa → przystanki → rampa.</summary>
    private int TourLength(IReadOnlyList<PickStop> route)
    {
        var total = DistanceFromDock(route[0]);

        for (var i = 1; i < route.Count; i++)
        {
            total += Distance(route[i - 1], route[i]);
        }

        return total + DistanceFromDock(route[^1]);
    }

    /// <summary>
    /// Odległość między dwoma gniazdami. Geometria hali jest prostokątna, więc metryka jest
    /// miejska: przejście alejką plus przejście poprzeczką między alejkami. Zmiana poziomu
    /// kosztuje osobno, bo to podniesienie masztu wózka, a nie marsz.
    /// </summary>
    private int Distance(PickStop a, PickStop b)
    {
        if (a.Aisle == b.Aisle)
        {
            return Math.Abs(a.Bay - b.Bay) * _settings.BaySpacingM
                 + Math.Abs(a.Level - b.Level) * _settings.LevelChangePenaltyM;
        }

        // Między alejkami idzie się poprzeczką na końcu hali, więc do rachunku wchodzą obie
        // odległości od poprzeczki, a nie różnica zatok.
        var crossAisle = Math.Abs(a.Aisle - b.Aisle) * _settings.AisleSpacingM;
        var toCross = Math.Min(a.Bay, _settings.BaysPerAisle - a.Bay) * _settings.BaySpacingM;
        var fromCross = Math.Min(b.Bay, _settings.BaysPerAisle - b.Bay) * _settings.BaySpacingM;

        return crossAisle + toCross + fromCross
             + Math.Abs(a.Level - b.Level) * _settings.LevelChangePenaltyM;
    }

    /// <summary>Odległość gniazda od rampy wydań; wartość zdenormalizowana w <c>warehouse.slots.travel_cost_m</c>.</summary>
    private static int DistanceFromDock(PickStop stop) => stop.TravelCostM;

    private PickPath Build(IReadOnlyList<PickStop> ordered, int totalDistanceM)
    {
        var legs = new List<PickPathLeg>(ordered.Count);
        var previous = (PickStop?)null;

        for (var i = 0; i < ordered.Count; i++)
        {
            var stop = ordered[i];
            var legDistance = previous is null ? DistanceFromDock(stop) : Distance(previous, stop);
            legs.Add(new PickPathLeg((short)(i + 1), stop, legDistance));
            previous = stop;
        }

        var walkSeconds = totalDistanceM / _settings.TravelSpeedMps;
        var handlingSeconds = ordered.Count * _settings.HandlingSecondsPerStop;

        return new PickPath(legs, totalDistanceM, (int)Math.Round(walkSeconds + handlingSeconds));
    }
}

/// <summary>
/// Parametry geometrii hali i tempa pracy. Wszystkie odległości w metrach (§0.2), prędkość
/// w metrach na sekundę — jednostek nie mieszamy nawet w polach konfiguracyjnych.
/// </summary>
/// <param name="AisleSpacingM">Rozstaw alejek.</param>
/// <param name="BaySpacingM">Rozstaw zatok wzdłuż alejki.</param>
/// <param name="BaysPerAisle">Liczba zatok w alejce; potrzebna do wyboru bliższej poprzeczki.</param>
/// <param name="LevelChangePenaltyM">Umowny koszt zmiany poziomu regału wyrażony w metrach marszu.</param>
/// <param name="TravelSpeedMps">Prędkość wózka z ładunkiem.</param>
/// <param name="HandlingSecondsPerStop">Czas samego podjęcia kontenera i potwierdzenia skanem.</param>
/// <param name="TwoOptIterations">Górna granica przebiegów 2-opt.</param>
public sealed record PickPathSettings(
    int AisleSpacingM,
    int BaySpacingM,
    int BaysPerAisle,
    int LevelChangePenaltyM,
    double TravelSpeedMps,
    int HandlingSecondsPerStop,
    int TwoOptIterations)
{
    /// <summary>Wartości domyślne dla hali regałowej o standardowym rozstawie.</summary>
    public static PickPathSettings Default { get; } = new(
        AisleSpacingM: 12,
        BaySpacingM: 3,
        BaysPerAisle: 40,
        LevelChangePenaltyM: 6,
        TravelSpeedMps: 1.4,
        HandlingSecondsPerStop: 75,
        TwoOptIterations: 12);
}

/// <summary>Jeden przystanek trasy — gniazdo plus to, po co się do niego idzie.</summary>
/// <param name="SlotId">Gniazdo, prefiks <c>slt_</c>.</param>
/// <param name="ContainerId">Kontener do zabrania, prefiks <c>cnt_</c>.</param>
/// <param name="ShipmentId">Przesyłka, prefiks <c>shp_</c>.</param>
/// <param name="Aisle">Alejka.</param>
/// <param name="Bay">Zatoka.</param>
/// <param name="Level">Poziom regału.</param>
/// <param name="TravelCostM">Odległość gniazda od rampy wydań.</param>
public sealed record PickStop(
    string SlotId,
    string ContainerId,
    string ShipmentId,
    short Aisle,
    short Bay,
    short Level,
    int TravelCostM);

/// <summary>Odcinek trasy: od poprzedniego przystanku (albo od rampy) do bieżącego.</summary>
/// <param name="SeqNo">Numer kolejny od 1; trafia wprost do <c>warehouse.pick_tasks.seq_no</c>.</param>
/// <param name="Stop">Przystanek.</param>
/// <param name="DistanceM">Długość odcinka.</param>
public sealed record PickPathLeg(short SeqNo, PickStop Stop, int DistanceM);

/// <summary>Gotowa trasa fali.</summary>
/// <param name="Legs">Odcinki w kolejności przejścia.</param>
/// <param name="TotalDistanceM">Suma odcinków wraz z powrotem na rampę.</param>
/// <param name="EstimatedSeconds">Szacowany czas: marsz plus obsługa przystanków.</param>
public sealed record PickPath(IReadOnlyList<PickPathLeg> Legs, int TotalDistanceM, int EstimatedSeconds);
