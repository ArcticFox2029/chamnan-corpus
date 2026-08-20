//
//  OFMultipartBody.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Uso interno.
//

import Foundation
import CryptoKit

/// Construye el cuerpo `multipart/form-data` de `POST /v1/documents`, que es la única forma de
/// meter bytes en la plataforma desde el terminal.
///
/// Lo usa la firma de entrega y la foto de daños. Calcula el `sha256` del contenido antes de
/// enviarlo porque `document-service` deduplica por ese hash: si el conductor pulsa "enviar" dos
/// veces, o si la cola reintenta después de un túnel, la segunda subida devuelve el `doc_` que ya
/// existía en vez de guardar el blob otra vez.
public struct OFMultipartBody {

    /// Frontera aleatoria por cuerpo. Reutilizar una constante entre subidas nos mordió una vez:
    /// un proxy intermedio cacheó la petición entera y la foto de un envío apareció colgando de
    /// otro.
    public let boundary: String

    private var data = Data()

    public init() {
        self.boundary = "of-driver-\(UUID().uuidString.lowercased())"
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Añade un campo de texto.
    public mutating func addField(name: String, value: String) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }

    /// Añade el fichero.
    ///
    /// - Parameters:
    ///   - name: nombre del campo, siempre `file` en este endpoint.
    ///   - filename: nombre visible. `document-service` lo ignora y genera su propio
    ///     `storage_key` prefijado por región, pero queda en los logs y ayuda a rastrear.
    ///   - mimeType: acaba tal cual en `platform.documents.mime_type`.
    public mutating func addFile(name: String, filename: String, mimeType: String, contents: Data) {
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        data.append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(contents)
        data.append("\r\n")
    }

    /// Cierra el cuerpo y lo devuelve.
    public mutating func finalize() -> Data {
        data.append("--\(boundary)--\r\n")
        return data
    }

    /// Metadatos que acompañan al fichero, con los nombres de columna de `platform.documents`.
    ///
    /// `owner_type` no es texto libre: `document-service` lo valida contra el vocabulario de
    /// `platform.document_owner_types` y además llama al servicio dueño para confirmar que el
    /// `owner_id` existe antes de confirmar la subida. Desde el terminal sólo usamos tres de los
    /// seis valores del vocabulario.
    public enum OwnerType: String, Sendable {
        case shipment
        case container
        /// Para la firma de entrega, que cuelga de la fila de `freight.shipment_scan_events`.
        case scan
    }

    /// Valores de `platform.documents.kind` que el terminal produce.
    public enum Kind: String, Sendable {
        case proofOfDelivery = "proof_of_delivery"
        case damagePhoto = "damage_photo"
    }

    /// Prepara el cuerpo completo de una subida.
    ///
    /// - Returns: los bytes, el `Content-Type` con su frontera y el `sha256` en hexadecimal, que
    ///   el llamante guarda para poder reconocer la deduplicación al reintentar.
    public static func makeDocumentUpload(
        ownerType: OwnerType,
        ownerID: String,
        kind: Kind,
        regionCode: OFRegionCode,
        filename: String,
        mimeType: String,
        contents: Data
    ) -> (body: Data, contentType: String, sha256Hex: String) {

        var builder = OFMultipartBody()
        builder.addField(name: "owner_type", value: ownerType.rawValue)
        builder.addField(name: "owner_id", value: ownerID)
        builder.addField(name: "kind", value: kind.rawValue)
        // La región del documento es la del envío al que pertenece, no la del terminal. Un
        // conductor que cruza de `eu-central` a `eu-west` no cambia la residencia de la foto que
        // hizo hace dos horas.
        builder.addField(name: "region_code", value: regionCode.rawValue)
        builder.addField(name: "mime_type", value: mimeType)
        builder.addFile(name: "file", filename: filename, mimeType: mimeType, contents: contents)

        let digest = SHA256.hash(data: contents)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return (builder.finalize(), builder.contentType, hex)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let encoded = string.data(using: .utf8) { append(encoded) }
    }
}
