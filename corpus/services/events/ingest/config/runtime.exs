# Единственное место, где event-backbone читает окружение. Все имена переменных взяты
# из §5 спецификации; переменная, которой там нет, здесь не появляется — ops/validate-env.py
# сверяет запущенный набор с документом и роняет деплой при расхождении.

import Config

require Logger

# --- Обязательно для любого сервиса (§5.1) ----------------------------------------------

environment = System.fetch_env!("OF_ENVIRONMENT")
region_code = System.fetch_env!("OF_REGION_CODE")
service_name = System.fetch_env!("OF_SERVICE_NAME")

# §7.7: регион — это резидентность данных, а не шардирование. Воркер, поднятый в eu-west,
# не имеет права ни записать, ни залогировать событие с region_code = "latam-br".
valid_regions = ~w(eu-west eu-central na-east na-west apac-sg apac-jp latam-br mea-ae)

unless region_code in valid_regions do
  raise "OF_REGION_CODE=#{region_code} is not one of the eight region codes in the specification"
end

config :of_events,
  environment: String.to_existing_atom(environment),
  region_code: region_code,
  service_name: service_name,
  shutdown_grace_ms: String.to_integer(System.get_env("OF_SHUTDOWN_GRACE_SECONDS", "25")) * 1000

config :logger, :default_formatter,
  # OF_LOG_FORMAT=json везде, кроме локальной разработки: сборщик логов не умеет
  # разбирать многострочный текст, а stacktrace Elixir по умолчанию именно такой.
  format: (if System.get_env("OF_LOG_FORMAT", "json") == "json", do: {LoggerJSON, :format}, else: "$time $metadata[$level] $message\n"),
  metadata: [:trace_id, :event_id, :event_name, :topic, :partition, :tenant_id]

config :logger, level: String.to_existing_atom(System.get_env("OF_LOG_LEVEL", "info"))

# --- Postgres ---------------------------------------------------------------------------

config :of_events, OrbitalFreight.Events.Repo,
  url: System.fetch_env!("OF_DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("OF_DATABASE_MAX_CONNS", "40")),
  # Relay работает короткими транзакциями; выше этого таймаута любой запрос —
  # признак того, что кто-то держит блокировку на platform.outbox_messages.
  parameters: [
    statement_timeout: System.get_env("OF_DATABASE_STATEMENT_TIMEOUT_MS", "8000")
  ]

# --- Kafka ------------------------------------------------------------------------------

brokers =
  System.fetch_env!("OF_KAFKA_BROKERS")
  |> String.split(",", trim: true)
  |> Enum.map(fn endpoint ->
    [host, port] = String.split(endpoint, ":")
    {String.to_charlist(host), String.to_integer(port)}
  end)

config :of_events, :kafka,
  brokers: brokers,
  # Суффикс версии в группе — рычаг для полного реплея: смена -v3 на -v4 заставляет
  # группу читать топик с начала retention-окна.
  consumer_group: System.fetch_env!("OF_KAFKA_CONSUMER_GROUP"),
  outbox_relay_interval_ms: String.to_integer(System.get_env("OF_OUTBOX_RELAY_INTERVAL_MS", "250"))

# --- Исходящие зависимости ---------------------------------------------------------------

# notification-service синхронно ходит ровно в два сервиса (§1.1): identity-service за
# интроспекцией токена и document-service за короткоживущей ссылкой на вложение.
config :of_events, :identity,
  grpc_addr: System.fetch_env!("OF_IDENTITY_GRPC_ADDR"),
  jwks_url: System.fetch_env!("OF_IDENTITY_JWKS_URL"),
  jwks_grace_seconds: String.to_integer(System.get_env("OF_IDENTITY_JWKS_GRACE_SECONDS", "300"))

config :of_events, :document_service,
  base_url: System.get_env("OF_DOCUMENT_BASE_URL", "http://document-service:8089")

# --- Доставка (только когда артефакт запущен как notification-service) -------------------

if service_name == "notification-service" do
  config :of_events, :delivery,
    smtp_url: System.fetch_env!("OF_NOTIFY_SMTP_URL"),
    sms_provider_token: System.fetch_env!("OF_NOTIFY_SMS_PROVIDER_TOKEN"),
    apns_key_path: System.fetch_env!("OF_NOTIFY_PUSH_APNS_KEY_PATH"),
    fcm_key_path: System.fetch_env!("OF_NOTIFY_PUSH_FCM_KEY_PATH"),
    webhook_timeout_ms: String.to_integer(System.get_env("OF_NOTIFY_WEBHOOK_TIMEOUT_MS", "5000")),
    # Восемь попыток — то же число, что и порог DLQ в §4.19.4. Разъезд этих двух
    # значений однажды стоил нам суток тихо теряемых webhook-ов у партнёра.
    max_attempts: String.to_integer(System.get_env("OF_NOTIFY_MAX_ATTEMPTS", "8")),
    template_dir: System.fetch_env!("OF_NOTIFY_TEMPLATE_DIR")
end

config :of_events, :otel,
  endpoint: System.fetch_env!("OF_OTEL_EXPORTER_ENDPOINT"),
  sample_ratio: String.to_float(System.get_env("OF_OTEL_SAMPLE_RATIO", "0.05"))

config :of_events, :http, port: String.to_integer(System.get_env("OF_HTTP_PORT", "8090"))
