defmodule OrbitalFreight.Events.Fanout.Router do
  @moduledoc """
  Единственная точка, где имя события превращается в вызов обработчика. Таблица
  ниже — это подписки notification-service из §4, разложенные по трём модулям
  `OrbitalFreight.Events.Handlers.*`.

  Проверка полноты выполняется при старте, а не в тесте: `verify_coverage!/0`
  сравнивает таблицу с `Topics.subscribed_events("notification-service")` и роняет
  под, если в §4 сервис объявлен консьюмером события, для которого здесь нет
  клоза. Подписка без обработчика — это молча проглоченное событие, и найти такое
  в проде можно только по жалобе клиента, не получившего письмо.

  Обратное несовпадение так же фатально: обработчик события, которое §4 нам не
  адресует, означает, что кто-то расширил подписку мимо спецификации.
  """

  require Logger

  alias OrbitalFreight.Events.Envelope
  alias OrbitalFreight.Events.Handlers.{Freight, Settlement, TelemetryAlerts}
  alias OrbitalFreight.Events.Topics

  @routes %{
    "shipment.scanned" => {Freight, :scanned},
    "shipment.status.changed" => {Freight, :status_changed},
    "fleet.assignment.created" => {Freight, :assignment_created},
    "route.replanned" => {Freight, :route_replanned},
    "telemetry.alert.raised" => {TelemetryAlerts, :alert_raised},
    "gateway.heartbeat.missed" => {TelemetryAlerts, :heartbeat_missed},
    "customs.declaration.filed" => {Settlement, :declaration_filed},
    "customs.declaration.cleared" => {Settlement, :declaration_cleared},
    "billing.invoice.issued" => {Settlement, :invoice_issued},
    "billing.invoice.settled" => {Settlement, :invoice_settled},
    "reconciliation.discrepancy.opened" => {Settlement, :discrepancy_opened}
  }

  @doc """
  Отдаёт конверт обработчику. `{:error, :no_handler}` — это не ошибка: топики
  общие, и мимо консьюмера постоянно едут события, адресованные другим сервисам
  (например `telemetry.reading.recorded`, который нужен только container-registry
  и analytics-pipeline).
  """
  @spec dispatch(Envelope.t()) :: :ok | {:error, :no_handler} | {:error, term()}
  def dispatch(%Envelope{event_name: name} = envelope) do
    case Map.fetch(@routes, name) do
      {:ok, {module, fun}} ->
        # Обработчику передаётся весь конверт, а не payload: ему нужны tenant_id для
        # выборки предпочтений, trace_id для склейки следа и event_id, который
        # станет `source_event_id` в platform.notifications.
        apply(module, fun, [envelope])

      :error ->
        {:error, :no_handler}
    end
  end

  @doc """
  Сверяет таблицу маршрутов с §4. Вызывается из `Application.start/2` до того, как
  поднимутся consumer-группы.
  """
  @spec verify_coverage!() :: :ok
  def verify_coverage! do
    declared = MapSet.new(Topics.subscribed_events("notification-service"))
    routed = @routes |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(declared, routed)
    extra = MapSet.difference(routed, declared)

    cond do
      MapSet.size(missing) > 0 ->
        raise "no handler for events notification-service consumes: #{inspect(MapSet.to_list(missing))}"

      MapSet.size(extra) > 0 ->
        raise "handlers registered for events not addressed to notification-service: #{inspect(MapSet.to_list(extra))}"

      true ->
        Logger.info("fan-out covers #{MapSet.size(routed)} of the 18 platform events")
        :ok
    end
  end

  @doc "Имена событий, которые backbone умеет обрабатывать. Используется контрактным тестом."
  @spec routed_events() :: [String.t()]
  def routed_events, do: Map.keys(@routes)
end
