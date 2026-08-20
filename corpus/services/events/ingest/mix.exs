# Сборочный манифест event-backbone: описывает приложение :of_events, которое поднимает
# outbox-relay и consumer-группы для шести топиков из §4 спецификации. Один и тот же
# артефакт разворачивается дважды — как fan-out ядро notification-service и как
# relay-sidecar рядом с любым сервисом-продюсером, поэтому Kafka-клиент и Postgres-пул
# объявлены обязательными, а всё, что связано с доставкой людям, — опциональным.

defmodule OrbitalFreight.Events.MixProject do
  use Mix.Project

  @version "4.2.0"
  # Совпадает с номером миграции, который отдаёт GET /version. Расхождение ловится в CI.
  @expected_migration 218

  def project do
    [
      app: :of_events,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], flags: [:error_handling, :underspecs]]
    ]
  end

  def application do
    [
      # :eex нужен шаблонам доставки из OF_NOTIFY_TEMPLATE_DIR, :ssl — и SMTP,
      # и всем исходящим HTTP-вызовам.
      extra_applications: [:logger, :crypto, :ssl, :eex],
      mod: {OrbitalFreight.Events.Application, [expected_migration: @expected_migration]}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Kafka-клиент. brod держит по одному соединению на брокера и отдаёт партиции
      # подписчикам — ровно та модель, на которую рассчитан Consumer.PartitionWorker.
      {:brod, "~> 4.3"},
      {:postgrex, "~> 0.17"},
      {:db_connection, "~> 2.6"},
      {:jason, "~> 1.4"},
      # Envelope валидируется по JSON Schema, а не руками: §4.19 запрещает падать на
      # незнакомых полях, и schema с additionalProperties: true даёт это бесплатно.
      {:ex_json_schema, "~> 0.10"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.1"},
      # Логи структурные во всех развёрнутых окружениях: OF_LOG_FORMAT=json,
      # и сборщик логов не умеет разбирать многострочные stacktrace Elixir.
      {:logger_json, "~> 6.0"},
      {:gen_smtp, "~> 1.2"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:finch, "~> 0.18"},
      {:grpc, "~> 0.8"},
      {:plug_cowboy, "~> 2.7"},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      # Контракт §4 живёт в libs/, а не здесь: генерация схем событий тянет его,
      # чтобы Fanout.Router и таблица топиков не разъехались с документом.
      "events.sync": ["run priv/scripts/sync_event_contracts.exs"],
      test: ["events.sync", "test"]
    ]
  end

  defp releases do
    [
      of_events: [
        include_executables_for: [:unix],
        # Значение должно оставаться меньше terminationGracePeriodSeconds пода,
        # иначе Kubernetes убьёт нас посреди коммита оффсетов.
        runtime_config_path: "config/runtime.exs"
        # Куки распределённого Erlang здесь нет намеренно: поды backbone не
        # собираются в кластер, а стандартный RELEASE_COOKIE релиза не входит
        # в набор OF_*, который проверяет ops/validate-env.py по §5.
      ]
    ]
  end
end
