//
//  OFErrorEnvelope.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Uso interno.
//

import Foundation

/// Traducción del sobre de error de ORBITALFREIGHT a tipos de Swift, y la decisión que se toma con
/// él: reintentar, encolar o rendirse y enseñar algo al conductor.
///
/// Todos los servicios devuelven la misma forma, incluidos los gRPC dentro de
/// `google.rpc.Status.details`, así que esta decodificación es única para las cinco pasarelas con
/// las que hablamos.

/// Cuerpo de error tal cual llega por el cable.
public struct OFErrorEnvelope: Decodable, Sendable {

    public struct Body: Decodable, Sendable {
        /// Código estable en `snake_case`. Es contrato público: se puede comparar y se puede
        /// mapear a un mensaje traducido. El campo `message` no, ése cambia sin avisar.
        public let code: String
        public let httpStatus: Int
        public let message: String
        public let traceID: String
        /// Lo que decide el backoff del cliente. No lo deducimos del código HTTP: hay `409` que
        /// sí merecen reintento y `500` que no.
        public let retryable: Bool
        public let fields: [FieldError]?

        enum CodingKeys: String, CodingKey {
            case code
            case httpStatus = "http_status"
            case message
            case traceID = "trace_id"
            case retryable
            case fields
        }
    }

    /// Detalle por campo, usado sobre todo al validar el cuerpo de un escaneo.
    public struct FieldError: Decodable, Sendable {
        /// Ruta JSON dentro de la petición: `containers[0].seal_number`.
        public let path: String
        public let reason: String
    }

    public let error: Body
}

/// Error de servicio ya interpretado, listo para que lo consuman las capas de arriba.
public struct OFServiceError: Error, Sendable {

    public let service: OFService
    public let code: String
    public let httpStatus: Int
    public let message: String
    public let traceID: String
    public let retryable: Bool
    public let fields: [OFErrorEnvelope.FieldError]

    public init(service: OFService, envelope: OFErrorEnvelope) {
        self.service = service
        self.code = envelope.error.code
        self.httpStatus = envelope.error.httpStatus
        self.message = envelope.error.message
        self.traceID = envelope.error.traceID
        self.retryable = envelope.error.retryable
        self.fields = envelope.error.fields ?? []
    }

    /// Códigos que el terminal reconoce y trata de forma específica.
    ///
    /// El resto acaba en un mensaje genérico con el `trace_id` visible, que es lo que el conductor
    /// dicta por teléfono a la central para que puedan seguir la traza.
    public enum Known: String {
        /// El envío ya está precintado: no acepta más contenedores. Lo devuelve `container-registry`.
        case shipmentAlreadySealed = "shipment_already_sealed"
        /// El vehículo o el conductor ya están reservados en ese intervalo. Lo levanta la
        /// restricción `EXCLUDE` de `fleet.vehicle_assignments` y `fleet-service` lo traduce.
        case assignmentOverlap = "assignment_overlap"
        /// Permiso de conducir o certificado ADR caducado, según `fleet.v1.FleetService/CheckEligibility`.
        case driverNotEligible = "driver_not_eligible"
        /// Horas de conducción agotadas para la ventana actual.
        case hoursOfServiceExceeded = "hours_of_service_exceeded"
        /// Cabecera `X-OF-Tenant` incoherente con la reclamación `tid` del token.
        case tenantMismatch = "tenant_mismatch"
        /// Reutilización de un refresh token ya rotado. Mata la familia entera; el conductor
        /// tiene que volver a autenticarse y no hay forma de salvarlo desde aquí.
        case refreshTokenReuse = "refresh_token_reuse"
        /// El documento ya existía con el mismo `sha256`. No es un fallo: `document-service`
        /// deduplica y devuelve el `doc_` que ya tenía.
        case documentDuplicate = "document_duplicate"
        /// Escritura fuera de la región de residencia del envío.
        case regionMismatch = "region_mismatch"
    }

    public var known: Known? { Known(rawValue: code) }

    /// Si merece la pena que la cola sin conexión lo vuelva a intentar.
    ///
    /// Se respeta `retryable` del servidor salvo en un caso: `document_duplicate` viene marcado
    /// como no reintentable y es correcto, pero para nosotros además es un éxito, así que quien
    /// sube documentos lo intercepta antes de llegar aquí.
    public var deservesRetry: Bool {
        if known == .refreshTokenReuse { return false }
        return retryable
    }
}

/// Fallos que ocurren por debajo del sobre: no hubo respuesta, o la hubo pero no era del formato
/// esperado.
public enum OFTransportError: Error, Sendable {
    /// El perfil de aprovisionamiento no trae URL base para ese servicio.
    case misconfiguredService(OFService)
    /// Respuesta con código de error pero sin sobre decodificable. Suele ser el ingress
    /// contestando antes de que la petición llegue al servicio (un `502` del WAF, típicamente).
    case malformedErrorBody(status: Int, service: OFService)
    /// El cuerpo `2xx` no encaja con el tipo esperado. Esto es una divergencia de contrato y se
    /// reporta con `trace_id` aunque el usuario no vea nada.
    case decodingFailed(underlying: Error, endpointPath: String)
    /// No hay red. Distinto de un timeout: aquí ni se intenta, se encola directamente.
    case offline
    /// Se agotó el plazo. La petición pudo llegar o no, así que la clave de idempotencia es lo
    /// único que nos salva de duplicar el escaneo al reintentar.
    case timedOut
    /// El pinning de certificado no cuadró. Nunca se reintenta y nunca se degrada a HTTP.
    case certificatePinningFailed(OFService)
}

extension OFTransportError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .misconfiguredService(let service):
            return "no base URL provisioned for \(service.rawValue)"
        case .malformedErrorBody(let status, let service):
            return "\(service.rawValue) returned HTTP \(status) without a decodable error envelope"
        case .decodingFailed(_, let path):
            return "response body for \(path) did not match the expected contract"
        case .offline:
            return "device is offline"
        case .timedOut:
            return "request timed out"
        case .certificatePinningFailed(let service):
            return "certificate pinning failed for \(service.rawValue)"
        }
    }

    /// Sólo dos de estos justifican encolar y seguir; el resto son fallos de configuración o de
    /// contrato y encolarlos sería llenar el disco del terminal de basura que nunca saldrá.
    public var shouldEnqueue: Bool {
        switch self {
        case .offline, .timedOut: return true
        default: return false
        }
    }
}
