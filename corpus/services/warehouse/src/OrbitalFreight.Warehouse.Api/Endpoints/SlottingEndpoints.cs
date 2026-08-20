using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Api.Contracts;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Api.Endpoints;

/// <summary>
/// Końcówki adresowania towaru: rekomendacja gniazda, zapis rozstawienia, zdjęcie kontenera
/// z gniazda i przegląd gniazd obiektu. Wszystkie mutacje przechodzą przez
/// <see cref="Middleware.IdempotencyMiddleware"/>, bo terminale w hali ponawiają wysyłkę.
/// </summary>
public static class SlottingEndpoints
{
    /// <summary>Podpina końcówki pod ścieżkę <c>/v1</c>.</summary>
    /// <param name="app">Budowniczy tras.</param>
    /// <returns>Ten sam budowniczy, dla łańcuchowania w <c>Program.cs</c>.</returns>
    public static IEndpointRouteBuilder MapSlottingEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/v1").WithTags("slotting");

        group.MapPost("/placements", CreatePlacementAsync)
            .WithName("CreatePlacement")
            .WithSummary("Adresuje kontener do gniazda i zapisuje rozstawienie");

        group.MapPost("/slotting/recommend", RecommendAsync)
            .WithName("RecommendSlots")
            .WithSummary("Zwraca ranking gniazd bez zapisywania czegokolwiek");

        group.MapDelete("/placements/{containerId}", RemovePlacementAsync)
            .WithName("RemovePlacement")
            .WithSummary("Zdejmuje kontener z gniazda, stemplując removed_at");

        group.MapGet("/facilities/{facilityId}/slots", ListSlotsAsync)
            .WithName("ListSlots")
            .WithSummary("Strona gniazd obiektu w kolejności obejścia hali");

        return app;
    }

    /// <summary>
    /// <c>POST /v1/placements</c> — przyjmuje kontener. Dane kontenera pobiera z container-registry,
    /// więc żądanie nie musi (i nie może) podawać jego typu ISO ani setpointu.
    /// </summary>
    private static async Task<IResult> CreatePlacementAsync(
        CreatePlacementRequest request,
        PutawayService putaway,
        ISlotRepository slots,
        IRequestContext context,
        IOptions<WarehouseOptions> options,
        CancellationToken ct)
    {
        if (!PrefixedId.IsValid(request.ContainerId, PrefixedId.Container))
        {
            return ErrorMapper.Build(
                "invalid_container_id",
                StatusCodes.Status400BadRequest,
                "container_id must be a cnt_ prefixed ULID",
                context.TraceId,
                retryable: false,
                fields: [new FieldError("container_id", "malformed")]);
        }

        var command = new PutawayCommand(
            request.FacilityId,
            request.ContainerId,
            request.ShipmentId,
            request.GrossKg,
            request.UnderCustomsControl,
            options.Value.RegionCode,
            options.Value.HazardSegregationRadiusBays,
            AislesWithSameShipment: new HashSet<short>());

        try
        {
            var result = await putaway.PlaceAsync(command, ct);
            var slot = await slots.FindSlotAsync(result.Placement.SlotId, ct);

            return Results.Created(
                $"/v1/placements/{result.Placement.PlacementId}",
                new PlacementResponse(
                    result.Placement.PlacementId,
                    result.Placement.SlotId,
                    slot?.SlotCode ?? string.Empty,
                    Math.Round(result.Score, 3),
                    result.Placement.PlacedAt));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary>
    /// <c>POST /v1/slotting/recommend</c> — ranking dla ekranu dyspozytora. Zwraca także gniazda
    /// odrzucone wraz z kodem przyczyny, bo pytanie „czemu nie to gniazdo” pada w hali codziennie.
    /// </summary>
    private static async Task<IResult> RecommendAsync(
        CreatePlacementRequest request,
        PutawayService putaway,
        IRequestContext context,
        IOptions<WarehouseOptions> options,
        CancellationToken ct)
    {
        var command = new PutawayCommand(
            request.FacilityId,
            request.ContainerId,
            request.ShipmentId,
            request.GrossKg,
            request.UnderCustomsControl,
            options.Value.RegionCode,
            options.Value.HazardSegregationRadiusBays,
            AislesWithSameShipment: new HashSet<short>());

        try
        {
            var ranking = await putaway.RecommendAsync(command, ct);

            var items = ranking
                .Take(20)
                .Select(s => new SlotRecommendationResponse(s.SlotId, Math.Round(s.Score, 3), s.IsEligible, s.ReasonCode))
                .ToList();

            return Results.Ok(new CursorPageResponse<SlotRecommendationResponse>(items, NextCursor: null));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary>
    /// <c>DELETE /v1/placements/{containerId}</c> — zdejmuje kontener z gniazda. Nazwa metody
    /// HTTP jest umowna: wiersz zostaje, zmienia się tylko <c>removed_at</c>, bo historia
    /// rozstawień jest dowodem przy sporach o uszkodzenia.
    /// </summary>
    private static async Task<IResult> RemovePlacementAsync(
        string containerId,
        string? reason,
        PutawayService putaway,
        IRequestContext context,
        CancellationToken ct)
    {
        try
        {
            var removed = await putaway.RemoveAsync(containerId, reason ?? "manual", ct);
            return removed ? Results.NoContent() : Results.NotFound();
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary><c>GET /v1/facilities/{facilityId}/slots</c> — paginacja kursorowa wg §0.5.</summary>
    private static async Task<IResult> ListSlotsAsync(
        string facilityId,
        string? cursor,
        int? limit,
        ISlotRepository slots,
        IRequestContext context,
        CancellationToken ct)
    {
        // Domyślnie 50, twardy sufit 200 — jak wszędzie na platformie.
        var effectiveLimit = Math.Clamp(limit ?? 50, 1, 200);

        try
        {
            var page = await slots.ListSlotsAsync(facilityId, cursor, effectiveLimit, ct);

            var items = page.Items
                .Select(s => new SlotResponse(
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
                    s.BlockedReason))
                .ToList();

            return Results.Ok(new CursorPageResponse<SlotResponse>(items, page.NextCursor));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }
}
