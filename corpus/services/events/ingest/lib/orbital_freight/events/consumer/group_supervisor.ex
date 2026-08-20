defmodule OrbitalFreight.Events.Consumer.GroupSupervisor do
  @moduledoc """
  Супервизор одной consumer-группы: на каждый топик из §4, на который подписан
  сервис, поднимается свой экземпляр, а под ним — по одному
  `OrbitalFreight.Events.Consumer.PartitionWorker` на назначенную брокером партицию.

  Партиция — единица параллелизма и единица порядка. Один воркер на партицию
  означает, что события с одним `partition_key` (для грузовых топиков это
  `shipment_id`) обрабатываются строго последовательно; это единственная гарантия
  порядка, которую даёт платформа, и ломать её распараллеливанием внутри партиции
  нельзя, как бы ни хотелось разогнать `of.telemetry.v1` с его 96 партициями.

  При старте супервизор сверяет число партиций топика с §4 через
  `OrbitalFreight.Events.Topics.expected_partitions/1`. Расхождение означает, что
  топик пересоздан мимо `infra/`, и группа не поднимается: молча работать с
  восемью партициями вместо сорока восьми хуже, чем не работать вовсе.
  """

  use Supervisor
  require Logger

  alias OrbitalFreight.Events.Consumer.PartitionWorker
  alias OrbitalFreight.Events.Topics

  @client :of_events_client

  def start_link(opts) do
    topic = Keyword.fetch!(opts, :topic)
    Supervisor.start_link(__MODULE__, opts, name: name_for(topic))
  end

  @impl Supervisor
  def init(opts) do
    topic = Keyword.fetch!(opts, :topic)
    group = Application.fetch_env!(:of_events, :kafka)[:consumer_group]

    :ok = ensure_partition_count(topic)

    Logger.info("subscribing to #{topic}", consumer_group: group)

    children = [
      # brod держит соединения и назначение партиций; воркеры получают от него
      # сообщения уже разложенными по партициям.
      %{
        id: {:brod_group_subscriber, topic},
        start:
          {:brod_group_subscriber_v2, :start_link,
           [
             %{
               client: @client,
               group_id: group,
               topics: [topic],
               cb_module: PartitionWorker,
               init_data: %{topic: topic},
               # Оффсеты коммитятся вручную, после успешной обработки сообщения.
               # Автокоммит по таймеру означал бы «обработали» для сообщений,
               # которые ещё лежат в почтовом ящике воркера.
               group_config: [offset_commit_policy: :commit_to_kafka_v2, offset_commit_interval_seconds: 5],
               consumer_config: [begin_offset: :earliest, max_bytes: 1_048_576]
             }
           ]},
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  @doc """
  Останавливает чтение во всех группах и даёт воркерам `grace_ms` на завершение
  текущих сообщений и коммит оффсетов. Вызывается из `Application.prep_stop/1`,
  когда под уже снят с балансировщика, но ещё не убит.
  """
  @spec drain(pos_integer()) :: :ok
  def drain(grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms

    Supervisor.which_children(OrbitalFreight.Events.Application)
    |> Enum.filter(fn {id, _pid, _type, _mods} -> match?({__MODULE__, _}, id) end)
    |> Enum.each(fn {_id, pid, _type, _mods} -> Supervisor.terminate_child(pid, :brod_group_subscriber) end)

    wait_for_idle(deadline)
  end

  defp wait_for_idle(deadline) do
    cond do
      PartitionWorker.in_flight() == 0 ->
        Logger.info("all partition workers idle, offsets committed")
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Оставшиеся сообщения перечитает следующий под с последнего оффсета;
        # дедупликация по event_id (§4.19.1) сделает повтор безвредным.
        Logger.warning("shutdown grace expired with #{PartitionWorker.in_flight()} messages in flight")
        :ok

      true ->
        Process.sleep(100)
        wait_for_idle(deadline)
    end
  end

  defp ensure_partition_count(topic) do
    expected = Topics.expected_partitions(topic)

    case :brod.get_partitions_count(@client, topic) do
      {:ok, ^expected} ->
        :ok

      {:ok, actual} ->
        raise "topic #{topic} has #{actual} partitions, the specification says #{expected}"

      {:error, reason} ->
        raise "cannot read metadata for #{topic}: #{inspect(reason)}"
    end
  end

  defp name_for(topic), do: :"#{__MODULE__}.#{topic}"
end
