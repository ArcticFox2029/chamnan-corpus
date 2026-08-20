//
//  OFAssignmentService.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation
import GRPC
import NIOCore
import os

/// Puente del terminal con `fleet-service`: aceptar una asignación, soltarla y consultar la
/// elegibilidad del conductor antes de reservar nada.
///
/// Las tres operaciones son gRPC (`fleet.v1.FleetService/Assign`, `/Release` y
/// `/CheckEligibility`); el listado de asignaciones del turno sí es HTTP. Conviene tener presente
/// que este app no decide nunca si una reserva es posible: el árbitro real es la restricción
/// `EXCLUDE` sobre `fleet.vehicle_assignments`, que impide que un mismo vehículo o un mismo
/// conductor estén en dos envíos con periodos solapados. La consola de despacho escribe en esa
/// misma tabla, así que la carrera con un planificador humano es real y ocurre a diario.
public actor OFAssignmentService {

    private let channel: GRPCChannel
    private let client: OFAPIClient
    private let traceContext: OFTraceContext
    private let scanService: OFScanSubmissionService
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "assignments")

    /// Talón generado en `libs/` a partir del `.proto` de la plataforma. No se edita a mano.
    private lazy var fleet = Fleet_V1_FleetServiceAsyncClient(channel: channel)

    public init(
        channel: GRPCChannel,
        client: OFAPIClient,
        traceContext: OFTraceContext,
        scanService: OFScanSubmissionService
    ) {
        self.channel = channel
        self.client = client
        self.traceContext = traceContext
        self.scanService = scanService
    }

    // MARK: - Turno

    /// Asignaciones activas del conductor, para la pantalla de inicio de turno.
    ///
    /// Llama a `GET /v1/assignments` con `driver_id` y `active=true`. El filtro por activas no es
    /// cosmético: sin él el listado trae el histórico completo y en un conductor veterano son miles
    /// de filas paginadas de veinticinco en veinticinco.
    public func activeAssignments(for driverID: OFDriverID) async throws -> [OFVehicleAssignment] {
        let paginator = OFCursorPaginator<OFVehicleAssignment>(
            client: client,
            endpoint: .assignments(driverID: driverID, activeOnly: true)
        )
        return try await paginator.collect(maximum: 50)
    }

    /// Carga el envío de una asignación y calienta la caché de contenedores.
    ///
    /// Se hace en cuanto el conductor abre la asignación y todavía tiene wifi del depósito, porque
    /// resolver un código BIC a `cnt_` es lo único del flujo de escaneo que no funciona a oscuras.
    public func loadShipment(for assignment: OFVehicleAssignment) async throws -> OFShipment {
        let shipment: OFShipment = try await client.send(.shipment(assignment.shipmentID))
        await scanService.warmContainerCache(for: shipment)
        return shipment
    }

    // MARK: - Reserva

    /// Comprueba si el conductor puede tomar el tramo, sin reservar nada.
    ///
    /// Se llama antes de enseñar el botón de aceptar. Mira permiso de conducir, certificado ADR y
    /// horas de conducción disponibles; ninguna de las tres las calcula el terminal, y replicar
    /// aquí el reglamento de tiempos de conducción sería una fuente inagotable de discrepancias con
    /// el servidor.
    public func checkEligibility(
        driverID: OFDriverID,
        vehicleID: OFVehicleID,
        shipmentID: OFShipmentID,
        legID: OFRouteLegID?
    ) async throws -> Eligibility {

        var request = Fleet_V1_CheckEligibilityRequest()
        request.driverID = driverID.rawValue
        request.vehicleID = vehicleID.rawValue
        request.shipmentID = shipmentID.rawValue
        if let legID { request.legID = legID.rawValue }

        let response = try await fleet.checkEligibility(request, callOptions: makeCallOptions())
        return Eligibility(
            isEligible: response.eligible,
            blockingReasons: response.blockingReasons,
            remainingDriveSeconds: Int(response.remainingDriveSeconds)
        )
    }

    /// Reserva vehículo y conductor para el tramo.
    ///
    /// - Returns: la asignación creada, con su `asg_`.
    /// - Throws: `OFAssignmentError.alreadyAssigned` cuando el periodo se solapa con otra
    ///   asignación viva. Ocurre de verdad: el conductor acepta desde el móvil en el mismo segundo
    ///   en que el planificador se lo asigna a otro desde la consola, y gana quien llega antes a la
    ///   base de datos. La pantalla recarga el listado y no reintenta.
    public func accept(
        driverID: OFDriverID,
        vehicleID: OFVehicleID,
        shipmentID: OFShipmentID,
        legID: OFRouteLegID?
    ) async throws -> OFVehicleAssignment {

        try await traceContext.withNewTrace(named: "assignment.accept") {
            var request = Fleet_V1_AssignRequest()
            request.driverID = driverID.rawValue
            request.vehicleID = vehicleID.rawValue
            request.shipmentID = shipmentID.rawValue
            if let legID { request.legID = legID.rawValue }
            request.assignedBy = driverID.rawValue

            do {
                let response = try await fleet.assign(request, callOptions: makeCallOptions())
                guard let assignmentID = OFAssignmentID(rawValue: response.assignmentID) else {
                    throw OFAssignmentError.malformedResponse
                }
                log.notice("assignment \(assignmentID.rawValue, privacy: .public) accepted")

                // No publicamos nada nosotros. `fleet-service` escribe la fila y el evento
                // `fleet.assignment.created` en la misma transacción, vía su bandeja de salida;
                // el terminal se entera del resultado por la respuesta y punto.
                return OFVehicleAssignment(
                    assignmentID: assignmentID,
                    vehicleID: vehicleID,
                    driverID: driverID,
                    shipmentID: shipmentID,
                    legID: legID,
                    assignedAt: response.assignedAt.date,
                    releasedAt: nil,
                    assignedBy: driverID.rawValue
                )
            } catch let status as GRPCStatus {
                throw Self.translate(status)
            }
        }
    }

    /// Cierra la asignación al terminar el tramo.
    ///
    /// Hay dos formas de que una asignación termine y sólo una es ésta. La otra llega sola: cuando
    /// `routing-service` replanifica y publica `route.replanned`, `fleet-service` libera las
    /// asignaciones cuyo `leg_id` ha dejado de existir. El terminal se entera por notificación
    /// push, no llamando aquí.
    public func release(
        assignmentID: OFAssignmentID,
        reason: ReleaseReason,
        distanceTravelledM: Int
    ) async throws {
        var request = Fleet_V1_ReleaseRequest()
        request.assignmentID = assignmentID.rawValue
        request.releaseReason = reason.rawValue
        request.distanceTravelledM = Int64(distanceTravelledM)

        do {
            _ = try await fleet.release(request, callOptions: makeCallOptions())
            log.notice("assignment \(assignmentID.rawValue, privacy: .public) released (\(reason.rawValue, privacy: .public))")
        } catch let status as GRPCStatus {
            throw Self.translate(status)
        }
    }

    // MARK: - Tipos

    public struct Eligibility: Sendable {
        public let isEligible: Bool
        /// Motivos legibles que la pantalla muestra tal cual. Vienen del servidor ya traducidos al
        /// idioma del usuario, según su `locale` en `identity.users`.
        public let blockingReasons: [String]
        public let remainingDriveSeconds: Int
    }

    /// Motivos de cierre que admite `fleet.assignment.released`.
    public enum ReleaseReason: String, Sendable {
        case completed
        case handover
        case breakdown
        case cancelled
    }

    // MARK: - Detalles de transporte

    /// Opciones de llamada comunes.
    ///
    /// La traza va también en gRPC: la misma cabecera `X-OF-Trace-Id`, con el mismo valor que en
    /// las peticiones HTTP del gesto. `fleet-service` la propaga a `container-registry` y a
    /// `routing-service`, y ellos a `geo-service`, que es donde el caché por traza de treinta
    /// segundos evita resolver la misma geocerca dos veces.
    private func makeCallOptions() -> CallOptions {
        var metadata = HPACKHeaders()
        metadata.add(name: "x-of-trace-id", value: traceContext.currentTraceID())
        var options = CallOptions(customMetadata: metadata)
        // Diez segundos. Aceptar una asignación es un gesto en el que el conductor está mirando la
        // pantalla, y `fleet-service` resuelve o rechaza en decenas de milisegundos; si tarda más
        // es que algo está mal y esperar no lo arregla.
        options.timeLimit = .timeout(.seconds(10))
        return options
    }

    private static func translate(_ status: GRPCStatus) -> Error {
        switch status.code {
        case .alreadyExists, .failedPrecondition:
            return OFAssignmentError.alreadyAssigned(detail: status.message ?? "")
        case .permissionDenied:
            return OFAssignmentError.notEligible(detail: status.message ?? "")
        case .deadlineExceeded, .unavailable:
            return OFTransportError.timedOut
        default:
            return OFAssignmentError.serviceFailure(code: status.code.rawValue, detail: status.message ?? "")
        }
    }
}

/// Fallos propios de la reserva de flota.
public enum OFAssignmentError: Error, Sendable {
    /// Solape detectado por la restricción de exclusión sobre `fleet.vehicle_assignments`.
    case alreadyAssigned(detail: String)
    /// Rechazado por `fleet.v1.FleetService/CheckEligibility`: permiso, ADR u horas.
    case notEligible(detail: String)
    case malformedResponse
    case serviceFailure(code: Int, detail: String)
}
