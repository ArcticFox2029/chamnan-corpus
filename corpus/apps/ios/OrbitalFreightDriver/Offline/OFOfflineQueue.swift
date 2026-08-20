//
//  OFOfflineQueue.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation
import SQLite3
import os

/// Cola persistente de escrituras pendientes: lo que el conductor hace sin cobertura y la
/// plataforma todavía no sabe.
///
/// Es el equivalente en el terminal de la bandeja de salida transaccional del backend: la acción se
/// da por hecha en local y se publica después, con la diferencia de que aquí "después" puede ser
/// ocho horas más tarde, al bajar de un puerto de montaña. Cada entrada nace con su clave de
/// idempotencia y con la traza del gesto original, y las dos se conservan intactas durante todos
/// los reintentos; ésa es la única razón por la que un escaneo reintentado no acaba siendo dos filas
/// en `freight.shipment_scan_events`.
public actor OFOfflineQueue {

    /// Operación pendiente, ya serializada.
    public struct PendingOperation: Sendable, Identifiable {
        public let id: Int64
        public let endpointKey: OFQueuedEndpoint
        public let path: String
        public let method: String
        public let bodyJSON: Data
        public let contentType: String
        /// Se genera una vez, al encolar, y no cambia nunca más.
        public let idempotencyKey: String
        /// Traza del gesto que originó la operación, no la del momento del envío.
        public let traceID: String
        /// Clave de orden: las operaciones del mismo envío salen en el orden en que ocurrieron.
        public let orderingKey: String
        public let enqueuedAt: Date
        public let attempts: Int
        public let nextAttemptAt: Date
        public let lastError: String?
    }

    /// Endpoints que la cola sabe reproducir. Es un conjunto pequeño a propósito: sólo entran
    /// escrituras cuyo reintento sea seguro y cuya semántica de idempotencia esté clara.
    public enum OFQueuedEndpoint: String, Sendable {
        /// `POST /v1/containers/{container_id}/scans` en `container-registry`.
        case recordScan = "record_scan"
        /// `POST /v1/drivers/{driver_id}/hours-of-service` en `fleet-service`.
        case hoursOfService = "hours_of_service"
        /// `POST /v1/documents` en `document-service` (multiparte, cuerpo en disco).
        case uploadDocument = "upload_document"
        /// `POST /v1/alerts/{alert_id}/acknowledge` en `telemetry-ingest`.
        case acknowledgeAlert = "acknowledge_alert"
        /// `PATCH /v1/shipments/{shipment_id}/status` en `container-registry`.
        case updateShipmentStatus = "update_shipment_status"

        var service: OFService {
            switch self {
            case .recordScan, .updateShipmentStatus: return .containerRegistry
            case .hoursOfService: return .fleet
            case .uploadDocument: return .document
            case .acknowledgeAlert: return .telemetryIngest
            }
        }
    }

    private var database: OpaquePointer?
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "offline-queue")

    /// Tope de intentos antes de apartar la operación.
    ///
    /// Ocho, igual que la política de reintentos de los consumidores de Kafka del backend. No es
    /// casualidad ni coincidencia estética: cuando una operación agota los ocho intentos el
    /// diagnóstico se parece tanto al de un mensaje envenenado que conviene que el número con el
    /// que se habla sea el mismo.
    public static let maximumAttempts = 8

    public init(databaseURL: URL) throws {
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw OFQueueError.cannotOpenDatabase(databaseURL)
        }
        // WAL para que el drenaje en segundo plano no bloquee al escáner en primer plano, que es
        // el escenario habitual: el conductor sigue leyendo precintos mientras la cola se vacía.
        execute("PRAGMA journal_mode = WAL;")
        execute("PRAGMA synchronous = FULL;")
        try migrate()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    // MARK: - Esquema local

    private func migrate() throws {
        execute("""
        CREATE TABLE IF NOT EXISTS pending_operations (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            endpoint_key    TEXT    NOT NULL,
            path            TEXT    NOT NULL,
            method          TEXT    NOT NULL,
            body            BLOB    NOT NULL,
            content_type    TEXT    NOT NULL,
            idempotency_key TEXT    NOT NULL UNIQUE,
            trace_id        TEXT    NOT NULL,
            ordering_key    TEXT    NOT NULL,
            enqueued_at     REAL    NOT NULL,
            attempts        INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL    NOT NULL,
            last_error      TEXT,
            parked          INTEGER NOT NULL DEFAULT 0
        );
        """)
        // El índice cubre exactamente la consulta del drenador: lo que toca ahora, en orden.
        execute("""
        CREATE INDEX IF NOT EXISTS pending_ready_idx
            ON pending_operations (parked, next_attempt_at, ordering_key, id);
        """)
        // La clave de idempotencia es única de verdad en el disco del terminal. Si dos gestos
        // generasen la misma, preferimos un fallo de inserción visible a dos peticiones que el
        // servidor colapsa silenciosamente en una.
    }

    // MARK: - Encolado

    /// Mete una operación en la cola y devuelve su identificador local.
    ///
    /// - Parameters:
    ///   - endpoint: cuál de las cinco escrituras reproducibles es.
    ///   - path: ruta ya resuelta, con los identificadores sustituidos.
    ///   - body: cuerpo serializado.
    ///   - orderingKey: normalmente el `shp_` del envío. La plataforma sólo garantiza orden por
    ///     clave de partición, y la del terminal es la misma idea: los escaneos de un envío salen
    ///     en secuencia, los de envíos distintos pueden adelantarse entre sí sin problema.
    ///   - traceID: traza del gesto, que se conserva hasta el envío efectivo.
    @discardableResult
    public func enqueue(
        endpoint: OFQueuedEndpoint,
        path: String,
        method: String = "POST",
        body: Data,
        contentType: String = "application/json",
        orderingKey: String,
        traceID: String,
        idempotencyKey: String = UUID().uuidString
    ) throws -> Int64 {

        let sql = """
        INSERT INTO pending_operations
            (endpoint_key, path, method, body, content_type, idempotency_key,
             trace_id, ordering_key, enqueued_at, next_attempt_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OFQueueError.statementFailed(lastMessage)
        }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        bindText(statement, 1, endpoint.rawValue)
        bindText(statement, 2, path)
        bindText(statement, 3, method)
        body.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 4, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        bindText(statement, 5, contentType)
        bindText(statement, 6, idempotencyKey)
        bindText(statement, 7, traceID)
        bindText(statement, 8, orderingKey)
        sqlite3_bind_double(statement, 9, now)
        sqlite3_bind_double(statement, 10, now)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw OFQueueError.statementFailed(lastMessage)
        }
        let identifier = sqlite3_last_insert_rowid(database)
        log.info("enqueued \(endpoint.rawValue, privacy: .public) id=\(identifier) key=\(orderingKey, privacy: .public)")
        return identifier
    }

    // MARK: - Drenaje

    /// Devuelve el siguiente lote listo para enviar, respetando el orden por clave.
    ///
    /// Sólo sale una operación por `ordering_key` en cada lote. Si el escaneo de carga de un envío
    /// está esperando reintento, el de descarga del mismo envío no puede adelantarlo: llegarían
    /// desordenados a `container-registry` y el rastro contaría una historia falsa.
    public func nextBatch(limit: Int = 10) throws -> [PendingOperation] {
        let sql = """
        SELECT id, endpoint_key, path, method, body, content_type, idempotency_key,
               trace_id, ordering_key, enqueued_at, attempts, next_attempt_at, last_error
        FROM pending_operations p
        WHERE parked = 0
          AND next_attempt_at <= ?
          AND id = (SELECT MIN(q.id) FROM pending_operations q
                    WHERE q.ordering_key = p.ordering_key AND q.parked = 0)
        ORDER BY next_attempt_at ASC, id ASC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OFQueueError.statementFailed(lastMessage)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var operations: [PendingOperation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let endpoint = OFQueuedEndpoint(rawValue: column(statement, 1)) else { continue }
            let blobPointer = sqlite3_column_blob(statement, 4)
            let blobLength = Int(sqlite3_column_bytes(statement, 4))
            let body = blobPointer.map { Data(bytes: $0, count: blobLength) } ?? Data()

            operations.append(PendingOperation(
                id: sqlite3_column_int64(statement, 0),
                endpointKey: endpoint,
                path: column(statement, 2),
                method: column(statement, 3),
                bodyJSON: body,
                contentType: column(statement, 5),
                idempotencyKey: column(statement, 6),
                traceID: column(statement, 7),
                orderingKey: column(statement, 8),
                enqueuedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                attempts: Int(sqlite3_column_int(statement, 10)),
                nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                lastError: sqlite3_column_text(statement, 12) == nil ? nil : column(statement, 12)
            ))
        }
        return operations
    }

    /// Borra la operación tras un envío aceptado.
    public func complete(_ identifier: Int64) {
        execute("DELETE FROM pending_operations WHERE id = \(identifier);")
    }

    /// Programa el siguiente intento con retroceso exponencial.
    ///
    /// Arranca en 500 ms y dobla, con un tope de cinco minutos y un jitter de hasta el 20 %. El
    /// tope importa más de lo que parece: sin él, un terminal que pasa la noche en un depósito sin
    /// cobertura despertaba con esperas de horas y el conductor empezaba el turno con la cola
    /// todavía llena.
    public func scheduleRetry(_ identifier: Int64, attempts: Int, reason: String) {
        let nextAttempts = attempts + 1
        if nextAttempts >= Self.maximumAttempts {
            park(identifier, reason: reason)
            return
        }
        let base = min(0.5 * pow(2, Double(attempts)), 300)
        let jitter = Double.random(in: 0...(base * 0.2))
        let nextAt = Date().timeIntervalSince1970 + base + jitter

        let sql = """
        UPDATE pending_operations
        SET attempts = ?, next_attempt_at = ?, last_error = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(nextAttempts))
        sqlite3_bind_double(statement, 2, nextAt)
        bindText(statement, 3, reason)
        sqlite3_bind_int64(statement, 4, identifier)
        sqlite3_step(statement)
    }

    /// Aparta una operación que ya no se va a reintentar sola.
    ///
    /// No se borra: queda visible en la pantalla de diagnóstico para que el conductor pueda
    /// enseñársela a la central, y para que soporte pueda leer el `trace_id` y buscarlo en el
    /// colector. Es el análogo local de la cola de mensajes envenenados del backend.
    public func park(_ identifier: Int64, reason: String) {
        let sql = "UPDATE pending_operations SET parked = 1, last_error = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, reason)
        sqlite3_bind_int64(statement, 2, identifier)
        sqlite3_step(statement)
        log.fault("parked operation \(identifier) after exhausting retries: \(reason, privacy: .public)")
    }

    /// Cuántas operaciones esperan, para el indicador de la barra superior.
    public func pendingCount() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT COUNT(*) FROM pending_operations WHERE parked = 0;", -1, &statement, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Purga las claves de idempotencia ya usadas y más viejas que la ventana del servidor.
    ///
    /// El backend conserva la clave 24 horas. Pasado ese plazo reenviar la misma clave ya no
    /// deduplica nada, así que una operación apartada más antigua que eso no debe reintentarse
    /// jamás de forma automática: se reenvía a mano, con clave nueva, y asumiendo el duplicado.
    public func idempotencyWindowExpired(for operation: PendingOperation) -> Bool {
        Date().timeIntervalSince(operation.enqueuedAt) > 24 * 3600
    }

    // MARK: - Utilidades SQLite

    private var lastMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private func execute(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(database, sql, nil, nil, &errorMessage) != SQLITE_OK, let errorMessage {
            log.error("sqlite: \(String(cString: errorMessage), privacy: .public)")
            sqlite3_free(errorMessage)
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}

/// Fallos propios del almacén local.
public enum OFQueueError: Error, Sendable {
    case cannotOpenDatabase(URL)
    case statementFailed(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
