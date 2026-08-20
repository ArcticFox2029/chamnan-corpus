// Copyright (c) 2026 ORBITALFREIGHT Holdings B.V.
// Uso interno. Distribuição sujeita ao acordo de licença do repositório.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';

import '../core/ids/prefixed_id.dart';
import '../features/route/data/route_repository.dart';
import '../sync/sync_engine.dart';

/// Recebe as notificações do notification-service e transforma-as em algo visível na cabina.
/// Cada mensagem traz o envelope de §0.7 nos `data`, portanto sabemos sempre o `event_name`, o
/// `event_id` e o `partition_key` — e é o `event_id` que garante que uma reentrega não produz
/// duas notificações (o notification-service tem `UNIQUE (source_event_id, channel,
/// recipient_user_id)` mas o push em si é entregue à mesma mais do que uma vez).
///
/// Algumas mensagens não são para mostrar, são para agir: um `route.replanned` desta expedição
/// faz a app ir buscar a versão nova em silêncio, para o condutor não abrir o ecrã e ver a rota
/// antiga.
class AlertInbox {
  AlertInbox({
    required Database db,
    required SyncEngine sync,
    required RouteRepository routes,
    FlutterLocalNotificationsPlugin? local,
  })  : _db = db,
        _sync = sync,
        _routes = routes,
        _local = local ?? FlutterLocalNotificationsPlugin();

  final Database _db;
  final SyncEngine _sync;
  final RouteRepository _routes;
  final FlutterLocalNotificationsPlugin _local;

  final Set<String> _seenEventIds = <String>{};

  /// Canal Android dedicado. O alerta de sensor tem de furar o modo "não incomodar": uma
  /// excursão de temperatura num contentor reefer é uma carga a estragar-se em tempo real.
  static const AndroidNotificationDetails _criticalChannel = AndroidNotificationDetails(
    'of_driver_critical',
    'Alertas de carga',
    importance: Importance.max,
    priority: Priority.high,
  );

  static const AndroidNotificationDetails _normalChannel = AndroidNotificationDetails(
    'of_driver_updates',
    'Atualizações de entregas',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  Future<void> attach() async {
    await _local.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    FirebaseMessaging.onMessage.listen(handle);
    FirebaseMessaging.onMessageOpenedApp.listen(handle);
  }

  /// Trata uma mensagem. Público porque o teste de instrumentação chama-o diretamente com
  /// envelopes construídos à mão — não há forma sensata de simular o FCM.
  Future<void> handle(RemoteMessage message) async {
    final envelope = message.data;
    final eventId = envelope['event_id'];
    final eventName = envelope['event_name'];
    if (eventId == null || eventName == null) return;

    // Idempotência em `event_id`, como manda a regra 1 de §4.19. O conjunto em memória chega:
    // uma reentrega acontece dentro de minutos, não de dias.
    if (!_seenEventIds.add(eventId)) return;

    final payload = envelope['payload'] == null
        ? const <String, Object?>{}
        : jsonDecode(envelope['payload']!) as Map<String, Object?>;

    switch (eventName) {
      case 'fleet.assignment.created':
        await _sync.flush();
        await _show(
          title: 'Nova entrega atribuída',
          body: 'Abra a app para ver a rota.',
          critical: false,
        );

      case 'fleet.assignment.released':
        await _sync.flush();
        await _show(
          title: 'Entrega retirada',
          body: 'Uma das suas entregas deixou de estar atribuída a si.',
          critical: false,
        );

      case 'telemetry.alert.raised':
        // `severity` vem de `telemetry.telemetry_alerts.severity`, 1 a 5. Acima de 3 o
        // container-registry costuma pôr a expedição em `at_risk` (o corte exato é o
        // `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` dele), e nessa altura o condutor tem de parar.
        final severity = (payload['severity'] as num?)?.toInt() ?? 1;
        await _show(
          title: 'Alerta na carga (${payload['rule_code']})',
          body: severity >= 4
              ? 'Pare em segurança e verifique o contentor.'
              : 'Verifique o contentor na próxima paragem.',
          critical: severity >= 4,
        );

      case 'shipment.status.changed':
        await _applyStatusLocally(payload);

      case 'route.replanned':
        await _applyReplan(payload);
    }
  }

  /// Atualiza o espelho local sem esperar pela sincronização. O evento traz `to_status`, que é
  /// exatamente a coluna que a lista de entregas mostra.
  Future<void> _applyStatusLocally(Map<String, Object?> payload) async {
    final shipmentId = payload['shipment_id'] as String?;
    final toStatus = payload['to_status'] as String?;
    if (shipmentId == null || toStatus == null) return;

    await _db.update(
      'local_assignments',
      <String, Object?>{'shipment_status': toStatus},
      where: 'shipment_id = ?',
      whereArgs: <Object?>[shipmentId],
    );

    if (toStatus == 'held_at_customs') {
      await _show(
        title: 'Expedição retida na alfândega',
        body: 'Não avance sem indicação do despachante.',
        critical: true,
      );
    }
  }

  /// Vai buscar a rota nova. O evento traz `route_id` e `legs_changed`; só avisamos o condutor se
  /// algum troço mudou mesmo — um replaneamento que só mexeu em troços marítimos futuros não lhe
  /// interessa nada.
  Future<void> _applyReplan(Map<String, Object?> payload) async {
    final routeId = payload['route_id'] as String?;
    if (routeId == null) return;

    await _routes.readRoute(PrefixedId.parse(IdPrefix.route, routeId));

    final changed = (payload['legs_changed'] as List<Object?>? ?? const <Object?>[]).length;
    if (changed > 0) {
      await _show(
        title: 'A rota foi alterada',
        body: '$changed troço(s) mudaram. Confirme o próximo destino.',
        critical: false,
      );
    }
  }

  Future<void> _show({
    required String title,
    required String body,
    required bool critical,
  }) async {
    await _local.show(
      // O id tem de caber num inteiro de 32 bits; o instante em milissegundos não cabe.
      DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      title,
      body,
      NotificationDetails(
        android: critical ? _criticalChannel : _normalChannel,
        iOS: DarwinNotificationDetails(
          interruptionLevel:
              critical ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
        ),
      ),
    );
  }
}
