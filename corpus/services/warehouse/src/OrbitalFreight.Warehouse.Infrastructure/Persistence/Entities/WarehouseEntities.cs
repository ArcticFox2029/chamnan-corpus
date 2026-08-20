using System;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

/// <summary>
/// Encje trwałe odwzorowujące jeden do jednego wiersze schematu <c>warehouse</c>. Świadomie są
/// osobnymi typami niż rekordy z <c>OrbitalFreight.Warehouse.Domain.Model</c>: encja ma pola
/// zmienne, żeby EF Core mógł śledzić zmiany, a domena pracuje na niemutowalnych rekordach.
/// Tłumaczeniem między nimi zajmują się repozytoria i nic poza nimi.
/// </summary>
public class ZoneEntity
{
    /// <summary>Klucz główny, prefiks <c>wzn_</c>.</summary>
    public string ZoneId { get; set; } = default!;

    /// <summary>Logiczny klucz obcy do <c>freight.facilities</c>.</summary>
    public string FacilityId { get; set; } = default!;

    /// <summary>Logiczny klucz obcy do <c>identity.tenants</c>.</summary>
    public string TenantId { get; set; } = default!;

    /// <summary>Rodzaj strefy zapisany jako tekst w <c>snake_case</c>.</summary>
    public string Kind { get; set; } = default!;

    /// <summary>Dolna granica koperty temperaturowej, <c>NUMERIC(5,2)</c>.</summary>
    public decimal? TemperatureMinC { get; set; }

    /// <summary>Górna granica koperty temperaturowej.</summary>
    public decimal? TemperatureMaxC { get; set; }

    /// <summary>Czy w strefie są gniazda zasilane.</summary>
    public bool HasPoweredSlots { get; set; }

    /// <summary>Logiczny klucz obcy do <c>geo.geofences</c>.</summary>
    public string GeofenceId { get; set; } = default!;

    /// <summary>Kod regionu z §0.6.</summary>
    public string RegionCode { get; set; } = default!;

    /// <summary>Gniazda strefy.</summary>
    public ICollection<SlotEntity> Slots { get; set; } = new List<SlotEntity>();
}

/// <summary>Wiersz tabeli <c>warehouse.slots</c>.</summary>
public class SlotEntity
{
    /// <summary>Klucz główny, prefiks <c>slt_</c>.</summary>
    public string SlotId { get; set; } = default!;

    /// <summary>Strefa nadrzędna.</summary>
    public string ZoneId { get; set; } = default!;

    /// <summary>Nawigacja do strefy; ładowana tylko tam, gdzie potrzebna jest koperta temperaturowa.</summary>
    public ZoneEntity? Zone { get; set; }

    /// <summary>Etykieta czytana skanerem.</summary>
    public string SlotCode { get; set; } = default!;

    /// <summary>Alejka.</summary>
    public short Aisle { get; set; }

    /// <summary>Zatoka.</summary>
    public short Bay { get; set; }

    /// <summary>Poziom regału.</summary>
    public short Level { get; set; }

    /// <summary>Nośność w kilogramach.</summary>
    public int MaxWeightKg { get; set; }

    /// <summary>Czy gniazdo ma zasilanie.</summary>
    public bool IsPowered { get; set; }

    /// <summary>Odległość od rampy wydań w metrach.</summary>
    public int TravelCostM { get; set; }

    /// <summary>Blokada gniazda.</summary>
    public bool IsBlocked { get; set; }

    /// <summary>Powód blokady w <c>snake_case</c>.</summary>
    public string? BlockedReason { get; set; }

    /// <summary>Znacznik utworzenia.</summary>
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>Wycofanie gniazda z użycia.</summary>
    public DateTimeOffset? RetiredAt { get; set; }
}

/// <summary>
/// Wiersz tabeli <c>warehouse.slot_placements</c>. Kolumna <c>active_period</c> jest generowana
/// przez bazę (<c>GENERATED ALWAYS AS tstzrange(placed_at, removed_at, '[)') STORED</c>) i to na
/// niej stoi ograniczenie wykluczające, które nie pozwala wstawić dwóch kontenerów do jednego
/// gniazda — ten sam wzorzec, co w <c>fleet.vehicle_assignments</c>.
/// </summary>
public class PlacementEntity
{
    /// <summary>Klucz główny, prefiks <c>plc_</c>.</summary>
    public string PlacementId { get; set; } = default!;

    /// <summary>Gniazdo.</summary>
    public string SlotId { get; set; } = default!;

    /// <summary>Kontener z <c>freight.containers</c>.</summary>
    public string ContainerId { get; set; } = default!;

    /// <summary>Przesyłka z <c>freight.shipments</c>; pusta dla pustego kontenera.</summary>
    public string? ShipmentId { get; set; }

    /// <summary>Masa brutto w chwili odstawienia.</summary>
    public int GrossKg { get; set; }

    /// <summary>Klasa ADR z <c>freight.hazard_classes</c>.</summary>
    public string? HazardClassCode { get; set; }

    /// <summary>Czy ładunek wymaga zasilania.</summary>
    public bool RequiresPower { get; set; }

    /// <summary>Początek okresu zajętości.</summary>
    public DateTimeOffset PlacedAt { get; set; }

    /// <summary>Koniec okresu zajętości.</summary>
    public DateTimeOffset? RemovedAt { get; set; }
}

/// <summary>Wiersz tabeli <c>warehouse.putaway_rules</c>.</summary>
public class PutawayRuleEntity
{
    /// <summary>Klucz główny, prefiks <c>wpr_</c>.</summary>
    public string RuleId { get; set; } = default!;

    /// <summary>Obiekt, którego reguła dotyczy.</summary>
    public string FacilityId { get; set; } = default!;

    /// <summary>Priorytet; niższy wygrywa.</summary>
    public short Priority { get; set; }

    /// <summary>Filtr po typie ISO kontenera.</summary>
    public string? IsoSizeType { get; set; }

    /// <summary>Filtr po agregacie chłodniczym.</summary>
    public bool? IsReefer { get; set; }

    /// <summary>Filtr po klasie ADR.</summary>
    public string? HazardClassCode { get; set; }

    /// <summary>Strefa docelowa.</summary>
    public string TargetZoneKind { get; set; } = default!;
}

/// <summary>Wiersz tabeli <c>warehouse.pick_waves</c>.</summary>
public class PickWaveEntity
{
    /// <summary>Klucz główny, prefiks <c>pkw_</c>.</summary>
    public string WaveId { get; set; } = default!;

    /// <summary>Obiekt.</summary>
    public string FacilityId { get; set; } = default!;

    /// <summary>Najemca.</summary>
    public string TenantId { get; set; } = default!;

    /// <summary>Strategia doboru zadań.</summary>
    public string Strategy { get; set; } = default!;

    /// <summary>Stan fali.</summary>
    public string State { get; set; } = default!;

    /// <summary>Suma odcinków trasy w metrach.</summary>
    public int TotalDistanceM { get; set; }

    /// <summary>Szacowany czas przejścia w sekundach.</summary>
    public int EstimatedSeconds { get; set; }

    /// <summary>Kiedy fala została policzona.</summary>
    public DateTimeOffset PlannedAt { get; set; }

    /// <summary>Kiedy trafiła na halę.</summary>
    public DateTimeOffset? ReleasedAt { get; set; }

    /// <summary>Kiedy zamknięto ostatnie zadanie.</summary>
    public DateTimeOffset? CompletedAt { get; set; }

    /// <summary>Zadania fali.</summary>
    public ICollection<PickTaskEntity> Tasks { get; set; } = new List<PickTaskEntity>();
}

/// <summary>Wiersz tabeli <c>warehouse.pick_tasks</c>.</summary>
public class PickTaskEntity
{
    /// <summary>Klucz główny, prefiks <c>pkt_</c>.</summary>
    public string TaskId { get; set; } = default!;

    /// <summary>Fala nadrzędna.</summary>
    public string WaveId { get; set; } = default!;

    /// <summary>Nawigacja do fali.</summary>
    public PickWaveEntity? Wave { get; set; }

    /// <summary>Gniazdo źródłowe.</summary>
    public string SlotId { get; set; } = default!;

    /// <summary>Kontener do zabrania.</summary>
    public string ContainerId { get; set; } = default!;

    /// <summary>Przesyłka.</summary>
    public string ShipmentId { get; set; } = default!;

    /// <summary>Pozycja w trasie.</summary>
    public short SeqNo { get; set; }

    /// <summary>Stan zadania.</summary>
    public string State { get; set; } = default!;

    /// <summary>Magazynier.</summary>
    public string? AssignedUserId { get; set; }

    /// <summary>Odcinek od poprzedniego gniazda w metrach.</summary>
    public int TravelCostM { get; set; }

    /// <summary>Przyjęcie zadania.</summary>
    public DateTimeOffset? StartedAt { get; set; }

    /// <summary>Zamknięcie zadania.</summary>
    public DateTimeOffset? CompletedAt { get; set; }

    /// <summary>Skan zwrócony przez container-registry, prefiks <c>scn_</c>.</summary>
    public string? ScanId { get; set; }
}

/// <summary>Wiersz tabeli <c>warehouse.cycle_count_plans</c>.</summary>
public class CycleCountPlanEntity
{
    /// <summary>Klucz główny, prefiks <c>ccp_</c>.</summary>
    public string PlanId { get; set; } = default!;

    /// <summary>Obiekt.</summary>
    public string FacilityId { get; set; } = default!;

    /// <summary>Najemca.</summary>
    public string TenantId { get; set; } = default!;

    /// <summary>Metoda doboru gniazd.</summary>
    public string Method { get; set; } = default!;

    /// <summary>Data robocza planu.</summary>
    public DateOnly ScheduledOn { get; set; }

    /// <summary>Ziarno losowania; bez niego planu nie da się odtworzyć przy sporze.</summary>
    public int Seed { get; set; }

    /// <summary>Liczba gniazd w planie.</summary>
    public int SlotCount { get; set; }

    /// <summary>Znacznik utworzenia.</summary>
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>Zamknięcie planu.</summary>
    public DateTimeOffset? ClosedAt { get; set; }

    /// <summary>Liczenia planu.</summary>
    public ICollection<CycleCountTaskEntity> Counts { get; set; } = new List<CycleCountTaskEntity>();
}

/// <summary>Wiersz tabeli <c>warehouse.cycle_count_tasks</c>.</summary>
public class CycleCountTaskEntity
{
    /// <summary>Klucz główny, prefiks <c>cct_</c>.</summary>
    public string CountId { get; set; } = default!;

    /// <summary>Plan nadrzędny.</summary>
    public string PlanId { get; set; } = default!;

    /// <summary>Gniazdo.</summary>
    public string SlotId { get; set; } = default!;

    /// <summary>Kontener oczekiwany.</summary>
    public string? ExpectedContainerId { get; set; }

    /// <summary>Kontener zastany.</summary>
    public string? ObservedContainerId { get; set; }

    /// <summary>Magazynier.</summary>
    public string? CountedByUserId { get; set; }

    /// <summary>Czas liczenia z terminala.</summary>
    public DateTimeOffset? CountedAt { get; set; }

    /// <summary>Czas zapisu w bazie; różni się od <see cref="CountedAt"/> przy pracy offline.</summary>
    public DateTimeOffset? RecordedAt { get; set; }
}

/// <summary>Wiersz tabeli <c>warehouse.count_variances</c>.</summary>
public class CountVarianceEntity
{
    /// <summary>Klucz główny, prefiks <c>cvr_</c>.</summary>
    public string VarianceId { get; set; } = default!;

    /// <summary>Liczenie, które rozbieżność ujawniło.</summary>
    public string CountId { get; set; } = default!;

    /// <summary>Gniazdo.</summary>
    public string SlotId { get; set; } = default!;

    /// <summary>Obiekt; zdenormalizowany, żeby ekran „do wyjaśnienia” nie musiał łączyć trzech tabel.</summary>
    public string FacilityId { get; set; } = default!;

    /// <summary>Rodzaj rozbieżności.</summary>
    public string Kind { get; set; } = default!;

    /// <summary>Stan oczekiwany.</summary>
    public string? ExpectedContainerId { get; set; }

    /// <summary>Stan zastany.</summary>
    public string? ObservedContainerId { get; set; }

    /// <summary>Zdjęcie w document-service.</summary>
    public string? EvidenceDocumentId { get; set; }

    /// <summary>Numer wpisu w <c>platform.audit_ledger_entries</c>.</summary>
    public long? LedgerEntryId { get; set; }

    /// <summary>Otwarcie.</summary>
    public DateTimeOffset OpenedAt { get; set; }

    /// <summary>Zamknięcie.</summary>
    public DateTimeOffset? ResolvedAt { get; set; }

    /// <summary>Notatka rozstrzygająca.</summary>
    public string? ResolutionNote { get; set; }
}

/// <summary>
/// Wiersz tabeli <c>platform.outbox_messages</c> widziany z naszej strony. Tabela należy do
/// schematu współdzielonego, ale każdy producent zapisuje wyłącznie własne wiersze i czyta je
/// wyłącznie własny przekaźnik.
/// </summary>
public class OutboxMessageEntity
{
    /// <summary>Identyfikator koperty, prefiks <c>evt_</c>.</summary>
    public string EventId { get; set; } = default!;

    /// <summary>Nazwa zdarzenia, np. <c>warehouse.pick_wave.released</c>.</summary>
    public string EventName { get; set; } = default!;

    /// <summary>Wersja schematu ładunku.</summary>
    public int SchemaVersion { get; set; }

    /// <summary>Temat Kafki.</summary>
    public string Topic { get; set; } = default!;

    /// <summary>Klucz partycji; decyduje o porządku.</summary>
    public string PartitionKey { get; set; } = default!;

    /// <summary>Najemca.</summary>
    public string TenantId { get; set; } = default!;

    /// <summary>Region z §0.6.</summary>
    public string RegionCode { get; set; } = default!;

    /// <summary>Nazwa producenta; u nas zawsze <c>warehouse-service</c>.</summary>
    public string Producer { get; set; } = default!;

    /// <summary>Identyfikator śladu W3C przeniesiony z nagłówka <c>X-OF-Trace-Id</c>.</summary>
    public string TraceId { get; set; } = default!;

    /// <summary>Ładunek zdarzenia jako JSON.</summary>
    public string Payload { get; set; } = default!;

    /// <summary>Czas wystąpienia zdarzenia.</summary>
    public DateTimeOffset OccurredAt { get; set; }

    /// <summary>Czas wypchnięcia przez przekaźnik; <see langword="null"/> = wiersz czeka.</summary>
    public DateTimeOffset? PublishedAt { get; set; }
}

/// <summary>
/// Wiersz tabeli <c>warehouse.idempotency_keys</c>: zapamiętana odpowiedź na żądanie mutujące,
/// trzymana 24 godziny zgodnie z §7 pkt 5.
/// </summary>
public class IdempotencyRecordEntity
{
    /// <summary>Wartość nagłówka <c>X-OF-Idempotency-Key</c>.</summary>
    public string Key { get; set; } = default!;

    /// <summary>Najemca; klucze nie przechodzą między najemcami.</summary>
    public string TenantId { get; set; } = default!;

    /// <summary>Metoda i ścieżka żądania, np. <c>POST /v1/placements</c>.</summary>
    public string Endpoint { get; set; } = default!;

    /// <summary>Skrót treści żądania; ten sam klucz z inną treścią to błąd <c>idempotency_key_reuse</c>.</summary>
    public string RequestSha256 { get; set; } = default!;

    /// <summary>Zapamiętany status HTTP.</summary>
    public int StatusCode { get; set; }

    /// <summary>Zapamiętane ciało odpowiedzi.</summary>
    public string ResponseBody { get; set; } = default!;

    /// <summary>Utworzenie wpisu.</summary>
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>Wygaśnięcie wpisu.</summary>
    public DateTimeOffset ExpiresAt { get; set; }
}
