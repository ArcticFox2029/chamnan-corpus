//
//  OFAPIClient.swift
//  OrbitalFreightDriver
//

import Foundation
import os

/// Cliente HTTP único del terminal del conductor.
///
/// Su trabajo es que ninguna petición salga del dispositivo sin las cinco cabeceras obligatorias de
/// la plataforma, y que ninguna respuesta suba a las pantallas sin haber pasado por el sobre de
/// error. Todo lo que el app escribe contra `container-registry`, `fleet-service`,
/// `document-service` y `telemetry-ingest` pasa por aquí; lo que no pasa por aquí es porque va por
/// gRPC, y ése es el cliente de `OFAssignmentService`.
public actor OFAPIClient {

    private let configuration: OFEnvironmentConfiguration
    private let session: URLSession
    private let tokenStore: OFTokenStore
    private let traceContext: OFTraceContext
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "api")

    public init(
        configuration: OFEnvironmentConfiguration,
        tokenStore: OFTokenStore,
        traceContext: OFTraceContext,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.traceContext = traceContext
        self.session = session

        // Los timestamps de la plataforma son RFC 3339 en UTC con sufijo Z y milisegundos
        // opcionales. `.iso8601` de serie se atraganta con la fracción de segundo, así que
        // llevamos un formateador propio en vez de rezar.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = OFRFC3339.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "not an RFC 3339 UTC timestamp: \(raw)"
                )
            }
            return date
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(OFRFC3339.string(from: date))
        }
        self.encoder = encoder
    }

    // MARK: - Petición con cuerpo decodificable

    /// Ejecuta una petición y decodifica la respuesta.
    ///
    /// - Parameters:
    ///   - endpoint: destino, del catálogo cerrado de `OFEndpoint`.
    ///   - body: cuerpo a codificar en JSON, o `nil` para las lecturas.
    ///   - idempotencyKey: obligatoria en toda escritura. Cuando la petición viene de la cola sin
    ///     conexión es la misma clave del primer intento, que es lo único que impide que un
    ///     escaneo reintentado tras un túnel se convierta en dos filas de
    ///     `freight.shipment_scan_events`.
    ///   - extraQuery: paginación u otros parámetros que no pertenecen al endpoint en sí.
    /// - Returns: el cuerpo decodificado.
    /// - Throws: `OFServiceError` si el servicio contestó con sobre de error, `OFTransportError`
    ///   en cualquier otro caso.
    public func send<Response: Decodable>(
        _ endpoint: OFEndpoint,
        body: (some Encodable)? = Optional<OFEmptyBody>.none,
        idempotencyKey: String? = nil,
        extraQuery: [URLQueryItem] = [],
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await sendRaw(
            endpoint,
            body: body,
            idempotencyKey: idempotencyKey,
            extraQuery: extraQuery
        )
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            log.error("contract drift on \(endpoint.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw OFTransportError.decodingFailed(underlying: error, endpointPath: endpoint.path)
        }
    }

    /// Variante que devuelve los bytes sin tocar, para las respuestas que el app reenvía tal cual
    /// (la subida de documentos, por ejemplo, cuyo cuerpo se guarda entero en la cola).
    public func sendRaw(
        _ endpoint: OFEndpoint,
        body: (some Encodable)? = Optional<OFEmptyBody>.none,
        idempotencyKey: String? = nil,
        extraQuery: [URLQueryItem] = [],
        rawBody: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {

        let url = try configuration.url(for: endpoint, extraQuery: extraQuery)
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method

        if let rawBody {
            request.httpBody = rawBody
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        try await applyPlatformHeaders(to: &request, endpoint: endpoint, idempotencyKey: idempotencyKey)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.translate(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OFTransportError.malformedErrorBody(status: 0, service: endpoint.service)
        }

        // 401 con token caducado: renovamos una sola vez y repetimos. Si el segundo intento
        // vuelve a dar 401 el problema no es el reloj sino la sesión, y hay que echar al usuario.
        if http.statusCode == 401 {
            let renewed = try await tokenStore.refreshIfPossible()
            if renewed {
                try await applyPlatformHeaders(to: &request, endpoint: endpoint, idempotencyKey: idempotencyKey)
                let (retryData, retryResponse) = try await session.data(for: request)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw OFTransportError.malformedErrorBody(status: 0, service: endpoint.service)
                }
                if (200..<300).contains(retryHTTP.statusCode) { return retryData }
                throw try makeError(from: retryData, status: retryHTTP.statusCode, service: endpoint.service)
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw try makeError(from: data, status: http.statusCode, service: endpoint.service)
        }
        return data
    }

    // MARK: - Cabeceras

    /// Pone las cinco cabeceras que exige la plataforma.
    ///
    /// `X-OF-Actor-Kind` es `user` mientras haya conductor autenticado y `device` cuando el
    /// terminal actúa con credencial de dispositivo (los tótems fijos de depósito, que no tienen
    /// persona detrás). Es la diferencia entre poder firmar una entrega y no poder.
    private func applyPlatformHeaders(
        to request: inout URLRequest,
        endpoint: OFEndpoint,
        idempotencyKey: String?
    ) async throws {

        if endpoint.service != .identity || endpoint.method != "POST" {
            let token = try await tokenStore.currentAccessToken()
            request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
            request.setValue(token.tenantID.rawValue, forHTTPHeaderField: "X-OF-Tenant")
            request.setValue(token.actorKind.rawValue, forHTTPHeaderField: "X-OF-Actor-Kind")
        }

        request.setValue(traceContext.currentTraceID(), forHTTPHeaderField: "X-OF-Trace-Id")

        if endpoint.requiresIdempotencyKey {
            guard let idempotencyKey else {
                // Preferimos romper en desarrollo a mandar una escritura sin clave: el servidor
                // la aceptaría, y el duplicado aparecería tres semanas después en una discrepancia
                // de conciliación que nadie sabría atribuir.
                assertionFailure("write to \(endpoint.path) without an idempotency key")
                throw OFTransportError.misconfiguredService(endpoint.service)
            }
            request.setValue(idempotencyKey, forHTTPHeaderField: "X-OF-Idempotency-Key")
        }

        // No se manda ninguna cabecera de región. La lista de cabeceras de la plataforma es cerrada
        // y no incluye ninguna: el destino ya es el de la región del terminal, y el servicio deduce
        // la residencia de los datos que toca, no de lo que le diga el cliente.
        request.setValue(OFDeviceInfo.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func makeError(from data: Data, status: Int, service: OFService) throws -> Error {
        guard let envelope = try? decoder.decode(OFErrorEnvelope.self, from: data) else {
            return OFTransportError.malformedErrorBody(status: status, service: service)
        }
        let error = OFServiceError(service: service, envelope: envelope)
        log.error("\(service.rawValue, privacy: .public) \(error.code, privacy: .public) trace=\(error.traceID, privacy: .public)")
        return error
    }

    private static func translate(_ error: URLError) -> OFTransportError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        case .timedOut:
            return .timedOut
        case .serverCertificateUntrusted, .cancelled where error.userInfo["pinning"] != nil:
            return .certificatePinningFailed(.identity)
        default:
            return .offline
        }
    }
}

/// Cuerpo vacío para las peticiones sin payload. Existe sólo para que el genérico de `send` tenga
/// un tipo con el que resolverse.
public struct OFEmptyBody: Codable, Sendable {}

/// Respuesta sin contenido útil (`204`, o un `200` cuyo cuerpo no nos interesa).
public struct OFAcknowledgement: Decodable, Sendable {
    public let acknowledged: Bool

    public init(from decoder: Decoder) throws {
        // Varios endpoints devuelven `{}` y otros `{"acknowledged": true}`. Aceptamos ambos: el
        // éxito ya lo indicó el código HTTP.
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        self.acknowledged = (try? container?.decode(Bool.self, forKey: .acknowledged)) ?? true
    }

    enum CodingKeys: String, CodingKey { case acknowledged }
}

/// Formateo RFC 3339 en UTC, que es el único formato de fecha que la plataforma admite en el cable.
enum OFRFC3339 {

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    /// Siempre escribimos con milisegundos. `occurred_at` y `recorded_at` de un mismo escaneo
    /// pueden diferir en décimas cuando hay cobertura, y perder esa precisión al escribir hacía
    /// que el rastro ordenado por `occurred_at DESC` saliera con empates arbitrarios.
    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }
}

/// Datos del terminal que viajan en cada petición.
enum OFDeviceInfo {

    /// Serie del dispositivo, que es lo que acaba en `freight.shipment_scan_events.device_serial`.
    /// En los tótems de depósito es la serie del lector; en un iPhone personal es el identificador
    /// de aprovisionamiento MDM, nunca el IDFV.
    static var deviceSerial: String {
        UserDefaults.standard.string(forKey: "of.device.serial") ?? "unprovisioned"
    }

    static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "OrbitalFreightDriver/\(version) (\(build); iOS)"
    }()
}
