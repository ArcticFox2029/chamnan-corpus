//
//  OFProofOfDeliveryCoordinator.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Uso interno.
//

import Foundation
import UIKit
import os

/// Orquesta la entrega: firma del destinatario, subida del documento y escaneo de prueba de
/// entrega, en ese orden y sin saltarse ninguno.
///
/// El orden importa porque la firma cuelga de la fila del escaneo. `document-service` valida el
/// `owner_type` contra el vocabulario de `platform.document_owner_types` y, además, llama al
/// servicio dueño para confirmar que el `owner_id` existe antes de confirmar la subida: si
/// intentásemos subir la firma con `owner_type = scan` antes de que `container-registry` haya
/// creado el `scn_`, la subida se rechaza. Así que primero el escaneo, después el documento.
///
/// Aguas abajo esto es lo que desbloquea la facturación: `container-registry` publica
/// `shipment.scanned`, y `billing-service` es consumidor de ese evento pero sólo reacciona cuando
/// `scan_type = 'proof_of_delivery'`.
public actor OFProofOfDeliveryCoordinator {

    private let client: OFAPIClient
    private let queue: OFOfflineQueue
    private let reachability: OFReachabilityMonitor
    private let traceContext: OFTraceContext
    private let configuration: OFEnvironmentConfiguration
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "pod")

    public init(
        client: OFAPIClient,
        queue: OFOfflineQueue,
        reachability: OFReachabilityMonitor,
        traceContext: OFTraceContext,
        configuration: OFEnvironmentConfiguration
    ) {
        self.client = client
        self.queue = queue
        self.reachability = reachability
        self.traceContext = traceContext
        self.configuration = configuration
    }

    /// Lo que el conductor recoge en la pantalla de entrega.
    public struct DeliveryEvidence: Sendable {
        public let shipmentID: OFShipmentID
        public let containerID: OFContainerID
        public let facilityID: OFFacilityID?
        /// Nombre de quien firma, tal y como lo teclea el conductor. Va en las notas del escaneo.
        public let recipientName: String
        /// Firma renderizada a PNG. Ronda los 20 kB, así que se sube incluso en itinerancia.
        public let signaturePNG: Data
        /// Fotos opcionales del estado de la mercancía en el momento de la entrega.
        public let photos: [Data]
        public let position: OFGeoPoint?
        public let occurredAt: Date

        public init(
            shipmentID: OFShipmentID,
            containerID: OFContainerID,
            facilityID: OFFacilityID?,
            recipientName: String,
            signaturePNG: Data,
            photos: [Data],
            position: OFGeoPoint?,
            occurredAt: Date
        ) {
            self.shipmentID = shipmentID
            self.containerID = containerID
            self.facilityID = facilityID
            self.recipientName = recipientName
            self.signaturePNG = signaturePNG
            self.photos = photos
            self.position = position
            self.occurredAt = occurredAt
        }
    }

    public struct Result: Sendable {
        public let scanID: OFScanID?
        public let signatureDocumentID: OFDocumentID?
        /// Cuántas piezas quedaron en la cola. Cero significa que la entrega llegó entera a la
        /// plataforma antes de que el conductor guardase el móvil.
        public let queuedOperations: Int
    }

    // MARK: - Flujo

    /// Cierra la entrega.
    ///
    /// - Throws: `OFProofOfDeliveryError.signatureMissing` si la firma viene vacía, que es lo único
    ///   que no se puede diferir: sin firma no hay prueba de entrega y no tiene sentido registrar
    ///   el escaneo.
    public func complete(_ evidence: DeliveryEvidence) async throws -> Result {

        guard !evidence.signaturePNG.isEmpty else {
            throw OFProofOfDeliveryError.signatureMissing
        }
        guard !evidence.recipientName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw OFProofOfDeliveryError.recipientNameMissing
        }

        return try await traceContext.withNewTrace(named: "pod.complete") {

            var queued = 0

            // 1. El escaneo primero: crea el `scn_` del que cuelga la firma.
            let scanID = try await recordProofScan(evidence, queuedCounter: &queued)

            // 2. La firma, colgando del escaneo. Sin `scn_` no se puede subir con
            //    `owner_type = scan`, así que en modo diferido la subida espera en la cola con la
            //    ruta ya resuelta y sale cuando el escaneo haya entrado.
            var signatureDocumentID: OFDocumentID?
            if let scanID {
                signatureDocumentID = try await upload(
                    contents: evidence.signaturePNG,
                    filename: "signature-\(scanID.rawValue).png",
                    mimeType: "image/png",
                    ownerType: .scan,
                    ownerID: scanID.rawValue,
                    kind: .proofOfDelivery,
                    orderingKey: evidence.shipmentID.rawValue,
                    queuedCounter: &queued
                )
            } else {
                queued += 1
                log.notice("signature upload deferred: the scan has not been accepted yet")
            }

            // 3. Las fotos cuelgan del contenedor, no del escaneo: sirven para reclamaciones de
            //    daños posteriores y tienen que seguir encontrándose por `cnt_` cuando el envío ya
            //    está cerrado.
            for (index, photo) in evidence.photos.enumerated() {
                _ = try await upload(
                    contents: photo,
                    filename: "delivery-\(evidence.containerID.rawValue)-\(index).jpg",
                    mimeType: "image/jpeg",
                    ownerType: .container,
                    ownerID: evidence.containerID.rawValue,
                    kind: .damagePhoto,
                    orderingKey: evidence.shipmentID.rawValue,
                    queuedCounter: &queued
                )
            }

            log.notice("delivery closed for \(evidence.shipmentID.rawValue, privacy: .public), \(queued) operations queued")
            return Result(scanID: scanID, signatureDocumentID: signatureDocumentID, queuedOperations: queued)
        }
    }

    // MARK: - Escaneo de entrega

    private func recordProofScan(
        _ evidence: DeliveryEvidence,
        queuedCounter: inout Int
    ) async throws -> OFScanID? {

        struct ScanRequest: Encodable {
            let shipmentID: String
            let scanType = OFScanType.proofOfDelivery.rawValue
            let facilityID: String?
            let occurredAt: Date
            let position: OFGeoPoint?
            let deviceSerial: String?
            let notes: String?

            enum CodingKeys: String, CodingKey {
                case shipmentID = "shipment_id"
                case scanType = "scan_type"
                case facilityID = "facility_id"
                case occurredAt = "occurred_at"
                case position
                case deviceSerial = "device_serial"
                case notes
            }
        }

        let request = ScanRequest(
            shipmentID: evidence.shipmentID.rawValue,
            facilityID: evidence.facilityID?.rawValue,
            occurredAt: evidence.occurredAt,
            position: evidence.position,
            deviceSerial: OFDeviceInfo.deviceSerial,
            notes: "received by \(evidence.recipientName)"
        )
        let idempotencyKey = "pod:\(evidence.shipmentID.rawValue):\(evidence.containerID.rawValue)"

        guard await reachability.current.isUsable else {
            let body = try Self.encoder.encode(request)
            try await queue.enqueue(
                endpoint: .recordScan,
                path: "/v1/containers/\(evidence.containerID.rawValue)/scans",
                body: body,
                orderingKey: evidence.shipmentID.rawValue,
                traceID: traceContext.currentTraceID(),
                idempotencyKey: idempotencyKey
            )
            queuedCounter += 1
            return nil
        }

        struct ScanResponse: Decodable {
            let scanID: OFScanID
            enum CodingKeys: String, CodingKey { case scanID = "scan_id" }
        }
        let response: ScanResponse = try await client.send(
            .recordScan(evidence.containerID),
            body: request,
            idempotencyKey: idempotencyKey
        )
        return response.scanID
    }

    // MARK: - Subida

    /// Sube un binario a `POST /v1/documents`, o lo encola si no hay red.
    ///
    /// - Returns: el `doc_` asignado, o `nil` si quedó pendiente.
    private func upload(
        contents: Data,
        filename: String,
        mimeType: String,
        ownerType: OFMultipartBody.OwnerType,
        ownerID: String,
        kind: OFMultipartBody.Kind,
        orderingKey: String,
        queuedCounter: inout Int
    ) async throws -> OFDocumentID? {

        let upload = OFMultipartBody.makeDocumentUpload(
            ownerType: ownerType,
            ownerID: ownerID,
            kind: kind,
            regionCode: configuration.regionCode,
            filename: filename,
            mimeType: mimeType,
            contents: contents
        )
        // La clave de idempotencia lleva el hash del contenido. Es coherente con lo que hace el
        // servicio al otro lado: `document-service` deduplica por `sha256`, de modo que reintentar
        // devuelve el mismo `doc_` en vez de guardar el blob dos veces.
        let idempotencyKey = "doc:\(ownerType.rawValue):\(ownerID):\(upload.sha256Hex)"

        // Las fotos esperan a una red barata; la firma no espera a nada.
        let expensive = await reachability.current.isExpensive
        let deferForCost = expensive && kind == .damagePhoto

        guard await reachability.current.isUsable, !deferForCost else {
            try await queue.enqueue(
                endpoint: .uploadDocument,
                path: "/v1/documents",
                body: upload.body,
                contentType: upload.contentType,
                orderingKey: orderingKey,
                traceID: traceContext.currentTraceID(),
                idempotencyKey: idempotencyKey
            )
            queuedCounter += 1
            return nil
        }

        do {
            struct DocumentResponse: Decodable {
                let documentID: OFDocumentID
                enum CodingKeys: String, CodingKey { case documentID = "document_id" }
            }
            let data = try await client.sendRaw(
                .uploadDocument,
                idempotencyKey: idempotencyKey,
                rawBody: upload.body,
                contentType: upload.contentType
            )
            let response = try JSONDecoder().decode(DocumentResponse.self, from: data)
            return response.documentID

        } catch let error as OFServiceError where error.known == .documentDuplicate {
            // No es un fallo. Otro terminal, u otro intento nuestro, ya subió el mismo fichero y
            // el servicio reutilizó el `doc_` existente.
            log.info("document deduplicated by sha256, reusing the existing doc_")
            return nil
        } catch {
            try await queue.enqueue(
                endpoint: .uploadDocument,
                path: "/v1/documents",
                body: upload.body,
                contentType: upload.contentType,
                orderingKey: orderingKey,
                traceID: traceContext.currentTraceID(),
                idempotencyKey: idempotencyKey
            )
            queuedCounter += 1
            return nil
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(OFRFC3339.string(from: date))
        }
        return encoder
    }()
}

/// Fallos de la entrega que se detectan antes de tocar la red.
public enum OFProofOfDeliveryError: Error, Sendable {
    case signatureMissing
    case recipientNameMissing
}
