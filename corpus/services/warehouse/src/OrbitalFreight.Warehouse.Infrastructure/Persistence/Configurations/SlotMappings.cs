using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using OrbitalFreight.Warehouse.Infrastructure.Persistence.Entities;

namespace OrbitalFreight.Warehouse.Infrastructure.Persistence.Configurations;

/// <summary>
/// Odwzorowanie topologii magazynu na tabele <c>warehouse.zones</c>, <c>warehouse.slots</c>,
/// <c>warehouse.slot_placements</c> i <c>warehouse.putaway_rules</c>. Nazwy kolumn są pisane
/// jawnie, a nie generowane konwencją — schemat jest wspólny z migracjami w <c>db/</c> i to one,
/// nie ten plik, są w tym sporze stroną rozstrzygającą.
/// </summary>
public sealed class ZoneMapping : IEntityTypeConfiguration<ZoneEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<ZoneEntity> builder)
    {
        builder.ToTable("zones", "warehouse");
        builder.HasKey(z => z.ZoneId);

        builder.Property(z => z.ZoneId).HasColumnName("zone_id").HasMaxLength(30);
        builder.Property(z => z.FacilityId).HasColumnName("facility_id").HasMaxLength(30).IsRequired();
        builder.Property(z => z.TenantId).HasColumnName("tenant_id").HasMaxLength(30).IsRequired();
        builder.Property(z => z.Kind).HasColumnName("kind").IsRequired();
        builder.Property(z => z.TemperatureMinC).HasColumnName("temperature_min_c").HasPrecision(5, 2);
        builder.Property(z => z.TemperatureMaxC).HasColumnName("temperature_max_c").HasPrecision(5, 2);
        builder.Property(z => z.HasPoweredSlots).HasColumnName("has_powered_slots");
        builder.Property(z => z.GeofenceId).HasColumnName("geofence_id").HasMaxLength(30).IsRequired();
        builder.Property(z => z.RegionCode).HasColumnName("region_code").IsRequired();

        // Obiekt i geofence są kluczami obcymi wyłącznie logicznymi: pierwszy należy do
        // container-registry, drugi do geo-service. Baza ich nie pilnuje, pilnuje tego walidacja
        // przy zakładaniu strefy, która woła 'geo.v1.GeoService/ResolveGeofence'.
        builder.HasIndex(z => new { z.FacilityId, z.Kind }).HasDatabaseName("zones_facility_kind_idx");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.slots</c>.</summary>
public sealed class SlotMapping : IEntityTypeConfiguration<SlotEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<SlotEntity> builder)
    {
        builder.ToTable("slots", "warehouse");
        builder.HasKey(s => s.SlotId);

        builder.Property(s => s.SlotId).HasColumnName("slot_id").HasMaxLength(30);
        builder.Property(s => s.ZoneId).HasColumnName("zone_id").HasMaxLength(30).IsRequired();
        builder.Property(s => s.SlotCode).HasColumnName("slot_code").HasMaxLength(24).IsRequired();
        builder.Property(s => s.Aisle).HasColumnName("aisle");
        builder.Property(s => s.Bay).HasColumnName("bay");
        builder.Property(s => s.Level).HasColumnName("level");
        builder.Property(s => s.MaxWeightKg).HasColumnName("max_weight_kg");
        builder.Property(s => s.IsPowered).HasColumnName("is_powered");
        builder.Property(s => s.TravelCostM).HasColumnName("travel_cost_m");
        builder.Property(s => s.IsBlocked).HasColumnName("is_blocked");
        builder.Property(s => s.BlockedReason).HasColumnName("blocked_reason");
        builder.Property(s => s.CreatedAt).HasColumnName("created_at");
        builder.Property(s => s.RetiredAt).HasColumnName("retired_at");

        builder.HasOne(s => s.Zone)
            .WithMany(z => z.Slots)
            .HasForeignKey(s => s.ZoneId)
            .OnDelete(DeleteBehavior.Restrict);

        // Etykieta gniazda musi być jednoznaczna w obrębie strefy, bo magazynier wpisuje ją
        // ręcznie, gdy kod kreskowy jest zdarty.
        builder.HasIndex(s => new { s.ZoneId, s.SlotCode }).IsUnique().HasDatabaseName("slots_code_uidx");

        // Indeks pod planer ścieżek: serpentyna czyta gniazda dokładnie w tej kolejności.
        builder.HasIndex(s => new { s.ZoneId, s.Aisle, s.Bay, s.Level }).HasDatabaseName("slots_walk_order_idx");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.slot_placements</c>.</summary>
public sealed class PlacementMapping : IEntityTypeConfiguration<PlacementEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<PlacementEntity> builder)
    {
        builder.ToTable("slot_placements", "warehouse");
        builder.HasKey(p => p.PlacementId);

        builder.Property(p => p.PlacementId).HasColumnName("placement_id").HasMaxLength(30);
        builder.Property(p => p.SlotId).HasColumnName("slot_id").HasMaxLength(30).IsRequired();
        builder.Property(p => p.ContainerId).HasColumnName("container_id").HasMaxLength(30).IsRequired();
        builder.Property(p => p.ShipmentId).HasColumnName("shipment_id").HasMaxLength(30);
        builder.Property(p => p.GrossKg).HasColumnName("gross_kg");
        builder.Property(p => p.HazardClassCode).HasColumnName("hazard_class_code");
        builder.Property(p => p.RequiresPower).HasColumnName("requires_power");
        builder.Property(p => p.PlacedAt).HasColumnName("placed_at");
        builder.Property(p => p.RemovedAt).HasColumnName("removed_at");

        // Kolumna active_period jest wyliczana przez bazę i to na niej stoi EXCLUDE USING gist.
        // EF Core musi o niej wiedzieć tyle, żeby jej nie próbował zapisywać.
        builder.Property<NpgsqlTypes.NpgsqlRange<DateTime>>("ActivePeriod")
            .HasColumnName("active_period")
            .ValueGeneratedOnAddOrUpdate()
            .Metadata.SetAfterSaveBehavior(Microsoft.EntityFrameworkCore.Metadata.PropertySaveBehavior.Ignore);

        builder.HasIndex(p => p.ContainerId)
            .HasDatabaseName("placements_container_open_idx")
            .HasFilter("removed_at IS NULL");

        builder.HasIndex(p => p.ShipmentId).HasDatabaseName("placements_shipment_idx");
    }
}

/// <summary>Odwzorowanie tabeli <c>warehouse.putaway_rules</c>.</summary>
public sealed class PutawayRuleMapping : IEntityTypeConfiguration<PutawayRuleEntity>
{
    /// <inheritdoc />
    public void Configure(EntityTypeBuilder<PutawayRuleEntity> builder)
    {
        builder.ToTable("putaway_rules", "warehouse");
        builder.HasKey(r => r.RuleId);

        builder.Property(r => r.RuleId).HasColumnName("rule_id").HasMaxLength(30);
        builder.Property(r => r.FacilityId).HasColumnName("facility_id").HasMaxLength(30).IsRequired();
        builder.Property(r => r.Priority).HasColumnName("priority");
        builder.Property(r => r.IsoSizeType).HasColumnName("iso_size_type").HasMaxLength(4);
        builder.Property(r => r.IsReefer).HasColumnName("is_reefer");
        builder.Property(r => r.HazardClassCode).HasColumnName("hazard_class_code");
        builder.Property(r => r.TargetZoneKind).HasColumnName("target_zone_kind").IsRequired();

        builder.HasIndex(r => new { r.FacilityId, r.Priority }).IsUnique().HasDatabaseName("putaway_rules_order_uidx");
    }
}
