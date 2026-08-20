using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Http;
using OrbitalFreight.Warehouse.Application.CycleCounting;
using OrbitalFreight.Warehouse.Application.Picking;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Api.Errors;

/// <summary>
/// Koperta błędu w kształcie z §0.4 — jednakowa dla całej platformy, bo klienci (konsola,
/// aplikacja inspector-android, partner-portal-api) mają jeden parser na wszystkie usługi.
/// Pole <c>code</c> jest częścią kontraktu publicznego i nie wolno go zmieniać bez wersjonowania,
/// a <c>retryable</c> steruje wycofywaniem po stronie klienta.
/// </summary>
/// <param name="Code">Kod w <c>snake_case</c>, np. <c>slot_occupied</c>.</param>
/// <param name="HttpStatus">Status HTTP powtórzony w ciele, żeby dało się go zalogować z samego ciała.</param>
/// <param name="Message">Zdanie po angielsku dla operatora; nie jest przeznaczone dla użytkownika końcowego.</param>
/// <param name="TraceId">Ślad W3C z <c>X-OF-Trace-Id</c>.</param>
/// <param name="Retryable">Czy powtórzenie tego samego żądania ma sens.</param>
/// <param name="Fields">Wskazania na konkretne pola żądania.</param>
public sealed record ErrorBody(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("http_status")] int HttpStatus,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("trace_id")] string TraceId,
    [property: JsonPropertyName("retryable")] bool Retryable,
    [property: JsonPropertyName("fields")] IReadOnlyList<FieldError>? Fields);

/// <summary>Wskazanie na pole żądania, które nie przeszło walidacji.</summary>
/// <param name="Path">Ścieżka w ciele żądania, np. <c>containers[0].seal_number</c>.</param>
/// <param name="Reason">Powód w <c>snake_case</c>, np. <c>immutable</c>.</param>
public sealed record FieldError(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("reason")] string Reason);

/// <summary>Opakowanie zewnętrzne — ciało odpowiedzi ma jedno pole <c>error</c>.</summary>
/// <param name="Error">Właściwa treść błędu.</param>
public sealed record ErrorEnvelope([property: JsonPropertyName("error")] ErrorBody Error);

/// <summary>
/// Tłumaczy wyjątki warstwy aplikacyjnej na koperty błędu. Mapowanie jest w jednym miejscu,
/// bo każdy kod przyczyny ma dokładnie jeden status HTTP i jedną odpowiedź na pytanie
/// „czy warto ponowić” — rozproszenie tego po końcówkach kończyło się tym, że ten sam
/// <c>no_eligible_slot</c> wracał raz jako 409, raz jako 422.
/// </summary>
public static class ErrorMapper
{
    /// <summary>Buduje odpowiedź błędu dla wyjątku.</summary>
    /// <param name="exception">Wyjątek z warstwy aplikacyjnej albo domenowej.</param>
    /// <param name="traceId">Ślad bieżącego żądania.</param>
    /// <returns>Wynik gotowy do zwrócenia z końcówki minimalnego API.</returns>
    public static IResult ToResult(Exception exception, string traceId) => exception switch
    {
        SlotOccupiedException ex => Build(
            "slot_occupied",
            StatusCodes.Status409Conflict,
            $"slot {ex.SlotId} is already occupied by {ex.OccupyingContainerId}",
            traceId,
            retryable: true),

        PutawayFailedException ex => Build(
            ex.Code,
            StatusFor(ex.Code),
            ex.Message,
            traceId,
            retryable: ex.Code == "no_eligible_slot"),

        PickWaveFailedException ex => Build(
            ex.Code,
            StatusFor(ex.Code),
            ex.Message,
            traceId,
            retryable: false),

        CycleCountFailedException ex => Build(
            ex.Code,
            StatusFor(ex.Code),
            ex.Message,
            traceId,
            retryable: false),

        ArgumentException ex => Build(
            "invalid_argument",
            StatusCodes.Status400BadRequest,
            ex.Message,
            traceId,
            retryable: false,
            fields: ex.ParamName is null ? null : [new FieldError(ex.ParamName, "invalid")]),

        OperationCanceledException => Build(
            "request_cancelled",
            StatusCodes.Status499ClientClosedRequest,
            "the client closed the connection before the request completed",
            traceId,
            retryable: false),

        // Wszystko, czego nie rozpoznajemy, jest błędem naszym, a nie klienta — i wolno je
        // ponowić, bo najczęściej stoi za tym chwilowa niedostępność bazy albo usługi zależnej.
        _ => Build(
            "internal_error",
            StatusCodes.Status500InternalServerError,
            "unexpected failure in warehouse-service",
            traceId,
            retryable: true)
    };

    /// <summary>Buduje kopertę wprost, z pominięciem wyjątku — dla walidacji w końcówkach.</summary>
    public static IResult Build(
        string code,
        int status,
        string message,
        string traceId,
        bool retryable,
        IReadOnlyList<FieldError>? fields = null) =>
        Results.Json(
            new ErrorEnvelope(new ErrorBody(code, status, message, traceId, retryable, fields)),
            statusCode: status);

    private static int StatusFor(string code) => code switch
    {
        "container_not_found" or "shipment_not_found" or "wave_not_found"
            or "task_not_found" or "count_not_found" => StatusCodes.Status404NotFound,

        "container_already_placed" or "wave_not_releasable" => StatusCodes.Status409Conflict,

        "no_eligible_slot" or "nothing_to_pick" or "facility_empty"
            or "no_slots_selected" => StatusCodes.Status409Conflict,

        _ => StatusCodes.Status422UnprocessableEntity
    };
}

/// <summary>Statusy HTTP spoza standardowego zestawu ASP.NET Core.</summary>
internal static class StatusCodesExtensions
{
    /// <summary>499 — klient zamknął połączenie. Nginx w warstwie wejściowej używa tego samego kodu.</summary>
    public const int Status499ClientClosedRequest = 499;
}
