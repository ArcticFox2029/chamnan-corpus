/// Raiz de composição da app: constrói uma única vez o SQLite local, a sessão, o cliente HTTP e
/// todos os repositórios, e é a única coisa no projeto que sabe como as peças se ligam umas às
/// outras. Existe porque o isolate de segundo plano do WorkManager precisa exatamente do mesmo
/// grafo de objetos que a UI, sem widgets pelo meio.
///
/// Regra que este ficheiro impõe: nada abaixo de `lib/app/` chama `GetIt` diretamente. Os
/// repositórios recebem as dependências pelo construtor, o que os torna testáveis sem registo
/// global — ver `test/` para os duplos usados.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get_it/get_it.dart';
import 'package:sqflite/sqflite.dart';

import '../core/config/driver_environment.dart';
import '../core/network/of_api_client.dart';
import '../core/network/of_session.dart';
import '../features/assignments/data/fleet_repository.dart';
import '../features/auth/data/identity_repository.dart';
import '../features/documents/data/document_repository.dart';
import '../features/hos/data/hours_of_service_repository.dart';
import '../features/pod/data/proof_of_delivery_repository.dart';
import '../features/route/data/route_repository.dart';
import '../features/scanning/data/scan_repository.dart';
import '../location/background_location_service.dart';
import '../location/geofence_evaluator.dart';
import '../notifications/alert_inbox.dart';
import '../notifications/push_registrar.dart';
import '../storage/driver_database.dart';
import '../sync/outbox_dao.dart';
import '../sync/sync_engine.dart';

class ServiceLocator {
  ServiceLocator._(this._getIt, this._database);

  final GetIt _getIt;
  final DriverDatabase _database;

  /// Constrói o grafo. `headless: true` salta tudo o que precise de contexto de UI — as
  /// notificações locais e o registo de push, que não podem ser inicializados fora do isolate
  /// principal sem rebentar no arranque do Android.
  static Future<ServiceLocator> bootstrap(
    DriverEnvironment environment, {
    bool headless = false,
  }) async {
    final getIt = GetIt.asNewInstance();
    final database = await DriverDatabase.open();

    getIt.registerSingleton<DriverEnvironment>(environment);
    getIt.registerSingleton<Database>(database.db);

    final session = OfSession(const FlutterSecureStorage());
    await session.restore();
    getIt.registerSingleton<OfSession>(session);

    final api = OfApiClient(environment: environment, session: session);
    getIt.registerSingleton<OfApiClient>(api);

    final identity = IdentityRepository(api: api, session: session);
    // Fecha o ciclo entre o cliente e o repositório sem que nenhum dos dois importe o outro:
    // o `OfApiClient` sabe pedir uma renovação, mas não sabe a quem.
    api.tokenRefresher = identity.refreshAccessToken;
    getIt.registerSingleton<IdentityRepository>(identity);

    final outbox = OutboxDao(database.db);
    getIt.registerSingleton<OutboxDao>(outbox);

    final geofences = GeofenceEvaluator(database.db);
    getIt.registerSingleton<GeofenceEvaluator>(geofences);

    final fleet = FleetRepository(api: api, db: database.db, session: session);
    final routes = RouteRepository(api: api, db: database.db);
    final documents = DocumentRepository(
      api: api,
      db: database.db,
      outbox: outbox,
      session: session,
      environment: environment,
    );
    final scans = ScanRepository(
      db: database.db,
      outbox: outbox,
      session: session,
      geofences: geofences,
      environment: environment,
    );

    getIt.registerSingleton<FleetRepository>(fleet);
    getIt.registerSingleton<RouteRepository>(routes);
    getIt.registerSingleton<DocumentRepository>(documents);
    getIt.registerSingleton<ScanRepository>(scans);
    getIt.registerSingleton<ProofOfDeliveryRepository>(
      ProofOfDeliveryRepository(
        db: database.db,
        outbox: outbox,
        scans: scans,
        documents: documents,
        session: session,
      ),
    );
    getIt.registerSingleton<HoursOfServiceRepository>(
      HoursOfServiceRepository(api: api, db: database.db, outbox: outbox, session: session),
    );

    getIt.registerSingleton<SyncEngine>(
      SyncEngine(
        api: api,
        outbox: outbox,
        db: database.db,
        fleet: fleet,
        routes: routes,
        environment: environment,
      ),
    );

    getIt.registerSingleton<BackgroundLocationService>(
      BackgroundLocationService(
        db: database.db,
        geofences: geofences,
        environment: environment,
      ),
    );

    if (!headless) {
      final push = PushRegistrar(api: api, session: session);
      await push.attach();
      getIt.registerSingleton<PushRegistrar>(push);

      // A caixa de alertas tem de existir antes de a primeira mensagem chegar: o FCM entrega
      // logo o que estiver pendente quando a app abre, e sem ouvinte registado essa mensagem
      // perde-se sem deixar rasto.
      final inbox = AlertInbox(
        db: database.db,
        sync: getIt.get<SyncEngine>(),
        routes: routes,
      );
      await inbox.attach();
      getIt.registerSingleton<AlertInbox>(inbox);
    }

    return ServiceLocator._(getIt, database);
  }

  T get<T extends Object>() => _getIt.get<T>();

  /// Poda a base local. Chamado pela tarefa `of.driver.housekeeping`.
  Future<void> prune() => _database.pruneStaleData();

  /// Fecha tudo o que tem estado de sistema. No isolate de segundo plano isto é obrigatório: um
  /// SQLite deixado aberto mantém o ficheiro WAL a crescer entre execuções da tarefa.
  Future<void> dispose() async {
    if (_getIt.isRegistered<SyncEngine>()) {
      await _getIt.get<SyncEngine>().stop();
    }
    if (_getIt.isRegistered<BackgroundLocationService>()) {
      await _getIt.get<BackgroundLocationService>().stop();
    }
    await _database.close();
    await _getIt.reset();
  }
}
