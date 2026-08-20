import Foundation

//
//  OFCursorPaginator.swift
//  OrbitalFreightDriver
//

/// Recorre las respuestas paginadas de la plataforma como una secuencia asíncrona.
///
/// La paginación es por cursor en todos los servicios, sin excepción: no existe `offset` en ningún
/// endpoint y pedirlo devuelve `400`. Esto importa aquí más que en la consola web, porque el
/// terminal pagina el rastro de escaneos de un envío mientras el conductor baja por la lista y la
/// cobertura entra y sale; con cursor, retomar donde se cortó es gratis.

/// Página tal cual la devuelve cualquier listado: `{"items": [...], "next_cursor": "…"|null}`.
public struct OFCursorPage<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    /// `nil` marca el final. Nunca es cadena vacía; si llega vacía la tratamos como final y lo
    /// registramos, porque significaría que un servicio se ha salido del contrato.
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

/// Secuencia asíncrona sobre un listado paginado.
///
/// Uso típico en la pantalla de rastro:
/// ```swift
/// let trail = OFCursorPaginator<OFScanEvent>(client: client, endpoint: .shipmentScans(shipmentID))
/// for try await scan in trail {
///     rows.append(scan)
/// }
/// ```
public struct OFCursorPaginator<Item: Decodable & Sendable>: AsyncSequence, Sendable {

    public typealias Element = Item

    /// Límite por página. El máximo del contrato es 200 y el valor por omisión 50; en el terminal
    /// bajamos a 25 a propósito, porque una página grande sobre una conexión de camión tarda más
    /// en llegar de lo que el conductor tarda en volver a guardar el móvil en el bolsillo.
    public static var mobilePageSize: Int { 25 }

    private let client: OFAPIClient
    private let endpoint: OFEndpoint
    private let pageSize: Int

    public init(client: OFAPIClient, endpoint: OFEndpoint, pageSize: Int = OFCursorPaginator.mobilePageSize) {
        self.client = client
        self.endpoint = endpoint
        self.pageSize = min(max(pageSize, 1), 200)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(client: client, endpoint: endpoint, pageSize: pageSize)
    }

    public struct Iterator: AsyncIteratorProtocol {

        private let client: OFAPIClient
        private let endpoint: OFEndpoint
        private let pageSize: Int
        private var buffer: [Item] = []
        private var cursor: String?
        private var exhausted = false

        init(client: OFAPIClient, endpoint: OFEndpoint, pageSize: Int) {
            self.client = client
            self.endpoint = endpoint
            self.pageSize = pageSize
        }

        public mutating func next() async throws -> Item? {
            if !buffer.isEmpty { return buffer.removeFirst() }
            if exhausted { return nil }

            var query = [URLQueryItem(name: "limit", value: String(pageSize))]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

            let page: OFCursorPage<Item> = try await client.send(endpoint, extraQuery: query)

            // Un cursor vacío es final, igual que un cursor nulo. El servidor no debería mandarlo,
            // pero un bucle infinito en el móvil de un conductor cuesta batería y datos.
            if let next = page.nextCursor, !next.isEmpty {
                cursor = next
            } else {
                exhausted = true
            }

            buffer = page.items
            return buffer.isEmpty ? nil : buffer.removeFirst()
        }
    }
}

extension OFCursorPaginator {

    /// Recoge páginas hasta agotar el listado o hasta llegar al tope indicado.
    ///
    /// El tope no es una cortesía: la pantalla de asignaciones del turno no debería traerse el
    /// histórico entero de un conductor con quince años en la empresa sólo porque el filtro
    /// `active=true` se haya perdido en una refactorización.
    public func collect(maximum: Int) async throws -> [Item] {
        var result: [Item] = []
        result.reserveCapacity(min(maximum, 200))
        for try await item in self {
            result.append(item)
            if result.count >= maximum { break }
        }
        return result
    }
}
