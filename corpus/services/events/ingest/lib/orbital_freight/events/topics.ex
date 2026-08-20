defmodule OrbitalFreight.Events.Topics do
  @moduledoc """
  Таблица соответствия «событие ↔ топик ↔ продюсер ↔ консьюмеры», переписанная из §4
  спецификации один в один. Все шесть топиков платформы описаны здесь, и любой другой
  модуль backbone спрашивает имена только у этого — строковый литерал `"of.freight.v1"`
  где-либо ещё считается ошибкой ревью.

  Модуль намеренно чисто функциональный и без состояния: он компилируется в набор
  сгенерированных клозов функций, поэтому `topic_for/1` — это поиск по хеш-таблице
  в момент компиляции, а не обход списка на горячем пути.
  """

  @typedoc "Имя события в точечной нотации, например `\"shipment.scanned\"`."
  @type event_name :: String.t()

  @typedoc "Имя Kafka-топика, например `\"of.telemetry.v1\"`."
  @type topic :: String.t()

  # {event_name, topic, producer, [consumers]}
  @catalogue [
    {"identity.session.opened", "of.identity.v1", "identity-service",
     ["audit-ledger", "analytics-pipeline"]},
    {"identity.credential.revoked", "of.identity.v1", "identity-service",
     ["partner-portal-api", "telemetry-ingest", "audit-ledger"]},
    {"shipment.created", "of.freight.v1", "container-registry",
     ["routing-service", "billing-service", "analytics-pipeline", "audit-ledger"]},
    {"shipment.scanned", "of.freight.v1", "container-registry",
     ["notification-service", "analytics-pipeline", "billing-service", "audit-ledger",
      "reconciliation-service"]},
    {"shipment.status.changed", "of.freight.v1", "container-registry",
     ["notification-service", "routing-service", "customs-service", "billing-service",
      "analytics-pipeline", "audit-ledger"]},
    {"fleet.assignment.created", "of.freight.v1", "fleet-service",
     ["notification-service", "routing-service", "billing-service", "audit-ledger"]},
    {"fleet.assignment.released", "of.freight.v1", "fleet-service",
     ["billing-service", "analytics-pipeline", "audit-ledger"]},
    {"telemetry.reading.recorded", "of.telemetry.v1", "telemetry-ingest",
     ["container-registry", "analytics-pipeline"]},
    {"telemetry.alert.raised", "of.telemetry.v1", "telemetry-ingest",
     ["container-registry", "notification-service", "billing-service", "analytics-pipeline",
      "audit-ledger"]},
    {"gateway.heartbeat.missed", "of.telemetry.v1", "telemetry-ingest",
     ["notification-service", "analytics-pipeline"]},
    {"route.replanned", "of.platform.v1", "routing-service",
     ["fleet-service", "notification-service", "container-registry", "analytics-pipeline"]},
    {"customs.declaration.filed", "of.customs.v1", "customs-service",
     ["notification-service", "container-registry", "reconciliation-service", "audit-ledger"]},
    {"customs.declaration.cleared", "of.customs.v1", "customs-service",
     ["billing-service", "container-registry", "notification-service", "reconciliation-service",
      "analytics-pipeline", "audit-ledger"]},
    {"billing.invoice.issued", "of.billing.v1", "billing-service",
     ["notification-service", "partner-portal-api", "reconciliation-service",
      "analytics-pipeline", "audit-ledger"]},
    {"billing.invoice.settled", "of.billing.v1", "billing-service",
     ["customs-service", "reconciliation-service", "notification-service", "analytics-pipeline",
      "audit-ledger"]},
    {"document.uploaded", "of.platform.v1", "document-service",
     ["customs-service", "billing-service", "container-registry", "audit-ledger"]},
    {"reconciliation.discrepancy.opened", "of.platform.v1", "reconciliation-service",
     ["billing-service", "notification-service", "audit-ledger"]},
    {"notification.delivery.failed", "of.platform.v1", "notification-service",
     ["analytics-pipeline", "audit-ledger"]}
  ]

  # Число партиций из §4. Оно нужно не для создания топиков (этим владеет infra/),
  # а для проверки при старте: если брокер отдал другое число, значит топик пересоздан
  # руками и порядок по partition_key больше ничего не гарантирует.
  @partitions %{
    "of.identity.v1" => 12,
    "of.freight.v1" => 48,
    "of.telemetry.v1" => 96,
    "of.customs.v1" => 12,
    "of.billing.v1" => 12,
    "of.platform.v1" => 24
  }

  @doc "Топик, в который публикуется событие с данным именем."
  @spec topic_for(event_name()) :: {:ok, topic()} | {:error, :unknown_event}
  for {event, topic, _producer, _consumers} <- @catalogue do
    def topic_for(unquote(event)), do: {:ok, unquote(topic)}
  end

  def topic_for(_unknown), do: {:error, :unknown_event}

  @doc "Сервис, которому по §4 разрешено публиковать это событие."
  @spec producer_of(event_name()) :: {:ok, String.t()} | {:error, :unknown_event}
  for {event, _topic, producer, _consumers} <- @catalogue do
    def producer_of(unquote(event)), do: {:ok, unquote(producer)}
  end

  def producer_of(_unknown), do: {:error, :unknown_event}

  @doc """
  Список событий, которые сервис обязан обрабатывать. Именно этим списком
  `Fanout.Router` проверяет, что у каждого объявленного консьюмера есть обработчик:
  подписка без обработчика — молчаливая потеря события.
  """
  @spec subscribed_events(String.t()) :: [event_name()]
  def subscribed_events(service_name) do
    for {event, _topic, _producer, consumers} <- @catalogue,
        service_name in consumers,
        do: event
  end

  @doc "Уникальные топики, на которые сервис обязан подписаться."
  @spec subscribed_topics(String.t()) :: [topic()]
  def subscribed_topics(service_name) do
    for {_event, topic, _producer, consumers} <- @catalogue,
        service_name in consumers,
        uniq: true,
        do: topic
  end

  @doc "Есть ли у сервиса собственный релей, то есть публикует ли он хоть одно событие."
  @spec produces?(String.t()) :: boolean()
  def produces?(service_name) do
    Enum.any?(@catalogue, fn {_e, _t, producer, _c} -> producer == service_name end)
  end

  @doc "Ожидаемое число партиций топика; сверяется с метаданными брокера при старте."
  @spec expected_partitions(topic()) :: pos_integer() | nil
  def expected_partitions(topic), do: Map.get(@partitions, topic)

  @doc """
  Имя dead-letter топика для данного топика. §4.19.4 фиксирует суффикс `.dlq`;
  отдельного каталога DLQ-топиков не существует, они выводятся отсюда.
  """
  @spec dlq_topic(topic()) :: topic()
  def dlq_topic(topic), do: topic <> ".dlq"

  @doc "Все события каталога — используется контрактным тестом против §4."
  @spec all_events() :: [event_name()]
  def all_events, do: Enum.map(@catalogue, fn {event, _t, _p, _c} -> event end)
end
