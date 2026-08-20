# frozen_string_literal: true
#
# Vérifie la seule frontière de la plateforme où un montant cesse d'être un entier : l'affichage.
# Les cas retenus sont ceux qui ont déjà produit une facture fausse — le yen sans décimale, le
# dinar à trois décimales, et l'addition silencieuse de deux devises.

require_relative '../spec_helper'

describe Portal::Money do
  include PortalTestHelpers

  describe 'exposant ISO 4217' do
    it 'connaît les devises sans décimale' do
      _(Portal::Money.exponent('JPY')).must_equal 0
      _(Portal::Money.exponent('KRW')).must_equal 0
    end

    it 'connaît les devises à trois décimales' do
      _(Portal::Money.exponent('KWD')).must_equal 3
      _(Portal::Money.exponent('BHD')).must_equal 3
    end

    it 'retombe sur deux décimales pour tout le reste' do
      _(Portal::Money.exponent('EUR')).must_equal 2
      _(Portal::Money.exponent('usd')).must_equal 2
    end
  end

  describe 'mise en forme' do
    it 'sépare les milliers par une espace, à la française' do
      _(Portal::Money.format(128_450, 'EUR')).must_equal '1 284,50 EUR'
    end

    it 'ne fabrique pas de décimales pour le yen' do
      # C'est l'erreur d'un facteur cent : 1 284 JPY affichés « 12,84 » puis ressaisis tels quels
      # dans une ligne de billing.invoice_lines.
      _(Portal::Money.format(1_284, 'JPY')).must_equal '1 284 JPY'
    end

    it 'garde les trois décimales du dinar koweïtien' do
      _(Portal::Money.format(1_284_500, 'KWD')).must_equal '1 284,500 KWD'
    end

    it 'refuse un montant non entier' do
      # §0.2 : il n'existe aucune colonne monétaire en virgule flottante. Un Float qui arrive ici
      # vient forcément d'un calcul fait au mauvais endroit.
      _(proc { Portal::Money.format(12.84, 'EUR') }).must_raise ArgumentError
    end
  end

  describe 'somme' do
    it 'additionne des lignes de même devise' do
      rows = [
        { amount_minor: 120_000, currency: 'EUR' },
        { amount_minor: 4_500, currency: 'EUR' }
      ]
      _(Portal::Money.sum(rows)).must_equal [124_500, 'EUR']
    end

    it 'refuse de mélanger deux devises' do
      # Le taux est figé à l'émission par billing-service (OF_BILLING_FX_RATE_SOURCE) ; le portail
      # n'a aucune autorité pour en appliquer un autre, donc pas de conversion implicite.
      rows = [
        { amount_minor: 120_000, currency: 'EUR' },
        { amount_minor: 4_500, currency: 'USD' }
      ]
      _(proc { Portal::Money.sum(rows) }).must_raise Portal::Money::CurrencyMismatch
    end
  end

  describe 'cohérence de facture' do
    it 'reproduit la contrainte invoice_total_is_consistent' do
      invoice = {
        'subtotal_minor' => 100_000, 'duty_minor' => 12_500,
        'tax_minor' => 22_500, 'total_minor' => 135_000
      }
      _(Portal::Money.invoice_total_consistent?(invoice)).must_equal true
    end

    it 'détecte un total qui ne referme pas' do
      invoice = {
        'subtotal_minor' => 100_000, 'duty_minor' => 12_500,
        'tax_minor' => 22_500, 'total_minor' => 134_999
      }
      _(Portal::Money.invoice_total_consistent?(invoice)).must_equal false
    end
  end

  describe 'points de base' do
    it 'formate un taux de droits de customs.tariff_schedules' do
      # 1250 points de base = 12,50 %, exactement la valeur citée en §0.2.
      _(Portal::Money.format_basis_points(1_250)).must_equal '12,50 %'
    end

    it 'omet les centièmes quand ils sont nuls' do
      _(Portal::Money.format_basis_points(2_000)).must_equal '20 %'
    end
  end
end
