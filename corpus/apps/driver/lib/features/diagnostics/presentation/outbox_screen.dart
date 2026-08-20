// Painel de diagnóstico da fila local. Serve a conversa entre o condutor e o suporte: quantas
// escritas estão por sair, quais bloquearam e qual foi o último `X-OF-Trace-Id` desta app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/driver_app.dart';
import '../../../core/config/driver_environment.dart';
import '../../../core/network/of_session.dart';
import '../../../sync/outbox_dao.dart';
import '../../../sync/sync_engine.dart';

/// Painel de diagnóstico: o que está por enviar, o que já falhou demasiadas vezes e qual foi o
/// último `X-OF-Trace-Id` desta app. Existe para uma conversa concreta — o condutor ao telefone
/// com o suporte, que precisa de um número para procurar nos registos do ingress.
///
/// Em produção só aparece se `DriverEnvironment.showsDiagnosticsPanel` o permitir: a fila mostra
/// caminhos com identificadores de expedições, e isso não deve ficar visível num telemóvel que
/// passa de turno em turno.
class OutboxScreen extends ConsumerStatefulWidget {
  const OutboxScreen({super.key});

  @override
  ConsumerState<OutboxScreen> createState() => _OutboxScreenState();
}

class _OutboxScreenState extends ConsumerState<OutboxScreen> {
  List<OutboxMessage> _poisoned = const <OutboxMessage>[];
  List<OutboxMessage> _due = const <OutboxMessage>[];
  int _pending = 0;
  SyncReport? _lastReport;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final locator = ref.read(serviceLocatorProvider);
    final outbox = locator.get<OutboxDao>();
    final environment = locator.get<DriverEnvironment>();

    final pending = await outbox.pendingCount();
    final due = await outbox.dueBatch(limit: 50);
    final poisoned = await outbox.poisoned(environment.maxOutboxAttempts);

    if (!mounted) return;
    setState(() {
      _pending = pending;
      _due = due;
      _poisoned = poisoned;
    });
  }

  Future<void> _flushNow() async {
    final report = await ref.read(serviceLocatorProvider).get<SyncEngine>().flush();
    if (!mounted) return;
    setState(() => _lastReport = report);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.read(serviceLocatorProvider).get<OfSession>();

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Fila local', style: Theme.of(context).textTheme.titleMedium),
          Text('$_pending linha(s) por publicar, ${_due.length} pronta(s) a sair agora.'),
          const SizedBox(height: 8),
          FilledButton(onPressed: _flushNow, child: const Text('Forçar sincronização')),
          if (_lastReport != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Última passagem: ${_lastReport!.published} publicadas, '
                '${_lastReport!.retried} adiadas, ${_lastReport!.discarded} descartadas '
                'em ${_lastReport!.elapsed.inMilliseconds} ms.',
              ),
            ),
          const Divider(height: 32),
          Text('Último trace', style: Theme.of(context).textTheme.titleMedium),
          SelectableText(
            session.lastTraceId ?? 'ainda nenhum nesta sessão',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 4),
          Text(
            'É este valor que o suporte procura nos registos do fleet-service e do '
            'container-registry.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('Bloqueadas', style: Theme.of(context).textTheme.titleMedium),
          if (_poisoned.isEmpty)
            const Text('Nenhuma. Tudo o que entrou na fila acabou por sair.')
          else
            for (final message in _poisoned)
              ListTile(
                dense: true,
                title: Text('${message.operation.targetService} · ${message.path}'),
                subtitle: Text(
                  '${message.attempts} tentativas · ${message.lastError ?? "sem erro registado"}',
                ),
              ),
        ],
      ),
    );
  }
}
