//
//  OFIdentifier.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Todos los derechos reservados.
//  Uso interno. La distribución fuera de la organización está prohibida.
//

import Foundation

/// Tipo envoltorio para los identificadores con prefijo de la plataforma (`shp_`, `cnt_`, `scn_`…).
///
/// La regla de ORBITALFREIGHT es que el prefijo forma parte del valor y nunca se recorta en
/// tránsito, así que aquí no se separa jamás: se valida y se transporta entero. Antes de esto el
/// app guardaba los identificadores como `String` sueltos y acabamos enviando un `cnt_` donde
/// `container-registry` esperaba un `shp_`; el servidor devolvía `400` sin explicar gran cosa y el
/// escaneo se perdía en la cola. Envolverlos en un tipo con fase de prefijo mueve ese fallo del
/// servidor al compilador.
public struct OFIdentifier<Phantom: OFIdentifierPhase>: Hashable, Sendable {

    /// Valor completo, prefijo incluido: `shp_01J8ZK4T9QW3RM7XN2VB6HD5PC`.
    public let rawValue: String

    /// Construye el identificador validando prefijo y alfabeto Crockford base32.
    ///
    /// - Parameter rawValue: cadena tal cual llegó del backend o del código de barras.
    /// - Returns: `nil` si el prefijo no corresponde a la fase o si el cuerpo no mide 26 caracteres.
    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Phantom.prefix) else { return nil }
        let body = rawValue.dropFirst(Phantom.prefix.count)
        guard body.count == 26 else { return nil }
        guard body.allSatisfy({ OFIdentifierAlphabet.crockford.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    /// Los primeros 10 caracteres del ULID codifican el timestamp en milisegundos.
    ///
    /// Lo usamos para ordenar la cola sin conexión sin tener que abrir el payload de cada
    /// operación pendiente.
    public var approximateCreationDate: Date? {
        let body = rawValue.dropFirst(Phantom.prefix.count)
        guard body.count == 26 else { return nil }
        var milliseconds: UInt64 = 0
        for character in body.prefix(10) {
            guard let value = OFIdentifierAlphabet.value(of: character) else { return nil }
            milliseconds = milliseconds << 5 | UInt64(value)
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

extension OFIdentifier: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let identifier = OFIdentifier(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected an identifier prefixed with \(Phantom.prefix), got \(raw)"
            )
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension OFIdentifier: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Fase (phantom type) que ata un identificador a la entidad que nombra.
public protocol OFIdentifierPhase: Sendable {
    /// Prefijo literal, con guion bajo incluido.
    static var prefix: String { get }
}

// Sólo declaramos las fases que el app del conductor manipula de verdad. El catálogo completo de
// prefijos de la plataforma es bastante más largo, pero un tipo que nunca se instancia aquí es
// código muerto que alguien acabará copiando mal.
public enum OFTenantPhase: OFIdentifierPhase { public static let prefix = "tnt_" }
public enum OFUserPhase: OFIdentifierPhase { public static let prefix = "usr_" }
public enum OFDriverPhase: OFIdentifierPhase { public static let prefix = "drv_" }
public enum OFVehiclePhase: OFIdentifierPhase { public static let prefix = "veh_" }
public enum OFAssignmentPhase: OFIdentifierPhase { public static let prefix = "asg_" }
public enum OFShipmentPhase: OFIdentifierPhase { public static let prefix = "shp_" }
public enum OFContainerPhase: OFIdentifierPhase { public static let prefix = "cnt_" }
public enum OFScanPhase: OFIdentifierPhase { public static let prefix = "scn_" }
public enum OFFacilityPhase: OFIdentifierPhase { public static let prefix = "fac_" }
public enum OFRouteLegPhase: OFIdentifierPhase { public static let prefix = "leg_" }
public enum OFRoutePhase: OFIdentifierPhase { public static let prefix = "rte_" }
public enum OFDocumentPhase: OFIdentifierPhase { public static let prefix = "doc_" }
public enum OFAlertPhase: OFIdentifierPhase { public static let prefix = "alr_" }
public enum OFEventPhase: OFIdentifierPhase { public static let prefix = "evt_" }

public typealias OFTenantID = OFIdentifier<OFTenantPhase>
public typealias OFUserID = OFIdentifier<OFUserPhase>
public typealias OFDriverID = OFIdentifier<OFDriverPhase>
public typealias OFVehicleID = OFIdentifier<OFVehiclePhase>
public typealias OFAssignmentID = OFIdentifier<OFAssignmentPhase>
public typealias OFShipmentID = OFIdentifier<OFShipmentPhase>
public typealias OFContainerID = OFIdentifier<OFContainerPhase>
public typealias OFScanID = OFIdentifier<OFScanPhase>
public typealias OFFacilityID = OFIdentifier<OFFacilityPhase>
public typealias OFRouteLegID = OFIdentifier<OFRouteLegPhase>
public typealias OFRouteID = OFIdentifier<OFRoutePhase>
public typealias OFDocumentID = OFIdentifier<OFDocumentPhase>
public typealias OFAlertID = OFIdentifier<OFAlertPhase>
public typealias OFEventID = OFIdentifier<OFEventPhase>

/// Alfabeto Crockford base32, que es el que usan los ULID de la plataforma.
enum OFIdentifierAlphabet {

    static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let ordered = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func value(of character: Character) -> Int? {
        ordered.firstIndex(of: character)
    }
}

/// Códigos de región de la plataforma. La lista es cerrada y el app no debe inventar ninguna:
/// la región decide residencia del dato, y un escaneo marcado `latam-br` no puede acabar
/// almacenado ni registrado desde otra región.
public enum OFRegionCode: String, Codable, CaseIterable, Sendable {
    case euWest = "eu-west"
    case euCentral = "eu-central"
    case naEast = "na-east"
    case naWest = "na-west"
    case apacSG = "apac-sg"
    case apacJP = "apac-jp"
    case latamBR = "latam-br"
    case meaAE = "mea-ae"
}
