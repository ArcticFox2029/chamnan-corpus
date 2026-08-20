/// Testes do contador local de horas de serviço. O cálculo autoritativo é do fleet-service, mas
/// este é o número que o condutor vê durante o dia todo, e um número visivelmente errado destrói
/// a confiança na app inteira — a seguir a isso ninguém volta a acreditar no aviso de limite.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitalfreight_driver/features/hos/domain/duty_status.dart';

DutyStatusChange _change(DutyStatus status, DateTime at) => DutyStatusChange(
      changeId: 'evt_TEST${status.wire}',
      status: status,
      startedAt: at,
    );

void main() {
  final now = DateTime.utc(2026, 3, 14, 18, 0);

  test('soma condução e serviço separadamente', () {
    final estimate = DutyDayEstimate.fromChanges(
      <DutyStatusChange>[
        _change(DutyStatus.onDuty, now.subtract(const Duration(hours: 8))),
        _change(DutyStatus.driving, now.subtract(const Duration(hours: 7, minutes: 30))),
        _change(DutyStatus.restBreak, now.subtract(const Duration(hours: 3, minutes: 30))),
        _change(DutyStatus.driving, now.subtract(const Duration(hours: 2, minutes: 45))),
      ],
      now: now,
    );

    // 4 h ao volante antes da pausa, mais 2 h 45 depois.
    expect(estimate.drivingMinutes, 405);
    // O serviço inclui a meia hora de `on_duty` inicial, mas não a pausa.
    expect(estimate.dutyMinutes, 435);
    expect(estimate.current, DutyStatus.driving);
  });

  test('o intervalo aberto conta até agora', () {
    final estimate = DutyDayEstimate.fromChanges(
      <DutyStatusChange>[_change(DutyStatus.driving, now.subtract(const Duration(minutes: 90)))],
      now: now,
    );
    expect(estimate.drivingMinutes, 90);
  });

  test('ignora mudanças com mais de 24 horas', () {
    final estimate = DutyDayEstimate.fromChanges(
      <DutyStatusChange>[
        _change(DutyStatus.driving, now.subtract(const Duration(hours: 30))),
        _change(DutyStatus.dailyRest, now.subtract(const Duration(hours: 26))),
        _change(DutyStatus.driving, now.subtract(const Duration(hours: 1))),
      ],
      now: now,
    );
    // Só a última mudança cai na janela; as duas anteriores pertencem ao turno de ontem, que é
    // contabilidade do fleet-service e não nossa.
    expect(estimate.drivingMinutes, 60);
  });

  test('sem mudanças assume fora de serviço', () {
    final estimate = DutyDayEstimate.fromChanges(const <DutyStatusChange>[], now: now);
    expect(estimate.current, DutyStatus.offDuty);
    expect(estimate.drivingMinutes, 0);
    expect(estimate.drivingFraction, 0);
  });

  test('a fração satura nas nove horas do eu_561', () {
    final estimate = DutyDayEstimate.fromChanges(
      <DutyStatusChange>[_change(DutyStatus.driving, now.subtract(const Duration(hours: 11)))],
      now: now,
    );
    expect(estimate.drivingMinutes, 660);
    expect(estimate.drivingFraction, 1.0);
  });
}
