// -----------------------------------------------------------------------------------------------
// Powierzchnia administracyjna topologii hali: odczyt stref, reguł adresowania i zakładanie blokad
// na gniazdach. Nie ma tu tworzenia stref ani gniazd — te powstają migracją razem z przebudową
// regałów, bo wiersz w bazie bez fizycznej etykiety na regale jest gorszy niż jego brak.
// -----------------------------------------------------------------------------------------------

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.EntityFrameworkCore;
using OrbitalFreight.Warehouse.Api.Contracts;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Api.Endpoints;

/// <summary>
/// Końcówki topologii. Istnienie obiektu potwierdza container-registry — magazyn nie czyta
/// <c>freight.facilities</c> SQL-em, bo schemat należy do innej usługi (§7 pkt 2).
/// </summary>
public static class ZoneEndpoints
{
    /// <summary>Podpina końcówki pod ścieżkę <c>/v1</c>.</summary>
    /// <param name="app">Budowniczy tras.</param>
    public static IEndpointRouteBuilder MapZoneEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/v1").WithTags("topology");

        group.MapGet("/facilities/{facilityId}/zones", ListZonesAsync)
            .WithName("ListZones")
            .WithSummary("Strefy obiektu wraz z kopertą temperaturową i liczbą gniazd");

        group.MapGet("/facilities/{facilityId}/putaway-rules", ListRulesAsync)
            .WithName("ListPutawayRules")
            .WithSummary("Reguły adresowania obiektu, rosnąco po priorytecie");

        group.MapPut("/slots/{slotId}/block", SetBlockAsync)
            .WithName("SetSlotBlock")
            .WithSummary("Zakłada albo zdejmuje blokadę gniazda");

        return app;
    }

    /// <summary>
    /// <c>GET /v1/facilities/{facility_id}/zones</c> — strefy obiektu. Liczbę gniazd doliczamy tu,
    /// a nie w repozytorium, bo to jedyne miejsce, które jej potrzebuje, a jest to zapytanie
    /// agregujące po całej hali.
    /// </summary>
    private static async Task<IResult> ListZonesAsync(
        string facilityId,
        ISlotRepository slots,
        WarehouseDbContext db,
        IRequestContext context,
        CancellationToken ct)
    {
        if (!facilityId.StartsWith("fac_", StringComparison.Ordinal))
        {
            return ErrorMapper.Build(
                "invalid_facility_id",
                StatusCodes.Status400BadRequest,
                "facility_id must carry the fac_ prefix from §0.1",
                context.TraceId,
                retryable: false);
        }

        var zones = await slots.GetZonesAsync(facilityId, ct);

        var counts = await db.Slots
            .Where(s => s.RetiredAt == null)
            .GroupBy(s => s.ZoneId)
            .Select(g => new { ZoneId = g.Key, Count = g.Count() })
            .ToDictionaryAsync(x => x.ZoneId, x => x.Count, ct);

        var response = zones
            .Select(zone => new ZoneResponse(
                zone.ZoneId,
                zone.FacilityId,
                ToSnakeCase(zone.Kind),
                zone.TemperatureMinC,
                zone.TemperatureMaxC,
                zone.HasPoweredSlots,
                zone.GeofenceId,
                zone.RegionCode,
                counts.GetValueOrDefault(zone.ZoneId)))
            .ToList();

        return Results.Json(response);
    }

    /// <summary>
    /// <c>GET /v1/facilities/{facility_id}/putaway-rules</c> — reguły adresowania. Dyspozytor czyta
    /// je, gdy chce zrozumieć, czemu kontener chłodniczy trafił do strefy <c>bonded</c>, a nie
    /// <c>reefer</c>: zwykle wygrała reguła o niższym priorytecie.
    /// </summary>
    private static async Task<IResult> ListRulesAsync(
        string facilityId,
        ISlotRepository slots,
        CancellationToken ct)
    {
        var rules = await slots.GetPutawayRulesAsync(facilityId, ct);

        return Results.Json(rules
            .Select(rule => new PutawayRuleResponse(
                rule.RuleId,
                rule.Priority,
                rule.IsoSizeType,
                rule.IsReefer,
                rule.HazardClassCode,
                ToSnakeCase(rule.TargetZoneKind)))
            .ToList());
    }

    /// <summary>
    /// <c>PUT /v1/slots/{slot_id}/block</c> — blokada gniazda. Blokada nie zdejmuje z gniazda
    /// kontenera, który już w nim stoi: uniemożliwia jedynie kolejne rozstawienie, więc zablokowanie
    /// zajętego gniazda jest poprawne i celowe przy otwartej rozbieżności inwentaryzacyjnej.
    /// </summary>
    private static async Task<IResult> SetBlockAsync(
        string slotId,
        SlotBlockRequest request,
        ISlotRepository slots,
        IRequestContext context,
        CancellationToken ct)
    {
        if (request.Blocked && string.IsNullOrWhiteSpace(request.Reason))
        {
            return ErrorMapper.Build(
                "blocked_reason_required",
                StatusCodes.Status422UnprocessableEntity,
                "a slot may not be blocked without a reason",
                context.TraceId,
                retryable: false,
                fields: [new FieldError("reason", "required when is_blocked is true")]);
        }

        var slot = await slots.FindSlotAsync(slotId, ct);
        if (slot is null)
        {
            return ErrorMapper.Build(
                "slot_not_found",
                StatusCodes.Status404NotFound,
                $"slot {slotId} does not exist",
                context.TraceId,
                retryable: false);
        }

        await slots.SetSlotBlockedAsync(slotId, request.Blocked, request.Reason, ct);

        return Results.Json(new SlotResponse(
            slot.SlotId,
            slot.ZoneId,
            slot.SlotCode,
            slot.Aisle,
            slot.Bay,
            slot.Level,
            slot.MaxWeightKg,
            slot.IsPowered,
            slot.TravelCostM,
            request.Blocked,
            request.Blocked ? request.Reason : null));
    }

    /// <summary>
    /// Zamienia nazwę wartości wyliczeniowej na <c>snake_case</c> oczekiwany na drucie —
    /// <c>InboundDock</c> staje się <c>inbound_dock</c>. Odwrotnej konwersji nie ma, bo żadna
    /// z tych końcówek nie przyjmuje rodzaju strefy w żądaniu.
    /// </summary>
    private static string ToSnakeCase(ZoneKind kind) =>
        string.Concat(kind.ToString().Select((c, i) =>
            char.IsUpper(c) && i > 0 ? $"_{char.ToLowerInvariant(c)}" : $"{char.ToLowerInvariant(c)}"));
}
