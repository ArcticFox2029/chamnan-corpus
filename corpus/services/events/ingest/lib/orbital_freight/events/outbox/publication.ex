# Доступ к таблице platform.outbox_messages: захват пачки неопубликованных строк,
# отметка об успешной публикации и запись ошибки. Вынесено из Relay, потому что
# SQL здесь тонкий (advisory-семантика SKIP LOCKED, частичный индекс) и его читают
# отдельно от логики цикла.

defmodule OrbitalFreight.Events.Outbox.Publication do
  @moduledoc """
  Тонкая обёртка над `platform.outbox_messages` — единственной таблицей, которую
  event-backbone трогает в чужой схеме. Формально это не нарушает §7.2: схема
  `platform` не принадлежит одному сервису, и строки, которые мы читаем,
  ограничены столбцом `producer` того же сервиса, в поде которого мы работаем.

  Запросы написаны против частичного индекса `outbox_pending_idx (producer, created_at)
  WHERE published_at IS NULL`. Порядок по `created_at` обязателен: внутри одного
  `partition_key` события обязаны уйти в брокер в том порядке, в котором их записала
  транзакция, иначе `shipment.status.changed` обгонит `shipment.created`.
  """

  alias OrbitalFreight.Events.Repo

  @claim_sql """
  SELECT message_id, producer, aggregate_type, aggregate_id, event_name, topic,
         partition_key, schema_version, payload, created_at, attempts
    FROM platform.outbox_messages
   WHERE producer = $1
     AND published_at IS NULL
     -- attempts >= 8 означает, что строку уже нельзя опубликовать автоматически:
     -- порог тот же, что и для DLQ в §4.19.4, и разбирается такое руками.
     AND attempts < 8
   ORDER BY created_at
   LIMIT $2
     FOR UPDATE SKIP LOCKED
  """

  @mark_sql """
  UPDATE platform.outbox_messages
     SET published_at = now()
   WHERE message_id = ANY($1)
  """

  @fail_sql """
  UPDATE platform.outbox_messages
     SET attempts = attempts + 1,
         last_error = data.reason
    FROM unnest($1::text[], $2::text[]) AS data(message_id, reason)
   WHERE platform.outbox_messages.message_id = data.message_id
  """

  @doc """
  Забирает до `limit` неопубликованных строк продюсера. `SKIP LOCKED` позволяет
  держать несколько подов одного сервиса без координации: каждый видит только те
  строки, которые никто не читает прямо сейчас.
  """
  @spec claim_pending(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def claim_pending(producer, limit) do
    Repo.transaction(fn ->
      case Repo.query(@claim_sql, [producer, limit]) do
        {:ok, result} -> rows_to_maps(result)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Проставляет `published_at` подтверждённым брокером сообщениям."
  @spec mark_published([String.t()]) :: :ok
  def mark_published([]), do: :ok

  def mark_published(message_ids) do
    {:ok, _} = Repo.query(@mark_sql, [message_ids])
    :ok
  end

  @doc """
  Инкрементирует `attempts` и пишет `last_error`. Строка остаётся неопубликованной и
  будет подобрана следующим проходом — до восьмой попытки, после чего её видно
  запросом дежурного и не видно релею.
  """
  @spec record_failures([{String.t(), String.t()}]) :: :ok
  def record_failures([]), do: :ok

  def record_failures(failures) do
    {ids, reasons} = Enum.unzip(failures)
    {:ok, _} = Repo.query(@fail_sql, [ids, reasons])
    :ok
  end

  @doc """
  Сколько строк продюсера ждут публикации и насколько стара самая старая.
  Значение отдаётся в `/metrics`; лаг больше нескольких секунд означает, что
  события платформы расходятся с состоянием базы.
  """
  @spec pending_stats(String.t()) :: %{count: non_neg_integer(), oldest_age_seconds: float()}
  def pending_stats(producer) do
    sql = """
    SELECT count(*)::bigint AS count,
           coalesce(extract(epoch FROM now() - min(created_at)), 0) AS oldest_age_seconds
      FROM platform.outbox_messages
     WHERE producer = $1 AND published_at IS NULL
    """

    {:ok, %{rows: [[count, age]]}} = Repo.query(sql, [producer])
    %{count: count, oldest_age_seconds: age / 1}
  end

  defp rows_to_maps(%{columns: columns, rows: rows}) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end
end
