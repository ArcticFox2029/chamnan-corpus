/// Cria leituras (`freight.shipment_scan_events`) no dispositivo e põe-nas na fila para
/// `POST /v1/containers/{container_id}/scans` do container-registry. É o caminho de escrita mais
/// usado da app e o que mais vezes acontece sem rede — uma doca de carga é um sítio com paredes
/// de betão e telhado metálico.
///
/// Nada aqui fala com a rede. A leitura fica gravada localmente e enfileirada na mesma transação;
/// é o `SyncEngine` que a entrega mais tarde, e é o container-registry que publica
/// `shipment.scanned` a partir do seu próprio outbox.
library;

import 'package:sqflite/sqflite.dart';

import '../../../core/config/driver_environment.dart';
import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/of_session.dart';
import '../../../location/geofence_evaluator.dart';
import '../../../sync/outbox_dao.dart';

/// Os oito valores de `freight.shipment_scan_events.scan_type` (§2.3). A app usa seis; a
/// inspeção alfandegária é registada pelo agente na consola e a inspeção de selo pelo inspetor
/// de depósito em `apps/inspector-android/`.
enum ScanType {
  gateIn('gate_in'),
  gateOut('gate_out'),
  load('load'),
  unload('unload'),
  sealCheck('seal_check'),
  damageReport('damage_report'),
  proofOfDelivery('proof_of_delivery');

  const ScanType(this.wire);

  final String wire;

  /// Só o comprovativo de entrega desbloqueia faturação: o billing-service consome
  /// `shipment.scanned` mas ignora tudo o que não seja `scan_type = 'proof_of_delivery'`.
  /// Por isso esta leitura tem um caminho próprio em `ProofOfDeliveryRepository`.
  bool get unlocksInvoicing => this == ScanType.proofOfDelivery;
}

/// O que a app conseguiu apurar sobre onde a leitura foi feita.
class ScanPosition {
  const ScanPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    this.facilityId,
  });

  final double latitude;
  final double longitude;
  final double accuracyM;

  /// `fac_…` deduzido localmente pelo `GeofenceEvaluator`. É um palpite: quem decide mesmo se um
  /// ponto está dentro da cerca é o `geo.v1.GeoService/PointInFence`, chamado pelo
  /// container-registry quando recebe a leitura. Mandamos o palpite na mesma porque poupa ao
  /// condutor escolher a instalação numa lista de quarenta.
  final PrefixedId? facilityId;
}

class ScanRepository {
  ScanRepository({
    required Database db,
    required OutboxDao outbox,
    required OfSession session,
    required GeofenceEvaluator geofences,
    required DriverEnvironment environment,
  })  : _db = db,
        _outbox = outbox,
        _session = session,
        _geofences = geofences,
        _environment = environment;

  final Database _db;
  final OutboxDao _outbox;
  final OfSession _session;
  final GeofenceEvaluator _geofences;
  final DriverEnvironment _environment;

  /// Grava uma leitura e enfileira-a. Devolve o `scn_` gerado, que quem chama precisa de guardar
  /// — é ele que serve de `owner_id` para qualquer documento associado (`owner_type = 'scan'`).
  ///
  /// O `occurredAt` é o relógio do telemóvel no momento do gesto. Não é corrigido: o
  /// container-registry compara-o com o `recorded_at` dele e sinaliza a leitura acima de
  /// `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S`. Falsificar a hora para evitar a marca seria
  /// apagar exatamente a informação que a auditoria quer ver.
  Future<PrefixedId> recordScan({
    required PrefixedId shipmentId,
    required ScanType type,
    PrefixedId? containerId,
    ScanPosition? position,
    String? notes,
    String? deviceSerial,
    String? dependsOnMessageId,
    DateTime? occurredAt,
  }) async {
    final scanId = PrefixedId.generate(IdPrefix.scan);
    final when = (occurredAt ?? DateTime.now()).toUtc();

    final resolved = position ?? await _geofences.currentPosition();
    // Sem contentor, a leitura é da expedição inteira (é o caso do comprovativo de entrega numa
    // carga de grupagem). O container-registry aceita `container_id` nulo — a coluna é
    // opcional em `freight.shipment_scan_events`.
    final payload = <String, Object?>{
      'scan_id': scanId.value,
      'shipment_id': shipmentId.value,
      'container_id': containerId?.value,
      'scan_type': type.wire,
      'facility_id': resolved?.facilityId?.value,
      'scanned_by_user_id': _session.userId.value,
      'occurred_at': when.toIso8601String(),
      if (resolved != null)
        'position': <String, Object?>{
          'lat': resolved.latitude,
          'lon': resolved.longitude,
        },
      'device_serial': deviceSerial,
      'notes': notes,
    };

    await _db.transaction((txn) async {
      await txn.insert('local_scan_events', <String, Object?>{
        'scan_id': scanId.value,
        'shipment_id': shipmentId.value,
        'container_id': containerId?.value,
        'scan_type': type.wire,
        'facility_id': resolved?.facilityId?.value,
        'occurred_at': when.toIso8601String(),
        'latitude': resolved?.latitude,
        'longitude': resolved?.longitude,
        'accuracy_m': resolved?.accuracyM,
        'device_serial': deviceSerial,
        'notes': notes,
        'sync_state': 'pending',
      });

      await _outbox.enqueueWithin(
        txn,
        operation: OutboxOperation.recordScan,
        method: 'POST',
        // O caminho exige um contentor. Sem ele usamos o endpoint da expedição, que aceita a
        // mesma forma de corpo — é o mesmo handler do lado do Ktor.
        path: containerId != null
            ? '/v1/containers/$containerId/scans'
            : '/v1/shipments/$shipmentId/scans',
        payload: payload,
        dependsOn: dependsOnMessageId,
      );
    });

    return scanId;
  }

  /// A leitura demorou tanto a sair do telemóvel que o container-registry a vai marcar como
  /// suspeita? O ecrã usa isto para avisar antes de o condutor sair do parque, quando ainda dá
  /// para apanhar rede lá fora.
  Future<bool> hasScansPastSkewTolerance() async {
    final threshold = DateTime.now()
        .toUtc()
        .subtract(_environment.scanClockSkewTolerance)
        .toIso8601String();
    final rows = await _db.query(
      'local_scan_events',
      where: "sync_state = 'pending' AND occurred_at < ?",
      whereArgs: <Object?>[threshold],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// O rasto local de uma expedição, mais recente primeiro. Mistura o que já foi confirmado com o
  /// que ainda está por enviar; a coluna `sync_state` é o que distingue os dois no ecrã.
  Future<List<Map<String, Object?>>> localTrail(PrefixedId shipmentId) => _db.query(
        'local_scan_events',
        where: 'shipment_id = ?',
        whereArgs: <Object?>[shipmentId.value],
        orderBy: 'occurred_at DESC',
      );
}
