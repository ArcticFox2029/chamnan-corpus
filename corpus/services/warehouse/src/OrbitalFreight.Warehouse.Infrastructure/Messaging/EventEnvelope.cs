using System.Text.Json;
using System.Text.Json.Serialization;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Koperta zdarzenia z §0.7 — identyczna dla każdego tematu, różni się wyłącznie ładunkiem.
/// Typ służy w obie strony: rozpakowujemy nim <c>shipment.scanned</c> z <c>of.freight.v1</c>
/// i pakujemy własne zdarzenia idące do <c>platform.outbox_messages</c>.
/// </summary>
/// <typeparam name="TPayload">Typ ładunku.</typeparam>
public sealed class EventEnvelope<TPayload>
{
    /// <summary>Identyfikator koperty, prefiks <c>evt_</c>; klucz odsiewania duplikatów (§4.19 pkt 1).</summary>
    [JsonPropertyName("event_id")]
    public string EventId { get; init; } = default!;

    /// <summary>Nazwa zdarzenia zapisana kropkami, np. <c>telemetry.alert.raised</c>.</summary>
    [JsonPropertyName("event_name")]
    public string EventName { get; init; } = default!;

    /// <summary>Wersja schematu ładunku; rośnie tylko przy usunięciu pola albo zmianie typu.</summary>
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; init; }

    /// <summary>Czas wystąpienia, RFC 3339 w UTC.</summary>
    [JsonPropertyName("occurred_at")]
    public DateTimeOffset OccurredAt { get; init; }

    /// <summary>Najemca.</summary>
    [JsonPropertyName("tenant_id")]
    public string TenantId { get; init; } = default!;

    /// <summary>Region z §0.6.</summary>
    [JsonPropertyName("region_code")]
    public string RegionCode { get; init; } = default!;

    /// <summary>Nazwa usługi wytwarzającej, dokładnie jak w §1.</summary>
    [JsonPropertyName("producer")]
    public string Producer { get; init; } = default!;

    /// <summary>Ślad W3C.</summary>
    [JsonPropertyName("trace_id")]
    public string TraceId { get; init; } = default!;

    /// <summary>Klucz partycji; porządek jest gwarantowany tylko w obrębie jednego klucza.</summary>
    [JsonPropertyName("partition_key")]
    public string PartitionKey { get; init; } = default!;

    /// <summary>Ładunek właściwy.</summary>
    [JsonPropertyName("payload")]
    public TPayload Payload { get; init; } = default!;

    /// <summary>
    /// Ustawienia serializacji wspólne dla całej usługi: <c>snake_case</c> na drucie i pomijanie
    /// wartości pustych. Nieznanych pól nie odrzucamy — §4.19 pkt 3 wymaga ich ignorowania,
    /// bo producent może dołożyć pole bez podbicia wersji schematu.
    /// </summary>
    public static JsonSerializerOptions SerializerOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip
    };
}

/// <summary>Ładunek zdarzenia <c>shipment.scanned</c> (§4.4), publikowanego przez container-registry.</summary>
public sealed class ShipmentScannedPayload
{
    /// <summary>Skan, prefiks <c>scn_</c>.</summary>
    [JsonPropertyName("scan_id")]
    public string ScanId { get; init; } = default!;

    /// <summary>Przesyłka.</summary>
    [JsonPropertyName("shipment_id")]
    public string ShipmentId { get; init; } = default!;

    /// <summary>Kontener; pusty przy skanie dotyczącym całej przesyłki.</summary>
    [JsonPropertyName("container_id")]
    public string? ContainerId { get; init; }

    /// <summary>Rodzaj skanu z <c>freight.shipment_scan_events.scan_type</c>.</summary>
    [JsonPropertyName("scan_type")]
    public string ScanType { get; init; } = default!;

    /// <summary>Obiekt, w którym skan powstał.</summary>
    [JsonPropertyName("facility_id")]
    public string? FacilityId { get; init; }

    /// <summary>Kto skanował.</summary>
    [JsonPropertyName("scanned_by_user_id")]
    public string ScannedByUserId { get; init; } = default!;

    /// <summary>Czas zdarzenia z terminala.</summary>
    [JsonPropertyName("occurred_at")]
    public DateTimeOffset OccurredAt { get; init; }

    /// <summary>Czas zapisu w container-registry; różni się przy pracy offline.</summary>
    [JsonPropertyName("recorded_at")]
    public DateTimeOffset RecordedAt { get; init; }

    /// <summary>Numer seryjny urządzenia; po nim poznajemy skany własnego autorstwa.</summary>
    [JsonPropertyName("device_serial")]
    public string? DeviceSerial { get; init; }
}

/// <summary>Ładunek zdarzenia <c>telemetry.alert.raised</c> (§4.9), publikowanego przez telemetry-ingest.</summary>
public sealed class TelemetryAlertRaisedPayload
{
    /// <summary>Alarm, prefiks <c>alr_</c>.</summary>
    [JsonPropertyName("alert_id")]
    public string AlertId { get; init; } = default!;

    /// <summary>Kontener, którego alarm dotyczy.</summary>
    [JsonPropertyName("container_id")]
    public string ContainerId { get; init; } = default!;

    /// <summary>Przesyłka.</summary>
    [JsonPropertyName("shipment_id")]
    public string? ShipmentId { get; init; }

    /// <summary>Kod reguły progowej z <c>OF_TELEMETRY_RULES_PATH</c>.</summary>
    [JsonPropertyName("rule_code")]
    public string RuleCode { get; init; } = default!;

    /// <summary>Waga alarmu.</summary>
    [JsonPropertyName("severity")]
    public string Severity { get; init; } = default!;

    /// <summary>Próg, który został przekroczony.</summary>
    [JsonPropertyName("threshold_value")]
    public decimal ThresholdValue { get; init; }

    /// <summary>Wartość szczytowa.</summary>
    [JsonPropertyName("peak_value")]
    public decimal PeakValue { get; init; }

    /// <summary>Otwarcie alarmu.</summary>
    [JsonPropertyName("opened_at")]
    public DateTimeOffset OpenedAt { get; init; }
}

/// <summary>Ładunek zdarzenia <c>customs.declaration.cleared</c> (§4.13), publikowanego przez customs-service.</summary>
public sealed class DeclarationClearedPayload
{
    /// <summary>Zgłoszenie celne, prefiks <c>dcl_</c>.</summary>
    [JsonPropertyName("declaration_id")]
    public string DeclarationId { get; init; } = default!;

    /// <summary>Przesyłka, której zgłoszenie dotyczy.</summary>
    [JsonPropertyName("shipment_id")]
    public string ShipmentId { get; init; } = default!;

    /// <summary>Numer ewidencyjny nadany przez organ celny.</summary>
    [JsonPropertyName("mrn")]
    public string Mrn { get; init; } = default!;

    /// <summary>Czas zwolnienia.</summary>
    [JsonPropertyName("cleared_at")]
    public DateTimeOffset ClearedAt { get; init; }

    /// <summary>Czy przeprowadzono rewizję.</summary>
    [JsonPropertyName("inspection_performed")]
    public bool InspectionPerformed { get; init; }

    /// <summary>Dokument decyzji w document-service.</summary>
    [JsonPropertyName("decision_document_id")]
    public string? DecisionDocumentId { get; init; }
}

/// <summary>Ładunek zdarzenia <c>shipment.status.changed</c> (§4.5).</summary>
public sealed class ShipmentStatusChangedPayload
{
    /// <summary>Przesyłka.</summary>
    [JsonPropertyName("shipment_id")]
    public string ShipmentId { get; init; } = default!;

    /// <summary>Stan poprzedni.</summary>
    [JsonPropertyName("from_status")]
    public string FromStatus { get; init; } = default!;

    /// <summary>Stan nowy.</summary>
    [JsonPropertyName("to_status")]
    public string ToStatus { get; init; } = default!;

    /// <summary>Kod przyczyny w <c>snake_case</c>.</summary>
    [JsonPropertyName("reason_code")]
    public string? ReasonCode { get; init; }

    /// <summary>Kto zmienił stan.</summary>
    [JsonPropertyName("changed_by")]
    public string ChangedBy { get; init; } = default!;

    /// <summary>Kiedy.</summary>
    [JsonPropertyName("changed_at")]
    public DateTimeOffset ChangedAt { get; init; }
}
