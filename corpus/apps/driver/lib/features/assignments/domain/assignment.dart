/// Modelo de uma atribuição tal como o condutor a vê: a linha de `fleet.vehicle_assignments`
/// juntada ao pouco que precisamos da expedição correspondente em `freight.shipments`.
/// É o objeto central da app — quase todos os outros ecrãs começam por um destes.
library;

import '../../../core/ids/prefixed_id.dart';

/// Estados de `freight.shipments.status` (§2.3). A app não os inventa nem os abrevia: são os
/// mesmos oito valores do CHECK da tabela, porque aparecem tal e qual nos eventos
/// `shipment.status.changed` que a notificação de push nos entrega.
enum ShipmentStatus {
  draft,
  booked,
  sealed,
  inTransit('in_transit'),
  atRisk('at_risk'),
  heldAtCustoms('held_at_customs'),
  delivered,
  cancelled;

  const ShipmentStatus([String? wire]) : _wire = wire;

  final String? _wire;

  String get wire => _wire ?? name;

  static ShipmentStatus parse(String raw) =>
      ShipmentStatus.values.firstWhere((s) => s.wire == raw);

  /// O condutor pode agir sobre a expedição? Uma expedição cancelada ou já entregue continua na
  /// lista até ao fim do turno, mas sem botões.
  bool get isActionable => switch (this) {
        ShipmentStatus.sealed ||
        ShipmentStatus.inTransit ||
        ShipmentStatus.atRisk =>
          true,
        _ => false,
      };

  /// `at_risk` chega sempre do container-registry a consumir `telemetry.alert.raised` — nunca é
  /// o condutor a pô-lo lá. `held_at_customs` vem de `customs.declaration.filed` sem
  /// clearance. Nos dois casos há uma explicação para mostrar em vez de um estado seco.
  bool get needsExplanation =>
      this == ShipmentStatus.atRisk || this == ShipmentStatus.heldAtCustoms;
}

class Assignment {
  const Assignment({
    required this.assignmentId,
    required this.shipmentId,
    required this.vehicleId,
    required this.driverId,
    required this.assignedAt,
    required this.shipmentStatus,
    required this.shipmentReference,
    required this.regionCode,
    this.legId,
    this.carrierId,
    this.releasedAt,
  });

  /// Desserializa a resposta de `GET /v1/assignments` já enriquecida com os campos que vieram
  /// de `GET /v1/shipments/{shipment_id}` — ver `FleetRepository.refreshActiveAssignments`.
  factory Assignment.fromJson(Map<String, Object?> json) => Assignment(
        assignmentId: json.id('assignment_id', IdPrefix.assignment),
        shipmentId: json.id('shipment_id', IdPrefix.shipment),
        legId: json.optionalId('leg_id', IdPrefix.leg),
        vehicleId: json.id('vehicle_id', IdPrefix.vehicle),
        driverId: json.id('driver_id', IdPrefix.driver),
        carrierId: json['carrier_id'] as String?,
        assignedAt: DateTime.parse(json['assigned_at']! as String),
        releasedAt: json['released_at'] == null
            ? null
            : DateTime.parse(json['released_at']! as String),
        shipmentStatus: ShipmentStatus.parse(json['shipment_status']! as String),
        shipmentReference: json['shipment_reference']! as String,
        regionCode: json['region_code']! as String,
      );

  factory Assignment.fromRow(Map<String, Object?> row) => Assignment(
        assignmentId: PrefixedId.parse(IdPrefix.assignment, row['assignment_id']! as String),
        shipmentId: PrefixedId.parse(IdPrefix.shipment, row['shipment_id']! as String),
        legId: row['leg_id'] == null
            ? null
            : PrefixedId.parse(IdPrefix.leg, row['leg_id']! as String),
        vehicleId: PrefixedId.parse(IdPrefix.vehicle, row['vehicle_id']! as String),
        driverId: PrefixedId.parse(IdPrefix.driver, row['driver_id']! as String),
        carrierId: row['carrier_id'] as String?,
        assignedAt: DateTime.parse(row['assigned_at']! as String),
        releasedAt: row['released_at'] == null
            ? null
            : DateTime.parse(row['released_at']! as String),
        shipmentStatus: ShipmentStatus.parse(row['shipment_status']! as String),
        shipmentReference: row['shipment_ref']! as String,
        regionCode: row['region_code']! as String,
      );

  final PrefixedId assignmentId;
  final PrefixedId shipmentId;

  /// Troço de `routing.route_legs` a que esta atribuição está presa. Fica nulo quando o
  /// despachante atribuiu o camião à expedição inteira em vez de a um troço.
  ///
  /// Cuidado: o fleet-service consome `route.replanned` e liberta as atribuições cujo `leg_id`
  /// deixou de existir na versão nova da rota. Uma atribuição pode portanto desaparecer da lista
  /// sem o condutor ter feito nada — o ecrã explica isso em vez de a apagar em silêncio.
  final PrefixedId? legId;

  final PrefixedId vehicleId;
  final PrefixedId driverId;
  final String? carrierId;
  final DateTime assignedAt;
  final DateTime? releasedAt;
  final ShipmentStatus shipmentStatus;

  /// `freight.shipments.reference` — a referência do cliente, que é o que o condutor lê em voz
  /// alta ao telefone. O `shp_` nunca aparece no ecrã principal.
  final String shipmentReference;

  final String regionCode;

  bool get isActive => releasedAt == null;

  Map<String, Object?> toRow() => <String, Object?>{
        'assignment_id': assignmentId.value,
        'shipment_id': shipmentId.value,
        'leg_id': legId?.value,
        'vehicle_id': vehicleId.value,
        'driver_id': driverId.value,
        'carrier_id': carrierId,
        'assigned_at': assignedAt.toIso8601String(),
        'released_at': releasedAt?.toIso8601String(),
        'shipment_status': shipmentStatus.wire,
        'shipment_ref': shipmentReference,
        'region_code': regionCode,
        'fetched_at': DateTime.now().toUtc().toIso8601String(),
      };
}

/// Resposta de `GET /v1/drivers/{driver_id}/availability`. Os minutos vêm já calculados pelo
/// fleet-service segundo o `OF_FLEET_HOS_RULESET` em vigor (`eu_561` na Europa, `us_fmcsa` na
/// América do Norte) — a app não reimplementa regulamento nenhum, só mostra o número.
class DriverAvailability {
  const DriverAvailability({
    required this.remainingDriveMinutes,
    required this.remainingDutyMinutes,
    required this.nextBreakDueAt,
    required this.ruleset,
  });

  factory DriverAvailability.fromJson(Map<String, Object?> json) => DriverAvailability(
        remainingDriveMinutes: json['remaining_drive_minutes']! as int,
        remainingDutyMinutes: json['remaining_duty_minutes']! as int,
        nextBreakDueAt: json['next_break_due_at'] == null
            ? null
            : DateTime.parse(json['next_break_due_at']! as String),
        ruleset: json['ruleset']! as String,
      );

  final int remainingDriveMinutes;
  final int remainingDutyMinutes;
  final DateTime? nextBreakDueAt;
  final String ruleset;

  /// Abaixo de meia hora avisamos com destaque. O bloqueio duro é do fleet-service, que recusa
  /// `fleet.v1.FleetService/Assign` com `hours_of_service_exceeded`; aqui é só cortesia.
  bool get isNearLimit => remainingDriveMinutes <= 30;
}
