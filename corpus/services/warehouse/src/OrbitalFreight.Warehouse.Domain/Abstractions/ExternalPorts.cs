using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Abstractions;

/// <summary>
/// Porty do usług, których danych nie wolno nam czytać SQL-em (§7 pkt 2). Każdy z nich ma
/// dokładnie jedną implementację po stronie infrastruktury i jest jedynym miejscem, w którym
/// warehouse-service wychodzi na zewnątrz — dzięki temu graf połączeń synchronicznych da się
/// odczytać z jednego pliku i porównać z §1.1 specyfikacji.
/// </summary>
public interface IContainerRegistryPort
{
    /// <summary>
    /// Czyta przesyłkę przez <c>GET /v1/shipments/{shipment_id}</c> w container-registry
    /// (kontenery są w odpowiedzi zagnieżdżone, więc jedno wywołanie wystarcza na całą falę).
    /// </summary>
    Task<ShipmentSnapshot?> GetShipmentAsync(string shipmentId, CancellationToken ct);

    /// <summary>Czyta kontener przez <c>GET /v1/containers/{container_id}</c>.</summary>
    Task<ContainerSnapshot?> GetContainerAsync(string containerId, CancellationToken ct);

    /// <summary>
    /// Rejestruje skan przez <c>POST /v1/containers/{container_id}/scans</c>. To jedyna droga
    /// do <c>freight.shipment_scan_events</c>; container-registry publikuje przy okazji
    /// <c>shipment.scanned</c>, którego sami następnie konsumujemy — i dlatego konsument musi
    /// rozpoznawać skany własnego autorstwa po <c>device_serial</c>.
    /// </summary>
    /// <param name="containerId">Kontener, prefiks <c>cnt_</c>.</param>
    /// <param name="shipmentId">Przesyłka, prefiks <c>shp_</c>.</param>
    /// <param name="scanType">Jedna z wartości <c>freight.shipment_scan_events.scan_type</c>.</param>
    /// <param name="facilityId">Obiekt, w którym skan powstał.</param>
    /// <param name="scannedByUserId">Magazynier.</param>
    /// <param name="occurredAt">Czas zdarzenia z terminala.</param>
    /// <param name="ct">Token anulowania.</param>
    /// <returns>Identyfikator skanu, prefiks <c>scn_</c>.</returns>
    Task<string> RecordScanAsync(
        string containerId,
        string shipmentId,
        string scanType,
        string facilityId,
        string scannedByUserId,
        DateTimeOffset occurredAt,
        CancellationToken ct);
}

/// <summary>
/// Port do geo-service. Używamy dwóch metod z <c>geo.v1.GeoService</c>: <c>ResolveGeofence</c>
/// dla obwiedni obiektu i <c>PointInFence</c> dla weryfikacji, czy terminal magazyniera był
/// faktycznie na terenie obiektu w chwili skanu.
/// </summary>
public interface IGeoPort
{
    /// <summary>Zwraca metadane geofence'u z <c>geo.geofences</c> (bufor <c>buffer_m</c> włącznie).</summary>
    Task<GeofenceSnapshot?> ResolveGeofenceAsync(string geofenceId, CancellationToken ct);

    /// <summary>
    /// Wsadowe sprawdzenie punktów w obwiedni. Kolejność wyniku odpowiada kolejności wejścia,
    /// a bufor <c>buffer_m</c> jest już uwzględniony po stronie geo-service.
    /// </summary>
    Task<IReadOnlyList<bool>> PointsInFenceAsync(
        string geofenceId,
        IReadOnlyList<(double Latitude, double Longitude)> points,
        CancellationToken ct);
}

/// <summary>
/// Port do document-service. Zdjęcie uszkodzenia albo protokół rozbieżności trafia tam przez
/// <c>POST /v1/documents</c>; wartość <c>owner_type</c> musi istnieć w
/// <c>platform.document_owner_types</c>, inaczej document-service odrzuci wgranie.
/// </summary>
public interface IDocumentPort
{
    /// <summary>Wysyła plik i zwraca jego identyfikator, prefiks <c>doc_</c>.</summary>
    /// <param name="ownerType">Wartość ze słownika <c>platform.document_owner_types</c>.</param>
    /// <param name="ownerId">Identyfikator właściciela, np. <c>cvr_</c> rozbieżności.</param>
    /// <param name="kind">Rodzaj dokumentu, np. <c>damage_photo</c>.</param>
    /// <param name="mimeType">Typ MIME; document-service odrzuca spoza <c>OF_DOCUMENT_ALLOWED_MIME_TYPES</c>.</param>
    /// <param name="content">Zawartość pliku.</param>
    /// <param name="ct">Token anulowania.</param>
    Task<string> UploadAsync(
        string ownerType,
        string ownerId,
        string kind,
        string mimeType,
        ReadOnlyMemory<byte> content,
        CancellationToken ct);

    /// <summary>
    /// Prosi o link ważny 15 minut (<c>POST /v1/documents/{document_id}/signed-url</c>).
    /// Bajtów nie pobieramy nigdy — konsola i aplikacja inspektora idą po link same.
    /// </summary>
    Task<Uri> CreateSignedUrlAsync(string documentId, CancellationToken ct);
}

/// <summary>
/// Port do audit-ledger. Korekta stanu magazynowego jest zdarzeniem księgowym, więc idzie
/// przez <c>audit.v1.LedgerService/Append</c> — jedyną ścieżkę zapisu do
/// <c>platform.audit_ledger_entries</c>.
/// </summary>
public interface IAuditLedgerPort
{
    /// <summary>Dopisuje wpis i zwraca jego <c>entry_id</c> (BIGINT, bo łańcuch skrótów wymaga porządku).</summary>
    /// <param name="subjectType">Rodzaj podmiotu, np. <c>warehouse_slot</c>.</param>
    /// <param name="subjectId">Identyfikator podmiotu.</param>
    /// <param name="action">Czynność w <c>snake_case</c>, np. <c>inventory_adjusted</c>.</param>
    /// <param name="actorId">Kto zadziałał: <c>usr_</c> albo <c>svc:warehouse-service</c>.</param>
    /// <param name="payload">Ładunek serializowany do JSON-a; trafia do skrótu wpisu.</param>
    /// <param name="ct">Token anulowania.</param>
    Task<long> AppendAsync(
        string subjectType,
        string subjectId,
        string action,
        string actorId,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken ct);
}

/// <summary>
/// Port do analytics-pipeline: <c>GET /v1/metrics/container-utilisation</c>, czyli widok
/// <c>analytics.mv_container_utilisation_weekly</c> podany API-em. To jedyne wejście dla
/// klasyfikacji ABC — sięgnięcie po ten widok SQL-em łamałoby §7 pkt 2, choć fizycznie
/// stoi w tej samej bazie.
/// </summary>
public interface IUtilisationSnapshotPort
{
    /// <summary>
    /// Rotacja kontenerów w zadanym tygodniu: klucz to <c>cnt_</c>, wartość to liczba przewozów
    /// (<c>trips</c>). Kontener nieobecny w słowniku traktujemy jak klasę C.
    /// </summary>
    Task<IReadOnlyDictionary<string, int>> GetWeeklyTripsAsync(string tenantId, DateOnly weekStart, CancellationToken ct);
}

/// <summary>
/// Skrzynka nadawcza. Zapis idzie do <c>platform.outbox_messages</c> w tej samej transakcji,
/// co zmiana stanu; osobny przekaźnik (interwał <c>OF_OUTBOX_RELAY_INTERVAL_MS</c>) przenosi
/// wiersze na temat Kafki.
/// </summary>
public interface IOutboxWriter
{
    /// <summary>
    /// Wstawia zdarzenie w kopercie z §0.7. Pola <c>event_id</c>, <c>occurred_at</c>,
    /// <c>producer</c>, <c>region_code</c> i <c>trace_id</c> wypełnia implementacja —
    /// wywołujący podaje tylko nazwę, klucz partycji i ładunek.
    /// </summary>
    /// <param name="eventName">Nazwa zdarzenia, np. <c>warehouse.pick_wave.released</c>.</param>
    /// <param name="topic">Temat Kafki, np. <c>of.platform.v1</c>.</param>
    /// <param name="partitionKey">Klucz porządkujący; dla operacji magazynowych zawsze <c>shp_</c> albo <c>fac_</c>.</param>
    /// <param name="payload">Ładunek zdarzenia.</param>
    /// <param name="ct">Token anulowania.</param>
    Task EnqueueAsync(
        string eventName,
        string topic,
        string partitionKey,
        IReadOnlyDictionary<string, object?> payload,
        CancellationToken ct);
}

/// <summary>Wycinek przesyłki, którego potrzebuje magazyn — reszty pola <c>freight.shipments</c> nie kopiujemy.</summary>
/// <param name="ShipmentId">Prefiks <c>shp_</c>.</param>
/// <param name="TenantId">Prefiks <c>tnt_</c>.</param>
/// <param name="Reference">Referencja klienta.</param>
/// <param name="Status">Stan z <c>freight.shipments.status</c>.</param>
/// <param name="OriginFacilityId">Obiekt nadania.</param>
/// <param name="DestinationFacilityId">Obiekt odbioru.</param>
/// <param name="SlaDeadlineAt">Termin SLA; steruje pilnością fali.</param>
/// <param name="RegionCode">Kod regionu z §0.6.</param>
/// <param name="ContainerIds">Kontenery przypięte przez <c>freight.shipment_containers</c>.</param>
public sealed record ShipmentSnapshot(
    string ShipmentId,
    string TenantId,
    string Reference,
    string Status,
    string OriginFacilityId,
    string DestinationFacilityId,
    DateTimeOffset? SlaDeadlineAt,
    string RegionCode,
    IReadOnlyList<string> ContainerIds);

/// <summary>Wycinek kontenera potrzebny do adresowania i do doboru gniazda.</summary>
/// <param name="ContainerId">Prefiks <c>cnt_</c>.</param>
/// <param name="IsoCode">Kod BIC, np. <c>MSCU3948571</c>.</param>
/// <param name="IsoSizeType">Typ ISO, np. <c>45R1</c>.</param>
/// <param name="TareWeightKg">Masa własna.</param>
/// <param name="MaxGrossKg">Dopuszczalna masa brutto.</param>
/// <param name="IsReefer">Czy kontener ma agregat.</param>
/// <param name="SetpointC">Zadana temperatura, tylko dla chłodni.</param>
/// <param name="PrimaryHazardClassCode">Wiodąca klasa ADR z <c>freight.container_hazard_classes</c>.</param>
public sealed record ContainerSnapshot(
    string ContainerId,
    string IsoCode,
    string IsoSizeType,
    int TareWeightKg,
    int MaxGrossKg,
    bool IsReefer,
    decimal? SetpointC,
    string? PrimaryHazardClassCode);

/// <summary>Obwiednia obiektu w postaci, jakiej potrzebuje weryfikacja skanu.</summary>
/// <param name="GeofenceId">Prefiks <c>gfn_</c>.</param>
/// <param name="Name">Nazwa czytelna dla człowieka.</param>
/// <param name="Kind">Rodzaj z <c>geo.geofences.kind</c>, dla magazynu zwykle <c>facility</c>.</param>
/// <param name="BufferM">Tolerancja GPS w metrach.</param>
public sealed record GeofenceSnapshot(string GeofenceId, string Name, string Kind, int BufferM);
