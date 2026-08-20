import Foundation
import UserNotifications
import os

//
//  OFPushEventRouter.swift
//  OrbitalFreightDriver
//

/// Traduce los avisos push de `notification-service` en algo que la interfaz del conductor pueda
/// hacer.
///
/// El terminal no consume Kafka: todo lo que le llega ha pasado antes por `notification-service`,
/// que es quien abanica los eventos hacia las personas respetando `platform.notification_preferences`
/// —incluidas las horas de silencio, que en un conductor de nocturno no son un detalle—. El payload
/// del push trae el `template_code` de la notificación y el `event_id` del evento que la originó,
/// y ese `event_id` es lo que nos permite ignorar el mismo aviso entregado dos veces.
public final class OFPushEventRouter: NSObject {

    /// Acciones que el router pide a la capa de presentación. No navega él: sólo interpreta.
    public enum Action: Sendable, Equatable {
        /// Abrir el envío. Llega con `shipment_status_changed` y con `route_replanned`.
        case openShipment(OFShipmentID)
        /// Recargar el listado de asignaciones porque una ha cambiado bajo los pies del conductor.
        case reloadAssignments(reason: String)
        /// Enseñar la tarjeta de alerta de temperatura o impacto del contenedor.
        case showContainerAlert(containerID: OFContainerID, alertID: OFAlertID, severity: Int)
        /// Aviso sin destino concreto: se muestra y ya está.
        case informational(title: String, body: String)
    }

    /// Códigos de plantilla que el app entiende. `notification-service` puede mandar otros y no
    /// pasa nada: se muestran como aviso informativo en vez de descartarse, porque un conductor
    /// prefiere leer algo raro a no enterarse.
    private enum Template: String {
        /// Origen: `shipment.status.changed`.
        case shipmentStatusChanged = "shipment_status_changed"
        /// Origen: `telemetry.alert.raised`. Es el que más urge: una excursión de temperatura en un
        /// frigorífico se arregla en el arcén, no en la oficina.
        case containerAlertRaised = "container_alert_raised"
        /// Origen: `route.replanned`. `fleet-service` puede haber liberado ya la asignación del
        /// conductor si el tramo que llevaba ha dejado de existir en la versión nueva de la ruta.
        case routeReplanned = "route_replanned"
        /// Origen: `fleet.assignment.created`, cuando el planificador asigna desde la consola.
        case assignmentCreated = "assignment_created"
        /// Origen: `fleet.assignment.released`.
        case assignmentReleased = "assignment_released"
        /// Origen: `customs.declaration.cleared`. El envío puede salir de la aduana.
        case declarationCleared = "declaration_cleared"
    }

    private let traceContext: OFTraceContext
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "push")

    /// Identificadores de evento ya procesados. La entrega push es "al menos una vez" igual que la
    /// de Kafka, así que la misma regla de idempotencia se aplica en el terminal.
    private var seenEventIDs: Set<String> = []
    private var seenOrder: [String] = []
    private static let seenLimit = 500

    /// Lo invoca el router con la acción resultante, ya en el hilo principal.
    public var onAction: ((Action) -> Void)?

    public init(traceContext: OFTraceContext) {
        self.traceContext = traceContext
        super.init()
    }

    // MARK: - Interpretación

    /// Interpreta un payload de APNs.
    ///
    /// - Parameter userInfo: diccionario tal cual lo entrega el sistema.
    /// - Returns: la acción a ejecutar, o `nil` si el aviso es un duplicado o no trae los datos
    ///   mínimos.
    @discardableResult
    public func handle(userInfo: [AnyHashable: Any]) -> Action? {

        guard let payload = userInfo["of"] as? [String: Any] else {
            log.error("push without the platform payload envelope")
            return nil
        }

        // Idempotencia sobre `event_id`, igual que en cualquier consumidor de la plataforma. Sin
        // esto, un reintento de APNs abría dos veces la misma pantalla de alerta.
        if let eventID = payload["event_id"] as? String {
            guard remember(eventID) else {
                log.debug("duplicate push ignored")
                return nil
            }
        }

        // La traza del evento original. Adoptarla hace que lo que el conductor haga a continuación
        // cuelgue de la misma cascada que provocó el aviso, en vez de aparecer suelto en el
        // colector.
        if let traceID = payload["trace_id"] as? String {
            _ = traceContext.adopt(traceID: traceID)
        }

        let templateCode = payload["template_code"] as? String ?? ""
        let action = interpret(templateCode: templateCode, payload: payload, userInfo: userInfo)

        if let action {
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(action)
            }
        }
        return action
    }

    private func interpret(
        templateCode: String,
        payload: [String: Any],
        userInfo: [AnyHashable: Any]
    ) -> Action? {

        switch Template(rawValue: templateCode) {

        case .shipmentStatusChanged, .declarationCleared:
            guard let raw = payload["shipment_id"] as? String,
                  let shipmentID = OFShipmentID(rawValue: raw) else { return fallback(userInfo) }
            return .openShipment(shipmentID)

        case .containerAlertRaised:
            guard let rawContainer = payload["container_id"] as? String,
                  let containerID = OFContainerID(rawValue: rawContainer),
                  let rawAlert = payload["alert_id"] as? String,
                  let alertID = OFAlertID(rawValue: rawAlert) else { return fallback(userInfo) }
            // La severidad va de 1 a 5 en `telemetry.telemetry_alerts`. A partir de 4 la tarjeta se
            // muestra con sonido aunque el terminal esté en silencio: son puertas abiertas en
            // tránsito y excursiones de temperatura con la carga ya en riesgo.
            let severity = payload["severity"] as? Int ?? 3
            return .showContainerAlert(containerID: containerID, alertID: alertID, severity: severity)

        case .routeReplanned:
            // La ruta nueva puede haber dejado sin tramo la asignación del conductor;
            // `fleet-service` la libera al consumir `route.replanned`. Recargamos el listado antes
            // de enseñar nada, para no mostrar un tramo que ya no existe.
            return .reloadAssignments(reason: "route_replanned")

        case .assignmentCreated:
            return .reloadAssignments(reason: "assignment_created")

        case .assignmentReleased:
            return .reloadAssignments(reason: "assignment_released")

        case .none:
            log.info("unknown template_code \(templateCode, privacy: .public), showing it as-is")
            return fallback(userInfo)
        }
    }

    private func fallback(_ userInfo: [AnyHashable: Any]) -> Action? {
        guard let aps = userInfo["aps"] as? [String: Any],
              let alert = aps["alert"] as? [String: Any] else { return nil }
        return .informational(
            title: alert["title"] as? String ?? "",
            body: alert["body"] as? String ?? ""
        )
    }

    /// Registra el `event_id` y dice si es nuevo. La ventana es acotada porque el terminal no
    /// necesita recordar más allá de un turno.
    private func remember(_ eventID: String) -> Bool {
        guard !seenEventIDs.contains(eventID) else { return false }
        seenEventIDs.insert(eventID)
        seenOrder.append(eventID)
        if seenOrder.count > Self.seenLimit {
            let evicted = seenOrder.removeFirst()
            seenEventIDs.remove(evicted)
        }
        return true
    }
}

// MARK: - Integración con el sistema

extension OFPushEventRouter: UNUserNotificationCenterDelegate {

    /// Avisos en primer plano.
    ///
    /// Las alertas de contenedor se enseñan aunque el conductor esté con la cámara abierta: es
    /// justo el momento en que puede ir a mirar el grupo frigorífico. El resto se procesa en
    /// silencio para no taparle el visor mientras escanea.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let action = handle(userInfo: notification.request.content.userInfo)
        if case .showContainerAlert(_, _, let severity) = action, severity >= 4 {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.list])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handle(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
