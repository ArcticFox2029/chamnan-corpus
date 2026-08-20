// -----------------------------------------------------------------------------------------------
// Najbardziej zewnętrzny element potoku: zamienia każdy niewyłapany wyjątek na kopertę błędu z §0.4.
// Istnieje po to, żeby klient nigdy nie zobaczył stosu wywołań ani pustej odpowiedzi 500 — kod
// błędu jest częścią kontraktu publicznego, a pole retryable steruje ponowieniem po stronie
// terminala w hali.
// -----------------------------------------------------------------------------------------------

using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Api.Errors;

namespace OrbitalFreight.Warehouse.Api.Middleware;

/// <summary>
/// Przechwytuje wyjątki i odpowiada kopertą błędu. Świadomie nie łapie
/// <see cref="OperationCanceledException"/> przy przerwanym połączeniu: klient już odszedł,
/// a zapisywanie takiego zdarzenia jako awarii zaśmiecało wskaźnik błędów przy każdym
/// przeładowaniu tablicy brygadzisty.
/// </summary>
/// <param name="next">Kolejny element potoku.</param>
/// <param name="logger">Dziennik.</param>
public sealed class ErrorEnvelopeMiddleware(RequestDelegate next, ILogger<ErrorEnvelopeMiddleware> logger)
{
    private readonly RequestDelegate _next = next;
    private readonly ILogger<ErrorEnvelopeMiddleware> _logger = logger;

    /// <summary>Obsługuje żądanie.</summary>
    /// <param name="context">Kontekst HTTP.</param>
    public async Task InvokeAsync(HttpContext context)
    {
        try
        {
            await _next(context);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            _logger.LogDebug("client aborted {Method} {Path}", context.Request.Method, context.Request.Path);
        }
        catch (Exception exception)
        {
            var traceId = TraceIdOf(context);

            // Poziom dziennika zależy od tego, czy to nasz błąd, czy błąd wołającego. Wyjątki
            // domenowe (np. no_eligible_slot) są normalnym wynikiem pracy hali, nie awarią.
            if (exception is InvalidOperationException)
            {
                _logger.LogInformation(
                    "rejected {Method} {Path}: {Reason} (trace {TraceId})",
                    context.Request.Method, context.Request.Path, exception.Message, traceId);
            }
            else
            {
                _logger.LogError(
                    exception,
                    "unhandled failure on {Method} {Path} (trace {TraceId})",
                    context.Request.Method, context.Request.Path, traceId);
            }

            if (context.Response.HasStarted)
            {
                // Nagłówki poszły — dopisanie koperty zepsułoby ciało odpowiedzi w połowie.
                // Jedyne, co zostaje, to zerwać połączenie, żeby klient nie uznał obciętej
                // odpowiedzi za kompletną.
                context.Abort();
                return;
            }

            await ErrorMapper.ToResult(exception, traceId).ExecuteAsync(context);
        }
    }

    /// <summary>
    /// Ślad z nagłówka <c>X-OF-Trace-Id</c>, a gdy go brak — identyfikator śladu wygenerowany
    /// przez warstwę wejściową. Koperta bez śladu jest bezużyteczna przy zgłoszeniu awarii.
    /// </summary>
    private static string TraceIdOf(HttpContext context) =>
        context.Request.Headers.TryGetValue("X-OF-Trace-Id", out var header) && header.Count > 0
            ? header[0]!
            : context.TraceIdentifier.Replace("-", string.Empty)[..Math.Min(32, context.TraceIdentifier.Length)];
}
