//
//  OFDriverAppComposition.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation
import GRPC
import NIOPosix
import UIKit
import os

/// Punto donde se monta el app entero: se leen los ajustes de aprovisionamiento, se construyen los
/// servicios en el orden correcto y se ata la cola sin conexión al vigilante de red.
///
/// Es intencionadamente el único sitio del proyecto que hace `init` de nada. Cuando cada pantalla
/// se fabricaba su propio cliente HTTP acabamos con tres `OFTokenStore` distintos rotando el mismo
/// refresh token en paralelo, que es exactamente lo que `identity-service` interpreta como
/// reutilización — y mata la familia de sesión entera.
@MainActor
public final class OFDriverAppComposition {

    public let configuration: OFEnvironmentConfiguration
    public let traceContext: OFTraceContext
    public let tokenStore: OFTokenStore
    public let apiClient: OFAPIClient
    public let offlineQueue: OFOfflineQueue
    public let reachability: OFReachabilityMonitor
    public let drainer: OFQueueDrainer
    public let scanService: OFScanSubmissionService
    public let assignments: OFAssignmentService
    public let proofOfDelivery: OFProofOfDeliveryCoordinator
    public let alerts: OFContainerAlertService
    public let pushRouter: OFPushEventRouter
    public let shipmentStatus: OFShipmentStatusService
    public let documents: OFDocumentViewerService
    public let location: OFDriverLocationProvider

    private let eventLoopGroup: EventLoopGroup
    private let fleetChannel: GRPCChannel
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "composition")

    /// Monta todo a partir del perfil de aprovisionamiento.
    ///
    /// - Parameter provisioning: lo que el MDM deja en el `Info.plist` o en los ajustes gestionados.
    ///   Trae entorno, región y las URL base de los cinco servicios con los que hablamos.
    public init(provisioning: OFProvisioningProfile) throws {

        self.configuration = OFEnvironmentConfiguration(
            environment: provisioning.environment,
            regionCode: provisioning.regionCode,
            baseURLs: provisioning.baseURLs,
            jwksGraceSeconds: provisioning.jwksGraceSeconds
        )

        self.traceContext = OFTraceContext()
        self.tokenStore = OFTokenStore(configuration: configuration)

        // Sesión propia, no `URLSession.shared`. Necesitamos plazos cortos y espera por conexión
        // desactivada: en el terminal preferimos fallar rápido y encolar a que el sistema
        // mantenga la petición viva media hora en un túnel.
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfiguration)

        self.apiClient = OFAPIClient(
            configuration: configuration,
            tokenStore: tokenStore,
            traceContext: traceContext,
            session: session
        )

        // La base de datos de la cola va en Application Support y no en Caches: el sistema puede
        // vaciar Caches cuando aprieta el disco, y ahí dentro hay escaneos que la plataforma
        // todavía no conoce.
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let queueURL = support.appendingPathComponent("of-outbound-queue.sqlite")
        self.offlineQueue = try OFOfflineQueue(databaseURL: queueURL)
        try Self.excludeFromBackup(queueURL)

        self.reachability = OFReachabilityMonitor(configuration: configuration, session: session)
        self.drainer = OFQueueDrainer(
            queue: offlineQueue,
            client: apiClient,
            reachability: reachability,
            traceContext: traceContext
        )

        self.scanService = OFScanSubmissionService(
            client: apiClient,
            queue: offlineQueue,
            reachability: reachability,
            traceContext: traceContext
        )

        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.fleetChannel = try GRPCChannelPool.with(
            target: .host(provisioning.fleetGRPCHost, port: provisioning.fleetGRPCPort),
            transportSecurity: .tls(.makeClientConfigurationBackedByNIOSSL()),
            eventLoopGroup: eventLoopGroup
        )
        self.assignments = OFAssignmentService(
            channel: fleetChannel,
            client: apiClient,
            traceContext: traceContext,
            scanService: scanService
        )

        self.proofOfDelivery = OFProofOfDeliveryCoordinator(
            client: apiClient,
            queue: offlineQueue,
            reachability: reachability,
            traceContext: traceContext,
            configuration: configuration
        )

        self.alerts = OFContainerAlertService(
            client: apiClient,
            queue: offlineQueue,
            reachability: reachability,
            traceContext: traceContext
        )

        self.shipmentStatus = OFShipmentStatusService(
            client: apiClient,
            queue: offlineQueue,
            reachability: reachability,
            traceContext: traceContext
        )

        // La caché de documentos sí va en Caches, al revés que la cola: son copias de algo que
        // `document-service` conserva, y volver a bajarlas cuesta una URL firmada y nada más.
        let documentCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("of-documents", isDirectory: true)
        self.documents = OFDocumentViewerService(
            client: apiClient,
            reachability: reachability,
            traceContext: traceContext,
            cacheDirectory: documentCache
        )

        self.location = OFDriverLocationProvider()

        self.pushRouter = OFPushEventRouter(traceContext: traceContext)
    }

    /// Arranca lo que tiene que estar vivo desde el primer segundo.
    public func start() async {
        await reachability.start()
        await drainer.start()
        // Una pasada inmediata al arrancar: el caso más común es abrir el app por la mañana con lo
        // de anoche todavía sin enviar.
        await drainer.drain(reason: "app-launch")
        // El GPS sólo entra en modo fino cuando una pantalla lo pide; aquí basta con los cambios
        // significativos, que es lo que sostiene la posición de los escaneos durante el turno.
        location.startShiftTracking()
        log.notice("composition started for region \(self.configuration.regionCode.rawValue, privacy: .public)")
    }

    /// Cierra ordenadamente. Se llama en `applicationWillTerminate` y al cerrar sesión.
    public func shutdown() async {
        await drainer.stop()
        await reachability.stop()
        location.stopShiftTracking()
        try? fleetChannel.close().wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    /// Excluye la cola de la copia de seguridad de iCloud.
    ///
    /// Un escaneo pendiente restaurado en otro terminal se enviaría con la misma clave de
    /// idempotencia pero con el token de otro conductor, y `scanned_by_user_id` acabaría
    /// atribuyendo el escaneo a quien no lo hizo.
    private static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}

/// Ajustes que el MDM entrega al terminal antes de que el conductor toque nada.
///
/// El app no trae ninguna URL compilada dentro. La flota está repartida entre las ocho regiones de
/// la plataforma y cada terminal habla con la pasarela de la suya, porque la región es residencia
/// del dato: un envío marcado `latam-br` no se atiende desde Fráncfort ni aunque el camión esté allí.
public struct OFProvisioningProfile: Sendable {

    public let environment: String
    public let regionCode: OFRegionCode
    public let baseURLs: [OFService: URL]
    public let fleetGRPCHost: String
    public let fleetGRPCPort: Int
    public let jwksGraceSeconds: TimeInterval

    /// Lee el perfil de los ajustes gestionados que deja el MDM.
    ///
    /// - Throws: `OFProvisioningError.missingKey` con el nombre de lo que falta. Es un fallo duro y
    ///   la pantalla que lo recoge enseña justo esa clave, porque quien lo va a arreglar es un
    ///   técnico de flota mirando el móvil del conductor, no un desarrollador.
    public static func fromManagedConfiguration() throws -> OFProvisioningProfile {
        let managed = UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed") ?? [:]

        func require(_ key: String) throws -> String {
            guard let value = managed[key] as? String, !value.isEmpty else {
                throw OFProvisioningError.missingKey(key)
            }
            return value
        }

        guard let region = OFRegionCode(rawValue: try require("regionCode")) else {
            throw OFProvisioningError.invalidRegion(managed["regionCode"] as? String ?? "")
        }

        var urls: [OFService: URL] = [:]
        // Los nombres de clave siguen el mismo criterio que las variables de entorno del backend:
        // un nombre por servicio destino, idéntico en todos los que lo llaman.
        let mapping: [(OFService, String)] = [
            (.identity, "identityBaseURL"),
            (.fleet, "fleetBaseURL"),
            (.containerRegistry, "containerRegistryBaseURL"),
            (.document, "documentBaseURL"),
            (.telemetryIngest, "telemetryIngestBaseURL")
        ]
        for (service, key) in mapping {
            guard let url = URL(string: try require(key)) else {
                throw OFProvisioningError.invalidURL(key)
            }
            urls[service] = url
        }

        return OFProvisioningProfile(
            environment: try require("environment"),
            regionCode: region,
            baseURLs: urls,
            fleetGRPCHost: try require("fleetGRPCHost"),
            fleetGRPCPort: managed["fleetGRPCPort"] as? Int ?? 9082,
            jwksGraceSeconds: TimeInterval(managed["jwksGraceSeconds"] as? Int ?? 300)
        )
    }
}

/// Fallos de aprovisionamiento. Siempre son de configuración del terminal, nunca del conductor.
public enum OFProvisioningError: Error, Sendable {
    case missingKey(String)
    case invalidRegion(String)
    case invalidURL(String)
}
