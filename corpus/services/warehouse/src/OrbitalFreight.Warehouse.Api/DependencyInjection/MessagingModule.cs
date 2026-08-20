// -----------------------------------------------------------------------------------------------
// Rejestracja czterech konsumentów zdarzeń i dwóch zadań w tle. Magazyn jest przede wszystkim
// konsumentem: reaguje na to, co zgłoszą container-registry, telemetry-ingest i customs-service,
// zamiast odpytywać je w pętli. Każdy konsument dostaje własny hosted service, bo pojedyncza pętla
// na cztery tematy oznaczała, że zator na of.telemetry.v1 wstrzymywał także przyjęcia towaru.
// -----------------------------------------------------------------------------------------------

using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OrbitalFreight.Warehouse.Infrastructure.Maintenance;
using OrbitalFreight.Warehouse.Infrastructure.Messaging;
using OrbitalFreight.Warehouse.Infrastructure.Persistence;

namespace OrbitalFreight.Warehouse.Api.DependencyInjection;

/// <summary>
/// Podpięcie subskrypcji Kafki oraz procesów okresowych. Kolejność rejestracji nie ma znaczenia —
/// hosted services startują równolegle — ale przekaźnik skrzynki nadawczej rejestrujemy pierwszy,
/// żeby był widoczny na liście przy diagnozowaniu zaległości publikacji.
/// </summary>
public static class MessagingModule
{
    /// <summary>Rejestruje konsumentów zdarzeń i zadania w tle.</summary>
    /// <param name="services">Kolekcja usług.</param>
    public static IServiceCollection AddWarehouseMessaging(this IServiceCollection services)
    {
        // Przekaźnik skrzynki nadawczej z §0.7: czyta wiersze zapisane w tej samej transakcji,
        // co zmiana stanu, i publikuje je na of.platform.v1. Nic w usłudze nie pisze do Kafki
        // bezpośrednio z obsługi żądania.
        services.AddHostedService<OutboxRelayWorker>();

        // shipment.scanned — skan gate_in tworzy dyspozycję odłożenia, load i unload domykają
        // zajętość gniazda. Skany wystawione przez nas samych rozpoznajemy po device_serial.
        services.AddHostedService<ShipmentScannedConsumer>();

        // shipment.status.changed — przejście w sealed zamraża falę kompletacji, cancelled ją
        // anuluje. To jedyna legalna droga, którą magazyn dowiaduje się o zmianie statusu.
        services.AddHostedService<ShipmentLifecycleConsumer>();

        // telemetry.alert.raised — wychylenie temperatury albo otwarte drzwi przenoszą kontener
        // do strefy Quarantine. Magazyn nigdy nie woła telemetry-ingest z powrotem (§4.19 pkt 2).
        services.AddHostedService<TelemetryAlertRaisedConsumer>();

        // customs.declaration.cleared — dopiero to zdarzenie zwalnia towar ze składu celnego.
        // Odpytywanie customs-service o status byłoby prostsze, ale zamknęłoby cykl w grafie.
        services.AddHostedService<CustomsClearanceConsumer>();

        services.AddHostedService<CycleCountPlanningWorker>();
        services.AddHostedService<RetentionWorker>();

        return services;
    }
}
