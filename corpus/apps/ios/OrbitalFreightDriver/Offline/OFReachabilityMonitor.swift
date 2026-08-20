//
//  OFReachabilityMonitor.swift
//  OrbitalFreightDriver
//

import Foundation
import Network
import os

/// Vigila la conectividad del terminal y avisa cuando vuelve a haber red utilizable.
///
/// "Utilizable" no es lo mismo que "conectada". El caso que nos importa es el portal cautivo del
/// wifi de un depósito de contenedores: `NWPathMonitor` da la ruta por satisfecha, el conductor
/// escanea, y todo se queda en la cola porque cada petición se come una página de login. Por eso
/// aquí, además del estado del sistema, se comprueba `GET /healthz` del servicio con el que
/// realmente hay que hablar antes de declarar la red buena.
public actor OFReachabilityMonitor {

    /// Estado de la conectividad tal y como lo usa el drenador.
    public enum Status: Sendable, CustomStringConvertible {
        /// Sin ruta.
        case offline
        /// Hay ruta pero no se ha validado contra la plataforma todavía.
        case unverified(interface: String)
        /// Ruta validada: `/healthz` contestó.
        case online(interface: String, expensive: Bool)
        /// Hay ruta, pero algo entre medias intercepta las peticiones.
        case captivePortal

        public var isUsable: Bool {
            if case .online = self { return true }
            return false
        }

        /// Redes caras (datos móviles en itinerancia). El drenador sigue funcionando, pero la
        /// subida de fotos de daños espera a tener wifi salvo que el conductor la fuerce: una
        /// prueba de entrega son unos kilobytes y una foto de daños puede ser de varios megas.
        public var isExpensive: Bool {
            if case .online(_, let expensive) = self { return expensive }
            return false
        }

        public var description: String {
            switch self {
            case .offline: return "offline"
            case .unverified(let interface): return "unverified(\(interface))"
            case .online(let interface, let expensive): return "online(\(interface),expensive=\(expensive))"
            case .captivePortal: return "captive-portal"
            }
        }
    }

    private let monitor = NWPathMonitor()
    private let configuration: OFEnvironmentConfiguration
    private let session: URLSession
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "reachability")

    private var continuations: [UUID: AsyncStream<Status>.Continuation] = [:]
    private(set) public var current: Status = .offline

    public init(configuration: OFEnvironmentConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Empieza a observar. Idempotente: llamarlo dos veces no duplica el observador.
    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handle(path: path) }
        }
        monitor.start(queue: DispatchQueue(label: "com.orbitalfreight.driver.reachability"))
    }

    public func stop() {
        monitor.cancel()
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }

    /// Flujo de estados. Cada suscriptor recibe el estado actual de entrada y luego los cambios.
    public func statusStream() -> AsyncStream<Status> {
        AsyncStream { continuation in
            let identifier = UUID()
            continuation.yield(current)
            continuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(identifier) }
            }
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations[identifier] = nil
    }

    // MARK: - Evaluación

    private func handle(path: NWPath) async {
        guard path.status == .satisfied else {
            publish(.offline)
            return
        }
        let interface = Self.describe(path)
        publish(.unverified(interface: interface))

        let verified = await verifyPlatformReachable()
        publish(verified ? .online(interface: interface, expensive: path.isExpensive) : .captivePortal)
    }

    /// Comprueba `GET /healthz` de `container-registry`.
    ///
    /// Se elige ese servicio y no otro porque es el destino de la mayor parte de lo que hay en la
    /// cola, y porque `/healthz` es liveness pura: no toca la base de datos, así que un `200` aquí
    /// significa "hay camino hasta el clúster" y nada más, que es justo lo que preguntamos.
    private func verifyPlatformReachable() async -> Bool {
        guard let base = configuration.baseURLs[.containerRegistry] else { return false }
        var request = URLRequest(url: base.appendingPathComponent("/healthz"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // Un portal cautivo devuelve casi siempre 200 con HTML, o un 302 a su página de login.
            // Distinguirlo por el `Content-Type` es más fiable que por el código.
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("text/html") {
                log.notice("captive portal detected on the current interface")
                return false
            }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    private func publish(_ status: Status) {
        guard status.description != current.description else { return }
        current = status
        log.info("reachability -> \(status.description, privacy: .public)")
        for continuation in continuations.values { continuation.yield(status) }
    }

    private static func describe(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        return "other"
    }
}
