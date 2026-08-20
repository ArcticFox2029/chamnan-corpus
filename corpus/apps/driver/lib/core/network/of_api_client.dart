/// Cliente HTTP único da app. Monta o Dio contra o ingress móvel, encadeia os interceptores de
/// cabeçalhos e de renovação de token, e traduz tudo o que corre mal para `OfErrorEnvelope`.
///
/// Só fala com serviços que a app tem direito a chamar: identity-service, fleet-service,
/// container-registry, routing-service, document-service e notification-service. geo-service e
/// audit-ledger não estão nessa lista de propósito — são folhas internas do cluster (§1.2) e o
/// que precisamos deles chega-nos pela mão de outro serviço.
library;

import 'package:dio/dio.dart';

import '../config/driver_environment.dart';
import 'error_envelope.dart';
import 'of_headers_interceptor.dart';
import 'of_session.dart';

/// Assinatura da função que renova o token; injetada para não criar uma dependência circular
/// entre este ficheiro e o `IdentityRepository`.
typedef TokenRefresher = Future<bool> Function();

/// Resposta paginada de §0.5. Só existe cursor — não há `offset` em lado nenhum da plataforma.
class OfPage<T> {
  const OfPage({required this.items, required this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

class OfApiClient {
  OfApiClient({
    required DriverEnvironment environment,
    required OfSession session,
    Dio? dio,
  })  : _environment = environment,
        _session = session,
        _dio = dio ?? Dio() {
    _dio.options = BaseOptions(
      baseUrl: environment.gatewayBaseUrl.toString(),
      connectTimeout: environment.requestTimeout,
      receiveTimeout: environment.requestTimeout,
      sendTimeout: environment.requestTimeout,
      contentType: Headers.jsonContentType,
      // Deixamos passar tudo e decidimos aqui: um 409 do container-registry é informação, não
      // uma exceção a rebentar no meio do ecrã de leitura.
      validateStatus: (status) => status != null && status < 600,
    );
    _dio.interceptors.add(
      OfHeadersInterceptor(
        session: session,
        userAgentSuffix: environment.userAgentSuffix,
      ),
    );
  }

  final DriverEnvironment _environment;
  final OfSession _session;
  final Dio _dio;

  TokenRefresher? _refresher;

  /// Ligado uma vez no arranque pelo `ServiceLocator`, depois de o `IdentityRepository` existir.
  set tokenRefresher(TokenRefresher refresher) => _refresher = refresher;

  /// GET simples. `query` já vai com os nomes exatos de §3 (`active`, `shipment_id`, `limit`,
  /// `cursor`) — não há tradução de nomes nesta camada.
  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, Object?> query = const <String, Object?>{},
  }) async {
    final response = await _send(
      () => _dio.get<Object?>(path, queryParameters: _clean(query)),
    );
    return response.data! as Map<String, Object?>;
  }

  /// GET paginado. Aplica o teto de 200 de §0.5 do lado do cliente para não levar um `400` por
  /// causa de um `limit` mal calculado numa lista longa de leituras.
  Future<OfPage<T>> getPage<T>(
    String path,
    T Function(Map<String, Object?>) parse, {
    Map<String, Object?> query = const <String, Object?>{},
    String? cursor,
    int limit = 50,
  }) async {
    final body = await getJson(path, query: <String, Object?>{
      ...query,
      'limit': limit.clamp(1, 200),
      if (cursor != null) 'cursor': cursor,
    });
    return OfPage<T>(
      items: (body['items']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(parse)
          .toList(growable: false),
      nextCursor: body['next_cursor'] as String?,
    );
  }

  /// POST com corpo JSON. `idempotencyKey` deve ser fornecida sempre que o pedido nasceu de uma
  /// linha do outbox local: a mesma linha reenviada tem de trazer a mesma chave, senão duplica
  /// o efeito do lado do serviço.
  Future<Map<String, Object?>> postJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
    bool anonymous = false,
  }) async {
    final response = await _send(
      () => _dio.post<Object?>(
        path,
        data: body,
        options: Options(extra: _extras(idempotencyKey, anonymous)),
      ),
    );
    return (response.data as Map<String, Object?>?) ?? const <String, Object?>{};
  }

  Future<Map<String, Object?>> patchJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final response = await _send(
      () => _dio.patch<Object?>(
        path,
        data: body,
        options: Options(extra: _extras(idempotencyKey, false)),
      ),
    );
    return (response.data as Map<String, Object?>?) ?? const <String, Object?>{};
  }

  /// Envio multipart para `POST /v1/documents`. O document-service valida o `owner_type` contra
  /// `platform.document_owner_types` e confirma o `owner_id` junto do serviço dono antes de
  /// aceitar o ficheiro, por isso a leitura tem de estar sincronizada *antes* de a assinatura ir.
  Future<Map<String, Object?>> postMultipart(
    String path,
    FormData form, {
    required String idempotencyKey,
    ProgressCallback? onSendProgress,
  }) async {
    final response = await _send(
      () => _dio.post<Object?>(
        path,
        data: form,
        onSendProgress: onSendProgress,
        options: Options(
          contentType: 'multipart/form-data',
          extra: _extras(idempotencyKey, false),
          // Uma fotografia de dano em 4G rural demora mais do que a fatia normal.
          sendTimeout: _environment.requestTimeout * 4,
        ),
      ),
    );
    return response.data! as Map<String, Object?>;
  }

  /// Núcleo comum: executa, renova o token uma única vez em caso de `401` e converte qualquer
  /// falha para o envelope de §0.4.
  Future<Response<Object?>> _send(
    Future<Response<Object?>> Function() call, {
    bool allowRetryAfterRefresh = true,
  }) async {
    try {
      if (_session.needsRefresh && _refresher != null) {
        await _refresher!.call();
      }
      final response = await call();
      final status = response.statusCode ?? 0;
      if (status >= 200 && status < 300) {
        return response;
      }

      final envelope = OfErrorEnvelope.fromJson(
        (response.data as Map<String, Object?>?) ?? const <String, Object?>{},
        status,
      );

      if (envelope.isAuthFailure && allowRetryAfterRefresh && _refresher != null) {
        final refreshed = await _refresher!.call();
        if (refreshed) {
          return _send(call, allowRetryAfterRefresh: false);
        }
      }
      throw envelope;
    } on DioException catch (e) {
      throw OfErrorEnvelope.fromDio(e);
    }
  }

  Map<String, Object?> _extras(String? idempotencyKey, bool anonymous) => <String, Object?>{
        if (idempotencyKey != null) kIdempotencyKeyExtra: idempotencyKey,
        if (anonymous) kAnonymousExtra: true,
      };

  Map<String, Object?> _clean(Map<String, Object?> query) =>
      Map<String, Object?>.fromEntries(query.entries.where((e) => e.value != null));
}
