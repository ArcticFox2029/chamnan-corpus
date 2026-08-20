// -----------------------------------------------------------------------------------------------
// Rejestracja połączeń wychodzących. Magazyn woła synchronicznie identity-service, container-registry,
// geo-service, document-service, audit-ledger i analytics-pipeline — i nic poza tym. Żadna z tych
// usług nie woła magazynu z powrotem, więc graf pozostaje acykliczny; dołożenie tu klienta usługi,
// która nas woła, złamałoby regułę §7 pkt 8 i zostanie odrzucone na przeglądzie.
// -----------------------------------------------------------------------------------------------

using System.Net;
using Grpc.Net.Client;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using OrbitalFreight.Warehouse.Domain.Abstractions;
using OrbitalFreight.Warehouse.Infrastructure.Clients;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;

namespace OrbitalFreight.Warehouse.Api.DependencyInjection;

/// <summary>
/// Klienci HTTP i kanały gRPC wraz z limitami czasu. Limity są krótkie i celowo nierówne: skan
/// w container-registry blokuje magazyniera stojącego przy regale, a wysyłka dokumentu dzieje się
/// w tle, więc może poczekać dłużej.
/// </summary>
public static class OutboundClientsModule
{
    private static readonly TimeSpan RegistryTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan DocumentTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan AnalyticsTimeout = TimeSpan.FromSeconds(30);

    /// <summary>Rejestruje wszystkich klientów wychodzących.</summary>
    /// <param name="services">Kolekcja usług.</param>
    public static IServiceCollection AddWarehouseOutboundClients(this IServiceCollection services)
    {
        // Uchwyt dokładający nagłówki z §0.3 i token usługowy z identity-service. Musi być
        // przejściowy: trzyma kontekst żądania, a ten zmienia się z każdą wiadomością i żądaniem.
        services.AddTransient<PlatformHeadersHandler>();

        services.AddHttpClient<IServiceTokenProvider, IdentityServiceTokenProvider>((provider, http) =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;

            // Token pobieramy po HTTP z tej samej usługi, której gRPC służy do introspekcji.
            // Adres bierzemy z OF_IDENTITY_JWKS_URL, bo to jedyna zmienna z §5, która niesie
            // nazwę hosta identity-service w postaci URL-a.
            http.BaseAddress = new Uri(new Uri(options.IdentityJwksUrl), "/");
            http.Timeout = TimeSpan.FromSeconds(4);
        });

        services
            .AddHttpClient<IContainerRegistryPort, ContainerRegistryClient>((provider, http) =>
            {
                var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
                http.BaseAddress = new Uri(options.ContainerRegistryBaseUrl);
                http.Timeout = RegistryTimeout;
            })
            .AddHttpMessageHandler<PlatformHeadersHandler>()
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                // Pula połączeń odnawiana co dwie minuty, żeby nadążyć za przenoszeniem podów
                // container-registry; bez tego klient trzymał adres poda, którego już nie ma.
                PooledConnectionLifetime = TimeSpan.FromMinutes(2),
                AutomaticDecompression = DecompressionMethods.All
            });

        services
            .AddHttpClient<IDocumentPort, DocumentServiceClient>((provider, http) =>
            {
                var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
                http.BaseAddress = new Uri(options.DocumentBaseUrl);
                http.Timeout = DocumentTimeout;
            })
            .AddHttpMessageHandler<PlatformHeadersHandler>();

        services
            .AddHttpClient<IUtilisationSnapshotPort, AnalyticsMetricsClient>((provider, http) =>
            {
                var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
                http.BaseAddress = new Uri(options.AnalyticsBaseUrl);
                http.Timeout = AnalyticsTimeout;
            })
            .AddHttpMessageHandler<PlatformHeadersHandler>();

        // Kanały gRPC są długowieczne i wielowątkowe — tworzenie kanału na wywołanie kosztowało
        // nas pełne uzgodnienie TLS przy każdym skanie, co widać było wprost w opóźnieniu p99.
        services.AddKeyedSingleton(GeoChannel, (provider, _) =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
            return GrpcChannel.ForAddress($"http://{options.GeoGrpcAddr}");
        });

        services.AddKeyedSingleton(LedgerChannel, (provider, _) =>
        {
            var options = provider.GetRequiredService<IOptions<WarehouseOptions>>().Value;
            return GrpcChannel.ForAddress($"http://{options.AuditLedgerGrpcAddr}");
        });

        services.AddScoped<IGeoPort>(provider => new GeoServiceClient(
            provider.GetRequiredKeyedService<GrpcChannel>(GeoChannel),
            provider.GetRequiredService<ILogger<GeoServiceClient>>()));

        services.AddScoped<IAuditLedgerPort>(provider => new AuditLedgerClient(
            provider.GetRequiredKeyedService<GrpcChannel>(LedgerChannel),
            provider.GetRequiredService<IRequestContext>()));

        return services;
    }

    /// <summary>Klucz kanału do <c>geo.v1.GeoService</c>.</summary>
    private const string GeoChannel = "geo-service";

    /// <summary>Klucz kanału do <c>audit.v1.LedgerService</c>.</summary>
    private const string LedgerChannel = "audit-ledger";
}
