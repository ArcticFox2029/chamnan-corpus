defmodule OrbitalFreight.Events.Consumer.Dedupe do
  @moduledoc """
  Seen-set по `event_id`, без которого правило §4.19.1 не выполняется: доставка
  at-least-once, релей публикует повторно после падения между Kafka и `UPDATE`
  строки `platform.outbox_messages`, и один и тот же `evt_…` приходит дважды.

  Хранилище — ETS `:set` с `read_concurrency`, владелец — этот GenServer. Такой
  выбор объясняет и стратегию `:rest_for_one` в `OrbitalFreight.Events.Application`:
  падение владельца уносит таблицу, и все партиционные воркеры обязаны
  перезапуститься вместе с ним, иначе они продолжат считать уже обработанные
  события новыми.

  Окно хранения равно retention топика (§4): 7 суток для `of.telemetry.v1`, 90 для
  `of.billing.v1` и `of.customs.v1`. Держать телеметрию три месяца невозможно —
  при 96 партициях это десятки миллионов ключей в памяти каждого пода.

  Что здесь сознательно НЕ сделано: seen-set не переживает перезапуск пода. После
  рестарта воркер перечитывает партицию с последнего закоммиченного оффсета и может
  обработать несколько сообщений повторно. Все обработчики fan-out пишут в
  `platform.notifications` с уникальным ключом `(source_event_id, channel,
  recipient_user_id)`, поэтому повтор гасится базой, а не памятью.
  """

  use GenServer
  require Logger

  @table :of_events_seen
  @sweep_interval_ms 60_000

  # Retention из §4, в секундах. Ключ живёт ровно столько, сколько может прожить
  # сообщение в топике: раньше выкидывать нельзя, позже — бессмысленно.
  @retention_seconds %{
    "of.identity.v1" => 30 * 86_400,
    "of.freight.v1" => 14 * 86_400,
    "of.telemetry.v1" => 7 * 86_400,
    "of.customs.v1" => 90 * 86_400,
    "of.billing.v1" => 90 * 86_400,
    "of.platform.v1" => 30 * 86_400
  }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Отмечает событие как обработанное. Возвращает `:new`, если его видят впервые, и
  `:duplicate`, если оно уже проходило через этот под.

  Вызывается ДО обработчика и после него не подтверждается: событие, упавшее в
  обработчике, всё равно уедет в `OrbitalFreight.Events.Consumer.DeadLetter`, а
  не будет обработано во второй раз тем же подом.
  """
  @spec seen(String.t(), String.t()) :: :new | :duplicate
  def seen(event_id, topic) do
    expires_at = System.system_time(:second) + Map.get(@retention_seconds, topic, 14 * 86_400)

    if :ets.insert_new(@table, {event_id, expires_at}) do
      :new
    else
      :duplicate
    end
  end

  @doc "Сколько ключей сейчас в наборе — уходит в `/metrics` как `of_events_dedupe_keys`."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)

  @doc """
  Принудительно забывает событие. Единственный законный вызывающий — оператор,
  повторно проигрывающий сообщение из `<topic>.dlq` после исправления шаблона:
  без этого backbone честно посчитает его дубликатом и молча пропустит.
  """
  @spec forget(String.t()) :: :ok
  def forget(event_id) do
    :ets.delete(@table, event_id)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table, swept: 0}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    # select_delete по одному match-spec вместо обхода: таблица на горячем пути,
    # и проход :ets.foldl держал бы её под чтением десятки миллисекунд.
    removed = :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if removed > 0 do
      Logger.debug("dedupe sweep removed #{removed} expired event ids", remaining: size())
    end

    schedule_sweep()
    {:noreply, %{state | swept: state.swept + removed}}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
