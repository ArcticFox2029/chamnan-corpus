using Microsoft.EntityFrameworkCore;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence;

/// <summary>
/// Kontekst EF Core dla schematu <c>warehouse</c> plus jedno okno na <c>platform.outbox_messages</c>.
/// Poza tymi dwoma miejscami usługa nie dotyka bazy — odczyt cudzego schematu jest zabroniony
/// (§7 pkt 2), więc kontener czy przesyłkę pobieramy z container-registry po HTTP, a nie JOIN-em,
/// mimo że fizycznie stoją w tym samym klastrze PostgreSQL.
/// </summary>
/// <param name="options">Opcje z <c>OF_DATABASE_URL</c>; ciąg połączenia zawiera <c>search_path=warehouse</c>.</param>
public sealed class WarehouseDbContext(DbContextOptions<WarehouseDbContext> options) : DbContext(options)
{
    /// <summary>Strefy magazynowe.</summary>
    public DbSet<ZoneEntity> Zones => Set<ZoneEntity>();

    /// <summary>Gniazda.</summary>
    public DbSet<SlotEntity> Slots => Set<SlotEntity>();

    /// <summary>Rozstawienia kontenerów.</summary>
    public DbSet<PlacementEntity> Placements => Set<PlacementEntity>();

    /// <summary>Reguły adresowania przy przyjęciu.</summary>
    public DbSet<PutawayRuleEntity> PutawayRules => Set<PutawayRuleEntity>();

    /// <summary>Fale kompletacyjne.</summary>
    public DbSet<PickWaveEntity> PickWaves => Set<PickWaveEntity>();

    /// <summary>Zadania kompletacji.</summary>
    public DbSet<PickTaskEntity> PickTasks => Set<PickTaskEntity>();

    /// <summary>Plany inwentaryzacji ciągłej.</summary>
    public DbSet<CycleCountPlanEntity> CycleCountPlans => Set<CycleCountPlanEntity>();

    /// <summary>Liczenia gniazd.</summary>
    public DbSet<CycleCountTaskEntity> CycleCounts => Set<CycleCountTaskEntity>();

    /// <summary>Rozbieżności inwentaryzacyjne.</summary>
    public DbSet<CountVarianceEntity> Variances => Set<CountVarianceEntity>();

    /// <summary>Skrzynka nadawcza w schemacie <c>platform</c>.</summary>
    public DbSet<OutboxMessageEntity> Outbox => Set<OutboxMessageEntity>();

    /// <summary>Zapamiętane odpowiedzi na żądania mutujące.</summary>
    public DbSet<IdempotencyRecordEntity> IdempotencyRecords => Set<IdempotencyRecordEntity>();

    /// <inheritdoc />
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema("warehouse");
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(WarehouseDbContext).Assembly);

        // Migracje mieszkają w db/ i są własnością zespołu bazodanowego — EF Core wyłącznie
        // odwzorowuje istniejący schemat i nie ma prawa go tworzyć. Stąd brak migracji w tym
        // projekcie i stąd testy sprawdzające model względem migracji w potoku CI.
        base.OnModelCreating(modelBuilder);
    }
}
