// -----------------------------------------------------------------------------------------------
// Cztery końcówki, które §3.15 nakazuje każdej usłudze na platformie: liveness, readiness, metryki
// i wersja. Nie noszą prefiksu /v1, nie wymagają nagłówków z §0.3 i nie przechodzą przez kontrolę
// najemcy — odpytuje je kubelet i Prometheus, a nie klient z tokenem.
// -----------------------------------------------------------------------------------------------

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Health;

namespace OrbitalFreight.Warehouse.Api.Endpoints;

/// <summary>
/// Końcówki operacyjne. Rozdział na <c>/healthz</c> i <c>/readyz</c> jest istotny: pierwsza nie
/// dotyka bazy, więc chwilowa niedostępność Postgresa nie powoduje restartu poda, który po
/// restarcie i tak zastanie tę samą bazę.
/// </summary>
public static class OperationalEndpoints
{
    /// <summary>Numer migracji, której oczekuje ta wersja kodu; sprawdzany przy starcie.</summary>
    private const int ExpectedMigration = 41;

    /// <summary>Podpina końcówki operacyjne w korzeniu ścieżki.</summary>
    /// <param name="app">Budowniczy tras.</param>
    public static IEndpointRouteBuilder MapOperationalEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/healthz", () => Results.Text("ok", "text/plain"))
            .WithName("Liveness")
            .ExcludeFromDescription();

        app.MapGet("/readyz", ReadinessAsync)
            .WithName("Readiness")
            .ExcludeFromDescription();

        app.MapGet("/metrics", MetricsAsync)
            .WithName("Metrics")
            .ExcludeFromDescription();

        app.MapGet("/version", Version)
            .WithName("Version")
            .ExcludeFromDescription();

        return app;
    }

    /// <summary>
    /// <c>GET /readyz</c> — sprawdza bazę, brokera i identity-service. Niedostępność
    /// identity-service nie jest sama w sobie powodem odmowy gotowości: przez
    /// <c>OF_IDENTITY_JWKS_GRACE_SECONDS</c> wolno nam weryfikować podpis lokalnie z pamięci,
    /// więc dopóki karencja trwa, raportujemy stan <c>degraded</c>, a nie 503.
    /// </summary>
    private static async Task<IResult> ReadinessAsync(
        WarehouseReadinessProbe probe,
        CancellationToken ct)
    {
        var report = await probe.CheckAsync(ct);

        return report.IsReady
            ? Results.Json(report, statusCode: StatusCodes.Status200OK)
            : Results.Json(report, statusCode: StatusCodes.Status503ServiceUnavailable);
    }

    /// <summary>
    /// <c>GET /metrics</c> — ekspozycja w formacie Prometheusa. Liczniki hali są tu, a nie
    /// w osobnej usłudze, bo wskaźnik zajętości gniazd musi pochodzić z tego samego odczytu,
    /// który obsługuje ruch — inaczej rozjeżdża się z tym, co widzi dyspozytor.
    /// </summary>
    private static async Task<IResult> MetricsAsync(WarehouseReadinessProbe probe, CancellationToken ct)
    {
        var snapshot = await probe.CollectMetricsAsync(ct);

        var body = string.Join('\n',
        [
            "# HELP warehouse_slots_total Liczba gniazd w obiektach obsługiwanych przez ten pod.",
            "# TYPE warehouse_slots_total gauge",
            $"warehouse_slots_total {snapshot.SlotsTotal}",
            "# HELP warehouse_slots_occupied Gniazda z aktywnym rozstawieniem.",
            "# TYPE warehouse_slots_occupied gauge",
            $"warehouse_slots_occupied {snapshot.SlotsOccupied}",
            "# HELP warehouse_pick_waves_open Fale kompletacyjne nierozliczone.",
            "# TYPE warehouse_pick_waves_open gauge",
            $"warehouse_pick_waves_open {snapshot.OpenPickWaves}",
            "# HELP warehouse_count_variances_open Rozbieżności inwentaryzacyjne bez rozstrzygnięcia.",
            "# TYPE warehouse_count_variances_open gauge",
            $"warehouse_count_variances_open {snapshot.OpenVariances}",
            "# HELP warehouse_outbox_pending Wiersze skrzynki nadawczej czekające na publikację.",
            "# TYPE warehouse_outbox_pending gauge",
            $"warehouse_outbox_pending {snapshot.OutboxPending}",
            string.Empty
        ]);

        return Results.Text(body, "text/plain; version=0.0.4");
    }

    /// <summary>
    /// <c>GET /version</c> — skrót budowy, wersja semantyczna i numer migracji, której kod oczekuje.
    /// Ostatnia pozycja bywa ważniejsza od dwóch pierwszych przy wycofywaniu wdrożenia.
    /// </summary>
    private static IResult Version(IOptions<WarehouseOptions> options) =>
        Results.Json(new
        {
            service = options.Value.ServiceName,
            semver = ThisAssembly.Semver,
            build_sha = ThisAssembly.CommitSha,
            expected_migration = ExpectedMigration,
            region_code = options.Value.RegionCode
        });
}

/// <summary>
/// Stałe wstrzykiwane przy budowaniu przez <c>dotnet build -p:CommitSha=…</c>. Wartości domyślne
/// obowiązują wyłącznie przy budowie lokalnej — potok wdrożeniowy zawsze je nadpisuje.
/// </summary>
internal static class ThisAssembly
{
    /// <summary>Wersja semantyczna wydania.</summary>
    public const string Semver = "1.6.2";

    /// <summary>Skrót rewizji, z której powstał obraz.</summary>
    public const string CommitSha = "0000000000000000000000000000000000000000";
}
