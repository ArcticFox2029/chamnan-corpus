//
//  OFDocumentModels.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//

import Foundation

/// Tipos de `platform.documents` vistos desde el terminal: la ficha de metadatos y el vocabulario
/// de `kind`, sin los bytes por ningún lado.
///
/// `document-service` no devuelve nunca el contenido en la misma respuesta que los metadatos; hay
/// que pedir después una URL firmada de quince minutos. Modelar las dos cosas por separado, y no
/// como un solo objeto con un `data` opcional, es lo que impide que una pantalla se descargue sin
/// querer un juego de papeles de veinte megas por una conexión de muelle.

/// Ficha de un documento. Espejo de las columnas de `platform.documents` que el app necesita.
public struct OFDocumentMetadata: Codable, Hashable, Sendable, Identifiable {

    public let documentID: OFDocumentID
    /// Uno de los seis valores de `platform.document_owner_types`. Desde aquí sólo llegan
    /// `shipment`, `container`, `scan` y `declaration`.
    public let ownerType: String
    public let ownerID: String
    public let kind: OFDocumentKind
    public let mimeType: String
    public let byteSize: Int64
    /// `sha256` en hexadecimal. Es la clave con la que el terminal reconoce que dos entradas del
    /// listado son el mismo fichero: `billing-service` y `customs-service` adjuntan la misma
    /// factura comercial al mismo envío y `document-service` reutiliza el `doc_`, pero el listado
    /// la devuelve una vez por cada dueño.
    public let sha256: String
    public let regionCode: OFRegionCode
    public let uploadedBy: String
    public let uploadedAt: Date
    /// Fecha hasta la que el documento es indestruible. La fija `customs-service` con
    /// `OF_CUSTOMS_RETENTION_YEARS` en lo que va a la aduana; el app se limita a no ofrecer el
    /// borrado cuando está en el futuro.
    public let retainedUntil: Date?

    public var id: String { documentID.rawValue }

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case ownerType = "owner_type"
        case ownerID = "owner_id"
        case kind
        case mimeType = "mime_type"
        case byteSize = "byte_size"
        case sha256
        case regionCode = "region_code"
        case uploadedBy = "uploaded_by"
        case uploadedAt = "uploaded_at"
        case retainedUntil = "retained_until"
    }

    /// Si el terminal puede pintarlo en pantalla o sólo listarlo.
    ///
    /// PDF e imagen se abren en el visor propio. Cualquier otra cosa —un XML de respuesta de la
    /// autoridad aduanera, por ejemplo— se enseña como fila con su nombre y nada más, porque
    /// abrirla con el visor del sistema sacaría al conductor del app en medio de un control.
    public var isViewableInApp: Bool {
        mimeType == "application/pdf" || mimeType.hasPrefix("image/")
    }
}

/// Vocabulario cerrado de `platform.documents.kind`.
///
/// Están los diez, aunque el terminal sólo produzca dos (`proof_of_delivery` y `damage_photo`):
/// los otros ocho llegan en el listado del envío y hay que saber nombrarlos en pantalla. Un valor
/// desconocido no rompe la decodificación, cae en `unknown` — la regla del contrato es que los
/// campos nuevos se ignoran, nunca se rechazan.
public enum OFDocumentKind: RawRepresentable, Codable, Hashable, Sendable {

    case billOfLading
    case commercialInvoice
    case packingList
    case certificateOfOrigin
    case proofOfDelivery
    case damagePhoto
    case insuranceCertificate
    case customsDecision
    case renderedInvoice
    case creditNote
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "bill_of_lading": self = .billOfLading
        case "commercial_invoice": self = .commercialInvoice
        case "packing_list": self = .packingList
        case "certificate_of_origin": self = .certificateOfOrigin
        case "proof_of_delivery": self = .proofOfDelivery
        case "damage_photo": self = .damagePhoto
        case "insurance_certificate": self = .insuranceCertificate
        case "customs_decision": self = .customsDecision
        case "rendered_invoice": self = .renderedInvoice
        case "credit_note": self = .creditNote
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .billOfLading: return "bill_of_lading"
        case .commercialInvoice: return "commercial_invoice"
        case .packingList: return "packing_list"
        case .certificateOfOrigin: return "certificate_of_origin"
        case .proofOfDelivery: return "proof_of_delivery"
        case .damagePhoto: return "damage_photo"
        case .insuranceCertificate: return "insurance_certificate"
        case .customsDecision: return "customs_decision"
        case .renderedInvoice: return "rendered_invoice"
        case .creditNote: return "credit_note"
        case .unknown(let raw): return raw
        }
    }

    /// Documentos que el conductor tiene que poder enseñar aunque el móvil no tenga cobertura.
    ///
    /// La lista sale de lo que piden en ventanilla en un paso fronterizo. No incluye la factura
    /// rendida ni el abono: eso es asunto de `billing-service` y del administrativo, y arrastrarlo
    /// al terminal sólo llenaría el disco del móvil.
    public var isPrefetchedForBorderStop: Bool {
        switch self {
        case .billOfLading, .commercialInvoice, .packingList,
             .certificateOfOrigin, .customsDecision:
            return true
        default:
            return false
        }
    }
}

/// Respuesta de `POST /v1/documents/{document_id}/signed-url`.
///
/// El TTL viene del servicio (`OF_DOCUMENT_SIGNED_URL_TTL_SECONDS`, quince minutos hoy) y el app
/// no lo asume: guarda `expiresAt` tal cual y vuelve a pedir la URL cuando falta menos de un
/// minuto. Cachearla más tiempo daba un 403 justo cuando el agente de aduanas miraba la pantalla.
public struct OFSignedDownload: Codable, Sendable {
    public let url: URL
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
    }

    public var isUsable: Bool {
        expiresAt.timeIntervalSinceNow > 60
    }
}
