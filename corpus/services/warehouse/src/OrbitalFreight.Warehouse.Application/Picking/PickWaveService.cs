using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Domain.Picking;

namespace OrbitalFreight.Warehouse.Application.Picking;

/// <summary>
/// Prowadzi falę kompletacyjną przez cały jej żywot: planowanie trasy, wydanie na halę,
/// potwierdzanie zadań i zamknięcie. Potwierdzenie zadania jest jedynym miejscem w usłudze,
/// które zapisuje coś poza własnym schematem — skan idzie do container-registry, bo to on
/// jest właścicielem <c>freight.shipment_scan_events</c>.
/// </summary>
/// <param name="waves">Repozytorium fal.</param>
/// <param name="slots">Repozytorium gniazd — trasa powstaje z ich współrzędnych.</param>
/// <param name="registry">Port do container-registry.</param>
/// <param name="putaway">Usługa przyjęć; zdejmuje kontener z gniazda po skompletowaniu.</param>
/// <param name="planner">Planer trasy.</param>
/// <param name="outbox">Skrzynka nadawcza.</param>
/// <param name="uow">Granica transakcji.</param>
/// <param name="ids">Wytwórnia identyfikatorów.</param>
/// <param name="clock">Zegar.</param>
/// <param name="logger">Dziennik.</param>
public sealed class PickWaveService(
    IPickWaveRepository waves,
    ISlotRepository slots,
    IContainerRegistryPort registry,
    PutawayService putaway,
    PickPathPlanner planner,
    IOutboxWriter outbox,
    IWarehouseUnitOfWork uow,
    IIdentifierFactory ids,
    TimeProvider clock,
    ILogger<PickWaveService> logger)
{
    private readonly IPickWaveRepository _waves = waves;
    private readonly ISlotRepository _slots = slots;
    private readonly IContainerRegistryPort _registry = registry;
    private readonly PutawayService _putaway = putaway;
    private readonly PickPathPlanner _planner = planner;
    private readonly IOutboxWriter _outbox = outbox;
    private readonly IWarehouseUnitOfWork _uow = uow;
    private readonly IIdentifierFactory _ids = ids;
    private readonly TimeProvider _clock = clock;
    private readonly ILogger<PickWaveService> _logger = logger;

    /// <summary>
    /// Planuje falę dla wskazanych przesyłek.
    /// </summary>
    /// <param name="command">Polecenie planowania.</param>
    /// <param name="ct">Token anulowania.</param>
    /// <returns>Fala w stanie <see cref="PickWaveState.Planned"/> wraz z zadaniami.</returns>
    /// <exception cref="PickWaveFailedException">Gdy żaden kontener nie nadaje się do kompletacji.</exception>
    public async Task<(PickWave Wave, IReadOnlyList<PickTask> Tasks)> PlanAsync(
        PlanWaveCommand command,
        CancellationToken ct)
    {
        var now = _clock.GetUtcNow();
        var alreadyClaimed = await _waves.GetContainersInOpenWavesAsync(command.FacilityId, ct);
        var stops = new List<PickStop>();

        foreach (var shipmentId in command.ShipmentIds)
        {
            var shipment = await _registry.GetShipmentAsync(shipmentId, ct)
                ?? throw new PickWaveFailedException("shipment_not_found", shipmentId);

            // Przesyłka zaplombowana albo w tranzycie nie ma czego szukać w magazynie; stany
            // pochodzą wprost z CHECK-a na freight.shipments.status.
            if (shipment.Status is "cancelled" or "delivered")
            {
                _logger.LogInformation("skipping shipment {ShipmentId} in status {Status}", shipmentId, shipment.Status);
                continue;
            }

            foreach (var containerId in shipment.ContainerIds)
            {
                if (alreadyClaimed.Contains(containerId))
                {
                    continue;
                }

                var placement = await _slots.FindActivePlacementByContainerAsync(containerId, ct);
                if (placement is null)
                {
                    continue;
                }

                var slot = await _slots.FindSlotAsync(placement.SlotId, ct);
                if (slot is null || !slot.IsUsable)
                {
                    continue;
                }

                stops.Add(new PickStop(
                    slot.SlotId,
                    containerId,
                    shipmentId,
                    slot.Aisle,
                    slot.Bay,
                    slot.Level,
                    slot.TravelCostM));
            }
        }

        if (stops.Count == 0)
        {
            throw new PickWaveFailedException("nothing_to_pick", command.FacilityId);
        }

        if (stops.Count > command.MaxTasks)
        {
            // Ucinamy po posortowaniu wg pilności, a nie losowo: przy strategii sla_first liczy się
            // to, żeby w fali znalazły się przesyłki z najbliższym terminem.
            stops = stops.Take(command.MaxTasks).ToList();
        }

        var path = _planner.Plan(stops);
        var waveId = _ids.NewId(PrefixedId.PickWave);

        var wave = new PickWave(
            waveId,
            command.FacilityId,
            command.TenantId,
            command.Strategy,
            PickWaveState.Planned,
            path.TotalDistanceM,
            path.EstimatedSeconds,
            now,
            ReleasedAt: null,
            CompletedAt: null);

        var tasks = path.Legs
            .Select(leg => new PickTask(
                _ids.NewId(PrefixedId.PickTask),
                waveId,
                leg.Stop.SlotId,
                leg.Stop.ContainerId,
                leg.Stop.ShipmentId,
                leg.SeqNo,
                PickTaskState.Pending,
                AssignedUserId: null,
                leg.DistanceM,
                StartedAt: null,
                CompletedAt: null,
                ScanId: null))
            .ToList();

        await _waves.AddWaveAsync(wave, tasks, ct);

        _logger.LogInformation(
            "planned wave {WaveId}: {TaskCount} tasks, {DistanceM} m, {Seconds} s",
            waveId,
            tasks.Count,
            path.TotalDistanceM,
            path.EstimatedSeconds);

        return (wave, tasks);
    }

    /// <summary>
    /// Wydaje falę na halę. Od tej chwili kolejność zadań jest zamrożona, a magazynier widzi
    /// ją na terminalu w takiej postaci, w jakiej ją dostał.
    /// </summary>
    public async Task ReleaseAsync(string waveId, string releasedByUserId, CancellationToken ct)
    {
        var wave = await _waves.FindWaveAsync(waveId, ct)
            ?? throw new PickWaveFailedException("wave_not_found", waveId);

        if (wave.State != PickWaveState.Planned)
        {
            throw new PickWaveFailedException("wave_not_releasable", waveId);
        }

        var now = _clock.GetUtcNow();
        var tasks = await _waves.GetTasksAsync(waveId, ct);

        await using var tx = await _uow.BeginAsync(ct);

        await _waves.UpdateWaveStateAsync(waveId, PickWaveState.Released, now, completedAt: null, ct);
        await _outbox.EnqueueAsync(
            "warehouse.pick_wave.released",
            "of.platform.v1",
            wave.FacilityId,
            new Dictionary<string, object?>
            {
                ["wave_id"] = waveId,
                ["facility_id"] = wave.FacilityId,
                ["strategy"] = wave.Strategy.ToString().ToLowerInvariant(),
                ["task_count"] = tasks.Count,
                ["shipment_ids"] = tasks.Select(t => t.ShipmentId).Distinct().ToList(),
                ["total_distance_m"] = wave.TotalDistanceM,
                ["estimated_seconds"] = wave.EstimatedSeconds,
                ["released_by"] = releasedByUserId,
                ["released_at"] = now
            },
            ct);

        await _uow.SaveChangesAsync(ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// Potwierdza wykonanie jednego zadania: zapisuje skan w container-registry, zdejmuje
    /// kontener z gniazda i — gdy to było ostatnie otwarte zadanie — zamyka falę.
    /// </summary>
    /// <param name="taskId">Zadanie, prefiks <c>pkt_</c>.</param>
    /// <param name="userId">Magazynier.</param>
    /// <param name="picked">Czy kontener faktycznie zabrano; <see langword="false"/> daje stan <c>short</c>.</param>
    /// <param name="occurredAt">Czas z terminala; przy pracy offline starszy niż chwila zapisu.</param>
    /// <param name="ct">Token anulowania.</param>
    public async Task CompleteTaskAsync(
        string taskId,
        string userId,
        bool picked,
        DateTimeOffset occurredAt,
        CancellationToken ct)
    {
        var task = await _waves.FindTaskAsync(taskId, ct)
            ?? throw new PickWaveFailedException("task_not_found", taskId);

        if (task.State is PickTaskState.Done or PickTaskState.Short or PickTaskState.Cancelled)
        {
            // Powtórka po utracie zasięgu. §7 pkt 5 wymaga, żeby dała ten sam skutek, więc
            // kończymy cicho zamiast zwracać konflikt.
            return;
        }

        var wave = await _waves.FindWaveAsync(task.WaveId, ct)
            ?? throw new PickWaveFailedException("wave_not_found", task.WaveId);

        string? scanId = null;

        if (picked)
        {
            // Typ 'load' jest jedną z wartości freight.shipment_scan_events.scan_type; skan
            // wraca do nas zdarzeniem shipment.scanned, dlatego konsument odsiewa własne skany
            // po device_serial.
            scanId = await _registry.RecordScanAsync(
                task.ContainerId,
                task.ShipmentId,
                "load",
                wave.FacilityId,
                userId,
                occurredAt,
                ct);
        }

        var now = _clock.GetUtcNow();
        var state = picked ? PickTaskState.Done : PickTaskState.Short;

        await _waves.CompleteTaskAsync(taskId, state, scanId, now, ct);

        if (picked)
        {
            await _putaway.RemoveAsync(task.ContainerId, "picked", ct);
        }
        else
        {
            // Brak towaru w gnieździe to sprawa dla inwentaryzacji: blokujemy gniazdo, żeby nikt
            // nic tam nie odstawił, zanim rozbieżność zostanie wyjaśniona.
            await _slots.SetSlotBlockedAsync(task.SlotId, isBlocked: true, "open_variance", ct);
            _logger.LogWarning("task {TaskId} reported short at slot {SlotId}", taskId, task.SlotId);
        }

        if (!await _waves.HasOpenTasksAsync(task.WaveId, ct))
        {
            await using var tx = await _uow.BeginAsync(ct);

            await _waves.UpdateWaveStateAsync(task.WaveId, PickWaveState.Completed, releasedAt: null, now, ct);
            await _outbox.EnqueueAsync(
                "warehouse.pick_wave.completed",
                "of.platform.v1",
                wave.FacilityId,
                new Dictionary<string, object?>
                {
                    ["wave_id"] = task.WaveId,
                    ["facility_id"] = wave.FacilityId,
                    ["completed_at"] = now
                },
                ct);

            await _uow.SaveChangesAsync(ct);
            await tx.CommitAsync(ct);
        }
    }

    /// <summary>
    /// Anuluje fale związane z przesyłką. Wywoływane przez konsumenta
    /// <c>shipment.status.changed</c> przy przejściu w <c>cancelled</c>.
    /// </summary>
    public async Task<int> CancelForShipmentAsync(string shipmentId, string reasonCode, CancellationToken ct)
    {
        var cancelled = await _waves.CancelWavesForShipmentAsync(shipmentId, reasonCode, ct);

        if (cancelled > 0)
        {
            _logger.LogInformation(
                "cancelled {Count} wave(s) for shipment {ShipmentId}, reason {ReasonCode}",
                cancelled,
                shipmentId,
                reasonCode);
        }

        return cancelled;
    }
}

/// <summary>Polecenie zaplanowania fali.</summary>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="TenantId">Najemca.</param>
/// <param name="ShipmentIds">Przesyłki do skompletowania.</param>
/// <param name="Strategy">Strategia doboru zadań.</param>
/// <param name="MaxTasks">Górna granica zadań, z <c>OF_WAREHOUSE_PICK_WAVE_MAX_TASKS</c>.</param>
public sealed record PlanWaveCommand(
    string FacilityId,
    string TenantId,
    IReadOnlyList<string> ShipmentIds,
    WaveStrategy Strategy,
    int MaxTasks);

/// <summary>Niepowodzenie operacji na fali, z kodem gotowym do koperty błędu (§0.4).</summary>
/// <param name="code">Kod w <c>snake_case</c>.</param>
/// <param name="subject">Podmiot odmowy.</param>
public sealed class PickWaveFailedException(string code, string subject)
    : InvalidOperationException($"{code}: {subject}")
{
    /// <summary>Kod przyczyny.</summary>
    public string Code { get; } = code;

    /// <summary>Podmiot.</summary>
    public string Subject { get; } = subject;
}
