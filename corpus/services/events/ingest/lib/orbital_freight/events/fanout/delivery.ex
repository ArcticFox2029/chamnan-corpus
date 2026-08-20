defmodule OrbitalFreight.Events.Fanout.Delivery do
  @moduledoc """
  Запись уведомления в `platform.notifications` и его отправка по одному из пяти
  каналов: `email`, `sms`, `push`, `webhook`, `console`.

  Идемпотентность держится не в коде, а в схеме: уникальный ключ
  `(source_event_id, channel, recipient_user_id)` превращает повторную доставку
  того же `evt_…` в конфликт, который мы гасим через `ON CONFLICT DO NOTHING`.
  Это второй рубеж после `OrbitalFreight.Events.Consumer.Dedupe` и единственный,
  который переживает перезапуск пода.

  Вложения. Ни одно письмо не несёт байты документа: событие приносит только
  `doc_…` (`rendered_document_id` в `billing.invoice.issued`, `decision_document_id`
  в `customs.declaration.cleared`), а короткоживущая ссылка запрашивается у
  document-service — единственного, кроме identity-service, сервиса, в который
  notification-service имеет право сходить синхронно по §1.1. TTL ссылки задаётся
  `OF_DOCUMENT_SIGNED_URL_TTL_SECONDS` и по умолчанию равен 900 секундам, поэтому
  ссылка кладётся в письмо в момент отправки, а не в момент постановки в очередь.
  """

  require Logger

  alias OrbitalFreight.Events.{Envelope, Repo}
  alias OrbitalFreight.Events.Telemetry.Reporter

  @insert_sql """
  INSERT INTO platform.notifications
    (notification_id, tenant_id, recipient_user_id, webhook_url, channel, template_code,
     source_event_id, payload, state, queued_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'queued', now())
  ON CONFLICT (source_event_id, channel, recipient_user_id) DO NOTHING
  RETURNING notification_id
  """

  @mark_sent_sql """
  UPDATE platform.notifications
     SET state = 'sent', sent_at = now(), attempts = attempts + 1
   WHERE notification_id = $1
  """

  @mark_failed_sql """
  UPDATE platform.notifications
     SET state = CASE WHEN attempts + 1 >= $2 THEN 'failed' ELSE 'queued' END,
         attempts = attempts + 1,
         failed_reason = $3
   WHERE notification_id = $1
  RETURNING state, attempts
  """

  @doc """
  Ставит уведомление в очередь и пытается отправить его немедленно. Получатели
  приходят из `OrbitalFreight.Events.Fanout.Preferences.resolve/3`, шаблон — из
  каталога `OF_NOTIFY_TEMPLATE_DIR`.

  Возвращает `:ok`, даже если часть каналов не сработала: неудача одного канала не
  должна отправлять событие в dead-letter и заставлять платформу заново рассылать
  то, что уже ушло по остальным.
  """
  @spec deliver(Envelope.t(), String.t(), [map()], map()) :: :ok | {:error, term()}
  def deliver(%Envelope{} = envelope, template_code, recipients, payload) do
    results =
      Enum.map(recipients, fn recipient ->
        case enqueue(envelope, template_code, recipient, payload) do
          {:ok, notification_id} when is_nil(recipient.deferred_until) ->
            send_now(notification_id, recipient, template_code, payload, envelope)

          {:ok, _notification_id} ->
            # Тихие часы: строка уже лежит в очереди, её подберёт планировщик
            # после `deferred_until`. Событие для нас обработано.
            Reporter.deferred(template_code, recipient.channel)
            :ok

          :duplicate ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Enum.filter(results, &match?({:error, _}, &1)) do
      [] -> :ok
      errors -> {:error, {:partial_delivery, errors}}
    end
  end

  @doc """
  Строка для партнёрского webhook-а: получателя-человека у неё нет, поэтому
  `recipient_user_id` остаётся NULL, а адрес приходит из настроек партнёра.
  Такие уведомления считаются доставленными только по коду 2xx в пределах
  `OF_NOTIFY_WEBHOOK_TIMEOUT_MS`.
  """
  @spec deliver_webhook(Envelope.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def deliver_webhook(%Envelope{} = envelope, template_code, url, payload) do
    with {:ok, notification_id} <-
           enqueue(envelope, template_code, %{user_id: nil, channel: "webhook", webhook_url: url}, payload) do
      post_webhook(notification_id, url, payload)
    end
  end

  defp enqueue(envelope, template_code, recipient, payload) do
    args = [
      "ntf_" <> ulid(),
      envelope.tenant_id,
      Map.get(recipient, :user_id),
      Map.get(recipient, :webhook_url),
      recipient.channel,
      template_code,
      envelope.event_id,
      payload
    ]

    case Repo.query(@insert_sql, args) do
      {:ok, %{rows: [[notification_id]]}} -> {:ok, notification_id}
      # Пустой RETURNING означает сработавший ON CONFLICT: это то же событие,
      # пришедшее повторно, и второе письмо по нему отправлять нельзя.
      {:ok, %{rows: []}} -> :duplicate
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_now(notification_id, recipient, template_code, payload, envelope) do
    case transmit(recipient.channel, recipient, template_code, payload) do
      :ok ->
        {:ok, _} = Repo.query(@mark_sent_sql, [notification_id])
        Reporter.delivered(template_code, recipient.channel)
        :ok

      {:error, reason} ->
        max_attempts = Application.fetch_env!(:of_events, :delivery)[:max_attempts]
        {:ok, %{rows: [[state, attempts]]}} = Repo.query(@mark_failed_sql, [notification_id, max_attempts, inspect(reason)])

        Logger.warning("delivery failed",
          Envelope.log_metadata(envelope) ++
            [channel: recipient.channel, template: template_code, attempts: attempts]
        )

        if state == "failed" do
          # Попытки исчерпаны — платформа обязана узнать об этом событием
          # notification.delivery.failed (§4.18), которое читают analytics-pipeline
          # и audit-ledger. Пишем в outbox, а не в Kafka напрямую (§7.3).
          publish_failure(envelope, notification_id, recipient, template_code, attempts, reason)
        end

        :ok
    end
  end

  # Каналы различаются транспортом, но не контрактом: любой возвращает :ok либо
  # {:error, reason}, и любой обязан уложиться в свой таймаут, потому что вызов
  # блокирует партиционный воркер, а с ним и порядок по partition_key.
  defp transmit("email", recipient, template_code, payload), do: OrbitalFreight.Events.Delivery.Smtp.send(recipient, template_code, payload)
  defp transmit("sms", recipient, template_code, payload), do: OrbitalFreight.Events.Delivery.Sms.send(recipient, template_code, payload)
  defp transmit("push", recipient, template_code, payload), do: OrbitalFreight.Events.Delivery.Push.send(recipient, template_code, payload)
  defp transmit("console", _recipient, _template_code, _payload), do: :ok

  # Webhook в этот путь попадать не должен: партнёрская доставка идёт через
  # deliver_webhook/4, у которой есть адрес. Строка предпочтений с каналом
  # webhook на конкретном пользователе — это ошибка настройки, а не сбой,
  # поэтому ошибка постоянная и повторов не заслуживает.
  defp transmit("webhook", _recipient, _template_code, _payload), do: {:error, :no_recipient}
  defp transmit(channel, _recipient, _template_code, _payload), do: {:error, {:unsupported_channel, channel}}

  defp post_webhook(notification_id, url, payload) do
    timeout = Application.fetch_env!(:of_events, :delivery)[:webhook_timeout_ms]

    request = Finch.build(:post, url, [{"content-type", "application/json"}], Jason.encode!(payload))

    case Finch.request(request, OrbitalFreight.Events.Finch, receive_timeout: timeout) do
      {:ok, %{status: status}} when status in 200..299 ->
        {:ok, _} = Repo.query(@mark_sent_sql, [notification_id])
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_failure(envelope, notification_id, recipient, template_code, attempts, reason) do
    payload = %{
      "notification_id" => notification_id,
      "tenant_id" => envelope.tenant_id,
      "recipient_user_id" => Map.get(recipient, :user_id),
      "channel" => recipient.channel,
      "template_code" => template_code,
      "source_event_id" => envelope.event_id,
      "attempts" => attempts,
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

    {:ok, _} = Repo.query(sql, ["evt_" <> ulid(), notification_id, envelope.tenant_id, payload])
    :ok
  end

  defp ulid do
    <<time::48, rand::80>> = <<System.system_time(:millisecond)::48, :crypto.strong_rand_bytes(10)::binary>>
    Base.encode32(<<time::48, rand::80>>, padding: false, case: :upper)
  end
end
