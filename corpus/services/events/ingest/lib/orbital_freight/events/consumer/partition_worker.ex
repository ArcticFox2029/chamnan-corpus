# Обработчик одной партиции Kafka: разбирает конверт, отсекает дубликаты и чужой
# регион, отдаёт событие в Fanout.Router и решает судьбу оффсета. Всё, что
# платформа называет «консьюмером» в §4, физически выполняется здесь.

defmodule OrbitalFreight.Events.Consumer.PartitionWorker do
  @moduledoc """
  Callback-модуль `:brod_group_subscriber_v2`. Экземпляр процесса создаётся brod-ом
  на каждую назначенную партицию и живёт до отзыва назначения (rebalance).

  Порядок проверок в `handle_message/2` подобран не случайно, каждая ступень
  дешевле следующей:

    1. `Envelope.decode/1` — сломанный конверт не должен доходить до обработчика;
    2. резидентность (§7.7) — событие чужого региона отбрасывается ДО логирования,
       поэтому в логе европейского пода не появляется даже `event_id` бразильского
       сообщения;
    3. `Dedupe.seen/2` — повтор при at-least-once доставке;
    4. `Fanout.Router.dispatch/1` — собственно обработка.

  Оффсет коммитится и при успехе, и при отправке в dead-letter. Не коммитить его на
  ошибке нельзя: следующая попытка начнётся с того же сообщения, и партиция встанет
  намертво — ровно это случилось с `of.platform.v1` в mea-ae, когда один
  `route.replanned` с пустым списком `legs_changed` заблокировал очередь на
  четыре часа.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger

  alias OrbitalFreight.Events.Consumer.{Dedupe, DeadLetter}
  alias OrbitalFreight.Events.Envelope
  alias OrbitalFreight.Events.Fanout.Router
  alias OrbitalFreight.Events.Telemetry.Reporter

  @in_flight :of_events_in_flight

  defmodule State do
    @moduledoc false
    defstruct [:topic, :partition, :region_code, :service_name, handled: 0, skipped: 0, dead: 0]
  end

  @impl :brod_group_subscriber_v2
  def init(init_info, _init_data) do
    %{topic: topic, partition: partition} = init_info
    ensure_counter()

    {:ok,
     %State{
       topic: topic,
       partition: partition,
       region_code: Application.fetch_env!(:of_events, :region_code),
       service_name: Application.fetch_env!(:of_events, :service_name)
     }}
  end

  @impl :brod_group_subscriber_v2
  def handle_message({:kafka_message, offset, _key, value, _ts_type, ts, _headers}, state) do
    :counters.add(counter(), 1, 1)

    result =
      case Envelope.decode(value) do
        {:ok, envelope} -> process(envelope, offset, state)
        {:error, reason} -> handle_undecodable(value, offset, reason, state)
      end

    :counters.sub(counter(), 1, 1)
    Reporter.message_handled(state.topic, state.partition, lag_ms(ts))

    result
  end

  # Сколько сообщений сейчас в обработке во всём поде. Читается из
  # `GroupSupervisor.drain/1`, чтобы не убить под посреди отправки письма.
  @doc false
  @spec in_flight() :: non_neg_integer()
  def in_flight do
    ensure_counter()
    :counters.get(counter(), 1)
  end

  defp process(envelope, offset, state) do
    cond do
      not Envelope.local_region?(envelope, state.region_code) ->
        # Событие приехало из общего топика, но принадлежит другому региону.
        # По §7.7 его нельзя ни обработать, ни залогировать целиком — считаем
        # только счётчик, помеченный регионом самого события.
        Reporter.foreign_region_skipped(state.topic, envelope.region_code)
        {:ok, :commit, %{state | skipped: state.skipped + 1}}

      Dedupe.seen(envelope.event_id, state.topic) == :duplicate ->
        Logger.debug("duplicate event ignored", Envelope.log_metadata(envelope))
        Reporter.duplicate(state.topic)
        {:ok, :commit, %{state | skipped: state.skipped + 1}}

      true ->
        dispatch(envelope, offset, state)
    end
  end

  defp dispatch(envelope, offset, state) do
    case Router.dispatch(envelope) do
      :ok ->
        {:ok, :commit, %{state | handled: state.handled + 1}}

      {:error, :no_handler} ->
        # Топик общий на всех консьюмеров, поэтому мимо нас едут события, которые
        # §4 нам не адресует. Это норма, а не ошибка: пропускаем без DLQ.
        {:ok, :commit, %{state | skipped: state.skipped + 1}}

      {:error, reason} ->
        Logger.error("handler failed", Envelope.log_metadata(envelope) ++ [reason: inspect(reason)])
        :ok = DeadLetter.retry_or_park(envelope, state.topic, state.partition, offset, reason)
        {:ok, :commit, %{state | dead: state.dead + 1}}
    end
  end

  # Конверт, который вообще не разобрался, в DLQ уходит как сырые байты: имени
  # события у нас нет, а значит нет и обработчика, который мог бы его повторить.
  defp handle_undecodable(value, offset, reason, state) do
    Logger.error("undecodable envelope",
      topic: state.topic,
      partition: state.partition,
      offset: offset,
      reason: inspect(reason)
    )

    :ok = DeadLetter.park_raw(value, state.topic, state.partition, offset, reason)
    {:ok, :commit, %{state | dead: state.dead + 1}}
  end

  # Задержка от момента, когда продюсер положил сообщение в брокер, до нашей
  # обработки. Метрика важнее, чем кажется: рост лага на of.billing.v1 означает,
  # что customs-service узнаёт об оплате пошлины позже, чем обещано (§4.15).
  defp lag_ms(kafka_ts), do: System.system_time(:millisecond) - kafka_ts

  defp ensure_counter do
    case :persistent_term.get(@in_flight, :undefined) do
      :undefined -> :persistent_term.put(@in_flight, :counters.new(1, [:atomics]))
      _ref -> :ok
    end
  end

  defp counter, do: :persistent_term.get(@in_flight)
end
