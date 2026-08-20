/// Acesso à fila de escrita local (`local_outbox`). Toda a mutação que a app faz — uma leitura,
/// uma mudança de estado de serviço, um documento — entra primeiro aqui, na mesma transação em
/// que o estado local muda, e só depois é que alguém tenta a rede.
///
/// É a mesma ideia do `platform.outbox_messages` de §2.8 aplicada ao telemóvel, e pela mesma
/// razão: mudar o ecrã e falar com o container-registry não podem falhar de forma independente.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/ids/prefixed_id.dart';

/// O que a linha da fila pede ao mundo. O nome é local — não é um `event_name` de §4 — mas
/// mapeia um para um num pedido de §3.
enum OutboxOperation {
  /// `POST /v1/containers/{container_id}/scans` no container-registry.
  recordScan('container-registry'),

  /// `POST /v1/documents` no document-service (assinatura, fotografia de dano).
  uploadDocument('document-service'),

  /// `POST /v1/drivers/{driver_id}/hours-of-service` no fleet-service.
  appendDutyStatus('fleet-service'),

  /// `PATCH /v1/shipments/{shipment_id}/status` no container-registry. Só é usado para a
  /// transição para `delivered`, e só depois de o comprovativo estar confirmado.
  changeShipmentStatus('container-registry');

  const OutboxOperation(this.targetService);

  /// Nome do serviço tal como aparece em §1 do SPEC. Vai para a coluna `target_service` e é o
  /// que o painel de diagnóstico mostra ao condutor.
  final String targetService;
}

/// Uma linha da fila, já pronta a enviar.
class OutboxMessage {
  const OutboxMessage({
    required this.messageId,
    required this.operation,
    required this.method,
    required this.path,
    required this.payload,
    required this.createdAt,
    required this.attempts,
    this.dependsOn,
    this.lastError,
  });

  factory OutboxMessage.fromRow(Map<String, Object?> row) => OutboxMessage(
        messageId: row['message_id']! as String,
        operation: OutboxOperation.values.byName(row['operation']! as String),
        method: row['http_method']! as String,
        path: row['path']! as String,
        payload: jsonDecode(row['payload_json']! as String) as Map<String, Object?>,
        createdAt: DateTime.parse(row['created_at']! as String),
        attempts: row['attempts']! as int,
        dependsOn: row['depends_on'] as String?,
        lastError: row['last_error'] as String?,
      );

  /// `evt_…`. É também a `X-OF-Idempotency-Key` do pedido: a mesma linha reenviada traz sempre a
  /// mesma chave, que é o que torna a retentativa inofensiva (§7 regra 5).
  final String messageId;
  final OutboxOperation operation;
  final String method;
  final String path;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final int attempts;

  /// Dependência dentro da própria fila. A assinatura do comprovativo depende da leitura
  /// `proof_of_delivery` que lhe dá o `owner_id`, porque o document-service confirma o `scn_`
  /// junto do container-registry antes de aceitar o ficheiro.
  final String? dependsOn;

  final String? lastError;
}

class OutboxDao {
  OutboxDao(this._db);

  final Database _db;

  /// Enfileira dentro de uma transação já aberta pelo repositório que também escreveu o estado
  /// local. Não abre transação própria de propósito — é esse acoplamento que garante a atomicidade.
  Future<String> enqueueWithin(
    Transaction txn, {
    required OutboxOperation operation,
    required String method,
    required String path,
    required Map<String, Object?> payload,
    String? dependsOn,
    DateTime? notBefore,
  }) async {
    final messageId = PrefixedId.generate(IdPrefix.event).value;
    await txn.insert('local_outbox', <String, Object?>{
      'message_id': messageId,
      'operation': operation.name,
      'target_service': operation.targetService,
      'http_method': method,
      'path': path,
      'payload_json': jsonEncode(payload),
      'depends_on': dependsOn,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'attempts': 0,
      'next_attempt_at': (notBefore ?? DateTime.now().toUtc()).toIso8601String(),
    });
    return messageId;
  }

  /// Lote pronto a enviar: nada agendado para o futuro, e nada cuja dependência ainda não tenha
  /// sido publicada. A ordenação é por `created_at` porque o ULID do `message_id` já é monotónico
  /// e queremos a ordem em que o condutor fez as coisas.
  Future<List<OutboxMessage>> dueBatch({int limit = 25}) async {
    final rows = await _db.rawQuery(
      '''
      SELECT o.* FROM local_outbox o
      LEFT JOIN local_outbox dep ON dep.message_id = o.depends_on
      WHERE o.published_at IS NULL
        AND o.next_attempt_at <= ?
        AND (o.depends_on IS NULL OR dep.published_at IS NOT NULL)
      ORDER BY o.created_at ASC
      LIMIT ?
      ''',
      <Object?>[DateTime.now().toUtc().toIso8601String(), limit],
    );
    return rows.map(OutboxMessage.fromRow).toList(growable: false);
  }

  Future<void> markPublished(String messageId) async {
    await _db.update(
      'local_outbox',
      <String, Object?>{'published_at': DateTime.now().toUtc().toIso8601String()},
      where: 'message_id = ?',
      whereArgs: <Object?>[messageId],
    );
  }

  /// Recuo exponencial a começar em 500 ms, como manda a regra 4 de §4.19 para as filas do lado
  /// do servidor. Tetamos em 15 minutos porque o condutor pode passar uma tarde inteira num
  /// terminal sem cobertura e não vale a pena acordar o rádio de dois em dois segundos.
  Future<void> markFailed(String messageId, int attempts, String reason) async {
    final delayMs = (500 * (1 << attempts.clamp(0, 11))).clamp(500, 900000);
    await _db.update(
      'local_outbox',
      <String, Object?>{
        'attempts': attempts + 1,
        'last_error': reason,
        'next_attempt_at': DateTime.now()
            .toUtc()
            .add(Duration(milliseconds: delayMs))
            .toIso8601String(),
      },
      where: 'message_id = ?',
      whereArgs: <Object?>[messageId],
    );
  }

  /// Descarta uma linha que o serviço rejeitou de forma definitiva (`retryable: false`). Fica
  /// registada como publicada com o erro, para o painel de diagnóstico continuar a mostrá-la ao
  /// condutor em vez de a fazer desaparecer sem explicação.
  Future<void> discard(String messageId, String reason) async {
    await _db.update(
      'local_outbox',
      <String, Object?>{
        'published_at': DateTime.now().toUtc().toIso8601String(),
        'last_error': reason,
      },
      where: 'message_id = ?',
      whereArgs: <Object?>[messageId],
    );
  }

  /// Quantas linhas continuam por enviar. É o número do crachá no canto do ecrã principal.
  Future<int> pendingCount() async {
    final result = await _db.rawQuery(
      'SELECT count(*) AS c FROM local_outbox WHERE published_at IS NULL',
    );
    return result.first['c']! as int;
  }

  /// Linhas que já esgotaram as tentativas configuradas. O equivalente ao `<topic>.dlq` de
  /// §4.19, exceto que aqui não há tópico nenhum — há um condutor a quem perguntar.
  Future<List<OutboxMessage>> poisoned(int maxAttempts) async {
    final rows = await _db.query(
      'local_outbox',
      where: 'published_at IS NULL AND attempts >= ?',
      whereArgs: <Object?>[maxAttempts],
      orderBy: 'created_at ASC',
    );
    return rows.map(OutboxMessage.fromRow).toList(growable: false);
  }
}
