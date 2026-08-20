using Microsoft.EntityFrameworkCore;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Repositories;

/// <summary>
/// Implementacja <see cref="ICycleCountRepository"/>. Wyniki liczenia zapisujemy warunkowo
/// (<c>counted_at IS NULL</c>), żeby ponowne wysłanie tego samego formularza z terminala nie
/// nadpisało pierwszego wyniku — przy inwentaryzacji liczy się pierwszy odczyt, nie ostatni.
/// </summary>
/// <param name="db">Kontekst schematu <c>warehouse</c>.</param>
public sealed class CycleCountRepository(WarehouseDbContext db) : ICycleCountRepository
{
    private readonly WarehouseDbContext _db = db;

    /// <inheritdoc />
    public async Task AddPlanAsync(CycleCountPlan plan, IReadOnlyList<CycleCountTask> tasks, CancellationToken ct)
    {
        _db.CycleCountPlans.Add(new CycleCountPlanEntity
        {
            PlanId = plan.PlanId,
            FacilityId = plan.FacilityId,
            TenantId = plan.TenantId,
            Method = EnumNames.FromMethod(plan.Method),
            ScheduledOn = plan.ScheduledOn,
            Seed = HashCode.Combine(plan.PlanId),
            SlotCount = plan.SlotCount,
            CreatedAt = plan.CreatedAt,
            ClosedAt = plan.ClosedAt,
            Counts = tasks.Select(t => new CycleCountTaskEntity
            {
                CountId = t.CountId,
                PlanId = t.PlanId,
                SlotId = t.SlotId,
                ExpectedContainerId = t.ExpectedContainerId,
                ObservedContainerId = t.ObservedContainerId,
                CountedByUserId = t.CountedByUserId,
                CountedAt = t.CountedAt
            }).ToList()
        });

        await _db.SaveChangesAsync(ct);
    }

    /// <inheritdoc />
    public async Task<CycleCountPlan?> FindPlanAsync(string planId, CancellationToken ct)
    {
        var row = await _db.CycleCountPlans.AsNoTracking().FirstOrDefaultAsync(p => p.PlanId == planId, ct);
        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<CycleCountTask?> FindCountAsync(string countId, CancellationToken ct)
    {
        var row = await _db.CycleCounts.AsNoTracking().FirstOrDefaultAsync(c => c.CountId == countId, ct);
        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<CycleCountTask>> GetPendingCountsAsync(string planId, CancellationToken ct)
    {
        var rows = await _db.CycleCounts
            .AsNoTracking()
            .Join(_db.Slots, c => c.SlotId, s => s.SlotId, (c, s) => new { Count = c, Slot = s })
            .Where(x => x.Count.PlanId == planId && x.Count.CountedAt == null)
            .OrderBy(x => x.Slot.Aisle)
            .ThenBy(x => x.Slot.Bay)
            .ThenBy(x => x.Slot.Level)
            .Select(x => x.Count)
            .ToListAsync(ct);

        return rows.Select(Map).ToList();
    }

    /// <inheritdoc />
    public async Task RecordCountAsync(
        string countId,
        string? observedContainerId,
        string countedByUserId,
        DateTimeOffset countedAt,
        CancellationToken ct)
    {
        await _db.CycleCounts
            .Where(c => c.CountId == countId && c.CountedAt == null)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(c => c.ObservedContainerId, observedContainerId)
                .SetProperty(c => c.CountedByUserId, countedByUserId)
                .SetProperty(c => c.CountedAt, countedAt)
                .SetProperty(c => c.RecordedAt, DateTimeOffset.UtcNow), ct);
    }

    /// <inheritdoc />
    public async Task AddVarianceAsync(CountVariance variance, CancellationToken ct)
    {
        // facility_id jest zdenormalizowany, więc pobieramy go po drodze przez gniazdo i strefę.
        var facilityId = await _db.Slots
            .AsNoTracking()
            .Where(s => s.SlotId == variance.SlotId)
            .Join(_db.Zones, s => s.ZoneId, z => z.ZoneId, (s, z) => z.FacilityId)
            .FirstAsync(ct);

        _db.Variances.Add(new CountVarianceEntity
        {
            VarianceId = variance.VarianceId,
            CountId = variance.CountId,
            SlotId = variance.SlotId,
            FacilityId = facilityId,
            Kind = EnumNames.FromVarianceKind(variance.Kind),
            ExpectedContainerId = variance.ExpectedContainerId,
            ObservedContainerId = variance.ObservedContainerId,
            EvidenceDocumentId = variance.EvidenceDocumentId,
            LedgerEntryId = variance.LedgerEntryId,
            OpenedAt = variance.OpenedAt,
            ResolvedAt = variance.ResolvedAt,
            ResolutionNote = variance.ResolutionNote
        });

        await _db.SaveChangesAsync(ct);
    }

    /// <inheritdoc />
    public async Task AttachEvidenceAsync(
        string varianceId,
        string? documentId,
        long? ledgerEntryId,
        CancellationToken ct)
    {
        await _db.Variances
            .Where(v => v.VarianceId == varianceId)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(v => v.EvidenceDocumentId, v => documentId ?? v.EvidenceDocumentId)
                .SetProperty(v => v.LedgerEntryId, v => ledgerEntryId ?? v.LedgerEntryId), ct);
    }

    /// <inheritdoc />
    public async Task<CursorPage<CountVariance>> ListOpenVariancesAsync(
        string facilityId,
        string? cursor,
        int limit,
        CancellationToken ct)
    {
        var query = _db.Variances
            .AsNoTracking()
            .Where(v => v.FacilityId == facilityId && v.ResolvedAt == null);

        if (!string.IsNullOrEmpty(cursor))
        {
            query = query.Where(v => string.Compare(v.VarianceId, cursor, StringComparison.Ordinal) > 0);
        }

        var rows = await query
            .OrderBy(v => v.VarianceId)
            .Take(limit + 1)
            .ToListAsync(ct);

        var hasMore = rows.Count > limit;
        var page = rows.Take(limit).Select(Map).ToList();

        return new CursorPage<CountVariance>(page, hasMore ? page[^1].VarianceId : null);
    }

    /// <inheritdoc />
    public async Task ResolveVarianceAsync(
        string varianceId,
        string note,
        DateTimeOffset resolvedAt,
        CancellationToken ct)
    {
        await _db.Variances
            .Where(v => v.VarianceId == varianceId && v.ResolvedAt == null)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(v => v.ResolvedAt, resolvedAt)
                .SetProperty(v => v.ResolutionNote, note), ct);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<string>> GetSlotsWithRecentVariancesAsync(
        string facilityId,
        int lookbackDays,
        CancellationToken ct)
    {
        var since = DateTimeOffset.UtcNow.AddDays(-lookbackDays);

        return await _db.Variances
            .AsNoTracking()
            .Where(v => v.FacilityId == facilityId && v.OpenedAt >= since)
            .Select(v => v.SlotId)
            .Distinct()
            .ToListAsync(ct);
    }

    private static CycleCountPlan Map(CycleCountPlanEntity p) => new(
        p.PlanId,
        p.FacilityId,
        p.TenantId,
        EnumNames.ToMethod(p.Method),
        p.ScheduledOn,
        p.SlotCount,
        p.CreatedAt,
        p.ClosedAt);

    private static CycleCountTask Map(CycleCountTaskEntity c) => new(
        c.CountId,
        c.PlanId,
        c.SlotId,
        c.ExpectedContainerId,
        c.ObservedContainerId,
        c.CountedByUserId,
        c.CountedAt);

    private static CountVariance Map(CountVarianceEntity v) => new(
        v.VarianceId,
        v.CountId,
        v.SlotId,
        EnumNames.ToVarianceKind(v.Kind),
        v.ExpectedContainerId,
        v.ObservedContainerId,
        v.EvidenceDocumentId,
        v.LedgerEntryId,
        v.OpenedAt,
        v.ResolvedAt,
        v.ResolutionNote);
}
