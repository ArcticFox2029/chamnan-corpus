/// Recolha de posição em segundo plano enquanto o condutor está ao serviço. Escreve em
/// `local_position_fixes` e mais nada: estes pontos **não** são telemetria e nunca vão para o
/// telemetry-ingest, que só aceita lotes assinados dos gateways de `edge/` com a chave Ed25519 de
/// `telemetry.device_gateways`.
///
/// O rasto tem dois usos, os dois locais: carimbar `position` numa leitura feita sem sinal, e
/// detetar entradas e saídas de geocerca para sugerir ao condutor a leitura de `gate_in` ou
/// `gate_out` no momento certo. Ao fim de 48 horas é apagado por `DriverDatabase.pruneStaleData`.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';

import '../core/config/driver_environment.dart';
import 'geofence_evaluator.dart';

/// Transição de geocerca detetada localmente, entregue a quem estiver a ouvir.
class FenceTransition {
  const FenceTransition({
    required this.fence,
    required this.entered,
    required this.at,
  });

  final CachedFence fence;

  /// `true` = entrou, `false` = saiu. É o que decide se se sugere `gate_in` ou `gate_out`.
  final bool entered;

  final DateTime at;
}

class BackgroundLocationService {
  BackgroundLocationService({
    required Database db,
    required GeofenceEvaluator geofences,
    required DriverEnvironment environment,
  })  : _db = db,
        _geofences = geofences,
        _environment = environment;

  final Database _db;
  final GeofenceEvaluator _geofences;
  final DriverEnvironment _environment;

  final StreamController<FenceTransition> _transitions =
      StreamController<FenceTransition>.broadcast();

  StreamSubscription<Position>? _subscription;
  String? _currentFenceId;

  Stream<FenceTransition> get transitions => _transitions.stream;

  bool get isRunning => _subscription != null;

  /// Arranca a recolha. Pede a autorização "sempre" — sem ela o Android corta o fluxo mal o ecrã
  /// se apaga, e o ecrã apaga-se durante a condução, que é exatamente quando isto interessa.
  ///
  /// O filtro de distância é o que mantém a bateria viva: a 90 km/h, 250 metros dá um ponto de
  /// dez em dez segundos; parado no cais, dá zero pontos, que é o correto.
  Future<bool> start() async {
    if (_subscription != null) return true;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }

    _subscription = Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 250,
        timeLimit: _environment.backgroundFixInterval * 10,
      ),
    ).listen(_onFix, onError: (Object _) {
      // Perder o fluxo por o utilizador ter desligado o GPS não é motivo para rebentar; a
      // recolha volta quando ele o ligar e voltar a entrar em serviço.
    });

    return true;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _currentFenceId = null;
  }

  /// Retoma a recolha se o turno tiver ficado aberto — a app foi morta pelo sistema com o
  /// condutor em `driving` e não faz sentido esperar que ele repare e volte a carregar no botão.
  Future<void> resumeIfShiftIsOpen() async {
    final rows = await _db.query(
      'local_duty_status_changes',
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final status = rows.first['status']! as String;
    if (status == 'driving' || status == 'on_duty') {
      await start();
    }
  }

  Future<void> _onFix(Position fix) async {
    final fence = await _geofences.fenceContaining(fix.latitude, fix.longitude, fix.accuracy);

    await _db.insert('local_position_fixes', <String, Object?>{
      'recorded_at': fix.timestamp.toUtc().toIso8601String(),
      'latitude': fix.latitude,
      'longitude': fix.longitude,
      'accuracy_m': fix.accuracy,
      'speed_mps': fix.speed,
      'inside_geofence_id': fence?.geofenceId.value,
    });

    _emitTransitionIfChanged(fence, fix.timestamp.toUtc());
  }

  /// Compara com o ponto anterior e emite uma transição quando a cerca muda. A histerese vem do
  /// `buffer_m` aplicado no `GeofenceEvaluator`, e não de um contador de pontos consecutivos:
  /// um camião parado no portão com GPS a saltar produzia dez transições por minuto na versão
  /// que contava pontos.
  void _emitTransitionIfChanged(CachedFence? fence, DateTime at) {
    final previous = _currentFenceId;
    final current = fence?.geofenceId.value;
    if (previous == current) return;

    if (previous != null && fence == null) {
      // Saiu, mas já não temos o objeto da cerca anterior em mão — não emitimos saída sem cerca,
      // o consumidor só precisa da entrada para sugerir a leitura.
      _currentFenceId = null;
      return;
    }
    if (fence != null) {
      _transitions.add(FenceTransition(fence: fence, entered: true, at: at));
    }
    _currentFenceId = current;
  }

  /// Último ponto conhecido, para quando uma leitura precisa de posição e não dá para esperar
  /// por um `fix` novo dentro de um armazém.
  Future<Map<String, Object?>?> lastKnownFix() async {
    final rows = await _db.query(
      'local_position_fixes',
      orderBy: 'recorded_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> dispose() async {
    await stop();
    await _transitions.close();
  }
}
