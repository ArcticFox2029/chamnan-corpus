using Microsoft.EntityFrameworkCore;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Infrastructure.Messaging;

/// <summary>
/// Pamięć obsłużonych zdarzeń oparta na tabeli <c>warehouse.processed_events</c>. Dostawa
/// „co najmniej raz” jest kontraktem platformy (§4.19 pkt 1), więc bez tego stołu każde
/// przetasowanie partycji odtwarzałoby przyjęcia i rozbieżności po raz drugi.
/// </summary>
/// <remarks>
/// Wstawienie jest warunkowe (<c>ON CONFLICT DO NOTHING</c>), a nie „sprawdź i wstaw” — dwa pody
/// tej samej grupy konsumenckiej mogą dostać tę samą wiadomość przy rebalansie i tylko baza
/// rozstrzygnie, który z nich był pierwszy. Stare wiersze kasuje zadanie z <c>ops/</c> po upływie
/// najdłuższego okna retencji tematu, czyli po 90 dniach (<c>of.customs.v1</c>).
/// </remarks>
/// <param name="db">Kontekst schematu <c>warehouse</c>.</param>
public sealed class PostgresEventDeduplicationStore(WarehouseDbContext db) : IEventDeduplicationStore
{
    private readonly WarehouseDbContext _db = db;

    /// <inheritdoc />
    public async Task<bool> HasSeenAsync(string eventId, CancellationToken ct)
    {
        var rows = await _db.Database
            .SqlQuery<int>($"SELECT 1 AS \"Value\" FROM warehouse.processed_events WHERE event_id = {eventId}")
            .ToListAsync(ct);

        return rows.Count > 0;
    }

    /// <inheritdoc />
    public async Task MarkSeenAsync(string eventId, CancellationToken ct)
    {
        await _db.Database.ExecuteSqlAsync(
            $"""
             INSERT INTO warehouse.processed_events (event_id, processed_at)
             VALUES ({eventId}, now())
             ON CONFLICT (event_id) DO NOTHING
             """,
            ct);
    }
}
