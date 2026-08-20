/// Repositório das atribuições. Lê `GET /v1/assignments` do fleet-service, completa cada linha
/// com `GET /v1/shipments/{shipment_id}` do container-registry e guarda o resultado em
/// `local_assignments`, que é o que a lista do condutor mostra — com ou sem rede.
///
/// A app nunca cria nem liberta atribuições: `fleet.v1.FleetService/Assign` e
/// `fleet.v1.FleetService/Release` são gRPC internos do cluster (§3.2) e quem lhes chama é o
/// despachante na consola de `web/`. Daqui só se lê.
library;

import 'package:sqflite/sqflite.dart';

import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/error_envelope.dart';
import '../../../core/network/of_api_client.dart';
import '../../../core/network/of_session.dart';
import '../domain/assignment.dart';

class FleetRepository {
  FleetRepository({
    required OfApiClient api,
    required Database db,
    required OfSession session,
  })  : _api = api,
        _db = db,
        _session = session;

  final OfApiClient _api;
  final Database _db;
  final OfSession _session;

  /// Puxa as atribuições abertas deste condutor e reescreve o espelho local. Chamado pelo
  /// `SyncEngine` no fim de cada passagem e pelo gesto de "puxar para atualizar".
  ///
  /// Sem rede devolve o que está em cache: é o comportamento certo num parque de contentores
  /// subterrâneo, onde o condutor precisa da lista mais do que precisa de a ter fresca.
  Future<List<Assignment>> refreshActiveAssignments() async {
    try {
      final page = await _api.getPage<Map<String, Object?>>(
        '/v1/assignments',
        (row) => row,
        query: <String, Object?>{
          'driver_id': _session.driverId.value,
          'active': true,
        },
        limit: 50,
      );

      final enriched = <Assignment>[];
      for (final row in page.items) {
        final shipmentId = row['shipment_id']! as String;
        final shipment = await _readShipment(shipmentId);
        enriched.add(
          Assignment.fromJson(<String, Object?>{
            ...row,
            'shipment_status': shipment['status'],
            'shipment_reference': shipment['reference'],
            'region_code': shipment['region_code'],
          }),
        );
      }

      await _replaceMirror(enriched);
      return enriched;
    } on OfErrorEnvelope catch (e) {
      if (!e.retryable) rethrow;
      return cachedAssignments();
    }
  }

  /// `GET /v1/shipments/{shipment_id}` no container-registry. A resposta traz os contentores
  /// embutidos, mas para a lista só interessam três campos; o resto é lido quando o condutor
  /// abre a expedição.
  Future<Map<String, Object?>> _readShipment(String shipmentId) =>
      _api.getJson('/v1/shipments/$shipmentId');

  /// Substitui o espelho numa única transação. É importante que seja uma só: se apagássemos e
  /// inseríssemos em duas operações, uma paragem da app pelo meio deixava o condutor com a lista
  /// vazia e sem forma de perceber porquê.
  Future<void> _replaceMirror(List<Assignment> assignments) async {
    await _db.transaction((txn) async {
      await txn.delete('local_assignments', where: 'released_at IS NULL');
      for (final assignment in assignments) {
        await txn.insert(
          'local_assignments',
          assignment.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// O que está guardado, por ordem de atribuição. É esta a fonte da UI — o `refresh` só escreve
  /// aqui, nunca alimenta um ecrã diretamente.
  Future<List<Assignment>> cachedAssignments({bool includeReleased = false}) async {
    final rows = await _db.query(
      'local_assignments',
      where: includeReleased ? null : 'released_at IS NULL',
      orderBy: 'assigned_at ASC',
    );
    return rows.map(Assignment.fromRow).toList(growable: false);
  }

  Future<Assignment?> byShipment(PrefixedId shipmentId) async {
    final rows = await _db.query(
      'local_assignments',
      where: 'shipment_id = ?',
      whereArgs: <Object?>[shipmentId.value],
      limit: 1,
    );
    return rows.isEmpty ? null : Assignment.fromRow(rows.first);
  }

  /// Marca localmente uma atribuição como libertada. Não chama nada: quem stampa `released_at`
  /// em `fleet.vehicle_assignments` é o fleet-service, seja por `FleetService/Release` a partir
  /// da consola, seja por ele próprio a consumir `route.replanned` e a descobrir que o `leg_id`
  /// desta atribuição já não existe na versão nova da rota.
  Future<void> markReleasedLocally(PrefixedId assignmentId, DateTime releasedAt) async {
    await _db.update(
      'local_assignments',
      <String, Object?>{'released_at': releasedAt.toIso8601String()},
      where: 'assignment_id = ?',
      whereArgs: <Object?>[assignmentId.value],
    );
  }

  /// `GET /v1/drivers/{driver_id}/availability`. Só faz sentido com rede; offline mostramos o
  /// último valor conhecido com a hora a que foi obtido, para o condutor decidir se ainda serve.
  Future<DriverAvailability> availability() async {
    final body = await _api.getJson('/v1/drivers/${_session.driverId}/availability');
    return DriverAvailability.fromJson(body);
  }

  /// `GET /v1/vehicles/{vehicle_id}`. Usado no cabeçalho da atribuição para mostrar matrícula e
  /// classe, e para avisar quando o veículo não é `adr_certified` mas a expedição leva um
  /// contentor com classe de perigo declarada em `freight.container_hazard_classes`.
  Future<Map<String, Object?>> vehicle(PrefixedId vehicleId) =>
      _api.getJson('/v1/vehicles/$vehicleId');
}
