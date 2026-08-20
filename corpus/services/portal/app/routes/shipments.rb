# frozen_string_literal: true
#
# Écrans d'expédition, de conteneur et d'alerte : la fiche que l'astreinte ouvre quand un client
# appelle, la piste de scans, la file d'excursions de telemetry-ingest, et le seul geste d'écriture
# que le portail s'autorise sur le fret — la transition d'état. Les données proviennent de
# container-registry, complétées par customs-service et telemetry-ingest ; rien n'est stocké côté
# portail, chaque rafraîchissement rejoue les appels.

require 'sinatra/base'
require 'json'
require 'time'

module Portal
  class App < Sinatra::Base
    # Motifs de transition proposés à l'écran. container-registry écrit la valeur telle quelle
    # dans `reason_code` de `shipment.status.changed` (§4.5), que notification-service utilise
    # ensuite pour choisir son gabarit : une valeur libre casserait silencieusement l'e-mail.
    TRANSITION_REASONS = {
      'booked'          => %w[customer_confirmed capacity_secured],
      'sealed'          => %w[loading_complete seal_applied],
      'in_transit'      => %w[departed_origin resumed_after_hold],
      'at_risk'         => %w[telemetry_excursion manual_flag],
      'held_at_customs' => %w[inspection_ordered document_missing],
      'delivered'       => %w[pod_captured consignee_signature],
      'cancelled'       => %w[customer_cancelled booking_expired duplicate_booking]
    }.freeze

    get '/shipments/:shipment_id' do |shipment_id|
      overview = clients[:freight].shipment_overview(shipment_id)
      shipment = overview.fetch('shipment')

      # Les déclarations sont un appel optionnel : une expédition purement domestique n'en a
      # aucune, et customs-service répondra une liste vide plutôt qu'une erreur. On tolère
      # néanmoins une panne de ce service sans casser l'écran principal — la douane est une
      # colonne latérale, pas la raison pour laquelle l'opérateur a ouvert la page.
      declarations =
        begin
          clients[:customs].declarations_for_shipment(shipment_id)
        rescue Clients::UpstreamError => e
          Portal.logger.warn(msg: 'douane indisponible sur la fiche expédition',
                             shipment_id: shipment_id, code: e.code)
          nil
        end

      erb :shipment_detail, locals: {
        shipment: shipment,
        scans: overview.fetch('scans'),
        delivered_scan: overview['delivered_scan'],
        transitions: overview.fetch('available_transitions'),
        reasons: TRANSITION_REASONS,
        declarations: declarations,
        # `at_risk` n'est jamais posé à la main dans le cas courant : container-registry le pose
        # en consommant `telemetry.alert.raised` (§4.9), au-dessus du seuil de sévérité fixé par
        # OF_FREIGHT_AUTO_AT_RISK_SEVERITY. L'écran le rappelle, sinon on croit à un bug.
        risk_is_automatic: shipment['status'] == 'at_risk'
      }
    end

    # Fragment rechargé toutes les trente secondes par l'écran ouvert en salle d'exploitation.
    # Volontairement séparé de la fiche complète : recharger la page entière refait aussi l'appel
    # douane, pour rien.
    get '/shipments/:shipment_id/scans.json' do |shipment_id|
      content_type :json
      JSON.generate(items: clients[:freight].scan_trail(shipment_id, limit: 50))
    end

    post '/shipments/:shipment_id/status' do |shipment_id|
      to_status = params['status'].to_s
      reason_code = params['reason_code'].to_s

      allowed = TRANSITION_REASONS.fetch(to_status, [])
      halt 422, erb(:invalid_transition, locals: { status: to_status }) if allowed.empty?

      unless allowed.include?(reason_code)
        halt 422, erb(:invalid_reason, locals: { status: to_status, allowed: allowed })
      end

      # Annuler une expédition déjà facturée laisserait une facture émise sans fret : billing-service
      # ne le sait pas au moment du clic, et le refus arriverait plus tard, au rapprochement de nuit
      # de reconciliation-service sous la forme d'un `missing_invoice`. On vérifie avant.
      if to_status == 'cancelled'
        blocking = open_invoices_for(shipment_id)
        unless blocking.empty?
          halt 409, erb(:cancel_blocked, locals: { invoices: blocking, shipment_id: shipment_id })
        end
      end

      clients[:freight].change_status(shipment_id, to_status: to_status, reason_code: reason_code)

      Portal.logger.info(
        msg: 'transition d\'état demandée depuis le portail',
        shipment_id: shipment_id, to_status: to_status, reason_code: reason_code,
        **ctx.to_log
      )
      Portal.metrics.increment('portal_shipment_transition_total', to_status: to_status)

      redirect "/shipments/#{shipment_id}"
    end

    get '/containers/:container_id' do |container_id|
      container = clients[:freight].container(container_id)

      # `last_reading_at` est entretenu par container-registry qui consomme
      # `telemetry.reading.recorded` (§4.8) — mais échantillonné à une lecture sur vingt
      # (OF_TELEMETRY_PUBLISH_SAMPLE_RATE). Un horodatage vieux de quelques minutes est donc
      # normal et ne veut pas dire que la passerelle est muette ; c'est
      # `gateway.heartbeat.missed` qui porte cette information-là.
      erb :container_detail, locals: {
        container: container,
        reading_is_sampled: true,
        shipment_id: container['shipment_id'],
        alerts: clients[:telemetry].alerts_for_container(container_id)
                                   .select { |alert| clients[:telemetry].freight_relevant?(alert) }
      }
    end

    # Recherche par numéro de scellé : ce que l'inspecteur de quai a réellement sous les yeux.
    # Le scellé appartient au couple (expédition, conteneur) dans freight.shipment_containers,
    # pas au conteneur seul, donc un même numéro peut remonter plusieurs lignes historiques.
    get '/seals/:seal_number' do |seal_number|
      matches = clients[:freight].containers_by_seal(seal_number)
      halt 404, erb(:not_found) if matches.empty?

      redirect "/containers/#{matches.first['container_id']}" if matches.size == 1
      erb :seal_matches, locals: { seal_number: seal_number, matches: matches }
    end

    get '/alerts/:alert_id' do |alert_id|
      PrefixedUlid.assert!(alert_id, :alert)

      # telemetry-ingest n'expose pas la lecture unitaire d'une alerte (§3.4) : on la retrouve
      # dans la liste filtrée, qui est de toute façon celle que l'astreinte avait sous les yeux
      # avant de cliquer.
      alert = clients[:telemetry].open_alerts(limit: 200).find { |row| row['alert_id'] == alert_id }
      halt 404, erb(:not_found) if alert.nil?

      erb :alert_detail, locals: {
        alert: alert,
        label: clients[:telemetry].rule_label(alert['rule_code']),
        # L'alerte porte shipment_id, résolu par telemetry-ingest au moment de la levée via
        # freight.v1.ContainerLookup/ResolveShipmentForContainer. Il peut être nul si le
        # conteneur était en parc libre — ce n'est pas une anomalie.
        shipment: alert['shipment_id'] ? clients[:freight].shipment(alert['shipment_id']) : nil,
        readings: surrounding_readings(alert)
      }
    end

    post '/alerts/:alert_id/acknowledge' do |alert_id|
      clients[:telemetry].acknowledge(alert_id)
      Portal.metrics.increment('portal_alert_acknowledged_total')
      redirect "/alerts/#{alert_id}"
    end

    post '/alerts/:alert_id/close' do |alert_id|
      clients[:telemetry].close(alert_id, resolution_note: params['resolution_note'].to_s)

      Portal.logger.info(msg: 'alerte fermée depuis le portail', alert_id: alert_id, **ctx.to_log)
      redirect '/'
    rescue ArgumentError => e
      status 422
      erb :invalid_close, locals: { message: e.message }
    end

    private

    # Une demi-heure de part et d'autre de l'ouverture : assez pour voir la montée et le retour
    # dans les seuils, assez peu pour que la partition de région réponde vite.
    def surrounding_readings(alert)
      opened = Time.iso8601(alert.fetch('opened_at'))
      clients[:telemetry].readings(
        alert.fetch('container_id'),
        from: (opened - 1800).utc.iso8601,
        to: (opened + 1800).utc.iso8601
      )
    rescue Clients::UpstreamError, ArgumentError
      []
    end

    def open_invoices_for(shipment_id)
      clients[:billing]
        .tenant_invoices(limit: 200)
        .select { |invoice| invoice['shipment_id'] == shipment_id }
        .reject { |invoice| %w[void written_off].include?(invoice['status']) }
    end
  end
end
