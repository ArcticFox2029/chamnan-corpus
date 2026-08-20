# Транспортные адаптеры доставки: SMTP, SMS-шлюз и мобильный push. Три тонких
# модуля в одном файле сознательно — у них общий контракт из четырёх строк, и
# держать их порознь означало бы три файла по тридцать строк с одинаковой
# обвязкой. Логика «кому и что» живёт в Fanout.Delivery, здесь только «как».

defmodule OrbitalFreight.Events.Delivery.Channel do
  @moduledoc """
  Контракт канала доставки. Реализации обязаны уложиться в свой таймаут: вызов
  происходит внутри партиционного воркера, и медленный SMTP останавливает
  обработку всей партиции, а вместе с ней и порядок по `partition_key`.

  Возвращаемое значение различает временную и постоянную ошибку. Временную
  (`{:error, :timeout}`, 5xx у шлюза) повторяет `OrbitalFreight.Events.Consumer.DeadLetter`
  по своей лестнице задержек; постоянная (неизвестный шаблон, отсутствующий
  адрес) повторов не заслуживает и уезжает в `<topic>.dlq` сразу.
  """

  @callback send(recipient :: map(), template_code :: String.t(), payload :: map()) ::
              :ok | {:error, term()}

  @doc "Каналы, перечисленные в CHECK-ограничении `platform.notifications.channel`."
  @spec known() :: [String.t()]
  def known, do: ~w(email sms push webhook console)
end

defmodule OrbitalFreight.Events.Delivery.Smtp do
  @moduledoc """
  Почта. Адрес получателя берётся у identity-service (`GET /v1/users/{user_id}`) —
  это разрешённый синхронный вызов (§1.1), и единственный, ради которого мы туда
  ходим не за интроспекцией.

  Вложения не прикладываются байтами: в письмо уходит короткоживущая ссылка от
  document-service (`POST /v1/documents/{document_id}/signed-url`, 15 минут по
  `OF_DOCUMENT_SIGNED_URL_TTL_SECONDS`). Ссылка запрашивается в момент отправки,
  а не постановки в очередь, — между ними могут быть тихие часы длиной в ночь.
  """

  @behaviour OrbitalFreight.Events.Delivery.Channel

  require Logger

  @impl true
  def send(recipient, template_code, payload) do
    config = Application.fetch_env!(:of_events, :delivery)

    with {:ok, address} <- lookup_address(recipient.user_id),
         {:ok, body} <- render(template_code, recipient, payload),
         {:ok, body} <- attach_link(body, payload) do
      deliver(config[:smtp_url], address, body)
    end
  end

  defp lookup_address(user_id) do
    url = "#{Application.fetch_env!(:of_events, :identity)[:jwks_url] |> String.replace("/.well-known/jwks.json", "")}/v1/users/#{user_id}"

    case Finch.build(:get, url) |> Finch.request(OrbitalFreight.Events.Finch, receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} ->
        %{"email" => email} = Jason.decode!(body)
        {:ok, email}

      {:ok, %{status: 404}} ->
        # Пользователь удалён из тенанта после того, как событие было записано.
        # Повторять нечего — это постоянная ошибка.
        {:error, :no_recipient}

      other ->
        {:error, other}
    end
  end

  defp render(template_code, recipient, payload) do
    dir = Application.fetch_env!(:of_events, :delivery)[:template_dir]
    path = Path.join([dir, recipient.channel || "email", template_code <> ".eex"])

    if File.exists?(path) do
      {:ok, EEx.eval_file(path, assigns: Map.to_list(payload))}
    else
      {:error, {:unknown_template, template_code}}
    end
  end

  defp attach_link(body, %{"attachment_document_id" => nil}), do: {:ok, body}
  defp attach_link(body, payload) when not is_map_key(payload, "attachment_document_id"), do: {:ok, body}

  defp attach_link(body, %{"attachment_document_id" => document_id}) do
    base = Application.fetch_env!(:of_events, :document_service)[:base_url]
    url = "#{base}/v1/documents/#{document_id}/signed-url"

    case Finch.build(:post, url, [{"content-type", "application/json"}], "{}")
         |> Finch.request(OrbitalFreight.Events.Finch, receive_timeout: 3_000) do
      {:ok, %{status: 201, body: response}} ->
        %{"url" => signed} = Jason.decode!(response)
        {:ok, body <> "\n\n" <> signed}

      {:ok, %{status: status}} ->
        # Письмо без ссылки лучше, чем письмо, не отправленное вовсе: сам факт
        # выпуска декларации или счёта важнее вложения.
        Logger.warning("document-service returned #{status} for #{document_id}, sending without attachment")
        {:ok, body}

      {:error, reason} ->
        Logger.warning("document-service unreachable: #{inspect(reason)}")
        {:ok, body}
    end
  end

  defp deliver(smtp_url, address, body) do
    :gen_smtp_client.send_blocking({smtp_url, [address], body}, relay: smtp_url, tls: :always)
    :ok
  catch
    :error, reason -> {:error, reason}
  end
end

defmodule OrbitalFreight.Events.Delivery.Sms do
  @moduledoc """
  SMS. Канал дорогой и односторонний, поэтому текст всегда одноразмерный: одно
  предложение и идентификатор, по которому получатель найдёт подробности в
  консоли. Длинные шаблоны бьются оператором на несколько сообщений и
  тарифицируются каждое отдельно — счёт за такую рассылку однажды заметили
  раньше, чем саму ошибку.
  """

  @behaviour OrbitalFreight.Events.Delivery.Channel

  @max_length 160

  @impl true
  def send(recipient, template_code, payload) do
    token = Application.fetch_env!(:of_events, :delivery)[:sms_provider_token]

    text =
      payload
      |> summarise(template_code)
      |> String.slice(0, @max_length)

    body = Jason.encode!(%{"to_user_id" => recipient.user_id, "text" => text})

    case Finch.build(:post, "https://sms-gateway.internal/v1/messages", headers(token), body)
         |> Finch.request(OrbitalFreight.Events.Finch, receive_timeout: 4_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:sms_gateway, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp headers(token), do: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}]

  # Суммы в SMS не показываются вообще: минорные единицы без валюты вводят в
  # заблуждение, а с валютой не помещаются вместе с идентификатором (§0.2).
  defp summarise(payload, template_code) do
    subject = payload["shipment_id"] || payload["invoice_id"] || payload["container_id"] || ""
    "ORBITALFREIGHT: #{template_code} #{subject}"
  end
end

defmodule OrbitalFreight.Events.Delivery.Push do
  @moduledoc """
  Мобильный push: APNs для driver-ios и FCM для inspector-android. Ключи лежат
  по `OF_NOTIFY_PUSH_APNS_KEY_PATH` и `OF_NOTIFY_PUSH_FCM_KEY_PATH`.

  Платформа выбирается по устройству, зарегистрированному за пользователем, а не
  по типу события: водитель бывает и инспектором, а `fleet.assignment.created`
  адресован именно человеку, а не приложению.
  """

  @behaviour OrbitalFreight.Events.Delivery.Channel

  @impl true
  def send(recipient, template_code, payload) do
    case device_tokens(recipient.user_id) do
      [] ->
        # Push включён в настройках, но приложение не установлено. Постоянная
        # ошибка: повторять восемь раз бессмысленно.
        {:error, :no_recipient}

      tokens ->
        results = Enum.map(tokens, fn {platform, token} -> push(platform, token, template_code, payload) end)
        if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, {:push_partial, results}}
    end
  end

  defp device_tokens(user_id) do
    sql = """
    SELECT payload->>'platform' AS platform, payload->>'device_token' AS device_token
      FROM platform.notifications
     WHERE recipient_user_id = $1 AND channel = 'push' AND state = 'sent'
     ORDER BY sent_at DESC
     LIMIT 4
    """

    case OrbitalFreight.Events.Repo.query(sql, [user_id]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [platform, token] -> {platform, token} end)
      _ -> []
    end
  end

  defp push("ios", token, template_code, payload) do
    key_path = Application.fetch_env!(:of_events, :delivery)[:apns_key_path]
    transmit("https://api.push.apple.com/3/device/#{token}", key_path, template_code, payload)
  end

  defp push("android", token, template_code, payload) do
    key_path = Application.fetch_env!(:of_events, :delivery)[:fcm_key_path]
    transmit("https://fcm.googleapis.com/v1/projects/orbitalfreight/messages:send", key_path, template_code, Map.put(payload, "token", token))
  end

  defp push(other, _token, _template_code, _payload), do: {:error, {:unknown_platform, other}}

  defp transmit(url, key_path, template_code, payload) do
    body = Jason.encode!(%{"template_code" => template_code, "data" => payload})

    case Finch.build(:post, url, [{"content-type", "application/json"}, {"x-key-path", key_path}], body)
         |> Finch.request(OrbitalFreight.Events.Finch, receive_timeout: 3_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 410}} -> {:error, :no_recipient}
      {:ok, %{status: status}} -> {:error, {:push_gateway, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
