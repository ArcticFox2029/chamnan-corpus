/// Motor de sincronização: drena a fila `local_outbox` para os serviços de §3 e traz de volta o
/// espelho de leitura das atribuições e da rota corrente. Corre em três gatilhos — arranque da
/// app, regresso da rede (connectivity_plus) e a tarefa periódica do WorkManager registada em
/// lib/main.dart.
///
/// A regra que governa este ficheiro: uma escrita só sai daqui com a `X-OF-Idempotency-Key` que
/// nasceu com ela. Enviar duas vezes tem de ser inofensivo, porque numa fronteira com rede fraca
/// é o que acontece várias vezes por dia.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../core/config/driver_environment.dart';
import '../core/network/error_envelope.dart';
import '../core/network/of_api_client.dart';
import '../features/assignments/data/fleet_repository.dart';
import '../features/route/data/route_repository.dart';
import 'outbox_dao.dart';

/// Resumo de uma passagem, mostrado no painel de diagnóstico e escrito nos registos locais.
class SyncReport {
  const SyncReport({
    required this.published,
    required this.retried,
    required this.discarded,
    required this.startedAt,
    required this.finishedAt,
  });

  final int published;
  final int retried;
  final int discarded;
  final DateTime startedAt;
  final DateTime finishedAt;

  Duration get elapsed => finishedAt.difference(startedAt);

  bool get isClean => retried == 0 && discarded == 0;
}

class SyncEngine {
  SyncEngine({
    required OfApiClient api,
    required OutboxDao outbox,
    required Database db,
    required FleetRepository fleet,
    required RouteRepository routes,
    required DriverEnvironment environment,
    Connectivity? connectivity,
  })  : _api = api,
        _outbox = outbox,
        _db = db,
        _fleet = fleet,
        _routes = routes,
        _environment = environment,
        _connectivity = connectivity ?? Connectivity();

  final OfApiClient _api;
  final OutboxDao _outbox;
  final Database _db;
  final FleetRepository _fleet;
  final RouteRepository _routes;
  final DriverEnvironment _environment;
  final Connectivity _connectivity;

  final StreamController<SyncReport> _reports = StreamController<SyncReport>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _timer;
  bool _running = false;

  /// Cada passagem completa publica aqui. O crachá da lista de entregas escuta este fluxo.
  Stream<SyncReport> get reports => _reports.stream;

  void start() {
    _timer ??= Timer.periodic(_environment.outboxFlushInterval, (_) => unawaited(flush()));
    _connectivitySub ??= _connectivity.onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      // Voltar a ter rede é o momento mais valioso para esvaziar a fila: normalmente é a saída
      // de um terminal, onde se acumularam as leituras de `gate_out` e de carga.
      if (online) unawaited(flush());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
  }

  /// Drena a fila. Reentrante por bandeira simples — duas passagens em paralelo enviariam a
  /// mesma linha duas vezes, o que é seguro do lado do serviço mas suja os registos e gasta rádio.
  Future<SyncReport> flush() async {
    if (_running) {
      return SyncReport(
        published: 0,
        retried: 0,
        discarded: 0,
        startedAt: DateTime.now().toUtc(),
        finishedAt: DateTime.now().toUtc(),
      );
    }
    _running = true;
    final startedAt = DateTime.now().toUtc();
    var published = 0;
    var retried = 0;
    var discarded = 0;

    try {
      var batch = await _outbox.dueBatch();
      while (batch.isNotEmpty) {
        for (final message in batch) {
          final outcome = await _deliver(message);
          switch (outcome) {
            case _DeliveryOutcome.published:
              published++;
            case _DeliveryOutcome.retry:
              retried++;
            case _DeliveryOutcome.discarded:
              discarded++;
            case _DeliveryOutcome.offline:
              // Sem rede não vale a pena continuar o lote: as restantes falhariam igual e cada
              // falha custa uma escrita no SQLite e um recuo desnecessário.
              _running = false;
              return _publishReport(startedAt, published, retried, discarded);
          }
        }
        batch = await _outbox.dueBatch();
      }
      await _pullReadModel();
    } finally {
      _running = false;
    }

    return _publishReport(startedAt, published, retried, discarded);
  }

  Future<_DeliveryOutcome> _deliver(OutboxMessage message) async {
    try {
      final response = switch (message.method) {
        'POST' => await _api.postJson(
            message.path,
            message.payload,
            idempotencyKey: message.messageId,
          ),
        'PATCH' => await _api.patchJson(
            message.path,
            message.payload,
            idempotencyKey: message.messageId,
          ),
        _ => throw StateError('método ${message.method} não sai por esta fila'),
      };
      await _applyServerEcho(message, response);
      await _outbox.markPublished(message.messageId);
      return _DeliveryOutcome.published;
    } on OfErrorEnvelope catch (e) {
      if (e.code == 'device_offline') {
        return _DeliveryOutcome.offline;
      }
      if (!e.retryable || message.attempts + 1 >= _environment.maxOutboxAttempts) {
        await _outbox.discard(message.messageId, '${e.code} (trace ${e.traceId})');
        return _DeliveryOutcome.discarded;
      }
      await _outbox.markFailed(message.messageId, message.attempts, e.code);
      return _DeliveryOutcome.retry;
    }
  }

  /// Reconcilia o que o serviço devolveu com a cópia local. O caso que interessa é a leitura:
  /// o container-registry devolve o `recorded_at` dele, e é a diferença para o nosso
  /// `occurred_at` que explica ao condutor por que motivo uma entrega aparece "registada às 19h"
  /// quando ele a fez às 17h30 sem rede.
  Future<void> _applyServerEcho(OutboxMessage message, Map<String, Object?> response) async {
    switch (message.operation) {
      case OutboxOperation.recordScan:
        await _db.update(
          'local_scan_events',
          <String, Object?>{
            'sync_state': 'confirmed',
            'recorded_at': response['recorded_at'],
          },
          where: 'scan_id = ?',
          whereArgs: <Object?>[message.payload['scan_id']],
        );
      case OutboxOperation.uploadDocument:
        await _db.update(
          'local_pending_documents',
          <String, Object?>{
            'document_id': response['document_id'],
            'uploaded_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'local_document_id = ?',
          whereArgs: <Object?>[message.payload['local_document_id']],
        );
      case OutboxOperation.appendDutyStatus:
        await _db.update(
          'local_duty_status_changes',
          <String, Object?>{'synced_at': DateTime.now().toUtc().toIso8601String()},
          where: 'change_id = ?',
          whereArgs: <Object?>[message.payload['change_id']],
        );
      case OutboxOperation.changeShipmentStatus:
        await _db.update(
          'local_assignments',
          <String, Object?>{'shipment_status': response['status'] ?? 'delivered'},
          where: 'shipment_id = ?',
          whereArgs: <Object?>[message.payload['shipment_id']],
        );
    }
  }

  /// Puxa o espelho de leitura. A ordem não é acidental: as atribuições primeiro, porque são
  /// elas que dizem que expedições nos interessam, e só depois a rota corrente de cada uma.
  Future<void> _pullReadModel() async {
    final assignments = await _fleet.refreshActiveAssignments();
    for (final assignment in assignments) {
      await _routes.refreshCurrentRoute(assignment.shipmentId);
    }
  }

  SyncReport _publishReport(DateTime startedAt, int published, int retried, int discarded) {
    final report = SyncReport(
      published: published,
      retried: retried,
      discarded: discarded,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
    );
    if (!_reports.isClosed) _reports.add(report);
    return report;
  }
}

enum _DeliveryOutcome { published, retry, discarded, offline }
