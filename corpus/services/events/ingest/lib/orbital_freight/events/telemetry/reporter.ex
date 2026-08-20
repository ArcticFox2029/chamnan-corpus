defmodule OrbitalFreight.Events.Telemetry.Reporter do
  @moduledoc """
  Все счётчики и гистограммы event-backbone в одном месте; их отдаёт
  `GET /metrics` (§3.15). Модуль намеренно тонкий: обработчики зовут именованные
  функции вроде `duplicate/1`, а не собирают события телеметрии руками, — так
  имена метрик нельзя разъехать между модулями, и их видно списком.

  Что здесь важно для дежурного:

    * `of_events_outbox_pending` — глубина `platform.outbox_messages` по продюсеру.
      Всё, что выше нуля дольше секунды, означает расхождение состояния базы с шиной;
    * `of_events_consumer_lag_ms` — задержка от записи в брокер до обработки. Рост
      на `of.billing.v1` напрямую задерживает `duty_paid` в customs-service (§4.15);
    * `of_events_dead_lettered_total` — по одному лейблу на топик и событие; любой
      ненулевой прирост разбирается человеком, автоматического повтора из DLQ нет;
    * `of_events_foreign_region_skipped_total` — событие чужого региона. Стабильно
      растущий счётчик означает неверный `OF_REGION_CODE` или топик, в который
      пишут все регионы сразу, и это нарушение §7.7, а не безобидный шум.

  Лейбл `tenant_id` не используется нигде. Тенантов тысячи, и кардинальность
  такого лейбла однажды положила Prometheus вместе с половиной алертинга.
  """

  use GenServer

  alias OrbitalFreight.Events.Outbox.Publication
  alias OrbitalFreight.Events.Topics

  @scrape_interval_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Итог одного прохода релея: сколько строк опубликовано и сколько не удалось."
  @spec outbox_batch(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def outbox_batch(producer, published, failed) do
    :telemetry.execute([:of_events, :outbox, :batch], %{published: published, failed: failed}, %{producer: producer})
  end

  @doc "Сообщение обработано; `lag_ms` — от записи в брокер до конца обработки."
  @spec message_handled(String.t(), non_neg_integer(), integer()) :: :ok
  def message_handled(topic, partition, lag_ms) do
    :telemetry.execute([:of_events, :consumer, :message], %{lag_ms: lag_ms}, %{topic: topic, partition: partition})
  end

  @doc "Повторно пришедший `event_id` — норма при at-least-once, но не при взрывном росте."
  @spec duplicate(String.t()) :: :ok
  def duplicate(topic), do: :telemetry.execute([:of_events, :consumer, :duplicate], %{count: 1}, %{topic: topic})

  @doc "Событие чужого региона, отброшенное на границе по §7.7."
  @spec foreign_region_skipped(String.t(), String.t()) :: :ok
  def foreign_region_skipped(topic, event_region) do
    :telemetry.execute([:of_events, :consumer, :foreign_region], %{count: 1}, %{topic: topic, event_region: event_region})
  end

  @doc "Сообщение припарковано в `<topic>.dlq` после восьми попыток."
  @spec dead_lettered(String.t(), String.t()) :: :ok
  def dead_lettered(topic, event_name) do
    :telemetry.execute([:of_events, :consumer, :dead_letter], %{count: 1}, %{topic: topic, event_name: event_name})
  end

  @doc "Обработчик справился на повторной попытке — метрика качества, а не ошибки."
  @spec recovered_after_retry(String.t(), String.t()) :: :ok
  def recovered_after_retry(topic, event_name) do
    :telemetry.execute([:of_events, :consumer, :recovered], %{count: 1}, %{topic: topic, event_name: event_name})
  end

  @doc "Уведомление ушло получателю по конкретному каналу."
  @spec delivered(String.t(), String.t()) :: :ok
  def delivered(template_code, channel) do
    :telemetry.execute([:of_events, :delivery, :sent], %{count: 1}, %{template: template_code, channel: channel})
  end

  @doc "Уведомление отложено до конца тихих часов получателя."
  @spec deferred(String.t(), String.t()) :: :ok
  def deferred(template_code, channel) do
    :telemetry.execute([:of_events, :delivery, :deferred], %{count: 1}, %{template: template_code, channel: channel})
  end

  @doc "Алерт телеметрии, разложенный по `rule_code` и severity 1–5."
  @spec alert_seen(String.t(), integer()) :: :ok
  def alert_seen(rule_code, severity) do
    :telemetry.execute([:of_events, :alert, :seen], %{count: 1}, %{rule_code: rule_code, severity: severity})
  end

  @impl GenServer
  def init(_opts) do
    metrics = [
      counter("of_events.outbox.batch.published", tags: [:producer]),
      counter("of_events.outbox.batch.failed", tags: [:producer]),
      last_value("of_events.outbox.pending", tags: [:producer]),
      last_value("of_events.outbox.oldest_age_seconds", tags: [:producer]),
      distribution("of_events.consumer.message.lag_ms",
        tags: [:topic],
        # Границы подобраны под наблюдаемое: медиана держится около 40 мс, и
        # корзины крупнее секунды нужны только чтобы увидеть аварию.
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1_000, 5_000, 30_000]]
      ),
      counter("of_events.consumer.duplicate.count", tags: [:topic]),
      counter("of_events.consumer.foreign_region.count", tags: [:topic, :event_region]),
      counter("of_events.consumer.dead_letter.count", tags: [:topic, :event_name]),
      counter("of_events.consumer.recovered.count", tags: [:topic, :event_name]),
      counter("of_events.delivery.sent.count", tags: [:template, :channel]),
      counter("of_events.delivery.deferred.count", tags: [:template, :channel]),
      counter("of_events.alert.seen.count", tags: [:rule_code, :severity]),
      last_value("of_events.dedupe.keys")
    ]

    {:ok, core} = TelemetryMetricsPrometheus.Core.start_link(metrics: metrics, name: :of_events_metrics)

    schedule_scrape()
    {:ok, %{core: core, producer: Application.fetch_env!(:of_events, :service_name)}}
  end

  @impl GenServer
  def handle_info(:scrape, state) do
    # Глубина outbox и размер seen-set — это не события, а состояние; их
    # приходится опрашивать самим, раз в 15 секунд, чтобы не делать запрос
    # к platform.outbox_messages на каждый scrape Prometheus.
    if Topics.produces?(state.producer) do
      stats = Publication.pending_stats(state.producer)

      :telemetry.execute([:of_events, :outbox], %{pending: stats.count, oldest_age_seconds: stats.oldest_age_seconds}, %{
        producer: state.producer
      })
    end

    :telemetry.execute([:of_events, :dedupe], %{keys: OrbitalFreight.Events.Consumer.Dedupe.size()}, %{})

    schedule_scrape()
    {:noreply, state}
  end

  @doc "Текст экспозиции Prometheus для `GET /metrics`."
  @spec scrape() :: String.t()
  def scrape, do: TelemetryMetricsPrometheus.Core.scrape(:of_events_metrics)

  defp schedule_scrape, do: Process.send_after(self(), :scrape, @scrape_interval_ms)

  defp counter(name, opts), do: Telemetry.Metrics.counter(name, opts)
  defp last_value(name, opts \\ []), do: Telemetry.Metrics.last_value(name, opts)
  defp distribution(name, opts), do: Telemetry.Metrics.distribution(name, opts)
end
