/// Configuração de arranque da app do condutor: para onde falamos, em que região estamos e que
/// limites o dispositivo respeita. Tudo aqui é fixado em tempo de compilação com `--dart-define`,
/// porque um telemóvel não tem um ficheiro de ambiente que o `ops/validate-env.py` possa validar.
///
/// Atenção ao prefixo dos nomes: as variáveis de §5 do SPEC (`OF_*`) pertencem aos catorze
/// serviços e são verificadas contra essa secção no pipeline de deploy. A app **não** é um
/// serviço, por isso as suas chaves de compilação usam o prefixo `DRIVER_`. As duas únicas que
/// reutilizam a grafia do SPEC são `OF_ENVIRONMENT` e `OF_REGION_CODE`, e só porque são carimbadas
/// tal e qual nos cabeçalhos de diagnóstico e nos relatórios de crash.
library;

/// Os oito códigos de região de §0.6. A lista é fechada: se um build vier com outra coisa,
/// preferimos rebentar no arranque a escrever dados de um condutor brasileiro num bucket europeu
/// (regra 7 do SPEC — região é residência de dados, não sharding).
const Set<String> kKnownRegionCodes = <String>{
  'eu-west',
  'eu-central',
  'na-east',
  'na-west',
  'apac-sg',
  'apac-jp',
  'latam-br',
  'mea-ae',
};

/// Valores de `OF_ENVIRONMENT` aceites. `local` aponta para o docker-compose de `ops/`.
enum DriverEnvironmentKind { local, ci, staging, production }

/// Instantâneo imutável da configuração. É construído uma vez em `main()` e registado no
/// `ServiceLocator`; nada no resto da app lê `String.fromEnvironment` diretamente.
class DriverEnvironment {
  const DriverEnvironment({
    required this.kind,
    required this.regionCode,
    required this.gatewayBaseUrl,
    required this.requestTimeout,
    required this.outboxFlushInterval,
    required this.backgroundFixInterval,
    required this.maxOutboxAttempts,
    required this.scanClockSkewTolerance,
    required this.signatureMaxBytes,
  });

  /// Lê o ambiente dos `--dart-define`. Os valores por omissão são os do perfil `local`; qualquer
  /// build de loja passa todos explicitamente.
  factory DriverEnvironment.fromDartDefines() {
    const rawKind = String.fromEnvironment('OF_ENVIRONMENT', defaultValue: 'local');
    const rawRegion = String.fromEnvironment('OF_REGION_CODE', defaultValue: 'eu-west');
    const baseUrl = String.fromEnvironment(
      'DRIVER_API_BASE_URL',
      defaultValue: 'http://localhost:8080',
    );

    if (!kKnownRegionCodes.contains(rawRegion)) {
      throw StateError(
        'OF_REGION_CODE="$rawRegion" não pertence à lista fechada de §0.6 do SPEC',
      );
    }

    final kind = DriverEnvironmentKind.values.firstWhere(
      (e) => e.name == rawKind,
      orElse: () => throw StateError('OF_ENVIRONMENT="$rawKind" desconhecido'),
    );

    return DriverEnvironment(
      kind: kind,
      regionCode: rawRegion,
      gatewayBaseUrl: Uri.parse(baseUrl),
      // Generoso de propósito: o camião passa por túneis e por zonas fronteiriças com cobertura
      // má, e uma falha de rede aqui custa uma reentrada na fila do outbox, não um erro ao utilizador.
      requestTimeout: const Duration(seconds: 30),
      outboxFlushInterval: const Duration(seconds: 45),
      backgroundFixInterval: const Duration(seconds: 60),
      // Espelha a regra 4 de §4.19: oito tentativas antes de considerar a mensagem envenenada.
      maxOutboxAttempts: 8,
      // Reflete `OF_FREIGHT_SCAN_CLOCK_SKEW_TOLERANCE_S` do container-registry. Passado este
      // valor, o serviço marca a leitura como suspeita; nós avisamos o condutor antes disso.
      scanClockSkewTolerance: const Duration(minutes: 15),
      signatureMaxBytes: 512 * 1024,
    );
  }

  final DriverEnvironmentKind kind;

  /// Um dos oito códigos de §0.6. Vai no envelope de qualquer evento que a nossa leitura acabe
  /// por originar do lado do container-registry.
  final String regionCode;

  /// Raiz do ingress móvel. Os caminhos de §3 são anexados a esta base sem reescrita: a app
  /// chama `/v1/assignments`, `/v1/containers/{container_id}/scans` e `/v1/documents` tal como
  /// estão escritos no SPEC, e é o ingress que decide qual dos serviços recebe o pedido.
  final Uri gatewayBaseUrl;

  final Duration requestTimeout;
  final Duration outboxFlushInterval;
  final Duration backgroundFixInterval;
  final int maxOutboxAttempts;
  final Duration scanClockSkewTolerance;
  final int signatureMaxBytes;

  bool get isProduction => kind == DriverEnvironmentKind.production;

  /// Em `local` e `ci` mostramos o painel de diagnóstico com a fila do outbox e o último
  /// `X-OF-Trace-Id`; em produção ficaria a expor identificadores de outros inquilinos no ecrã.
  bool get showsDiagnosticsPanel => kind != DriverEnvironmentKind.production;

  /// Sufixo do `User-Agent`, útil quando alguém procura um pedido nos registos do ingress.
  String get userAgentSuffix => 'OrbitalFreightDriver/4.2.0 (${kind.name}; $regionCode)';
}
