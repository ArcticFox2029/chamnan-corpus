import Foundation

//
//  OFFleetModels.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT.
//

/// Modelos de la flota: asignaciones, vehículos, conductor y estado de jornada.
///
/// Todo lo que hay aquí pertenece a `fleet-service`, que es quien decide si una asignación existe
/// (el árbitro real es la restricción `EXCLUDE` sobre `fleet.vehicle_assignments`, no el app). El
/// terminal del conductor sólo lee y propone; nunca da por hecha una reserva que no le haya
/// confirmado `fleet.v1.FleetService/Assign`.

// MARK: - Asignación

/// Una fila de `fleet.vehicle_assignments` vista desde el terminal.
public struct OFVehicleAssignment: Codable, Identifiable, Sendable {

    public let assignmentID: OFAssignmentID
    public let vehicleID: OFVehicleID
    public let driverID: OFDriverID
    public let shipmentID: OFShipmentID
    /// Tramo concreto de la ruta. Puede desaparecer sin previo aviso: cuando `routing-service`
    /// replanifica publica `route.replanned`, y `fleet-service` libera las asignaciones cuyo
    /// `leg_id` ya no existe. El app se entera por push, no preguntando en bucle.
    public let legID: OFRouteLegID?
    public let assignedAt: Date
    public let releasedAt: Date?
    public let assignedBy: String

    public var id: String { assignmentID.rawValue }

    /// Una asignación está viva mientras no tenga `released_at`.
    public var isActive: Bool { releasedAt == nil }

    enum CodingKeys: String, CodingKey {
        case assignmentID = "assignment_id"
        case vehicleID = "vehicle_id"
        case driverID = "driver_id"
        case shipmentID = "shipment_id"
        case legID = "leg_id"
        case assignedAt = "assigned_at"
        case releasedAt = "released_at"
        case assignedBy = "assigned_by"
    }
}

/// Vehículo tal y como lo devuelve `GET /v1/vehicles/{vehicle_id}`.
public struct OFVehicle: Codable, Identifiable, Sendable {
    public let vehicleID: OFVehicleID
    public let carrierID: String
    public let plate: String
    public let plateCountry: String
    public let vehicleClass: OFVehicleClass
    public let maxPayloadKg: Int
    /// Serie de la unidad telemática montada en el vehículo. Coincide con
    /// `telemetry.device_gateways.serial`, y es el valor que ponemos en `device_serial` cuando el
    /// escaneo lo hace el terminal fijo de la cabina en vez del móvil del conductor.
    public let telematicsUnitID: String?
    public let adrCertified: Bool
    public let decommissionedAt: Date?

    public var id: String { vehicleID.rawValue }

    enum CodingKeys: String, CodingKey {
        case vehicleID = "vehicle_id"
        case carrierID = "carrier_id"
        case plate
        case plateCountry = "plate_country"
        case vehicleClass = "vehicle_class"
        case maxPayloadKg = "max_payload_kg"
        case telematicsUnitID = "telematics_unit_id"
        case adrCertified = "adr_certified"
        case decommissionedAt = "decommissioned_at"
    }
}

/// Clases de vehículo de `fleet.vehicles.vehicle_class`.
///
/// La lista incluye modos que un conductor de carretera no conduce nunca (`rail_wagon`, `barge`)
/// porque el mismo catálogo sirve a la consola de despacho. El app los decodifica igual: descartar
/// un valor válido del servidor sería romper la lectura de una asignación multimodal perfectamente
/// legítima.
public enum OFVehicleClass: String, Codable, Sendable {
    case van
    case rigid
    case tractor
    case chassis
    case reeferTractor = "reefer_tractor"
    case railWagon = "rail_wagon"
    case barge

    /// Si esta clase la conduce físicamente el usuario del app.
    public var isDriverOperated: Bool {
        switch self {
        case .railWagon, .barge: return false
        default: return true
        }
    }
}

/// Ficha del conductor conectado, derivada de `fleet.drivers`.
public struct OFDriverProfile: Codable, Sendable {
    public let driverID: OFDriverID
    public let carrierID: String
    /// Nulo para subcontratados: entran en el listado mucho antes de tener cuenta en la consola,
    /// a veces sin llegar a tenerla nunca. Si es nulo el app funciona en modo credencial de
    /// dispositivo y no puede firmar entregas a su nombre.
    public let userID: OFUserID?
    public let fullName: String
    public let licenceNumber: String
    public let licenceCountry: String
    public let licenceExpiresOn: OFCalendarDate
    public let adrExpiresOn: OFCalendarDate?
    public let phoneE164: String

    enum CodingKeys: String, CodingKey {
        case driverID = "driver_id"
        case carrierID = "carrier_id"
        case userID = "user_id"
        case fullName = "full_name"
        case licenceNumber = "licence_number"
        case licenceCountry = "licence_country"
        case licenceExpiresOn = "licence_expires_on"
        case adrExpiresOn = "adr_expires_on"
        case phoneE164 = "phone_e164"
    }
}

// MARK: - Jornada

/// Cambio de estado de jornada que el app envía a
/// `POST /v1/drivers/{driver_id}/hours-of-service`.
///
/// El registro es acumulativo: cada llamada añade un cambio, nunca corrige el anterior. Una
/// corrección es otro cambio con nota, igual que en el resto de la plataforma.
public struct OFDutyStatusChange: Codable, Sendable {
    public let status: OFDutyStatus
    public let occurredAt: Date
    public let position: OFGeoPoint?
    public let vehicleID: OFVehicleID?
    public let odometerKm: Int?
    public let note: String?

    public init(
        status: OFDutyStatus,
        occurredAt: Date,
        position: OFGeoPoint?,
        vehicleID: OFVehicleID?,
        odometerKm: Int?,
        note: String? = nil
    ) {
        self.status = status
        self.occurredAt = occurredAt
        self.position = position
        self.vehicleID = vehicleID
        self.odometerKm = odometerKm
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case status
        case occurredAt = "occurred_at"
        case position
        case vehicleID = "vehicle_id"
        case odometerKm = "odometer_km"
        case note
    }
}

/// Estados de jornada del reglamento europeo, que es el que aplica `fleet-service` al calcular
/// disponibilidad.
public enum OFDutyStatus: String, Codable, CaseIterable, Sendable {
    case driving
    case onDuty = "on_duty"
    case rest
    case availability
    case offDuty = "off_duty"
}

/// Respuesta de `GET /v1/drivers/{driver_id}/availability`: cuánto le queda al conductor.
///
/// El cálculo lo hace `fleet-service` y el app no lo replica ni lo corrige. Sí lo cachea, porque
/// la pantalla de jornada tiene que seguir mostrando algo dentro de un túnel.
public struct OFDriverAvailability: Codable, Sendable {
    public let driverID: OFDriverID
    public let remainingDriveSeconds: Int
    public let remainingDutySeconds: Int
    public let nextRequiredRestAt: Date?
    public let currentStatus: OFDutyStatus
    public let calculatedAt: Date

    /// Marca de agua para avisar al conductor antes de que `fleet.v1.FleetService/CheckEligibility`
    /// le rechace la siguiente asignación por horas.
    public var isCloseToLimit: Bool { remainingDriveSeconds < 30 * 60 }

    enum CodingKeys: String, CodingKey {
        case driverID = "driver_id"
        case remainingDriveSeconds = "remaining_drive_seconds"
        case remainingDutySeconds = "remaining_duty_seconds"
        case nextRequiredRestAt = "next_required_rest_at"
        case currentStatus = "current_status"
        case calculatedAt = "calculated_at"
    }
}

/// Fecha sin hora, en el formato de las columnas con sufijo `_on` (`licence_expires_on`,
/// `insurance_expires_on`). Se decodifica como `YYYY-MM-DD` y no como instante: convertirla a
/// `Date` en el huso del terminal hacía que un permiso caducase un día antes en Auckland.
public struct OFCalendarDate: Codable, Hashable, Comparable, Sendable {

    public let year: Int
    public let month: Int
    public let day: Int

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected a YYYY-MM-DD calendar date, got \(raw)"
            )
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }

    public static func < (lhs: OFCalendarDate, rhs: OFCalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
