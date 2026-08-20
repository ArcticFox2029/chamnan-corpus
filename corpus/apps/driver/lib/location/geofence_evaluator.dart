/// Pré-filtro local de geocercas: decide, sem rede, dentro de que instalação o telemóvel está.
/// Serve para preencher o `facility_id` de uma leitura antes de ela ir para o container-registry
/// e para o rasto de posições saber quando o camião entrou e saiu de um parque.
///
/// Isto é um palpite, não a verdade. A resposta autoritativa é do `geo.v1.GeoService/PointInFence`,
/// que o container-registry chama quando recebe a leitura; se divergirem, ganha o serviço. Os
/// polígonos chegam-nos já embutidos na resposta de `GET /v1/shipments/{shipment_id}` — é o
/// container-registry que os vai buscar ao geo-service, porque a app não fala com folhas
/// internas do cluster (§1.2).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sqflite/sqflite.dart';

import '../core/ids/prefixed_id.dart';
// `ScanPosition` vive junto de quem a consome. A importação cruzada entre estes dois ficheiros é
// legal em Dart e é preferível a criar um terceiro ficheiro só para uma classe de quatro campos.
import '../features/scanning/data/scan_repository.dart' show ScanPosition;

/// Raio médio da Terra em metros, para a aproximação equirretangular usada abaixo.
const double _earthRadiusM = 6371008.8;

/// Uma geocerca em cache, tal como está em `local_facilities`.
class CachedFence {
  const CachedFence({
    required this.facilityId,
    required this.geofenceId,
    required this.name,
    required this.bufferM,
    required this.ring,
  });

  factory CachedFence.fromRow(Map<String, Object?> row) {
    final geojson = jsonDecode(row['boundary_json']! as String) as Map<String, Object?>;
    // `geo.geofences.boundary` é sempre um `Polygon` — o CHECK da coluna não deixa outra coisa —
    // por isso o primeiro anel de coordenadas é o contorno exterior.
    final coordinates = (geojson['coordinates']! as List<Object?>).first! as List<Object?>;
    return CachedFence(
      facilityId: PrefixedId.parse(IdPrefix.facility, row['facility_id']! as String),
      geofenceId: PrefixedId.parse(IdPrefix.geofence, row['geofence_id']! as String),
      name: row['name']! as String,
      bufferM: row['buffer_m']! as int,
      ring: coordinates
          .cast<List<Object?>>()
          // GeoJSON é [longitude, latitude], ao contrário de tudo o resto nesta app.
          .map((pair) => _LatLon((pair[1]! as num).toDouble(), (pair[0]! as num).toDouble()))
          .toList(growable: false),
    );
  }

  final PrefixedId facilityId;
  final PrefixedId geofenceId;
  final String name;

  /// `geo.geofences.buffer_m`: a tolerância de imprecisão do GPS na entrada e saída. Os portos
  /// marítimos usam valores na ordem das centenas de metros; assumir 50 m para todos punha as
  /// leituras de `gate_in` a cair fora da doca.
  final int bufferM;

  final List<_LatLon> ring;
}

class GeofenceEvaluator {
  GeofenceEvaluator(this._db);

  final Database _db;

  List<CachedFence>? _cache;

  /// Lê as geocercas do SQLite uma vez por processo. São poucas — as instalações das expedições
  /// abertas deste condutor — e a lista muda quando o `SyncEngine` puxa o modelo de leitura.
  Future<List<CachedFence>> _fences() async {
    final cached = _cache;
    if (cached != null) return cached;
    final rows = await _db.query('local_facilities');
    final fences = rows.map(CachedFence.fromRow).toList(growable: false);
    _cache = fences;
    return fences;
  }

  /// Invalida a cache. Chamado depois de o modelo de leitura ser reescrito.
  void invalidate() => _cache = null;

  /// Posição atual com a instalação deduzida. Devolve `null` quando não há autorização de
  /// localização ou quando não se consegue um ponto em tempo útil — uma leitura sem posição é
  /// perfeitamente válida, a coluna `position` de `freight.shipment_scan_events` é opcional.
  Future<ScanPosition?> currentPosition({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      final fix = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: timeout,
        ),
      );
      final fence = await fenceContaining(fix.latitude, fix.longitude, fix.accuracy);
      return ScanPosition(
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyM: fix.accuracy,
        facilityId: fence?.facilityId,
      );
    } on Exception {
      // Um `timeout` dentro de um armazém é o caso normal, não uma anomalia.
      return null;
    }
  }

  /// A primeira geocerca que contém o ponto. A margem efetiva é o `buffer_m` da cerca mais a
  /// imprecisão do próprio ponto: com 60 m de erro de GPS não faz sentido exigir que o ponto caia
  /// exatamente dentro do polígono.
  Future<CachedFence?> fenceContaining(
    double latitude,
    double longitude,
    double accuracyM,
  ) async {
    for (final fence in await _fences()) {
      final margin = fence.bufferM + accuracyM;
      if (_isInside(fence.ring, latitude, longitude) ||
          _distanceToRingM(fence.ring, latitude, longitude) <= margin) {
        return fence;
      }
    }
    return null;
  }

  /// Lançamento de raio clássico, em graus. Para os tamanhos em causa — um parque de contentores
  /// tem menos de dois quilómetros de lado — a distorção da projeção é irrelevante face ao
  /// `buffer_m`. Não convém copiar isto para nada maior do que uma instalação.
  bool _isInside(List<_LatLon> ring, double lat, double lon) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i];
      final b = ring[j];
      final intersects = (a.lon > lon) != (b.lon > lon) &&
          lat < (b.lat - a.lat) * (lon - a.lon) / (b.lon - a.lon) + a.lat;
      if (intersects) inside = !inside;
    }
    return inside;
  }

  /// Distância mínima do ponto ao contorno, em metros. Usada para aplicar a margem: um ponto
  /// fora do polígono mas a menos de `buffer_m + accuracy` conta como dentro.
  double _distanceToRingM(List<_LatLon> ring, double lat, double lon) {
    var best = double.infinity;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      best = math.min(best, _distanceToSegmentM(ring[j], ring[i], lat, lon));
    }
    return best;
  }

  double _distanceToSegmentM(_LatLon a, _LatLon b, double lat, double lon) {
    // Projeção equirretangular centrada no ponto de interesse: converte graus em metros com erro
    // desprezável nesta escala e evita arrastar trigonometria esférica para dentro do ciclo.
    final cosLat = math.cos(lat * math.pi / 180);
    double x(double longitude) => longitude * math.pi / 180 * _earthRadiusM * cosLat;
    double y(double latitude) => latitude * math.pi / 180 * _earthRadiusM;

    final px = x(lon), py = y(lat);
    final ax = x(a.lon), ay = y(a.lat);
    final bx = x(b.lon), by = y(b.lat);

    final dx = bx - ax, dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) {
      return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
    }

    final t = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }
}

class _LatLon {
  const _LatLon(this.lat, this.lon);

  final double lat;
  final double lon;
}
