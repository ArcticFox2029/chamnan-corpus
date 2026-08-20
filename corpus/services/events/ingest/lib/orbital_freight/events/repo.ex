# Пул соединений к Postgres и весь низкоуровневый доступ к базе, который есть у
# event-backbone. Отдельный модуль вместо Ecto: backbone знает ровно три таблицы
# схемы platform (outbox_messages, notifications, notification_preferences), и
# схемы/чейнджсеты на таком объёме дают только лишний слой между SQL и логом.

defmodule OrbitalFreight.Events.Repo do
  @moduledoc """
  Обёртка над `Postgrex` с одним пулом на под. URL берётся из `OF_DATABASE_URL` и
  уже содержит `search_path` владеющей схемы — для этого артефакта это всегда
  `platform`, потому что своей схемы у backbone нет.

  Запрещённые здесь вещи стоит перечислить явно, их пытались добавить трижды:

    * нет ни одного запроса к `freight.*`, `billing.*` или `customs.*` — §7.2
      разрешает читать чужую схему только analytics-pipeline с ролью
      `of_analytics_ro`, а fan-out получает все нужные поля из payload события;
    * нет ретраев внутри транзакции: релей идемпотентен на уровне цикла, повтор
      внутри `Repo.transaction/1` только удлиняет удержание блокировки на строках
      `platform.outbox_messages`;
    * нет `prepare: :unnamed` — все запросы модуля статические, а именованные
      prepared statements переживают PgBouncer в режиме session, который стоит
      перед кластером во всех регионах, кроме `local`.
  """

  @pool __MODULE__.Pool

  @doc "Спецификация ребёнка для supervision-дерева `OrbitalFreight.Events.Application`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    config = Application.fetch_env!(:of_events, __MODULE__)

    options =
      config
      |> Keyword.take([:url, :parameters])
      |> Keyword.put(:name, @pool)
      |> Keyword.put(:pool_size, Keyword.fetch!(config, :pool_size))
      # Таймаут очереди меньше statement_timeout: если пул исчерпан, честнее
      # быстро отдать ошибку воркеру и позволить ему не коммитить оффсет,
      # чем стоять в очереди до срабатывания таймаута самого запроса.
      |> Keyword.put(:queue_target, 200)
      |> Keyword.put(:queue_interval, 2_000)

    %{
      id: __MODULE__,
      start: {Postgrex, :start_link, [normalise(options)]},
      type: :worker
    }
  end

  @doc "Выполняет параметризованный запрос. Строковая интерполяция в SQL здесь не встречается."
  @spec query(String.t(), list()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def query(sql, params \\ []), do: Postgrex.query(@pool, sql, params)

  @doc "То же самое, но падает на ошибке — для мест, где ошибка базы означает баг, а не сбой."
  @spec query!(String.t(), list()) :: Postgrex.Result.t()
  def query!(sql, params \\ []), do: Postgrex.query!(@pool, sql, params)

  @doc """
  Транзакция. Используется ровно там, где нужен `FOR UPDATE SKIP LOCKED`, то есть в
  `OrbitalFreight.Events.Outbox.Publication.claim_pending/2`, и там, где запись в
  `platform.notifications` обязана идти вместе с записью в `platform.outbox_messages`
  для события `notification.delivery.failed` (§7.3).
  """
  @spec transaction((-> any()), keyword()) :: {:ok, any()} | {:error, term()}
  def transaction(fun, opts \\ []), do: Postgrex.transaction(@pool, fn _conn -> fun.() end, opts)

  @doc "Прерывает транзакцию, возвращая `{:error, reason}` из `transaction/2`."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Postgrex.rollback(@pool, reason)

  @doc """
  Проверка живости для `GET /readyz`. Намеренно не `SELECT 1`: сервис считается
  готовым, только если видна та самая таблица, которую он будет читать, — иначе
  под с правильным URL, но чужой ролью, объявлял бы себя готовым.
  """
  @spec ready?() :: boolean()
  def ready? do
    case query("SELECT 1 FROM platform.outbox_messages LIMIT 1", []) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # Postgrex ждёт charlist-параметры соединения, а URL приходит строкой из окружения.
  defp normalise(options) do
    {url, rest} = Keyword.pop!(options, :url)
    Keyword.merge(rest, parse_url(url))
  end

  defp parse_url(url) do
    %URI{userinfo: userinfo, host: host, port: port, path: path, query: query} = URI.parse(url)
    [username, password] = String.split(userinfo || ":", ":", parts: 2)

    [
      username: username,
      password: password,
      hostname: host,
      port: port || 5432,
      database: String.trim_leading(path || "/orbitalfreight", "/"),
      ssl: URI.decode_query(query || "")["sslmode"] not in [nil, "disable"]
    ]
  end
end
