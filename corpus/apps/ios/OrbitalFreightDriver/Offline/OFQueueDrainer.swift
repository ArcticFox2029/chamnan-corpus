import Foundation
import UIKit
import os

//
//  OFQueueDrainer.swift
//  OrbitalFreightDriver
//

/// Vacía la cola sin conexión contra los servicios reales en cuanto hay red, y decide qué hacer con
/// cada rechazo.
///
/// La regla de oro es que sólo el servidor sabe si una operación se aplicó. El drenador nunca
/// inspecciona el payload para adivinarlo: reenvía con la misma clave de idempotencia y deja que
/// `container-registry`, `fleet-service`, `document-service` o `telemetry-ingest` colapsen el
/// duplicado. Lo único que interpreta es el sobre de error, y ahí sólo un campo: `retryable`.
public actor OFQueueDrainer {

    private let queue: OFOfflineQueue
    private let client: OFAPIClient
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "drainer")

    private var loop: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Se emite tras cada pasada con el número de operaciones que siguen esperando. Lo consume el
    /// indicador de la barra superior, que es lo único que el conductor ve de todo esto.
    public var onPendingCountChanged: (@Sendable (Int) -> Void)?

    public init(
        queue: OFOfflineQueue,
        client: OFAPIClient,
        reachability: OFReachabilityMonitor,
        traceContext: OFTraceContext
    ) {
        self.queue = queue
        self.client = client
        self.reachability = reachability
        self.traceContext = traceContext
    }

    // MARK: - Ciclo de vida

    /// Arranca el bucle de drenaje y lo deja escuchando cambios de conectividad.
    ///
    /// No hay temporizador fijo. Sondear cada N segundos con la pantalla apagada gastaba batería
    /// para nada durante los descansos obligatorios, que son horas; el bucle despierta cuando la
    /// red vuelve o cuando alguien encola algo.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            for await status in await self.reachability.statusStream() {
                guard status.isUsable else { continue }
                await self.drain(reason: "connectivity:\(status.description)")
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Drena hasta agotar la cola o hasta que algo devuelva un fallo de red.
    ///
    /// - Parameter reason: de dónde vino el disparo, sólo para los logs locales.
    public func drain(reason: String) async {
        beginBackgroundWindow()
        defer { endBackgroundWindow() }

        log.info("drain started (\(reason, privacy: .public))")
        var sentInThisPass = 0

        while !Task.isCancelled {
            let batch: [OFOfflineQueue.PendingOperation]
            do {
                batch = try await queue.nextBatch(limit: 10)
            } catch {
                log.error("cannot read the queue: \(error.localizedDescription, privacy: .public)")
                break
            }
            if batch.isEmpty { break }

            var networkFailed = false
            for operation in batch {
                if Task.isCancelled { break }
                let outcome = await send(operation)
                switch outcome {
                case .accepted:
                    await queue.complete(operation.id)
                    sentInThisPass += 1
                case .retryLater(let reason):
                    await queue.scheduleRetry(operation.id, attempts: operation.attempts, reason: reason)
                case .parked(let reason):
                    await queue.park(operation.id, reason: reason)
                case .networkGone:
                    // No se marca intento: no llegó a haber intento. Contar los cortes de
                    // cobertura como reintentos agotaba los ocho en un solo trayecto por un valle.
                    networkFailed = true
                }
                if networkFailed { break }
            }
            if networkFailed { break }
        }

        let remaining = await queue.pendingCount()
        onPendingCountChanged?(remaining)
        log.info("drain finished: \(sentInThisPass) sent, \(remaining) pending")
    }

    // MARK: - Envío

    private enum Outcome {
        case accepted
        case retryLater(String)
        case parked(String)
        case networkGone
    }

    private func send(_ operation: OFOfflineQueue.PendingOperation) async -> Outcome {

        // Pasada la ventana de idempotencia del servidor, reenviar deja de ser seguro: la clave ya
        // no deduplica y el reintento crearía un escaneo duplicado de verdad.
        if await queue.idempotencyWindowExpired(for: operation) {
            return .parked("idempotency_window_expired")
        }

        _ = traceContext.adopt(traceID: operation.traceID)

        do {
            _ = try await client.sendRaw(
                operation.endpointKey.rebuiltEndpoint(path: operation.path),
                idempotencyKey: operation.idempotencyKey,
                rawBody: operation.bodyJSON,
                contentType: operation.contentType
            )
            return .accepted

        } catch let error as OFServiceError {
            // `document_duplicate` es éxito disfrazado: `document-service` encontró el mismo
            // `sha256` y reutilizó el `doc_` que ya tenía, que es exactamente lo que queríamos.
            if error.known == .documentDuplicate { return .accepted }

            // Una transición de estado que el servidor considera ilegal no mejora esperando. Suele
            // ser el propio conductor habiendo cerrado la entrega desde otro terminal.
            if error.known == .shipmentAlreadySealed { return .parked(error.code) }

            return error.deservesRetry
                ? .retryLater(error.code)
                : .parked("\(error.code) trace=\(error.traceID)")

        } catch let error as OFTransportError {
            switch error {
            case .offline, .timedOut:
                return .networkGone
            case .decodingFailed, .malformedErrorBody:
                // El servidor aceptó o rechazó, pero no sabemos cuál. Reintentar es seguro
                // gracias a la clave de idempotencia, así que reintentamos.
                return .retryLater("unreadable_response")
            case .misconfiguredService, .certificatePinningFailed:
                return .parked("transport:\(error.localizedDescription)")
            }
        } catch {
            return .retryLater("unexpected:\(error.localizedDescription)")
        }
    }

    // MARK: - Segundo plano

    /// Pide al sistema una ventana corta para terminar el lote cuando el conductor bloquea el móvil
    /// justo después de escanear, que es lo que pasa siempre.
    private func beginBackgroundWindow() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "of.queue.drain") { [weak self] in
            Task { await self?.endBackgroundWindow() }
        }
    }

    private func endBackgroundWindow() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}

private extension OFOfflineQueue.OFQueuedEndpoint {

    /// Reconstruye el caso de `OFEndpoint` a partir de la ruta guardada.
    ///
    /// La cola persiste la ruta ya resuelta y no el caso del `enum`, porque el `enum` cambia entre
    /// versiones del app y una operación encolada tiene que sobrevivir a una actualización desde la
    /// App Store. Los identificadores se vuelven a extraer de la ruta.
    func rebuiltEndpoint(path: String) -> OFEndpoint {
        let segments = path.split(separator: "/").map(String.init)
        switch self {
        case .recordScan:
            if segments.count >= 3, let id = OFContainerID(rawValue: segments[2]) {
                return .recordScan(id)
            }
        case .hoursOfService:
            if segments.count >= 3, let id = OFDriverID(rawValue: segments[2]) {
                return .appendHoursOfService(id)
            }
        case .uploadDocument:
            return .uploadDocument
        case .acknowledgeAlert:
            if segments.count >= 3, let id = OFAlertID(rawValue: segments[2]) {
                return .acknowledgeAlert(id)
            }
        case .updateShipmentStatus:
            if segments.count >= 3, let id = OFShipmentID(rawValue: segments[2]) {
                return .updateShipmentStatus(id)
            }
        }
        // Si la ruta guardada ya no se puede reconstruir es que la escribió una versión del app que
        // no entendemos. Devolvemos la subida de documentos, que es inocua, y el `park` posterior
        // por ruta inválida deja rastro en la pantalla de diagnóstico.
        return .uploadDocument
    }
}
