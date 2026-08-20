import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/driver_app.dart';
import '../../assignments/domain/assignment.dart';
import '../../pod/presentation/signature_capture_screen.dart';
import '../../scanning/presentation/container_scan_screen.dart';
import '../data/route_repository.dart';
import '../domain/route_plan.dart';

/// Linha do tempo dos troços de uma expedição, com os botões de ação em baixo: ler um contentor
/// e fechar a entrega. É o ecrã onde o condutor passa o dia, por isso mostra os troços por
/// `seq_no` com o atual em destaque e não esconde nada atrás de menus.
///
/// Os troços que não são `road` aparecem esbatidos — não são deste condutor, mas explicam porque
/// é que a caixa só chega ao terminal na quinta-feira.
class LegTimelineScreen extends ConsumerStatefulWidget {
  const LegTimelineScreen({required this.assignment, super.key});

  final Assignment assignment;

  @override
  ConsumerState<LegTimelineScreen> createState() => _LegTimelineScreenState();
}

class _LegTimelineScreenState extends ConsumerState<LegTimelineScreen> {
  RoutePlan? _plan;
  bool _loading = true;

  static final DateFormat _hhmm = DateFormat('dd/MM HH:mm');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final routes = ref.read(serviceLocatorProvider).get<RouteRepository>();
    // Cache primeiro para o ecrã abrir instantâneo, rede a seguir para corrigir.
    final cached = await routes.cachedRoute(widget.assignment.shipmentId);
    if (mounted) setState(() => _plan = cached);

    final fresh = await routes.refreshCurrentRoute(widget.assignment.shipmentId);
    if (!mounted) return;
    setState(() {
      _plan = fresh ?? cached;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final assignment = widget.assignment;

    return Scaffold(
      appBar: AppBar(title: Text(assignment.shipmentReference)),
      body: _loading && plan == null
          ? const Center(child: CircularProgressIndicator())
          : plan == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Esta expedição ainda não tem rota planeada. O despachante planeia-a '
                      'no routing-service antes de a caixa sair.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  children: <Widget>[
                    if (plan.crossingLegs.isNotEmpty) const _CustomsWarning(),
                    for (final leg in plan.legs) _LegTile(leg: leg, format: _hhmm),
                    const Divider(height: 32),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Rota versão ${plan.version} · '
                        '${(plan.totalDistanceM / 1000).toStringAsFixed(0)} km no total',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
      bottomNavigationBar: assignment.shipmentStatus.isActionable
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Ler contentor'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ContainerScanScreen(assignment: assignment),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.draw_outlined),
                        label: const Text('Entregar'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SignatureCaptureScreen(assignment: assignment),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// Aviso de fronteira. Não bloqueia nada: quem decide se a caixa passa é o customs-service, e a
/// app só sabe que o troço tem `crossing_id` preenchido.
class _CustomsWarning extends StatelessWidget {
  const _CustomsWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.all(16),
      child: const Text(
        'Esta rota atravessa fronteira. Leve consigo os documentos da declaração — se a '
        'expedição passar a "retida na alfândega", pare e contacte o despachante.',
      ),
    );
  }
}

class _LegTile extends StatelessWidget {
  const _LegTile({required this.leg, required this.format});

  final RouteLeg leg;
  final DateFormat format;

  @override
  Widget build(BuildContext context) {
    final dim = !leg.mode.isDriverExecuted;
    final style = dim
        ? TextStyle(color: Theme.of(context).disabledColor)
        : const TextStyle(fontWeight: FontWeight.w600);

    return ListTile(
      leading: CircleAvatar(child: Text('${leg.seqNo}')),
      title: Text('${leg.mode.name.toUpperCase()} · ${leg.distanceKm.toStringAsFixed(0)} km',
          style: style),
      subtitle: Text(
        '${format.format(leg.plannedDepartAt.toLocal())} → '
        '${format.format(leg.plannedArriveAt.toLocal())}'
        '${leg.crossingId != null ? '  ·  fronteira' : ''}',
      ),
      trailing: leg.isDone
          ? const Icon(Icons.check)
          : leg.isCurrent
              ? const Icon(Icons.navigation)
              : null,
    );
  }
}
