import Foundation
import os

//
//  OFContainerAlertService.swift
//  OrbitalFreightDriver
//

/// Trae los avisos abiertos del contenedor que el conductor lleva encima y le deja confirmarlos
/// desde el arcén.
///
/// Los avisos los levanta `telemetry-ingest` a partir de las lecturas que le mandan las pasarelas de
/// depósito y las unidades de a bordo, y llegan a la pantalla por dos caminos distintos: el push de
/// `notification-service`, que es el rápido, y esta consulta a `GET /v1/alerts`, que es la que
/// asegura que un aviso levantado mientras el móvil no tenía cobertura acabe viéndose igualmente.
///
/// Conviene saber lo que hay detrás: cuando `telemetry-ingest` publica `telemetry.alert.raised`,
/// `container-registry` lo consume y pasa el envío a `at_risk`. Ése es el único camino por el que un
/// envío llega a ese estado, y explica por qué la pantalla del conductor puede enseñar un envío en
/// rojo unos segundos antes de que el aviso concreto aparezca en esta lista.
public actor OFContainerAlertService {

    private let client: OFAPIClient
    private let queue: OFOfflineQueue
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "alerts")

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

    /// Aviso abierto sobre un contenedor. Espejo de `telemetry.telemetry_alerts`.
    public struct Alert: Codable, Identifiable, Sendable {
        public let alertID: OFAlertID
        public let containerID: OFContainerID
        public let shipmentID: OFShipmentID?
        public let ruleCode: RuleCode
        /// De 1 a 5. A partir de 4 la pantalla lo enseña en rojo y suena aunque el terminal esté
        /// en silencio.
        public let severity: Int
        public let openedAt: Date
        public let closedAt: Date?
        public let peakValue: Decimal?
        public let thresholdValue: Decimal
        public let acknowledgedBy: String?
        public let acknowledgedAt: Date?

        public var id: String { alertID.rawValue }
        public var isOpen: Bool { closedAt == nil }

        enum CodingKeys: String, CodingKey {
            case alertID = "alert_id"
            case containerID = "container_id"
            case shipmentID = "shipment_id"
            case ruleCode = "rule_code"
            case severity
            case openedAt = "opened_at"
            case closedAt = "closed_at"
            case peakValue = "peak_value"
            case thresholdValue = "threshold_value"
            case acknowledgedBy = "acknowledged_by"
            case acknowledgedAt = "acknowledged_at"
        }
    }

    /// Reglas que puede disparar `telemetry-ingest`.
    public enum RuleCode: String, Codable, Sendable {
        case tempExcursionHigh = "temp_excursion_high"
        case tempExcursionLow = "temp_excursion_low"
        case humidityHigh = "humidity_high"
        case shockImpact = "shock_impact"
        case doorOpenInTransit = "door_open_in_transit"
        case batteryCritical = "battery_critical"
        case gatewaySilent = "gateway_silent"
        case geofenceBreach = "geofence_breach"

        /// Reglas sobre las que el conductor puede hacer algo ahora mismo, que son las que la
        /// pantalla pone arriba del todo.
        public var isActionableByDriver: Bool {
            switch self {
            case .tempExcursionHigh, .tempExcursionLow, .doorOpenInTransit, .shockImpact:
                return true
            case .humidityHigh, .batteryCritical, .gatewaySilent, .geofenceBreach:
                // De éstas se ocupa el depósito o el equipo de mantenimiento. `gateway_silent`
                // además llega con su propio evento, `gateway.heartbeat.missed`, que va a otra
                // gente.
                return false
            }
        }
    }

    /// Avisos abiertos de un contenedor.
    public func openAlerts(for containerID: OFContainerID) async throws -> [Alert] {
        let paginator = OFCursorPaginator<Alert>(
            client: client,
            endpoint: .alerts(containerID: containerID, openOnly: true)
        )
        let alerts = try await paginator.collect(maximum: 40)
        return alerts.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.openedAt > rhs.openedAt
        }
    }

    /// Confirma que el conductor ha visto el aviso.
    ///
    /// Sólo sella `acknowledged_by` y `acknowledged_at`; el aviso sigue abierto. Cerrarlo es otra
    /// cosa distinta y no se hace desde aquí: `POST /v1/alerts/{alert_id}/close` significa que la
    /// causa está resuelta sobre el terreno, y esa decisión es del depósito, no de quien conduce.
    ///
    /// - Returns: `true` si el servicio lo aceptó en el momento, `false` si quedó encolado.
    @discardableResult
    public func acknowledge(_ alertID: OFAlertID, note: String?) async throws -> Bool {

        struct AcknowledgeRequest: Encodable {
            let note: String?
            let acknowledgedAt: Date
            enum CodingKeys: String, CodingKey {
                case note
                case acknowledgedAt = "acknowledged_at"
            }
        }

        let request = AcknowledgeRequest(note: note, acknowledgedAt: Date())
        let idempotencyKey = "alert-ack:\(alertID.rawValue)"

        guard await reachability.current.isUsable else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(OFRFC3339.string(from: date))
            }
            try await queue.enqueue(
                endpoint: .acknowledgeAlert,
                path: "/v1/alerts/\(alertID.rawValue)/acknowledge",
                body: try encoder.encode(request),
                // Cada aviso va por su cuenta: confirmarlos en orden no aporta nada y encadenarlos
                // haría que un aviso atascado bloquease a los demás.
                orderingKey: "alert:\(alertID.rawValue)",
                traceID: traceContext.currentTraceID(),
                idempotencyKey: idempotencyKey
            )
            return false
        }

        _ = try await client.send(
            .acknowledgeAlert(alertID),
            body: request,
            idempotencyKey: idempotencyKey,
            as: OFAcknowledgement.self
        )
        log.info("alert \(alertID.rawValue, privacy: .public) acknowledged")
        return true
    }
}
