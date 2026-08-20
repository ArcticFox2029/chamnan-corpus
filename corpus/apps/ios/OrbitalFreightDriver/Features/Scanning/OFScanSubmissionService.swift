import Foundation
import os

//
//  OFScanSubmissionService.swift
//  OrbitalFreightDriver
//

/// Convierte una lectura de cámara en un escaneo registrado en `container-registry`, con o sin
/// cobertura.
///
/// Es el camino más transitado del app y el que más cuidado exige, porque cada escaneo aceptado
/// acaba publicándose como `shipment.scanned` y desde ahí lo consumen cinco servicios. Uno de
/// ellos, `billing-service`, sólo reacciona a `scan_type = 'proof_of_delivery'` y es lo que
/// desbloquea la facturación del envío; los demás lo usan para el rastro, las notificaciones y la
/// conciliación nocturna. Un escaneo duplicado aquí es una discrepancia allí.
public actor OFScanSubmissionService {

    private let client: OFAPIClient
    private let queue: OFOfflineQueue
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "scan")

    /// Caché de código BIC a `cnt_`, para no resolver dos veces el mismo contenedor durante una
    /// carga de veinte piezas. Se vacía al cambiar de envío.
    private var containerIDCache: [String: OFContainerID] = [:]

    public init(
        client: OFAPIClient,
        queue: OFOfflineQueue,
        reachability: OFReachabilityMonitor,
        traceContext: OFTraceContext
    ) {
        self.client = client
        self.queue = queue
        self.reachability = reachability
        self.traceContext = traceContext
    }

    /// Cuerpo de `POST /v1/containers/{container_id}/scans`.
    struct ScanRequest: Encodable {
        let shipmentID: String
        let scanType: String
        let facilityID: String?
        /// Momento real del gesto. `container-registry` pone `recorded_at` por su cuenta al
        /// persistir, y la diferencia entre los dos es exactamente el tiempo que el terminal pasó
        /// sin cobertura. No se toca al reintentar.
        let occurredAt: Date
        let position: OFGeoPoint?
        let deviceSerial: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case shipmentID = "shipment_id"
            case scanType = "scan_type"
            case facilityID = "facility_id"
            case occurredAt = "occurred_at"
            case position
            case deviceSerial = "device_serial"
            case notes
        }
    }

    /// Resultado de intentar registrar un escaneo.
    public enum Submission: Sendable {
        /// Aceptado por el servicio; trae el `scn_` real.
        case recorded(OFScanID)
        /// Guardado en la cola. El identificador es local y no sirve fuera del terminal.
        case queued(localID: Int64)
    }

    // MARK: - Registro

    /// Registra un escaneo a partir de una lectura de cámara.
    ///
    /// - Parameters:
    ///   - capture: lo que devolvió `OFScanCaptureController`.
    ///   - shipmentID: envío al que se atribuye. Lo elige el conductor en la pantalla, o se deduce
    ///     de la asignación activa cuando sólo hay una.
    ///   - scanType: tipo de escaneo. La prueba de entrega no entra por aquí, tiene su propio flujo.
    ///   - facilityID: instalación donde ocurre. Nulo cuando el escaneo pasa en carretera.
    ///   - notes: nota del conductor, opcional salvo en `damage_report`.
    /// - Returns: si se registró en el momento o quedó encolado.
    public func submit(
        capture: OFScanCaptureController.Capture,
        shipmentID: OFShipmentID,
        scanType: OFScanType,
        facilityID: OFFacilityID?,
        notes: String?
    ) async throws -> Submission {

        precondition(scanType != .proofOfDelivery, "proof of delivery goes through OFProofOfDeliveryCoordinator")

        if scanType == .damageReport, notes?.isEmpty != false {
            throw OFScanError.notesRequiredForDamageReport
        }

        return try await traceContext.withNewTrace(named: "scan.\(scanType.rawValue)") {
            let containerID = try await resolveContainerID(isoCode: capture.isoCode)

            let request = ScanRequest(
                shipmentID: shipmentID.rawValue,
                scanType: scanType.rawValue,
                facilityID: facilityID?.rawValue,
                occurredAt: capture.occurredAt,
                position: capture.position,
                deviceSerial: OFDeviceInfo.deviceSerial,
                notes: notes
            )
            let body = try Self.encoder.encode(request)
            let idempotencyKey = Self.idempotencyKey(
                containerID: containerID,
                shipmentID: shipmentID,
                scanType: scanType,
                occurredAt: capture.occurredAt
            )

            // Sin red no se intenta siquiera: la petición tardaría treinta segundos en fallar y el
            // conductor se quedaría mirando la rueda con el siguiente contenedor delante.
            guard await reachability.current.isUsable else {
                return .queued(localID: try await enqueue(
                    containerID: containerID,
                    shipmentID: shipmentID,
                    body: body,
                    idempotencyKey: idempotencyKey
                ))
            }

            do {
                struct ScanResponse: Decodable {
                    let scanID: OFScanID
                    enum CodingKeys: String, CodingKey { case scanID = "scan_id" }
                }
                let response: ScanResponse = try await client.send(
                    .recordScan(containerID),
                    body: request,
                    idempotencyKey: idempotencyKey
                )
                log.info("scan \(response.scanID.rawValue, privacy: .public) recorded online")
                return .recorded(response.scanID)

            } catch let error as OFTransportError where error.shouldEnqueue {
                return .queued(localID: try await enqueue(
                    containerID: containerID,
                    shipmentID: shipmentID,
                    body: body,
                    idempotencyKey: idempotencyKey
                ))
            } catch let error as OFServiceError where error.deservesRetry {
                return .queued(localID: try await enqueue(
                    containerID: containerID,
                    shipmentID: shipmentID,
                    body: body,
                    idempotencyKey: idempotencyKey
                ))
            }
        }
    }

    private func enqueue(
        containerID: OFContainerID,
        shipmentID: OFShipmentID,
        body: Data,
        idempotencyKey: String
    ) async throws -> Int64 {
        try await queue.enqueue(
            endpoint: .recordScan,
            path: "/v1/containers/\(containerID.rawValue)/scans",
            body: body,
            // El orden se garantiza por envío, igual que en el backend: los escaneos de un mismo
            // `shp_` salen en secuencia. Ordenar por contenedor habría dejado que la descarga
            // adelantara a la carga cuando son piezas distintas del mismo camión.
            orderingKey: shipmentID.rawValue,
            traceID: traceContext.currentTraceID(),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Resolución de contenedor

    /// Traduce un código BIC leído por cámara al `cnt_` que espera la ruta del escaneo.
    ///
    /// Usa `GET /v1/containers?iso_code=`. Sin cobertura tira de caché, y si el contenedor no está
    /// en caché el escaneo no se puede encolar: la ruta lleva el `cnt_` dentro y no lo tenemos.
    /// Éste es el único punto del flujo de escaneo que no funciona sin conexión, y por eso la
    /// pantalla de preparación de turno precarga los contenedores de las asignaciones activas.
    private func resolveContainerID(isoCode: String) async throws -> OFContainerID {
        if let cached = containerIDCache[isoCode] { return cached }

        guard await reachability.current.isUsable else {
            throw OFScanError.containerNotCachedOffline(isoCode: isoCode)
        }

        // El listado devuelve la fila de `freight.containers`, no el emparejamiento con el envío:
        // aquí sólo necesitamos el `cnt_`, y el precinto pertenece a la pareja envío-contenedor.
        struct ContainerSummary: Decodable {
            let containerID: OFContainerID
            let isoCode: String
            let retiredAt: Date?

            enum CodingKeys: String, CodingKey {
                case containerID = "container_id"
                case isoCode = "iso_code"
                case retiredAt = "retired_at"
            }
        }

        let page: OFCursorPage<ContainerSummary> = try await client.send(.containerByISOCode(isoCode))
        // El `iso_code` es único en `freight.containers`, de modo que como mucho hay una fila. Se
        // comprueba `retired_at` igualmente: un contenedor retirado sigue existiendo y sigue
        // resolviendo, pero escanearlo contra un envío vivo es casi siempre un error de la puerta.
        guard let match = page.items.first else {
            throw OFScanError.unknownContainer(isoCode: isoCode)
        }
        if match.retiredAt != nil {
            log.notice("scanning a retired container \(isoCode, privacy: .public)")
        }
        containerIDCache[isoCode] = match.containerID
        return match.containerID
    }

    /// Precarga la correspondencia BIC → `cnt_` de un envío para poder escanear sin cobertura.
    ///
    /// Se llama al aceptar la asignación, que es cuando el conductor todavía tiene wifi del
    /// depósito. Después ya no hay ocasión.
    public func warmContainerCache(for shipment: OFShipment) {
        for container in shipment.containers {
            containerIDCache[container.isoCode] = container.containerID
        }
        log.info("warmed \(shipment.containers.count) container ids for \(shipment.reference, privacy: .public)")
    }

    public func clearContainerCache() {
        containerIDCache.removeAll()
    }

    // MARK: - Idempotencia

    /// Deriva la clave de idempotencia del contenido del escaneo, no de un UUID aleatorio.
    ///
    /// Si el conductor escanea el mismo contenedor, del mismo envío, con el mismo tipo y en el
    /// mismo segundo, es el mismo gesto por mucho que la pantalla haya recibido dos toques. Con un
    /// UUID por intento, el servidor vería dos escrituras distintas y las guardaría las dos.
    private static func idempotencyKey(
        containerID: OFContainerID,
        shipmentID: OFShipmentID,
        scanType: OFScanType,
        occurredAt: Date
    ) -> String {
        let second = Int(occurredAt.timeIntervalSince1970)
        return "scan:\(shipmentID.rawValue):\(containerID.rawValue):\(scanType.rawValue):\(second)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(OFRFC3339.string(from: date))
        }
        return encoder
    }()
}

/// Fallos del flujo de escaneo que no vienen del servidor.
public enum OFScanError: Error, Sendable {
    /// `damage_report` sin nota. La pantalla lo impide, pero el servicio lo vuelve a comprobar
    /// porque el mismo método lo llama el flujo por voz.
    case notesRequiredForDamageReport
    /// Código BIC válido que `container-registry` no conoce. Suele ser un contenedor de un
    /// transitario que todavía no se ha dado de alta con `POST /v1/containers`.
    case unknownContainer(isoCode: String)
    /// Sin cobertura y sin el contenedor en caché: no se puede construir la ruta del escaneo.
    case containerNotCachedOffline(isoCode: String)
}
