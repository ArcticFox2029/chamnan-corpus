//
//  OFFreightModels.swift
//  OrbitalFreightDriver
//

import Foundation
import CoreLocation

/// Modelos de la parte de carga: lo que `container-registry` devuelve en
/// `GET /v1/shipments/{shipment_id}` y lo que el app le envía en
/// `POST /v1/containers/{container_id}/scans`.
///
/// Es deliberadamente un espejo plano del esquema `freight`: mismos nombres de campo, mismas
/// enumeraciones, mismos `CHECK`. Cuando alguien añade un estado en el servidor y aquí no, la
/// decodificación falla en un sitio y no en quince.

// MARK: - Envío

/// Un envío tal y como lo ve el conductor. Corresponde a una fila de `freight.shipments`.
public struct OFShipment: Codable, Identifiable, Sendable {

    public let shipmentID: OFShipmentID
    public let tenantID: OFTenantID
    /// Referencia de reserva del cliente. Es lo que el conductor lee en el muelle, así que va
    /// siempre en la cabecera de la pantalla aunque internamente ordenemos por `shipmentID`.
    public let reference: String
    public let originFacilityID: OFFacilityID
    public let destinationFacilityID: OFFacilityID
    public let incoterm: String
    public let status: OFShipmentStatus
    public let slaDeadlineAt: Date?
    public let declaredValueMinor: Int64
    public let currency: String
    public let regionCode: OFRegionCode
    public let createdAt: Date
    public let deliveredAt: Date?
    /// `container-registry` los devuelve incrustados en la respuesta de lectura; en el listado
    /// vienen vacíos.
    public let containers: [OFShipmentContainer]

    public var id: String { shipmentID.rawValue }

    /// Valor declarado en unidades menores, junto a su divisa. Nunca se convierte a `Double`:
    /// la regla de la plataforma es que el dinero no viaja como coma flotante y el app no es
    /// una excepción sólo porque aquí sólo se muestre.
    public var declaredValue: OFMoney {
        OFMoney(amountMinor: declaredValueMinor, currency: currency)
    }

    enum CodingKeys: String, CodingKey {
        case shipmentID = "shipment_id"
        case tenantID = "tenant_id"
        case reference
        case originFacilityID = "origin_facility_id"
        case destinationFacilityID = "destination_facility_id"
        case incoterm
        case status
        case slaDeadlineAt = "sla_deadline_at"
        case declaredValueMinor = "declared_value_minor"
        case currency
        case regionCode = "region_code"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case containers
    }
}

/// Estados posibles de `freight.shipments.status`.
///
/// El app no cambia el estado por su cuenta: la única vía legal es
/// `PATCH /v1/shipments/{shipment_id}/status` en `container-registry`, y de los ocho valores el
/// conductor sólo puede provocar dos de forma indirecta (`in_transit` al hacer `gate_out`,
/// `delivered` al cerrar la prueba de entrega). `at_risk` llega solo: `container-registry` lo pone
/// al consumir `telemetry.alert.raised`, y nosotros nos limitamos a pintarlo en rojo.
public enum OFShipmentStatus: String, Codable, Sendable {
    case draft
    case booked
    case sealed
    case inTransit = "in_transit"
    case atRisk = "at_risk"
    case heldAtCustoms = "held_at_customs"
    case delivered
    case cancelled

    /// Un envío precintado ya no admite contenedores nuevos. Lo comprobamos en local para no
    /// gastar un viaje de red y una entrada de cola contra un `409 shipment_already_sealed`.
    public var acceptsNewContainers: Bool {
        switch self {
        case .draft, .booked: return true
        default: return false
        }
    }
}

/// Emparejamiento envío-contenedor con el número de precinto, que pertenece a la pareja y no a
/// ninguno de los dos lados por separado. Refleja `freight.shipment_containers`.
public struct OFShipmentContainer: Codable, Hashable, Sendable {
    public let containerID: OFContainerID
    public let isoCode: String
    public let isoSizeType: String
    public let sealNumber: String
    public let grossKg: Int
    public let isReefer: Bool
    public let setpointC: Decimal?
    public let loadedAt: Date?
    public let unloadedAt: Date?

    enum CodingKeys: String, CodingKey {
        case containerID = "container_id"
        case isoCode = "iso_code"
        case isoSizeType = "iso_size_type"
        case sealNumber = "seal_number"
        case grossKg = "gross_kg"
        case isReefer = "is_reefer"
        case setpointC = "setpoint_c"
        case loadedAt = "loaded_at"
        case unloadedAt = "unloaded_at"
    }
}

// MARK: - Rastro de escaneos

/// Tipos de escaneo admitidos por `freight.shipment_scan_events.scan_type`.
///
/// `proof_of_delivery` tiene consecuencias fuera de `container-registry`: `billing-service`
/// consume `shipment.scanned` y sólo reacciona a ese valor, que es lo que desbloquea la
/// facturación del envío. Por eso la pantalla de entrega pide firma y foto antes de dejar
/// enviarlo, y por eso este caso no se ofrece en el selector genérico de escaneo.
public enum OFScanType: String, Codable, CaseIterable, Sendable {
    case gateIn = "gate_in"
    case gateOut = "gate_out"
    case load
    case unload
    case sealCheck = "seal_check"
    case customsInspection = "customs_inspection"
    case damageReport = "damage_report"
    case proofOfDelivery = "proof_of_delivery"

    /// Escaneos que el conductor puede elegir a mano en el escáner.
    ///
    /// `customs_inspection` lo registra el agente de aduanas desde la consola, y
    /// `proof_of_delivery` tiene su propio flujo con firma.
    public static var driverSelectable: [OFScanType] {
        [.gateIn, .gateOut, .load, .unload, .sealCheck, .damageReport]
    }

    /// Si el escaneo necesita un contenedor concreto o basta con el envío.
    ///
    /// `container_id` es NULL-able en el esquema precisamente para los escaneos de puerta, que
    /// se hacen al camión entero.
    public var requiresContainer: Bool {
        switch self {
        case .gateIn, .gateOut: return false
        default: return true
        }
    }
}

/// Escaneo tal y como lo devuelve `GET /v1/shipments/{shipment_id}/scans` (más reciente primero).
public struct OFScanEvent: Codable, Identifiable, Sendable {
    public let scanID: OFScanID
    public let shipmentID: OFShipmentID
    public let containerID: OFContainerID?
    public let scanType: OFScanType
    public let scannedByUserID: OFUserID
    public let facilityID: OFFacilityID?
    /// Momento real en el muelle, según el reloj del terminal.
    public let occurredAt: Date
    /// Momento en que `container-registry` lo persistió. Los dos valores divergen exactamente lo
    /// que el terminal estuvo sin cobertura, y esa diferencia es la métrica con la que medimos si
    /// la cola sin conexión está haciendo su trabajo.
    public let recordedAt: Date
    public let position: OFGeoPoint?
    public let deviceSerial: String?
    public let notes: String?

    public var id: String { scanID.rawValue }

    /// Retraso introducido por trabajar sin cobertura.
    public var offlineLag: TimeInterval { recordedAt.timeIntervalSince(occurredAt) }

    enum CodingKeys: String, CodingKey {
        case scanID = "scan_id"
        case shipmentID = "shipment_id"
        case containerID = "container_id"
        case scanType = "scan_type"
        case scannedByUserID = "scanned_by_user_id"
        case facilityID = "facility_id"
        case occurredAt = "occurred_at"
        case recordedAt = "recorded_at"
        case position
        case deviceSerial = "device_serial"
        case notes
    }
}

/// Punto geográfico en el formato `{lat, lon}` que viaja en el payload de `shipment.scanned`.
///
/// No usamos `CLLocationCoordinate2D` directamente en la capa de red porque no es `Codable` y
/// porque su orden de campos invita a equivocarse; la conversión vive aquí y en un solo sitio.
public struct OFGeoPoint: Codable, Hashable, Sendable {
    public let lat: Double
    public let lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    public init(_ coordinate: CLLocationCoordinate2D) {
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Dinero

/// Importe en unidades menores más su divisa ISO 4217, que en esta plataforma siempre viajan
/// juntos. El app sólo muestra dinero (facturación es cosa de `billing-service`), pero el tipo
/// existe para que nadie caiga en la tentación de dividir entre cien y guardarlo en un `Double`.
public struct OFMoney: Hashable, Sendable {

    public let amountMinor: Int64
    public let currency: String

    public init(amountMinor: Int64, currency: String) {
        self.amountMinor = amountMinor
        self.currency = currency
    }

    /// Formatea usando la configuración regional del terminal, pero con la divisa del importe.
    ///
    /// Un conductor en Hamburgo con el móvil en español debe ver `1.234,50 USD` y no una
    /// conversión inventada.
    public func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency
        let fractionDigits = formatter.maximumFractionDigits
        let divisor = pow(Decimal(10), fractionDigits)
        let value = Decimal(amountMinor) / divisor
        return formatter.string(from: value as NSDecimalNumber) ?? "\(amountMinor) \(currency)"
    }
}
