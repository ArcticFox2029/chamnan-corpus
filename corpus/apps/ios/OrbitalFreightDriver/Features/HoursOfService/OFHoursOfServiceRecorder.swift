import Foundation
import CoreLocation
import os

//
//  OFHoursOfServiceRecorder.swift
//  OrbitalFreightDriver
//

/// Registro de jornada del conductor: cada cambio de estado se manda a `fleet-service` y se refleja
/// en la pantalla de tiempos.
///
/// Aquí no se calcula nada de la normativa. El terminal envía hechos —"empecé a conducir a las
/// 06:12 en estas coordenadas"— y lee de `GET /v1/drivers/{driver_id}/availability` lo que queda;
/// las reglas de tiempos de conducción viven en `fleet-service` y son las mismas que aplica
/// `fleet.v1.FleetService/CheckEligibility` al aceptar una asignación. Que el móvil y el servidor
/// contasen distinto sería peor que no contar en el móvil.
public actor OFHoursOfServiceRecorder {

    private let client: OFAPIClient
    private let queue: OFOfflineQueue
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let driverID: OFDriverID
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "hos")

    private var lastKnownAvailability: OFDriverAvailability?
    private var lastLocalStatus: OFDutyStatus = .offDuty
    private var lastChangeAt: Date = .distantPast

    /// Cambios de estado más juntos que esto se consideran un doble toque. Se descartan en local
    /// sin llegar a la red: el reglamento no reconoce un cambio de estado de dos segundos y
    /// `fleet-service` los rechazaría igualmente.
    private static let minimumInterval: TimeInterval = 15

    public init(
        client: OFAPIClient,
        queue: OFOfflineQueue,
        reachability: OFReachabilityMonitor,
        traceContext: OFTraceContext,
        driverID: OFDriverID
    ) {
        self.client = client
        self.queue = queue
        self.reachability = reachability
        self.traceContext = traceContext
        self.driverID = driverID
    }

    // MARK: - Cambios de estado

    /// Registra un cambio de estado de jornada.
    ///
    /// El envío no es opcional ni puede perderse: la jornada es un registro legal y una hora sin
    /// contabilizar es una infracción en una inspección de carretera. Por eso, a diferencia de otras
    /// escrituras, ésta se encola siempre que no salga a la primera, sin importar el motivo del
    /// fallo.
    ///
    /// - Parameters:
    ///   - status: nuevo estado.
    ///   - location: posición en el momento del cambio, si hay fijación.
    ///   - vehicleID: vehículo en el que ocurre. Nulo en los descansos fuera del camión.
    ///   - odometerKm: lectura del cuentakilómetros que el conductor introduce a mano al empezar y
    ///     terminar el turno.
    ///   - note: aclaración libre, por ejemplo una espera en frontera.
    @discardableResult
    public func record(
        status: OFDutyStatus,
        location: CLLocation?,
        vehicleID: OFVehicleID?,
        odometerKm: Int?,
        note: String? = nil
    ) async throws -> Bool {

        let now = Date()
        guard status != lastLocalStatus || now.timeIntervalSince(lastChangeAt) > Self.minimumInterval else {
            log.debug("duty status change debounced")
            return false
        }

        let change = OFDutyStatusChange(
            status: status,
            occurredAt: now,
            position: location.map { OFGeoPoint($0.coordinate) },
            vehicleID: vehicleID,
            odometerKm: odometerKm,
            note: note
        )
        let body = try Self.encoder.encode(change)
        // La clave se deriva del conductor, el estado y el segundo exacto: dos toques en el mismo
        // segundo son el mismo hecho, y el servidor los colapsa en vez de apuntar dos cambios.
        let idempotencyKey = "hos:\(driverID.rawValue):\(status.rawValue):\(Int(now.timeIntervalSince1970))"

        lastLocalStatus = status
        lastChangeAt = now

        guard await reachability.current.isUsable else {
            try await enqueue(body: body, idempotencyKey: idempotencyKey)
            return false
        }

        do {
            _ = try await traceContext.withNewTrace(named: "hos.\(status.rawValue)") {
                try await client.send(
                    .appendHoursOfService(driverID),
                    body: change,
                    idempotencyKey: idempotencyKey,
                    as: OFAcknowledgement.self
                )
            }
            log.info("duty status \(status.rawValue, privacy: .public) accepted")
            // Refrescamos disponibilidad en cuanto el cambio entra, porque la pantalla enseña el
            // tiempo restante justo debajo del botón que se acaba de pulsar.
            await refreshAvailability()
            return true

        } catch {
            log.error("duty status change deferred to the queue: \(error.localizedDescription, privacy: .public)")
            try await enqueue(body: body, idempotencyKey: idempotencyKey)
            return false
        }
    }

    private func enqueue(body: Data, idempotencyKey: String) async throws {
        try await queue.enqueue(
            endpoint: .hoursOfService,
            path: "/v1/drivers/\(driverID.rawValue)/hours-of-service",
            body: body,
            // Todos los cambios de jornada de un conductor comparten clave de orden, y con razón:
            // "descanso" seguido de "conduciendo" cuenta una historia distinta que al revés, y el
            // servidor los aplica en el orden en que llegan.
            orderingKey: "hos:\(driverID.rawValue)",
            traceID: traceContext.currentTraceID(),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Disponibilidad

    /// Relee `GET /v1/drivers/{driver_id}/availability` y cachea el resultado.
    ///
    /// - Returns: lo que devolvió el servicio, o el último valor conocido si no hay red. El valor
    ///   cacheado se marca con su `calculated_at` para que la pantalla pueda avisar de que lo que
    ///   se ve es de hace dos horas.
    @discardableResult
    public func refreshAvailability() async -> OFDriverAvailability? {
        do {
            let availability: OFDriverAvailability = try await client.send(.driverAvailability(driverID))
            lastKnownAvailability = availability
            if availability.isCloseToLimit {
                log.notice("driver within 30 minutes of the drive-time limit")
            }
            return availability
        } catch {
            log.error("availability unavailable: \(error.localizedDescription, privacy: .public)")
            return lastKnownAvailability
        }
    }

    /// Último valor conocido, sin tocar la red.
    public var cachedAvailability: OFDriverAvailability? {
        lastKnownAvailability
    }

    /// Estimación local del tiempo restante a partir del último cálculo del servidor.
    ///
    /// Se descuenta el tiempo transcurrido desde `calculated_at` sólo si el conductor sigue en
    /// `driving`. Es una aproximación para la pantalla y jamás para una decisión: quien decide si
    /// puede coger otro tramo es `fleet.v1.FleetService/CheckEligibility`.
    public func estimatedRemainingDriveSeconds(at moment: Date = Date()) -> Int? {
        guard let availability = lastKnownAvailability else { return nil }
        guard availability.currentStatus == .driving else { return availability.remainingDriveSeconds }
        let elapsed = Int(moment.timeIntervalSince(availability.calculatedAt))
        return max(0, availability.remainingDriveSeconds - elapsed)
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
