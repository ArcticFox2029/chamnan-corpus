// -----------------------------------------------------------------------------------------------
// Rdzeń kompozycji: odczyt zmiennych OF_* z §5, kontekst bazy, repozytoria, polityki domenowe
// i usługi aplikacyjne. Plik jest jedynym miejscem, w którym implementacja poznaje swój interfejs —
// żadna klasa poniżej nie tworzy zależności sama z siebie, dzięki czemu test podmienia dowolny
// element bez modyfikowania kodu produkcyjnego.
// -----------------------------------------------------------------------------------------------

using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Application.CycleCounting;
using OrbitalFreight.Warehouse.Application.Picking;
using OrbitalFreight.Warehouse.Application.Slotting;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Domain.CycleCounting;
using OrbitalFreight.Warehouse.Domain.Picking;
using OrbitalFreight.Warehouse.Domain.Slotting;
using OrbitalFreight.Warehouse.Infrastructure;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Health;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Repositories;

namespace OrbitalFreight.Warehouse.Api.DependencyInjection;

/// <summary>
/// Rejestracje wspólne dla wszystkich trybów pracy procesu — obsługi HTTP i pętli konsumentów.
/// </summary>
public static class WarehouseModule
{
    /// <summary>
    /// Przepisuje zmienne środowiskowe z §5 na klucze konfiguracji. Odwzorowanie jest jawne,
    /// bo <c>OF_DATABASE_MAX_CONNS</c> nie odwzorowuje się automatycznie na
    /// <see cref="WarehouseOptions.DatabaseMaxConns"/>, a milczące pominięcie zmiennej kończyło się
    /// wcześniej podem, który wstawał z pulą czterdziestu połączeń zamiast czterech.
    /// </summary>
    /// <returns>Pary klucz-wartość gotowe dla dostawcy konfiguracji w pamięci.</returns>
    public static IEnumerable<KeyValuePair<string, string?>> ReadPlatformEnvironment()
    {
        string[] names =
        [
            "OF_ENVIRONMENT", "OF_REGION_CODE", "OF_SERVICE_NAME", "OF_LOG_LEVEL", "OF_LOG_FORMAT",
            "OF_HTTP_PORT", "OF_DATABASE_URL", "OF_DATABASE_MAX_CONNS", "OF_DATABASE_STATEMENT_TIMEOUT_MS",
            "OF_KAFKA_BROKERS", "OF_KAFKA_CONSUMER_GROUP", "OF_OTEL_EXPORTER_ENDPOINT", "OF_OTEL_SAMPLE_RATIO",
            "OF_IDENTITY_GRPC_ADDR", "OF_IDENTITY_JWKS_URL", "OF_IDENTITY_JWKS_GRACE_SECONDS",
            "OF_OUTBOX_RELAY_INTERVAL_MS", "OF_SHUTDOWN_GRACE_SECONDS",
            "OF_CONTAINER_REGISTRY_GRPC_ADDR", "OF_CONTAINER_REGISTRY_BASE_URL", "OF_GEO_GRPC_ADDR",
            "OF_DOCUMENT_BASE_URL", "OF_AUDIT_LEDGER_GRPC_ADDR", "OF_ANALYTICS_BASE_URL",
            "OF_WAREHOUSE_PICK_WAVE_MAX_TASKS", "OF_WAREHOUSE_TRAVEL_SPEED_MPS",
            "OF_WAREHOUSE_TWO_OPT_ITERATIONS", "OF_WAREHOUSE_REEFER_SLOT_RESERVE_PCT",
            "OF_WAREHOUSE_CYCLE_COUNT_SLOTS_PER_DAY", "OF_WAREHOUSE_VARIANCE_LOOKBACK_DAYS",
            "OF_WAREHOUSE_HAZARD_SEGREGATION_RADIUS_BAYS", "OF_WAREHOUSE_IDEMPOTENCY_TTL_HOURS"
        ];

        foreach (var name in names)
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (value is null) continue;

            // OF_DATABASE_MAX_CONNS -> OF:DatabaseMaxConns. Człon WAREHOUSE_ w zmiennych własnych
            // usługi jest pomijany, bo nazwa usługi nie powtarza się we właściwościach — inaczej
            // OF_WAREHOUSE_TRAVEL_SPEED_MPS szukałoby właściwości WarehouseTravelSpeedMps.
            var bare = name["OF_".Length..];
            if (bare.StartsWith("WAREHOUSE_", StringComparison.Ordinal))
            {
                bare = bare["WAREHOUSE_".Length..];
            }

            var property = string.Concat(
                bare.Split('_').Select(part =>
                    string.Concat(char.ToUpperInvariant(part[0]), part[1..].ToLowerInvariant())));

            yield return new KeyValuePair<string, string?>($"{WarehouseOptions.SectionName}:{property}", value);
        }
    }

    /// <summary>Podpina i waliduje <see cref="WarehouseOptions"/>.</summary>
    /// <param name="services">Kolekcja usług.</param>
    /// <param name="configuration">Konfiguracja zbudowana z <see cref="ReadPlatformEnvironment"/>.</param>
    public static IServiceCollection AddWarehouseConfiguration(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        services
            .AddOptions<WarehouseOptions>()
            .Bind(configuration.GetSection(WarehouseOptions.SectionName))
            .ValidateDataAnnotations()
            .Validate(
                options => RegionCodes.Contains(options.RegionCode),
                "OF_REGION_CODE must be one of the eight region codes in §0.6")
            .Validate(
                options => options.ServiceName == "warehouse-service",
                "OF_SERVICE_NAME must be exactly 'warehouse-service'")
            .ValidateOnStart();

        return services;
    }

    /// <summary>Rejestruje bazę, repozytoria, polityki domenowe i usługi aplikacyjne.</summary>
    /// <param name="services">Kolekcja usług.</param>
    public static IServiceCollection AddWarehouseCore(this IServiceCollection services)
    {
        services.AddDbContext<WarehouseDbContext>((provider, db) =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;

            db.UseNpgsql(options.DatabaseUrl, npgsql =>
            {
                npgsql.CommandTimeout(options.DatabaseStatementTimeoutMs / 1000);
                npgsql.MigrationsHistoryTable("__ef_migrations", "warehouse");
            });

            // Śledzenie encji jest wyłączone domyślnie, bo repozytoria zwracają rekordy domenowe
            // i nikt poza nimi nie zapisuje przez kontekst — a włączone śledzenie zatrzymywało
            // w pamięci całe strony gniazd czytane przy planowaniu fali.
            db.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
        });

        services.AddScoped<ISlotRepository, SlotRepository>();
        services.AddScoped<IPickWaveRepository, PickWaveRepository>();
        services.AddScoped<ICycleCountRepository, CycleCountRepository>();
        services.AddScoped<IWarehouseUnitOfWork, WarehouseUnitOfWork>();
        services.AddScoped<IOutboxWriter, OutboxWriter>();
        services.AddScoped<IEventDeduplicationStore, PostgresEventDeduplicationStore>();

        // Kontekst żądania jest bezstanowy — całe jego państwo siedzi w AsyncLocal — więc może być
        // pojedynczy, mimo że wartości są różne dla każdego żądania i każdej wiadomości.
        services.AddSingleton<IRequestContext, AmbientRequestContext>();
        services.AddSingleton<IIdentifierFactory, UlidIdentifierFactory>();
        services.AddSingleton(TimeProvider.System);

        services.AddSingleton(provider =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
            return SlottingWeights.Default with
            {
                PoweredReserveRatio = options.ReeferSlotReservePct / 100.0
            };
        });

        services.AddSingleton(provider =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
            return PickPathSettings.Default with
            {
                TravelSpeedMps = options.TravelSpeedMps,
                TwoOptIterations = options.TwoOptIterations
            };
        });

        services.AddSingleton(provider =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
            return CycleCountSettings.Default with
            {
                MaxSlotsPerDay = options.CycleCountSlotsPerDay
            };
        });

        services.AddSingleton<SlottingPolicy>();
        services.AddSingleton<PickPathPlanner>();
        services.AddSingleton<CycleCountScheduler>();

        // Sonda gotowości jest zakresowa, bo trzyma kontekst bazy; /readyz i /metrics
        // są jedynymi jej wołającymi.
        services.AddScoped<WarehouseReadinessProbe>();

        services.AddScoped<PutawayService>();
        services.AddScoped<PickWaveService>();
        services.AddScoped<CycleCountService>();

        return services;
    }

    /// <summary>Zamknięta lista kodów regionów z §0.6; niczego poza nią nie wolno przyjąć.</summary>
    private static readonly HashSet<string> RegionCodes =
    [
        "eu-west", "eu-central", "na-east", "na-west",
        "apac-sg", "apac-jp", "latam-br", "mea-ae"
    ];
}
