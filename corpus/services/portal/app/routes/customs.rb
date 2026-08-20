# frozen_string_literal: true
#
# Écran douane du portail : suivi d'une déclaration de customs-service, contrôle ligne à ligne de
# l'assiette contre customs.tariff_schedules, et explication de l'état de règlement. Tout y est en
# lecture — le dépôt et l'amendement d'une déclaration passent par customs-service directement, ou
# par partner-portal-api pour un courtier externe, jamais par cet écran.

require 'sinatra/base'
require 'json'
require 'time'

module Portal
  class App < Sinatra::Base
    get '/declarations/:declaration_id' do |declaration_id|
      declaration = clients[:customs].declaration(declaration_id)
      summary = clients[:customs].summarise(declaration)

      erb :declaration_detail, locals: {
        declaration: declaration,
        summary: summary,
        payment_state: clients[:customs].payment_state_label(declaration),
        # Une déclaration retenue bloque l'expédition en `held_at_customs` côté
        # container-registry, qui l'apprend par `customs.declaration.filed` puis par
        # `customs.declaration.cleared` (§4.12 et §4.13). L'écran affiche les deux faces pour
        # éviter la question « la douane dit dédouané, pourquoi mon fret est bloqué » : la
        # réponse est presque toujours qu'un consommateur a du retard.
        shipment: safe_shipment(declaration['shipment_id']),
        invoices: invoices_for_shipment(declaration['shipment_id'])
      }
    end

    # Contrôle d'assiette d'une ligne. On rejoue le calcul de customs-service à partir de la ligne
    # tarifaire en vigueur à la date de dépôt, pas à celle du jour : les périodes de
    # customs.tariff_schedules ne se recouvrent pas, et une déclaration déposée avant un décret
    # doit rester assise à l'ancien taux.
    get '/declarations/:declaration_id/lines/:line_id/check' do |declaration_id, line_id|
      PrefixedUlid.assert!(declaration_id, :declaration)

      declaration = clients[:customs].declaration(declaration_id)
      line = Array(declaration['lines']).find { |row| row['line_id'] == line_id }
      halt 404, erb(:not_found) if line.nil?

      # filed_at plutôt que created_at : c'est le dépôt qui fixe le taux, pas la saisie du
      # brouillon, qui peut traîner plusieurs jours chez le courtier.
      on_date = (declaration['filed_at'] || declaration['created_at']).to_s[0, 10]

      tariff = clients[:customs].tariff_lookup(
        hs_code: line.fetch('hs_code'),
        destination_country: destination_country_for(declaration),
        origin_country: line.fetch('origin_country'),
        on_date: on_date
      )

      comparison = clients[:customs].recompute_line_duty(line, tariff)

      erb :tariff_check, locals: {
        declaration: declaration,
        line: line,
        tariff: tariff,
        comparison: comparison,
        duty_rate_label: Money.format_basis_points(tariff.fetch('duty_rate_bp')),
        vat_rate_label: Money.format_basis_points(tariff.fetch('vat_rate_bp')),
        on_date: on_date
      }
    end

    private

    # La direction porte la géographie : sur un import, le pays de destination est celui du
    # bureau de dédouanement ; sur un export, il est chez le destinataire. customs-service ne
    # renvoie pas ce champ tout mâché, il faut le déduire, et se tromper ici donne un taux
    # plausible mais faux — le pire cas possible sur cet écran.
    def destination_country_for(declaration)
      case declaration['direction']
      when 'import'  then declaration.fetch('customs_office_code')[0, 2]
      when 'export'  then declaration.fetch('destination_country')
      else                declaration.fetch('destination_country', declaration.fetch('customs_office_code')[0, 2])
      end
    end

    def safe_shipment(shipment_id)
      return nil if shipment_id.nil?

      clients[:freight].shipment(shipment_id)
    rescue Clients::UpstreamError => e
      Portal.logger.warn(msg: 'expédition injoignable depuis l\'écran douane',
                         shipment_id: shipment_id, code: e.code)
      nil
    end

    # Les droits assis ne deviennent une ligne de facture qu'une fois la déclaration dédouanée :
    # billing-service pose duty_minor en consommant `customs.declaration.cleared`, et rien avant.
    # Une déclaration `under_review` sans facture correspondante est donc parfaitement normale.
    def invoices_for_shipment(shipment_id)
      return [] if shipment_id.nil?

      clients[:billing]
        .tenant_invoices(limit: 200)
        .select { |invoice| invoice['shipment_id'] == shipment_id }
    rescue Clients::UpstreamError
      []
    end
  end
end
