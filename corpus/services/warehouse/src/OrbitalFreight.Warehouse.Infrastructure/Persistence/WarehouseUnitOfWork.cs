using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence;

/// <summary>
/// Transakcja spinająca zmianę stanu z wierszem w <c>platform.outbox_messages</c>. Bez niej
/// dałoby się zapisać rozstawienie i zgubić zdarzenie o nim — dokładnie ten scenariusz reguła
/// §7 pkt 3 wyklucza.
/// </summary>
/// <param name="db">Kontekst schematu <c>warehouse</c>.</param>
public sealed class WarehouseUnitOfWork(WarehouseDbContext db) : IWarehouseUnitOfWork
{
    private readonly WarehouseDbContext _db = db;

    /// <inheritdoc />
    public async Task<IWarehouseTransaction> BeginAsync(CancellationToken ct)
    {
        // Zagnieżdżone wywołanie nie otwiera drugiej transakcji, tylko oddaje uchwyt-atrapę.
        // Dzięki temu usługa aplikacyjna może wołać repozytorium bez sprawdzania, czy ktoś
        // wyżej już transakcję otworzył.
        if (_db.Database.CurrentTransaction is not null)
        {
            return new NestedTransaction();
        }

        var transaction = await _db.Database.BeginTransactionAsync(ct);
        return new EfTransaction(transaction);
    }

    /// <inheritdoc />
    public Task<int> SaveChangesAsync(CancellationToken ct) => _db.SaveChangesAsync(ct);

    private sealed class EfTransaction(IDbContextTransaction transaction) : IWarehouseTransaction
    {
        private readonly IDbContextTransaction _transaction = transaction;
        private bool _finished;

        public async Task CommitAsync(CancellationToken ct)
        {
            await _transaction.CommitAsync(ct);
            _finished = true;
        }

        public async Task RollbackAsync(CancellationToken ct)
        {
            await _transaction.RollbackAsync(ct);
            _finished = true;
        }

        public async ValueTask DisposeAsync()
        {
            // Porzucenie bez commitu jest wycofaniem — jawnie, żeby nie zależeć od tego, co
            // dostawca zrobi w Dispose.
            if (!_finished)
            {
                await _transaction.RollbackAsync(CancellationToken.None);
            }

            await _transaction.DisposeAsync();
        }
    }

    private sealed class NestedTransaction : IWarehouseTransaction
    {
        public Task CommitAsync(CancellationToken ct) => Task.CompletedTask;

        public Task RollbackAsync(CancellationToken ct) => Task.CompletedTask;

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
