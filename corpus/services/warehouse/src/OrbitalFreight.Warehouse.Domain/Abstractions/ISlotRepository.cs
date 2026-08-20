using OrbitalFreight.Warehouse.Domain.Model;

namespace OrbitalFreight.Warehouse.Domain.Abstractions;

/// <summary>
/// Jedyna droga do tabel <c>warehouse.zones</c>, <c>warehouse.slots</c> i
/// <c>warehouse.slot_placements</c>. Warstwa domenowa nie zna EF Core — dostaje rekordy,
/// oddaje rekordy, a o transakcję prosi przez <see cref="IWarehouseUnitOfWork"/>.
/// </summary>
public interface ISlotRepository
{
    /// <summary>Wczytuje strefy obiektu wraz z kopertą temperaturową.</summary>
    /// <param name="facilityId">Obiekt z <c>freight.facilities</c>, prefiks <c>fac_</c>.</param>
    /// <param name="ct">Token anulowania żądania.</param>
    Task<IReadOnlyList<WarehouseZone>> GetZonesAsync(string facilityId, CancellationToken ct);

    /// <summary>
    /// Zwraca gniazda kandydujące do rozstawienia: nieblokowane, niewycofane i wolne w chwili
    /// <paramref name="asOf"/>. Zapytanie celowo nie filtruje po nośności — limit masy sprawdza
    /// <c>SlottingPolicy</c>, żeby odrzucenie miało czytelny kod przyczyny zamiast pustej listy.
    /// </summary>
    /// <param name="zoneIds">Strefy, w których wolno szukać (wynik dopasowania <see cref="PutawayRule"/>).</param>
    /// <param name="asOf">Moment, na który liczymy zajętość.</param>
    /// <param name="limit">Górna granica liczby kandydatów; planer i tak ocenia je wszystkie.</param>
    /// <param name="ct">Token anulowania.</param>
    Task<IReadOnlyList<Slot>> GetFreeSlotsAsync(
        IReadOnlyCollection<string> zoneIds,
        DateTimeOffset asOf,
        int limit,
        CancellationToken ct);

    /// <summary>Odczyt pojedynczego gniazda po kluczu.</summary>
    Task<Slot?> FindSlotAsync(string slotId, CancellationToken ct);

    /// <summary>Odczyt gniazda po etykiecie skanowanej terminalem, np. <c>A-14-03-2</c>.</summary>
    Task<Slot?> FindSlotByCodeAsync(string facilityId, string slotCode, CancellationToken ct);

    /// <summary>Strona gniazd obiektu, w kolejności (alejka, zatoka, poziom) — patrz §0.5.</summary>
    Task<CursorPage<Slot>> ListSlotsAsync(string facilityId, string? cursor, int limit, CancellationToken ct);

    /// <summary>
    /// Klasy ADR rozstawione w sąsiedztwie gniazda. Wykorzystywane do sprawdzenia
    /// <c>freight.hazard_classes.segregation_group</c> zanim dołożymy tam kolejny ładunek.
    /// </summary>
    /// <param name="slotId">Gniazdo, wokół którego patrzymy.</param>
    /// <param name="radiusBays">Promień w zatokach; 1 oznacza sąsiadów bezpośrednich.</param>
    /// <param name="ct">Token anulowania.</param>
    Task<IReadOnlyList<string>> GetNeighbourHazardClassesAsync(string slotId, int radiusBays, CancellationToken ct);

    /// <summary>Bieżące rozstawienie w gnieździe albo <see langword="null"/>, gdy gniazdo jest puste.</summary>
    Task<SlotPlacement?> GetActivePlacementAsync(string slotId, CancellationToken ct);

    /// <summary>Bieżące rozstawienie danego kontenera, niezależnie od obiektu.</summary>
    Task<SlotPlacement?> FindActivePlacementByContainerAsync(string containerId, CancellationToken ct);

    /// <summary>
    /// Dopisuje rozstawienie. Konflikt z ograniczeniem wykluczającym na <c>(slot_id, active_period)</c>
    /// jest sygnalizowany wyjątkiem <see cref="SlotOccupiedException"/>, nie cichym nadpisaniem.
    /// </summary>
    Task AddPlacementAsync(SlotPlacement placement, CancellationToken ct);

    /// <summary>Zamyka okres zajętości, stemplując <c>removed_at</c>. DELETE nie istnieje.</summary>
    Task ClosePlacementAsync(string placementId, DateTimeOffset removedAt, CancellationToken ct);

    /// <summary>Zakłada lub zdejmuje blokadę gniazda, np. na czas wyjaśniania rozbieżności.</summary>
    /// <param name="slotId">Gniazdo.</param>
    /// <param name="isBlocked">Nowy stan blokady.</param>
    /// <param name="reason">Powód w <c>snake_case</c>; wymagany przy zakładaniu blokady.</param>
    /// <param name="ct">Token anulowania.</param>
    Task SetSlotBlockedAsync(string slotId, bool isBlocked, string? reason, CancellationToken ct);

    /// <summary>Reguły adresowania obiektu, posortowane rosnąco po priorytecie.</summary>
    Task<IReadOnlyList<PutawayRule>> GetPutawayRulesAsync(string facilityId, CancellationToken ct);
}

/// <summary>
/// Rzucany, gdy dwa równoległe rozstawienia trafiły w to samo gniazdo. Rozstrzyga baza
/// (EXCLUDE USING gist), tak samo jak w <c>fleet.vehicle_assignments</c> — usługa tylko tłumaczy
/// błąd na kod <c>slot_occupied</c> z koperty błędu (§0.4).
/// </summary>
public sealed class SlotOccupiedException(string slotId, string occupyingContainerId)
    : InvalidOperationException($"slot {slotId} is already occupied by {occupyingContainerId}")
{
    /// <summary>Gniazdo, o które toczył się spór.</summary>
    public string SlotId { get; } = slotId;

    /// <summary>Kontener, który wygrał wyścig.</summary>
    public string OccupyingContainerId { get; } = occupyingContainerId;
}
