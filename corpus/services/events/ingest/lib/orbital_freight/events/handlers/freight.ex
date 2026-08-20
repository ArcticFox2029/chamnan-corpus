# Обработчики четырёх грузовых событий, на которые подписан notification-service:
# сканирование, смена статуса отгрузки, назначение машины и перепланирование
# маршрута. Модуль решает, кого это касается и по какому шаблону, а отправкой
# занимается Fanout.Delivery.

defmodule OrbitalFreight.Events.Handlers.Freight do
  @moduledoc """
  События `shipment.scanned`, `shipment.status.changed` (публикует
  container-registry), `fleet.assignment.created` (fleet-service) и
  `route.replanned` (routing-service).

  Общее правило для всех четырёх: обработчик не ходит обратно к продюсеру. §4.19.2
  запрещает синхронный вызов издателя из обработчика, и здесь это не абстракция —
  запрос `GET /v1/shipments/{shipment_id}` в container-registry за именем
  отправителя выглядел безобидно ровно до дня, когда очередь `of.freight.v1`
  выросла на порядок и сорок восемь партиций начали дружно опрашивать реестр.
  Всё, что нужно письму, обязано быть в payload; чего нет в payload — того нет в
  письме.

  Второе общее правило: шумные переходы не рассылаются. `draft → booked` человека
  не интересует, а `in_transit → at_risk` интересует немедленно.
  """

  require Logger

  alias OrbitalFreight.Events.Envelope
  alias OrbitalFreight.Events.Fanout.{Delivery, Preferences}

  # Переходы статуса freight.shipments, о которых уведомляем. Остальные комбинации
  # из CHECK-ограничения таблицы проходят молча.
  @notable_statuses ~w(at_risk held_at_customs delivered cancelled)

  # Типы сканирования, достойные уведомления. gate_in/gate_out случаются десятками
  # раз за рейс и в почте создают только шум.
  @notable_scan_types ~w(proof_of_delivery damage_report customs_inspection seal_check)

  @doc """
  `shipment.scanned`. Уведомление уходит тому, кто сканировал, и — для
  `proof_of_delivery` — подписчикам на завершение доставки.

  Событие несёт `position` как `{lat, lon}` либо `null`: сканирование из офлайна
  (приложение inspector-android копит их в дороге) приходит без координат, и
  шаблон обязан это переживать.
  """
  @spec scanned(Envelope.t()) :: :ok | {:error, term()}
  def scanned(%Envelope{payload: payload} = envelope) do
    scan_type = payload["scan_type"]

    if scan_type in @notable_scan_types do
      recipients = Preferences.resolve([payload["scanned_by_user_id"]], envelope.event_name)

      Delivery.deliver(envelope, template_for_scan(scan_type), recipients, %{
        "scan_id" => payload["scan_id"],
        "shipment_id" => payload["shipment_id"],
        "container_id" => payload["container_id"],
        "facility_id" => payload["facility_id"],
        "scan_type" => scan_type,
        "occurred_at" => payload["occurred_at"],
        # Разрыв между occurred_at и recorded_at показывают в письме отдельно:
        # для офлайн-сканов он бывает в часах, и без него время выглядит враньём.
        "recorded_at" => payload["recorded_at"],
        "position" => payload["position"],
        "device_serial" => payload["device_serial"]
      })
    else
      :ok
    end
  end

  @doc """
  `shipment.status.changed`. Статус `at_risk` появляется здесь как следствие
  `telemetry.alert.raised`: container-registry переводит отгрузку в него, потребив
  алерт (§4.9). Поэтому по одному инциденту человек получает два письма — про
  сам алерт от `OrbitalFreight.Events.Handlers.TelemetryAlerts` и про статус
  отсюда, — и это осознанно: они адресованы разным ролям.
  """
  @spec status_changed(Envelope.t()) :: :ok | {:error, term()}
  def status_changed(%Envelope{payload: payload} = envelope) do
    to_status = payload["to_status"]

    if to_status in @notable_statuses do
      recipients = Preferences.resolve([payload["changed_by"]], envelope.event_name, urgent: to_status == "at_risk")

      Delivery.deliver(envelope, "shipment_status_" <> to_status, recipients, %{
        "shipment_id" => payload["shipment_id"],
        "from_status" => payload["from_status"],
        "to_status" => to_status,
        "reason_code" => payload["reason_code"],
        "changed_at" => payload["changed_at"]
      })
    else
      Logger.debug("uninteresting status transition ignored", Envelope.log_metadata(envelope))
      :ok
    end
  end

  @doc """
  `fleet.assignment.created`. Основной канал — push в driver-ios: водителю нужно
  увидеть назначение раньше, чем он откроет почту. Событие приходит уже после
  того, как fleet-service провёл резервирование через `fleet.v1.FleetService/Assign`
  и exclusion-ограничение на `fleet.vehicle_assignments` подтвердило, что машина
  свободна, — переспрашивать нечего.
  """
  @spec assignment_created(Envelope.t()) :: :ok | {:error, term()}
  def assignment_created(%Envelope{payload: payload} = envelope) do
    recipients =
      [payload["driver_id"], payload["assigned_by"]]
      |> Enum.reject(&is_nil/1)
      |> Preferences.resolve(envelope.event_name)

    Delivery.deliver(envelope, "assignment_created", recipients, %{
      "assignment_id" => payload["assignment_id"],
      "shipment_id" => payload["shipment_id"],
      "leg_id" => payload["leg_id"],
      "vehicle_id" => payload["vehicle_id"],
      "carrier_id" => payload["carrier_id"],
      "assigned_at" => payload["assigned_at"]
    })
  end

  @doc """
  `route.replanned`. Уведомляем только тогда, когда изменились ноги маршрута:
  пустой `legs_changed` означает пересчёт ETA без смены плана, а такие события
  routing-service публикует пачками при каждом обновлении дорожной обстановки.

  Освобождением назначений, чей `leg_id` исчез, занимается fleet-service — он
  тоже подписан на это событие (§4.11). Backbone здесь только рассказывает людям.
  """
  @spec route_replanned(Envelope.t()) :: :ok | {:error, term()}
  def route_replanned(%Envelope{payload: payload} = envelope) do
    changed = payload["legs_changed"] || []

    if changed == [] do
      :ok
    else
      recipients = Preferences.resolve([payload["planned_by"]], envelope.event_name)

      Delivery.deliver(envelope, "route_replanned", recipients, %{
        "route_id" => payload["route_id"],
        "shipment_id" => payload["shipment_id"],
        "version" => payload["version"],
        "previous_version" => payload["previous_version"],
        "strategy" => payload["strategy"],
        "reason_code" => payload["reason_code"],
        "legs_changed_count" => length(changed),
        # Расстояние в метрах и длительность в секундах — как на шине (§0.2).
        # Перевод в километры и часы делает шаблон, а не обработчик.
        "total_distance_m" => payload["total_distance_m"],
        "total_duration_s" => payload["total_duration_s"]
      })
    end
  end

  defp template_for_scan("proof_of_delivery"), do: "delivery_confirmed"
  defp template_for_scan("damage_report"), do: "container_damage_reported"
  defp template_for_scan("customs_inspection"), do: "customs_inspection_recorded"
  defp template_for_scan("seal_check"), do: "seal_check_recorded"
end
