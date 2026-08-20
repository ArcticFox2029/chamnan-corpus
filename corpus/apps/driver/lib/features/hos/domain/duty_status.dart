/// Estados de serviço do condutor e as contas que a app faz sobre eles. O cálculo que vale é o do
/// fleet-service, que aplica o `OF_FLEET_HOS_RULESET` configurado (`eu_561` na Europa,
/// `us_fmcsa` na América do Norte); o que está aqui é a estimativa local que permite mostrar o
/// contador a andar sem rede e avisar antes de o limite ser atingido.
///
/// Nunca usar estes valores para decidir se o condutor pode conduzir. Essa resposta vem de
/// `GET /v1/drivers/{driver_id}/availability` ou, no limite, do `fleet.v1.FleetService/Assign` a
/// recusar com `hours_of_service_exceeded`.
library;

/// Os estados que o fleet-service aceita no corpo de `POST /v1/drivers/{driver_id}/hours-of-service`.
enum DutyStatus {
  offDuty('off_duty', 'Fora de serviço'),
  onDuty('on_duty', 'Ao serviço (sem conduzir)'),
  driving('driving', 'A conduzir'),
  restBreak('rest_break', 'Pausa'),
  dailyRest('daily_rest', 'Descanso diário');

  const DutyStatus(this.wire, this.label);

  final String wire;

  /// Texto para o botão. Aparece no ecrã do condutor, por isso é conteúdo, não comentário.
  final String label;

  static DutyStatus parse(String raw) => DutyStatus.values.firstWhere((s) => s.wire == raw);

  /// Só `driving` conta para o tempo de condução; `on_duty` conta para o tempo de trabalho, que
  /// tem outro limite. Esta distinção é a origem de metade das reclamações de condutores sobre
  /// tacógrafos, e é por isso que os dois contadores aparecem separados no ecrã.
  bool get countsAsDriving => this == DutyStatus.driving;

  bool get countsAsDuty => this == DutyStatus.driving || this == DutyStatus.onDuty;
}

/// Uma mudança de estado, tal como fica em `local_duty_status_changes` antes de subir.
class DutyStatusChange {
  const DutyStatusChange({
    required this.changeId,
    required this.status,
    required this.startedAt,
    this.vehicleId,
    this.odometerM,
    this.syncedAt,
  });

  factory DutyStatusChange.fromRow(Map<String, Object?> row) => DutyStatusChange(
        changeId: row['change_id']! as String,
        status: DutyStatus.parse(row['status']! as String),
        startedAt: DateTime.parse(row['started_at']! as String),
        vehicleId: row['vehicle_id'] as String?,
        odometerM: row['odometer_m'] as int?,
        syncedAt: row['synced_at'] == null
            ? null
            : DateTime.parse(row['synced_at']! as String),
      );

  final String changeId;
  final DutyStatus status;
  final DateTime startedAt;
  final String? vehicleId;

  /// Conta-quilómetros em metros inteiros, seguindo a convenção `_m` de §0.2. O condutor
  /// introduz quilómetros; a conversão é feita no ecrã, uma vez.
  final int? odometerM;

  final DateTime? syncedAt;

  bool get isPending => syncedAt == null;
}

/// Estimativa local do dia, reconstruída a partir da sequência de mudanças. O fleet-service faz
/// o mesmo do lado dele, e faz melhor: sabe os dias anteriores, os descansos compensatórios e as
/// exceções do regulamento. Aqui só se olha para as últimas 24 horas.
class DutyDayEstimate {
  const DutyDayEstimate({
    required this.drivingMinutes,
    required this.dutyMinutes,
    required this.since,
    required this.current,
  });

  /// Percorre as mudanças por ordem cronológica e soma a duração de cada intervalo ao contador
  /// certo. Um intervalo aberto (o estado atual) conta até agora.
  factory DutyDayEstimate.fromChanges(
    List<DutyStatusChange> changes, {
    DateTime? now,
  }) {
    final reference = (now ?? DateTime.now()).toUtc();
    final since = reference.subtract(const Duration(hours: 24));
    final ordered = changes.where((c) => c.startedAt.isAfter(since)).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

    var driving = 0;
    var duty = 0;
    for (var i = 0; i < ordered.length; i++) {
      final change = ordered[i];
      final end = i + 1 < ordered.length ? ordered[i + 1].startedAt : reference;
      final minutes = end.difference(change.startedAt).inMinutes;
      if (change.status.countsAsDriving) driving += minutes;
      if (change.status.countsAsDuty) duty += minutes;
    }

    return DutyDayEstimate(
      drivingMinutes: driving,
      dutyMinutes: duty,
      since: since,
      current: ordered.isEmpty ? DutyStatus.offDuty : ordered.last.status,
    );
  }

  final int drivingMinutes;
  final int dutyMinutes;
  final DateTime since;
  final DutyStatus current;

  /// Nove horas de condução diária é o limite normal do `eu_561`, com duas exceções semanais de
  /// dez. Mostramos a barra contra as nove; quem autoriza a décima hora é o fleet-service.
  double get drivingFraction => (drivingMinutes / (9 * 60)).clamp(0.0, 1.0);
}
