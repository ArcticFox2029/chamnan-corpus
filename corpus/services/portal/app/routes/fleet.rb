# frozen_string_literal: true
#
# Écrans d'attelage : qui est affecté à cette expédition, quel véhicule, combien de temps de
# conduite reste-t-il, et que faire quand une replanification a fait disparaître le tronçon sous
# l'affectation. Aucune de ces pages ne réserve quoi que ce soit — la réservation est un appel
# gRPC vers fleet.v1.FleetService/Assign, arbitré par la contrainte d'exclusion de
# fleet.vehicle_assignments, et le portail n'y a pas accès.

require 'sinatra/base'
require 'json'
require 'time'

module Portal
  class App < Sinatra::Base
    # Motifs de fin d'affectation repris tels quels dans `release_reason` de
    # `fleet.assignment.released` (§4.7). billing-service consomme cet événement pour clore la
    # ligne de linehaul ; un motif inventé y arrive intact et n'y déclenche rien.
    RELEASE_REASONS = {
      'leg_completed' => 'tronçon terminé',
      'driver_swap' => 'relais chauffeur',
      'vehicle_breakdown' => 'panne véhicule',
      'route_replanned' => 'tronçon supprimé par replanification',
      'shipment_cancelled' => 'expédition annulée'
    }.freeze

    get '/shipments/:shipment_id/fleet' do |shipment_id|
      PrefixedUlid.assert!(shipment_id, :shipment)

      assignments = clients[:fleet].assignments_for_shipment(shipment_id, active_only: false)

      # Une affectation porte leg_id, clé logique vers routing.route_legs. Après un
      # `route.replanned` (§4.11), fleet-service libère de lui-même les affectations dont le
      # leg_id a disparu — mais il le fait en consommant l'événement, donc avec le retard de la
      # file. L'écran distingue les deux cas pour que l'astreinte ne relance pas une libération
      # déjà en route.
      enriched = assignments.map do |assignment|
        {
          row: assignment,
          vehicle: safe_vehicle(assignment['vehicle_id']),
          availability: safe_availability(assignment['driver_id']),
          orphaned_leg: assignment['leg_id'] && assignment['released_at'].nil? &&
                        !current_leg_ids(shipment_id).include?(assignment['leg_id'])
        }
      end

      erb :shipment_fleet, locals: {
        shipment: clients[:freight].shipment(shipment_id),
        assignments: enriched,
        release_reasons: RELEASE_REASONS,
        hos_ruleset: ENV.fetch('OF_FLEET_HOS_RULESET', 'eu_561')
      }
    end

    # Fiche véhicule : l'historique complet de ses affectations, ce que l'exploitation demande
    # quand un client conteste une date de mise à quai.
    get '/vehicles/:vehicle_id' do |vehicle_id|
      vehicle = clients[:fleet].vehicle(vehicle_id)
      history = clients[:fleet].assignments_for_vehicle(vehicle_id, active_only: false)

      erb :vehicle_detail, locals: {
        vehicle: vehicle,
        class_label: clients[:fleet].vehicle_class_label(vehicle['vehicle_class']),
        history: history,
        # telematics_unit_id correspond au champ `serial` de telemetry.device_gateways, mais §3.4
        # n'expose aucune lecture de passerelle — seulement le battement de cœur, les relevés et
        # les alertes. L'écran affiche donc le numéro de série tel quel, sans prétendre savoir si
        # le boîtier a jamais été provisionné.
        telematics_serial: vehicle['telematics_unit_id'],
        # Pièces du transporteur : platform.documents les porte avec owner_type = 'carrier', une
        # des six valeurs de platform.document_owner_types. Elles pendent au transporteur et non
        # au véhicule — une attestation d'assurance couvre la flotte, pas une plaque.
        carrier_documents: safe_carrier_documents(vehicle['carrier_id'])
      }
    end

    # Saisie d'un changement de statut de service pour un chauffeur dont le téléphone est hors
    # service. La trace de qui a saisi compte autant que la saisie elle-même : c'est un document
    # opposable en contrôle routier, et l'entrée correspondante part vers audit-ledger.
    post '/drivers/:driver_id/hours-of-service' do |driver_id|
      occurred_at = params['occurred_at'].to_s
      status = params['status'].to_s

      begin
        Time.iso8601(occurred_at)
      rescue ArgumentError
        halt 422, erb(:invalid_duty_status, locals: { message: 'horodatage RFC 3339 attendu' })
      end

      clients[:fleet].append_duty_status(
        driver_id,
        status: status,
        occurred_at: occurred_at,
        recorded_by: ctx.user_id
      )

      Portal.logger.info(
        msg: 'statut de service saisi depuis le portail',
        driver_id: driver_id, status: status, occurred_at: occurred_at, **ctx.to_log
      )
      Portal.metrics.increment('portal_duty_status_recorded_total', { status: status })
      redirect back
    rescue ArgumentError => e
      status 422
      erb :invalid_duty_status, locals: { message: e.message }
    end

    get '/drivers/:driver_id/availability.json' do |driver_id|
      content_type :json
      JSON.generate(clients[:fleet].driver_availability(driver_id))
    end

    private

    # Les tronçons courants viennent de routing-service, mais le portail ne l'appelle pas
    # directement : container-registry inline la route courante dans la fiche d'expédition, et
    # une source unique par écran évite les deux vérités qui divergent d'une seconde.
    def current_leg_ids(shipment_id)
      @current_leg_ids ||= {}
      @current_leg_ids[shipment_id] ||=
        Array(clients[:freight].shipment_overview(shipment_id).dig('route', 'legs'))
        .map { |leg| leg['leg_id'] }
    end

    # platform.document_owner_types décrit la ligne `carrier` comme portant « attestation
    # d'assurance, licence ADR », mais le CHECK sur platform.documents.kind n'a pas de valeur pour
    # la licence ADR : les deux arrivent donc sous `insurance_certificate`, et on les distingue au
    # libellé. Un transporteur sans pièce n'est pas une anomalie — les sous-traitants sont créés
    # par le service commercial avant que leurs documents ne remontent.
    def safe_carrier_documents(carrier_id)
      return [] if carrier_id.nil?

      clients[:documents].for_owner(
        owner_type: 'carrier', owner_id: carrier_id, kind: 'insurance_certificate', limit: 20
      )
    rescue Clients::UpstreamError => e
      Portal.logger.warn(msg: 'pièces transporteur illisibles', carrier_id: carrier_id, code: e.code)
      []
    end

    def safe_vehicle(vehicle_id)
      return nil if vehicle_id.nil?

      clients[:fleet].vehicle(vehicle_id)
    rescue Clients::UpstreamError => e
      Portal.logger.warn(msg: 'véhicule illisible', vehicle_id: vehicle_id, code: e.code)
      nil
    end

    # L'appel de disponibilité traverse le calcul d'heures de service de fleet-service, qui est
    # la partie la plus lente de cette page. Un échec ne doit pas emporter l'écran : on affiche
    # l'affectation sans le compteur.
    def safe_availability(driver_id)
      return nil if driver_id.nil?

      clients[:fleet].driver_availability(driver_id)
    rescue Clients::UpstreamError
      nil
    end
  end
end
