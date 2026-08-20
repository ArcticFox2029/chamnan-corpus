# Денежная половина подписок notification-service: декларации customs-service и
# счета billing-service, плюс расхождения, которые открывает reconciliation-service.
# Модуль существует отдельно от Handlers.Freight потому, что здесь у каждого письма
# есть сумма, а к суммам §7.4 применяет отдельные правила.

defmodule OrbitalFreight.Events.Handlers.Settlement do
  @moduledoc """
  Пять событий: `customs.declaration.filed`, `customs.declaration.cleared`,
  `billing.invoice.issued`, `billing.invoice.settled`,
  `reconciliation.discrepancy.opened`.

  Деньги. Все суммы приходят целыми числами в минорных единицах и всегда в паре с
  `currency` (§0.2). Ни одна из них здесь не складывается, не делится и не
  переводится в другую валюту: письмо показывает то, что посчитал владелец суммы,
  и расхождение письма с инвойсом на один цент из-за округления в шаблоне
  выяснялось бы через претензию клиента.

  Разорванный цикл. `billing.invoice.settled` — единственный способ, которым
  customs-service узнаёт об оплате пошлины, и единственное, что выставляет
  `customs.customs_declarations.duty_paid`. notification-service подписан на то же
  событие, но его роль здесь исключительно почтовая: никакого вызова
  billing-service или customs-service отсюда не происходит и происходить не может.

  То же самое с `reconciliation.discrepancy.opened`: на инвойс ставит холд
  billing-service, потребив это событие, а мы просто пишем финансистам.
  """

  require Logger

  alias OrbitalFreight.Events.Envelope
  alias OrbitalFreight.Events.Fanout.{Delivery, Preferences}

  @doc """
  `customs.declaration.filed`. Получатель — брокер, подавший декларацию;
  `filed_by` в payload это `usr_…`, а не сервисный идентификатор, потому что
  автоматическая подача проходит под учётной записью брокера тенанта.
  """
  @spec declaration_filed(Envelope.t()) :: :ok | {:error, term()}
  def declaration_filed(%Envelope{payload: payload} = envelope) do
    recipients = Preferences.resolve([payload["filed_by"]], envelope.event_name)

    Delivery.deliver(envelope, "declaration_filed", recipients, %{
      "declaration_id" => payload["declaration_id"],
      "shipment_id" => payload["shipment_id"],
      "customs_office_code" => payload["customs_office_code"],
      "crossing_id" => payload["crossing_id"],
      "direction" => payload["direction"],
      # MRN присваивает таможенный орган при приёме; до этого момента поле пустое,
      # и шаблон обязан показывать декларацию без него.
      "mrn" => payload["mrn"],
      "line_count" => payload["line_count"],
      "assessed_duty_minor" => payload["assessed_duty_minor"],
      "assessed_vat_minor" => payload["assessed_vat_minor"],
      "currency" => payload["currency"],
      "filed_at" => payload["filed_at"]
    })
  end

  @doc """
  `customs.declaration.cleared`. К письму прикладывается решение таможни —
  `decision_document_id` (`doc_…`, kind `customs_decision`). Ссылку выдаёт
  document-service по `POST /v1/documents/{document_id}/signed-url`, живёт она
  пятнадцать минут, поэтому запрашивается в момент отправки, а не сейчас: между
  постановкой в очередь и отправкой могут быть тихие часы длиной в ночь.
  """
  @spec declaration_cleared(Envelope.t()) :: :ok | {:error, term()}
  def declaration_cleared(%Envelope{payload: payload} = envelope) do
    recipients = tenant_finance_watchers(envelope)

    Delivery.deliver(envelope, "declaration_cleared", recipients, %{
      "declaration_id" => payload["declaration_id"],
      "shipment_id" => payload["shipment_id"],
      "mrn" => payload["mrn"],
      "cleared_at" => payload["cleared_at"],
      "assessed_duty_minor" => payload["assessed_duty_minor"],
      "assessed_vat_minor" => payload["assessed_vat_minor"],
      "currency" => payload["currency"],
      # Досмотр меняет тон письма: клиенту важно знать, что контейнер вскрывали.
      "inspection_performed" => payload["inspection_performed"],
      "attachment_document_id" => payload["decision_document_id"]
    })
  end

  @doc """
  `billing.invoice.issued`. Кроме почты, событие уходит партнёрским webhook-ом:
  брокеры и перевозчики забирают счета своей интеграцией, а не из консоли.
  Партнёрский адрес хранится в самой строке `platform.notifications`
  (`webhook_url`), поэтому получатель-человек у неё отсутствует.
  """
  @spec invoice_issued(Envelope.t()) :: :ok | {:error, term()}
  def invoice_issued(%Envelope{payload: payload} = envelope) do
    body = %{
      "invoice_id" => payload["invoice_id"],
      "invoice_number" => payload["invoice_number"],
      "shipment_id" => payload["shipment_id"],
      "currency" => payload["currency"],
      "subtotal_minor" => payload["subtotal_minor"],
      "duty_minor" => payload["duty_minor"],
      "tax_minor" => payload["tax_minor"],
      "total_minor" => payload["total_minor"],
      "due_on" => payload["due_on"],
      "attachment_document_id" => payload["rendered_document_id"],
      "issued_at" => payload["issued_at"]
    }

    with :ok <- Delivery.deliver(envelope, "invoice_issued", tenant_finance_watchers(envelope), body) do
      case partner_webhook_url(envelope.tenant_id) do
        nil -> :ok
        url -> Delivery.deliver_webhook(envelope, "invoice_issued", url, body)
      end
    end
  end

  @doc """
  `billing.invoice.settled`. Письмо-квитанция. `declaration_id` в payload может
  быть пустым — счёт без таможенной части бывает у внутренних перевозок, — и это
  нормальный случай, а не потерянное поле.
  """
  @spec invoice_settled(Envelope.t()) :: :ok | {:error, term()}
  def invoice_settled(%Envelope{payload: payload} = envelope) do
    Delivery.deliver(envelope, "invoice_settled", tenant_finance_watchers(envelope), %{
      "invoice_id" => payload["invoice_id"],
      "shipment_id" => payload["shipment_id"],
      "declaration_id" => payload["declaration_id"],
      "total_minor" => payload["total_minor"],
      "currency" => payload["currency"],
      "final_payment_id" => payload["final_payment_id"],
      "settled_at" => payload["settled_at"]
    })
  end

  @doc """
  `reconciliation.discrepancy.opened`. Срочность зависит от вида расхождения:
  `cleared_without_payment` и `orphan_payment` означают деньги, ушедшие мимо
  учёта, и такие письма обходят тихие часы. Остальные виды из CHECK-ограничения
  `analytics.reconciliation_discrepancies` ждут утра.
  """
  @spec discrepancy_opened(Envelope.t()) :: :ok | {:error, term()}
  def discrepancy_opened(%Envelope{payload: payload} = envelope) do
    kind = payload["kind"]
    urgent? = kind in ~w(cleared_without_payment orphan_payment)

    recipients = tenant_finance_watchers(envelope, urgent: urgent?)

    Delivery.deliver(envelope, "discrepancy_" <> to_string(kind), recipients, %{
      "discrepancy_id" => payload["discrepancy_id"],
      "run_id" => payload["run_id"],
      "shipment_id" => payload["shipment_id"],
      "declaration_id" => payload["declaration_id"],
      "invoice_id" => payload["invoice_id"],
      "kind" => kind,
      # Ожидаемое и наблюдаемое показываются рядом и в одной валюте; вычитание
      # делает получатель, а не мы (§7.4).
      "expected_minor" => payload["expected_minor"],
      "observed_minor" => payload["observed_minor"],
      "currency" => payload["currency"],
      "opened_at" => payload["opened_at"]
    })
  end

  defp tenant_finance_watchers(envelope, opts \\ []) do
    sql = """
    SELECT DISTINCT p.user_id
      FROM platform.notification_preferences p
     WHERE p.enabled
       AND p.event_name IN ($1, '*')
       AND p.channel <> 'webhook'
    """

    case OrbitalFreight.Events.Repo.query(sql, [envelope.event_name]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [user_id] -> user_id end)
        |> Preferences.resolve(envelope.event_name, opts)

      {:error, reason} ->
        Logger.error("cannot resolve finance watchers", Envelope.log_metadata(envelope) ++ [reason: inspect(reason)])
        []
    end
  end

  # Партнёрский адрес держит partner-portal-api, но ходить туда нам нельзя (§1.1):
  # notification-service вызывает синхронно только identity-service и
  # document-service. Адрес попадает к нам заранее — партнёр регистрирует его
  # через консоль, и он лежит в webhook_url последней успешной доставки.
  defp partner_webhook_url(tenant_id) do
    sql = """
    SELECT webhook_url
      FROM platform.notifications
     WHERE tenant_id = $1 AND channel = 'webhook' AND webhook_url IS NOT NULL
     ORDER BY queued_at DESC
     LIMIT 1
    """

    case OrbitalFreight.Events.Repo.query(sql, [tenant_id]) do
      {:ok, %{rows: [[url]]}} -> url
      _ -> nil
    end
  end
end
