// -----------------------------------------------------------------------------------------------
// Testy planera ścieżki kompletacji. Pilnują dwóch rzeczy, na których planer już raz się wyłożył:
// że trasa nie gubi ani nie dubluje przystanku oraz że sumaryczna droga nie rośnie po włączeniu
// przebiegów 2-opt. Druga własność jest ważniejsza — regres tutaj widać dopiero w hali, jako
// wydłużoną falę.
// -----------------------------------------------------------------------------------------------

using OrbitalFreight.Warehouse.Domain.Picking;
using Xunit;

namespace OrbitalFreight.Warehouse.Tests;

/// <summary>Testy jednostkowe <see cref="PickPathPlanner"/>.</summary>
public sealed class PickPathPlannerTests
{
    [Fact]
    public void Trasa_odwiedza_kazdy_przystanek_dokladnie_raz()
    {
        var planner = new PickPathPlanner(PickPathSettings.Default);
        var stops = Stops(12);

        var path = planner.Plan(stops);

        Assert.Equal(stops.Count, path.Legs.Count);
        Assert.Equal(
            stops.Select(s => s.SlotId).OrderBy(id => id, StringComparer.Ordinal),
            path.Legs.Select(l => l.Stop.SlotId).OrderBy(id => id, StringComparer.Ordinal));
    }

    [Fact]
    public void Numeracja_odcinkow_jest_ciagla_od_jedynki()
    {
        var planner = new PickPathPlanner(PickPathSettings.Default);

        var path = planner.Plan(Stops(7));

        Assert.Equal(Enumerable.Range(1, 7).Select(i => (short)i), path.Legs.Select(l => l.SeqNo));
    }

    [Fact]
    public void Przebiegi_dwuopt_nie_wydluzaja_trasy()
    {
        var stops = Stops(20);
        var without = new PickPathPlanner(PickPathSettings.Default with { TwoOptIterations = 0 }).Plan(stops);
        var tuned = new PickPathPlanner(PickPathSettings.Default with { TwoOptIterations = 25 }).Plan(stops);

        Assert.True(tuned.TotalDistanceM <= without.TotalDistanceM);
    }

    [Fact]
    public void Pusta_fala_daje_trase_zerowa()
    {
        var planner = new PickPathPlanner(PickPathSettings.Default);

        var path = planner.Plan([]);

        Assert.Empty(path.Legs);
        Assert.Equal(0, path.TotalDistanceM);
        Assert.Equal(0, path.EstimatedSeconds);
    }

    [Fact]
    public void Czas_rosnie_z_liczba_przystankow_bo_obsluga_kosztuje()
    {
        var planner = new PickPathPlanner(PickPathSettings.Default);

        var shorter = planner.Plan(Stops(3));
        var longer = planner.Plan(Stops(9));

        Assert.True(longer.EstimatedSeconds > shorter.EstimatedSeconds);
    }

    /// <summary>
    /// Buduje przystanki rozrzucone po hali. Współrzędne są deterministyczne, ale celowo
    /// nieuporządkowane — trasa podana już posortowana nie sprawdziłaby niczego.
    /// </summary>
    /// <param name="count">Liczba przystanków.</param>
    private static IReadOnlyList<PickStop> Stops(int count) =>
        Enumerable.Range(0, count)
            .Select(i => new PickStop(
                SlotId: $"slt_{i:D26}",
                ContainerId: $"cnt_{i:D26}",
                ShipmentId: "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
                Aisle: (short)(1 + i * 7 % 12),
                Bay: (short)(1 + i * 13 % 40),
                Level: (short)(i % 4),
                TravelCostM: 15 + i * 11 % 180))
            .ToList();
}
