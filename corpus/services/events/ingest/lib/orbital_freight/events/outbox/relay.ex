defmodule OrbitalFreight.Events.Outbox.Relay do
  @moduledoc """
  GenServer, который вычитывает неопубликованные строки `platform.outbox_messages`
  своего продюсера и отправляет их в Kafka. Это единственный код в системе, которому
  разрешено писать в брокер: правило §7.3 требует, чтобы изменение состояния и
  событие лежали в одной транзакции, а значит из обработчика запроса публиковать
  нельзя в принципе.

  Цикл простой и намеренно скучный:

    1. `SELECT ... FOR UPDATE SKIP LOCKED` по индексу `outbox_pending_idx`, отсюда же
       берётся ограничение по `producer` — релей никогда не забирает чужие строки;
    2. публикация пачки в топик, полученный из `Topics.topic_for/1`;
    3. `UPDATE ... SET published_at = now()` по подтверждённым `message_id`.

  Между шагами 2 и 3 возможен сбой, и тогда сообщение уедет в Kafka дважды. Это
  сознательный выбор: доставка at-least-once плюс дедупликация по `event_id` на
  стороне консьюмера (§4.19.1) дешевле, чем распределённая транзакция с брокером.

  Интервал опроса берётся из `OF_OUTBOX_RELAY_INTERVAL_MS` (по умолчанию 250 мс) и
  на пустой очереди растёт до секунды: девяносто процентов подов простаивают, а
  каждый опрос — это запрос к базе, общей для всех схем.
  """

  use GenServer
  require Logger

  alias OrbitalFreight.Events.{Envelope, Topics}
  alias OrbitalFreight.Events.Outbox.Publication
  alias OrbitalFreight.Events.Telemetry.Reporter

  @batch_size 200
  @idle_backoff_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct [:producer, :region_code, :base_interval_ms, :next_interval_ms, :timer, published: 0]
  end

  @doc "Стартует релей для одного сервиса-продюсера из §4."
  def start_link(opts) do
    producer = Keyword.fetch!(opts, :producer)
    GenServer.start_link(__MODULE__, opts, name: via(producer))
  end

  @doc "Немедленный проход цикла — вызывается после ручного повторного проигрывания."
  @spec flush_now(String.t()) :: :ok
  def flush_now(producer), do: GenServer.cast(via(producer), :tick)

  @impl GenServer
  def init(opts) do
    producer = Keyword.fetch!(opts, :producer)
    interval = Application.fetch_env!(:of_events, :kafka)[:outbox_relay_interval_ms]

    unless Topics.produces?(producer) do
      # Релей без единого события в каталоге §4 — почти всегда опечатка в
      # OF_SERVICE_NAME. Молча простаивающий под искали бы неделю.
      raise ArgumentError, "service #{producer} publishes no event listed in the specification"
    end

    state = %State{
      producer: producer,
      region_code: Application.fetch_env!(:of_events, :region_code),
      base_interval_ms: interval,
      next_interval_ms: interval
    }

    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_info(:tick, state), do: {:noreply, state |> drain_batch() |> schedule()}

  @impl GenServer
  def handle_cast(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, state |> drain_batch() |> schedule()}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # На выключении дочитываем очередь: строки, оставшиеся неопубликованными, подберёт
    # следующий под, но задержка события `billing.invoice.settled` на минуту означает
    # минуту, в течение которой customs-service не знает, что пошлина оплачена.
    _ = drain_batch(state)
    :ok
  end

  defp drain_batch(state) do
    case Publication.claim_pending(state.producer, @batch_size) do
      {:ok, []} ->
        %{state | next_interval_ms: @idle_backoff_ms}

      {:ok, rows} ->
        {published, failed} = publish_rows(rows, state)
        :ok = Publication.mark_published(published)
        :ok = Publication.record_failures(failed)

        Reporter.outbox_batch(state.producer, length(published), length(failed))

        # Пачка была полной — очередь, скорее всего, не кончилась, идём сразу снова.
        interval = if length(rows) == @batch_size, do: 0, else: state.base_interval_ms
        %{state | next_interval_ms: interval, published: state.published + length(published)}

      {:error, reason} ->
        Logger.error("outbox claim failed", producer: state.producer, reason: inspect(reason))
        %{state | next_interval_ms: state.base_interval_ms}
    end
  end

  defp publish_rows(rows, state) do
    Enum.reduce(rows, {[], []}, fn row, {ok, failed} ->
      envelope = Envelope.from_outbox_row(row, region_code: state.region_code)

      case Topics.topic_for(envelope.event_name) do
        {:ok, topic} ->
          case :brod.produce_sync(:of_events_client, topic, :hash, envelope.partition_key,
                 Envelope.encode(envelope)) do
            :ok ->
              {[row["message_id"] | ok], failed}

            {:error, reason} ->
              {ok, [{row["message_id"], inspect(reason)} | failed]}
          end

        {:error, :unknown_event} ->
          # Событие, которого нет в §4, никуда не публикуется и остаётся в таблице с
          # записанной ошибкой: пусть его увидит человек, а не dead-letter топик,
          # которого для несуществующего топика всё равно не существует.
          {ok, [{row["message_id"], "event_name is not in the specification"} | failed]}
      end
    end)
  end

  defp schedule(state) do
    %{state | timer: Process.send_after(self(), :tick, state.next_interval_ms)}
  end

  defp via(producer), do: {:global, {__MODULE__, producer}}
end
