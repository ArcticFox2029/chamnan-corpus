/// Guarda o par de tokens emitido pelo identity-service e o inquilino a que pertencem, para que
/// o resto da app não tenha de saber nada sobre `Authorization` nem sobre rotação de refresh.
/// O acesso ao disco passa sempre pelo Keychain/Keystore: o refresh token vive 30 dias
/// (`OF_IDENTITY_REFRESH_TOKEN_TTL_DAYS`) e um telemóvel de camião é roubado com frequência
/// suficiente para isso importar.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ids/prefixed_id.dart';

const String _storageKey = 'of.driver.session.v2';

/// Sessão em memória, espelhada no armazenamento seguro. Uma instância por processo.
class OfSession {
  OfSession(this._storage);

  final FlutterSecureStorage _storage;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessExpiresAt;
  PrefixedId? _tenantId;
  PrefixedId? _userId;
  PrefixedId? _driverId;
  String? _lastTraceId;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;

  /// Lança se não houver sessão: quem chama isto já devia ter passado pelo ecrã de entrada.
  PrefixedId get tenantId => _tenantId!;

  /// `usr_…` do condutor. Vai em `freight.shipment_scan_events.scanned_by_user_id` em cada
  /// leitura que a app cria.
  PrefixedId get userId => _userId!;

  /// `drv_…` da linha em `fleet.drivers`. É opcional no esquema (um subcontratado pode nunca ter
  /// login na consola), mas quem usa esta app tem sempre os dois, senão não há atribuições.
  PrefixedId get driverId => _driverId!;

  String? get lastTraceId => _lastTraceId;

  bool get isAuthenticated => _accessToken != null && _tenantId != null;

  /// O token de acesso dura 15 minutos (`OF_IDENTITY_ACCESS_TOKEN_TTL_SECONDS`). Renovamos com
  /// 90 segundos de folga para não apanhar a expiração a meio de um upload de assinatura.
  bool get needsRefresh {
    final expiry = _accessExpiresAt;
    if (expiry == null) return true;
    return DateTime.now().toUtc().isAfter(expiry.subtract(const Duration(seconds: 90)));
  }

  Future<void> restore() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, Object?>;
    _accessToken = json['access_token'] as String?;
    _refreshToken = json['refresh_token'] as String?;
    _accessExpiresAt = DateTime.tryParse(json['access_expires_at'] as String? ?? '');
    _tenantId = json.optionalId('tenant_id', IdPrefix.tenant);
    _userId = json.optionalId('user_id', IdPrefix.user);
    _driverId = json.optionalId('driver_id', IdPrefix.driver);
  }

  Future<void> adopt({
    required String accessToken,
    required String refreshToken,
    required DateTime accessExpiresAt,
    required PrefixedId tenantId,
    required PrefixedId userId,
    required PrefixedId driverId,
  }) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _accessExpiresAt = accessExpiresAt;
    _tenantId = tenantId;
    _userId = userId;
    _driverId = driverId;
    await _persist();
  }

  /// Chamado quando o identity-service responde `401` a uma rotação: a família de refresh foi
  /// morta por reutilização (`revoked_reason = 'rotation_reuse'`) e não há nada a salvar.
  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
    _accessExpiresAt = null;
    _tenantId = null;
    _userId = null;
    _driverId = null;
    await _storage.delete(key: _storageKey);
  }

  void rememberTrace(String traceId) => _lastTraceId = traceId;

  Future<void> _persist() async {
    await _storage.write(
      key: _storageKey,
      value: jsonEncode(<String, Object?>{
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'access_expires_at': _accessExpiresAt?.toIso8601String(),
        'tenant_id': _tenantId?.value,
        'user_id': _userId?.value,
        'driver_id': _driverId?.value,
      }),
    );
  }
}
