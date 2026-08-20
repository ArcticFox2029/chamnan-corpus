// Ecrã do estado de serviço. É daqui que saem as mudanças de estado para
// `POST /v1/drivers/{driver_id}/hours-of-service` e é também daqui que a recolha de posição em
// segundo plano é ligada e desligada, conforme o condutor entra e sai de serviço.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/driver_app.dart';
import '../../../location/background_location_service.dart';
import '../data/hours_of_service_repository.dart';
import '../domain/duty_status.dart';

/// Ecrã do estado de serviço: cinco botões grandes e dois contadores. É também o sítio onde a
/// recolha de posição em segundo plano é ligada e desligada — o rasto só existe enquanto o
/// condutor está `driving` ou `on_duty`, e não há nenhuma razão legítima para o telemóvel
/// registar onde ele almoça.
class DutyStatusScreen extends ConsumerStatefulWidget {
  const DutyStatusScreen({super.key});

  @override
  ConsumerState<DutyStatusScreen> createState() => _DutyStatusScreenState();
}

class _DutyStatusScreenState extends ConsumerState<DutyStatusScreen> {
  DutyDayEstimate? _estimate;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    // O contador anda sozinho; recalcular de minuto a minuto a partir das mudanças é barato e
    // evita ter de manter estado derivado em memória.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_reload()));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final hos = ref.read(serviceLocatorProvider).get<HoursOfServiceRepository>();
    final estimate = await hos.localEstimate();
    if (!mounted) return;
    setState(() => _estimate = estimate);
  }

  Future<void> _select(DutyStatus status) async {
    final locator = ref.read(serviceLocatorProvider);
    await locator.get<HoursOfServiceRepository>().changeStatus(status);

    final location = locator.get<BackgroundLocationService>();
    if (status.countsAsDuty) {
      await location.start();
    } else {
      await location.stop();
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final estimate = _estimate;

    return Scaffold(
      appBar: AppBar(title: const Text('Estado de serviço')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (estimate != null) ...<Widget>[
            Text('Condução hoje', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: estimate.drivingFraction, minHeight: 12),
            const SizedBox(height: 8),
            Text(
              '${estimate.drivingMinutes ~/ 60}h ${estimate.drivingMinutes % 60}min a conduzir · '
              '${estimate.dutyMinutes ~/ 60}h ${estimate.dutyMinutes % 60}min ao serviço',
            ),
            const SizedBox(height: 4),
            Text(
              'Valores estimados no telemóvel. O cálculo que conta é o do fleet-service.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 32),
          ],
          for (final status in DutyStatus.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FilledButton.tonal(
                onPressed: estimate?.current == status ? null : () => _select(status),
                child: Text(status.label),
              ),
            ),
        ],
      ),
    );
  }
}
