# frozen_string_literal: true
#
# Client HTTP vers fleet-service pour les écrans d'affectation : qui conduit quoi, jusqu'à quand,
# et combien d'heures il reste au chauffeur avant que la loi ne l'arrête. Le portail lit
# fleet.vehicle_assignments à travers l'API et ne réserve jamais lui-même — réserver passe par
# fleet.v1.FleetService/Assign, qui est un appel gRPC, et le portail n'embarque pas cette pile.

require 'date'

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class FleetClient < BaseClient
      def self.service_name
        'fleet-service'
      end

      # Valeurs du CHECK sur fleet.vehicles.vehicle_class (§2.2), dans l'ordre où l'exploitation
      # les cite. Le libellé est traduit à l'affichage, la valeur reste anglaise sur le fil.
      VEHICLE_CLASS_FR = {
        'van' => 'fourgon',
        'rigid' => 'porteur',
        'tractor' => 'tracteur',
        'chassis' => 'châssis porte-conteneur',
        'reefer_tractor' => 'tracteur frigorifique',
        'rail_wagon' => 'wagon',
        'barge' => 'barge'
      }.freeze

      # Deux modes seulement, parce que OF_FLEET_HOS_RULESET n'en connaît que trois et que le
      # troisième (`none`) désactive tout contrôle. Le portail affiche un bandeau explicite dans
      # ce cas : une flotte sans règle d'heures de service est une décision, pas un défaut.
      HOS_RULESETS = %w[eu_561 us_fmcsa none].freeze

      # Affectations d'une expédition. `active=true` filtre sur released_at IS NULL côté service ;
      # la contrainte d'exclusion sur fleet.vehicle_assignments garantit qu'il n'y en a jamais
      # deux qui se recouvrent pour le même véhicule, donc cette liste est courte par construction.
      def assignments_for_shipment(shipment_id, active_only: true)
        PrefixedUlid.assert!(shipment_id, :shipment)
        paginate('/v1/assignments', { shipment_id: shipment_id, active: active_only || nil }, max_items: 50)
      end

      def assignments_for_vehicle(vehicle_id, active_only: false)
        PrefixedUlid.assert!(vehicle_id, :vehicle)
        paginate('/v1/assignments', { vehicle_id: vehicle_id, active: active_only || nil }, max_items: 100)
      end

      def vehicle(vehicle_id)
        PrefixedUlid.assert!(vehicle_id, :vehicle)
        get("/v1/vehicles/#{vehicle_id}")
      end

      def carrier_fleet(carrier_id, limit: 200)
        PrefixedUlid.assert!(carrier_id, :carrier)
        paginate("/v1/carriers/#{carrier_id}/vehicles", {}, max_items: limit)
      end

      # Temps de conduite restant dans la fenêtre courante. C'est la seule question que
      # l'astreinte pose vraiment à fleet-service : « est-ce que je peux lui demander de faire
      # encore deux heures, ou est-ce que je cherche un relais ? »
      def driver_availability(driver_id)
        PrefixedUlid.assert!(driver_id, :driver)
        get("/v1/drivers/#{driver_id}/availability")
      end

      # Changement de statut de service saisi depuis le portail : l'application driver-ios le fait
      # normalement elle-même, mais un téléphone à plat en zone portuaire arrive tous les jours.
      # La clé d'idempotence inclut l'horodatage déclaré, sinon deux saisies légitimes du même
      # chauffeur à la même minute seraient fusionnées en une.
      def append_duty_status(driver_id, status:, occurred_at:, recorded_by:)
        PrefixedUlid.assert!(driver_id, :driver)
        unless %w[driving on_duty rest sleeper_berth].include?(status)
          raise ArgumentError, "statut de service inconnu : #{status}"
        end

        post(
          "/v1/drivers/#{driver_id}/hours-of-service",
          { status: status, occurred_at: occurred_at, recorded_by: recorded_by, source: 'portal' },
          idempotency_key: "portal-hos-#{driver_id}-#{occurred_at}"
        )
      end

      # Pré-contrôle sans réservation. Son équivalent gRPC est fleet.v1.FleetService/CheckEligibility ;
      # le portail s'en approche avec ce qu'il peut lire en HTTP — permis, ADR, heures — et le dit
      # à l'écran, parce que le verdict qui compte reste celui rendu au moment de l'affectation.
      #
      # @return [Array<Hash>] motifs de blocage, vide si rien ne s'oppose au départ
      def eligibility_warnings(driver, vehicle, on_date: Date.today)
        warnings = []

        licence_expiry = driver['licence_expires_on']
        if licence_expiry && Date.parse(licence_expiry) <= on_date
          warnings << { code: 'licence_expired', detail: licence_expiry }
        elsif licence_expiry && Date.parse(licence_expiry) <= on_date + licence_warn_days
          warnings << { code: 'licence_expires_soon', detail: licence_expiry }
        end

        # ADR : un tracteur non certifié ne peut pas prendre un conteneur porteur d'une classe de
        # danger, et c'est freight.container_hazard_classes qui le dit. Le portail ne recroise pas
        # les deux ici — il signale seulement l'absence de certification côté attelage.
        adr_expiry = driver['adr_expires_on']
        warnings << { code: 'adr_expired', detail: adr_expiry } if adr_expiry && Date.parse(adr_expiry) <= on_date
        warnings << { code: 'vehicle_not_adr_certified' } if vehicle && vehicle['adr_certified'] == false

        warnings << { code: 'vehicle_decommissioned' } if vehicle && vehicle['decommissioned_at']
        warnings
      end

      def vehicle_class_label(code)
        VEHICLE_CLASS_FR.fetch(code, code)
      end

      private

      def licence_warn_days
        Integer(ENV.fetch('OF_FLEET_LICENCE_EXPIRY_WARN_DAYS', '30'))
      end
    end
  end
end
