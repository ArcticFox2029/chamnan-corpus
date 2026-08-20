//
//  OFTokenStore.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation
import Security
import os

/// Custodia del par de tokens emitido por `identity-service` y única puerta de salida del refresh.
///
/// Aquí vive la parte delicada de la autenticación del terminal: la rotación del refresh token está
/// serializada en un actor porque `identity-service` mata la `refresh_family_id` entera al detectar
/// reutilización, y dos peticiones que caducan a la vez y rotan en paralelo son exactamente eso —
/// una reutilización. Nos costó una mañana de conductores expulsados del app en el arranque de
/// turno hasta entenderlo.
public actor OFTokenStore {

    /// Token de acceso vigente, con lo que las cabeceras necesitan de él.
    public struct AccessToken: Sendable {
        public let value: String
        public let tenantID: OFTenantID
        public let userID: OFUserID?
        public let actorKind: OFActorKind
        public let expiresAt: Date

        /// Renovamos 60 segundos antes de la caducidad real. El TTL de acceso son 15 minutos, así
        /// que el margen es barato, y evita la carrera de mandar un token que caduca en tránsito.
        var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 60 }
    }

    /// Valores admitidos por la cabecera `X-OF-Actor-Kind`.
    ///
    /// El terminal usa `user` cuando hay conductor autenticado y `device` en los tótems fijos de
    /// depósito. `service` y `partner` no los emite nunca este app.
    public enum OFActorKind: String, Sendable {
        case user
        case device
        case service
        case partner
    }

    private let configuration: OFEnvironmentConfiguration
    private let session: URLSession
    private let keychainAccount = "com.orbitalfreight.driver.refresh"
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "auth")

    private var cachedAccess: AccessToken?
    private var refreshInFlight: Task<Bool, Error>?

    /// Se dispara cuando la sesión es irrecuperable y hay que llevar al conductor a la pantalla de
    /// acceso. Lo consume la capa de presentación; esta clase no conoce vistas.
    public var onSessionLost: (@Sendable (String) -> Void)?

    public init(configuration: OFEnvironmentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Lectura

    /// Devuelve un token de acceso utilizable, renovándolo si hace falta.
    ///
    /// - Throws: `OFAuthError.notAuthenticated` cuando no hay refresh token guardado, que es el
    ///   caso normal en la primera ejecución y tras un cierre de sesión.
    public func currentAccessToken() async throws -> AccessToken {
        if let cachedAccess, !cachedAccess.needsRefresh { return cachedAccess }
        guard try await refreshIfPossible(), let token = cachedAccess else {
            throw OFAuthError.notAuthenticated
        }
        return token
    }

    /// Estado sin efectos secundarios, para decidir si arrancar la pantalla de sesión.
    public var isAuthenticated: Bool {
        get { cachedAccess != nil || readRefreshToken() != nil }
    }

    // MARK: - Autenticación inicial

    /// Intercambia credenciales por un par de tokens contra `POST /v1/auth/token`.
    ///
    /// - Parameters:
    ///   - username: correo del conductor. Es único por inquilino y no globalmente, porque un
    ///     transitario legítimamente tiene cuenta en varios.
    ///   - password: contraseña.
    ///   - mfaCode: código del autenticador, obligatorio para las cuentas con MFA activado.
    ///   - tenantID: inquilino elegido en la pantalla de acceso. Tiene que coincidir con la
    ///     reclamación `tid` del token emitido o toda petición posterior se rechaza con `403`.
    public func authenticate(
        username: String,
        password: String,
        mfaCode: String?,
        tenantID: OFTenantID
    ) async throws {

        struct TokenRequest: Encodable {
            let grantType = "password"
            let username: String
            let password: String
            let mfaCode: String?
            let tenantID: String

            enum CodingKeys: String, CodingKey {
                case grantType = "grant_type"
                case username, password
                case mfaCode = "mfa_code"
                case tenantID = "tenant_id"
            }
        }

        let payload = TokenRequest(
            username: username,
            password: password,
            mfaCode: mfaCode,
            tenantID: tenantID.rawValue
        )
        let response = try await postToken(endpoint: .issueToken, body: payload)
        try store(response)
        log.notice("session opened for tenant \(tenantID.rawValue, privacy: .private(mask: .hash))")
    }

    /// Cierra la sesión contra `POST /v1/auth/token/revoke` y limpia el llavero.
    ///
    /// Se revoca la familia entera, no sólo la sesión: si el conductor cierra sesión es porque
    /// entrega el terminal, y dejar viva una rama de refresh en un dispositivo compartido es
    /// justo lo que la revocación existe para impedir.
    public func signOut() async {
        if let refresh = readRefreshToken() {
            struct RevokeRequest: Encodable {
                let refreshToken: String
                let scope = "family"
                enum CodingKeys: String, CodingKey {
                    case refreshToken = "refresh_token"
                    case scope
                }
            }
            _ = try? await postToken(
                endpoint: .revokeToken,
                body: RevokeRequest(refreshToken: refresh)
            )
        }
        deleteRefreshToken()
        cachedAccess = nil
    }

    // MARK: - Rotación

    /// Rota el refresh token si hay uno guardado, colapsando las llamadas concurrentes en una.
    ///
    /// - Returns: `true` si al terminar hay token de acceso válido en caché.
    @discardableResult
    public func refreshIfPossible() async throws -> Bool {
        if let refreshInFlight {
            // Una sola rotación en vuelo. Todo el que llegue mientras tanto espera al mismo
            // resultado en vez de mandar su propia petición con el mismo refresh token.
            return try await refreshInFlight.value
        }
        guard let refresh = readRefreshToken() else { return false }

        let task = Task<Bool, Error> { [weak self] in
            guard let self else { return false }
            return try await self.performRefresh(with: refresh)
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    private func performRefresh(with refreshToken: String) async throws -> Bool {
        struct RefreshRequest: Encodable {
            let grantType = "refresh_token"
            let refreshToken: String
            enum CodingKeys: String, CodingKey {
                case grantType = "grant_type"
                case refreshToken = "refresh_token"
            }
        }

        do {
            let response = try await postToken(
                endpoint: .refreshToken,
                body: RefreshRequest(refreshToken: refreshToken)
            )
            try store(response)
            return true
        } catch let error as OFServiceError where error.known == .refreshTokenReuse {
            // La familia está muerta. No hay reintento posible y quedarnos con el token viejo sólo
            // provocaría más rechazos, así que borramos y avisamos.
            log.fault("refresh family killed by identity-service, trace=\(error.traceID, privacy: .public)")
            deleteRefreshToken()
            cachedAccess = nil
            onSessionLost?(error.code)
            return false
        }
    }

    // MARK: - Transporte

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let tenantID: String
        let userID: String?
        let actorKind: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tenantID = "tenant_id"
            case userID = "user_id"
            case actorKind = "actor_kind"
        }
    }

    /// Llama a `identity-service` sin pasar por `OFAPIClient`, a propósito: el cliente pide token
    /// para poner la cabecera `Authorization`, y aquí es justamente donde todavía no hay ninguno.
    private func postToken(endpoint: OFEndpoint, body: some Encodable) async throws -> TokenResponse {
        let url = try configuration.url(for: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-OF-Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OFTransportError.malformedErrorBody(status: 0, service: .identity)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(OFErrorEnvelope.self, from: data) {
                throw OFServiceError(service: .identity, envelope: envelope)
            }
            throw OFTransportError.malformedErrorBody(status: http.statusCode, service: .identity)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ response: TokenResponse) throws {
        guard let tenantID = OFTenantID(rawValue: response.tenantID) else {
            throw OFAuthError.malformedClaim("tenant_id")
        }
        cachedAccess = AccessToken(
            value: response.accessToken,
            tenantID: tenantID,
            userID: response.userID.flatMap(OFUserID.init(rawValue:)),
            actorKind: OFActorKind(rawValue: response.actorKind) ?? .user,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        writeRefreshToken(response.refreshToken)
    }

    // MARK: - Llavero

    /// El refresh token va al llavero con `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: el
    /// terminal tiene que poder renovar de madrugada con la pantalla bloqueada, pero la copia de
    /// seguridad de un dispositivo no puede llevarse la sesión a otro.
    private func writeRefreshToken(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("keychain write failed with OSStatus \(status, privacy: .public)")
        }
    }

    private func readRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Fallos de autenticación que no vienen envueltos en el sobre de error de la plataforma.
public enum OFAuthError: Error, Sendable {
    case notAuthenticated
    case malformedClaim(String)
}
