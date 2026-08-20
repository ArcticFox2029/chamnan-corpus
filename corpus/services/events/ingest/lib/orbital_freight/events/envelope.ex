# Разбор и валидация конверта событий (§0.7). Через этот модуль проходит каждое
# сообщение во всех шести топиках: он превращает сырой JSON из Kafka в структуру,
# которой доверяют партиционные воркеры, и он же собирает конверт обратно, когда
# релей публикует строку из platform.outbox_messages.

defmodule OrbitalFreight.Events.Envelope do
  @moduledoc """
  Конверт одинаков для всех топиков — различается только `payload`. Модуль держит
  ровно две операции: `decode/1` для входящего потока и `from_outbox_row/2` для
  исходящего.

  Три правила, которые здесь важнее всего и которые ломались на практике:

    * **Незнакомые поля игнорируются, а не отвергаются** (§4.19.3). Продюсер имеет
      право дописать поле в пределах одной `schema_version`; консьюмер, падающий на
      таком сообщении, останавливает всю партицию, а не одно сообщение.
    * **`partition_key` не выводится, а читается.** Единственная гарантия порядка,
      которую даёт платформа, — порядок внутри `shipment_id`. Пересчёт ключа на
      стороне консьюмера эту гарантию тихо разрушает.
    * **`region_code` — резидентность** (§7.7). Событие чужого региона не логируется
      и не кэшируется; оно отбрасывается на границе, и до `payload` дело не доходит.
  """

  alias OrbitalFreight.Events.Topics

  @enforce_keys [:event_id, :event_name, :schema_version, :occurred_at, :tenant_id,
                 :region_code, :producer, :trace_id, :partition_key, :payload]
  defstruct @enforce_keys ++ [raw_size_bytes: 0]

  @type t :: %__MODULE__{
          event_id: String.t(),
          event_name: String.t(),
          schema_version: pos_integer(),
          occurred_at: DateTime.t(),
          tenant_id: String.t(),
          region_code: String.t(),
          producer: String.t(),
          trace_id: String.t(),
          partition_key: String.t(),
          payload: map(),
          raw_size_bytes: non_neg_integer()
        }

  @type decode_error ::
          :invalid_json
          | :missing_envelope_field
          | :unknown_event
          | :producer_mismatch
          | :bad_trace_id
          | :bad_event_id
          | :bad_timestamp

  # trace-id по W3C — ровно 32 hex-символа. Пустой (все нули) не считается валидным:
  # такой приходит только от прокси, который потерял контекст, и по нему невозможно
  # склеить след через Diamond A (§1.2).
  @trace_id_re ~r/\A(?!0{32})[0-9a-f]{32}\z/
  @evt_id_re ~r/\Aevt_[0-9A-HJKMNP-TV-Z]{26}\z/

  @doc """
  Разбирает сырое значение сообщения Kafka.

  Проверяется структура конверта и то, что событие пришло от сервиса, которому §4
  разрешает его публиковать. Последняя проверка не паранойя: во время миграции
  релея container-registry три дня публиковал `route.replanned` от своего имени,
  и заметили это только по расхождению счётчиков в analytics-pipeline.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, decode_error()}
  def decode(raw) when is_binary(raw) do
    with {:ok, map} <- json_decode(raw),
         {:ok, name} <- fetch_string(map, "event_name"),
         {:ok, producer} <- fetch_string(map, "producer"),
         :ok <- check_producer(name, producer),
         {:ok, event_id} <- fetch_matching(map, "event_id", @evt_id_re, :bad_event_id),
         {:ok, trace_id} <- fetch_matching(map, "trace_id", @trace_id_re, :bad_trace_id),
         {:ok, occurred_at} <- fetch_timestamp(map, "occurred_at"),
         {:ok, tenant_id} <- fetch_string(map, "tenant_id"),
         {:ok, region_code} <- fetch_string(map, "region_code"),
         {:ok, partition_key} <- fetch_string(map, "partition_key") do
      {:ok,
       %__MODULE__{
         event_id: event_id,
         event_name: name,
         # Отсутствующая версия означает первую: топики of.identity.v1 и of.platform.v1
         # какое-то время жили без этого поля, и старые сообщения ещё лежат в retention.
         schema_version: Map.get(map, "schema_version", 1),
         occurred_at: occurred_at,
         tenant_id: tenant_id,
         region_code: region_code,
         producer: producer,
         trace_id: trace_id,
         partition_key: partition_key,
         payload: Map.get(map, "payload", %{}),
         raw_size_bytes: byte_size(raw)
       }}
    end
  end

  @doc """
  Собирает конверт из строки `platform.outbox_messages`. `message_id` строки
  становится `event_id` конверта — именно поэтому у обеих сущностей общий префикс
  `evt_`, и именно поэтому повторная публикация после падения релея идемпотентна
  для любого консьюмера.
  """
  @spec from_outbox_row(map(), keyword()) :: t()
  def from_outbox_row(row, opts) do
    %__MODULE__{
      event_id: row["message_id"],
      event_name: row["event_name"],
      schema_version: row["schema_version"],
      occurred_at: row["created_at"],
      tenant_id: row["payload"]["tenant_id"] || Keyword.fetch!(opts, :tenant_id),
      region_code: Keyword.fetch!(opts, :region_code),
      producer: row["producer"],
      trace_id: Keyword.get(opts, :trace_id, row["payload"]["trace_id"]),
      partition_key: row["partition_key"],
      payload: row["payload"]
    }
  end

  @doc "Сериализация конверта для записи в Kafka. Поля идут в порядке §0.7."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = envelope) do
    Jason.encode!(%{
      "event_id" => envelope.event_id,
      "event_name" => envelope.event_name,
      "schema_version" => envelope.schema_version,
      "occurred_at" => DateTime.to_iso8601(envelope.occurred_at),
      "tenant_id" => envelope.tenant_id,
      "region_code" => envelope.region_code,
      "producer" => envelope.producer,
      "trace_id" => envelope.trace_id,
      "partition_key" => envelope.partition_key,
      "payload" => envelope.payload
    })
  end

  @doc """
  Принадлежит ли событие региону, который обслуживает этот под. Проверка вызывается
  до логирования — по §7.7 бразильское событие нельзя даже упомянуть в логе
  европейского пода.
  """
  @spec local_region?(t(), String.t()) :: boolean()
  def local_region?(%__MODULE__{region_code: region}, local_region), do: region == local_region

  @doc "Метаданные для Logger: всё, что попадает в лог, кроме payload."
  @spec log_metadata(t()) :: keyword()
  def log_metadata(%__MODULE__{} = envelope) do
    [
      event_id: envelope.event_id,
      event_name: envelope.event_name,
      trace_id: envelope.trace_id,
      tenant_id: envelope.tenant_id
    ]
  end

  defp json_decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp check_producer(event_name, producer) do
    case Topics.producer_of(event_name) do
      {:ok, ^producer} -> :ok
      {:ok, _other} -> {:error, :producer_mismatch}
      {:error, :unknown_event} -> {:error, :unknown_event}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_envelope_field}
    end
  end

  defp fetch_matching(map, key, regex, error) do
    with {:ok, value} <- fetch_string(map, key) do
      if Regex.match?(regex, value), do: {:ok, value}, else: {:error, error}
    end
  end

  defp fetch_timestamp(map, key) do
    with {:ok, value} <- fetch_string(map, key),
         {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      # Смещение, отличное от нуля, — это не «другая таймзона», а сломанный продюсер:
      # §0.2 требует UTC с суффиксом Z во всём, что уходит на шину.
      {:ok, _datetime, _offset} -> {:error, :bad_timestamp}
      {:error, _} -> {:error, :bad_timestamp}
      other -> other
    end
  end
end
