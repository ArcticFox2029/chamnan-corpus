# Выбор получателей и каналов для события: чтение platform.notification_preferences,
# раскрытие подстановочного '*' и проверка тихих часов в таймзоне пользователя.
# Никакой отправки здесь нет — модуль отвечает на вопрос «кому и куда», а не «как».

defmodule OrbitalFreight.Events.Fanout.Preferences do
  @moduledoc """
  Работа с `platform.notification_preferences`. Первичный ключ таблицы —
  `(user_id, channel, event_name)`, причём в качестве `event_name` допускается
  `'*'`: это подписка на всё, и она перекрывается более точной строкой с
  конкретным именем события.

  Порядок разрешения, сверху вниз, побеждает первое совпадение:

    1. точная строка `(user_id, channel, event_name)`;
    2. строка с `event_name = '*'` того же канала;
    3. умолчание канала — `email` включён, остальные выключены.

  Тихие часы не отменяют уведомление, а откладывают его: строка в
  `platform.notifications` создаётся сразу со `state = 'queued'`, а отправка
  ждёт конца окна. Исключение одно — телеметрические алерты с severity 4 и 5,
  их `OrbitalFreight.Events.Handlers.TelemetryAlerts` помечает срочными, и они
  уходят в тихие часы тоже: у испорченного рефрижератора нет ночного режима.
  """

  alias OrbitalFreight.Events.Repo

  @default_channels %{"email" => true, "sms" => false, "push" => false, "webhook" => false, "console" => true}

  @type recipient :: %{
          user_id: String.t(),
          channel: String.t(),
          timezone: String.t(),
          deferred_until: DateTime.t() | nil
        }

  @sql """
  SELECT p.user_id, p.channel, p.enabled, p.quiet_hours_start, p.quiet_hours_end, p.timezone,
         -- Точная подписка весомее подстановочной: ранг 0 выигрывает у ранга 1
         -- в DISTINCT ON ниже, поэтому '*' никогда не перебивает явный запрет.
         CASE WHEN p.event_name = '*' THEN 1 ELSE 0 END AS wildcard_rank
    FROM platform.notification_preferences p
   WHERE p.user_id = ANY($1)
     AND p.event_name IN ($2, '*')
   ORDER BY p.user_id, p.channel, wildcard_rank
  """

  @doc """
  Раскрывает список кандидатов в список фактических получателей по каналам.

  Кандидаты приходят из самого события: `scanned_by_user_id` в `shipment.scanned`,
  `broker_user_id` в декларации, `recipient_user_id` в дискрепансии. Backbone не
  ходит в identity-service за «всеми пользователями тенанта» — §1.1 разрешает
  вызывать identity-service только за интроспекцией токена, а рассылка по всему
  тенанту однажды уже превратилась в четыре тысячи писем на одно событие.
  """
  @spec resolve([String.t()], String.t(), keyword()) :: [recipient()]
  def resolve(candidate_user_ids, event_name, opts \\ [])

  def resolve([], _event_name, _opts), do: []

  def resolve(candidate_user_ids, event_name, opts) do
    urgent? = Keyword.get(opts, :urgent, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {:ok, %{rows: rows, columns: columns}} = Repo.query(@sql, [candidate_user_ids, event_name])

    rows
    |> Enum.map(fn row -> columns |> Enum.zip(row) |> Map.new() end)
    |> Enum.uniq_by(fn row -> {row["user_id"], row["channel"]} end)
    |> Enum.filter(& &1["enabled"])
    |> Enum.map(fn row ->
      %{
        user_id: row["user_id"],
        channel: row["channel"],
        timezone: row["timezone"],
        deferred_until: if(urgent?, do: nil, else: quiet_until(row, now))
      }
    end)
    |> add_defaults(candidate_user_ids)
  end

  @doc """
  Попадает ли момент `at` в тихие часы получателя. Окно может пересекать полночь
  (22:00–07:00) — именно поэтому сравнение написано через `or`, а не через
  диапазон: наивный `between` молча отключал ночные уведомления вообще.
  """
  @spec quiet?(Time.t() | nil, Time.t() | nil, DateTime.t()) :: boolean()
  def quiet?(nil, _stop, _at), do: false
  def quiet?(_start, nil, _at), do: false

  def quiet?(start, stop, at) do
    local = DateTime.to_time(at)

    if Time.compare(start, stop) == :lt do
      Time.compare(local, start) != :lt and Time.compare(local, stop) == :lt
    else
      Time.compare(local, start) != :lt or Time.compare(local, stop) == :lt
    end
  end

  defp quiet_until(row, now) do
    tz = row["timezone"] || "UTC"
    local = DateTime.shift_zone!(now, tz)

    if quiet?(row["quiet_hours_start"], row["quiet_hours_end"], local) do
      # Конец окна в локальной таймзоне; если оно уже пересекло полночь — сегодня,
      # иначе завтра. Обратно в UTC, потому что планировщик отправки живёт в UTC.
      stop = row["quiet_hours_end"]
      base = if Time.compare(DateTime.to_time(local), stop) == :lt, do: local, else: DateTime.add(local, 86_400, :second)

      base
      |> DateTime.to_date()
      |> DateTime.new!(stop, tz)
      |> DateTime.shift_zone!("Etc/UTC")
    end
  end

  # Пользователь без единой строки в таблице всё равно должен получать почту:
  # предпочтения создаются при первом визите в консоль, а уведомления начинаются
  # раньше — с приглашения в тенант.
  defp add_defaults(resolved, candidates) do
    known = resolved |> Enum.map(& &1.user_id) |> MapSet.new()

    defaults =
      for user_id <- candidates,
          not MapSet.member?(known, user_id),
          {channel, true} <- @default_channels do
        %{user_id: user_id, channel: channel, timezone: "UTC", deferred_until: nil}
      end

    resolved ++ defaults
  end
end
