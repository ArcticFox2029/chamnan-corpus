/// Tudo o que a app faz contra o identity-service: trocar credenciais por um par de tokens,
/// rodar o refresh antes de o acesso expirar e revogar a sessão quando o condutor sai.
/// É o único ficheiro autorizado a chamar `/v1/auth/*`.
///
/// Detalhe importante: a app precisa de saber o seu próprio `drv_…` e não existe em §3.2 nenhum
/// endpoint no fleet-service que traduza `usr_` para `drv_`. O identity-service acrescenta a
/// claim `drv` ao token quando o utilizador tem linha em `fleet.drivers`; lemos essa claim do
/// corpo do JWT sem verificar assinatura — a verificação é do lado do serviço, aqui só
/// desempacotamos o que já nos foi dado.
library;

import 'dart:convert';

import '../../../core/ids/prefixed_id.dart';
import '../../../core/network/error_envelope.dart';
import '../../../core/network/of_api_client.dart';
import '../../../core/network/of_session.dart';

/// Resultado de uma tentativa de entrada. O `mfaRequired` existe porque o identity-service
/// responde `401` com `code = 'mfa_required'` na primeira volta e espera o mesmo pedido outra vez
/// com o campo `mfa_code` preenchido.
enum SignInOutcome { granted, mfaRequired, rejected, offline }

class IdentityRepository {
  IdentityRepository({required OfApiClient api, required OfSession session})
      : _api = api,
        _session = session;

  final OfApiClient _api;
  final OfSession _session;

  /// `POST /v1/auth/token`. Vai marcado como anónimo porque é o único pedido da app que não pode
  /// levar `Authorization` — ainda não há token nenhum para pôr lá.
  Future<SignInOutcome> signIn({
    required String email,
    required String password,
    String? mfaCode,
  }) async {
    try {
      final body = await _api.postJson(
        '/v1/auth/token',
        <String, Object?>{
          'grant_type': 'password',
          'email': email,
          'password': password,
          if (mfaCode != null) 'mfa_code': mfaCode,
          // O identity-service usa isto para escolher o TTL e para carimbar
          // `identity.sessions.user_agent`, que é o que aparece na consola do despachante.
          'client': 'driver-app',
        },
        anonymous: true,
      );
      await _adopt(body);
      return SignInOutcome.granted;
    } on OfErrorEnvelope catch (e) {
      if (e.code == 'mfa_required') return SignInOutcome.mfaRequired;
      if (e.code == 'device_offline' || e.code == 'device_network_timeout') {
        return SignInOutcome.offline;
      }
      return SignInOutcome.rejected;
    }
  }

  /// `POST /v1/auth/token/refresh`. Devolve `false` quando a família de refresh foi morta — o
  /// identity-service deteta a reutilização de um token rodado e revoga toda a
  /// `refresh_family_id` de uma vez (`revoked_reason = 'rotation_reuse'`), o que na prática
  /// significa que este dispositivo tem de voltar a fazer login.
  ///
  /// Nunca chamar isto de dois sítios ao mesmo tempo: duas rotações concorrentes com o mesmo
  /// refresh token *são* uma reutilização aos olhos do serviço, e matam a sessão de um condutor
  /// que não fez nada de errado. É por isso que o `_inFlight` existe.
  Future<bool> refreshAccessToken() async {
    final pending = _inFlight;
    if (pending != null) return pending;

    final refresh = _session.refreshToken;
    if (refresh == null) return false;

    final future = _doRefresh(refresh);
    _inFlight = future;
    try {
      return await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<bool>? _inFlight;

  Future<bool> _doRefresh(String refreshToken) async {
    try {
      final body = await _api.postJson(
        '/v1/auth/token/refresh',
        <String, Object?>{'refresh_token': refreshToken},
        anonymous: true,
      );
      await _adopt(body);
      return true;
    } on OfErrorEnvelope catch (e) {
      // Sem rede não deitamos a sessão fora: o condutor continua a trabalhar offline e a fila
      // local continua a encher. Só um `401`/`403` explícito do serviço é motivo para limpar.
      if (e.retryable && !e.isAuthFailure) return false;
      await _session.clear();
      return false;
    }
  }

  /// `POST /v1/auth/token/revoke`. Revoga a família inteira, não só esta sessão: se o condutor
  /// carrega em "terminar sessão" é porque o telemóvel vai mudar de mãos.
  Future<void> signOut() async {
    try {
      await _api.postJson(
        '/v1/auth/token/revoke',
        <String, Object?>{
          'refresh_token': _session.refreshToken,
          'scope': 'family',
        },
      );
    } on OfErrorEnvelope {
      // Falhou por falta de rede: limpamos na mesma. O token de acesso expira em 15 minutos
      // (`OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS`) e o refresh fica inutilizável sem o ficheiro
      // do armazenamento seguro, que é o que acabamos de apagar.
    } finally {
      await _session.clear();
    }
  }

  /// `GET /v1/users/{user_id}/effective-roles`. A app só quer saber uma coisa: se este utilizador
  /// tem mesmo o papel `driver`. Um despachante que faça login aqui por engano vê um ecrã vazio
  /// em vez de uma lista de atribuições que não lhe pertence.
  Future<Set<String>> effectiveRoleCodes() async {
    final body = await _api.getJson('/v1/users/${_session.userId}/effective-roles');
    return (body['items']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((row) => row['code']! as String)
        .toSet();
  }

  Future<void> _adopt(Map<String, Object?> body) async {
    final accessToken = body['access_token']! as String;
    final claims = decodeJwtClaims(accessToken);

    await _session.adopt(
      accessToken: accessToken,
      refreshToken: body['refresh_token']! as String,
      accessExpiresAt: DateTime.now().toUtc().add(
            Duration(seconds: body['expires_in']! as int),
          ),
      tenantId: PrefixedId.parse(IdPrefix.tenant, claims['tid']! as String),
      userId: PrefixedId.parse(IdPrefix.user, claims['sub']! as String),
      driverId: PrefixedId.parse(IdPrefix.driver, claims['drv']! as String),
    );
  }
}

/// Descodifica o payload de um JWT sem verificar a assinatura. A verificação pertence aos
/// serviços — todos eles chamam `identity.v1.TokenIntrospection/Introspect`, e nenhum confia no
/// que um telemóvel lhes diga sobre o próprio token.
Map<String, Object?> decodeJwtClaims(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) {
    throw const FormatException('token não tem as três partes de um JWT');
  }
  final normalised = base64Url.normalize(parts[1]);
  return jsonDecode(utf8.decode(base64Url.decode(normalised))) as Map<String, Object?>;
}
