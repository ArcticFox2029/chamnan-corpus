using Microsoft.EntityFrameworkCore;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Repositories;

/// <summary>
/// Implementacja <see cref="IPickWaveRepository"/>. Fala z zadaniami jest zapisywana jednym
/// <c>SaveChanges</c> — czterdzieści osobnych INSERT-ów potrafiło przy trzech równoległych
/// planistach zakleszczyć się na indeksie <c>pick_tasks_container_open_uidx</c>.
/// </summary>
/// <param name="db">Kontekst schematu <c>warehouse</c>.</param>
public sealed class PickWaveRepository(WarehouseDbContext db) : IPickWaveRepository
{
    private readonly WarehouseDbContext _db = db;

    /// <inheritdoc />
    public async Task AddWaveAsync(PickWave wave, IReadOnlyList<PickTask> tasks, CancellationToken ct)
    {
        var entity = new PickWaveEntity
        {
            WaveId = wave.WaveId,
            FacilityId = wave.FacilityId,
            TenantId = wave.TenantId,
            Strategy = EnumNames.FromStrategy(wave.Strategy),
            State = EnumNames.FromWaveState(wave.State),
            TotalDistanceM = wave.TotalDistanceM,
            EstimatedSeconds = wave.EstimatedSeconds,
            PlannedAt = wave.PlannedAt,
            ReleasedAt = wave.ReleasedAt,
            CompletedAt = wave.CompletedAt,
            Tasks = tasks.Select(t => new PickTaskEntity
            {
                TaskId = t.TaskId,
                WaveId = t.WaveId,
                SlotId = t.SlotId,
                ContainerId = t.ContainerId,
                ShipmentId = t.ShipmentId,
                SeqNo = t.SeqNo,
                State = EnumNames.FromTaskState(t.State),
                AssignedUserId = t.AssignedUserId,
                TravelCostM = t.TravelCostM,
                StartedAt = t.StartedAt,
                CompletedAt = t.CompletedAt,
                ScanId = t.ScanId
            }).ToList()
        };

        _db.PickWaves.Add(entity);
        await _db.SaveChangesAsync(ct);
    }

    /// <inheritdoc />
    public async Task<PickWave?> FindWaveAsync(string waveId, CancellationToken ct)
    {
        var row = await _db.PickWaves.AsNoTracking().FirstOrDefaultAsync(w => w.WaveId == waveId, ct);
        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<PickTask>> GetTasksAsync(string waveId, CancellationToken ct)
    {
        var rows = await _db.PickTasks
            .AsNoTracking()
            .Where(t => t.WaveId == waveId)
            .OrderBy(t => t.SeqNo)
            .ToListAsync(ct);

        return rows.Select(Map).ToList();
    }

    /// <inheritdoc />
    public async Task<PickTask?> FindTaskAsync(string taskId, CancellationToken ct)
    {
        var row = await _db.PickTasks.AsNoTracking().FirstOrDefaultAsync(t => t.TaskId == taskId, ct);
        return row is null ? null : Map(row);
    }

    /// <inheritdoc />
    public async Task<IReadOnlySet<string>> GetContainersInOpenWavesAsync(string facilityId, CancellationToken ct)
    {
        var ids = await _db.PickTasks
            .AsNoTracking()
            .Join(_db.PickWaves, t => t.WaveId, w => w.WaveId, (t, w) => new { Task = t, Wave = w })
            .Where(x => x.Wave.FacilityId == facilityId
                        && (x.Task.State == "pending" || x.Task.State == "in_progress"))
            .Select(x => x.Task.ContainerId)
            .Distinct()
            .ToListAsync(ct);

        return ids.ToHashSet(StringComparer.Ordinal);
    }

    /// <inheritdoc />
    public async Task UpdateWaveStateAsync(
        string waveId,
        PickWaveState state,
        DateTimeOffset? releasedAt,
        DateTimeOffset? completedAt,
        CancellationToken ct)
    {
        var text = EnumNames.FromWaveState(state);

        await _db.PickWaves
            .Where(w => w.WaveId == waveId)
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(w => w.State, text)
                .SetProperty(w => w.ReleasedAt, w => releasedAt ?? w.ReleasedAt)
                .SetProperty(w => w.CompletedAt, w => completedAt ?? w.CompletedAt), ct);
    }

    /// <inheritdoc />
    public async Task CompleteTaskAsync(
        string taskId,
        PickTaskState state,
        string? scanId,
        DateTimeOffset completedAt,
        CancellationToken ct)
    {
        var text = EnumNames.FromTaskState(state);

        var affected = await _db.PickTasks
            .Where(t => t.TaskId == taskId && (t.State == "pending" || t.State == "in_progress"))
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(t => t.State, text)
                .SetProperty(t => t.ScanId, scanId)
                .SetProperty(t => t.CompletedAt, completedAt), ct);

        if (affected == 0)
        {
            // Zadanie już zamknięte. To nie jest błąd: terminal ponawia potwierdzenie po utracie
            // zasięgu, a §7 pkt 5 wymaga, żeby powtórka dawała ten sam skutek.
            return;
        }
    }

    /// <inheritdoc />
    public Task<bool> HasOpenTasksAsync(string waveId, CancellationToken ct) =>
        _db.PickTasks
            .AsNoTracking()
            .AnyAsync(t => t.WaveId == waveId && (t.State == "pending" || t.State == "in_progress"), ct);

    /// <inheritdoc />
    public async Task<int> CancelWavesForShipmentAsync(string shipmentId, string reasonCode, CancellationToken ct)
    {
        var waveIds = await _db.PickTasks
            .AsNoTracking()
            .Where(t => t.ShipmentId == shipmentId && (t.State == "pending" || t.State == "in_progress"))
            .Select(t => t.WaveId)
            .Distinct()
            .ToListAsync(ct);

        if (waveIds.Count == 0)
        {
            return 0;
        }

        // Zadania w toku zamykamy jako 'cancelled', a nie 'short' — brak towaru i odwołanie fali
        // to dwie różne historie i raport z rozbieżności nie może ich mylić.
        await _db.PickTasks
            .Where(t => waveIds.Contains(t.WaveId) && (t.State == "pending" || t.State == "in_progress"))
            .ExecuteUpdateAsync(setters => setters.SetProperty(t => t.State, "cancelled"), ct);

        await _db.PickWaves
            .Where(w => waveIds.Contains(w.WaveId))
            .ExecuteUpdateAsync(setters => setters
                .SetProperty(w => w.State, "cancelled")
                .SetProperty(w => w.CompletedAt, DateTimeOffset.UtcNow), ct);

        _ = reasonCode; // powód idzie do zdarzenia w skrzynce nadawczej, nie do tabeli fal
        return waveIds.Count;
    }

    private static PickWave Map(PickWaveEntity w) => new(
        w.WaveId,
        w.FacilityId,
        w.TenantId,
        EnumNames.ToStrategy(w.Strategy),
        EnumNames.ToWaveState(w.State),
        w.TotalDistanceM,
        w.EstimatedSeconds,
        w.PlannedAt,
        w.ReleasedAt,
        w.CompletedAt);

    private static PickTask Map(PickTaskEntity t) => new(
        t.TaskId,
        t.WaveId,
        t.SlotId,
        t.ContainerId,
        t.ShipmentId,
        t.SeqNo,
        EnumNames.ToTaskState(t.State),
        t.AssignedUserId,
        t.TravelCostM,
        t.StartedAt,
        t.CompletedAt,
        t.ScanId);
}
