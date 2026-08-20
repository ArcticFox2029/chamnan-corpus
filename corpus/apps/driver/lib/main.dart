/// Ponto de entrada da app do condutor. Faz três coisas e mais nenhuma: monta o `ServiceLocator`,
/// regista as tarefas periódicas do WorkManager (drenagem do outbox e poda do SQLite local) e
/// entrega o controlo ao `DriverApp`.
///
/// O isolate de segundo plano do WorkManager não partilha memória com a UI, por isso o
/// `callbackDispatcher` reconstrói tudo do zero — base de dados, sessão e cliente HTTP. É feio,
/// mas é a única forma de a fila continuar a esvaziar-se com a app fechada, que é o caso normal
/// quando o camião está a andar.
library;

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'app/driver_app.dart';
import 'app/service_locator.dart';
import 'core/config/driver_environment.dart';
import 'location/background_location_service.dart';
import 'sync/sync_engine.dart';

/// Identificadores das tarefas periódicas. São visíveis no `adb shell dumpsys jobscheduler`, por
/// isso o nome tem de dizer alguma coisa a quem estiver a diagnosticar um telemóvel em campo.
const String kOutboxFlushTask = 'of.driver.outbox_flush';
const String kHousekeepingTask = 'of.driver.housekeeping';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final environment = DriverEnvironment.fromDartDefines();
  final locator = await ServiceLocator.bootstrap(environment);

  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: !environment.isProduction,
  );

  // 15 minutos é o mínimo que o Android garante; o iOS trata isto como uma sugestão e acorda-nos
  // quando lhe apetece. Nenhum dos dois é fiável ao ponto de podermos depender só disto, e é por
  // isso que o `SyncEngine` também dispara ao voltar a haver rede.
  await Workmanager().registerPeriodicTask(
    kOutboxFlushTask,
    kOutboxFlushTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );
  await Workmanager().registerPeriodicTask(
    kHousekeepingTask,
    kHousekeepingTask,
    frequency: const Duration(hours: 12),
    constraints: Constraints(requiresBatteryNotLow: true),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  locator.get<SyncEngine>().start();
  await locator.get<BackgroundLocationService>().resumeIfShiftIsOpen();

  runApp(DriverApp(locator: locator));
}

/// Corpo do isolate de segundo plano. Tem de estar no topo do ficheiro e marcado como ponto de
/// entrada da VM, senão o tree shaking do build de release deita-o fora e as tarefas passam a
/// falhar em silêncio — foi assim que a versão 4.0.3 chegou à loja sem sincronização em segundo
/// plano durante nove dias.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final environment = DriverEnvironment.fromDartDefines();
    final locator = await ServiceLocator.bootstrap(environment, headless: true);

    try {
      switch (task) {
        case kOutboxFlushTask:
          final report = await locator.get<SyncEngine>().flush();
          // Devolver `false` faz o WorkManager repetir com o seu próprio recuo. Só o fazemos
          // quando ficou mesmo alguma coisa por publicar; um lote limpo não merece uma segunda
          // ida ao rádio.
          return report.isClean;
        case kHousekeepingTask:
          await locator.prune();
          return true;
        default:
          return true;
      }
    } finally {
      await locator.dispose();
    }
  });
}
