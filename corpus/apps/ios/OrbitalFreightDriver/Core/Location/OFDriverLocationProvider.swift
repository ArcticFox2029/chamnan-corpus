//
//  OFDriverLocationProvider.swift
//  OrbitalFreightDriver
//

import CoreLocation
import Foundation
import os

/// Única fuente de posición del terminal: la que rellena `position` en cada escaneo y en cada
/// cambio de jornada.
///
/// El app no lleva rastro de recorrido ni lo sube a ninguna parte. La traza de un envío la produce
/// el sensor del contenedor y entra por `telemetry-ingest`; lo que aporta el móvil es un punto
/// puntual, atado al gesto del conductor, que acaba en `freight.shipment_scan_events.position` y
/// que `container-registry` usa para resolver la instalación contra `geo.v1.GeoService/PointInFence`.
/// Esa diferencia es la que justifica todo lo que hay aquí: si el punto no vale, es mejor no
/// mandarlo que mandarlo malo.
public final class OFDriverLocationProvider: NSObject, OFLocationProvider, @unchecked Sendable {

    /// Precisión por debajo de la cual un punto no sirve para nada.
    ///
    /// Las vallas de `geo.geofences` traen un `buffer_m` de 50 metros por defecto para absorber el
    /// error de GPS. Una fijación con 300 metros de incertidumbre se cuela dentro de ese margen y
    /// hace que `PointInFence` diga que sí en una instalación en la que el conductor no está — y
    /// eso ya no lo corrige nadie aguas abajo, porque el escaneo queda atribuido a la instalación
    /// equivocada en el rastro.
    public static let maximumAcceptableAccuracyM: CLLocationDistance = 150

    /// Antigüedad máxima de una fijación reutilizable.
    ///
    /// Noventa segundos son unos dos kilómetros de autopista. Más allá de eso el punto ya no
    /// describe dónde ocurrió el gesto, y para el rastro es peor un punto plausible y falso que un
    /// nulo honesto.
    public static let maximumFixAgeSeconds: TimeInterval = 90

    private let manager: CLLocationManager
    private let lock = NSLock()
    private var lastFix: CLLocation?
    private var precisionRequests = 0
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "location")

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = true
        manager.activityType = .automotiveNavigation
        // Fuera de una sesión de escaneo el terminal vive en cambios significativos. Un turno son
        // doce horas y el conductor no puede quedarse sin batería a las seis, así que el GPS fino
        // sólo se enciende mientras hay una pantalla que lo necesita.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
    }

    // MARK: - Ciclo de vida

    /// Arranca el seguimiento de bajo consumo. Se llama al abrir el turno, no al abrir el app.
    public func startShiftTracking() {
        guard CLLocationManager.locationServicesEnabled() else {
            log.notice("location services disabled; scans will carry a null position")
            return
        }
        manager.requestWhenInUseAuthorization()
        manager.startMonitoringSignificantLocationChanges()
    }

    public func stopShiftTracking() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopUpdatingLocation()
        lock.withLock { precisionRequests = 0 }
    }

    /// Sube la precisión mientras dura una tarea concreta y la baja al terminar.
    ///
    /// El contador existe porque las pantallas se solapan más de lo que parece: el conductor abre
    /// la cámara, y desde ella salta a la firma de entrega sin cerrar la anterior. Con un simple
    /// booleano, la primera que terminaba apagaba el GPS de la que seguía abierta y la firma se
    /// guardaba sin punto.
    public func withPreciseFix<T>(_ operation: () async throws -> T) async rethrows -> T {
        beginPrecision()
        defer { endPrecision() }
        return try await operation()
    }

    private func beginPrecision() {
        lock.lock()
        precisionRequests += 1
        let isFirst = precisionRequests == 1
        lock.unlock()
        guard isFirst else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
    }

    private func endPrecision() {
        lock.lock()
        precisionRequests = max(0, precisionRequests - 1)
        let isLast = precisionRequests == 0
        lock.unlock()
        guard isLast else { return }
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 250
    }

    // MARK: - OFLocationProvider

    public func currentPoint() -> OFGeoPoint? {
        lock.lock()
        let fix = lastFix
        lock.unlock()

        guard let fix else { return nil }
        guard Self.isUsable(fix, now: Date()) else {
            log.debug("fix rejected: accuracy=\(fix.horizontalAccuracy) age=\(-fix.timestamp.timeIntervalSinceNow)")
            return nil
        }
        return OFGeoPoint(fix.coordinate)
    }

    /// Punto con espera acotada, para cuando la pantalla puede permitirse un par de segundos.
    ///
    /// La usa la prueba de entrega, que sólo ocurre una vez por envío y donde perder el punto
    /// obliga al administrativo a justificar después dónde se firmó. El escáner de puerta, en
    /// cambio, llama a `currentPoint()` directamente: allí la espera se nota y el conductor tiene
    /// otro contenedor detrás.
    public func awaitFix(timeout: TimeInterval = 4) async -> OFGeoPoint? {
        if let point = currentPoint() { return point }
        beginPrecision()
        defer { endPrecision() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let point = currentPoint() { return point }
        }
        log.notice("no usable fix within \(timeout, format: .fixed(precision: 1))s; position stays null")
        return nil
    }

    static func isUsable(_ fix: CLLocation, now: Date) -> Bool {
        guard fix.horizontalAccuracy >= 0 else { return false }
        guard fix.horizontalAccuracy <= maximumAcceptableAccuracyM else { return false }
        return now.timeIntervalSince(fix.timestamp) <= maximumFixAgeSeconds
    }
}

extension OFDriverLocationProvider: CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        lock.withLock {
            // Se guarda aunque no pase el filtro de calidad: `currentPoint()` vuelve a decidir con
            // la edad ya contada, y guardar una fijación mala no es peor que no guardar nada.
            lastFix = newest
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `kCLErrorLocationUnknown` es transitorio y llega a puñados dentro de un almacén con
        // techo metálico. No se registra como fallo ni se le enseña nada al conductor: el escaneo
        // sale con `position` a nulo, que es un caso previsto en el contrato.
        if (error as? CLError)?.code == .locationUnknown { return }
        log.error("location manager failed: \(error.localizedDescription, privacy: .public)")
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startMonitoringSignificantLocationChanges()
        case .denied, .restricted:
            // Denegado no bloquea el turno. Se pierde el punto del escaneo y nada más; quien
            // decide si eso es aceptable es el jefe de flota, no el app.
            lock.withLock { lastFix = nil }
            log.notice("location authorisation denied; scans continue without position")
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}
