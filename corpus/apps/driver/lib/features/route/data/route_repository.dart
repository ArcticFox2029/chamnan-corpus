/// Traz a rota corrente do routing-service (`GET /v1/shipments/{shipment_id}/route`) e mantém o
/// espelho em `local_route_legs`. Também trata do caso desagradável: o replaneamento.
///
/// Quando o routing-service publica `route.replanned`, o troço que o condutor tinha à frente
/// pode simplesmente deixar de existir, e o fleet-service liberta a atribuição correspondente.
/// A app descobre isso por push (notification-service) ou na sincronização seguinte, e o que faz
/// aqui é apagar em bloco os troços das versões antigas para não misturar duas rotas no ecrã.
library;

import 'package:sqflite/sqflite.dart';

import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/error_envelope.dart';
import '../../../core/network/of_api_client.dart';
import '../domain/route_plan.dart';

class RouteRepository {
  RouteRepository({required OfApiClient api, required Database db})
      : _api = api,
        _db = db;

  final OfApiClient _api;
  final Database _db;

  /// Puxa e guarda a rota corrente. Devolve `null` quando a expedição ainda não tem rota — é
  /// normal entre `shipment.created` e o primeiro `POST /v1/routes/plan`, e o ecrã mostra
  /// "rota por planear" em vez de um erro.
  Future<RoutePlan?> refreshCurrentRoute(PrefixedId shipmentId) async {
    try {
      final body = await _api.getJson('/v1/shipments/$shipmentId/route');
      final plan = RoutePlan.fromJson(body);
      await _persist(plan);
      return plan;
    } on OfErrorEnvelope catch (e) {
      if (e.httpStatus == 404) return null;
      if (!e.retryable) rethrow;
      return cachedRoute(shipmentId);
    }
  }

  /// `GET /v1/routes/{route_id}`. Usado quando o push de `route.replanned` traz o `route_id` novo
  /// e queremos a versão nova sem esperar pela passagem seguinte do `SyncEngine`.
  Future<RoutePlan> readRoute(PrefixedId routeId) async {
    final body = await _api.getJson('/v1/routes/$routeId');
    final plan = RoutePlan.fromJson(body);
    await _persist(plan);
    return plan;
  }

  /// Escreve os troços e limpa tudo o que pertença a uma versão anterior da mesma expedição.
  /// A limpeza é parte da mesma transação de propósito: uma rota meio-substituída no ecrã de um
  /// condutor a chegar a uma fronteira é pior do que nenhuma rota.
  Future<void> _persist(RoutePlan plan) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'local_route_legs',
        where: 'shipment_id = ? AND route_version < ?',
        whereArgs: <Object?>[plan.shipmentId.value, plan.version],
      );
      for (final leg in plan.legs) {
        await txn.insert(
          'local_route_legs',
          leg.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Reconstrói a rota a partir do espelho local. O cabeçalho (`strategy`, totais) não é
  /// guardado — não vale uma tabela só para ele — por isso é recomposto dos troços: o total é a
  /// soma das distâncias e a estratégia fica marcada como desconhecida.
  Future<RoutePlan?> cachedRoute(PrefixedId shipmentId) async {
    final rows = await _db.query(
      'local_route_legs',
      where: 'shipment_id = ?',
      whereArgs: <Object?>[shipmentId.value],
      orderBy: 'route_version DESC, seq_no ASC',
    );
    if (rows.isEmpty) return null;

    final version = rows.first['route_version']! as int;
    final legs = rows
        .where((row) => row['route_version'] == version)
        .map(RouteLeg.fromRow)
        .toList(growable: false);

    return RoutePlan(
      routeId: legs.first.routeId,
      shipmentId: shipmentId,
      version: version,
      strategy: 'unknown',
      totalDistanceM: legs.fold<int>(0, (sum, leg) => sum + leg.distanceM),
      totalDurationS: legs.fold<int>(
        0,
        (sum, leg) => sum + leg.plannedArriveAt.difference(leg.plannedDepartAt).inSeconds,
      ),
      legs: legs,
    );
  }

  /// `POST /v1/eta/batch`. O routing-service aceita até 500 expedições de uma vez e responde com
  /// a chegada prevista por troço; nós mandamos as do turno todas juntas, uma vez por
  /// sincronização, em vez de uma chamada por ecrã aberto.
  ///
  /// A previsão sai do prior de `analytics.mv_lane_performance_daily` — é a mesma vista que
  /// alimenta o painel de corredores da consola, e é por isso que o número muda ao fim do dia
  /// mesmo sem a rota mudar.
  Future<Map<String, DateTime>> batchEta(List<PrefixedId> shipmentIds) async {
    if (shipmentIds.isEmpty) return const <String, DateTime>{};
    final body = await _api.postJson('/v1/eta/batch', <String, Object?>{
      'shipment_ids': shipmentIds.map((id) => id.value).toList(growable: false),
    });
    return <String, DateTime>{
      for (final row in (body['items']! as List<Object?>).cast<Map<String, Object?>>())
        row['shipment_id']! as String: DateTime.parse(row['predicted_arrive_at']! as String),
    };
  }

  /// Apaga o espelho de uma expedição fechada. Chamado quando a atribuição é libertada; guardar
  /// troços de entregas antigas só faz o ficheiro crescer.
  Future<void> forget(PrefixedId shipmentId) async {
    await _db.delete(
      'local_route_legs',
      where: 'shipment_id = ?',
      whereArgs: <Object?>[shipmentId.value],
    );
  }
}
