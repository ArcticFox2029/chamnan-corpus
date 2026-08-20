/// Põe os cinco cabeçalhos obrigatórios de §0.3 em cada pedido que sai do telemóvel:
/// `Authorization`, `X-OF-Tenant`, `X-OF-Trace-Id`, `X-OF-Idempotency-Key` e `X-OF-Actor-Kind`.
/// Nenhum repositório desta app monta cabeçalhos à mão — se um pedido sair sem `X-OF-Tenant`,
/// o identity-service devolve `403` e a culpa é deste ficheiro.
library;

import 'dart:math';

import 'package:dio/dio.dart';

import '../ids/prefixed_id.dart';
import 'of_session.dart';

/// Chave usada nos `extra` do Dio para reaproveitar uma chave de idempotência entre tentativas.
/// É crítica: §7 regra 5 diz que o serviço guarda o resultado por 24 horas contra a mesma
/// `X-OF-Idempotency-Key`, portanto reenviar a *mesma* leitura com uma chave nova cria uma
/// segunda linha em `freight.shipment_scan_events` em vez de devolver a primeira.
const String kIdempotencyKeyExtra = 'of.idempotency_key';

/// Chave de `extra` para pedidos que podem seguir sem sessão (só `POST /v1/auth/token`).
const String kAnonymousExtra = 'of.anonymous';

class OfHeadersInterceptor extends Interceptor {
  OfHeadersInterceptor({
    required OfSession session,
    required String userAgentSuffix,
    Random? random,
  })  : _session = session,
        _userAgentSuffix = userAgentSuffix,
        _random = random ?? Random.secure();

  final OfSession _session;
  final String _userAgentSuffix;
  final Random _random;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final anonymous = options.extra[kAnonymousExtra] == true;

    if (!anonymous) {
      final token = _session.accessToken;
      if (token == null) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            message: 'sem sessão ativa; o pedido não chega a sair do dispositivo',
          ),
        );
        return;
      }
      options.headers['Authorization'] = 'Bearer $token';
      // Tem de bater certo com a claim `tid` do próprio token, senão é rejeitado com 403.
      options.headers['X-OF-Tenant'] = _session.tenantId.value;
    }

    // O condutor autentica-se como pessoa. `device` fica reservado para os gateways de `edge/`,
    // que assinam os lotes com a chave Ed25519 de telemetry.device_gateways.
    options.headers['X-OF-Actor-Kind'] = 'user';
    options.headers['X-OF-Trace-Id'] = _newTraceId();
    options.headers['User-Agent'] = _userAgentSuffix;

    final method = options.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      final key = options.extra[kIdempotencyKeyExtra] as String? ??
          PrefixedId.generate(IdPrefix.event).value;
      options.extra[kIdempotencyKeyExtra] = key;
      options.headers['X-OF-Idempotency-Key'] = key;
    }

    handler.next(options);
  }

  @override
  void onResponse(Response<Object?> response, ResponseInterceptorHandler handler) {
    // O ingress carimba o trace que gerou quando o nosso cabeçalho se perde; guardamos o último
    // para o painel de diagnóstico e para o ecrã "reportar problema".
    final echoed = response.headers.value('X-OF-Trace-Id');
    if (echoed != null) {
      _session.rememberTrace(echoed);
    }
    handler.next(response);
  }

  /// Trace-id do W3C: 32 hexadecimais, tudo-a-zero é inválido. Geramos no dispositivo porque a
  /// cadeia começa aqui — o mesmo valor aparece depois nos registos de fleet-service,
  /// container-registry e document-service para a mesma entrega.
  String _newTraceId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write('0123456789abcdef'[_random.nextInt(16)]);
    }
    final trace = buffer.toString();
    return trace == '0' * 32 ? _newTraceId() : trace;
  }
}
