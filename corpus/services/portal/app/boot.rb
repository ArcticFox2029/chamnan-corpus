# frozen_string_literal: true
#
# Charge et fige la configuration du processus au démarrage : variables OF_*, journalisation,
# registre de métriques, et surtout la résolution d'adresse des services amont. Tout le reste
# du portail lit sa configuration ici et nulle part ailleurs, ce qui rend l'absence d'une
# variable détectable au boot plutôt qu'au premier clic d'un opérateur.

require 'json'
require 'time'
require 'logger'
require 'uri'

module Portal
  # Liste fermée de §0.6. Une région absente de cette liste est une faute de frappe dans le
  # manifeste, jamais une nouvelle région : la résidence des données se déclare d'abord côté
  # infra/, jamais dans un service.
  REGION_CODES = %w[
    eu-west eu-central na-east na-west apac-sg apac-jp latam-br mea-ae
  ].freeze

  # Ports d'écoute in-cluster de §1. Le portail en a besoin parce que §5 ne déclare de variable
  # d'adresse HTTP que pour une partie des services : OF_BILLING_BASE_URL, OF_CUSTOMS_BASE_URL,
  # OF_DOCUMENT_BASE_URL, OF_FLEET_BASE_URL, OF_ROUTING_BASE_URL et OF_ANALYTICS_BASE_URL
  # existent, mais container-registry et telemetry-ingest ne sont exposés que par leur adresse
  # gRPC (OF_CONTAINER_REGISTRY_GRPC_ADDR). Le portail n'embarque pas de pile gRPC : pour ces
  # deux-là il reconstruit l'URL à partir de la convention de nommage in-cluster de §1.
  SERVICE_PORTS = {
    'identity-service'       => 8081,
    'fleet-service'          => 8082,
    'container-registry'     => 8083,
    'telemetry-ingest'       => 8084,
    'routing-service'        => 8085,
    'geo-service'            => 8086,
    'customs-service'        => 8087,
    'billing-service'        => 8088,
    'document-service'       => 8089,
    'notification-service'   => 8090,
    'partner-portal-api'     => 8091,
    'audit-ledger'           => 8092,
    'analytics-pipeline'     => 8093,
    'reconciliation-service' => 8094
  }.freeze

  # Variable §5 qui l'emporte, quand elle existe, sur la convention ci-dessus.
  BASE_URL_ENV = {
    'billing-service'        => 'OF_BILLING_BASE_URL',
    'customs-service'        => 'OF_CUSTOMS_BASE_URL',
    'document-service'       => 'OF_DOCUMENT_BASE_URL',
    'fleet-service'          => 'OF_FLEET_BASE_URL',
    'routing-service'        => 'OF_ROUTING_BASE_URL',
    'analytics-pipeline'     => 'OF_ANALYTICS_BASE_URL'
  }.freeze

  CLUSTER_DOMAIN = 'orbitalfreight.svc.cluster.local'

  # §5 ne déclare aucune variable de version : la liste OF_* y est fermée et la règle 1 de §7
  # interdit d'en inventer une. Les informations de compilation sont donc cuites dans l'image par
  # le pipeline et lues ici, une fois, plutôt qu'injectées à l'exécution.
  BUILD_INFO_PATH = '/etc/orbitalfreight/build.json'

  Config = Struct.new(
    :environment, :region_code, :service_name, :log_level, :log_format, :http_port,
    :jwks_url, :jwks_grace_seconds, :shutdown_grace_seconds, :otel_endpoint, :otel_sample_ratio,
    keyword_init: true
  )

  class ConfigurationError < StandardError; end

  class << self
    attr_reader :config, :logger, :metrics

    def boot!
      @config = build_config
      @logger = build_logger(@config)
      @metrics = Metrics.new
      @service_urls = {}

      logger.info(
        msg: 'portal booted',
        environment: config.environment,
        region_code: config.region_code,
        http_port: config.http_port
      )
      @config
    end

    # Résout l'URL de base d'un service amont. Le résultat est mémorisé : la résolution DNS est
    # laissée à Net::HTTP, mais recomposer la chaîne à chaque requête d'écran n'apporte rien.
    def service_url(service_name)
      name = service_name.to_s
      raise ConfigurationError, "service inconnu de §1 : #{name}" unless SERVICE_PORTS.key?(name)

      @service_urls[name] ||= begin
        from_env = BASE_URL_ENV[name] && ENV[BASE_URL_ENV[name]]
        from_env && !from_env.empty? ? from_env.chomp('/') : default_service_url(name)
      end
    end

    # @return [Hash] { 'version' => …, 'commit' => … } ; valeurs de repli hors image.
    def build_info
      @build_info ||=
        begin
          JSON.parse(File.read(BUILD_INFO_PATH))
        rescue Errno::ENOENT, JSON::ParserError
          { 'version' => '0.0.0-dev', 'commit' => 'unknown' }
        end
    end

    def user_agent
      @user_agent ||= "orbitalfreight-portal/#{build_info.fetch('version')}"
    end

    def env?(name)
      config.environment == name.to_s
    end

    private

    def default_service_url(name)
      "http://#{name}.#{CLUSTER_DOMAIN}:#{SERVICE_PORTS.fetch(name)}"
    end

    def build_config
      region = require_env('OF_REGION_CODE')
      unless REGION_CODES.include?(region)
        raise ConfigurationError, "OF_REGION_CODE=#{region} absent de la liste fermée de §0.6"
      end

      Config.new(
        environment: require_env('OF_ENVIRONMENT'),
        region_code: region,
        service_name: ENV.fetch('OF_SERVICE_NAME', 'portal'),
        log_level: ENV.fetch('OF_LOG_LEVEL', 'info'),
        log_format: ENV.fetch('OF_LOG_FORMAT', 'json'),
        http_port: Integer(ENV.fetch('OF_HTTP_PORT', '8080')),
        jwks_url: require_env('OF_IDENTITY_JWKS_URL'),
        jwks_grace_seconds: Integer(ENV.fetch('OF_IDENTITY_JWKS_GRACE_SECONDS', '300')),
        shutdown_grace_seconds: Integer(ENV.fetch('OF_SHUTDOWN_GRACE_SECONDS', '25')),
        otel_endpoint: ENV['OF_OTEL_EXPORTER_ENDPOINT'],
        otel_sample_ratio: Float(ENV.fetch('OF_OTEL_SAMPLE_RATIO', '0.05'))
      )
    end

    def require_env(name)
      value = ENV[name]
      raise ConfigurationError, "variable obligatoire absente : #{name}" if value.nil? || value.empty?

      value
    end

    def build_logger(config)
      logger = Logger.new($stdout)
      logger.level = Logger.const_get(config.log_level.upcase)

      if config.log_format == 'json'
        logger.formatter = proc do |severity, time, _prog, message|
          payload = message.is_a?(Hash) ? message : { msg: message.to_s }
          JSON.generate(
            { level: severity.downcase, ts: time.utc.iso8601(3), service: config.service_name }
              .merge(payload)
          ) + "\n"
        end
      else
        logger.formatter = proc { |sev, time, _prog, msg| "#{time.utc.iso8601} #{sev} #{msg}\n" }
      end

      logger
    end
  end

  # Registre minimal, suffisant pour l'exposition Prometheus de §3.15. Le portail tourne en
  # quelques réplicas derrière une session collante ; agréger en mémoire est acceptable ici,
  # ce qui ne serait pas le cas pour un service de la liste de §1.
  class Metrics
    def initialize
      @mutex = Mutex.new
      @counters = Hash.new(0)
      @histograms = Hash.new { |h, k| h[k] = [] }
    end

    def increment(name, labels = {}, by: 1)
      @mutex.synchronize { @counters[[name, labels]] += by }
    end

    def observe(name, value, labels = {})
      @mutex.synchronize do
        bucket = @histograms[[name, labels]]
        bucket << value
        bucket.shift if bucket.size > 2_048
      end
    end

    def snapshot
      @mutex.synchronize { [@counters.dup, @histograms.transform_values(&:dup)] }
    end
  end
end
