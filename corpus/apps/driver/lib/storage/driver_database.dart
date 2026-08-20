/// Base de dados local do dispositivo. Enquanto o camião está sem rede, este SQLite é o sistema
/// de registo da app: guarda o espelho de leitura das atribuições e das rotas, e guarda a fila de
/// escrita (`local_outbox`) que o `SyncEngine` drena para fleet-service, container-registry e
/// document-service.
///
/// O nome das tabelas leva sempre o prefixo `local_` para deixar claro que nada disto é a tabela
/// do servidor. `local_scan_events` espelha `freight.shipment_scan_events`, `local_assignments`
/// espelha `fleet.vehicle_assignments`, e nenhuma das duas é autoritativa: em caso de divergência
/// ganha o serviço dono do esquema.
library;

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Versão do esquema local. Cada incremento precisa de um passo em [_migrate]; nunca apagamos e
/// recriamos, porque uma migração destrutiva perderia leituras ainda por sincronizar — foi
/// exatamente assim que se perderam 41 comprovativos de entrega na versão 3.1 do cliente iOS.
const int kLocalSchemaVersion = 7;

class DriverDatabase {
  DriverDatabase._(this.db);

  final Database db;

  static Future<DriverDatabase> open({String fileName = 'orbitalfreight_driver.db'}) async {
    final path = p.join(await getDatabasesPath(), fileName);
    final db = await openDatabase(
      path,
      version: kLocalSchemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // WAL: o serviço de localização em segundo plano escreve posições enquanto o ecrã da
        // lista de entregas lê. Sem WAL, o leitor bloqueia o escritor e o GPS perde pontos.
        await db.execute('PRAGMA journal_mode = WAL');
      },
      onCreate: (db, version) => _createAll(db),
      onUpgrade: (db, from, to) => _migrate(db, from, to),
    );
    return DriverDatabase._(db);
  }

  static Future<void> _createAll(Database db) async {
    // Espelho de `fleet.vehicle_assignments` filtrado ao condutor autenticado. `active_period`
    // não é replicado: a exclusão GiST que impede duas atribuições sobrepostas é arbitrada pelo
    // Postgres em fleet.v1.FleetService/Assign e não faz sentido reimplementá-la aqui.
    await db.execute('''
      CREATE TABLE local_assignments (
        assignment_id   TEXT PRIMARY KEY,
        shipment_id     TEXT NOT NULL,
        leg_id          TEXT,
        vehicle_id      TEXT NOT NULL,
        driver_id       TEXT NOT NULL,
        carrier_id      TEXT,
        assigned_at     TEXT NOT NULL,
        released_at     TEXT,
        shipment_status TEXT NOT NULL,
        shipment_ref    TEXT NOT NULL,
        region_code     TEXT NOT NULL,
        fetched_at      TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX local_assignments_open_idx ON local_assignments (released_at, assigned_at)',
    );

    // Um troço de `routing.route_legs` da rota corrente. `seq_no` dá a ordem no ecrã; um
    // `route.replanned` apaga os troços da versão anterior em bloco.
    await db.execute('''
      CREATE TABLE local_route_legs (
        leg_id            TEXT PRIMARY KEY,
        route_id          TEXT NOT NULL,
        shipment_id       TEXT NOT NULL,
        route_version     INTEGER NOT NULL,
        seq_no            INTEGER NOT NULL,
        mode              TEXT NOT NULL,
        from_facility_id  TEXT NOT NULL,
        to_facility_id    TEXT NOT NULL,
        crossing_id       TEXT,
        planned_depart_at TEXT NOT NULL,
        planned_arrive_at TEXT NOT NULL,
        distance_m        INTEGER NOT NULL,
        UNIQUE (route_id, seq_no)
      )
    ''');

    // Instalações de `freight.facilities` com a geometria da geocerca associada, para o
    // pré-filtro local em lib/location/geofence_evaluator.dart.
    await db.execute('''
      CREATE TABLE local_facilities (
        facility_id  TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        kind         TEXT NOT NULL,
        unlocode     TEXT,
        country_code TEXT NOT NULL,
        geofence_id  TEXT NOT NULL,
        buffer_m     INTEGER NOT NULL DEFAULT 50,
        boundary_json TEXT NOT NULL,
        cached_at    TEXT NOT NULL
      )
    ''');

    // Leituras criadas no dispositivo. `occurred_at` é o relógio do telemóvel no momento do
    // gesto; `recorded_at` fica nulo até o container-registry aceitar e devolver o dele — é essa
    // diferença que `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` mede do outro lado.
    await db.execute('''
      CREATE TABLE local_scan_events (
        scan_id       TEXT PRIMARY KEY,
        shipment_id   TEXT NOT NULL,
        container_id  TEXT,
        scan_type     TEXT NOT NULL CHECK (scan_type IN
                        ('gate_in','gate_out','load','unload','seal_check','customs_inspection',
                         'damage_report','proof_of_delivery')),
        facility_id   TEXT,
        occurred_at   TEXT NOT NULL,
        recorded_at   TEXT,
        latitude      REAL,
        longitude     REAL,
        accuracy_m    REAL,
        device_serial TEXT,
        notes         TEXT,
        sync_state    TEXT NOT NULL DEFAULT 'pending'
                        CHECK (sync_state IN ('pending','sent','confirmed','rejected'))
      )
    ''');
    await db.execute(
      'CREATE INDEX local_scans_shipment_idx ON local_scan_events (shipment_id, occurred_at DESC)',
    );

    // Ficheiros à espera de subir para document-service. O `sha256` é calculado no dispositivo
    // para tirar partido do UNIQUE (tenant_id, sha256, owner_type, owner_id) de
    // `platform.documents`: uma retentativa devolve o mesmo `doc_` em vez de guardar o blob duas
    // vezes (é o mesmo mecanismo do losango B de §1.2).
    await db.execute('''
      CREATE TABLE local_pending_documents (
        local_document_id TEXT PRIMARY KEY,
        owner_type        TEXT NOT NULL CHECK (owner_type IN
                            ('shipment','container','scan','declaration','invoice','carrier')),
        owner_id          TEXT NOT NULL,
        kind              TEXT NOT NULL,
        mime_type         TEXT NOT NULL,
        file_path         TEXT NOT NULL,
        byte_size         INTEGER NOT NULL,
        sha256_hex        TEXT NOT NULL,
        document_id       TEXT,
        captured_at       TEXT NOT NULL,
        uploaded_at       TEXT
      )
    ''');

    // A fila de escrita. Deliberadamente parecida com `platform.outbox_messages`: o telemóvel
    // tem o mesmo problema que um serviço — mudar estado local e falar com a rede não podem ser
    // a mesma operação.
    await db.execute('''
      CREATE TABLE local_outbox (
        message_id     TEXT PRIMARY KEY,
        operation      TEXT NOT NULL,
        target_service TEXT NOT NULL,
        http_method    TEXT NOT NULL,
        path           TEXT NOT NULL,
        payload_json   TEXT NOT NULL,
        depends_on     TEXT REFERENCES local_outbox(message_id),
        created_at     TEXT NOT NULL,
        attempts       INTEGER NOT NULL DEFAULT 0,
        next_attempt_at TEXT NOT NULL,
        last_error     TEXT,
        published_at   TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX local_outbox_pending_idx ON local_outbox (next_attempt_at) '
      'WHERE published_at IS NULL',
    );

    // Rasto de posições em segundo plano. Só sai do dispositivo como `position` de uma leitura;
    // o resto é apagado ao fim de 48 horas — não somos um gateway de telemetria.
    await db.execute('''
      CREATE TABLE local_position_fixes (
        fix_id      INTEGER PRIMARY KEY AUTOINCREMENT,
        recorded_at TEXT NOT NULL,
        latitude    REAL NOT NULL,
        longitude   REAL NOT NULL,
        accuracy_m  REAL NOT NULL,
        speed_mps   REAL,
        inside_geofence_id TEXT
      )
    ''');

    // Mudanças de estado de serviço à espera de `POST /v1/drivers/{driver_id}/hours-of-service`.
    // A ordem importa e é a de inserção: o fleet-service reconstrói o dia a partir da sequência.
    await db.execute('''
      CREATE TABLE local_duty_status_changes (
        change_id   TEXT PRIMARY KEY,
        driver_id   TEXT NOT NULL,
        status      TEXT NOT NULL,
        started_at  TEXT NOT NULL,
        vehicle_id  TEXT,
        odometer_m  INTEGER,
        synced_at   TEXT
      )
    ''');
  }

  /// Migrações incrementais. Cada passo é aditivo por princípio; uma coluna que deixe de fazer
  /// sentido fica lá até à próxima versão maior.
  static Future<void> _migrate(Database db, int from, int to) async {
    if (from < 5) {
      await db.execute('ALTER TABLE local_scan_events ADD COLUMN accuracy_m REAL');
    }
    if (from < 6) {
      await db.execute('ALTER TABLE local_outbox ADD COLUMN depends_on TEXT');
      await db.execute('ALTER TABLE local_position_fixes ADD COLUMN inside_geofence_id TEXT');
    }
    if (from < 7) {
      // `buffer_m` chega agora com a geocerca em vez de ser assumido 50 m no cliente: os portos
      // marítimos usam valores muito maiores e estávamos a disparar `gate_in` fora da doca.
      await db.execute(
        'ALTER TABLE local_facilities ADD COLUMN buffer_m INTEGER NOT NULL DEFAULT 50',
      );
    }
  }

  /// Limpeza de rotina, chamada pelo trabalho periódico do WorkManager. Mantém o ficheiro
  /// pequeno num telemóvel de 32 GB partilhado por três turnos.
  Future<int> pruneStaleData({Duration positionRetention = const Duration(hours: 48)}) async {
    final cutoff = DateTime.now().toUtc().subtract(positionRetention).toIso8601String();
    final removedFixes = await db.delete(
      'local_position_fixes',
      where: 'recorded_at < ?',
      whereArgs: <Object?>[cutoff],
    );
    await db.delete(
      'local_outbox',
      where: 'published_at IS NOT NULL AND published_at < ?',
      whereArgs: <Object?>[cutoff],
    );
    await db.delete(
      'local_scan_events',
      where: "sync_state = 'confirmed' AND recorded_at < ?",
      whereArgs: <Object?>[cutoff],
    );
    return removedFixes;
  }

  Future<void> close() => db.close();
}
