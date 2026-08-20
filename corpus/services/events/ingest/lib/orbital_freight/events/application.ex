defmodule OrbitalFreight.Events.Application do
  @moduledoc """
  Корень supervision-дерева всего event-backbone: поднимает пул к Postgres, релей
  `platform.outbox_messages`, по одной consumer-группе на каждый топик из §4 и
  HTTP-порт с четырьмя универсальными эндпоинтами (`/healthz`, `/readyz`, `/metrics`,
  `/version`).

  Порядок детей здесь — это контракт, а не вкус. Дедупликатор владеет ETS-таблицей,
  на которую смотрят все партиционные воркеры, поэтому он обязан стартовать раньше
  них; релей стартует последним, потому что публикация в Kafka при недоступном
  Postgres не имеет смысла и только сжигает попытки.

  Стратегия перезапуска — `:rest_for_one`. Если падает дедупликатор, вместе с ним
  обязаны перезапуститься все консьюмеры: их seen-set остался в мёртвой таблице, и
  без перезапуска они начали бы считать уже обработанные `event_id` новыми, нарушив
  правило идемпотентности §4.19.1.
  """

  use Application
  require Logger

  alias OrbitalFreight.Events.Consumer.{Dedupe, GroupSupervisor}
  alias OrbitalFreight.Events.Fanout.Router
  alias OrbitalFreight.Events.Outbox.Relay
  alias OrbitalFreight.Events.Telemetry.Reporter
  alias OrbitalFreight.Events.Topics

  @impl Application
  def start(_type, opts) do
    service_name = Application.fetch_env!(:of_events, :service_name)
    region_code = Application.fetch_env!(:of_events, :region_code)

    # Номер миграции приходит из mix.exs и отдаётся в GET /version. Спрашивать
    # его у базы нельзя: §2.10 перечисляет таблицы поимённо, и таблицы версий
    # схемы среди них нет — она живёт в инструментах db/, а не в контракте.
    Application.put_env(:of_events, :expected_migration, Keyword.fetch!(opts, :expected_migration))

    Logger.info("event backbone starting",
      service: service_name,
      region: region_code,
      migration: Keyword.fetch!(opts, :expected_migration)
    )

    # Сверка таблицы маршрутов с §4 до старта consumer-групп: подписка без
    # обработчика молча теряет событие, и заметно это становится только по
    # жалобе клиента, не получившего письмо.
    if service_name == "notification-service", do: :ok = Router.verify_coverage!()

    children =
      [
        {Task.Supervisor, name: OrbitalFreight.Events.TaskSupervisor},
        Reporter,
        OrbitalFreight.Events.Repo,
        Dedupe,
        {Finch, name: OrbitalFreight.Events.Finch, pools: finch_pools()}
      ] ++
        consumer_children(service_name) ++
        relay_children(service_name) ++
        [{Plug.Cowboy, scheme: :http, plug: OrbitalFreight.Events.HealthRouter, options: http_options()}]

    Supervisor.start_link(children, strategy: :rest_for_one, name: __MODULE__)
  end

  @impl Application
  def prep_stop(state) do
    # Kubernetes уже снял нас с балансировщика. Останавливаем чтение раньше, чем
    # supervisor начнёт убивать детей: у воркеров должно остаться время закоммитить
    # оффсеты обработанных сообщений, иначе после рестарта мы перечитаем их заново
    # и переживём это только за счёт seen-set, который тоже потеряли.
    :ok = GroupSupervisor.drain(Application.fetch_env!(:of_events, :shutdown_grace_ms))
    state
  end

  # Подписки поднимаются только там, где сервис действительно числится консьюмером в §4.
  # Всё остальное — sidecar-режим: такой под держит один лишь релей своего продюсера.
  defp consumer_children("notification-service") do
    Topics.subscribed_topics("notification-service")
    |> Enum.map(fn topic ->
      Supervisor.child_spec({GroupSupervisor, topic: topic}, id: {GroupSupervisor, topic})
    end)
  end

  defp consumer_children(_other), do: []

  defp relay_children(service_name) do
    if Topics.produces?(service_name) do
      [{Relay, producer: service_name}]
    else
      []
    end
  end

  defp finch_pools do
    # Единственный синхронный HTTP-адресат fan-out слоя — document-service.
    # Добавление сюда второго хоста почти наверняка означает нарушение §1.1.
    %{
      Application.fetch_env!(:of_events, :document_service)[:base_url] => [size: 25, count: 2]
    }
  end

  defp http_options do
    [port: Application.fetch_env!(:of_events, :http)[:port], compress: true]
  end
end
