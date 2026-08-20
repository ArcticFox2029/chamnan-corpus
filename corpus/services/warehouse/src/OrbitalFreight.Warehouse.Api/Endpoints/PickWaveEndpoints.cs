using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Api.Contracts;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Application.Picking;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Api.Endpoints;

/// <summary>
/// Końcówki kompletacji: planowanie fali, wydanie jej na halę, odczyt trasy przez terminal
/// i potwierdzanie zadań. Potwierdzenie zadania zapisuje skan typu <c>load</c> w
/// container-registry — to jedyne miejsce, w którym magazyn pisze poza własnym schematem.
/// </summary>
public static class PickWaveEndpoints
{
    /// <summary>Podpina końcówki fal pod ścieżkę <c>/v1</c>.</summary>
    public static IEndpointRouteBuilder MapPickWaveEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/v1").WithTags("picking");

        group.MapPost("/pick-waves", PlanWaveAsync)
            .WithName("PlanPickWave")
            .WithSummary("Planuje falę i liczy trasę obejścia hali");

        group.MapPost("/pick-waves/{waveId}/release", ReleaseWaveAsync)
            .WithName("ReleasePickWave")
            .WithSummary("Wydaje falę magazynierom; kolejność zadań zostaje zamrożona");

        group.MapGet("/pick-waves/{waveId}", GetWaveAsync)
            .WithName("GetPickWave")
            .WithSummary("Odczyt fali z zadaniami w kolejności trasy");

        group.MapPost("/pick-tasks/{taskId}/complete", CompleteTaskAsync)
            .WithName("CompletePickTask")
            .WithSummary("Potwierdza zadanie i zapisuje skan w container-registry");

        return app;
    }

    /// <summary><c>POST /v1/pick-waves</c> — planuje falę dla wskazanych przesyłek.</summary>
    private static async Task<IResult> PlanWaveAsync(
        PlanWaveRequest request,
        PickWaveService waves,
        IRequestContext context,
        IOptions<WarehouseOptions> options,
        CancellationToken ct)
    {
        if (request.ShipmentIds.Count == 0)
        {
            return ErrorMapper.Build(
                "no_shipments_given",
                StatusCodes.Status400BadRequest,
                "at least one shipment_id is required to plan a wave",
                context.TraceId,
                retryable: false,
                fields: [new FieldError("shipment_ids", "empty")]);
        }

        var invalid = request.ShipmentIds
            .Where(id => !PrefixedId.IsValid(id, PrefixedId.Shipment))
            .Select((id, index) => new FieldError($"shipment_ids[{index}]", "malformed"))
            .ToList();

        if (invalid.Count > 0)
        {
            return ErrorMapper.Build(
                "invalid_shipment_id",
                StatusCodes.Status400BadRequest,
                "every shipment_id must be a shp_ prefixed ULID",
                context.TraceId,
                retryable: false,
                fields: invalid);
        }

        var command = new PlanWaveCommand(
            request.FacilityId,
            context.TenantId,
            request.ShipmentIds,
            ParseStrategy(request.Strategy),
            options.Value.PickWaveMaxTasks);

        try
        {
            var (wave, tasks) = await waves.PlanAsync(command, ct);
            return Results.Created($"/v1/pick-waves/{wave.WaveId}", ToResponse(wave, tasks));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary><c>POST /v1/pick-waves/{waveId}/release</c> — wydaje falę na halę.</summary>
    private static async Task<IResult> ReleaseWaveAsync(
        string waveId,
        PickWaveService waves,
        IRequestContext context,
        CancellationToken ct)
    {
        try
        {
            await waves.ReleaseAsync(waveId, context.ActorId, ct);
            return Results.Accepted($"/v1/pick-waves/{waveId}");
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary><c>GET /v1/pick-waves/{waveId}</c> — to samo, co widzi terminal magazyniera.</summary>
    private static async Task<IResult> GetWaveAsync(
        string waveId,
        IPickWaveRepository repository,
        IRequestContext context,
        CancellationToken ct)
    {
        var wave = await repository.FindWaveAsync(waveId, ct);
        if (wave is null)
        {
            return ErrorMapper.Build(
                "wave_not_found",
                StatusCodes.Status404NotFound,
                $"no wave {waveId}",
                context.TraceId,
                retryable: false);
        }

        var tasks = await repository.GetTasksAsync(waveId, ct);
        return Results.Ok(ToResponse(wave, tasks));
    }

    /// <summary>
    /// <c>POST /v1/pick-tasks/{taskId}/complete</c> — potwierdzenie z terminala. Pole
    /// <c>occurred_at</c> bierzemy z żądania, a nie z zegara serwera: terminal potrafi wysłać
    /// potwierdzenie kwadrans po fakcie, gdy magazynier wyjdzie ze strefy bez zasięgu.
    /// </summary>
    private static async Task<IResult> CompleteTaskAsync(
        string taskId,
        CompleteTaskRequest request,
        PickWaveService waves,
        IRequestContext context,
        CancellationToken ct)
    {
        try
        {
            await waves.CompleteTaskAsync(taskId, context.ActorId, request.Picked, request.OccurredAt, ct);
            return Results.NoContent();
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    private static WaveResponse ToResponse(PickWave wave, IReadOnlyList<PickTask> tasks) => new(
        wave.WaveId,
        wave.FacilityId,
        ToWire(wave.State),
        wave.TotalDistanceM,
        wave.EstimatedSeconds,
        tasks.Select(t => new PickTaskResponse(
            t.TaskId,
            t.SeqNo,
            t.SlotId,
            t.ContainerId,
            t.ShipmentId,
            ToWire(t.State),
            t.TravelCostM,
            t.ScanId)).ToList());

    private static string ToWire(PickWaveState state) => state switch
    {
        PickWaveState.Planned => "planned",
        PickWaveState.Released => "released",
        PickWaveState.Picking => "picking",
        PickWaveState.Completed => "completed",
        PickWaveState.Cancelled => "cancelled",
        _ => "unknown"
    };

    private static string ToWire(PickTaskState state) => state switch
    {
        PickTaskState.Pending => "pending",
        PickTaskState.InProgress => "in_progress",
        PickTaskState.Done => "done",
        PickTaskState.Short => "short",
        PickTaskState.Cancelled => "cancelled",
        _ => "unknown"
    };

    private static WaveStrategy ParseStrategy(string value) => value switch
    {
        "sla_first" => WaveStrategy.SlaFirst,
        "lane_batch" => WaveStrategy.LaneBatch,
        "single_shipment" => WaveStrategy.SingleShipment,
        "zone_batch" => WaveStrategy.ZoneBatch,
        _ => throw new ArgumentException($"unknown wave strategy '{value}'", nameof(value))
    };
}
