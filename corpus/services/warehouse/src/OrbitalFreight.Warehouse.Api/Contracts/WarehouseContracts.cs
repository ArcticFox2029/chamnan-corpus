using System.Text.Json.Serialization;

namespace OrbitalFreight.Warehouse.Api.Contracts;

/// <summary>
/// Kontrakty HTTP usługi warehouse-service. Są celowo osobnymi typami niż rekordy domeny:
/// na drucie obowiązuje <c>snake_case</c>, masy mają sufiks <c>_kg</c>, odległości <c>_m</c>,
/// a znaczniki czasu <c>_at</c> — konwencje z §0.2, których model wewnętrzny nie musi znać.
/// Odpowiedzi kolekcyjne zawsze wracają w postaci <see cref="CursorPageResponse{T}"/>, bo
/// paginacja po offsecie na tej platformie nie istnieje.
/// </summary>
/// <typeparam name="T">Typ elementu strony.</typeparam>
/// <param name="Items">Elementy strony.</param>
/// <param name="NextCursor">Kursor następnej strony albo <see langword="null"/>.</param>
public sealed record CursorPageResponse<T>(
    [property: JsonPropertyName("items")] IReadOnlyList<T> Items,
    [property: JsonPropertyName("next_cursor")] string? NextCursor);

/// <summary>Żądanie rozstawienia kontenera w gnieździe.</summary>
/// <param name="FacilityId">Obiekt z <c>freight.facilities</c>, prefiks <c>fac_</c>.</param>
/// <param name="ContainerId">Kontener, prefiks <c>cnt_</c>.</param>
/// <param name="ShipmentId">Przesyłka albo <see langword="null"/> dla pustego kontenera.</param>
/// <param name="GrossKg">Masa brutto w kilogramach.</param>
/// <param name="UnderCustomsControl">Czy towar czeka na <c>customs.declaration.cleared</c>.</param>
public sealed record CreatePlacementRequest(
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("container_id")] string ContainerId,
    [property: JsonPropertyName("shipment_id")] string? ShipmentId,
    [property: JsonPropertyName("gross_kg")] int GrossKg,
    [property: JsonPropertyName("under_customs_control")] bool UnderCustomsControl);

/// <summary>Odpowiedź po rozstawieniu.</summary>
/// <param name="PlacementId">Rozstawienie, prefiks <c>plc_</c>.</param>
/// <param name="SlotId">Wybrane gniazdo, prefiks <c>slt_</c>.</param>
/// <param name="SlotCode">Etykieta gniazda do odczytania z terminala.</param>
/// <param name="Score">Punktacja wyboru; ekran dyspozytora pokazuje ją obok rekomendacji.</param>
/// <param name="PlacedAt">Czas rozstawienia.</param>
public sealed record PlacementResponse(
    [property: JsonPropertyName("placement_id")] string PlacementId,
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("slot_code")] string SlotCode,
    [property: JsonPropertyName("score")] double Score,
    [property: JsonPropertyName("placed_at")] DateTimeOffset PlacedAt);

/// <summary>Jedna pozycja rankingu gniazd.</summary>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="Score">Punktacja reguł miękkich.</param>
/// <param name="Eligible">Czy gniazdo przeszło reguły twarde.</param>
/// <param name="ReasonCode">Kod odrzucenia, gdy nie przeszło.</param>
public sealed record SlotRecommendationResponse(
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("score")] double Score,
    [property: JsonPropertyName("eligible")] bool Eligible,
    [property: JsonPropertyName("reason_code")] string? ReasonCode);

/// <summary>Gniazdo w odpowiedzi listującej.</summary>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="ZoneId">Strefa.</param>
/// <param name="SlotCode">Etykieta.</param>
/// <param name="Aisle">Alejka.</param>
/// <param name="Bay">Zatoka.</param>
/// <param name="Level">Poziom.</param>
/// <param name="MaxWeightKg">Nośność.</param>
/// <param name="Powered">Czy z zasilaniem.</param>
/// <param name="TravelCostM">Odległość od rampy wydań.</param>
/// <param name="Blocked">Czy zablokowane.</param>
/// <param name="BlockedReason">Powód blokady.</param>
public sealed record SlotResponse(
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("zone_id")] string ZoneId,
    [property: JsonPropertyName("slot_code")] string SlotCode,
    [property: JsonPropertyName("aisle")] short Aisle,
    [property: JsonPropertyName("bay")] short Bay,
    [property: JsonPropertyName("level")] short Level,
    [property: JsonPropertyName("max_weight_kg")] int MaxWeightKg,
    [property: JsonPropertyName("is_powered")] bool Powered,
    [property: JsonPropertyName("travel_cost_m")] int TravelCostM,
    [property: JsonPropertyName("is_blocked")] bool Blocked,
    [property: JsonPropertyName("blocked_reason")] string? BlockedReason);

/// <summary>Żądanie zaplanowania fali kompletacyjnej.</summary>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="ShipmentIds">Przesyłki do skompletowania; kolejność bez znaczenia.</param>
/// <param name="Strategy">Strategia: <c>sla_first</c>, <c>lane_batch</c>, <c>single_shipment</c> albo <c>zone_batch</c>.</param>
public sealed record PlanWaveRequest(
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("shipment_ids")] IReadOnlyList<string> ShipmentIds,
    [property: JsonPropertyName("strategy")] string Strategy);

/// <summary>Fala wraz z trasą.</summary>
/// <param name="WaveId">Fala, prefiks <c>pkw_</c>.</param>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="State">Stan fali.</param>
/// <param name="TotalDistanceM">Długość trasy w metrach.</param>
/// <param name="EstimatedSeconds">Szacowany czas przejścia.</param>
/// <param name="Tasks">Zadania w kolejności obejścia.</param>
public sealed record WaveResponse(
    [property: JsonPropertyName("wave_id")] string WaveId,
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("total_distance_m")] int TotalDistanceM,
    [property: JsonPropertyName("estimated_seconds")] int EstimatedSeconds,
    [property: JsonPropertyName("tasks")] IReadOnlyList<PickTaskResponse> Tasks);

/// <summary>Zadanie kompletacji w postaci, jaką czyta terminal magazyniera.</summary>
/// <param name="TaskId">Zadanie, prefiks <c>pkt_</c>.</param>
/// <param name="SeqNo">Pozycja w trasie.</param>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="ContainerId">Kontener.</param>
/// <param name="ShipmentId">Przesyłka.</param>
/// <param name="State">Stan zadania.</param>
/// <param name="TravelCostM">Odcinek od poprzedniego gniazda.</param>
/// <param name="ScanId">Skan potwierdzający, prefiks <c>scn_</c>.</param>
public sealed record PickTaskResponse(
    [property: JsonPropertyName("task_id")] string TaskId,
    [property: JsonPropertyName("seq_no")] short SeqNo,
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("container_id")] string ContainerId,
    [property: JsonPropertyName("shipment_id")] string ShipmentId,
    [property: JsonPropertyName("state")] string State,
    [property: JsonPropertyName("travel_cost_m")] int TravelCostM,
    [property: JsonPropertyName("scan_id")] string? ScanId);

/// <summary>Potwierdzenie zadania z terminala.</summary>
/// <param name="Picked">Czy kontener zabrano; <see langword="false"/> zgłasza brak.</param>
/// <param name="OccurredAt">Czas z terminala; przy pracy offline starszy niż chwila wysyłki.</param>
public sealed record CompleteTaskRequest(
    [property: JsonPropertyName("picked")] bool Picked,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset OccurredAt);

/// <summary>Żądanie ułożenia planu inwentaryzacji.</summary>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="ScheduledOn">Dzień roboczy planu.</param>
/// <param name="Method">Metoda: <c>abc</c>, <c>random</c>, <c>variance_driven</c> albo <c>blind_recount</c>.</param>
public sealed record CreateCountPlanRequest(
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("scheduled_on")] DateOnly ScheduledOn,
    [property: JsonPropertyName("method")] string Method);

/// <summary>Plan inwentaryzacji.</summary>
/// <param name="PlanId">Plan, prefiks <c>ccp_</c>.</param>
/// <param name="FacilityId">Obiekt.</param>
/// <param name="Method">Metoda.</param>
/// <param name="ScheduledOn">Dzień roboczy.</param>
/// <param name="SlotCount">Liczba gniazd do policzenia.</param>
public sealed record CountPlanResponse(
    [property: JsonPropertyName("plan_id")] string PlanId,
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("method")] string Method,
    [property: JsonPropertyName("scheduled_on")] DateOnly ScheduledOn,
    [property: JsonPropertyName("slot_count")] int SlotCount);

/// <summary>Wynik liczenia jednego gniazda przysłany z terminala.</summary>
/// <param name="ObservedContainerId">Kontener zastany; <see langword="null"/> = gniazdo puste.</param>
/// <param name="CountedAt">Czas liczenia.</param>
/// <param name="DamageReported">Czy zgłoszono uszkodzenie.</param>
/// <param name="SealMatches">Czy plomba zgadza się z <c>freight.shipment_containers.seal_number</c>.</param>
/// <param name="EvidencePhotoBase64">Zdjęcie dowodowe; przekazywane dalej do document-service.</param>
public sealed record SubmitCountRequest(
    [property: JsonPropertyName("observed_container_id")] string? ObservedContainerId,
    [property: JsonPropertyName("counted_at")] DateTimeOffset CountedAt,
    [property: JsonPropertyName("damage_reported")] bool DamageReported,
    [property: JsonPropertyName("seal_matches")] bool SealMatches,
    [property: JsonPropertyName("evidence_photo_base64")] string? EvidencePhotoBase64);

/// <summary>Rozbieżność inwentaryzacyjna.</summary>
/// <param name="VarianceId">Rozbieżność, prefiks <c>cvr_</c>.</param>
/// <param name="SlotId">Gniazdo.</param>
/// <param name="Kind">Rodzaj rozbieżności.</param>
/// <param name="ExpectedContainerId">Stan oczekiwany.</param>
/// <param name="ObservedContainerId">Stan zastany.</param>
/// <param name="EvidenceDocumentId">Zdjęcie w document-service, prefiks <c>doc_</c>.</param>
/// <param name="LedgerEntryId">Numer wpisu w <c>platform.audit_ledger_entries</c>.</param>
/// <param name="OpenedAt">Otwarcie.</param>
public sealed record VarianceResponse(
    [property: JsonPropertyName("variance_id")] string VarianceId,
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("expected_container_id")] string? ExpectedContainerId,
    [property: JsonPropertyName("observed_container_id")] string? ObservedContainerId,
    [property: JsonPropertyName("evidence_document_id")] string? EvidenceDocumentId,
    [property: JsonPropertyName("ledger_entry_id")] long? LedgerEntryId,
    [property: JsonPropertyName("opened_at")] DateTimeOffset OpenedAt);

/// <summary>Zamknięcie rozbieżności notatką.</summary>
/// <param name="SlotId">Gniazdo, którego rozbieżność dotyczy; odblokowujemy je przy zamknięciu.</param>
/// <param name="Note">Notatka rozstrzygająca dla kontroli wewnętrznej.</param>
public sealed record ResolveVarianceRequest(
    [property: JsonPropertyName("slot_id")] string SlotId,
    [property: JsonPropertyName("note")] string Note);
