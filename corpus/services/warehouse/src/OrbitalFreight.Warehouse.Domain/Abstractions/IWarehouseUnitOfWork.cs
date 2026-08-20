namespace OrbitalFreight.Warehouse.Domain.Abstractions;

/// <summary>
/// Granica transakcji. Istnieje wyłącznie po to, żeby dało się dotrzymać reguły §7 pkt 3:
/// zmiana stanu i zdarzenie, które o niej mówi, zapisują się jedną transakcją — wiersz w
/// tabeli dziedzinowej plus wiersz w <c>platform.outbox_messages</c>. Nie ma w kodzie ścieżki,
/// która publikuje do Kafki obok bazy.
/// </summary>
public interface IWarehouseUnitOfWork
{
    /// <summary>Otwiera transakcję; zagnieżdżone wywołanie zwraca uchwyt do już otwartej.</summary>
    Task<IWarehouseTransaction> BeginAsync(CancellationToken ct);

    /// <summary>Zapisuje zmiany bez domykania transakcji — przydatne przy wsadach zadań fali.</summary>
    Task<int> SaveChangesAsync(CancellationToken ct);
}

/// <summary>Uchwyt transakcji. Porzucenie bez <see cref="CommitAsync"/> oznacza wycofanie.</summary>
public interface IWarehouseTransaction : IAsyncDisposable
{
    /// <summary>Zatwierdza transakcję wraz z wierszami skrzynki nadawczej.</summary>
    Task CommitAsync(CancellationToken ct);

    /// <summary>Jawne wycofanie; wywoływane w gałęziach błędu, żeby nie czekać na finalizator.</summary>
    Task RollbackAsync(CancellationToken ct);
}
