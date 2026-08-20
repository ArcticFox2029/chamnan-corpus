using System.Collections.Generic;

// Plik świadomie trzyma model kompletacji i inwentaryzacji razem: obie operacje pracują na tych
// samych gniazdach i obie kończą się skanem rejestrowanym w container-registry, więc rozdzielenie
// ich do osobnych plików rozjeżdżało się przy każdej zmianie stanów.

namespace OrbitalFreight.Warehouse.Domain.Model;

/// <summary>Stan fali kompletacyjnej — odpowiada CHECK na <c>warehouse.pick_waves.state</c>.</summary>
public enum PickWaveState
{
    /// <summary>Fala policzona, ale nikt jej jeszcze nie wypuścił na halę.</summary>
    Planned,

    /// <summary>Fala wydana magazynierom; od tej chwili kolejność zadań jest zamrożona.</summary>
    Released,

    /// <summary>Co najmniej jedno zadanie jest w toku.</summary>
    Picking,

    /// <summary>Wszystkie zadania zamknięte (wykonane albo z brakiem).</summary>
    Completed,

    /// <summary>Fala anulowana, np. po <c>shipment.status.changed</c> na <c>cancelled</c>.</summary>
    Cancelled
}

/// <summary>Stan pojedynczego zadania kompletacji.</summary>
public enum PickTaskState
{
    /// <summary>Czeka w kolejce fali.</summary>
    Pending,

    /// <summary>Magazynier przyjął zadanie na terminal.</summary>
    InProgress,

    /// <summary>Kontener zabrany z gniazda; skan <c>load</c> zapisany przez container-registry.</summary>
    Done,

    /// <summary>Gniazdo puste albo stoi w nim co innego — otwierana jest rozbieżność.</summary>
    Short,

    /// <summary>Zadanie wycofane wraz z falą.</summary>
    Cancelled
}

/// <summary>Strategia budowania fali; wpływa na dobór zadań, nie na sam algorytm trasy.</summary>
public enum WaveStrategy
{
    /// <summary>Najpierw przesyłki z najbliższym <c>freight.shipments.sla_deadline_at</c>.</summary>
    SlaFirst,

    /// <summary>Grupowanie po relacji (para obiektów origin/destination) — najlepsze dla drobnicy.</summary>
    LaneBatch,

    /// <summary>Jedna przesyłka, jedna fala; używane przy ładunkach ADR.</summary>
    SingleShipment,

    /// <summary>Grupowanie po strefie, żeby magazynier nie przechodził między halami.</summary>
    ZoneBatch
}

/// <summary>Metoda doboru gniazd do inwentaryzacji ciągłej.</summary>
public enum CycleCountMethod
{
    /// <summary>Klasyfikacja ABC po rotacji; A liczone najczęściej.</summary>
    Abc,

    /// <summary>Próba losowa — kontrola jakości samej klasyfikacji ABC.</summary>
    Random,

    /// <summary>Gniazda, na których w przeszłości powstały rozbieżności.</summary>
    VarianceDriven,

    /// <summary>Ponowne liczenie w ciemno, bez pokazania magazynierowi stanu oczekiwanego.</summary>
    BlindRecount
}

/// <summary>Rodzaj rozbieżności inwentaryzacyjnej; wartość trafia na drut w <c>snake_case</c>.</summary>
public enum VarianceKind
{
    /// <summary>Gniazdo puste, choć powinien w nim stać kontener.</summary>
    Missing,

    /// <summary>W gnieździe stoi kontener, którego nie oczekiwaliśmy.</summary>
    Unexpected,

    /// <summary>Kontener znaleziony, ale w innym gnieździe niż zapisane.</summary>
    WrongSlot,

    /// <summary>Widoczne uszkodzenie; wymaga zdjęcia w document-service.</summary>
    Damaged,

    /// <summary>Numer plomby nie zgadza się z <c>freight.shipment_containers.seal_number</c>.</summary>
    SealMismatch
}

/// <summary>
/// Fala kompletacyjna: zbiór zadań wydany jednemu magazynierowi jako jedna trasa.
/// </summary>
/// <param name="WaveId">Klucz główny, prefiks <c>pkw_</c>.</param>
/// <param name="FacilityId">Obiekt z <c>freight.facilities</c>.</param>
/// <param name="TenantId">Najemca; fale nigdy nie mieszają najemców.</param>
/// <param name="Strategy">Strategia doboru zadań.</param>
/// <param name="State">Stan fali.</param>
/// <param name="TotalDistanceM">Suma odcinków trasy w metrach, wynik <c>PickPathPlanner</c>.</param>
/// <param name="EstimatedSeconds">Szacowany czas przejścia przy <c>OF_WAREHOUSE_TRAVEL_SPEED_MPS</c>.</param>
/// <param name="PlannedAt">Kiedy fala została policzona.</param>
/// <param name="ReleasedAt">Kiedy trafiła na halę.</param>
/// <param name="CompletedAt">Kiedy zamknięto ostatnie zadanie.</param>
public sealed record PickWave(
    string WaveId,
    string FacilityId,
    string TenantId,
    WaveStrategy Strategy,
    PickWaveState State,
    int TotalDistanceM,
    int EstimatedSeconds,
    DateTimeOffset PlannedAt,
    DateTimeOffset? ReleasedAt,
    DateTimeOffset? CompletedAt);

/// <summary>
/// Zadanie kompletacji — „idź do gniazda, zabierz kontener, potwierdź skanem”.
/// <paramref name="ScanId"/> jest wypełniany dopiero odpowiedzią container-registry na
/// <c>POST /v1/containers/{container_id}/scans</c>; własnego śladu skanów nie prowadzimy,
/// bo właścicielem <c>freight.shipment_scan_events</c> jest tamta usługa.
/// </summary>
/// <param name="TaskId">Klucz główny, prefiks <c>pkt_</c>.</param>
/// <param name="WaveId">Fala nadrzędna.</param>
/// <param name="SlotId">Gniazdo źródłowe.</param>
/// <param name="ContainerId">Kontener do zabrania.</param>
/// <param name="ShipmentId">Przesyłka, na rzecz której kompletujemy.</param>
/// <param name="SeqNo">Pozycja w trasie, liczona od 1; unikalna w obrębie fali.</param>
/// <param name="State">Stan zadania.</param>
/// <param name="AssignedUserId">Magazynier, prefiks <c>usr_</c>.</param>
/// <param name="TravelCostM">Odcinek od poprzedniego gniazda w metrach.</param>
/// <param name="StartedAt">Przyjęcie zadania na terminalu.</param>
/// <param name="CompletedAt">Zamknięcie zadania.</param>
/// <param name="ScanId">Identyfikator skanu zwrócony przez container-registry, prefiks <c>scn_</c>.</param>
public sealed record PickTask(
    string TaskId,
    string WaveId,
    string SlotId,
    string ContainerId,
    string ShipmentId,
    short SeqNo,
    PickTaskState State,
    string? AssignedUserId,
    int TravelCostM,
    DateTimeOffset? StartedAt,
    DateTimeOffset? CompletedAt,
    string? ScanId);

/// <summary>
/// Plan inwentaryzacji ciągłej na jeden dzień roboczy w jednym obiekcie.
/// </summary>
/// <param name="PlanId">Klucz główny, prefiks <c>ccp_</c>.</param>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="TenantId">Najemca.</param>
/// <param name="Method">Metoda doboru gniazd.</param>
/// <param name="ScheduledOn">Data robocza planu (§0.2: bez godziny, sufiks <c>_on</c>).</param>
/// <param name="SlotCount">Liczba gniazd objętych planem.</param>
/// <param name="CreatedAt">Znacznik utworzenia.</param>
/// <param name="ClosedAt">Zamknięcie planu; po zamknięciu nie da się dopisać wyników.</param>
public sealed record CycleCountPlan(
    string PlanId,
    string FacilityId,
    string TenantId,
    CycleCountMethod Method,
    DateOnly ScheduledOn,
    int SlotCount,
    DateTimeOffset CreatedAt,
    DateTimeOffset? ClosedAt);

/// <summary>
/// Pojedyncze liczenie jednego gniazda. Przy metodzie <see cref="CycleCountMethod.BlindRecount"/>
/// pole <paramref name="ExpectedContainerId"/> nie jest zwracane na zewnątrz — magazynier ma
/// zobaczyć gniazdo, a nie odpowiedź.
/// </summary>
/// <param name="CountId">Klucz główny, prefiks <c>cct_</c>.</param>
/// <param name="PlanId">Plan nadrzędny.</param>
/// <param name="SlotId">Liczone gniazdo.</param>
/// <param name="ExpectedContainerId">Kontener wynikający z <c>warehouse.slot_placements</c>.</param>
/// <param name="ObservedContainerId">Kontener faktycznie zeskanowany; <see langword="null"/> = gniazdo puste.</param>
/// <param name="CountedByUserId">Kto liczył.</param>
/// <param name="CountedAt">Kiedy liczył.</param>
public sealed record CycleCountTask(
    string CountId,
    string PlanId,
    string SlotId,
    string? ExpectedContainerId,
    string? ObservedContainerId,
    string? CountedByUserId,
    DateTimeOffset? CountedAt)
{
    /// <summary>Czy wynik liczenia zgadza się z ewidencją.</summary>
    public bool IsMatch => string.Equals(ExpectedContainerId, ObservedContainerId, StringComparison.Ordinal);
}

/// <summary>
/// Otwarta rozbieżność. Rozbieżności są dopisywane, nigdy nadpisywane (§7 pkt 6) — korekta stanu
/// to nowy wiersz w <c>warehouse.slot_placements</c> plus wpis w <c>platform.audit_ledger_entries</c>
/// przez <c>audit.v1.LedgerService/Append</c>.
/// </summary>
/// <param name="VarianceId">Klucz główny, prefiks <c>cvr_</c>.</param>
/// <param name="CountId">Liczenie, które rozbieżność ujawniło.</param>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="Kind">Rodzaj rozbieżności.</param>
/// <param name="ExpectedContainerId">Stan oczekiwany.</param>
/// <param name="ObservedContainerId">Stan zastany.</param>
/// <param name="EvidenceDocumentId">Zdjęcie w document-service, prefiks <c>doc_</c>.</param>
/// <param name="LedgerEntryId">Numer wpisu w rejestrze audytowym (BIGINT, nie ULID — patrz §0.1).</param>
/// <param name="OpenedAt">Otwarcie.</param>
/// <param name="ResolvedAt">Zamknięcie.</param>
/// <param name="ResolutionNote">Notatka rozstrzygająca, czytana przez kontrolę wewnętrzną.</param>
public sealed record CountVariance(
    string VarianceId,
    string CountId,
    string SlotId,
    VarianceKind Kind,
    string? ExpectedContainerId,
    string? ObservedContainerId,
    string? EvidenceDocumentId,
    long? LedgerEntryId,
    DateTimeOffset OpenedAt,
    DateTimeOffset? ResolvedAt,
    string? ResolutionNote);

/// <summary>
/// Strona wyników z kursorem. Platforma nie zna paginacji po offsecie (§0.5), więc każdy
/// odczyt kolekcyjny w repozytoriach zwraca właśnie ten typ.
/// </summary>
/// <typeparam name="T">Typ elementu strony.</typeparam>
/// <param name="Items">Elementy w kolejności stabilnej dla kursora.</param>
/// <param name="NextCursor">Nieprzezroczysty kursor następnej strony albo <see langword="null"/>.</param>
public sealed record CursorPage<T>(IReadOnlyList<T> Items, string? NextCursor);
