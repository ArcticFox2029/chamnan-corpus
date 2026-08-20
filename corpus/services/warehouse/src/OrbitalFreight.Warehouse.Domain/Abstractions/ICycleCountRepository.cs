using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Abstractions;

/// <summary>
/// Dostęp do <c>warehouse.cycle_count_plans</c>, <c>warehouse.cycle_count_tasks</c> i
/// <c>warehouse.count_variances</c>. Wyniki liczenia są dopisywane raz i nie podlegają edycji —
/// poprawka to nowe liczenie metodą <see cref="CycleCountMethod.BlindRecount"/>.
/// </summary>
public interface ICycleCountRepository
{
    /// <summary>Zapisuje plan wraz z wylosowanymi lub wybranymi gniazdami.</summary>
    Task AddPlanAsync(CycleCountPlan plan, IReadOnlyList<CycleCountTask> tasks, CancellationToken ct);

    /// <summary>Plan po kluczu.</summary>
    Task<CycleCountPlan?> FindPlanAsync(string planId, CancellationToken ct);

    /// <summary>Liczenie po kluczu.</summary>
    Task<CycleCountTask?> FindCountAsync(string countId, CancellationToken ct);

    /// <summary>Nierozliczone liczenia planu, w kolejności trasy po hali.</summary>
    Task<IReadOnlyList<CycleCountTask>> GetPendingCountsAsync(string planId, CancellationToken ct);

    /// <summary>Zapisuje wynik liczenia jednego gniazda.</summary>
    /// <param name="countId">Liczenie, prefiks <c>cct_</c>.</param>
    /// <param name="observedContainerId">Kontener zastany; <see langword="null"/> = gniazdo puste.</param>
    /// <param name="countedByUserId">Magazynier, prefiks <c>usr_</c>.</param>
    /// <param name="countedAt">Czas liczenia z terminala (może być starszy niż zapis, gdy terminal był offline).</param>
    /// <param name="ct">Token anulowania.</param>
    Task RecordCountAsync(
        string countId,
        string? observedContainerId,
        string countedByUserId,
        DateTimeOffset countedAt,
        CancellationToken ct);

    /// <summary>Dopisuje rozbieżność.</summary>
    Task AddVarianceAsync(CountVariance variance, CancellationToken ct);

    /// <summary>
    /// Uzupełnia rozbieżność o numer wpisu zwrócony przez <c>audit.v1.LedgerService/Append</c>
    /// oraz o identyfikator zdjęcia z document-service.
    /// </summary>
    Task AttachEvidenceAsync(string varianceId, string? documentId, long? ledgerEntryId, CancellationToken ct);

    /// <summary>Otwarte rozbieżności obiektu — źródło ekranu „do wyjaśnienia”.</summary>
    Task<CursorPage<CountVariance>> ListOpenVariancesAsync(
        string facilityId,
        string? cursor,
        int limit,
        CancellationToken ct);

    /// <summary>Zamyka rozbieżność notatką; wiersz zostaje, zmienia się tylko <c>resolved_at</c>.</summary>
    Task ResolveVarianceAsync(string varianceId, string note, DateTimeOffset resolvedAt, CancellationToken ct);

    /// <summary>
    /// Gniazda, na których w ostatnich <paramref name="lookbackDays"/> dniach powstała rozbieżność.
    /// Karmi metodę <see cref="CycleCountMethod.VarianceDriven"/>.
    /// </summary>
    Task<IReadOnlyList<string>> GetSlotsWithRecentVariancesAsync(
        string facilityId,
        int lookbackDays,
        CancellationToken ct);
}
