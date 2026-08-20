// -----------------------------------------------------------------------------------------------
// Kontrakty wejścia i wyjścia dla powierzchni administracyjnej hali: stref, blokad gniazd i reguł
// adresowania. Trzymamy je osobno od kontraktów operacyjnych, bo zmienia je zupełnie inny zespół
// i w innym rytmie — topologia hali rusza się przy przebudowie regałów, a nie co wdrożenie.
// -----------------------------------------------------------------------------------------------

using System.Text.Json.Serialization;

namespace OrbitalFreight.Warehouse.Api.Contracts;

/// <summary>Strefa w odpowiedzi HTTP. Koperta temperaturowa jest podawana w °C zgodnie z §0.2.</summary>
/// <param name="ZoneId">Identyfikator strefy, prefiks <c>wzn_</c>.</param>
/// <param name="FacilityId">Obiekt z <c>freight.facilities</c>.</param>
/// <param name="Kind">Rodzaj strefy w <c>snake_case</c>.</param>
/// <param name="TemperatureMinC">Dolna granica koperty temperaturowej.</param>
/// <param name="TemperatureMaxC">Górna granica koperty temperaturowej.</param>
/// <param name="Powered">Czy strefa ma gniazda z zasilaniem agregatu.</param>
/// <param name="GeofenceId">Geofence z <c>geo.geofences</c>, rozwiązywany przez geo-service.</param>
/// <param name="RegionCode">Region z §0.6.</param>
/// <param name="SlotCount">Liczba gniazd niewycofanych.</param>
public sealed record ZoneResponse(
    [property: JsonPropertyName("zone_id")] string ZoneId,
    [property: JsonPropertyName("facility_id")] string FacilityId,
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("temperature_min_c")] decimal? TemperatureMinC,
    [property: JsonPropertyName("temperature_max_c")] decimal? TemperatureMaxC,
    [property: JsonPropertyName("has_powered_slots")] bool Powered,
    [property: JsonPropertyName("geofence_id")] string GeofenceId,
    [property: JsonPropertyName("region_code")] string RegionCode,
    [property: JsonPropertyName("slot_count")] int SlotCount);

/// <summary>
/// Żądanie zablokowania albo odblokowania gniazda. Powód jest wymagany przy zakładaniu blokady —
/// blokada bez powodu żyła w hali średnio siedem tygodni, bo nikt nie wiedział, czy wolno ją zdjąć.
/// </summary>
/// <param name="Blocked">Docelowy stan blokady.</param>
/// <param name="Reason">Powód w <c>snake_case</c>: <c>rack_damage</c>, <c>open_variance</c>, <c>refit</c>.</param>
public sealed record SlotBlockRequest(
    [property: JsonPropertyName("is_blocked")] bool Blocked,
    [property: JsonPropertyName("reason")] string? Reason);

/// <summary>
/// Reguła adresowania w odpowiedzi HTTP. Reguły są sprawdzane rosnąco po priorytecie i pierwsza
/// pasująca wskazuje rodzaj strefy; polityka slottingu wybiera potem gniazdo już tylko w jej obrębie.
/// </summary>
/// <param name="RuleId">Identyfikator reguły.</param>
/// <param name="Priority">Priorytet; niższy znaczy wcześniej.</param>
/// <param name="IsoSizeType">Dopasowanie po <c>freight.containers.iso_size_type</c>; <c>null</c> = dowolny.</param>
/// <param name="Reefer">Dopasowanie po <c>freight.containers.is_reefer</c>; <c>null</c> = bez znaczenia.</param>
/// <param name="HazardClassCode">Dopasowanie po <c>freight.hazard_classes.hazard_class_code</c>.</param>
/// <param name="TargetZoneKind">Rodzaj strefy, do której reguła kieruje.</param>
public sealed record PutawayRuleResponse(
    [property: JsonPropertyName("rule_id")] string RuleId,
    [property: JsonPropertyName("priority")] short Priority,
    [property: JsonPropertyName("iso_size_type")] string? IsoSizeType,
    [property: JsonPropertyName("is_reefer")] bool? Reefer,
    [property: JsonPropertyName("hazard_class_code")] string? HazardClassCode,
    [property: JsonPropertyName("target_zone_kind")] string TargetZoneKind);
