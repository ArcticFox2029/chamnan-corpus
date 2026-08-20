// -----------------------------------------------------------------------------------------------
// Nocne planowanie inwentaryzacji ciągłej. Raz na dobę, po odświeżeniu widoku
// analytics.mv_container_utilisation_weekly, zakłada plan liczenia na najbliższą zmianę dla każdego
// obiektu obsługiwanego przez ten pod. Dzięki temu brygadzista zastaje rano gotową listę gniazd
// zamiast układać ją ręcznie — a metoda ABC ma świeże dane o rotacji.
// -----------------------------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.CycleCounting;
using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Infrastructure.Maintenance;

/// <summary>
/// Zadanie okresowe planujące liczenia. Uruchamia się o 04:00 czasu UTC, czyli po odświeżeniu
/// widoków materializowanych przez analytics-pipeline (<c>OF_ANALYTICS_MV_REFRESH_CRON</c> to
/// <c>15 3 * * *</c>) — wcześniejszy start czytał wczorajszą rotację i klasyfikacja ABC systematycznie
/// spóźniała się o dobę.
/// </summary>
/// <param name="scopes">Fabryka zakresów dla usług zakresowych.</param>
/// <param name="options">Konfiguracja usługi.</param>
/// <param name="clock">Zegar; w testach podmieniany na sterowany.</param>
/// <param name="logger">Dziennik.</param>
public sealed class CycleCountPlanningWorker(
    IServiceScopeFactory scopes,
    IOptions<WarehouseOptions> options,
    TimeProvider clock,
    ILogger<CycleCountPlanningWorker> logger) : BackgroundService
{
    /// <summary>Godzina UTC uruchomienia planowania.</summary>
    private static readonly TimeOnly RunAt = new(4, 0);

    private readonly IServiceScopeFactory _scopes = scopes;
    private readonly WarehouseOptions _options = options.Value;
    private readonly TimeProvider _clock = clock;
    private readonly ILogger<CycleCountPlanningWorker> _logger = logger;

    /// <inheritdoc />
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            var delay = UntilNextRun(_clock.GetUtcNow());
            _logger.LogInformation("next cycle-count planning pass in {Delay}", delay);

            await Task.Delay(delay, _clock, stoppingToken);

            try
            {
                await PlanAsync(stoppingToken);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // Nieudane planowanie nie może zatrzymać pętli — brygadzista założy plan ręcznie
                // przez POST /v1/cycle-counts, a my spróbujemy ponownie następnej doby.
                _logger.LogError(exception, "cycle-count planning pass failed");
            }
        }
    }

    /// <summary>Zakłada plan liczenia dla każdego obiektu, który ma choć jedno zajęte gniazdo.</summary>
    private async Task PlanAsync(CancellationToken ct)
    {
        using var scope = _scopes.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<WarehouseDbContext>();
        var counts = scope.ServiceProvider.GetRequiredService<CycleCountService>();

        var facilities = await db.Zones
            .Select(z => new { z.FacilityId, z.TenantId, z.RegionCode })
            .Distinct()
            .ToListAsync(ct);

        var scheduledOn = DateOnly.FromDateTime(_clock.GetUtcNow().UtcDateTime);
        var planned = 0;

        foreach (var facility in facilities)
        {
            // Rezydencja danych (§7 pkt 7): pod z jednego regionu nie planuje pracy w innym,
            // nawet gdyby wiersze były widoczne w replice.
            if (facility.RegionCode != _options.RegionCode) continue;

            using var context = AmbientRequestContext.Enter(
                facility.TenantId,
                Guid.NewGuid().ToString("N"),
                facility.RegionCode,
                "service",
                $"svc:{_options.ServiceName}");

            try
            {
                var plan = await counts.CreatePlanAsync(
                    new CreateCountPlanCommand(
                        facility.FacilityId,
                        facility.TenantId,
                        scheduledOn,
                        CycleCountMethod.Abc,
                        _options.VarianceLookbackDays,
                        // Ziarno wyprowadzone z daty i obiektu, żeby powtórzone uruchomienie tego
                        // samego dnia dało ten sam plan zamiast drugiej, rozbieżnej listy.
                        Seed: HashCode.Combine(facility.FacilityId, scheduledOn.DayNumber)),
                    ct);

                planned++;
                _logger.LogInformation(
                    "planned cycle count {PlanId} for facility {FacilityId} on {Date}",
                    plan.PlanId, facility.FacilityId, scheduledOn);
            }
            catch (CycleCountFailedException exception) when (exception.Message.StartsWith("facility_empty"))
            {
                // Pusty obiekt to nie awaria: magazyn sezonowy bywa pusty przez pół kwartału.
                _logger.LogDebug("facility {FacilityId} is empty, nothing to count", facility.FacilityId);
            }
        }

        _logger.LogInformation("cycle-count planning finished: {Planned} plan(s) created", planned);
    }

    /// <summary>Czas do najbliższej godziny uruchomienia.</summary>
    /// <param name="now">Bieżąca chwila UTC.</param>
    internal static TimeSpan UntilNextRun(DateTimeOffset now)
    {
        var todayAt = new DateTimeOffset(now.Year, now.Month, now.Day, RunAt.Hour, RunAt.Minute, 0, TimeSpan.Zero);
        return todayAt > now ? todayAt - now : todayAt.AddDays(1) - now;
    }
}
