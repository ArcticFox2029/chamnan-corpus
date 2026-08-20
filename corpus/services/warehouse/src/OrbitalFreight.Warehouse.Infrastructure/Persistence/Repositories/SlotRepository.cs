using Microsoft.EntityFrameworkCore;
using Npgsql;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Repositories;

/// <summary>
/// Implementacja <see cref="ISlotRepository"/> na EF Core. Odczyty idą bez śledzenia zmian
/// (<c>AsNoTracking</c>), bo warstwa domenowa i tak dostaje niemutowalne rekordy; śledzimy
/// tylko to, co faktycznie zapisujemy.
/// </summary>
/// <param name="db">Kontekst schematu <c>warehouse</c>.</param>
public sealed class SlotRepository(WarehouseDbContext db) : ISlotRepository
{
    private readonly WarehouseDbContext _db = db;

    /// <inheritdoc />
    public async Task<IReadOnlyList<WarehouseZone>> GetZonesAsync(string facilityId, CancellationToken ct)
    {
        var rows = await _db.Zones
            .AsNoTracking()
            .Where(z => z.FacilityId == facilityId)
            .OrderBy(z => z.Kind)
            .ToListAsync(ct);

        return rows.Select(Map).ToList();
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<Slot>> GetFreeSlotsAsync(
        IReadOnlyCollection<string> zoneIds,
        DateTimeOffset asOf,
        int limit,
        CancellationToken ct)
    {
        // Wolne gniazdo to takie, dla którego nie istnieje otwarte rozstawienie. NOT EXISTS jest
        // tu wyraźnie szybszy od LEFT JOIN ... IS NULL, bo indeks częściowy
        // placements_container_open_idx obejmuje dokładnie wiersze z removed_at IS NULL.
        var rows = await _db.Slots
            .AsNoTracking()
            .Where(s => zoneIds.Contains(s.ZoneId) && !s.IsBlocked && s.RetiredAt == null)
            .Where(s => !_db.Placements.Any(p =>
                p.SlotId == s.SlotId && p.PlacedAt <= asOf && (p.RemovedAt == null || p.RemovedAt > asOf)))
            .OrderBy(s => s.TravelCostM)
            .Take(limit)
            .ToListAsync(ct);

        return rows.Select(Map).ToList();
    }

    /// <inheritdoc />
    public async Task<Slot?> FindSlotAsync(string slotId, CancellationToken ct)
    {
        var row = await _db.Slots.AsNoTracking().FirstOrDefaultAsync(s => s.SlotId == slotId, ct);
        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<Slot?> FindSlotByCodeAsync(string facilityId, string slotCode, CancellationToken ct)
    {
        var row = await _db.Slots
            .AsNoTracking()
            .Join(_db.Zones, s => s.ZoneId, z => z.ZoneId, (s, z) => new { Slot = s, Zone = z })
            .Where(x => x.Zone.FacilityId == facilityId && x.Slot.SlotCode == slotCode)
            .Select(x => x.Slot)
            .FirstOrDefaultAsync(ct);

        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<CursorPage<Slot>> ListSlotsAsync(
        string facilityId,
        string? cursor,
        int limit,
        CancellationToken ct)
    {
        // Kursor jest po prostu ostatnim widzianym slot_id — porządek (alejka, zatoka, poziom,
        // slot_id) jest całkowity, więc para (klucz, porządek) wystarcza i nie potrzeba kodowania
        // złożonego kursora. Offsetu platforma nie zna (§0.5).
        var query = _db.Slots
            .AsNoTracking()
            .Join(_db.Zones, s => s.ZoneId, z => z.ZoneId, (s, z) => new { Slot = s, Zone = z })
            .Where(x => x.Zone.FacilityId == facilityId);

        if (!string.IsNullOrEmpty(cursor))
        {
            query = query.Where(x => string.Compare(x.Slot.SlotId, cursor, StringComparison.Ordinal) > 0);
        }

        var rows = await query
            .OrderBy(x => x.Slot.Aisle)
            .ThenBy(x => x.Slot.Bay)
            .ThenBy(x => x.Slot.Level)
            .ThenBy(x => x.Slot.SlotId)
            .Take(limit + 1)
            .Select(x => x.Slot)
            .ToListAsync(ct);

        var hasMore = rows.Count > limit;
        var page = rows.Take(limit).Select(Map).ToList();

        return new CursorPage<Slot>(page, hasMore ? page[^1].SlotId : null);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<string>> GetNeighbourHazardClassesAsync(
        string slotId,
        int radiusBays,
        CancellationToken ct)
    {
        var anchor = await _db.Slots.AsNoTracking().FirstOrDefaultAsync(s => s.SlotId == slotId, ct);
        if (anchor is null)
        {
            return [];
        }

        var lowerBay = (short)(anchor.Bay - radiusBays);
        var upperBay = (short)(anchor.Bay + radiusBays);

        return await _db.Placements
            .AsNoTracking()
            .Join(_db.Slots, p => p.SlotId, s => s.SlotId, (p, s) => new { Placement = p, Slot = s })
            .Where(x => x.Slot.ZoneId == anchor.ZoneId
                        && x.Slot.Aisle == anchor.Aisle
                        && x.Slot.Bay >= lowerBay
                        && x.Slot.Bay <= upperBay
                        && x.Slot.SlotId != slotId
                        && x.Placement.RemovedAt == null
                        && x.Placement.HazardClassCode != null)
            .Select(x => x.Placement.HazardClassCode!)
            .Distinct()
            .ToListAsync(ct);
    }

    /// <inheritdoc />
    public async Task<SlotPlacement?> GetActivePlacementAsync(string slotId, CancellationToken ct)
    {
        var row = await _db.Placements
            .AsNoTracking()
            .FirstOrDefaultAsync(p => p.SlotId == slotId && p.RemovedAt == null, ct);

        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<SlotPlacement?> FindActivePlacementByContainerAsync(string containerId, CancellationToken ct)
    {
        var row = await _db.Placements
            .AsNoTracking()
            .FirstOrDefaultAsync(p => p.ContainerId == containerId && p.RemovedAt == null, ct);

        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task AddPlacementAsync(SlotPlacement placement, CancellationToken ct)
    {
        _db.Placements.Add(new PlacementEntity
        {
            PlacementId = placement.PlacementId,
            SlotId = placement.SlotId,
            ContainerId = placement.ContainerId,
            ShipmentId = placement.ShipmentId,
            GrossKg = placement.GrossKg,
            HazardClassCode = placement.HazardClassCode,
            RequiresPower = placement.RequiresPower,
            PlacedAt = placement.PlacedAt,
            RemovedAt = placement.RemovedAt
        });

        try
        {
            await _db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex) when (ex.InnerException is PostgresException { SqlState: "23P01" })
        {
            // 23P01 = exclusion_violation. Wyścig o gniazdo rozstrzyga baza; my tylko tłumaczymy
            // go na wyjątek domenowy, który warstwa HTTP zamieni na kod 'slot_occupied' (409).
            var occupant = await _db.Placements
                .AsNoTracking()
                .Where(p => p.SlotId == placement.SlotId && p.RemovedAt == null)
                .Select(p => p.ContainerId)
                .FirstOrDefaultAsync(ct);

            throw new SlotOccupiedException(placement.SlotId, occupant ?? "unknown");
        }
    }

    /// <inheritdoc />
    public async Task ClosePlacementAsync(string placementId, DateTimeOffset removedAt, CancellationToken ct)
    {
        await _db.Placements
            .Where(p => p.PlacementId == placementId && p.RemovedAt == null)
            .ExecuteUpdateAsync(setters => setters.SetProperty(p => p.RemovedAt, removedAt), ct);
    }

    /// <inheritdoc />
    public async Task SetSlotBlockedAsync(string slotId, bool isBlocked, string? reason, CancellationToken ct)
    {
        if (isBlocked && string.IsNullOrWhiteSpace(reason))
        {
            throw new ArgumentException("blocking a slot requires a reason code", nameof(reason));
        }

        await _db.Slots
            .Where(s => s.SlotId == slotId)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(s => s.IsBlocked, isBlocked)
                .SetProperty(s => s.BlockedReason, isBlocked ? reason : null), ct);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<PutawayRule>> GetPutawayRulesAsync(string facilityId, CancellationToken ct)
    {
        var rows = await _db.PutawayRules
            .AsNoTracking()
            .Where(r => r.FacilityId == facilityId)
            .OrderBy(r => r.Priority)
            .ToListAsync(ct);

        return rows
            .Select(r => new PutawayRule(
                r.RuleId,
                r.FacilityId,
                r.Priority,
                r.IsoSizeType,
                r.IsReefer,
                r.HazardClassCode,
                EnumNames.ToZoneKind(r.TargetZoneKind)))
            .ToList();
    }

    private static WarehouseZone Map(ZoneEntity z) => new(
        z.ZoneId,
        z.FacilityId,
        z.TenantId,
        EnumNames.ToZoneKind(z.Kind),
        z.TemperatureMinC,
        z.TemperatureMaxC,
        z.HasPoweredSlots,
        z.GeofenceId,
        z.RegionCode);

    private static Slot Map(SlotEntity s) => new(
        s.SlotId,
        s.ZoneId,
        s.SlotCode,
        s.Aisle,
        s.Bay,
        s.Level,
        s.MaxWeightKg,
        s.IsPowered,
        s.TravelCostM,
        s.IsBlocked,
        s.BlockedReason,
        s.CreatedAt,
        s.RetiredAt);

    private static SlotPlacement Map(PlacementEntity p) => new(
        p.PlacementId,
        p.SlotId,
        p.ContainerId,
        p.ShipmentId,
        p.GrossKg,
        p.HazardClassCode,
        p.RequiresPower,
        p.PlacedAt,
        p.RemovedAt);
}

/// <summary>
/// Tłumaczenie między wartościami tekstowymi w bazie (<c>snake_case</c>, bo tak wyglądają
/// ograniczenia CHECK i tak samo idą na drut) a wyliczeniami domeny. Trzymamy to w jednym
/// miejscu, żeby literówka w nazwie stanu nie rozjechała się między repozytoriami.
/// </summary>
internal static class EnumNames
{
    /// <summary>Zamienia tekst z kolumny na <see cref="ZoneKind"/>.</summary>
    /// <exception cref="ArgumentOutOfRangeException">Gdy baza zawiera wartość spoza CHECK-a.</exception>
    public static ZoneKind ToZoneKind(string value) => value switch
    {
        "inbound_dock" => ZoneKind.InboundDock,
        "bulk" => ZoneKind.Bulk,
        "rack" => ZoneKind.Rack,
        "reefer" => ZoneKind.Reefer,
        "bonded" => ZoneKind.Bonded,
        "outbound_dock" => ZoneKind.OutboundDock,
        "quarantine" => ZoneKind.Quarantine,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown zone kind")
    };

    /// <summary>Zamienia <see cref="ZoneKind"/> na tekst zapisywany w kolumnie.</summary>
    public static string FromZoneKind(ZoneKind kind) => kind switch
    {
        ZoneKind.InboundDock => "inbound_dock",
        ZoneKind.Bulk => "bulk",
        ZoneKind.Rack => "rack",
        ZoneKind.Reefer => "reefer",
        ZoneKind.Bonded => "bonded",
        ZoneKind.OutboundDock => "outbound_dock",
        ZoneKind.Quarantine => "quarantine",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "unknown zone kind")
    };

    /// <summary>Stan fali w postaci tekstowej.</summary>
    public static string FromWaveState(PickWaveState state) => state switch
    {
        PickWaveState.Planned => "planned",
        PickWaveState.Released => "released",
        PickWaveState.Picking => "picking",
        PickWaveState.Completed => "completed",
        PickWaveState.Cancelled => "cancelled",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "unknown wave state")
    };

    /// <summary>Stan fali odczytany z bazy.</summary>
    public static PickWaveState ToWaveState(string value) => value switch
    {
        "planned" => PickWaveState.Planned,
        "released" => PickWaveState.Released,
        "picking" => PickWaveState.Picking,
        "completed" => PickWaveState.Completed,
        "cancelled" => PickWaveState.Cancelled,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown wave state")
    };

    /// <summary>Stan zadania w postaci tekstowej.</summary>
    public static string FromTaskState(PickTaskState state) => state switch
    {
        PickTaskState.Pending => "pending",
        PickTaskState.InProgress => "in_progress",
        PickTaskState.Done => "done",
        PickTaskState.Short => "short",
        PickTaskState.Cancelled => "cancelled",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "unknown task state")
    };

    /// <summary>Stan zadania odczytany z bazy.</summary>
    public static PickTaskState ToTaskState(string value) => value switch
    {
        "pending" => PickTaskState.Pending,
        "in_progress" => PickTaskState.InProgress,
        "done" => PickTaskState.Done,
        "short" => PickTaskState.Short,
        "cancelled" => PickTaskState.Cancelled,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown task state")
    };

    /// <summary>Strategia fali w postaci tekstowej.</summary>
    public static string FromStrategy(WaveStrategy strategy) => strategy switch
    {
        WaveStrategy.SlaFirst => "sla_first",
        WaveStrategy.LaneBatch => "lane_batch",
        WaveStrategy.SingleShipment => "single_shipment",
        WaveStrategy.ZoneBatch => "zone_batch",
        _ => throw new ArgumentOutOfRangeException(nameof(strategy), strategy, "unknown strategy")
    };

    /// <summary>Strategia fali odczytana z bazy.</summary>
    public static WaveStrategy ToStrategy(string value) => value switch
    {
        "sla_first" => WaveStrategy.SlaFirst,
        "lane_batch" => WaveStrategy.LaneBatch,
        "single_shipment" => WaveStrategy.SingleShipment,
        "zone_batch" => WaveStrategy.ZoneBatch,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown strategy")
    };

    /// <summary>Metoda inwentaryzacji w postaci tekstowej.</summary>
    public static string FromMethod(CycleCountMethod method) => method switch
    {
        CycleCountMethod.Abc => "abc",
        CycleCountMethod.Random => "random",
        CycleCountMethod.VarianceDriven => "variance_driven",
        CycleCountMethod.BlindRecount => "blind_recount",
        _ => throw new ArgumentOutOfRangeException(nameof(method), method, "unknown method")
    };

    /// <summary>Metoda inwentaryzacji odczytana z bazy.</summary>
    public static CycleCountMethod ToMethod(string value) => value switch
    {
        "abc" => CycleCountMethod.Abc,
        "random" => CycleCountMethod.Random,
        "variance_driven" => CycleCountMethod.VarianceDriven,
        "blind_recount" => CycleCountMethod.BlindRecount,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown method")
    };

    /// <summary>Rodzaj rozbieżności w postaci tekstowej.</summary>
    public static string FromVarianceKind(VarianceKind kind) => kind switch
    {
        VarianceKind.Missing => "missing",
        VarianceKind.Unexpected => "unexpected",
        VarianceKind.WrongSlot => "wrong_slot",
        VarianceKind.Damaged => "damaged",
        VarianceKind.SealMismatch => "seal_mismatch",
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "unknown variance kind")
    };

    /// <summary>Rodzaj rozbieżności odczytany z bazy.</summary>
    public static VarianceKind ToVarianceKind(string value) => value switch
    {
        "missing" => VarianceKind.Missing,
        "unexpected" => VarianceKind.Unexpected,
        "wrong_slot" => VarianceKind.WrongSlot,
        "damaged" => VarianceKind.Damaged,
        "seal_mismatch" => VarianceKind.SealMismatch,
        _ => throw new ArgumentOutOfRangeException(nameof(value), value, "unknown variance kind")
    };
}
