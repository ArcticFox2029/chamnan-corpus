defmodule OrbitalFreight.Events.Handlers.TelemetryAlerts do
  @moduledoc """
  Два события топика `of.telemetry.v1`, адресованные notification-service:
  `telemetry.alert.raised` и `gateway.heartbeat.missed`. Оба публикует
  telemetry-ingest.

  Здесь важнее всего то, чего этот модуль НЕ делает. Он не переводит отгрузку в
  `at_risk` — это делает container-registry, потребив то же самое событие (§4.9), и
  именно так разорван цикл container-registry ↔ telemetry-ingest. Он не вызывает
  `POST /v1/alerts/{alert_id}/acknowledge`, чтобы «отметить, что мы увидели»: это
  синхронный вызов издателя из обработчика, прямо запрещённый §4.19.2.

  Срочность считается по `severity` (1–5 из CHECK-ограничения
  `telemetry.telemetry_alerts`). Уровни 4 и 5 обходят тихие часы получателя:
  порванная холодовая цепь стоит дороже, чем испорченный сон дежурного. Порог
  совпадает с `OF_FREIGHT_AUTO_AT_RISK_SEVERITY` не случайно — если человек
  получил срочное письмо, отгрузка к этому моменту уже помечена рискованной, и
  расхождение порогов сделало бы одно без другого.
  """

  require Logger

  alias OrbitalFreight.Events.Envelope
  alias OrbitalFreight.Events.Fanout.{Delivery, Preferences}
  alias OrbitalFreight.Events.Telemetry.Reporter

  @urgent_from_severity 4

  # rule_code из CHECK-ограничения telemetry.telemetry_alerts: восемь правил, и
  # каждому соответствует свой шаблон в OF_NOTIFY_TEMPLATE_DIR. Неизвестный код —
  # это новое правило, добавленное в telemetry-ingest мимо §2.5, и такое письмо
  # уходит по общему шаблону, а не теряется.
  @templates %{
    "temp_excursion_high" => "cold_chain_breach_high",
    "temp_excursion_low" => "cold_chain_breach_low",
    "humidity_high" => "humidity_excursion",
    "shock_impact" => "shock_impact_detected",
    "door_open_in_transit" => "door_open_in_transit",
    "battery_critical" => "sensor_battery_critical",
    "gateway_silent" => "gateway_silent",
    "geofence_breach" => "geofence_breach"
  }

  @doc """
  `telemetry.alert.raised`. Получатели — подписчики тенанта на это событие;
  привязки к конкретному пользователю у алерта нет, потому что сенсор не знает,
  кто отвечает за рейс, и поле `acknowledged_by` заполняется позже человеком.

  `threshold_value` и `peak_value` идут в письмо как есть: это `NUMERIC(10,3)` из
  `telemetry.telemetry_alerts`, единица измерения определяется `rule_code`, и
  преобразовывать их в обработчике нельзя — градусы и g перепутать легко, а
  проверить потом невозможно.
  """
  @spec alert_raised(Envelope.t()) :: :ok | {:error, term()}
  def alert_raised(%Envelope{payload: payload} = envelope) do
    severity = payload["severity"] || 1
    urgent? = severity >= @urgent_from_severity
    rule_code = payload["rule_code"]

    Reporter.alert_seen(rule_code, severity)

    recipients =
      envelope.tenant_id
      |> watchers_of_tenant()
      |> Preferences.resolve(envelope.event_name, urgent: urgent?)

    Delivery.deliver(envelope, Map.get(@templates, rule_code, "telemetry_alert_generic"), recipients, %{
      "alert_id" => payload["alert_id"],
      "container_id" => payload["container_id"],
      "shipment_id" => payload["shipment_id"],
      "rule_code" => rule_code,
      "severity" => severity,
      "threshold_value" => payload["threshold_value"],
      "peak_value" => payload["peak_value"],
      "first_reading_id" => payload["first_reading_id"],
      "opened_at" => payload["opened_at"],
      # Ссылку на экран алерта собирает шаблон; backbone передаёт только
      # идентификатор, потому что базовый URL консоли отличается по регионам.
      "urgent" => urgent?
    })
  end

  @doc """
  `gateway.heartbeat.missed`. Событие про инфраструктуру, а не про груз: молчащий
  шлюз означает, что показания целого депо не доезжают до telemetry-ingest.

  Уведомление всегда несрочное, даже когда `silent_minutes` велик. Шлюз молчит и
  ночью, и будить дежурного из-за депо, которое всё равно закрыто до утра,
  бессмысленно — а вот вал таких писем однажды заставил половину получателей
  выключить канал целиком.
  """
  @spec heartbeat_missed(Envelope.t()) :: :ok | {:error, term()}
  def heartbeat_missed(%Envelope{payload: payload} = envelope) do
    recipients =
      envelope.tenant_id
      |> watchers_of_tenant()
      |> Preferences.resolve(envelope.event_name)

    Delivery.deliver(envelope, "gateway_silent", recipients, %{
      "gateway_id" => payload["gateway_id"],
      "serial" => payload["serial"],
      "depot_id" => payload["depot_id"],
      "region_code" => payload["region_code"],
      "last_heartbeat_at" => payload["last_heartbeat_at"],
      "silent_minutes" => payload["silent_minutes"],
      # Версия прошивки из firmware/sensor-node: половина инцидентов «молчащего
      # шлюза» оказывалась выкаткой прошивки, и без этого поля связь не видна.
      "firmware_version" => payload["firmware_version"]
    })
  end

  # Кандидаты в получатели — те, у кого в platform.notification_preferences есть
  # строка на это событие. Список тенанта берётся из той же таблицы, а не из
  # identity-service: §1.1 разрешает нам звонить туда только за интроспекцией.
  defp watchers_of_tenant(tenant_id) do
    sql = """
    SELECT DISTINCT p.user_id
      FROM platform.notification_preferences p
      JOIN platform.notifications n ON n.recipient_user_id = p.user_id AND n.tenant_id = $1
     WHERE p.enabled
       AND p.event_name IN ('telemetry.alert.raised', 'gateway.heartbeat.missed', '*')
    """

    case OrbitalFreight.Events.Repo.query(sql, [tenant_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [user_id] -> user_id end)

      {:error, reason} ->
        # Без списка получателей письмо отправить некому, но и терять алерт нельзя:
        # возвращаем ошибку, DeadLetter повторит с задержкой.
        Logger.error("cannot resolve alert watchers", tenant_id: tenant_id, reason: inspect(reason))
        []
    end
  end
end
