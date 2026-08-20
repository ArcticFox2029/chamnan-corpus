# frozen_string_literal: true
#
# Client HTTP vers customs-service, utilisé par l'écran « douane » du portail : suivi d'une
# déclaration, contrôle des lignes, et résolution d'un droit dans customs.tariff_schedules quand
# un exploitant conteste un montant. Rien n'est écrit ici — le portail regarde, il ne dépose pas.

require_relative 'base_client'
require_relative '../../lib/portal/money'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class CustomsClient < BaseClient
      def self.service_name
        'customs-service'
      end

      # CHECK sur customs.customs_declarations.status. `cleared` implique un mrn et un cleared_at
      # non nuls (contrainte declaration_cleared_needs_mrn) : l'écran peut donc afficher le MRN
      # sans le tester quand le statut est `cleared`.
      OPEN_STATUSES = %w[draft submitted under_review held].freeze

      def declaration(declaration_id)
        PrefixedUlid.assert!(declaration_id, :declaration)
        get("/v1/declarations/#{declaration_id}")
      end

      def declarations_for_shipment(shipment_id)
        PrefixedUlid.assert!(shipment_id, :shipment)
        # Une expédition peut porter plusieurs déclarations : import, export et transit sont trois
        # directions distinctes, et une amendment garde le même mrn mais crée une ligne de plus.
        get("/v1/shipments/#{shipment_id}/declarations").fetch('items', [])
      end

      # Résolution d'une ligne tarifaire à une date donnée. `on_date` n'est pas facultatif dans
      # l'usage du portail : sans elle, on lirait le tarif du jour alors que l'exploitant conteste
      # une assiette calculée à la date de dépôt. Les périodes ne se recouvrent jamais, la table
      # porte une contrainte EXCLUDE sur le tstzrange pour cela.
      def tariff_lookup(hs_code:, destination_country:, origin_country:, on_date:)
        get(
          '/v1/tariffs/lookup',
          hs_code: hs_code,
          destination_country: destination_country,
          origin_country: origin_country,
          on_date: on_date
        )
      end

      # Recalcule à l'écran ce que customs-service a assis, pour montrer l'écart plutôt que de
      # l'affirmer. Les taux sont en points de base (§0.2), donc la division est entière et
      # arrondie au plus proche, comme côté service.
      def recompute_line_duty(line, tariff)
        base_minor = line.fetch('customs_value_minor')
        duty_bp = tariff.fetch('duty_rate_bp')
        vat_bp = tariff.fetch('vat_rate_bp')

        duty_minor = (base_minor * duty_bp + 5_000) / 10_000
        # La TVA porte sur la valeur en douane majorée des droits, pas sur la seule valeur : une
        # erreur d'assiette classique, et la raison pour laquelle ce calcul est reproduit ici.
        vat_minor = ((base_minor + duty_minor) * vat_bp + 5_000) / 10_000

        {
          'duty_minor' => duty_minor,
          'vat_minor' => vat_minor,
          'assessed_duty_minor' => line['duty_minor'],
          'matches' => line['duty_minor'].nil? || line['duty_minor'] == duty_minor
        }
      end

      # Le drapeau duty_paid n'est jamais posé depuis une API : il est mis à jour par
      # customs-service en consommant `billing.invoice.settled` (§4.15), qui est le seul chemin
      # existant. Une déclaration dédouanée dont duty_paid reste faux plusieurs heures après le
      # règlement signale un consommateur en retard, pas une donnée manquante — d'où le libellé
      # explicite plutôt qu'un simple « non ».
      def payment_state_label(declaration)
        return 'sans objet' unless declaration['status'] == 'cleared'

        declaration['duty_paid'] ? 'droits réglés' : 'règlement non encore propagé'
      end

      def summarise(declaration)
        lines = Array(declaration['lines'])
        {
          'line_count' => lines.size,
          'total_customs_value_minor' => lines.sum { |line| line.fetch('customs_value_minor', 0) },
          'total_net_weight_kg' => lines.sum { |line| line.fetch('net_weight_kg', 0).to_f }.round(3),
          'currency' => declaration['currency'],
          'open' => OPEN_STATUSES.include?(declaration['status'])
        }
      end
    end
  end
end
