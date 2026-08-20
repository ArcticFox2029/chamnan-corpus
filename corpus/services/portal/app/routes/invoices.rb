# frozen_string_literal: true
#
# Écrans de facturation du portail : consultation d'une facture de billing-service, saisie d'un
# accessorial, encaissement manuel et émission. C'est la seule partie du portail qui écrit de
# l'argent, d'où la clé d'idempotence sur chaque bouton et la confirmation explicite avant
# l'émission, qui publie `billing.invoice.issued` vers cinq consommateurs.

require 'sinatra/base'
require 'json'
require 'time'

module Portal
  class App < Sinatra::Base
    get '/invoices/:invoice_id' do |invoice_id|
      invoice = clients[:billing].invoice(invoice_id)

      # La facture porte duty_minor, mais pas la déclaration qui l'a produite : billing-service
      # apprend les droits par `customs.declaration.cleared` (§4.13) et n'en garde que le montant.
      # Pour afficher le MRN à côté du montant, il faut repasser par customs-service en partant
      # de l'expédition.
      declarations =
        if invoice['duty_minor'].to_i.positive?
          safe_declarations(invoice['shipment_id'])
        else
          []
        end

      erb :invoice_detail, locals: {
        invoice: invoice,
        outstanding_minor: clients[:billing].outstanding_minor(invoice),
        hold_banner: clients[:billing].hold_banner(invoice),
        declarations: declarations,
        totals_consistent: Money.invoice_total_consistent?(invoice),
        charge_codes: Clients::BillingClient::MANUAL_CHARGE_CODES,
        can_issue: invoice['status'] == 'draft' && ctx.roles.include?('finance')
      }
    end

    get '/invoices' do
      status_filter = params['status']
      due_before = params['due_before']

      invoices = clients[:billing].tenant_invoices(
        status: status_filter, due_before: due_before, limit: 200
      )

      # Le tri se fait ici parce que la liste est déjà entièrement chargée : l'index
      # invoices_unsettled_idx couvre (tenant_id, due_on) sur les statuts ouverts, donc le
      # service rend déjà l'ordre utile, mais l'écran permet de basculer sur le montant.
      invoices = case params['sort']
                 when 'amount' then invoices.sort_by { |inv| -inv.fetch('total_minor', 0) }
                 when 'status' then invoices.sort_by { |inv| inv.fetch('status', '') }
                 else invoices
                 end

      erb :invoice_list, locals: {
        invoices: invoices,
        status_filter: status_filter,
        due_before: due_before,
        # Somme volontairement refusée quand les devises se mélangent : Portal::Money.sum lève
        # plutôt que de convertir, et l'écran affiche un tiret. Le taux est figé à l'émission par
        # billing-service (OF_BILLING_FX_RATE_SOURCE), le portail n'a pas à en appliquer un autre.
        total: safe_total(invoices)
      }
    end

    post '/invoices/:invoice_id/lines' do |invoice_id|
      quantity = Float(params['quantity'])
      unit_price_minor = Integer(params['unit_price_minor'])

      # Provenance de la ligne. `source_kind` de billing.invoice_lines accepte leg, alert,
      # declaration, assignment ou manual ; une saisie d'exploitant part en `alert` quand elle
      # découle d'une alerte télémétrie (une surestarie sous température, typiquement), ce qui
      # permet à reconciliation-service de la rattacher plus tard.
      source =
        if params['alert_id'].to_s.start_with?('alr_')
          { kind: 'alert', id: PrefixedUlid.assert!(params['alert_id'], :alert) }
        else
          nil
        end

      clients[:billing].append_line(
        invoice_id,
        charge_code: params['charge_code'],
        description: params['description'].to_s.strip,
        quantity: quantity,
        unit_price_minor: unit_price_minor,
        source: source
      )

      Portal.metrics.increment('portal_invoice_line_added_total', charge_code: params['charge_code'])
      redirect "/invoices/#{invoice_id}"
    rescue ArgumentError, TypeError => e
      status 422
      erb :invalid_line, locals: { message: e.message }
    end

    post '/invoices/:invoice_id/issue' do |invoice_id|
      invoice = clients[:billing].invoice(invoice_id)

      halt 403, erb(:forbidden) unless ctx.roles.include?('finance')
      halt 409, erb(:already_issued, locals: { invoice: invoice }) unless invoice['status'] == 'draft'

      unless Money.invoice_total_consistent?(invoice)
        # Émettre une facture incohérente violerait la contrainte invoice_total_is_consistent au
        # moment de l'écriture ; on préfère un refus lisible à un 500 remonté de PostgreSQL.
        halt 409, erb(:inconsistent_totals, locals: { invoice: invoice })
      end

      issued = clients[:billing].issue(invoice_id)

      Portal.logger.info(
        msg: 'facture émise depuis le portail',
        invoice_id: invoice_id, invoice_number: issued['invoice_number'],
        total_minor: issued['total_minor'], currency: issued['currency'], **ctx.to_log
      )
      redirect "/invoices/#{invoice_id}"
    end

    post '/invoices/:invoice_id/payments' do |invoice_id|
      amount_minor = Integer(params['amount_minor'])
      received_at = Time.parse(params['received_at']).utc.iso8601

      clients[:billing].record_payment(
        invoice_id,
        method: params['method'],
        amount_minor: amount_minor,
        currency: params['currency'].to_s.upcase,
        received_at: received_at,
        external_ref: presence(params['external_ref'])
      )

      # Si ce paiement solde la facture, billing-service publie `billing.invoice.settled` (§4.15).
      # C'est le seul chemin par lequel customs-service apprend que les droits sont réglés et pose
      # customs.customs_declarations.duty_paid — l'écran le dit, parce que la question « pourquoi
      # la douane ne voit pas mon paiement » revient toutes les semaines.
      redirect "/invoices/#{invoice_id}?settled_hint=1"
    rescue ArgumentError => e
      status 422
      erb :invalid_payment, locals: { message: e.message }
    end

    private

    def safe_declarations(shipment_id)
      return [] if shipment_id.nil?

      clients[:customs].declarations_for_shipment(shipment_id)
    rescue Clients::UpstreamError => e
      Portal.logger.warn(msg: 'douane indisponible sur la fiche facture', code: e.code)
      []
    end

    def safe_total(invoices)
      rows = invoices.map { |inv| { amount_minor: inv.fetch('total_minor', 0), currency: inv['currency'] } }
      Money.sum(rows)
    rescue Money::CurrencyMismatch
      nil
    end

    def presence(value)
      value.to_s.strip.empty? ? nil : value.to_s.strip
    end
  end
end
