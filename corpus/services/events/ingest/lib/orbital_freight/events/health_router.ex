# Четыре универсальных эндпоинта из §3.15 — единственный HTTP, который есть у
# event-backbone в режиме relay-sidecar. Когда тот же артефакт запущен как
# notification-service, поверх этого роутера монтируется /v1 из §3.10.

defmodule OrbitalFreight.Events.HealthRouter do
  @moduledoc """
  `GET /healthz`, `GET /readyz`, `GET /metrics`, `GET /version`.

  Разница между двумя первыми — не формальность, и её ломали дважды. `/healthz`
  отвечает, пока жив процесс BEAM, и не трогает ни базу, ни брокер: kubelet бьёт
  по нему каждые несколько секунд и перезапускает под при неответе, поэтому
  добавить сюда `SELECT` — значит устроить перезапуск всех подов региона при
  первой же паузе в Postgres.

  `/readyz` наоборот проверяет всё, без чего работать нельзя: пул к базе, наличие
  метаданных топиков у брокера и доступность identity-service. Неготовый под
  снимается с балансировщика, но продолжает дочитывать свою партицию — это
  правильно, чтение из Kafka не зависит от того, ходит ли к нам трафик.
  """

  use Plug.Router

  alias OrbitalFreight.Events.{Repo, Topics}
  alias OrbitalFreight.Events.Telemetry.Reporter

  plug(:match)
  plug(:dispatch)

  @version Mix.Project.config()[:version]

  # SHA сборки кладёт в priv/ CI-задание, а не окружение: §5 перечисляет каждую
  # переменную OF_* поимённо, и заводить ещё одну ради одной строки в /version
  # означало бы править спецификацию.
  @build_sha (case File.read("priv/build_sha") do
                {:ok, sha} -> String.trim(sha)
                {:error, _} -> "unknown"
              end)

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  get "/readyz" do
    checks = %{
      database: Repo.ready?(),
      kafka: kafka_ready?(),
      identity: identity_ready?()
    }

    status = if Enum.all?(Map.values(checks)), do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{ready: status == 200, checks: checks}))
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, Reporter.scrape())
  end

  get "/version" do
    body = %{
      service: Application.fetch_env!(:of_events, :service_name),
      version: @version,
      build_sha: @build_sha,
      # Номер миграции, которого ждёт этот бинарник. Деплой сравнивает его с
      # применённым в кластере: под, поднятый на более старой схеме, не увидит
      # столбцов, из которых читает.
      schema_migration: Application.fetch_env!(:of_events, :expected_migration),
      region_code: Application.fetch_env!(:of_events, :region_code)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  match _ do
    # Ошибка в формате §0.4 — одинаковом для всех четырнадцати сервисов, включая
    # тот случай, когда её отдаёт роутер здоровья.
    body = %{
      error: %{
        code: "not_found",
        http_status: 404,
        message: "no route for #{conn.method} #{conn.request_path}",
        trace_id: trace_id(conn),
        retryable: false,
        fields: []
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(body))
  end

  defp kafka_ready? do
    Enum.all?(Topics.subscribed_topics(Application.fetch_env!(:of_events, :service_name)), fn topic ->
      match?({:ok, _}, :brod.get_partitions_count(:of_events_client, topic))
    end)
  end

  # identity-service опрашивается по JWKS, а не по gRPC-интроспекции: у пода в
  # момент проверки нет ничьего токена, а §1.2 разрешает пережить недоступность
  # identity-service в пределах OF_IDENTITY_JWKS_GRACE_SECONDS на кэше ключей.
  defp identity_ready? do
    url = Application.fetch_env!(:of_events, :identity)[:jwks_url]

    case Finch.build(:get, url) |> Finch.request(OrbitalFreight.Events.Finch, receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  defp trace_id(conn) do
    case get_req_header(conn, "x-of-trace-id") do
      [value | _] -> value
      [] -> String.duplicate("0", 32)
    end
  end
end
