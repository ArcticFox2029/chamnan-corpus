// Copyright (c) 2026 ORBITALFREIGHT Holdings B.V.
// Uso interno. Distribuição sujeita ao acordo de licença do repositório.

import 'package:dio/dio.dart';

/// Tradução do envelope de erro de §0.4 para um objeto que a app consegue usar em decisões.
/// Interessam-nos três coisas de cada falha: o `code` (estável e parte do contrato público, por
/// isso é seguro fazer `switch` sobre ele), o `retryable` (decide se a linha volta para a fila do
/// outbox ou se vai para o ecrã do condutor) e o `trace_id` (é o que o despachante pede ao
/// suporte quando liga a reclamar).
class OfErrorEnvelope implements Exception {
  const OfErrorEnvelope({
    required this.code,
    required this.httpStatus,
    required this.message,
    required this.retryable,
    this.traceId,
    this.fields = const <OfFieldError>[],
  });

  /// Constrói a partir do corpo já desserializado. Um corpo que não siga §0.4 — tipicamente uma
  /// página HTML do ingress durante um deploy — cai no `unexpected` com `retryable: true`,
  /// porque é quase sempre transitório.
  factory OfErrorEnvelope.fromJson(Map<String, Object?> body, int status) {
    final error = body['error'];
    if (error is! Map<String, Object?>) {
      return OfErrorEnvelope(
        code: 'unexpected',
        httpStatus: status,
        message: 'resposta fora do envelope de §0.4',
        retryable: status >= 500,
      );
    }
    return OfErrorEnvelope(
      code: error['code'] as String? ?? 'unexpected',
      httpStatus: error['http_status'] as int? ?? status,
      message: error['message'] as String? ?? '',
      retryable: error['retryable'] as bool? ?? false,
      traceId: error['trace_id'] as String?,
      fields: (error['fields'] as List<Object?>? ?? const <Object?>[])
          .cast<Map<String, Object?>>()
          .map(OfFieldError.fromJson)
          .toList(growable: false),
    );
  }

  /// Converte uma exceção do Dio. Timeouts e falhas de socket não têm envelope nenhum — o pedido
  /// nem chegou a um serviço — mas são exatamente o caso normal desta app, por isso ganham um
  /// código sintético e `retryable: true`.
  factory OfErrorEnvelope.fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, Object?>) {
      return OfErrorEnvelope.fromJson(data, e.response?.statusCode ?? 0);
    }
    return OfErrorEnvelope(
      code: switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'device_network_timeout',
        DioExceptionType.connectionError => 'device_offline',
        DioExceptionType.badCertificate => 'device_tls_rejected',
        _ => 'unexpected',
      },
      httpStatus: e.response?.statusCode ?? 0,
      message: e.message ?? 'falha de rede no dispositivo',
      // O certificado inválido é o único que não vale a pena repetir: ou é MITM numa rede de
      // hotel, ou é um telemóvel com a data trocada. Nos dois casos, insistir não resolve.
      retryable: e.type != DioExceptionType.badCertificate,
    );
  }

  final String code;
  final int httpStatus;
  final String message;
  final bool retryable;
  final String? traceId;
  final List<OfFieldError> fields;

  /// O token expirou ou a sessão foi revogada em `POST /v1/auth/token/revoke`. O interceptor de
  /// autenticação tenta uma rotação antes de deixar o erro subir até aqui.
  bool get isAuthFailure => httpStatus == 401;

  /// `X-OF-Tenant` não bate certo com a claim `tid` (§0.3). Nunca é culpa do condutor: significa
  /// que o dispositivo ficou com credenciais de outro inquilino em cache.
  bool get isTenantMismatch => httpStatus == 403 && code == 'tenant_mismatch';

  /// Conflitos que a app sabe explicar em português ao condutor em vez de mostrar o `message`
  /// cru do serviço. `shipment_already_sealed` vem do container-registry quando se tenta anexar
  /// um contentor a uma expedição já em `sealed`.
  bool get isExplainableConflict => const <String>{
        'shipment_already_sealed',
        'assignment_overlaps_active_period',
        'driver_licence_expired',
        'hours_of_service_exceeded',
        'declaration_not_cleared',
      }.contains(code);

  @override
  String toString() => 'OfErrorEnvelope($code, http=$httpStatus, trace=$traceId)';
}

/// Uma entrada de `error.fields[]`: o caminho do campo rejeitado e a razão.
class OfFieldError {
  const OfFieldError({required this.path, required this.reason});

  factory OfFieldError.fromJson(Map<String, Object?> json) => OfFieldError(
        path: json['path']! as String,
        reason: json['reason']! as String,
      );

  /// Caminho no corpo do pedido, com índices: `containers[0].seal_number`.
  final String path;

  /// Motivo estável, por exemplo `immutable` ou `out_of_range`.
  final String reason;
}
