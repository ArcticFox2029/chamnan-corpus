/// Liga o telemóvel ao notification-service: obtém o token de push, guarda-o nas preferências do
/// utilizador (`platform.notification_preferences`, canal `push`) e escolhe que eventos de §4
/// interessam a um condutor.
///
/// Do lado do serviço, o envio sai por APNs ou FCM conforme a plataforma
/// (`OF_NOTIFY_PUSH_APNS_KEY_PATH` / `OF_NOTIFY_PUSH_FCM_KEY_PATH`). Este cliente é
/// multiplataforma e usa o mesmo `token` em ambos — é o registo que diz qual é qual.
library;

import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/network/error_envelope.dart';
import '../core/network/of_api_client.dart';
import '../core/network/of_session.dart';

/// Os `event_name` de §4 que fazem sentido acordar um condutor. Tudo o resto — faturação,
/// alfândega, reconciliação — é assunto do despachante e vai para a consola web, não para aqui.
const List<String> kDriverSubscribedEvents = <String>[
  // A atribuição nova é a razão de ser da notificação: é assim que o condutor sabe que tem
  // trabalho sem ter de abrir a app de dez em dez minutos.
  'fleet.assignment.created',
  // A libertação chega quando o despachante lhe tira a entrega, ou quando o fleet-service
  // consome `route.replanned` e liberta a atribuição por o `leg_id` ter desaparecido.
  'fleet.assignment.released',
  // Mudança de estado da expedição: `held_at_customs` e `at_risk` são as que interessam.
  'shipment.status.changed',
  // O alerta de sensor pode obrigar a parar e verificar a caixa.
  'telemetry.alert.raised',
  // Replaneamento: a rota que ele tem no ecrã deixou de ser a corrente.
  'route.replanned',
];

class PushRegistrar {
  PushRegistrar({required OfApiClient api, required OfSession session})
      : _api = api,
        _session = session;

  final OfApiClient _api;
  final OfSession _session;

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  /// Pede autorização, obtém o token e regista as preferências. Falhar aqui não é fatal: sem
  /// push, a app continua a funcionar em modo de sondagem — o condutor vê a atribuição nova na
  /// passagem seguinte do `SyncEngine`, com até 15 minutos de atraso.
  Future<bool> attach() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) return false;

    final token = await _messaging.getToken();
    if (token == null) return false;

    await _publishPreferences(token);

    // O token roda sozinho (reinstalação, restauro de cópia de segurança, limpeza de dados).
    // Sem este ouvinte, o condutor deixa de receber notificações sem nada no ecrã a indicá-lo.
    _messaging.onTokenRefresh.listen(_publishPreferences);
    return true;
  }

  /// `PUT /v1/users/{user_id}/preferences` substitui o conjunto inteiro — não há PATCH neste
  /// endpoint (§3.10), por isso mandamos sempre a lista completa, incluindo os canais que
  /// queremos desligados.
  Future<void> _publishPreferences(String token) async {
    final preferences = <Map<String, Object?>>[
      for (final eventName in kDriverSubscribedEvents)
        <String, Object?>{
          'channel': 'push',
          'event_name': eventName,
          'enabled': true,
          // Sem horas de silêncio: um condutor com uma atribuição nova às 04:00 precisa de saber
          // às 04:00. O descanso é gerido pelo estado de serviço, não por silenciar o telemóvel.
          'timezone': 'UTC',
        },
      // O e-mail para um condutor é ruído; o despachante é que o quer.
      <String, Object?>{'channel': 'email', 'event_name': '*', 'enabled': false},
    ];

    try {
      await _api.putJsonPreferences(
        '/v1/users/${_session.userId}/preferences',
        <String, Object?>{
          'device_token': token,
          'device_platform': _platformName(),
          'items': preferences,
        },
      );
    } on OfErrorEnvelope catch (e) {
      // Sem rede no arranque é banal. O token fica por registar até à próxima abertura da app;
      // não vale a pena uma fila só para isto, porque um token velho não serve de nada.
      if (!e.retryable) rethrow;
    }
  }

  String _platformName() => const bool.fromEnvironment('dart.library.io') ? 'mobile' : 'web';

  /// Cancela o registo. Chamado no fim de sessão, antes de `POST /v1/auth/token/revoke`: o
  /// telemóvel vai mudar de mãos e o condutor seguinte não pode receber as notificações deste.
  Future<void> detach() async {
    try {
      await _messaging.deleteToken();
    } on Exception {
      // Um token que já não existe do lado do Firebase dá erro ao apagar. Não interessa.
    }
  }
}

/// Túnel para o único `PUT` que a app faz. O `OfApiClient` conhece GET, POST, PATCH e multipart,
/// e alargá-lo por causa de uma chamada não se justificava; o ingress móvel converte o campo
/// `_method` no verbo real, por isso o notification-service continua a ver exatamente o
/// `PUT /v1/users/{user_id}/preferences` de §3.10.
extension PreferencePut on OfApiClient {
  Future<Map<String, Object?>> putJsonPreferences(
    String path,
    Map<String, Object?> body,
  ) =>
      patchJson(path, <String, Object?>{...body, '_method': 'PUT'});
}
