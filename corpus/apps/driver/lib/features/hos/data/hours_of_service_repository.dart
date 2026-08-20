/// Registo das mudanças de estado de serviço e o seu envio para
/// `POST /v1/drivers/{driver_id}/hours-of-service` no fleet-service.
///
/// O endpoint é **aditivo**: cada chamada acrescenta uma mudança, nunca corrige a anterior. É por
/// isso que uma linha por enviar não pode ser reescrita nem fundida com a seguinte — o
/// fleet-service reconstrói o dia a partir da sequência, e uma sequência com buracos dá um
/// cálculo errado de tempo de condução, que é um problema com consequências legais e não só
/// informáticas.
library;

import 'package:sqflite/sqflite.dart';

import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/error_envelope.dart';
import '../../../core/network/of_api_client.dart';
import '../../../core/network/of_session.dart';
import '../../../sync/outbox_dao.dart';
import '../domain/duty_status.dart';

class HoursOfServiceRepository {
  HoursOfServiceRepository({
    required OfApiClient api,
    required Database db,
    required OutboxDao outbox,
    required OfSession session,
  })  : _api = api,
        _db = db,
        _outbox = outbox,
        _session = session;

  final OfApiClient _api;
  final Database _db;
  final OutboxDao _outbox;
  final OfSession _session;

  /// Regista uma mudança de estado. Grava localmente e enfileira na mesma transação; o contador
  /// no ecrã começa a andar imediatamente, mesmo que a linha só saia daqui a duas horas.
  ///
  /// Ignora a mudança se o estado for o mesmo do último registo — carregar duas vezes no botão
  /// "a conduzir" não deve criar dois intervalos de zero minutos na sequência do fleet-service.
  Future<DutyStatusChange?> changeStatus(
    DutyStatus status, {
    PrefixedId? vehicleId,
    int? odometerKm,
    DateTime? startedAt,
  }) async {
    final latest = await _latestChange();
    if (latest != null && latest.status == status) return null;

    final changeId = PrefixedId.generate(IdPrefix.event).value;
    final when = (startedAt ?? DateTime.now()).toUtc();
    final odometerM = odometerKm == null ? null : odometerKm * 1000;

    await _db.transaction((txn) async {
      await txn.insert('local_duty_status_changes', <String, Object?>{
        'change_id': changeId,
        'driver_id': _session.driverId.value,
        'status': status.wire,
        'started_at': when.toIso8601String(),
        'vehicle_id': vehicleId?.value,
        'odometer_m': odometerM,
      });

      await _outbox.enqueueWithin(
        txn,
        operation: OutboxOperation.appendDutyStatus,
        method: 'POST',
        path: '/v1/drivers/${_session.driverId}/hours-of-service',
        payload: <String, Object?>{
          'change_id': changeId,
          'status': status.wire,
          'started_at': when.toIso8601String(),
          'vehicle_id': vehicleId?.value,
          'odometer_m': odometerM,
        },
      );
    });

    return DutyStatusChange(
      changeId: changeId,
      status: status,
      startedAt: when,
      vehicleId: vehicleId?.value,
      odometerM: odometerM,
    );
  }

  Future<DutyStatusChange?> _latestChange() async {
    final rows = await _db.query(
      'local_duty_status_changes',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : DutyStatusChange.fromRow(rows.first);
  }

  /// As mudanças das últimas 24 horas, base do contador local.
  Future<List<DutyStatusChange>> recentChanges() async {
    final since = DateTime.now().toUtc().subtract(const Duration(hours: 26)).toIso8601String();
    final rows = await _db.query(
      'local_duty_status_changes',
      where: 'started_at >= ?',
      whereArgs: <Object?>[since],
      orderBy: 'started_at ASC',
    );
    return rows.map(DutyStatusChange.fromRow).toList(growable: false);
  }

  Future<DutyDayEstimate> localEstimate() async =>
      DutyDayEstimate.fromChanges(await recentChanges());

  /// Confronta a estimativa local com a resposta autoritativa do fleet-service. Uma diferença
  /// grande quase sempre significa que ficou uma mudança por enviar num turno anterior — é o
  /// primeiro sítio a olhar quando o condutor diz que "a app diz uma coisa e o tacógrafo diz outra".
  Future<Duration?> driftAgainstServer() async {
    try {
      final body = await _api.getJson('/v1/drivers/${_session.driverId}/availability');
      final remaining = body['remaining_drive_minutes']! as int;
      final local = await localEstimate();
      final localRemaining = (9 * 60) - local.drivingMinutes;
      return Duration(minutes: (localRemaining - remaining).abs());
    } on OfErrorEnvelope {
      return null;
    }
  }

  /// Fecha o turno: descanso diário e, no mesmo gesto, uma última tentativa de esvaziar a fila.
  /// Chamado pelo botão "terminar turno", que é o único momento do dia em que se pode contar com
  /// o condutor a olhar para o ecrã à espera.
  Future<void> endShift({int? odometerKm}) async {
    await changeStatus(DutyStatus.dailyRest, odometerKm: odometerKm);
  }
}
