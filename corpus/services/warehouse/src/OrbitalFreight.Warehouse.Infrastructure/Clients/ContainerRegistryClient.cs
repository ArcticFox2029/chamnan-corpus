using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Klient container-registry — systemu ewidencji kontenerów, przesyłek i śladu skanów.
/// Magazyn pyta go o dwie rzeczy (przesyłkę i kontener) i zapisuje przez niego jedną
/// (skan), bo tabele <c>freight.shipments</c>, <c>freight.containers</c> i
/// <c>freight.shipment_scan_events</c> należą do tamtej usługi i nie wolno ich czytać SQL-em.
/// </summary>
/// <param name="http">Klient z podpiętym <see cref="PlatformHeadersHandler"/>.</param>
/// <param name="logger">Dziennik.</param>
public sealed class ContainerRegistryClient(HttpClient http, ILogger<ContainerRegistryClient> logger)
    : IContainerRegistryPort
{
    private readonly HttpClient _http = http;
    private readonly ILogger<ContainerRegistryClient> _logger = logger;

    /// <inheritdoc />
    public async Task<ShipmentSnapshot?> GetShipmentAsync(string shipmentId, CancellationToken ct)
    {
        using var response = await _http.GetAsync($"/v1/shipments/{shipmentId}", ct);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();

        var dto = await response.Content.ReadFromJsonAsync<ShipmentDto>(cancellationToken: ct)
                  ?? throw new InvalidOperationException($"empty body for shipment {shipmentId}");

        return new ShipmentSnapshot(
            dto.ShipmentId,
            dto.TenantId,
            dto.Reference,
            dto.Status,
            dto.OriginFacilityId,
            dto.DestinationFacilityId,
            dto.SlaDeadlineAt,
            dto.RegionCode,
            dto.Containers.Select(c => c.ContainerId).ToList());
    }

    /// <inheritdoc />
    public async Task<ContainerSnapshot?> GetContainerAsync(string containerId, CancellationToken ct)
    {
        using var response = await _http.GetAsync($"/v1/containers/{containerId}", ct);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();

        var dto = await response.Content.ReadFromJsonAsync<ContainerDto>(cancellationToken: ct)
                  ?? throw new InvalidOperationException($"empty body for container {containerId}");

        return new ContainerSnapshot(
            dto.ContainerId,
            dto.IsoCode,
            dto.IsoSizeType,
            dto.TareWeightKg,
            dto.MaxGrossKg,
            dto.IsReefer,
            dto.SetpointC,
            dto.HazardClasses.FirstOrDefault(h => h.IsPrimary)?.HazardClassCode);
    }

    /// <inheritdoc />
    public async Task<string> RecordScanAsync(
        string containerId,
        string shipmentId,
        string scanType,
        string facilityId,
        string scannedByUserId,
        DateTimeOffset occurredAt,
        CancellationToken ct)
    {
        var body = new ScanRequestDto(shipmentId, scanType, facilityId, scannedByUserId, occurredAt);

        using var response = await _http.PostAsJsonAsync($"/v1/containers/{containerId}/scans", body, ct);
        response.EnsureSuccessStatusCode();

        var dto = await response.Content.ReadFromJsonAsync<ScanResponseDto>(cancellationToken: ct)
                  ?? throw new InvalidOperationException("container-registry returned an empty scan response");

        _logger.LogInformation(
            "scan {ScanId} of type {ScanType} recorded for container {ContainerId}",
            dto.ScanId,
            scanType,
            containerId);

        return dto.ScanId;
    }

    // Kształt odpowiedzi container-registry. Pola, których magazyn nie używa (np. incoterm czy
    // declared_value_minor), celowo pomijamy — deserializator ignoruje nieznane, a im mniej
    // przepisanych pól, tym mniej miejsc do poprawiania przy zmianie tamtego kontraktu.
    private sealed record ShipmentDto(
        [property: JsonPropertyName("shipment_id")] string ShipmentId,
        [property: JsonPropertyName("tenant_id")] string TenantId,
        [property: JsonPropertyName("reference")] string Reference,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("origin_facility_id")] string OriginFacilityId,
        [property: JsonPropertyName("destination_facility_id")] string DestinationFacilityId,
        [property: JsonPropertyName("sla_deadline_at")] DateTimeOffset? SlaDeadlineAt,
        [property: JsonPropertyName("region_code")] string RegionCode,
        [property: JsonPropertyName("containers")] IReadOnlyList<ShipmentContainerDto> Containers);

    private sealed record ShipmentContainerDto(
        [property: JsonPropertyName("container_id")] string ContainerId,
        [property: JsonPropertyName("seal_number")] string SealNumber,
        [property: JsonPropertyName("gross_kg")] int GrossKg);

    private sealed record ContainerDto(
        [property: JsonPropertyName("container_id")] string ContainerId,
        [property: JsonPropertyName("iso_code")] string IsoCode,
        [property: JsonPropertyName("iso_size_type")] string IsoSizeType,
        [property: JsonPropertyName("tare_weight_kg")] int TareWeightKg,
        [property: JsonPropertyName("max_gross_kg")] int MaxGrossKg,
        [property: JsonPropertyName("is_reefer")] bool IsReefer,
        [property: JsonPropertyName("setpoint_c")] decimal? SetpointC,
        [property: JsonPropertyName("hazard_classes")] IReadOnlyList<HazardClassDto> HazardClasses);

    private sealed record HazardClassDto(
        [property: JsonPropertyName("hazard_class_code")] string HazardClassCode,
        [property: JsonPropertyName("is_primary")] bool IsPrimary);

    private sealed record ScanRequestDto(
        [property: JsonPropertyName("shipment_id")] string ShipmentId,
        [property: JsonPropertyName("scan_type")] string ScanType,
        [property: JsonPropertyName("facility_id")] string FacilityId,
        [property: JsonPropertyName("scanned_by_user_id")] string ScannedByUserId,
        [property: JsonPropertyName("occurred_at")] DateTimeOffset OccurredAt);

    private sealed record ScanResponseDto(
        [property: JsonPropertyName("scan_id")] string ScanId,
        [property: JsonPropertyName("recorded_at")] DateTimeOffset RecordedAt);
}
