// -----------------------------------------------------------------------------------------------
// Punkt wejścia warehouse-service. Plik składa aplikację z trzech modułów rejestracji, ustawia
// potok HTTP w kolejności wymaganej przez §0.3 i §0.4 i podpina końcówki z §3. Poza kolejnością
// potoku nie ma tu żadnej logiki — wszystko, co robi usługa, mieszka w warstwie aplikacji.
// -----------------------------------------------------------------------------------------------

using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OrbitalFreight.Warehouse.Api.DependencyInjection;
using OrbitalFreight.Warehouse.Api.Endpoints;
using OrbitalFreight.Warehouse.Api.Middleware;
using OrbitalFreight.Warehouse.Infrastructure.Configuration;

var builder = WebApplication.CreateBuilder(args);

// Konfiguracja pochodzi wyłącznie ze zmiennych środowiskowych z §5. Pliki appsettings.json celowo
// nie są czytane: zestaw zmiennych sprawdza ops/validate-env.py w potoku wdrożeniowym i plik
// leżący obok binarki potrafiłby ten sprawdzian obejść.
builder.Configuration.Sources.Clear();
builder.Configuration.AddInMemoryCollection(WarehouseModule.ReadPlatformEnvironment());

builder.Services.AddWarehouseConfiguration(builder.Configuration);
builder.Services.AddWarehouseCore();
builder.Services.AddWarehouseOutboundClients();
builder.Services.AddWarehouseMessaging();

var startupOptions = builder.Configuration
    .GetSection(WarehouseOptions.SectionName)
    .Get<WarehouseOptions>() ?? throw new InvalidOperationException("OF_* environment is incomplete");

builder.WebHost.ConfigureKestrel(kestrel => kestrel.ListenAnyIP(startupOptions.HttpPort));

// OF_SHUTDOWN_GRACE_SECONDS musi zmieścić się w okresie karencji poda, bo inaczej Kubernetes
// zabije proces w trakcie zatwierdzania przesunięcia w Kafce i konsument odtworzy partię od nowa.
builder.Services.Configure<HostOptions>(host =>
    host.ShutdownTimeout = TimeSpan.FromSeconds(startupOptions.ShutdownGraceSeconds));

builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole();

var app = builder.Build();

// Kolejność potoku jest istotna i została ustalona po incydencie, w którym błąd walidacji wychodził
// bez identyfikatora śladu:
//   1. koperta błędu — musi być najbardziej zewnętrzna, żeby złapać także awarie kolejnych warstw,
//   2. kontekst żądania — ustawia najemcę i ślad, z których korzysta wszystko poniżej,
//   3. idempotencja — potrzebuje już znanego najemcy, bo klucz jest unikalny w jego obrębie.
app.UseMiddleware<ErrorEnvelopeMiddleware>();
app.UseMiddleware<RequestContextMiddleware>();
app.UseMiddleware<IdempotencyMiddleware>();

app.MapOperationalEndpoints();
app.MapZoneEndpoints();
app.MapSlottingEndpoints();
app.MapPickWaveEndpoints();
app.MapCycleCountEndpoints();

var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("startup");
logger.LogInformation(
    "warehouse-service listening on {Port} in region {Region} ({Environment})",
    startupOptions.HttpPort,
    startupOptions.RegionCode,
    startupOptions.Environment);

await app.RunAsync();

/// <summary>
/// Uchwyt dla testów integracyjnych z <c>WebApplicationFactory&lt;Program&gt;</c>. Klasa jest pusta
/// z założenia — istnieje tylko po to, żeby wygenerowany typ punktu wejścia był publiczny.
/// </summary>
public partial class Program;
