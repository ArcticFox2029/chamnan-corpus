import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/driver_app.dart';
import '../../../core/config/driver_environment.dart';
import '../../../sync/outbox_dao.dart';
import '../../../sync/sync_engine.dart';
import '../../diagnostics/presentation/outbox_screen.dart';
import '../../hos/presentation/duty_status_screen.dart';
import '../../route/presentation/leg_timeline_screen.dart';
import '../data/fleet_repository.dart';
import '../domain/assignment.dart';

/// Ecrã inicial: as atribuições abertas deste condutor, por ordem de `assigned_at`. É o único
/// ecrã que o condutor vê ao pegar no telemóvel, por isso carrega sempre da cache local primeiro
/// e só depois tenta a rede — abrir a app dentro de um armazém não pode dar uma lista vazia.
///
/// O crachá do canto conta as linhas por publicar em `local_outbox`. Ficar acima de zero durante
/// muito tempo é o sintoma que o suporte pede primeiro quando o despachante liga a dizer que uma
/// entrega "não aparece no sistema".
class AssignmentListScreen extends ConsumerStatefulWidget {
  const AssignmentListScreen({super.key});

  @override
  ConsumerState<AssignmentListScreen> createState() => _AssignmentListScreenState();
}

class _AssignmentListScreenState extends ConsumerState<AssignmentListScreen> {
  List<Assignment> _assignments = const <Assignment>[];
  DriverAvailability? _availability;
  int _pending = 0;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFromCache());
    unawaited(_refresh());
  }

  Future<void> _loadFromCache() async {
    final locator = ref.read(serviceLocatorProvider);
    final cached = await locator.get<FleetRepository>().cachedAssignments();
    final pending = await locator.get<OutboxDao>().pendingCount();
    if (!mounted) return;
    setState(() {
      _assignments = cached;
      _pending = pending;
    });
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final locator = ref.read(serviceLocatorProvider);
    // Esvaziar a fila antes de puxar evita mostrar uma expedição ainda em `in_transit` quando a
    // leitura de `proof_of_delivery` já saiu do telemóvel neste mesmo gesto.
    await locator.get<SyncEngine>().flush();
    final assignments = await locator.get<FleetRepository>().refreshActiveAssignments();
    DriverAvailability? availability;
    try {
      availability = await locator.get<FleetRepository>().availability();
    } on Exception {
      // Sem rede não há disponibilidade fresca; mantemos a anterior no ecrã.
      availability = _availability;
    }
    final pending = await locator.get<OutboxDao>().pendingCount();

    if (!mounted) return;
    setState(() {
      _assignments = assignments;
      _availability = availability;
      _pending = pending;
      _refreshing = false;
    });
  }

  /// Só abre o painel fora de produção: mostra caminhos com identificadores de expedições e o
  /// telemóvel muda de mãos ao fim do turno.
  Future<void> _openDiagnostics() async {
    final environment = ref.read(serviceLocatorProvider).get<DriverEnvironment>();
    if (!environment.showsDiagnosticsPanel) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const OutboxScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('As minhas entregas'),
        actions: <Widget>[
          if (_pending > 0)
            // O crachá é tocável: leva ao painel de diagnóstico, que é onde está a explicação.
            InkWell(
              onTap: _openDiagnostics,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Chip(
                  avatar: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text('$_pending'),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Estado de serviço',
            icon: const Icon(Icons.timer_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DutyStatusScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: <Widget>[
            if (_availability != null) _AvailabilityBanner(availability: _availability!),
            if (_assignments.isEmpty && !_refreshing)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Sem atribuições abertas. Se esperava uma, o despachante ainda não a criou '
                  'ou a rota foi replaneada e a atribuição foi libertada.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final assignment in _assignments)
              _AssignmentTile(
                assignment: assignment,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LegTimelineScreen(assignment: assignment),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvailabilityBanner extends StatelessWidget {
  const _AvailabilityBanner({required this.availability});

  final DriverAvailability availability;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: availability.isNearLimit ? scheme.errorContainer : scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        'Condução restante: ${availability.remainingDriveMinutes} min '
        '(regulamento ${availability.ruleset})',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  const _AssignmentTile({required this.assignment, required this.onTap});

  final Assignment assignment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(_iconFor(assignment.shipmentStatus)),
      title: Text(assignment.shipmentReference),
      subtitle: Text(_subtitleFor(assignment)),
      trailing: assignment.shipmentStatus.needsExplanation
          ? const Icon(Icons.priority_high)
          : const Icon(Icons.chevron_right),
    );
  }

  IconData _iconFor(ShipmentStatus status) => switch (status) {
        ShipmentStatus.atRisk => Icons.thermostat,
        ShipmentStatus.heldAtCustoms => Icons.gavel,
        ShipmentStatus.delivered => Icons.check_circle_outline,
        ShipmentStatus.cancelled => Icons.block,
        _ => Icons.local_shipping_outlined,
      };

  /// Traduz o estado para uma frase que faça sentido na cabina. `at_risk` chega sempre de um
  /// `telemetry.alert.raised` — normalmente uma excursão de temperatura num contentor reefer — e
  /// dizer só "em risco" faz o condutor telefonar ao despachante para perguntar porquê.
  String _subtitleFor(Assignment assignment) => switch (assignment.shipmentStatus) {
        ShipmentStatus.atRisk => 'Alerta de sensor aberto — verificar o contentor',
        ShipmentStatus.heldAtCustoms => 'Retida na alfândega — aguardar desalfandegamento',
        ShipmentStatus.sealed => 'Selada, pronta a carregar',
        ShipmentStatus.inTransit => 'Em trânsito',
        ShipmentStatus.delivered => 'Entregue',
        _ => assignment.shipmentStatus.wire,
      };
}
