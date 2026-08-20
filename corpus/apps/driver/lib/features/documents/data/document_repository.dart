/// Envio de ficheiros para o document-service: assinaturas de comprovativo de entrega e
/// fotografias de dano. Trata das duas metades do problema — calcular o SHA-256 no dispositivo
/// para aproveitar a desduplicação do serviço, e sobreviver a um telemóvel que fica sem rede a
/// meio de um upload de três megabytes.
///
/// Há dois caminhos, de propósito:
///
///  * **Direto** — com rede, `POST /v1/documents` em multipart, tal como está em §3.9. É o
///    caminho de qualquer fotografia: são grandes e não vale a pena passarem pela fila.
///  * **Pela fila** — sem rede, a linha vai para `local_outbox` com o conteúdo embutido. O
///    ingress móvel reembrulha esse corpo em multipart, por isso o document-service continua a
///    ver exatamente o mesmo `POST /v1/documents`. Só é usado abaixo de `signatureMaxBytes`,
///    que é o tamanho de uma assinatura e não o de uma fotografia.
///
/// A ordem importa: o document-service valida o `owner_type` contra
/// `platform.document_owner_types` e **chama o serviço dono para confirmar que o `owner_id`
/// existe** antes de aceitar o ficheiro. Um documento com `owner_type = 'scan'` só é aceite
/// depois de o `scn_` estar mesmo em `freight.shipment_scan_events` — daí a dependência entre
/// linhas do outbox.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/config/driver_environment.dart';
import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/error_envelope.dart';
import '../../../core/network/of_api_client.dart';
import '../../../core/network/of_session.dart';
import '../../../sync/outbox_dao.dart';

/// Valores de `platform.documents.kind` que esta app produz. A lista completa do CHECK tem dez
/// entradas; as outras nascem no customs-service e no billing-service.
enum DocumentKind {
  proofOfDelivery('proof_of_delivery'),
  damagePhoto('damage_photo');

  const DocumentKind(this.wire);

  final String wire;
}

class DocumentRepository {
  DocumentRepository({
    required OfApiClient api,
    required Database db,
    required OutboxDao outbox,
    required OfSession session,
    required DriverEnvironment environment,
  })  : _api = api,
        _db = db,
        _outbox = outbox,
        _session = session,
        _environment = environment;

  final OfApiClient _api;
  final Database _db;
  final OutboxDao _outbox;
  final OfSession _session;
  final DriverEnvironment _environment;

  /// Regista o ficheiro localmente e devolve o `message_id` da linha do outbox, para quem chamar
  /// poder encadear dependências. `ownerId` é sempre o `scn_` da leitura correspondente quando
  /// `ownerType = 'scan'`.
  Future<String> stage({
    required File file,
    required String ownerType,
    required PrefixedId ownerId,
    required DocumentKind kind,
    required String mimeType,
    String? dependsOnMessageId,
  }) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    final localId = PrefixedId.generate(IdPrefix.document).value;

    final metadata = <String, Object?>{
      'local_document_id': localId,
      'owner_type': ownerType,
      'owner_id': ownerId.value,
      'kind': kind.wire,
      'mime_type': mimeType,
      'byte_size': bytes.length,
      // Hexadecimal minúsculo, como no evento `document.uploaded`. A coluna
      // `platform.documents.sha256` é `BYTEA`; a conversão é do lado do serviço.
      'sha256': digest.toString(),
      'region_code': _environment.regionCode,
      'uploaded_by': _session.userId.value,
    };

    late String messageId;
    await _db.transaction((txn) async {
      await txn.insert('local_pending_documents', <String, Object?>{
        'local_document_id': localId,
        'owner_type': ownerType,
        'owner_id': ownerId.value,
        'kind': kind.wire,
        'mime_type': mimeType,
        'file_path': file.path,
        'byte_size': bytes.length,
        'sha256_hex': digest.toString(),
        'captured_at': DateTime.now().toUtc().toIso8601String(),
      });

      messageId = await _outbox.enqueueWithin(
        txn,
        operation: OutboxOperation.uploadDocument,
        method: 'POST',
        path: '/v1/documents',
        payload: <String, Object?>{
          ...metadata,
          if (bytes.length <= _environment.signatureMaxBytes)
            'content_base64': base64Encode(bytes),
        },
        dependsOn: dependsOnMessageId,
      );
    });

    return messageId;
  }

  /// Sobe já, em multipart, sem passar pela fila. Devolve o `doc_` atribuído — ou o que já lá
  /// estava: se outro cliente subiu o mesmo ficheiro para o mesmo dono, o UNIQUE
  /// `(tenant_id, sha256, owner_type, owner_id)` faz o document-service devolver o `doc_`
  /// existente em vez de guardar o blob duas vezes. É o mesmo mecanismo do losango B de §1.2,
  /// onde billing-service e customs-service anexam a mesma fatura comercial.
  Future<PrefixedId?> uploadNow({
    required File file,
    required String ownerType,
    required PrefixedId ownerId,
    required DocumentKind kind,
    required String mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    final idempotencyKey = PrefixedId.generate(IdPrefix.event).value;

    final form = FormData.fromMap(<String, Object?>{
      'owner_type': ownerType,
      'owner_id': ownerId.value,
      'kind': kind.wire,
      'sha256': digest.toString(),
      'region_code': _environment.regionCode,
      'file': MultipartFile.fromBytes(
        bytes,
        filename: file.uri.pathSegments.last,
        contentType: DioMediaType.parse(mimeType),
      ),
    });

    try {
      final body = await _api.postMultipart(
        '/v1/documents',
        form,
        idempotencyKey: idempotencyKey,
        onSendProgress: onProgress,
      );
      final documentId = PrefixedId.parse(IdPrefix.document, body['document_id']! as String);
      await _markUploaded(digest.toString(), documentId);
      return documentId;
    } on OfErrorEnvelope catch (e) {
      // `owner_not_found` acontece quando a leitura ainda não chegou ao container-registry.
      // Não é erro nosso e não é definitivo: fica para a fila, que respeita a dependência.
      if (e.retryable || e.code == 'owner_not_found') return null;
      rethrow;
    }
  }

  Future<void> _markUploaded(String sha256Hex, PrefixedId documentId) async {
    await _db.update(
      'local_pending_documents',
      <String, Object?>{
        'document_id': documentId.value,
        'uploaded_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'sha256_hex = ? AND uploaded_at IS NULL',
      whereArgs: <Object?>[sha256Hex],
    );
  }

  /// Ficheiros grandes que ficaram à espera de rede — tipicamente fotografias de dano tiradas
  /// num parque sem cobertura. Chamado quando a conectividade volta.
  Future<int> flushOversizedPending() async {
    final rows = await _db.query(
      'local_pending_documents',
      where: 'uploaded_at IS NULL AND byte_size > ?',
      whereArgs: <Object?>[_environment.signatureMaxBytes],
      orderBy: 'captured_at ASC',
    );

    var sent = 0;
    for (final row in rows) {
      final file = File(row['file_path']! as String);
      if (!file.existsSync()) continue;
      final documentId = await uploadNow(
        file: file,
        ownerType: row['owner_type']! as String,
        ownerId: PrefixedId.parse(IdPrefix.scan, row['owner_id']! as String),
        kind: DocumentKind.values.firstWhere((k) => k.wire == row['kind']),
        mimeType: row['mime_type']! as String,
      );
      if (documentId != null) sent++;
    }
    return sent;
  }

  /// `GET /v1/documents?owner_type=&owner_id=&kind=`. Serve para o condutor confirmar que a
  /// assinatura da entrega de ontem chegou mesmo lá — a pergunta mais frequente do suporte.
  Future<List<Map<String, Object?>>> documentsForScan(PrefixedId scanId) async {
    final body = await _api.getJson('/v1/documents', query: <String, Object?>{
      'owner_type': 'scan',
      'owner_id': scanId.value,
    });
    return (body['items']! as List<Object?>).cast<Map<String, Object?>>();
  }
}
