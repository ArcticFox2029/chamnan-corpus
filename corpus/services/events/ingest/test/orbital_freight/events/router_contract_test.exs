# Контрактный тест против §4 спецификации: таблица топиков и таблица маршрутов
# fan-out обязаны совпадать с документом. Тест дешёвый и ловит самый частый вид
# расхождения — подписку, добавленную в один список и забытую во втором.

defmodule OrbitalFreight.Events.RouterContractTest do
  use ExUnit.Case, async: true

  alias OrbitalFreight.Events.Fanout.Router
  alias OrbitalFreight.Events.Topics

  test "в каталоге ровно восемнадцать событий и шесть топиков" do
    assert length(Topics.all_events()) == 18

    topics =
      Topics.all_events()
      |> Enum.map(fn event ->
        {:ok, topic} = Topics.topic_for(event)
        topic
      end)
      |> Enum.uniq()

    assert length(topics) == 6
  end

  test "у каждой подписки notification-service есть обработчик" do
    # То же самое делает Router.verify_coverage!/0 при старте пода; тест нужен,
    # чтобы расхождение падало в CI, а не в момент выкатки в первый регион.
    assert :ok = Router.verify_coverage!()
  end

  test "backbone не обрабатывает события, которые ему не адресованы" do
    declared = MapSet.new(Topics.subscribed_events("notification-service"))

    for event <- Router.routed_events() do
      assert MapSet.member?(declared, event), "#{event} routed but notification-service is not its consumer"
    end
  end

  test "число партиций совпадает с §4" do
    assert Topics.expected_partitions("of.telemetry.v1") == 96
    assert Topics.expected_partitions("of.freight.v1") == 48
    assert Topics.expected_partitions("of.platform.v1") == 24
    assert Topics.expected_partitions("of.billing.v1") == 12
  end

  test "имя dead-letter топика выводится, а не задаётся" do
    assert Topics.dlq_topic("of.freight.v1") == "of.freight.v1.dlq"
  end

  test "продюсер каждого события совпадает со спецификацией" do
    assert {:ok, "container-registry"} = Topics.producer_of("shipment.scanned")
    assert {:ok, "telemetry-ingest"} = Topics.producer_of("telemetry.alert.raised")
    assert {:ok, "billing-service"} = Topics.producer_of("billing.invoice.settled")
    assert {:ok, "reconciliation-service"} = Topics.producer_of("reconciliation.discrepancy.opened")
  end

  test "релей поднимается только у сервисов-продюсеров" do
    assert Topics.produces?("notification-service")
    assert Topics.produces?("customs-service")
    # geo-service и audit-ledger не публикуют ни одного события §4 — sidecar с
    # релеем рядом с ними означал бы пустой цикл опроса базы каждые 250 мс.
    refute Topics.produces?("geo-service")
    refute Topics.produces?("audit-ledger")
  end
end
