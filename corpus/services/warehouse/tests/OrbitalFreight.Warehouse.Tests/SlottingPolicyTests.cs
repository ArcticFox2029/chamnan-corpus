// -----------------------------------------------------------------------------------------------
// Testy reguł adresowania. Sprawdzają to, co w hali kosztuje najwięcej, gdy zawiedzie: że towar pod
// dozorem celnym nie opuści strefy bonded, że kontener chłodniczy nie stanie bez zasilania i że
// separacja ADR wygrywa z każdą regułą miękką. Klasa SlottingPolicy jest czysta, więc wszystko
// poniżej działa bez bazy i bez brokera.
// -----------------------------------------------------------------------------------------------

using OrbitalFreight.Warehouse.Domain.Model;
using OrbitalFreight.Warehouse.Domain.Slotting;
using Xunit;

namespace OrbitalFreight.Warehouse.Tests;

/// <summary>Testy jednostkowe <see cref="SlottingPolicy"/>.</summary>
public sealed class SlottingPolicyTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 14, 9, 21, 44, TimeSpan.Zero);

    private readonly SlottingPolicy _policy = new(SlottingWeights.Default);

    [Fact]
    public void Odrzuca_gniazdo_bez_zasilania_dla_kontenera_chlodniczego()
    {
        var request = Request(requiresPower: true, setpointC: -18m);
        var candidate = Candidate(Slot(powered: false), Zone(ZoneKind.Rack));

        var score = Assert.Single(_policy.Rank(request, [candidate]));

        Assert.False(score.IsEligible);
        Assert.Equal("power_required", score.ReasonCode);
    }

    [Fact]
    public void Nie_wypuszcza_towaru_pod_dozorem_celnym_poza_strefe_bonded()
    {
        var request = Request(underCustomsControl: true);
        var rack = Candidate(Slot(slotId: "slt_rack"), Zone(ZoneKind.Rack));
        var bonded = Candidate(Slot(slotId: "slt_bonded"), Zone(ZoneKind.Bonded));

        var chosen = _policy.Choose(request, [rack, bonded]);

        // Zdjęcie flagi należy do konsumenta 'customs.declaration.cleared' — polityka nigdy nie
        // rozstrzyga tego sama, bo nie wolno jej pytać customs-service synchronicznie.
        Assert.NotNull(chosen);
        Assert.Equal("slt_bonded", chosen!.SlotId);
    }

    [Fact]
    public void Separacja_adr_odrzuca_sasiedztwo_utleniacza()
    {
        var request = Request(hazardClassCode: "3");
        var candidate = Candidate(
            Slot(),
            Zone(ZoneKind.Rack),
            neighbours: ["5.1"]);

        var score = Assert.Single(_policy.Rank(request, [candidate]));

        Assert.False(score.IsEligible);
        Assert.Equal("hazard_segregation_conflict", score.ReasonCode);
    }

    [Fact]
    public void Bliskosc_rampy_wygrywa_przy_rownych_pozostalych_warunkach()
    {
        var request = Request();
        var near = Candidate(Slot(slotId: "slt_near", travelCostM: 20), Zone(ZoneKind.Rack));
        var far = Candidate(Slot(slotId: "slt_far", travelCostM: 180), Zone(ZoneKind.Rack));

        var ranked = _policy.Rank(request, [far, near]);

        Assert.Equal("slt_near", ranked[0].SlotId);
        Assert.True(ranked[0].Score > ranked[1].Score);
    }

    [Fact]
    public void Nie_adresuje_do_strefy_z_innego_regionu()
    {
        var request = Request();
        var candidate = Candidate(Slot(), Zone(ZoneKind.Rack, regionCode: "latam-br"));

        var score = Assert.Single(_policy.Rank(request, [candidate]));

        Assert.False(score.IsEligible);
        Assert.Equal("region_mismatch", score.ReasonCode);
    }

    [Fact]
    public void Pilnosc_rosnie_gdy_termin_sla_mija()
    {
        Assert.Equal(1.0, SlottingRequest.UrgencyFrom(null, Now));
        Assert.Equal(1.0, SlottingRequest.UrgencyFrom(Now.AddHours(48), Now));
        Assert.Equal(2.0, SlottingRequest.UrgencyFrom(Now.AddMinutes(-5), Now));
    }

    private static SlottingRequest Request(
        bool requiresPower = false,
        decimal? setpointC = null,
        string? hazardClassCode = null,
        bool underCustomsControl = false) =>
        new(
            ContainerId: "cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            ShipmentId: "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            GrossKg: 12_400,
            IsoSizeType: "42G1",
            RequiresPower: requiresPower,
            SetpointC: setpointC,
            HazardClassCode: hazardClassCode,
            IsUnderCustomsControl: underCustomsControl,
            RegionCode: "eu-west",
            UrgencyFactor: 1.0);

    private static Slot Slot(
        string slotId = "slt_01J8ZK4T9QW3RM7XN2VB6HD5PC",
        bool powered = true,
        int travelCostM = 60) =>
        new(
            SlotId: slotId,
            ZoneId: "wzn_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            SlotCode: "A-14-03-2",
            Aisle: 14,
            Bay: 3,
            Level: 2,
            MaxWeightKg: 30_000,
            IsPowered: powered,
            TravelCostM: travelCostM,
            IsBlocked: false,
            BlockedReason: null,
            CreatedAt: Now.AddYears(-2),
            RetiredAt: null);

    private static WarehouseZone Zone(ZoneKind kind, string regionCode = "eu-west") =>
        new(
            ZoneId: "wzn_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            FacilityId: "fac_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            TenantId: "tnt_01J7A0000000000000000000AA",
            Kind: kind,
            TemperatureMinC: kind == ZoneKind.Reefer ? -25m : null,
            TemperatureMaxC: kind == ZoneKind.Reefer ? 8m : null,
            HasPoweredSlots: kind == ZoneKind.Reefer,
            GeofenceId: "gfn_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            RegionCode: regionCode);

    private static SlotCandidate Candidate(
        Slot slot,
        WarehouseZone zone,
        IReadOnlyList<string>? neighbours = null) =>
        new(
            Slot: slot,
            Zone: zone,
            NeighbourHazardClassCodes: neighbours ?? [],
            MaxTravelCostM: 200,
            PoweredSlotsFreeRatio: 0.4,
            SameShipmentInAisle: false,
            SizeFitRatio: 1.0);
}
