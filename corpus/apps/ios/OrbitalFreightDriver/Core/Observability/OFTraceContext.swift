import Foundation
import os

//
//  OFTraceContext.swift
//  OrbitalFreightDriver
//

/// Genera y propaga el `trace-id` de W3C que viaja en `X-OF-Trace-Id`, y agrupa bajo una misma
/// traza todas las llamadas de una acción del conductor.
///
/// No es sólo telemetría. La traza tiene un efecto medible en el backend: `geo-service` cachea el
/// resultado de `geo.v1.GeoService/ResolveGeofence` por traza durante 30 segundos, y una asignación
/// de flota resuelve la misma geocerca dos veces —una por `container-registry` y otra por
/// `routing-service`, ambas colgando de `fleet-service`— salvo que el llamante propague la misma
/// cabecera. Si el terminal inventa un `trace-id` por petición, ese caché no acierta nunca.
public final class OFTraceContext: @unchecked Sendable {

    private let lock = NSLock()
    private var activeTraceID: String
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "trace")

    public init() {
        self.activeTraceID = Self.makeTraceID()
    }

    /// Traza en curso, en minúsculas y 32 hexadecimales exactos.
    public func currentTraceID() -> String {
        lock.lock()
        defer { lock.unlock() }
        return activeTraceID
    }

    /// Abre una traza nueva para una acción de usuario y la deja activa mientras dura el bloque.
    ///
    /// Una "acción" es lo que el conductor percibe como un gesto único: pulsar *escanear*, cerrar
    /// una entrega, aceptar una asignación. Todo lo que se dispare dentro —la lectura del envío,
    /// la subida del documento, el registro del escaneo— comparte identificador y se ve como una
    /// sola cascada en el colector.
    ///
    /// - Parameters:
    ///   - name: etiqueta legible, sólo para los logs locales.
    ///   - operation: trabajo a ejecutar bajo la traza nueva.
    public func withNewTrace<T>(named name: String, _ operation: () async throws -> T) async rethrows -> T {
        let previous: String
        let fresh = Self.makeTraceID()
        lock.lock()
        previous = activeTraceID
        activeTraceID = fresh
        lock.unlock()

        log.debug("trace \(fresh, privacy: .public) opened for \(name, privacy: .public)")
        defer {
            lock.lock()
            activeTraceID = previous
            lock.unlock()
        }
        return try await operation()
    }

    /// Adopta una traza que ya viene decidida desde fuera.
    ///
    /// El caso real es el push: `notification-service` incluye el `trace_id` del evento que originó
    /// el aviso, y cuando el conductor toca la notificación queremos que lo que haga a continuación
    /// cuelgue de esa misma traza en vez de empezar una huérfana.
    public func adopt(traceID: String) -> Bool {
        guard Self.isValid(traceID) else {
            log.error("rejected malformed inbound trace id")
            return false
        }
        lock.lock()
        activeTraceID = traceID.lowercased()
        lock.unlock()
        return true
    }

    /// Traza de la cola sin conexión.
    ///
    /// Cuando una operación se encola, guardamos la traza del momento del gesto y la reutilizamos
    /// al drenarla horas más tarde. Es la única forma de que en el colector el escaneo aparezca
    /// junto a la lectura del envío que lo precedió, y no como un evento suelto de las 03:40.
    public static func makeTraceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        // 16 bytes aleatorios; el generador del sistema es de calidad criptográfica y no cuesta
        // nada frente a una petición de red.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // La especificación de W3C prohíbe el trace-id todo a ceros. Es improbable, pero es un
        // rechazo silencioso en el colector cuando pasa.
        if bytes.allSatisfy({ $0 == 0 }) { bytes[15] = 1 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ candidate: String) -> Bool {
        guard candidate.count == 32 else { return false }
        guard candidate.allSatisfy({ $0.isHexDigit }) else { return false }
        return candidate.contains { $0 != "0" }
    }
}

/// Muestreo local. Espejo de `OF_OTEL_SAMPLE_RATIO`, que en producción va al 5 % y en preproducción
/// al 100 %.
///
/// El terminal muestrea aparte del backend porque su volumen es otro: un conductor genera unas
/// decenas de trazas por turno, no miles por segundo. Aun así respetamos la proporción configurada
/// para que las trazas del móvil y las del servicio se puedan comparar sin corregir sesgo.
public struct OFTraceSampler: Sendable {

    public let ratio: Double

    public init(ratio: Double) {
        self.ratio = min(max(ratio, 0), 1)
    }

    /// Las escrituras se muestrean siempre, pase lo que pase con la proporción.
    ///
    /// Un escaneo perdido es una investigación, y sin traza esa investigación empieza a ciegas.
    public func shouldSample(isWrite: Bool) -> Bool {
        if isWrite { return true }
        return Double.random(in: 0..<1) < ratio
    }
}
