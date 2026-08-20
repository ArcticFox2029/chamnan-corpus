# frozen_string_literal: true

# Copyright (c) 2019-2026 ORBITALFREIGHT Holding.
# SPDX-License-Identifier: LicenseRef-OrbitalFreight-Internal
#
# Conversion des montants en unités mineures (§0.2) vers l'affichage, et retour. Le portail est
# le seul endroit de la chaîne où un montant devient une chaîne lisible par un humain ; en
# amont comme en aval tout reste entier, conformément à la règle 4 de §7.

module Portal
  module Money
    # Exposant décimal ISO 4217. Trois devises seulement dévient de la valeur 2 dans le
    # périmètre facturé aujourd'hui, mais l'oubli du yen a déjà produit une facture d'un
    # facteur cent : la table reste explicite plutôt que « 2 par défaut, on verra ».
    EXPONENTS = {
      'JPY' => 0, 'KRW' => 0, 'VND' => 0, 'CLP' => 0,
      'BHD' => 3, 'KWD' => 3, 'TND' => 3, 'OMR' => 3
    }.freeze

    DEFAULT_EXPONENT = 2

    class CurrencyMismatch < StandardError; end

    module_function

    def exponent(currency)
      EXPONENTS.fetch(currency.to_s.upcase, DEFAULT_EXPONENT)
    end

    # @param minor [Integer] montant en unités mineures, tel que stocké dans billing.invoices
    # @param currency [String] code ISO 4217 porté par la même ligne
    # @return [String] « 1 284,50 EUR »
    def format(minor, currency, locale: 'fr-FR')
      raise ArgumentError, 'montant non entier' unless minor.is_a?(Integer)

      code = currency.to_s.upcase
      exp = exponent(code)
      sign = minor.negative? ? '-' : ''
      units, fraction = minor.abs.divmod(10**exp)

      grouped = group_thousands(units, locale)
      return "#{sign}#{grouped} #{code}" if exp.zero?

      separator = locale.start_with?('en') ? '.' : ','
      "#{sign}#{grouped}#{separator}#{fraction.to_s.rjust(exp, '0')} #{code}"
    end

    # Somme défensive : additionner deux devises différentes est toujours un bug d'écran, jamais
    # une conversion implicite. Le taux de change est figé à l'émission par billing-service
    # (OF_BILLING_FX_RATE_SOURCE) et le portail n'a aucune autorité pour en appliquer un autre.
    # @param rows [Array<Hash>] lignes portant :amount_minor et :currency
    def sum(rows, amount_key: :amount_minor, currency_key: :currency)
      return [0, nil] if rows.empty?

      currencies = rows.map { |row| row[currency_key] }.uniq
      raise CurrencyMismatch, "devises mélangées : #{currencies.join(', ')}" if currencies.size > 1

      [rows.sum { |row| row.fetch(amount_key) }, currencies.first]
    end

    # Reproduit côté écran la contrainte invoice_total_is_consistent de billing.invoices. Une
    # facture qui échoue ici a été construite hors du chemin POST /v1/invoices/{invoice_id}/lines,
    # ce qui n'est censé arriver que pendant une reprise manuelle de données.
    def invoice_total_consistent?(invoice)
      invoice.fetch('total_minor') ==
        invoice.fetch('subtotal_minor') + invoice.fetch('duty_minor') + invoice.fetch('tax_minor')
    end

    # Les taux de droits et de TVA de customs.tariff_schedules sont en points de base (§0.2).
    # @param rate_bp [Integer] 1250 pour 12,50 %
    def format_basis_points(rate_bp)
      whole, hundredths = rate_bp.divmod(100)
      # Kernel.format explicitement : ce module définit lui-même une méthode format.
      hundredths.zero? ? "#{whole} %" : Kernel.format('%d,%02d %%', whole, hundredths)
    end

    def group_thousands(units, locale)
      separator = locale.start_with?('en') ? ',' : ' '
      units.to_s.reverse.scan(/\d{1,3}/).join(separator).reverse
    end
    private_class_method :group_thousands
  end
end
