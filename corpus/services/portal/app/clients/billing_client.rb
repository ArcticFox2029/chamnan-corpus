# frozen_string_literal: true
#
# Client HTTP vers billing-service pour les écrans de facturation de l'exploitation : consultation
# d'une facture, encaissement manuel, mise au rebut par avoir. Le portail n'invente jamais de
# montant — il n'assemble que ce que billing.invoices contient déjà, et laisse le service seul
# maître de la cohérence subtotal + duty + tax = total.

require_relative 'base_client'
require_relative '../../lib/portal/money'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class BillingClient < BaseClient
      def self.service_name
        'billing-service'
      end

      # Valeurs du CHECK sur billing.invoices.status (§2). `on_hold` n'est jamais posé depuis le
      # portail : c'est billing-service qui le pose en consommant `reconciliation.discrepancy.opened`
      # (§4.17), avec hold_reason repris du champ `kind` de l'événement.
      TERMINAL_STATUSES = %w[settled void written_off].freeze

      # Codes de charge autorisés sur billing.invoice_lines. Le portail n'en propose qu'un
      # sous-ensemble : `duty_disbursement` est réservé au flux automatique alimenté par
      # `customs.declaration.cleared`, l'ajouter à la main dupliquerait la ligne de droits.
      MANUAL_CHARGE_CODES = %w[
        demurrage detention waiting_time hazmat_handling reefer_power
      ].freeze

      def invoice(invoice_id)
        PrefixedUlid.assert!(invoice_id, :invoice)
        get("/v1/invoices/#{invoice_id}")
      end

      def tenant_invoices(status: nil, due_before: nil, limit: 50)
        paginate(
          "/v1/tenants/#{@context.tenant_id}/invoices",
          { status: status, due_before: due_before },
          max_items: limit
        )
      end

      # Ajout d'une ligne d'accessorial saisie par un exploitant. Le montant est recalculé ici
      # uniquement pour l'afficher avant envoi ; c'est la valeur envoyée qui fait foi, et
      # billing-service la revalide contre sa propre arithmétique en unités mineures (§0.2).
      def append_line(invoice_id, charge_code:, description:, quantity:, unit_price_minor:, source: nil)
        PrefixedUlid.assert!(invoice_id, :invoice)
        unless MANUAL_CHARGE_CODES.include?(charge_code)
          raise ArgumentError, "code de charge non saisissable depuis le portail : #{charge_code}"
        end

        amount_minor = (unit_price_minor * quantity).round

        post(
          "/v1/invoices/#{invoice_id}/lines",
          {
            charge_code: charge_code,
            description: description,
            quantity: quantity,
            unit_price_minor: unit_price_minor,
            amount_minor: amount_minor,
            source_kind: source ? source[:kind] : 'manual',
            source_id: source ? source[:id] : nil
          },
          idempotency_key: "portal-line-#{invoice_id}-#{charge_code}-#{amount_minor}"
        )
      end

      # Émission. C'est l'appel qui attribue invoice_number et publie `billing.invoice.issued`
      # (§4.14), lu ensuite par notification-service, partner-portal-api, reconciliation-service,
      # analytics-pipeline et audit-ledger. Un double-clic ici est donc visible par cinq services,
      # d'où la clé d'idempotence stable plutôt qu'un UUID par requête.
      def issue(invoice_id)
        PrefixedUlid.assert!(invoice_id, :invoice)
        post("/v1/invoices/#{invoice_id}/issue", {}, idempotency_key: "portal-issue-#{invoice_id}")
      end

      # Encaissement saisi à la main : virement SWIFT arrivé hors du fichier bancaire, ou avoir.
      # La contrainte UNIQUE (method, external_ref) sur billing.payments protège contre le
      # double import ; la clé d'idempotence protège contre le double clic, ce n'est pas la
      # même défense et les deux sont nécessaires.
      def record_payment(invoice_id, method:, amount_minor:, currency:, received_at:, external_ref: nil)
        PrefixedUlid.assert!(invoice_id, :invoice)
        raise ArgumentError, 'montant nul ou négatif' unless amount_minor.is_a?(Integer) && amount_minor.positive?

        post(
          "/v1/invoices/#{invoice_id}/payments",
          {
            method: method,
            amount_minor: amount_minor,
            currency: currency,
            received_at: received_at,
            external_ref: external_ref
          },
          idempotency_key: "portal-payment-#{invoice_id}-#{method}-#{external_ref || amount_minor}"
        )
      end

      # Annulation. billing-service exige un avoir déjà déposé chez document-service : le portail
      # vérifie la présence de l'identifiant avant l'appel pour éviter un aller-retour perdu, mais
      # c'est bien le service qui refuse en dernier ressort.
      def void(invoice_id, credit_note_document_id:, reason:)
        PrefixedUlid.assert!(invoice_id, :invoice)
        PrefixedUlid.assert!(credit_note_document_id, :document)

        post(
          "/v1/invoices/#{invoice_id}/void",
          { credit_note_document_id: credit_note_document_id, reason: reason },
          idempotency_key: "portal-void-#{invoice_id}"
        )
      end

      # Solde restant dû, calculé côté portail pour l'affichage. billing-service ne publie pas de
      # champ « reste à payer » : le passage à `settled` se fait quand le cumul des paiements
      # atteint total_minor, et c'est cette même somme qu'on reproduit ici.
      def outstanding_minor(invoice)
        return 0 if TERMINAL_STATUSES.include?(invoice['status'])

        paid = Array(invoice['payments'])
               .reject { |payment| payment['reversed_at'] }
               .sum { |payment| payment.fetch('amount_minor', 0) }

        [invoice.fetch('total_minor') - paid, 0].max
      end

      def hold_banner(invoice)
        return nil unless invoice['status'] == 'on_hold'

        # hold_reason reprend le `kind` de analytics.reconciliation_discrepancies. Le libellé est
        # traduit ici et nulle part ailleurs : la valeur sur le fil reste anglaise.
        labels = {
          'missing_declaration' => 'déclaration douanière absente',
          'missing_invoice' => 'facture absente du rapprochement',
          'duty_mismatch' => 'écart de droits de douane',
          'weight_mismatch' => 'écart de poids',
          'orphan_payment' => 'paiement orphelin',
          'unbilled_accessorial' => 'accessorial non facturé',
          'cleared_without_payment' => 'dédouanée sans paiement'
        }
        labels.fetch(invoice['hold_reason'], invoice['hold_reason'])
      end
    end
  end
end
