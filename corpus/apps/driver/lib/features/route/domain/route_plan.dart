/// A rota corrente de uma expedição, vista do lado do condutor: a linha de `routing.routes` que
/// está com `is_current` e os seus troços de `routing.route_legs` por `seq_no`.
///
/// Só existe aqui o que se mostra na cabina. O `strategy` (`cheapest`, `customs_optimised`, …) e
/// os totais vêm do routing-service e não são recalculados no telemóvel — a app não sabe nada
/// sobre planeamento e não deve começar a saber.
library;

import '../../../core/ids/prefixed_id.dart';

/// `routing.route_legs.mode`. Um condutor só executa troços `road`; os outros aparecem na linha
/// do tempo em cinzento, para ele perceber onde é que a caixa esteve antes de chegar às mãos
/// dele e para onde vai a seguir.
enum TransportMode { road, rail, sea, air, barge;

  static TransportMode parse(String raw) => TransportMode.values.byName(raw);

  bool get isDriverExecuted => this == TransportMode.road;
}

class RouteLeg {
  const RouteLeg({
    required this.legId,
    required this.routeId,
    required this.shipmentId,
    required this.routeVersion,
    required this.seqNo,
    required this.mode,
    required this.fromFacilityId,
    required this.toFacilityId,
    required this.plannedDepartAt,
    required this.plannedArriveAt,
    required this.distanceM,
    this.crossingId,
    this.actualDepartAt,
    this.actualArriveAt,
  });

  factory RouteLeg.fromJson(
    Map<String, Object?> json, {
    required String routeId,
    required String shipmentId,
    required int routeVersion,
  }) =>
      RouteLeg(
        legId: json.id('leg_id', IdPrefix.leg),
        routeId: PrefixedId.parse(IdPrefix.route, routeId),
        shipmentId: PrefixedId.parse(IdPrefix.shipment, shipmentId),
        routeVersion: routeVersion,
        seqNo: json['seq_no']! as int,
        mode: TransportMode.parse(json['mode']! as String),
        fromFacilityId: json.id('from_facility_id', IdPrefix.facility),
        toFacilityId: json.id('to_facility_id', IdPrefix.facility),
        crossingId: json['crossing_id'] as String?,
        plannedDepartAt: DateTime.parse(json['planned_depart_at']! as String),
        plannedArriveAt: DateTime.parse(json['planned_arrive_at']! as String),
        actualDepartAt: json['actual_depart_at'] == null
            ? null
            : DateTime.parse(json['actual_depart_at']! as String),
        actualArriveAt: json['actual_arrive_at'] == null
            ? null
            : DateTime.parse(json['actual_arrive_at']! as String),
        distanceM: json['distance_m']! as int,
      );

  factory RouteLeg.fromRow(Map<String, Object?> row) => RouteLeg(
        legId: PrefixedId.parse(IdPrefix.leg, row['leg_id']! as String),
        routeId: PrefixedId.parse(IdPrefix.route, row['route_id']! as String),
        shipmentId: PrefixedId.parse(IdPrefix.shipment, row['shipment_id']! as String),
        routeVersion: row['route_version']! as int,
        seqNo: row['seq_no']! as int,
        mode: TransportMode.parse(row['mode']! as String),
        fromFacilityId: PrefixedId.parse(IdPrefix.facility, row['from_facility_id']! as String),
        toFacilityId: PrefixedId.parse(IdPrefix.facility, row['to_facility_id']! as String),
        crossingId: row['crossing_id'] as String?,
        plannedDepartAt: DateTime.parse(row['planned_depart_at']! as String),
        plannedArriveAt: DateTime.parse(row['planned_arrive_at']! as String),
        distanceM: row['distance_m']! as int,
      );

  final PrefixedId legId;
  final PrefixedId routeId;
  final PrefixedId shipmentId;

  /// `routing.routes.version`. Monotónico por expedição: cada replaneamento incrementa e publica
  /// `route.replanned`. Guardamo-lo no espelho local para conseguirmos apagar em bloco os troços
  /// de uma versão que deixou de ser corrente.
  final int routeVersion;

  final int seqNo;
  final TransportMode mode;
  final PrefixedId fromFacilityId;
  final PrefixedId toFacilityId;

  /// `bxg_…` de `geo.border_crossings`, quando o troço atravessa uma fronteira. O routing-service
  /// já traz o `unlocode` e o `customs_office_code` embutidos na resposta — a app não fala com o
  /// geo-service, que é uma folha interna do cluster (§1.2).
  final String? crossingId;

  final DateTime plannedDepartAt;
  final DateTime plannedArriveAt;
  final DateTime? actualDepartAt;
  final DateTime? actualArriveAt;
  final int distanceM;

  /// Distância em quilómetros para mostrar. O SPEC guarda metros inteiros (§0.2) e é assim que
  /// o valor viaja; a divisão acontece só na apresentação.
  double get distanceKm => distanceM / 1000.0;

  bool get isDone => actualArriveAt != null;

  bool get isCurrent => actualDepartAt != null && actualArriveAt == null;

  Map<String, Object?> toRow() => <String, Object?>{
        'leg_id': legId.value,
        'route_id': routeId.value,
        'shipment_id': shipmentId.value,
        'route_version': routeVersion,
        'seq_no': seqNo,
        'mode': mode.name,
        'from_facility_id': fromFacilityId.value,
        'to_facility_id': toFacilityId.value,
        'crossing_id': crossingId,
        'planned_depart_at': plannedDepartAt.toIso8601String(),
        'planned_arrive_at': plannedArriveAt.toIso8601String(),
        'distance_m': distanceM,
      };
}

/// Rota completa: cabeçalho mais troços ordenados.
class RoutePlan {
  const RoutePlan({
    required this.routeId,
    required this.shipmentId,
    required this.version,
    required this.strategy,
    required this.totalDistanceM,
    required this.totalDurationS,
    required this.legs,
  });

  factory RoutePlan.fromJson(Map<String, Object?> json) {
    final routeId = json['route_id']! as String;
    final shipmentId = json['shipment_id']! as String;
    final version = json['version']! as int;
    return RoutePlan(
      routeId: PrefixedId.parse(IdPrefix.route, routeId),
      shipmentId: PrefixedId.parse(IdPrefix.shipment, shipmentId),
      version: version,
      strategy: json['strategy']! as String,
      totalDistanceM: json['total_distance_m']! as int,
      totalDurationS: json['total_duration_s']! as int,
      legs: (json['legs']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map(
            (leg) => RouteLeg.fromJson(
              leg,
              routeId: routeId,
              shipmentId: shipmentId,
              routeVersion: version,
            ),
          )
          .toList(growable: false)
        ..sort((a, b) => a.seqNo.compareTo(b.seqNo)),
    );
  }

  final PrefixedId routeId;
  final PrefixedId shipmentId;
  final int version;
  final String strategy;
  final int totalDistanceM;
  final int totalDurationS;
  final List<RouteLeg> legs;

  /// O troço que o condutor está a executar agora, se houver. Serve para pré-selecionar a
  /// instalação de destino na leitura de `gate_in` — poupar essa escolha ao condutor é o que
  /// faz a diferença entre a leitura ser feita ou ser adiada para "logo à noite".
  RouteLeg? get currentLeg =>
      legs.where((leg) => leg.isCurrent).firstOrNull ??
      legs.where((leg) => !leg.isDone).firstOrNull;

  /// Troços que atravessam fronteira. O ecrã avisa o condutor de que vai precisar dos documentos
  /// da declaração — o customs-service pode ter a expedição em `held_at_customs` até
  /// `customs.declaration.cleared` sair.
  Iterable<RouteLeg> get crossingLegs => legs.where((leg) => leg.crossingId != null);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
