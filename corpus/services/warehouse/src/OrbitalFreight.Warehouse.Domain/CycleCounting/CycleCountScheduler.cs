using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.CycleCounting;

/// <summary>
/// Wybiera gniazda do policzenia na dany dzień roboczy. Inwentaryzacja ciągła zastępuje u nas
/// remanent roczny, więc plan musi trafiać w gniazda o największym ryzyku pomyłki, a nie
/// w losowy przekrój hali: klasa A z rotacji (<c>analytics.mv_container_utilisation_weekly</c>
/// podawany przez analytics-pipeline), gniazda z historią rozbieżności i próba kontrolna.
/// </summary>
public sealed class CycleCountScheduler(CycleCountSettings settings)
{
    private readonly CycleCountSettings _settings = settings;

    /// <summary>
    /// Buduje listę gniazd do policzenia.
    /// </summary>
    /// <param name="occupiedSlots">Gniazda zajęte na chwilę planowania wraz z kontenerem.</param>
    /// <param name="weeklyTrips">Rotacja kontenerów; brak wpisu oznacza klasę C.</param>
    /// <param name="slotsWithRecentVariances">Gniazda z rozbieżnością w oknie <c>OF_WAREHOUSE_VARIANCE_LOOKBACK_DAYS</c>.</param>
    /// <param name="method">Metoda planu.</param>
    /// <param name="seed">Ziarno losowania; zapisywane w logu, żeby plan dało się odtworzyć.</param>
    /// <returns>Gniazda w kolejności obejścia hali, przycięte do dziennego limitu.</returns>
    public IReadOnlyList<CountCandidate> BuildPlan(
        IReadOnlyList<OccupiedSlot> occupiedSlots,
        IReadOnlyDictionary<string, int> weeklyTrips,
        IReadOnlySet<string> slotsWithRecentVariances,
        CycleCountMethod method,
        int seed)
    {
        var random = new Random(seed);

        var candidates = occupiedSlots
            .Select(slot => new CountCandidate(
                slot.SlotId,
                slot.ContainerId,
                Classify(slot.ContainerId, weeklyTrips),
                slotsWithRecentVariances.Contains(slot.SlotId),
                slot.Aisle,
                slot.Bay,
                slot.Level))
            .ToList();

        var selected = method switch
        {
            CycleCountMethod.Abc => SelectByAbc(candidates, random),
            CycleCountMethod.VarianceDriven => candidates.Where(c => c.HasRecentVariance).ToList(),
            CycleCountMethod.Random => Shuffle(candidates, random),
            CycleCountMethod.BlindRecount => candidates.Where(c => c.HasRecentVariance).ToList(),
            _ => throw new ArgumentOutOfRangeException(nameof(method), method, "unknown cycle count method")
        };

        // Kolejność obejścia jest serpentyną tak samo jak przy kompletacji — magazynier liczący
        // gniazda idzie halą dokładnie tą samą drogą co przy zbieraniu towaru.
        return selected
            .Take(_settings.MaxSlotsPerDay)
            .OrderBy(c => c.Aisle)
            .ThenBy(c => c.Aisle % 2 == 0 ? c.Bay : short.MaxValue - c.Bay)
            .ThenBy(c => c.Level)
            .ToList();
    }

    /// <summary>
    /// Klasyfikacja ABC po liczbie przewozów w tygodniu. Progi są udziałami, nie liczbami
    /// bezwzględnymi — magazyn sezonowy inaczej wyglądałby w lipcu, a inaczej w styczniu.
    /// </summary>
    private AbcClass Classify(string containerId, IReadOnlyDictionary<string, int> weeklyTrips)
    {
        if (!weeklyTrips.TryGetValue(containerId, out var trips))
        {
            return AbcClass.C;
        }

        if (trips >= _settings.ClassATripThreshold)
        {
            return AbcClass.A;
        }

        return trips >= _settings.ClassBTripThreshold ? AbcClass.B : AbcClass.C;
    }

    /// <summary>
    /// Dobór proporcjonalny: klasa A liczona najczęściej, C najrzadziej, a gniazda z historią
    /// rozbieżności wchodzą do planu zawsze, niezależnie od klasy.
    /// </summary>
    private List<CountCandidate> SelectByAbc(List<CountCandidate> candidates, Random random)
    {
        var forced = candidates.Where(c => c.HasRecentVariance).ToList();
        var remaining = _settings.MaxSlotsPerDay - forced.Count;

        if (remaining <= 0)
        {
            return forced;
        }

        var quotaA = (int)Math.Round(remaining * _settings.ShareOfClassA);
        var quotaB = (int)Math.Round(remaining * _settings.ShareOfClassB);
        var quotaC = Math.Max(0, remaining - quotaA - quotaB);

        var pool = candidates.Except(forced).ToList();
        var plan = new List<CountCandidate>(forced);

        plan.AddRange(TakeFromClass(pool, AbcClass.A, quotaA, random));
        plan.AddRange(TakeFromClass(pool, AbcClass.B, quotaB, random));
        plan.AddRange(TakeFromClass(pool, AbcClass.C, quotaC, random));

        return plan;
    }

    private static IEnumerable<CountCandidate> TakeFromClass(
        List<CountCandidate> pool,
        AbcClass abcClass,
        int quota,
        Random random)
    {
        if (quota <= 0)
        {
            return [];
        }

        return pool
            .Where(c => c.Class == abcClass)
            .OrderBy(_ => random.Next())
            .Take(quota);
    }

    private static List<CountCandidate> Shuffle(List<CountCandidate> candidates, Random random) =>
        candidates.OrderBy(_ => random.Next()).ToList();

    /// <summary>
    /// Ocenia wynik liczenia. Zwraca rodzaj rozbieżności albo <see langword="null"/>, gdy stan
    /// się zgadza — logika jest tu, a nie w warstwie HTTP, bo ten sam osąd stosuje konsument
    /// zdarzenia <c>shipment.scanned</c> przy skanie typu <c>seal_check</c>.
    /// </summary>
    /// <param name="expectedContainerId">Kontener z ewidencji.</param>
    /// <param name="observedContainerId">Kontener zastany; <see langword="null"/> = gniazdo puste.</param>
    /// <param name="observedElsewhere">Czy zastany kontener figuruje w ewidencji w innym gnieździe.</param>
    /// <param name="damageReported">Czy magazynier zgłosił uszkodzenie.</param>
    /// <param name="sealMatches">Czy numer plomby zgadza się z <c>freight.shipment_containers.seal_number</c>.</param>
    public static VarianceKind? Evaluate(
        string? expectedContainerId,
        string? observedContainerId,
        bool observedElsewhere,
        bool damageReported,
        bool sealMatches)
    {
        if (damageReported)
        {
            return VarianceKind.Damaged;
        }

        if (!sealMatches && observedContainerId is not null)
        {
            return VarianceKind.SealMismatch;
        }

        if (expectedContainerId is null && observedContainerId is null)
        {
            return null;
        }

        if (expectedContainerId is null)
        {
            return VarianceKind.Unexpected;
        }

        if (observedContainerId is null)
        {
            return VarianceKind.Missing;
        }

        if (string.Equals(expectedContainerId, observedContainerId, StringComparison.Ordinal))
        {
            return null;
        }

        return observedElsewhere ? VarianceKind.WrongSlot : VarianceKind.Unexpected;
    }
}

/// <summary>Klasa rotacji.</summary>
public enum AbcClass
{
    /// <summary>Najwyższa rotacja, największe ryzyko pomyłki.</summary>
    A,

    /// <summary>Rotacja średnia.</summary>
    B,

    /// <summary>Towar leżakujący.</summary>
    C
}

/// <summary>Zajęte gniazdo w postaci, jakiej potrzebuje planista inwentaryzacji.</summary>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="ContainerId">Kontener stojący w gnieździe.</param>
/// <param name="Aisle">Alejka.</param>
/// <param name="Bay">Zatoka.</param>
/// <param name="Level">Poziom.</param>
public sealed record OccupiedSlot(string SlotId, string ContainerId, short Aisle, short Bay, short Level);

/// <summary>Gniazdo wytypowane do policzenia.</summary>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="ContainerId">Kontener oczekiwany.</param>
/// <param name="Class">Klasa rotacji.</param>
/// <param name="HasRecentVariance">Czy gniazdo miało niedawno rozbieżność.</param>
/// <param name="Aisle">Alejka.</param>
/// <param name="Bay">Zatoka.</param>
/// <param name="Level">Poziom.</param>
public sealed record CountCandidate(
    string SlotId,
    string ContainerId,
    AbcClass Class,
    bool HasRecentVariance,
    short Aisle,
    short Bay,
    short Level);

/// <summary>Nastawy planisty inwentaryzacji, wiązane ze zmiennych <c>OF_WAREHOUSE_*</c>.</summary>
/// <param name="MaxSlotsPerDay">Ile gniazd zmieści się w dniu roboczym jednej zmiany.</param>
/// <param name="ShareOfClassA">Udział klasy A w planie.</param>
/// <param name="ShareOfClassB">Udział klasy B.</param>
/// <param name="ClassATripThreshold">Od ilu przewozów tygodniowo kontener jest klasy A.</param>
/// <param name="ClassBTripThreshold">Od ilu przewozów jest klasy B.</param>
public sealed record CycleCountSettings(
    int MaxSlotsPerDay,
    double ShareOfClassA,
    double ShareOfClassB,
    int ClassATripThreshold,
    int ClassBTripThreshold)
{
    /// <summary>Nastawy domyślne: 60 gniazd na zmianę, połowa planu z klasy A.</summary>
    public static CycleCountSettings Default { get; } = new(
        MaxSlotsPerDay: 60,
        ShareOfClassA: 0.5,
        ShareOfClassB: 0.3,
        ClassATripThreshold: 3,
        ClassBTripThreshold: 1);
}
