//
//  OFEndpoint.swift
//  OrbitalFreightDriver
//

import Foundation

/// Catálogo cerrado de las rutas que el app del conductor tiene permitido llamar, con el servicio
/// dueño de cada una.
///
/// Existe para que ninguna URL se construya interpolando cadenas por ahí suelto. El terminal habla
/// con cinco de los catorce servicios y nada más; si una pantalla necesita algo que no está en
/// este archivo, la conversación es con el equipo dueño del servicio antes que con el compilador.
public enum OFEndpoint: Sendable {

    // MARK: identity-service

    /// `POST /v1/auth/token` — intercambia contraseña + MFA por un par de tokens.
    case issueToken
    /// `POST /v1/auth/token/refresh` — rota el refresh token. Reutilizar uno viejo mata la
    /// `refresh_family_id` entera, así que el `OFTokenStore` serializa esta llamada.
    case refreshToken
    /// `POST /v1/auth/token/revoke` — cierre de sesión explícito desde ajustes.
    case revokeToken
    /// `GET /.well-known/jwks.json` — claves públicas, cacheadas para la ventana de gracia.
    case jwks

    // MARK: fleet-service

    /// `GET /v1/assignments` — filtrado por `driver_id` y `active=true` en el arranque del turno.
    case assignments(driverID: OFDriverID, activeOnly: Bool)
    /// `GET /v1/vehicles/{vehicle_id}`
    case vehicle(OFVehicleID)
    /// `POST /v1/drivers/{driver_id}/hours-of-service`
    case appendHoursOfService(OFDriverID)
    /// `GET /v1/drivers/{driver_id}/availability`
    case driverAvailability(OFDriverID)

    // MARK: container-registry

    /// `GET /v1/shipments/{shipment_id}` — lectura con los contenedores incrustados.
    case shipment(OFShipmentID)
    /// `GET /v1/shipments/{shipment_id}/scans` — el rastro, del más reciente al más antiguo.
    case shipmentScans(OFShipmentID)
    /// `POST /v1/containers/{container_id}/scans` — registra el escaneo y publica
    /// `shipment.scanned`. Es la escritura más frecuente del app con diferencia.
    case recordScan(OFContainerID)
    /// `GET /v1/containers?iso_code=` — resolver un código BIC leído por cámara a un `cnt_`.
    case containerByISOCode(String)
    /// `PATCH /v1/shipments/{shipment_id}/status` — la única vía legal de transición de estado.
    case updateShipmentStatus(OFShipmentID)

    // MARK: document-service

    /// `POST /v1/documents` — subida multiparte de la firma de entrega y de las fotos de daños.
    case uploadDocument
    /// `POST /v1/documents/{document_id}/signed-url` — URL de descarga de 15 minutos.
    case documentSignedURL(OFDocumentID)
    /// `GET /v1/documents/{document_id}` — sólo metadatos. Los bytes no salen nunca por esta ruta,
    /// hay que pedir después la URL firmada.
    case document(OFDocumentID)
    /// `GET /v1/documents?owner_type=&owner_id=&kind=` — la carpeta de papeles de un envío, que es
    /// lo que el conductor enseña en la ventanilla de aduana.
    case documentsForOwner(ownerType: String, ownerID: String, kind: String?)

    // MARK: telemetry-ingest

    /// `GET /v1/alerts` — avisos abiertos del contenedor que el conductor lleva encima.
    case alerts(containerID: OFContainerID, openOnly: Bool)
    /// `POST /v1/alerts/{alert_id}/acknowledge` — el conductor confirma que ha visto la excursión
    /// de temperatura y que va a mirar el grupo frigorífico.
    case acknowledgeAlert(OFAlertID)

    // MARK: - Resolución

    /// Servicio dueño del endpoint. Determina el host y, con él, el certificado que se pinea.
    public var service: OFService {
        switch self {
        case .issueToken, .refreshToken, .revokeToken, .jwks:
            return .identity
        case .assignments, .vehicle, .appendHoursOfService, .driverAvailability:
            return .fleet
        case .shipment, .shipmentScans, .recordScan, .containerByISOCode, .updateShipmentStatus:
            return .containerRegistry
        case .uploadDocument, .documentSignedURL, .document, .documentsForOwner:
            return .document
        case .alerts, .acknowledgeAlert:
            return .telemetryIngest
        }
    }

    public var method: String {
        switch self {
        case .issueToken, .refreshToken, .revokeToken, .recordScan,
             .appendHoursOfService, .uploadDocument, .documentSignedURL, .acknowledgeAlert:
            return "POST"
        case .updateShipmentStatus:
            return "PATCH"
        case .jwks, .assignments, .vehicle, .driverAvailability, .shipment,
             .shipmentScans, .containerByISOCode, .alerts, .document, .documentsForOwner:
            return "GET"
        }
    }

    /// Ruta absoluta, exactamente como está escrita en el contrato. Nada de plurales inventados.
    public var path: String {
        switch self {
        case .issueToken: return "/v1/auth/token"
        case .refreshToken: return "/v1/auth/token/refresh"
        case .revokeToken: return "/v1/auth/token/revoke"
        case .jwks: return "/.well-known/jwks.json"

        case .assignments: return "/v1/assignments"
        case .vehicle(let id): return "/v1/vehicles/\(id.rawValue)"
        case .appendHoursOfService(let id): return "/v1/drivers/\(id.rawValue)/hours-of-service"
        case .driverAvailability(let id): return "/v1/drivers/\(id.rawValue)/availability"

        case .shipment(let id): return "/v1/shipments/\(id.rawValue)"
        case .shipmentScans(let id): return "/v1/shipments/\(id.rawValue)/scans"
        case .recordScan(let id): return "/v1/containers/\(id.rawValue)/scans"
        case .containerByISOCode: return "/v1/containers"
        case .updateShipmentStatus(let id): return "/v1/shipments/\(id.rawValue)/status"

        case .uploadDocument: return "/v1/documents"
        case .documentSignedURL(let id): return "/v1/documents/\(id.rawValue)/signed-url"
        case .document(let id): return "/v1/documents/\(id.rawValue)"
        case .documentsForOwner: return "/v1/documents"

        case .alerts: return "/v1/alerts"
        case .acknowledgeAlert(let id): return "/v1/alerts/\(id.rawValue)/acknowledge"
        }
    }

    /// Parámetros de consulta propios del endpoint. La paginación (`limit`, `cursor`) la añade
    /// `OFCursorPaginator`, no cada caso.
    public var queryItems: [URLQueryItem] {
        switch self {
        case .assignments(let driverID, let activeOnly):
            var items = [URLQueryItem(name: "driver_id", value: driverID.rawValue)]
            if activeOnly { items.append(URLQueryItem(name: "active", value: "true")) }
            return items
        case .containerByISOCode(let isoCode):
            return [URLQueryItem(name: "iso_code", value: isoCode)]
        case .alerts(let containerID, let openOnly):
            var items = [URLQueryItem(name: "container_id", value: containerID.rawValue)]
            if openOnly { items.append(URLQueryItem(name: "state", value: "open")) }
            return items
        case .documentsForOwner(let ownerType, let ownerID, let kind):
            var items = [
                URLQueryItem(name: "owner_type", value: ownerType),
                URLQueryItem(name: "owner_id", value: ownerID)
            ]
            if let kind { items.append(URLQueryItem(name: "kind", value: kind)) }
            return items
        default:
            return []
        }
    }

    /// Si la petición necesita clave de idempotencia.
    ///
    /// La regla de la plataforma la exige en todo lo que crea o cobra. En el terminal la aplicamos
    /// a cualquier escritura sin excepción, porque la cola sin conexión reintenta a ciegas después
    /// de un túnel y no sabe si el primer intento llegó a tocar la base de datos.
    public var requiresIdempotencyKey: Bool { method != "GET" }
}

/// Los cinco servicios con los que el terminal habla directamente.
///
/// No hay ningún BFF por medio: el app es un cliente más y aguanta las mismas cabeceras
/// obligatorias que cualquier servicio interno.
public enum OFService: String, Sendable, CaseIterable {
    case identity = "identity-service"
    case fleet = "fleet-service"
    case containerRegistry = "container-registry"
    case document = "document-service"
    case telemetryIngest = "telemetry-ingest"
}

/// Configuración de destino resuelta en el arranque a partir del perfil de aprovisionamiento.
///
/// Las URL base cambian por región, no sólo por entorno: un envío de `latam-br` se atiende desde
/// la pasarela brasileña y nunca desde la europea, porque la región es residencia del dato.
public struct OFEnvironmentConfiguration: Sendable {

    public let environment: String
    public let regionCode: OFRegionCode
    public let baseURLs: [OFService: URL]
    /// Espejo de `OF_IDENTITY_JWKS_GRACE_SECONDS`: cuánto sigue valiendo un JWKS cacheado cuando
    /// `identity-service` no contesta. El app lo aplica al arrancar sin cobertura para dejar
    /// entrar al conductor con el token que ya tenía.
    public let jwksGraceSeconds: TimeInterval

    public init(
        environment: String,
        regionCode: OFRegionCode,
        baseURLs: [OFService: URL],
        jwksGraceSeconds: TimeInterval = 300
    ) {
        self.environment = environment
        self.regionCode = regionCode
        self.baseURLs = baseURLs
        self.jwksGraceSeconds = jwksGraceSeconds
    }

    /// Construye la URL final de un endpoint.
    ///
    /// - Throws: `OFTransportError.misconfiguredService` si el perfil no trae host para ese
    ///   servicio, que es un fallo de aprovisionamiento y no algo que el usuario pueda arreglar.
    public func url(for endpoint: OFEndpoint, extraQuery: [URLQueryItem] = []) throws -> URL {
        guard let base = baseURLs[endpoint.service] else {
            throw OFTransportError.misconfiguredService(endpoint.service)
        }
        guard var components = URLComponents(
            url: base.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw OFTransportError.misconfiguredService(endpoint.service)
        }
        let items = endpoint.queryItems + extraQuery
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            throw OFTransportError.misconfiguredService(endpoint.service)
        }
        return url
    }
}
