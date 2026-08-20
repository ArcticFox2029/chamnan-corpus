/// <summary>
/// Model topologii magazynu: strefy, gniazda i to, co w nich aktualnie stoi. Jest to obraz
/// tabel <c>warehouse.zones</c>, <c>warehouse.slots</c> i <c>warehouse.slot_placements</c>
/// widziany przez warstwę domenową — kontener i przesyłkę identyfikujemy tu wyłącznie przez
/// <c>cnt_</c>/<c>shp_</c>, bo ich właścicielem pozostaje container-registry.
/// </summary>

namespace OrbitalFreight.Warehouse.Domain.Model;

/// <summary>
/// Rodzaj strefy. Odpowiada ograniczeniu CHECK na kolumnie <c>warehouse.zones.kind</c>;
/// wartości na drucie są zapisywane w <c>snake_case</c>, tak jak wszędzie na platformie.
/// </summary>
public enum ZoneKind
{
    /// <summary>Rampa przyjęć — miejsce przejściowe, nie wolno tu parkować dłużej niż dobę.</summary>
    InboundDock,

    /// <summary>Skład blokowy, bez regałów; kontener stoi na placu.</summary>
    Bulk,

    /// <summary>Regał wielopoziomowy dla ładunków drobnicowych.</summary>
    Rack,

    /// <summary>Strefa chłodnicza z gniazdami zasilanymi (<c>is_powered</c>).</summary>
    Reefer,

    /// <summary>Skład celny; towar czeka na <c>customs.declaration.cleared</c>.</summary>
    Bonded,

    /// <summary>Rampa wydań — punkt docelowy każdej ścieżki kompletacji.</summary>
    OutboundDock,

    /// <summary>Kwarantanna: uszkodzenia, zerwane plomby, rozbieżności inwentaryzacyjne.</summary>
    Quarantine
}

/// <summary>
/// Strefa magazynowa wewnątrz obiektu z <c>freight.facilities</c> o rodzaju <c>warehouse</c>
/// lub <c>bonded_store</c>. <paramref name="FacilityId"/> jest logicznym kluczem obcym —
/// istnienie obiektu potwierdza container-registry, baza tego nie pilnuje.
/// </summary>
/// <param name="ZoneId">Klucz główny, prefiks <c>wzn_</c>.</param>
/// <param name="FacilityId">Obiekt z <c>freight.facilities</c>, prefiks <c>fac_</c>.</param>
/// <param name="TenantId">Najemca, prefiks <c>tnt_</c>; musi zgadzać się z nagłówkiem <c>X-OF-Tenant</c>.</param>
/// <param name="Kind">Rodzaj strefy.</param>
/// <param name="TemperatureMinC">Dolna granica koperty temperaturowej w °C, <see langword="null"/> dla stref otoczenia.</param>
/// <param name="TemperatureMaxC">Górna granica koperty temperaturowej w °C.</param>
/// <param name="HasPoweredSlots">Czy strefa ma gniazda z zasilaniem dla agregatów chłodniczych.</param>
/// <param name="GeofenceId">Geofence z <c>geo.geofences</c>; rozwiązywany przez geo-service.</param>
/// <param name="RegionCode">Kod regionu z §0.6 — decyduje o rezydencji danych, nie o shardingu.</param>
public sealed record WarehouseZone(
    string ZoneId,
    string FacilityId,
    string TenantId,
    ZoneKind Kind,
    decimal? TemperatureMinC,
    decimal? TemperatureMaxC,
    bool HasPoweredSlots,
    string GeofenceId,
    string RegionCode)
{
    /// <summary>
    /// Czy strefa mieści kontener chłodniczy o zadanym <c>setpoint_c</c>. Kontener bez agregatu
    /// (<c>is_reefer = false</c>) przechodzi zawsze — koperta go nie dotyczy.
    /// </summary>
    public bool AcceptsSetpoint(decimal? setpointC)
    {
        if (setpointC is null)
        {
            return true;
        }

        return (TemperatureMinC is null || setpointC >= TemperatureMinC)
            && (TemperatureMaxC is null || setpointC <= TemperatureMaxC);
    }
}

/// <summary>
/// Pojedyncze gniazdo. <paramref name="TravelCostM"/> to odległość marszowa od rampy wydań
/// tej strefy, w metrach — liczona raz przy zakładaniu gniazda, bo geometria regałów się nie zmienia,
/// a planer ścieżek pyta o nią kilkaset razy na falę.
/// </summary>
/// <param name="SlotId">Klucz główny, prefiks <c>slt_</c>.</param>
/// <param name="ZoneId">Strefa nadrzędna, prefiks <c>wzn_</c>.</param>
/// <param name="SlotCode">Etykieta czytana skanerem, np. <c>A-14-03-2</c>; unikalna w obrębie obiektu.</param>
/// <param name="Aisle">Numer alejki; para (alejka, zatoka) tworzy współrzędne dla planera.</param>
/// <param name="Bay">Numer zatoki wzdłuż alejki.</param>
/// <param name="Level">Poziom regału, 0 = poziom posadzki.</param>
/// <param name="MaxWeightKg">Nośność gniazda w kilogramach (§0.2: masy są całkowite, sufiks <c>_kg</c>).</param>
/// <param name="IsPowered">Czy gniazdo ma zasilanie dla agregatu.</param>
/// <param name="TravelCostM">Odległość marszowa od rampy wydań w metrach.</param>
/// <param name="IsBlocked">Gniazdo wyłączone z użycia (remont, uszkodzenie regału, otwarta rozbieżność).</param>
/// <param name="BlockedReason">Powód blokady w <c>snake_case</c>, np. <c>open_variance</c>.</param>
/// <param name="CreatedAt">Znacznik utworzenia, UTC.</param>
/// <param name="RetiredAt">Wycofanie gniazda; wiersz zostaje, bo wskazują na niego stare zadania.</param>
public sealed record Slot(
    string SlotId,
    string ZoneId,
    string SlotCode,
    short Aisle,
    short Bay,
    short Level,
    int MaxWeightKg,
    bool IsPowered,
    int TravelCostM,
    bool IsBlocked,
    string? BlockedReason,
    DateTimeOffset CreatedAt,
    DateTimeOffset? RetiredAt)
{
    /// <summary>Gniazdo nadające się do przyjęcia towaru tu i teraz.</summary>
    public bool IsUsable => !IsBlocked && RetiredAt is null;
}

/// <summary>
/// Fakt, że dany kontener stoi w danym gnieździe. Zamknięcie okresu to wpis w
/// <c>removed_at</c>, nigdy DELETE — historia rozstawień jest dowodem przy sporach
/// o uszkodzenia i zasila trzystronne uzgodnienie w reconciliation-service.
/// </summary>
/// <param name="PlacementId">Klucz główny, prefiks <c>plc_</c>.</param>
/// <param name="SlotId">Gniazdo, prefiks <c>slt_</c>.</param>
/// <param name="ContainerId">Kontener z <c>freight.containers</c>, prefiks <c>cnt_</c>.</param>
/// <param name="ShipmentId">Przesyłka z <c>freight.shipments</c>; pusta dla pustych kontenerów w składzie.</param>
/// <param name="GrossKg">Masa brutto w chwili odstawienia, przepisana z <c>freight.shipment_containers.gross_kg</c>.</param>
/// <param name="HazardClassCode">Klasa ADR z <c>freight.hazard_classes</c>, jeśli ładunek jest niebezpieczny.</param>
/// <param name="RequiresPower">Wynik <c>freight.containers.is_reefer</c> w chwili rozstawienia.</param>
/// <param name="PlacedAt">Początek okresu zajętości.</param>
/// <param name="RemovedAt">Koniec okresu; <see langword="null"/> oznacza gniazdo zajęte.</param>
public sealed record SlotPlacement(
    string PlacementId,
    string SlotId,
    string ContainerId,
    string? ShipmentId,
    int GrossKg,
    string? HazardClassCode,
    bool RequiresPower,
    DateTimeOffset PlacedAt,
    DateTimeOffset? RemovedAt)
{
    /// <summary>Czy rozstawienie jest bieżące.</summary>
    public bool IsActive => RemovedAt is null;
}

/// <summary>
/// Reguła adresowania towaru przy przyjęciu. Reguły są uporządkowane rosnąco po
/// <paramref name="Priority"/> i wygrywa pierwsza dopasowana — dokładnie tak, jak listy
/// dostępu, bo magazynierzy potrafią czytać taką tabelę bez szkolenia.
/// </summary>
/// <param name="RuleId">Klucz główny, prefiks <c>wpr_</c>.</param>
/// <param name="FacilityId">Obiekt, którego reguła dotyczy.</param>
/// <param name="Priority">Im niższa liczba, tym wcześniej reguła jest sprawdzana.</param>
/// <param name="IsoSizeType">Filtr po <c>freight.containers.iso_size_type</c>, np. <c>45R1</c>; <see langword="null"/> = dowolny.</param>
/// <param name="IsReefer">Filtr po <c>freight.containers.is_reefer</c>; <see langword="null"/> = obojętne.</param>
/// <param name="HazardClassCode">Filtr po klasie ADR; <see langword="null"/> = obojętne.</param>
/// <param name="TargetZoneKind">Strefa, do której reguła kieruje.</param>
public sealed record PutawayRule(
    string RuleId,
    string FacilityId,
    short Priority,
    string? IsoSizeType,
    bool? IsReefer,
    string? HazardClassCode,
    ZoneKind TargetZoneKind)
{
    /// <summary>
    /// Dopasowanie reguły do konkretnego kontenera. Każdy niepusty filtr musi się zgadzać;
    /// puste filtry są przezroczyste.
    /// </summary>
    public bool Matches(string isoSizeType, bool isReefer, string? hazardClassCode) =>
        (IsoSizeType is null || string.Equals(IsoSizeType, isoSizeType, StringComparison.Ordinal))
        && (IsReefer is null || IsReefer == isReefer)
        && (HazardClassCode is null || string.Equals(HazardClassCode, hazardClassCode, StringComparison.Ordinal));
}
