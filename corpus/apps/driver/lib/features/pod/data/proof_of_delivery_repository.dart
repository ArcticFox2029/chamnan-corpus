/// Fecha uma entrega. É a operação mais delicada da app porque são três escritas em serviços
/// diferentes que têm de acontecer por esta ordem e mais nenhuma:
///
///  1. a leitura `proof_of_delivery` no container-registry
///     (`POST /v1/containers/{container_id}/scans`),
///  2. a assinatura no document-service (`POST /v1/documents`, `owner_type = 'scan'`),
///  3. a transição para `delivered` no container-registry
///     (`PATCH /v1/shipments/{shipment_id}/status`).
///
/// A ordem não é estética. O document-service confirma o `owner_id` junto do serviço dono antes
/// de aceitar o ficheiro, portanto a assinatura não pode chegar antes da leitura. E a transição
/// para `delivered` só depois da assinatura, porque o billing-service reage a
/// `shipment.scanned` com `scan_type = 'proof_of_delivery'` para desbloquear a faturação e não
/// queremos uma expedição faturável sem o comprovativo lá dentro.
///
/// As três linhas entram na fila numa única transação SQLite, encadeadas por `depends_on`. O
/// `SyncEngine` respeita a cadeia: nenhuma sai antes de a anterior estar publicada.
library;

import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/of_session.dart';
import '../../../sync/outbox_dao.dart';
import '../../documents/data/document_repository.dart';
import '../../scanning/data/scan_repository.dart';

/// Quem assinou, do lado do cliente. Vai nas notas da leitura e no corpo do documento; não há
/// coluna própria para isto em `freight.shipment_scan_events`, e inventar uma seria mexer no
/// esquema de outro serviço.
class Consignee {
  const Consignee({required this.name, this.company, this.idDocument});

  final String name;
  final String? company;
  final String? idDocument;

  String toNote() => <String>[
        'consignee=$name',
        if (company != null) 'company=$company',
        if (idDocument != null) 'id=$idDocument',
      ].join('; ');
}

/// O que ficou registado, para o ecrã de confirmação mostrar ao condutor.
class ProofOfDeliveryReceipt {
  const ProofOfDeliveryReceipt({
    required this.scanId,
    required this.signatureMessageId,
    required this.statusMessageId,
    required this.occurredAt,
  });

  final PrefixedId scanId;
  final String signatureMessageId;
  final String statusMessageId;
  final DateTime occurredAt;
}

class ProofOfDeliveryRepository {
  ProofOfDeliveryRepository({
    required Database db,
    required OutboxDao outbox,
    required ScanRepository scans,
    required DocumentRepository documents,
    required OfSession session,
  })  : _db = db,
        _outbox = outbox,
        _scans = scans,
        _documents = documents,
        _session = session;

  final Database _db;
  final OutboxDao _outbox;
  final ScanRepository _scans;
  final DocumentRepository _documents;
  final OfSession _session;

  /// Regista a entrega completa. Funciona igual com ou sem rede — o que muda é só quando as
  /// três linhas saem do telemóvel.
  Future<ProofOfDeliveryReceipt> complete({
    required PrefixedId shipmentId,
    required File signaturePng,
    required Consignee consignee,
    PrefixedId? containerId,
    String? damageNote,
  }) async {
    final occurredAt = DateTime.now().toUtc();

    // 1. A leitura. Guarda a posição e a instalação deduzida pela geocerca local.
    final scanId = await _scans.recordScan(
      shipmentId: shipmentId,
      type: ScanType.proofOfDelivery,
      containerId: containerId,
      notes: <String>[
        consignee.toNote(),
        if (damageNote != null) 'damage=$damageNote',
      ].join('; '),
      occurredAt: occurredAt,
    );

    final scanMessageId = await _messageIdForScan(scanId);

    // 2. A assinatura, dependente da leitura.
    final signatureMessageId = await _documents.stage(
      file: signaturePng,
      ownerType: 'scan',
      ownerId: scanId,
      kind: DocumentKind.proofOfDelivery,
      mimeType: 'image/png',
      dependsOnMessageId: scanMessageId,
    );

    // 3. A transição de estado, dependente da assinatura.
    late String statusMessageId;
    await _db.transaction((txn) async {
      statusMessageId = await _outbox.enqueueWithin(
        txn,
        operation: OutboxOperation.changeShipmentStatus,
        method: 'PATCH',
        path: '/v1/shipments/$shipmentId/status',
        payload: <String, Object?>{
          'shipment_id': shipmentId.value,
          'to_status': 'delivered',
          // O container-registry só aceita transições legais; `reason_code` vai para o evento
          // `shipment.status.changed` e daí para o audit-ledger.
          'reason_code': 'pod_captured',
          'changed_by': _session.userId.value,
          'changed_at': occurredAt.toIso8601String(),
          'proof_scan_id': scanId.value,
        },
        dependsOn: signatureMessageId,
      );

      await txn.update(
        'local_assignments',
        <String, Object?>{'shipment_status': 'delivered'},
        where: 'shipment_id = ?',
        whereArgs: <Object?>[shipmentId.value],
      );
    });

    return ProofOfDeliveryReceipt(
      scanId: scanId,
      signatureMessageId: signatureMessageId,
      statusMessageId: statusMessageId,
      occurredAt: occurredAt,
    );
  }

  /// Encontra a linha do outbox que transporta uma leitura. O `ScanRepository` devolve o `scn_`
  /// mas não o `message_id`, e é o `message_id` que serve de âncora ao `depends_on`.
  Future<String> _messageIdForScan(PrefixedId scanId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT message_id FROM local_outbox
      WHERE operation = ? AND payload_json LIKE ?
      ORDER BY created_at DESC LIMIT 1
      ''',
      <Object?>[OutboxOperation.recordScan.name, '%${scanId.value}%'],
    );
    if (rows.isEmpty) {
      throw StateError('leitura ${scanId.value} não foi enfileirada');
    }
    return rows.first['message_id']! as String;
  }

  /// A entrega já saiu toda do telemóvel? O ecrã de confirmação usa isto para dizer ao condutor
  /// se pode desligar os dados ou se ainda tem coisas por enviar.
  Future<bool> isFullySynced(PrefixedId shipmentId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT count(*) AS c FROM local_outbox
      WHERE published_at IS NULL AND payload_json LIKE ?
      ''',
      <Object?>['%${shipmentId.value}%'],
    );
    return (rows.first['c']! as int) == 0;
  }
}
