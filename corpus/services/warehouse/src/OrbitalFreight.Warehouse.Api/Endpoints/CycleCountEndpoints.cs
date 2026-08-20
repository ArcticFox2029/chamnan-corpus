using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Api.Contracts;
using OrbitalFreight.Warehouse.Api.Errors;
using OrbitalFreight.Warehouse.Application.CycleCounting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Api.Endpoints;

/// <summary>
/// Końcówki inwentaryzacji ciągłej: układanie planu na dzień roboczy, przyjmowanie wyników
/// z terminali, przegląd otwartych rozbieżności i ich zamykanie. Każda rozbieżność jest przed
/// zapisem odkładana w <c>platform.audit_ledger_entries</c> przez audit-ledger.
/// </summary>
public static class CycleCountEndpoints
{
    /// <summary>Podpina końcówki inwentaryzacji pod ścieżkę <c>/v1</c>.</summary>
    public static IEndpointRouteBuilder MapCycleCountEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/v1/cycle-counts").WithTags("cycle-count");

        group.MapPost("/plans", CreatePlanAsync)
            .WithName("CreateCountPlan")
            .WithSummary("Układa plan liczenia na wskazany dzień roboczy");

        group.MapPost("/tasks/{countId}/submit", SubmitCountAsync)
            .WithName("SubmitCount")
            .WithSummary("Przyjmuje wynik liczenia jednego gniazda");

        group.MapGet("/variances", ListVariancesAsync)
            .WithName("ListVariances")
            .WithSummary("Otwarte rozbieżności obiektu");

        group.MapPost("/variances/{varianceId}/resolve", ResolveVarianceAsync)
            .WithName("ResolveVariance")
            .WithSummary("Zamyka rozbieżność notatką i odblokowuje gniazdo");

        return app;
    }

    /// <summary><c>POST /v1/cycle-counts/plans</c> — plan na dzień roboczy.</summary>
    private static async Task<IResult> CreatePlanAsync(
        CreateCountPlanRequest request,
        CycleCountService counts,
        IRequestContext context,
        IOptions<WarehouseOptions> options,
        CancellationToken ct)
    {
        CycleCountMethod method;

        try
        {
            method = ParseMethod(request.Method);
        }
        catch (ArgumentException ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }

        // Ziarno wywodzimy z obiektu i daty, a nie z zegara: dwa wywołania tego samego dnia dla
        // tego samego obiektu mają dać ten sam plan, inaczej powtórka żądania po utracie
        // odpowiedzi wygenerowałaby drugi, inny plan.
        var seed = HashCode.Combine(request.FacilityId, request.ScheduledOn);

        var command = new CreateCountPlanCommand(
            request.FacilityId,
            context.TenantId,
            request.ScheduledOn,
            method,
            options.Value.VarianceLookbackDays,
            seed);

        try
        {
            var plan = await counts.CreatePlanAsync(command, ct);

            return Results.Created(
                $"/v1/cycle-counts/plans/{plan.PlanId}",
                new CountPlanResponse(
                    plan.PlanId,
                    plan.FacilityId,
                    request.Method,
                    plan.ScheduledOn,
                    plan.SlotCount));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary>
    /// <c>POST /v1/cycle-counts/tasks/{countId}/submit</c> — wynik liczenia. Zdjęcie przychodzi
    /// w base64 i jest przekazywane do document-service; magazyn nie przechowuje bajtów u siebie.
    /// </summary>
    private static async Task<IResult> SubmitCountAsync(
        string countId,
        SubmitCountRequest request,
        CycleCountService counts,
        IRequestContext context,
        CancellationToken ct)
    {
        ReadOnlyMemory<byte> photo = ReadOnlyMemory<byte>.Empty;

        if (!string.IsNullOrEmpty(request.EvidencePhotoBase64))
        {
            try
            {
                photo = Convert.FromBase64String(request.EvidencePhotoBase64);
            }
            catch (FormatException)
            {
                return ErrorMapper.Build(
                    "invalid_evidence_photo",
                    StatusCodes.Status400BadRequest,
                    "evidence_photo_base64 is not valid base64",
                    context.TraceId,
                    retryable: false,
                    fields: [new FieldError("evidence_photo_base64", "malformed")]);
            }
        }

        var command = new SubmitCountCommand(
            countId,
            request.ObservedContainerId,
            context.ActorId,
            request.CountedAt,
            request.DamageReported,
            request.SealMatches,
            photo);

        try
        {
            var variance = await counts.SubmitCountAsync(command, ct);

            // Brak rozbieżności to 204: liczenie zapisane, nie ma czego pokazywać.
            return variance is null
                ? Results.NoContent()
                : Results.Ok(ToResponse(variance));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary><c>GET /v1/cycle-counts/variances</c> — ekran „do wyjaśnienia”.</summary>
    private static async Task<IResult> ListVariancesAsync(
        string facilityId,
        string? cursor,
        int? limit,
        ICycleCountRepository counts,
        IRequestContext context,
        CancellationToken ct)
    {
        var effectiveLimit = Math.Clamp(limit ?? 50, 1, 200);

        try
        {
            var page = await counts.ListOpenVariancesAsync(facilityId, cursor, effectiveLimit, ct);
            var items = page.Items.Select(ToResponse).ToList();

            return Results.Ok(new CursorPageResponse<VarianceResponse>(items, page.NextCursor));
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    /// <summary><c>POST /v1/cycle-counts/variances/{varianceId}/resolve</c> — zamknięcie sprawy.</summary>
    private static async Task<IResult> ResolveVarianceAsync(
        string varianceId,
        ResolveVarianceRequest request,
        CycleCountService counts,
        IRequestContext context,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.Note))
        {
            return ErrorMapper.Build(
                "resolution_note_required",
                StatusCodes.Status400BadRequest,
                "closing a variance requires a note for internal control",
                context.TraceId,
                retryable: false,
                fields: [new FieldError("note", "empty")]);
        }

        try
        {
            await counts.ResolveVarianceAsync(varianceId, request.SlotId, request.Note, context.ActorId, ct);
            return Results.NoContent();
        }
        catch (Exception ex)
        {
            return ErrorMapper.ToResult(ex, context.TraceId);
        }
    }

    private static VarianceResponse ToResponse(CountVariance variance) => new(
        variance.VarianceId,
        variance.SlotId,
        variance.Kind switch
        {
            VarianceKind.Missing => "missing",
            VarianceKind.Unexpected => "unexpected",
            VarianceKind.WrongSlot => "wrong_slot",
            VarianceKind.Damaged => "damaged",
            VarianceKind.SealMismatch => "seal_mismatch",
            _ => "unknown"
        },
        variance.ExpectedContainerId,
        variance.ObservedContainerId,
        variance.EvidenceDocumentId,
        variance.LedgerEntryId,
        variance.OpenedAt);

    private static CycleCountMethod ParseMethod(string value) => value switch
    {
        "abc" => CycleCountMethod.Abc,
        "random" => CycleCountMethod.Random,
        "variance_driven" => CycleCountMethod.VarianceDriven,
        "blind_recount" => CycleCountMethod.BlindRecount,
        _ => throw new ArgumentException($"unknown cycle count method '{value}'", nameof(value))
    };
}
