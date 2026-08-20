using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Configurations;

/// <summary>
/// Odwzorowanie operacji magazynowych: fale kompletacyjne, zadania, plany inwentaryzacji,
/// liczenia, rozbieżności, skrzynka nadawcza i klucze idempotencji. Wszystko, co ląduje na
/// terminalu magazyniera, ma tu indeks — hala pracuje na trzy zmiany i zapytania z terminala
/// są najgorętszym odczytem w całej usłudze.
/// </summary>
public sealed class PickWaveMapping : IEntityTypeConfiguration<PickWaveEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<PickWaveEntity> builder)
    {
        builder.ToTable("pick_waves", "warehouse");
        builder.HasKey(w => w.WaveId);

        builder.Property(w => w.WaveId).HasColumnName("wave_id").HasMaxLength(30);
        builder.Property(w => w.FacilityId).HasColumnName("facility_id").HasMaxLength(30).IsRequired();
        builder.Property(w => w.TenantId).HasColumnName("tenant_id").HasMaxLength(30).IsRequired();
        builder.Property(w => w.Strategy).HasColumnName("strategy").IsRequired();
        builder.Property(w => w.State).HasColumnName("state").IsRequired();
        builder.Property(w => w.TotalDistanceM).HasColumnName("total_distance_m");
        builder.Property(w => w.EstimatedSeconds).HasColumnName("estimated_seconds");
        builder.Property(w => w.PlannedAt).HasColumnName("planned_at");
        builder.Property(w => w.ReleasedAt).HasColumnName("released_at");
        builder.Property(w => w.CompletedAt).HasColumnName("completed_at");

        // Indeks częściowy pod pytanie "co jest otwarte w tym obiekcie" — fale zamknięte stanowią
        // po pół roku 99 % tabeli i nie ma powodu ich indeksować.
        builder.HasIndex(w => new { w.FacilityId, w.State })
            .HasDatabaseName("pick_waves_open_idx")
            .HasFilter("state IN ('planned','released','picking')");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.pick_tasks</c>.</summary>
public sealed class PickTaskMapping : IEntityTypeConfiguration<PickTaskEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<PickTaskEntity> builder)
    {
        builder.ToTable("pick_tasks", "warehouse");
        builder.HasKey(t => t.TaskId);

        builder.Property(t => t.TaskId).HasColumnName("task_id").HasMaxLength(30);
        builder.Property(t => t.WaveId).HasColumnName("wave_id").HasMaxLength(30).IsRequired();
        builder.Property(t => t.SlotId).HasColumnName("slot_id").HasMaxLength(30).IsRequired();
        builder.Property(t => t.ContainerId).HasColumnName("container_id").HasMaxLength(30).IsRequired();
        builder.Property(t => t.ShipmentId).HasColumnName("shipment_id").HasMaxLength(30).IsRequired();
        builder.Property(t => t.SeqNo).HasColumnName("seq_no");
        builder.Property(t => t.State).HasColumnName("state").IsRequired();
        builder.Property(t => t.AssignedUserId).HasColumnName("assigned_user_id").HasMaxLength(30);
        builder.Property(t => t.TravelCostM).HasColumnName("travel_cost_m");
        builder.Property(t => t.StartedAt).HasColumnName("started_at");
        builder.Property(t => t.CompletedAt).HasColumnName("completed_at");
        builder.Property(t => t.ScanId).HasColumnName("scan_id").HasMaxLength(30);

        builder.HasOne(t => t.Wave)
            .WithMany(w => w.Tasks)
            .HasForeignKey(t => t.WaveId)
            .OnDelete(DeleteBehavior.Cascade);

        builder.HasIndex(t => new { t.WaveId, t.SeqNo }).IsUnique().HasDatabaseName("pick_tasks_sequence_uidx");

        // Jeden kontener nie może wisieć w dwóch otwartych zadaniach naraz. Sprawdza to indeks
        // częściowy, a nie kod — dwie fale planowane równolegle trafiłyby w tę samą lukę czasową.
        builder.HasIndex(t => t.ContainerId)
            .IsUnique()
            .HasDatabaseName("pick_tasks_container_open_uidx")
            .HasFilter("state IN ('pending','in_progress')");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.cycle_count_plans</c>.</summary>
public sealed class CycleCountPlanMapping : IEntityTypeConfiguration<CycleCountPlanEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<CycleCountPlanEntity> builder)
    {
        builder.ToTable("cycle_count_plans", "warehouse");
        builder.HasKey(p => p.PlanId);

        builder.Property(p => p.PlanId).HasColumnName("plan_id").HasMaxLength(30);
        builder.Property(p => p.FacilityId).HasColumnName("facility_id").HasMaxLength(30).IsRequired();
        builder.Property(p => p.TenantId).HasColumnName("tenant_id").HasMaxLength(30).IsRequired();
        builder.Property(p => p.Method).HasColumnName("method").IsRequired();
        builder.Property(p => p.ScheduledOn).HasColumnName("scheduled_on");
        builder.Property(p => p.Seed).HasColumnName("seed");
        builder.Property(p => p.SlotCount).HasColumnName("slot_count");
        builder.Property(p => p.CreatedAt).HasColumnName("created_at");
        builder.Property(p => p.ClosedAt).HasColumnName("closed_at");

        // Jeden plan na obiekt i dzień roboczy. Druga próba tego samego dnia to ponowne liczenie
        // metodą blind_recount, które ma własny plan i własną datę.
        builder.HasIndex(p => new { p.FacilityId, p.ScheduledOn, p.Method })
            .IsUnique()
            .HasDatabaseName("cycle_count_plans_day_uidx");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.cycle_count_tasks</c>.</summary>
public sealed class CycleCountTaskMapping : IEntityTypeConfiguration<CycleCountTaskEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<CycleCountTaskEntity> builder)
    {
        builder.ToTable("cycle_count_tasks", "warehouse");
        builder.HasKey(c => c.CountId);

        builder.Property(c => c.CountId).HasColumnName("count_id").HasMaxLength(30);
        builder.Property(c => c.PlanId).HasColumnName("plan_id").HasMaxLength(30).IsRequired();
        builder.Property(c => c.SlotId).HasColumnName("slot_id").HasMaxLength(30).IsRequired();
        builder.Property(c => c.ExpectedContainerId).HasColumnName("expected_container_id").HasMaxLength(30);
        builder.Property(c => c.ObservedContainerId).HasColumnName("observed_container_id").HasMaxLength(30);
        builder.Property(c => c.CountedByUserId).HasColumnName("counted_by_user_id").HasMaxLength(30);
        builder.Property(c => c.CountedAt).HasColumnName("counted_at");
        builder.Property(c => c.RecordedAt).HasColumnName("recorded_at");

        builder.HasIndex(c => new { c.PlanId, c.SlotId }).IsUnique().HasDatabaseName("cycle_count_tasks_slot_uidx");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.count_variances</c>.</summary>
public sealed class CountVarianceMapping : IEntityTypeConfiguration<CountVarianceEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<CountVarianceEntity> builder)
    {
        builder.ToTable("count_variances", "warehouse");
        builder.HasKey(v => v.VarianceId);

        builder.Property(v => v.VarianceId).HasColumnName("variance_id").HasMaxLength(30);
        builder.Property(v => v.CountId).HasColumnName("count_id").HasMaxLength(30).IsRequired();
        builder.Property(v => v.SlotId).HasColumnName("slot_id").HasMaxLength(30).IsRequired();
        builder.Property(v => v.FacilityId).HasColumnName("facility_id").HasMaxLength(30).IsRequired();
        builder.Property(v => v.Kind).HasColumnName("kind").IsRequired();
        builder.Property(v => v.ExpectedContainerId).HasColumnName("expected_container_id").HasMaxLength(30);
        builder.Property(v => v.ObservedContainerId).HasColumnName("observed_container_id").HasMaxLength(30);
        builder.Property(v => v.EvidenceDocumentId).HasColumnName("evidence_document_id").HasMaxLength(30);
        builder.Property(v => v.LedgerEntryId).HasColumnName("ledger_entry_id");
        builder.Property(v => v.OpenedAt).HasColumnName("opened_at");
        builder.Property(v => v.ResolvedAt).HasColumnName("resolved_at");
        builder.Property(v => v.ResolutionNote).HasColumnName("resolution_note");

        builder.HasIndex(v => new { v.FacilityId, v.OpenedAt })
            .HasDatabaseName("count_variances_open_idx")
            .HasFilter("resolved_at IS NULL");
    }
}

/// <summary>
/// Odwzorowanie <c>platform.outbox_messages</c>. Schemat jest cudzy (współdzielony), dlatego
/// nazwa schematu jest tu podana wprost i nie dziedziczy domyślnej z kontekstu.
/// </summary>
public sealed class OutboxMessageMapping : IEntityTypeConfiguration<OutboxMessageEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<OutboxMessageEntity> builder)
    {
        builder.ToTable("outbox_messages", "platform");
        builder.HasKey(m => m.EventId);

        builder.Property(m => m.EventId).HasColumnName("event_id").HasMaxLength(30);
        builder.Property(m => m.EventName).HasColumnName("event_name").IsRequired();
        builder.Property(m => m.SchemaVersion).HasColumnName("schema_version");
        builder.Property(m => m.Topic).HasColumnName("topic").IsRequired();
        builder.Property(m => m.PartitionKey).HasColumnName("partition_key").IsRequired();
        builder.Property(m => m.TenantId).HasColumnName("tenant_id").HasMaxLength(30).IsRequired();
        builder.Property(m => m.RegionCode).HasColumnName("region_code").IsRequired();
        builder.Property(m => m.Producer).HasColumnName("producer").IsRequired();
        builder.Property(m => m.TraceId).HasColumnName("trace_id").HasMaxLength(32).IsRequired();
        builder.Property(m => m.Payload).HasColumnName("payload").HasColumnType("jsonb").IsRequired();
        builder.Property(m => m.OccurredAt).HasColumnName("occurred_at");
        builder.Property(m => m.PublishedAt).HasColumnName("published_at");

        builder.HasIndex(m => m.OccurredAt)
            .HasDatabaseName("outbox_unpublished_warehouse_idx")
            .HasFilter("published_at IS NULL AND producer = 'warehouse-service'");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.idempotency_keys</c>.</summary>
public sealed class IdempotencyRecordMapping : IEntityTypeConfiguration<IdempotencyRecordEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<IdempotencyRecordEntity> builder)
    {
        builder.ToTable("idempotency_keys", "warehouse");
        builder.HasKey(r => new { r.TenantId, r.Key });

        builder.Property(r => r.Key).HasColumnName("idempotency_key").HasMaxLength(128);
        builder.Property(r => r.TenantId).HasColumnName("tenant_id").HasMaxLength(30);
        builder.Property(r => r.Endpoint).HasColumnName("endpoint").IsRequired();
        builder.Property(r => r.RequestSha256).HasColumnName("request_sha256").HasMaxLength(64).IsRequired();
        builder.Property(r => r.StatusCode).HasColumnName("status_code");
        builder.Property(r => r.ResponseBody).HasColumnName("response_body").HasColumnType("jsonb").IsRequired();
        builder.Property(r => r.CreatedAt).HasColumnName("created_at");
        builder.Property(r => r.ExpiresAt).HasColumnName("expires_at");

        // Sprzątaniem zajmuje się zadanie w ops/, a nie usługa — indeks jest po to, żeby to
        // zadanie kasowało wsadowo zamiast skanować całą tabelę.
        builder.HasIndex(r => r.ExpiresAt).HasDatabaseName("idempotency_expiry_idx");
    }
}
