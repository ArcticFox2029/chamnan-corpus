using Grpc.Core;
using Grpc.Net.Client;
using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Domain.Abstractions;

namespace OrbitalFreight.Warehouse.Infrastructure.Clients;

/// <summary>
/// Klient gRPC do geo-service. Używany w dwóch miejscach: przy zakładaniu strefy, żeby
/// potwierdzić istnienie geofence'u z <c>geo.geofences</c>, i przy potwierdzaniu skanu, żeby
/// sprawdzić, czy pozycja terminala mieści się w obwiedni obiektu.
/// </summary>
/// <remarks>
/// geo-service trzyma wynik <c>geo.v1.GeoService/ResolveGeofence</c> w pamięci przez 30 sekund
/// z kluczem po <c>X-OF-Trace-Id</c> (§1.2, diament A). Dlatego ślad przekazujemy dalej zamiast
/// generować nowy — dwa wywołania w obrębie jednej operacji magazynowej mają trafić w ten sam
/// wpis pamięci podręcznej, a nie policzyć geometrię dwa razy.
/// </remarks>
/// <param name="channel">Kanał do <c>OF_GEO_GRPC_ADDR</c>.</param>
/// <param name="logger">Dziennik.</param>
public sealed class GeoServiceClient(GrpcChannel channel, ILogger<GeoServiceClient> logger) : IGeoPort
{
    private readonly GrpcChannel _channel = channel;
    private readonly ILogger<GeoServiceClient> _logger = logger;

    /// <inheritdoc />
    public async Task<GeofenceSnapshot?> ResolveGeofenceAsync(string geofenceId, CancellationToken ct)
    {
        var client = new Gen.Geo.V1.GeoService.GeoServiceClient(_channel);

        try
        {
            var reply = await client.ResolveGeofenceAsync(
                new Gen.Geo.V1.ResolveGeofenceRequest { GeofenceId = geofenceId },
                cancellationToken: ct);

            return new GeofenceSnapshot(reply.GeofenceId, reply.Name, reply.Kind, reply.BufferM);
        }
        catch (RpcException ex) when (ex.StatusCode == StatusCode.NotFound)
        {
            _logger.LogWarning("geofence {GeofenceId} does not exist in geo-service", geofenceId);
            return null;
        }
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<bool>> PointsInFenceAsync(
        string geofenceId,
        IReadOnlyList<(double Latitude, double Longitude)> points,
        CancellationToken ct)
    {
        if (points.Count == 0)
        {
            return [];
        }

        var client = new Gen.Geo.V1.GeoService.GeoServiceClient(_channel);
        var request = new Gen.Geo.V1.PointInFenceRequest { GeofenceId = geofenceId };

        foreach (var (latitude, longitude) in points)
        {
            request.Points.Add(new Gen.Geo.V1.Point { Lat = latitude, Lon = longitude });
        }

        var reply = await client.PointInFenceAsync(request, cancellationToken: ct);

        if (reply.Inside.Count != points.Count)
        {
            // Kontrakt mówi, że wynik ma tę samą długość co wejście. Rozjazd oznacza niezgodność
            // wersji stubów, a nie dane — lepiej zatrzymać operację, niż dopasowywać po indeksie.
            throw new InvalidOperationException(
                $"geo-service returned {reply.Inside.Count} results for {points.Count} points");
        }

        return reply.Inside.ToList();
    }
}
