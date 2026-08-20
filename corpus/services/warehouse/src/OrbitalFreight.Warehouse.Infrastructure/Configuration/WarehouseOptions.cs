using System.ComponentModel.DataAnnotations;

namespace OrbitalFreight.Warehouse.Infrastructure.Configuration;

/// <summary>
/// Odwzorowanie zmiennych środowiskowych na obiekt konfiguracji. Usługa, która czyta zmienną
/// spoza §5 specyfikacji, nie wstaje — <c>ops/validate-env.py</c> sprawdza zestaw w potoku
/// wdrożeniowym, a walidacja adnotacjami poniżej łapie to samo lokalnie, zanim pod wejdzie
/// w pętlę restartów.
/// </summary>
public sealed class WarehouseOptions
{
    /// <summary>Prefiks sekcji konfiguracji; zmienne <c>OF_*</c> są mapowane płasko.</summary>
    public const string SectionName = "OF";

    /// <summary><c>OF_ENVIRONMENT</c>: <c>local</c>, <c>ci</c>, <c>staging</c> albo <c>production</c>.</summary>
    [Required]
    public string Environment { get; init; } = "local";

    /// <summary><c>OF_REGION_CODE</c>: jeden z ośmiu kodów z §0.6.</summary>
    [Required]
    public string RegionCode { get; init; } = default!;

    /// <summary><c>OF_SERVICE_NAME</c>; musi brzmieć dokładnie <c>warehouse-service</c>.</summary>
    [Required]
    public string ServiceName { get; init; } = "warehouse-service";

    /// <summary><c>OF_HTTP_PORT</c>; usługa nie ma powierzchni gRPC, więc <c>OF_GRPC_PORT</c> zostaje nieustawiona.</summary>
    [Range(1024, 65535)]
    public int HttpPort { get; init; } = 8095;

    /// <summary><c>OF_DATABASE_URL</c> — ciąg połączenia z <c>search_path=warehouse</c>.</summary>
    [Required]
    public string DatabaseUrl { get; init; } = default!;

    /// <summary><c>OF_DATABASE_MAX_CONNS</c> — pula na pod, nie na klaster.</summary>
    [Range(1, 500)]
    public int DatabaseMaxConns { get; init; } = 40;

    /// <summary><c>OF_DATABASE_STATEMENT_TIMEOUT_MS</c>.</summary>
    [Range(100, 60_000)]
    public int DatabaseStatementTimeoutMs { get; init; } = 8_000;

    /// <summary><c>OF_KAFKA_BROKERS</c> — lista po przecinku.</summary>
    [Required]
    public string KafkaBrokers { get; init; } = default!;

    /// <summary><c>OF_KAFKA_CONSUMER_GROUP</c>; podbicie sufiksu wymusza odtworzenie tematów od nowa.</summary>
    [Required]
    public string KafkaConsumerGroup { get; init; } = "warehouse-service-v1";

    /// <summary><c>OF_OUTBOX_RELAY_INTERVAL_MS</c>.</summary>
    [Range(50, 10_000)]
    public int OutboxRelayIntervalMs { get; init; } = 250;

    /// <summary><c>OF_SHUTDOWN_GRACE_SECONDS</c>; musi być mniejsze od okresu karencji poda.</summary>
    [Range(1, 120)]
    public int ShutdownGraceSeconds { get; init; } = 25;

    /// <summary><c>OF_IDENTITY_GRPC_ADDR</c>: adres <c>identity.v1.TokenIntrospection/Introspect</c>.</summary>
    [Required]
    public string IdentityGrpcAddr { get; init; } = "identity-service:9081";

    /// <summary><c>OF_IDENTITY_JWKS_URL</c> — klucze do weryfikacji offline.</summary>
    [Required]
    public string IdentityJwksUrl { get; init; } = default!;

    /// <summary><c>OF_IDENTITY_JWKS_GRACE_SECONDS</c>: jak długo wolno ufać kluczom z pamięci, gdy identity-service nie odpowiada.</summary>
    [Range(0, 3600)]
    public int IdentityJwksGraceSeconds { get; init; } = 300;

    /// <summary><c>OF_CONTAINER_REGISTRY_GRPC_ADDR</c>; nazwa jest wspólna dla wszystkich wołających.</summary>
    [Required]
    public string ContainerRegistryGrpcAddr { get; init; } = "container-registry:9083";

    /// <summary>Adres HTTP container-registry; ścieżki skanów i przesyłek są REST-owe.</summary>
    [Required]
    public string ContainerRegistryBaseUrl { get; init; } = "http://container-registry:8083";

    /// <summary><c>OF_GEO_GRPC_ADDR</c>.</summary>
    [Required]
    public string GeoGrpcAddr { get; init; } = "geo-service:9086";

    /// <summary><c>OF_DOCUMENT_BASE_URL</c>.</summary>
    [Required]
    public string DocumentBaseUrl { get; init; } = "http://document-service:8089";

    /// <summary><c>OF_AUDIT_LEDGER_GRPC_ADDR</c>.</summary>
    [Required]
    public string AuditLedgerGrpcAddr { get; init; } = "audit-ledger:9092";

    /// <summary><c>OF_ANALYTICS_BASE_URL</c> — źródło klasyfikacji ABC.</summary>
    [Required]
    public string AnalyticsBaseUrl { get; init; } = "http://analytics-pipeline:8093";

    /// <summary><c>OF_WAREHOUSE_PICK_WAVE_MAX_TASKS</c> — górna granica zadań w jednej fali.</summary>
    [Range(1, 200)]
    public int PickWaveMaxTasks { get; init; } = 40;

    /// <summary><c>OF_WAREHOUSE_TRAVEL_SPEED_MPS</c> — prędkość wózka z ładunkiem.</summary>
    [Range(0.2, 5.0)]
    public double TravelSpeedMps { get; init; } = 1.4;

    /// <summary><c>OF_WAREHOUSE_TWO_OPT_ITERATIONS</c> — ile przebiegów wolno zrobić planerowi trasy.</summary>
    [Range(0, 100)]
    public int TwoOptIterations { get; init; } = 12;

    /// <summary><c>OF_WAREHOUSE_REEFER_SLOT_RESERVE_PCT</c> — jaki udział gniazd zasilanych trzymamy wolny.</summary>
    [Range(0, 90)]
    public int ReeferSlotReservePct { get; init; } = 15;

    /// <summary><c>OF_WAREHOUSE_CYCLE_COUNT_SLOTS_PER_DAY</c> — ile gniazd liczy jedna zmiana.</summary>
    [Range(1, 1000)]
    public int CycleCountSlotsPerDay { get; init; } = 60;

    /// <summary><c>OF_WAREHOUSE_VARIANCE_LOOKBACK_DAYS</c> — okno historii rozbieżności dla metody <c>variance_driven</c>.</summary>
    [Range(1, 365)]
    public int VarianceLookbackDays { get; init; } = 30;

    /// <summary><c>OF_WAREHOUSE_HAZARD_SEGREGATION_RADIUS_BAYS</c> — promień sprawdzania sąsiedztwa ADR.</summary>
    [Range(0, 10)]
    public int HazardSegregationRadiusBays { get; init; } = 1;

    /// <summary><c>OF_WAREHOUSE_IDEMPOTENCY_TTL_HOURS</c>; §7 pkt 5 wymaga co najmniej 24 godzin.</summary>
    [Range(24, 168)]
    public int IdempotencyTtlHours { get; init; } = 24;

    /// <summary>
    /// Numer seryjny „urządzenia”, którym podpisujemy skany zapisywane w container-registry.
    /// Po nim konsument <c>shipment.scanned</c> poznaje własne skany i ich nie przetwarza
    /// ponownie — inaczej potwierdzenie kompletacji wracałoby do nas jako nowe zdarzenie.
    /// </summary>
    public string ScanDeviceSerial => $"wms-{ServiceName}";
}
