defmodule OrbitalFreight.Events.Consumer.DeadLetter do
  @moduledoc """
  Реализация правила §4.19.4: восемь попыток с экспоненциальной задержкой от 500 мс,
  после чего сообщение уезжает в `<topic>.dlq` и поднимается алерт через
  notification-service.

  Повторы делаются в памяти пода, а не через отдельный retry-топик. Причина
  практическая: у backbone нет способа сохранить порядок внутри `partition_key`,
  если часть сообщений уедет в сторону и вернётся позже, а порядок по
  `shipment_id` — единственная гарантия, которую платформа даёт наружу.

  Задержки: 500, 1000, 2000, 4000, 8000, 16000, 32000 мс — семь пауз между восемью
  попытками, суммарно чуть больше минуты. Дольше держать партицию нельзя, брокер
  выкинет консьюмера из группы по `session.timeout.ms`.

  Алерт об исчерпании попыток идёт не HTTP-вызовом, а строкой в
  `platform.outbox_messages` с событием `notification.delivery.failed` (§4.18) —
  §7.3 не делает исключения для собственных ошибок сервиса.
  """

  require Logger

  alias OrbitalFreight.Events.{Envelope, Repo, Topics}
  alias OrbitalFreight.Events.Fanout.Router
  alias OrbitalFreight.Events.Telemetry.Reporter

  @max_attempts 8
  @base_backoff_ms 500
  @client :of_events_client

  @doc """
  Повторяет обработку с нарастающей паузой и, если все попытки исчерпаны,
  паркует конверт в dead-letter топик. Возвращает `:ok` в обоих случаях —
  вызывающий воркер в любом исходе коммитит оффсет.
  """
  @spec retry_or_park(Envelope.t(), String.t(), non_neg_integer(), integer(), term()) :: :ok
  def retry_or_park(%Envelope{} = envelope, topic, partition, offset, first_reason) do
    case retry_loop(envelope, 2, first_reason) do
      :ok ->
        Reporter.recovered_after_retry(topic, envelope.event_name)
        :ok

      {:error, last_reason} ->
        park(envelope, topic, partition, offset, last_reason)
    end
  end

  @doc """
  Паркует сообщение, конверт которого не разобрался. Ключом в DLQ становится
  `topic:partition:offset` — единственный идентификатор, который у нас есть,
  когда `event_id` прочитать не удалось.
  """
  @spec park_raw(binary(), String.t(), non_neg_integer(), integer(), term()) :: :ok
  def park_raw(raw_value, topic, partition, offset, reason) do
    key = "#{topic}:#{partition}:#{offset}"
    dlq = Topics.dlq_topic(topic)

    :ok = :brod.produce_sync(@client, dlq, :hash, key, raw_value)
    Reporter.dead_lettered(topic, "undecodable")

    Logger.error("parked undecodable message in #{dlq}",
      topic: topic,
      partition: partition,
      offset: offset,
      reason: inspect(reason)
    )

    :ok
  end

  defp retry_loop(_envelope, attempt, last_reason) when attempt > @max_attempts do
    {:error, last_reason}
  end

  defp retry_loop(envelope, attempt, _last_reason) do
    Process.sleep(backoff_ms(attempt))

    case Router.dispatch(envelope) do
      :ok ->
        Logger.info("handler succeeded on attempt #{attempt}", Envelope.log_metadata(envelope))
        :ok

      {:error, reason} ->
        # Ошибка, которая не изменится от повтора, не заслуживает оставшихся попыток:
        # неизвестный шаблон или отсутствующий получатель — это разбор человеком.
        if permanent?(reason) do
          {:error, reason}
        else
          retry_loop(envelope, attempt + 1, reason)
        end
    end
  end

  defp park(envelope, topic, partition, offset, reason) do
    dlq = Topics.dlq_topic(topic)

    :ok = :brod.produce_sync(@client, dlq, :hash, envelope.partition_key, Envelope.encode(envelope))
    :ok = raise_alert(envelope, reason)
    Reporter.dead_lettered(topic, envelope.event_name)

    Logger.error("parked in #{dlq} after #{@max_attempts} attempts",
      Envelope.log_metadata(envelope) ++ [partition: partition, offset: offset, reason: inspect(reason)]
    )

    :ok
  end

  # notification.delivery.failed (§4.18) читают analytics-pipeline и audit-ledger.
  # source_event_id — это тот самый event_id, который мы не смогли обработать:
  # по нему дежурный находит исходное сообщение в DLQ.
  defp raise_alert(envelope, reason) do
    payload = %{
      "notification_id" => nil,
      "tenant_id" => envelope.tenant_id,
      "recipient_user_id" => nil,
      "channel" => "console",
      "template_code" => "event_dead_lettered",
      "source_event_id" => envelope.event_id,
      "attempts" => @max_attempts,
      "failed_reason" => inspect(reason),
      "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    sql = """
    INSERT INTO platform.outbox_messages
      (message_id, producer, aggregate_type, aggregate_id, event_name, topic,
       partition_key, schema_version, payload)
    VALUES ($1, 'notification-service', 'notification', $2, 'notification.delivery.failed',
            'of.platform.v1', $3, 1, $4)
    """

    {:ok, _} =
      Repo.query(sql, [
        "evt_" <> ulid(),
        envelope.event_id,
        envelope.tenant_id,
        payload
      ])

    :ok
  end

  defp permanent?({:unknown_template, _}), do: true
  defp permanent?({:unknown_owner_type, _}), do: true
  defp permanent?(:no_recipient), do: true
  defp permanent?(_), do: false

  defp backoff_ms(attempt), do: @base_backoff_ms * :math.pow(2, attempt - 2) |> trunc()

  # Crockford base32 без разделителей: тот же формат, что у всех идентификаторов §0.1.
  defp ulid do
    <<time::48, rand::80>> = <<System.system_time(:millisecond)::48, :crypto.strong_rand_bytes(10)::binary>>
    Base.encode32(<<time::48, rand::80>>, padding: false, case: :upper)
  end
end
