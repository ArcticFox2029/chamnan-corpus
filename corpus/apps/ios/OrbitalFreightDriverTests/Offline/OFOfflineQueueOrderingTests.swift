import XCTest
@testable import OrbitalFreightDriver

//
//  OFOfflineQueueOrderingTests.swift
//  OrbitalFreightDriverTests
//

/// Pruebas de las dos propiedades de la cola sin conexión de las que depende que el rastro de un
/// envío sea cierto: el orden por envío y la conservación de la clave de idempotencia.
///
/// Se ejecutan sobre una base SQLite temporal, sin red y sin dobles de `OFAPIClient`: lo que se
/// mide es el comportamiento del almacén, no el del envío. El resto del drenaje ya está cubierto en
/// las pruebas de `OFQueueDrainer`.
final class OFOfflineQueueOrderingTests: XCTestCase {

    private var databaseURL: URL!
    private var queue: OFOfflineQueue!

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("of-queue-\(UUID().uuidString).sqlite")
        queue = try OFOfflineQueue(databaseURL: databaseURL)
    }

    override func tearDown() async throws {
        queue = nil
        try? FileManager.default.removeItem(at: databaseURL)
        try await super.tearDown()
    }

    // MARK: - Orden

    /// Dos escrituras del mismo envío no pueden salir en el mismo lote.
    ///
    /// Si la carga y la descarga de un mismo envío llegan juntas a `container-registry`, el orden
    /// de escritura lo decide la concurrencia del servidor y el rastro de
    /// `freight.shipment_scan_events` puede acabar contando que el contenedor se descargó antes de
    /// cargarse. La plataforma sólo garantiza orden dentro de una clave de partición y aquí la
    /// clave es el `shp_`.
    func testOneOperationPerOrderingKeyInABatch() async throws {
        let shipment = "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC"

        _ = try await queue.enqueue(
            endpoint: .recordScan,
            path: "/v1/containers/cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC/scans",
            body: Data(#"{"scan_type":"load"}"#.utf8),
            orderingKey: shipment,
            traceID: String(repeating: "a", count: 32)
        )
        _ = try await queue.enqueue(
            endpoint: .recordScan,
            path: "/v1/containers/cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC/scans",
            body: Data(#"{"scan_type":"unload"}"#.utf8),
            orderingKey: shipment,
            traceID: String(repeating: "b", count: 32)
        )

        let batch = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(batch.count, 1, "el segundo escaneo del mismo envío tiene que esperar")
        XCTAssertEqual(batch.first?.orderingKey, shipment)
    }

    /// Envíos distintos sí pueden adelantarse entre sí.
    ///
    /// Es lo que salva el turno del conductor que sale de un puerto con cuatro entregas
    /// acumuladas: la que falla no bloquea a las otras tres.
    func testDifferentShipmentsGoOutInParallel() async throws {
        for suffix in ["AA", "BB", "CC"] {
            _ = try await queue.enqueue(
                endpoint: .recordScan,
                path: "/v1/containers/cnt_01J8ZK4T9QW3RM7XN2VB6HD5\(suffix)/scans",
                body: Data(#"{"scan_type":"gate_out"}"#.utf8),
                orderingKey: "shp_01J8ZK4T9QW3RM7XN2VB6HD5\(suffix)",
                traceID: String(repeating: "c", count: 32)
            )
        }

        let batch = try await queue.nextBatch(limit: 10)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(Set(batch.map(\.orderingKey)).count, 3)
    }

    // MARK: - Idempotencia

    /// La clave de idempotencia nace al encolar y sobrevive intacta a los reintentos.
    ///
    /// Es lo único que impide que un escaneo enviado dos veces tras un túnel se convierta en dos
    /// filas de `freight.shipment_scan_events` y, por debajo, en dos `shipment.scanned` que
    /// `reconciliation-service` acabaría contando como una discrepancia.
    func testIdempotencyKeySurvivesRetries() async throws {
        let identifier = try await queue.enqueue(
            endpoint: .acknowledgeAlert,
            path: "/v1/alerts/alr_01J8ZK4T9QW3RM7XN2VB6HD5PC/acknowledge",
            body: Data("{}".utf8),
            orderingKey: "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            traceID: String(repeating: "d", count: 32)
        )

        let original = try await queue.nextBatch(limit: 1).first
        XCTAssertEqual(original?.id, identifier)

        await queue.scheduleRetry(identifier, attempts: 0, reason: "503 from telemetry-ingest")
        let afterRetry = try await firstOperationIgnoringSchedule()

        XCTAssertEqual(original?.idempotencyKey, afterRetry?.idempotencyKey)
        XCTAssertEqual(original?.traceID, afterRetry?.traceID, "la traza es la del gesto, no la del envío")
        XCTAssertEqual(afterRetry?.attempts, 1)
        XCTAssertEqual(afterRetry?.lastError, "503 from telemetry-ingest")
    }

    /// Pasadas veinticuatro horas la clave ya no vale y reintentar deja de ser seguro.
    ///
    /// El servidor guarda las claves de idempotencia veinticuatro horas. Más allá de eso el
    /// reintento no se deduplica y crearía un duplicado real, así que la operación se aparta y
    /// aparece en la pantalla de diagnóstico para que alguien decida.
    func testOperationsPastTheIdempotencyWindowAreNotReplayable() async throws {
        let stale = OFOfflineQueue.PendingOperation(
            id: 1,
            endpointKey: .recordScan,
            path: "/v1/containers/cnt_01J8ZK4T9QW3RM7XN2VB6HD5PC/scans",
            method: "POST",
            bodyJSON: Data("{}".utf8),
            contentType: "application/json",
            idempotencyKey: UUID().uuidString,
            traceID: String(repeating: "e", count: 32),
            orderingKey: "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            enqueuedAt: Date().addingTimeInterval(-26 * 3600),
            attempts: 3,
            nextAttemptAt: Date(),
            lastError: nil
        )

        let expired = await queue.idempotencyWindowExpired(for: stale)
        XCTAssertTrue(expired)
    }

    func testParkedOperationsLeaveTheBatch() async throws {
        let identifier = try await queue.enqueue(
            endpoint: .uploadDocument,
            path: "/v1/documents",
            body: Data("{}".utf8),
            orderingKey: "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
            traceID: String(repeating: "f", count: 32)
        )

        await queue.park(identifier, reason: "415 unsupported mime type")

        let batch = try await queue.nextBatch(limit: 10)
        XCTAssertTrue(batch.isEmpty)
        // Apartada no es borrada, pero tampoco cuenta en el indicador de la barra superior: ese
        // número le promete al conductor que la cola se va a vaciar sola, y una operación apartada
        // ya no se va a ir sin que alguien la mire. Vive en la pantalla de diagnóstico.
        let pending = await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Utilidades

    private func firstOperationIgnoringSchedule() async throws -> OFOfflineQueue.PendingOperation? {
        // `nextBatch` respeta el retardo del reintento, así que aquí se espera lo justo para que
        // venza la primera espera exponencial: 500 ms más un jitter de hasta el 20 %.
        try await Task.sleep(nanoseconds: 800_000_000)
        return try await queue.nextBatch(limit: 1).first
    }
}
