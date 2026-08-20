using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.CycleCounting;
using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Application.CycleCounting;

/// <summary>
/// Obsługuje inwentaryzację ciągłą: układa plan na dzień roboczy, przyjmuje wyniki liczenia
/// z terminali i otwiera rozbieżności. Każda rozbieżność jest zdarzeniem księgowym, więc trafia
/// do <c>platform.audit_ledger_entries</c> przez audit-ledger, zanim ktokolwiek zobaczy ją
/// na ekranie.
/// </summary>
/// <param name="counts">Repozytorium planów, liczeń i rozbieżności.</param>
/// <param name="slots">Repozytorium gniazd.</param>
/// <param name="utilisation">Port do analytics-pipeline (klasyfikacja ABC).</param>
/// <param name="ledger">Port do audit-ledger.</param>
/// <param name="documents">Port do document-service.</param>
/// <param name="outbox">Skrzynka nadawcza.</param>
/// <param name="uow">Granica transakcji.</param>
/// <param name="scheduler">Reguły doboru gniazd.</param>
/// <param name="ids">Wytwórnia identyfikatorów.</param>
/// <param name="clock">Zegar.</param>
/// <param name="logger">Dziennik.</param>
public sealed class CycleCountService(
    ICycleCountRepository counts,
    ISlotRepository slots,
    IUtilisationSnapshotPort utilisation,
    IAuditLedgerPort ledger,
    IDocumentPort documents,
    IOutboxWriter outbox,
    IWarehouseUnitOfWork uow,
    CycleCountScheduler scheduler,
    IIdentifierFactory ids,
    TimeProvider clock,
    ILogger<CycleCountService> logger)
{
    private readonly ICycleCountRepository _counts = counts;
    private readonly ISlotRepository _slots = slots;
    private readonly IUtilisationSnapshotPort _utilisation = utilisation;
    private readonly IAuditLedgerPort _ledger = ledger;
    private readonly IDocumentPort _documents = documents;
    private readonly IOutboxWriter _outbox = outbox;
    private readonly IWarehouseUnitOfWork _uow = uow;
    private readonly CycleCountScheduler _scheduler = scheduler;
    private readonly IIdentifierFactory _ids = ids;
    private readonly TimeProvider _clock = clock;
    private readonly ILogger<CycleCountService> _logger = logger;

    /// <summary>
    /// Układa plan liczenia na wskazany dzień.
    /// </summary>
    /// <param name="command">Polecenie planowania.</param>
    /// <param name="ct">Token anulowania.</param>
    /// <returns>Plan wraz z listą liczeń do wykonania.</returns>
    public async Task<CycleCountPlan> CreatePlanAsync(CreateCountPlanCommand command, CancellationToken ct)
    {
        var occupied = await LoadOccupiedSlotsAsync(command.FacilityId, ct);

        if (occupied.Count == 0)
        {
            throw new CycleCountFailedException("facility_empty", command.FacilityId);
        }

        // Awaria analytics-pipeline nie zatrzymuje inwentaryzacji — degradujemy plan do próby
        // losowej, bo policzone 60 losowych gniazd jest warte więcej niż nie policzone nic.
        IReadOnlyDictionary<string, int> trips;
        var method = command.Method;

        try
        {
            trips = await _utilisation.GetWeeklyTripsAsync(
                command.TenantId,
                WeekStartOf(command.ScheduledOn),
                ct);
        }
        catch (HttpRequestException ex)
        {
            _logger.LogWarning(ex, "analytics-pipeline unavailable, falling back to random sampling");
            trips = new Dictionary<string, int>(StringComparer.Ordinal);
            method = method == CycleCountMethod.Abc ? CycleCountMethod.Random : method;
        }

        var recentVariances = (await _counts.GetSlotsWithRecentVariancesAsync(
            command.FacilityId,
            command.VarianceLookbackDays,
            ct)).ToHashSet(StringComparer.Ordinal);

        var selected = _scheduler.BuildPlan(occupied, trips, recentVariances, method, command.Seed);

        if (selected.Count == 0)
        {
            throw new CycleCountFailedException("no_slots_selected", command.FacilityId);
        }

        var planId = _ids.NewId(PrefixedId.CountPlan);
        var now = _clock.GetUtcNow();

        var plan = new CycleCountPlan(
            planId,
            command.FacilityId,
            command.TenantId,
            method,
            command.ScheduledOn,
            selected.Count,
            now,
            ClosedAt: null);

        var tasks = selected
            .Select(candidate => new CycleCountTask(
                _ids.NewId(PrefixedId.CountTask),
                planId,
                candidate.SlotId,
                candidate.ContainerId,
                ObservedContainerId: null,
                CountedByUserId: null,
                CountedAt: null))
            .ToList();

        await _counts.AddPlanAsync(plan, tasks, ct);

        _logger.LogInformation(
            "cycle count plan {PlanId} for {FacilityId} on {ScheduledOn}: {SlotCount} slots, method {Method}",
            planId,
            command.FacilityId,
            command.ScheduledOn,
            tasks.Count,
            method);

        return plan;
    }

    /// <summary>
    /// Przyjmuje wynik liczenia jednego gniazda i — gdy trzeba — otwiera rozbieżność.
    /// </summary>
    /// <param name="command">Wynik z terminala.</param>
    /// <param name="ct">Token anulowania.</param>
    /// <returns>Otwarta rozbieżność albo <see langword="null"/>, gdy stan się zgadza.</returns>
    public async Task<CountVariance?> SubmitCountAsync(SubmitCountCommand command, CancellationToken ct)
    {
        var count = await _counts.FindCountAsync(command.CountId, ct)
            ?? throw new CycleCountFailedException("count_not_found", command.CountId);

        if (count.CountedAt is not null)
        {
            // Przy inwentaryzacji obowiązuje pierwszy odczyt. Powtórka z terminala nie nadpisuje
            // wyniku, tylko kończy się bezgłośnie — poprawkę robi się ponownym liczeniem w ciemno.
            _logger.LogInformation("count {CountId} was already recorded, ignoring resubmission", command.CountId);
            return null;
        }

        var observedElsewhere = command.ObservedContainerId is not null
            && await _slots.FindActivePlacementByContainerAsync(command.ObservedContainerId, ct) is { } elsewhere
            && !string.Equals(elsewhere.SlotId, count.SlotId, StringComparison.Ordinal);

        var kind = CycleCountScheduler.Evaluate(
            count.ExpectedContainerId,
            command.ObservedContainerId,
            observedElsewhere,
            command.DamageReported,
            command.SealMatches);

        await _counts.RecordCountAsync(
            command.CountId,
            command.ObservedContainerId,
            command.CountedByUserId,
            command.CountedAt,
            ct);

        if (kind is null)
        {
            return null;
        }

        var varianceId = _ids.NewId(PrefixedId.Variance);
        var now = _clock.GetUtcNow();

        // Wpis w rejestrze powstaje przed zapisem rozbieżności: gdyby audit-ledger był
        // nieosiągalny, wolimy nie mieć rozbieżności w bazie niż mieć ją bez śladu w rejestrze.
        var entryId = await _ledger.AppendAsync(
            "warehouse_slot",
            count.SlotId,
            "inventory_variance_opened",
            command.CountedByUserId,
            new Dictionary<string, object?>
            {
                ["variance_id"] = varianceId,
                ["count_id"] = command.CountId,
                ["kind"] = kind.Value.ToString().ToLowerInvariant(),
                ["expected_container_id"] = count.ExpectedContainerId,
                ["observed_container_id"] = command.ObservedContainerId
            },
            ct);

        string? documentId = null;
        if (command.EvidencePhoto is { Length: > 0 } photo)
        {
            documentId = await _documents.UploadAsync(
                "warehouse_count_variance",
                varianceId,
                "damage_photo",
                "image/jpeg",
                photo,
                ct);
        }

        var variance = new CountVariance(
            varianceId,
            command.CountId,
            count.SlotId,
            kind.Value,
            count.ExpectedContainerId,
            command.ObservedContainerId,
            documentId,
            entryId,
            now,
            ResolvedAt: null,
            ResolutionNote: null);

        await using var tx = await _uow.BeginAsync(ct);

        await _counts.AddVarianceAsync(variance, ct);
        await _slots.SetSlotBlockedAsync(count.SlotId, isBlocked: true, "open_variance", ct);
        await _outbox.EnqueueAsync(
            "warehouse.count_variance.opened",
            "of.platform.v1",
            count.SlotId,
            new Dictionary<string, object?>
            {
                ["variance_id"] = varianceId,
                ["count_id"] = command.CountId,
                ["slot_id"] = count.SlotId,
                ["kind"] = kind.Value.ToString().ToLowerInvariant(),
                ["expected_container_id"] = count.ExpectedContainerId,
                ["observed_container_id"] = command.ObservedContainerId,
                ["evidence_document_id"] = documentId,
                ["ledger_entry_id"] = entryId,
                ["opened_at"] = now
            },
            ct);

        await _uow.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);

        _logger.LogWarning(
            "variance {VarianceId} of kind {Kind} opened on slot {SlotId}",
            varianceId,
            kind,
            count.SlotId);

        return variance;
    }

    /// <summary>
    /// Zamyka rozbieżność notatką, odblokowuje gniazdo i dopisuje wpis kompensujący do rejestru.
    /// </summary>
    public async Task ResolveVarianceAsync(
        string varianceId,
        string slotId,
        string note,
        string resolvedByUserId,
        CancellationToken ct)
    {
        var now = _clock.GetUtcNow();

        await _ledger.AppendAsync(
            "warehouse_slot",
            slotId,
            "inventory_variance_resolved",
            resolvedByUserId,
            new Dictionary<string, object?>
            {
                ["variance_id"] = varianceId,
                ["note"] = note
            },
            ct);

        await _counts.ResolveVarianceAsync(varianceId, note, now, ct);
        await _slots.SetSlotBlockedAsync(slotId, isBlocked: false, reason: null, ct);
    }

    /// <summary>Zajęte gniazda obiektu w postaci wymaganej przez planistę.</summary>
    private async Task<IReadOnlyList<OccupiedSlot>> LoadOccupiedSlotsAsync(string facilityId, CancellationToken ct)
    {
        var zones = await _slots.GetZonesAsync(facilityId, ct);
        var occupied = new List<OccupiedSlot>();

        foreach (var zone in zones)
        {
            var page = await _slots.ListSlotsAsync(facilityId, cursor: null, limit: 200, ct);

            foreach (var slot in page.Items.Where(s => s.ZoneId == zone.ZoneId))
            {
                var placement = await _slots.GetActivePlacementAsync(slot.SlotId, ct);
                if (placement is not null)
                {
                    occupied.Add(new OccupiedSlot(slot.SlotId, placement.ContainerId, slot.Aisle, slot.Bay, slot.Level));
                }
            }
        }

        return occupied;
    }

    /// <summary>Poniedziałek tygodnia, w którym leży data — widok tygodniowy jest liczony od poniedziałku.</summary>
    private static DateOnly WeekStartOf(DateOnly date)
    {
        var offset = ((int)date.DayOfWeek + 6) % 7;
        return date.AddDays(-offset);
    }
}

/// <summary>Polecenie ułożenia planu inwentaryzacji.</summary>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="TenantId">Najemca.</param>
/// <param name="ScheduledOn">Dzień roboczy planu.</param>
/// <param name="Method">Metoda doboru gniazd.</param>
/// <param name="VarianceLookbackDays">Okno historii rozbieżności.</param>
/// <param name="Seed">Ziarno losowania; zapisywane, żeby plan dało się odtworzyć.</param>
public sealed record CreateCountPlanCommand(
    string FacilityId,
    string TenantId,
    DateOnly ScheduledOn,
    CycleCountMethod Method,
    int VarianceLookbackDays,
    int Seed);

/// <summary>Wynik liczenia jednego gniazda przysłany z terminala.</summary>
/// <param name="CountId">Liczenie, prefiks <c>cct_</c>.</param>
/// <param name="ObservedContainerId">Kontener zastany; <see langword="null"/> = gniazdo puste.</param>
/// <param name="CountedByUserId">Magazynier.</param>
/// <param name="CountedAt">Czas liczenia z terminala.</param>
/// <param name="DamageReported">Czy zgłoszono uszkodzenie.</param>
/// <param name="SealMatches">Czy plomba zgadza się z ewidencją.</param>
/// <param name="EvidencePhoto">Zdjęcie dowodowe; trafia do document-service.</param>
public sealed record SubmitCountCommand(
    string CountId,
    string? ObservedContainerId,
    string CountedByUserId,
    DateTimeOffset CountedAt,
    bool DamageReported,
    bool SealMatches,
    ReadOnlyMemory<byte> EvidencePhoto);

/// <summary>Niepowodzenie operacji inwentaryzacyjnej.</summary>
/// <param name="code">Kod w <c>snake_case</c>.</param>
/// <param name="subject">Podmiot odmowy.</param>
public sealed class CycleCountFailedException(string code, string subject)
    : InvalidOperationException($"{code}: {subject}")
{
    /// <summary>Kod przyczyny.</summary>
    public string Code { get; } = code;

    /// <summary>Podmiot.</summary>
    public string Subject { get; } = subject;
}
