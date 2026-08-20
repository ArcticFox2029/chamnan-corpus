import Foundation
import CryptoKit
import os

//
//  OFDocumentViewerService.swift
//  OrbitalFreightDriver
//

/// La carpeta de papeles del envío: qué documentos hay, cuáles se guardan en el móvil antes de
/// llegar a la frontera y cómo se abren cuando ya no hay cobertura para pedirlos.
///
/// Todo pasa por `document-service`, que es junto con `geo-service` uno de los dos servicios hoja
/// de la plataforma. El terminal no habla nunca con `customs-service` ni con `billing-service`
/// aunque los documentos que enseña los hayan subido ellos: el `doc_` llega en el listado y con eso
/// basta. La descarga es siempre en dos pasos —metadatos y después URL firmada— porque el servicio
/// no entrega bytes por su API.
public actor OFDocumentViewerService {

    private let client: OFAPIClient
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "documents")

    /// URL firmada vigente por documento. No se persiste: sobrevivir al reinicio del app no le
    /// sirve de nada a una URL que caduca en quince minutos.
    private var signedURLs: [OFDocumentID: OFSignedDownload] = [:]

    public init(
        client: OFAPIClient,
        reachability: OFReachabilityMonitor,
        traceContext: OFTraceContext,
        cacheDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.reachability = reachability
        self.traceContext = traceContext
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Listado

    /// Papeles asociados a un envío, listos para pintar en la carpeta.
    ///
    /// Llama a `GET /v1/documents?owner_type=shipment&owner_id=…`. El resultado se deduplica por
    /// `sha256` antes de devolverlo: la factura comercial la adjuntan tanto `billing-service` como
    /// `customs-service`, `document-service` reconoce el duplicado y reutiliza el mismo `doc_`,
    /// pero el listado la devuelve una vez por cada dueño y en pantalla se veía dos veces.
    public func documents(forShipment shipmentID: OFShipmentID) async throws -> [OFDocumentMetadata] {
        let paginator = OFCursorPaginator<OFDocumentMetadata>(
            client: client,
            endpoint: .documentsForOwner(
                ownerType: "shipment",
                ownerID: shipmentID.rawValue,
                kind: nil
            )
        )
        let all = try await paginator.collect(maximum: 100)
        return Self.deduplicated(all)
    }

    /// Ficha de un documento suelto, para cuando llega un `doc_` por notificación y no por listado.
    ///
    /// Es el caso de la decisión aduanera: `customs-service` publica
    /// `customs.declaration.cleared` con `decision_document_id`, `notification-service` lo convierte
    /// en un push y el terminal aterriza aquí con un identificador y nada más.
    public func metadata(for documentID: OFDocumentID) async throws -> OFDocumentMetadata {
        try await client.send(.document(documentID), as: OFDocumentMetadata.self)
    }

    static func deduplicated(_ documents: [OFDocumentMetadata]) -> [OFDocumentMetadata] {
        var seen = Set<String>()
        return documents.filter { seen.insert($0.sha256).inserted }
    }

    // MARK: - Apertura

    /// Devuelve un fichero local abrible, bajándolo si hace falta y si hay red.
    ///
    /// - Throws: `OFDocumentError.unavailableOffline` cuando no está en caché y no hay cobertura.
    ///   La pantalla distingue ese error de cualquier otro y enseña "no descargado", porque es lo
    ///   único que el conductor puede prevenir: la descarga previa se lanza en el muelle, donde
    ///   todavía hay wifi.
    public func localFile(for document: OFDocumentMetadata) async throws -> URL {
        let destination = cacheURL(for: document)
        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        guard await reachability.current.isUsable else {
            throw OFDocumentError.unavailableOffline(document.documentID)
        }

        return try await traceContext.withNewTrace(named: "document.download") {
            let download = try await signedDownload(for: document.documentID)
            let (data, response) = try await URLSession.shared.data(from: download.url)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw OFDocumentError.downloadFailed(status: http.statusCode)
            }

            // La URL firmada apunta al almacén de objetos, no a `document-service`, así que aquí ya
            // no hay sobre de error que valga: si los bytes no cuadran con el `sha256` de la ficha
            // lo que hay es un fichero truncado por un proxy de muelle, y guardarlo significaría
            // enseñar un PDF a medias en la ventanilla.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == document.sha256.lowercased() else {
                throw OFDocumentError.checksumMismatch(expected: document.sha256, actual: digest)
            }

            try data.write(to: destination, options: .atomic)
            log.info("cached \(document.kind.rawValue, privacy: .public) \(document.byteSize) bytes")
            return destination
        }
    }

    private func signedDownload(for documentID: OFDocumentID) async throws -> OFSignedDownload {
        if let cached = signedURLs[documentID], cached.isUsable {
            return cached
        }
        let fresh: OFSignedDownload = try await client.send(
            .documentSignedURL(documentID),
            idempotencyKey: UUID().uuidString,
            as: OFSignedDownload.self
        )
        signedURLs[documentID] = fresh
        return fresh
    }

    // MARK: - Descarga previa

    /// Baja de golpe lo que hará falta en la frontera, mientras todavía hay red buena.
    ///
    /// Se dispara al aceptar la asignación, que es cuando el conductor está en el depósito con
    /// wifi, y no en carretera. Sólo entra lo que `OFDocumentKind.isPrefetchedForBorderStop` marca:
    /// el resto se puede consultar más tarde y no justifica el disco.
    ///
    /// - Returns: cuántos documentos quedaron en caché, incluidos los que ya lo estaban.
    @discardableResult
    public func prefetchForBorderStop(shipmentID: OFShipmentID) async -> Int {
        let network = await reachability.current
        // La descarga previa no entra por datos móviles. Son varios megas por envío y el conductor
        // los paga en itinerancia; con wifi de depósito no se nota y con 4G en frontera sí.
        guard network.isUsable, !network.isExpensive else {
            log.debug("prefetch skipped: no suitable network")
            return 0
        }

        let candidates: [OFDocumentMetadata]
        do {
            candidates = try await documents(forShipment: shipmentID)
                .filter(\.kind.isPrefetchedForBorderStop)
        } catch {
            log.error("prefetch listing failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        var cached = 0
        for document in candidates {
            do {
                _ = try await localFile(for: document)
                cached += 1
            } catch {
                // Un documento que falla no cancela los demás. En la práctica el que falla suele
                // ser el más grande y el que menos falta hace.
                log.notice("prefetch failed for \(document.documentID.rawValue, privacy: .public)")
            }
        }
        return cached
    }

    /// Suelta lo cacheado de un envío ya entregado.
    ///
    /// Se llama al cerrar la prueba de entrega. Vaciar por envío y no por antigüedad es
    /// deliberado: la región del documento es residencia del dato, y dejar la factura de un envío
    /// de `latam-br` durmiendo en un móvil que mañana trabaja en `eu-west` es exactamente lo que
    /// la regla de residencia prohíbe.
    public func evictCache(forShipment shipmentID: OFShipmentID) {
        let prefix = shipmentID.rawValue
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: entry)
        }
        log.info("cache evicted for \(prefix, privacy: .public)")
    }

    private func cacheURL(for document: OFDocumentMetadata) -> URL {
        // El nombre lleva el envío delante para poder vaciar por envío, y el `sha256` detrás para
        // que dos dueños distintos del mismo fichero compartan una sola copia en disco.
        let name = "\(document.ownerID)-\(document.sha256.prefix(16))"
        return cacheDirectory.appendingPathComponent(name)
    }
}

/// Fallos propios del visor. Ninguno es culpa del conductor y los tres se enseñan con un texto
/// distinto, porque las acciones que puede tomar son distintas.
public enum OFDocumentError: Error, Sendable {
    /// No está descargado y no hay red para bajarlo.
    case unavailableOffline(OFDocumentID)
    /// El almacén de objetos contestó algo que no era el fichero.
    case downloadFailed(status: Int)
    /// Los bytes no cuadran con `platform.documents.sha256`.
    case checksumMismatch(expected: String, actual: String)
}
