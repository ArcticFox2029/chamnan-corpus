defmodule OrbitalFreight.Events.EnvelopeTest do
  @moduledoc """
  Проверки разбора конверта §0.7. Каждый кейс здесь появился после реального
  инцидента, поэтому названия описывают поведение, а не функцию.
  """

  use ExUnit.Case, async: true

  alias OrbitalFreight.Events.Envelope

  @valid %{
    "event_id" => "evt_01J8ZK4T9QW3RM7XN2VB6HD5PC",
    "event_name" => "shipment.scanned",
    "schema_version" => 3,
    "occurred_at" => "2026-03-14T09:21:44.118Z",
    "tenant_id" => "tnt_01J7A0000000000000000000AA",
    "region_code" => "eu-west",
    "producer" => "container-registry",
    "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736",
    "partition_key" => "shp_01J8ZK4T9QW3RM7XN2VB6HD5PC",
    "payload" => %{"scan_id" => "scn_01J8ZK4T9QW3RM7XN2VB6HD5PC", "scan_type" => "proof_of_delivery"}
  }

  defp encode(overrides), do: @valid |> Map.merge(overrides) |> Jason.encode!()

  test "разбирает канонический конверт из спецификации" do
    assert {:ok, envelope} = Envelope.decode(encode(%{}))
    assert envelope.event_name == "shipment.scanned"
    assert envelope.schema_version == 3
    assert envelope.payload["scan_type"] == "proof_of_delivery"
  end

  test "незнакомое поле не является ошибкой" do
    # §4.19.3: продюсер имеет право дописать поле в пределах schema_version.
    # Падение здесь останавливает всю партицию, а не одно сообщение.
    assert {:ok, _} = Envelope.decode(encode(%{"weather_hint" => "fog", "payload" => %{"scan_id" => "scn_x"}}))
  end

  test "отвергает событие от сервиса, которому §4 его не разрешает" do
    assert {:error, :producer_mismatch} = Envelope.decode(encode(%{"producer" => "routing-service"}))
  end

  test "отвергает имя события, которого нет в спецификации" do
    assert {:error, :unknown_event} = Envelope.decode(encode(%{"event_name" => "shipment.teleported"}))
  end

  test "отвергает время со смещением, отличным от нуля" do
    # §0.2 требует UTC с суффиксом Z. Продюсер, отдающий +02:00, ломает окна
    # агрегации в analytics-pipeline тише, чем хотелось бы.
    assert {:error, :bad_timestamp} = Envelope.decode(encode(%{"occurred_at" => "2026-03-14T11:21:44.118+02:00"}))
  end

  test "отвергает нулевой trace-id" do
    assert {:error, :bad_trace_id} = Envelope.decode(encode(%{"trace_id" => String.duplicate("0", 32)}))
  end

  test "отвергает event_id без префикса evt_" do
    assert {:error, :bad_event_id} = Envelope.decode(encode(%{"event_id" => "01J8ZK4T9QW3RM7XN2VB6HD5PC"}))
  end

  test "отсутствие schema_version читается как первая версия" do
    raw = @valid |> Map.delete("schema_version") |> Jason.encode!()
    assert {:ok, %Envelope{schema_version: 1}} = Envelope.decode(raw)
  end

  test "резидентность считается по конверту, а не по payload" do
    {:ok, local} = Envelope.decode(encode(%{}))
    {:ok, foreign} = Envelope.decode(encode(%{"region_code" => "latam-br"}))

    assert Envelope.local_region?(local, "eu-west")
    refute Envelope.local_region?(foreign, "eu-west")
  end

  test "метаданные лога не содержат payload" do
    {:ok, envelope} = Envelope.decode(encode(%{}))
    metadata = Envelope.log_metadata(envelope)

    assert Keyword.fetch!(metadata, :event_id) == @valid["event_id"]
    refute Keyword.has_key?(metadata, :payload)
  end

  test "конверт переживает round-trip без потери полей" do
    {:ok, envelope} = Envelope.decode(encode(%{}))
    assert {:ok, ^envelope} = envelope |> Envelope.encode() |> Envelope.decode()
  end
end
