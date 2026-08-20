//
//  OFShipmentStatusService.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation
import os

/// Las dos únicas transiciones de estado que el conductor puede provocar, y el filtro que impide
/// que se intente cualquier otra.
///
/// `PATCH /v1/shipments/{shipment_id}/status` es la vía legal única y la tiene `container-registry`,
/// que publica `shipment.status.changed` en la misma transacción. Ese evento lo consumen seis
/// servicios —entre ellos `billing-service`, `customs-service` y `routing-service`—, así que una
/// transición equivocada desde el móvil no se queda en una pantalla mal pintada: replantea rutas y
/// mueve facturación. De ahí que el filtro esté aquí y no sólo en el servidor.
public actor OFShipmentStatusService {

    private let client: OFAPIClient
    private let queue: OFOfflineQueue
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "shipment-status")

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

    /// Cuerpo del `PATCH`. `reason_code` viaja tal cual al payload de `shipment.status.changed`,
    /// que es lo que acaba leyendo el despachador en la consola cuando pregunta por qué se movió
    /// un envío a las tres de la mañana.
    struct StatusChangeRequest: Encodable {
        let status: String
        let reasonCode: String
        let changedAt: Date

        enum CodingKeys: String, CodingKey {
            case status
            case reasonCode = "reason_code"
            case changedAt = "changed_at"
        }
    }

    /// Motivos que el terminal sabe dar. Son los únicos que la consola tiene traducidos.
    public enum ReasonCode: String, Sendable {
        /// Salida de la instalación de origen confirmada con un `gate_out`.
        case gateOutConfirmed = "driver_gate_out"
        /// Prueba de entrega cerrada y firmada.
        case deliveryConfirmed = "driver_delivery_confirmed"
    }

    public enum Outcome: Sendable {
        case applied(OFShipmentStatus)
        case queued(localID: Int64)
        /// El envío ya estaba en ese estado. No es un error y no gasta ni red ni cola.
        case alreadyInState(OFShipmentStatus)
    }

    // MARK: - Transiciones permitidas

    /// Comprueba en local si la transición tiene sentido antes de gastar un viaje de red.
    ///
    /// La lista es corta a propósito y no reproduce la máquina de estados entera de
    /// `container-registry`: sólo describe lo que un conductor puede causar. `at_risk` y
    /// `held_at_customs` no aparecen porque no los pone nadie desde aquí — el primero lo escribe
    /// `container-registry` al consumir `telemetry.alert.raised` y el segundo sale del flujo de
    /// aduana. Si el envío está en cualquiera de los dos, el cambio se rechaza en el terminal y la
    /// pantalla dice a quién llamar.
    static func isDriverTransitionAllowed(from current: OFShipmentStatus, to target: OFShipmentStatus) -> Bool {
        switch (current, target) {
        case (.sealed, .inTransit), (.booked, .inTransit):
            return true
        case (.inTransit, .delivered):
            return true
        default:
            return false
        }
    }

    // MARK: - Salida de instalación

    /// Marca el envío como `in_transit` después de un `gate_out` aceptado.
    ///
    /// Se llama justo detrás del escaneo, nunca antes: si el `gate_out` se quedó en la cola y el
    /// cambio de estado saliese primero, `routing-service` recibiría un envío en tránsito cuya
    /// primera etapa todavía no ha empezado y lo replantearía sin motivo. Compartir la clave de
    /// orden del envío es lo que garantiza la secuencia.
    public func markInTransit(
        shipmentID: OFShipmentID,
        currentStatus: OFShipmentStatus
    ) async throws -> Outcome {
        try await change(
            shipmentID: shipmentID,
            from: currentStatus,
            to: .inTransit,
            reason: .gateOutConfirmed
        )
    }

    /// Marca el envío como `delivered` al cerrar la prueba de entrega.
    ///
    /// El desbloqueo de la facturación no depende de esto sino del escaneo:
    /// `billing-service` reacciona a `shipment.scanned` con `scan_type = 'proof_of_delivery'`. El
    /// estado es lo que ve el cliente en la consola, y por eso se manda igual aunque el escaneo ya
    /// haya salido.
    public func markDelivered(
        shipmentID: OFShipmentID,
        currentStatus: OFShipmentStatus
    ) async throws -> Outcome {
        try await change(
            shipmentID: shipmentID,
            from: currentStatus,
            to: .delivered,
            reason: .deliveryConfirmed
        )
    }

    // MARK: - Núcleo

    private func change(
        shipmentID: OFShipmentID,
        from current: OFShipmentStatus,
        to target: OFShipmentStatus,
        reason: ReasonCode
    ) async throws -> Outcome {

        if current == target {
            return .alreadyInState(current)
        }
        guard Self.isDriverTransitionAllowed(from: current, to: target) else {
            throw OFShipmentStatusError.transitionNotAllowed(from: current, to: target)
        }

        return try await traceContext.withNewTrace(named: "shipment.status.\(target.rawValue)") {
            let request = StatusChangeRequest(
                status: target.rawValue,
                reasonCode: reason.rawValue,
                changedAt: Date()
            )
            let body = try Self.encoder.encode(request)
            // La clave de idempotencia es determinista sobre envío y estado destino: dos toques
            // seguidos del mismo botón, o un reintento tras un túnel, son la misma transición y
            // `container-registry` la aplica una sola vez.
            let idempotencyKey = "status:\(shipmentID.rawValue):\(target.rawValue)"

            guard await reachability.current.isUsable else {
                let localID = try await queue.enqueue(
                    endpoint: .updateShipmentStatus,
                    path: OFEndpoint.updateShipmentStatus(shipmentID).path,
                    method: "PATCH",
                    body: body,
                    orderingKey: shipmentID.rawValue,
                    traceID: traceContext.currentTraceID(),
                    idempotencyKey: idempotencyKey
                )
                log.notice("status \(target.rawValue, privacy: .public) queued for \(shipmentID.rawValue, privacy: .public)")
                return .queued(localID: localID)
            }

            do {
                let updated: OFShipment = try await client.send(
                    .updateShipmentStatus(shipmentID),
                    body: request,
                    idempotencyKey: idempotencyKey,
                    as: OFShipment.self
                )
                return .applied(updated.status)
            } catch let error as OFServiceError where error.deservesRetry {
                // Un fallo reintentable con red disponible acaba en la cola igual que si no
                // hubiese cobertura. El caso real es el `503` de un despliegue rodante de
                // `container-registry`: dura segundos y no tiene por qué llegarle al conductor.
                let localID = try await queue.enqueue(
                    endpoint: .updateShipmentStatus,
                    path: OFEndpoint.updateShipmentStatus(shipmentID).path,
                    method: "PATCH",
                    body: body,
                    orderingKey: shipmentID.rawValue,
                    traceID: traceContext.currentTraceID(),
                    idempotencyKey: idempotencyKey
                )
                return .queued(localID: localID)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// El único error propio del cambio de estado. Todo lo demás sube tal cual desde `OFAPIClient`.
public enum OFShipmentStatusError: Error, Sendable {
    case transitionNotAllowed(from: OFShipmentStatus, to: OFShipmentStatus)
}
