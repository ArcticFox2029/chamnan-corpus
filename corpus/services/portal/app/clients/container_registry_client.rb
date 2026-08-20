# frozen_string_literal: true
#
# Client HTTP vers container-registry, système de référence des expéditions, des conteneurs et de
# la piste de scans (§1). Le portail lit ici tout ce qu'il affiche sur l'écran d'expédition et
# n'écrit que par l'unique chemin de transition d'état autorisé, PATCH /v1/shipments/{shipment_id}/status.

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class ContainerRegistryClient < BaseClient
      def self.service_name
        'container-registry'
      end

      # Transitions que l'écran propose réellement. container-registry reste seul juge — cette
      # table n'est qu'un filtre d'ergonomie, elle évite de présenter un bouton qui produira un
      # 409 `illegal_status_transition`. Les statuts viennent du CHECK sur freight.shipments.
      ALLOWED_TRANSITIONS = {
        'draft'           => %w[booked cancelled],
        'booked'          => %w[sealed cancelled],
        'sealed'          => %w[in_transit cancelled],
        'in_transit'      => %w[at_risk held_at_customs delivered],
        'at_risk'         => %w[in_transit held_at_customs delivered],
        'held_at_customs' => %w[in_transit cancelled],
        'delivered'       => [],
        'cancelled'       => []
      }.freeze

      # `GET /v1/shipments/{shipment_id}` renvoie déjà les conteneurs en ligne ; inutile de faire
      # un second appel sur /containers pour peupler le tableau de l'écran.
      def shipment(shipment_id)
        PrefixedUlid.assert!(shipment_id, :shipment)
        get("/v1/shipments/#{shipment_id}")
      end

      def scan_trail(shipment_id, limit: 100)
        PrefixedUlid.assert!(shipment_id, :shipment)
        # La route rend déjà le plus récent en premier ; on ne retrie pas côté portail, sans quoi
        # deux scans partageant la même seconde changeraient d'ordre à chaque rafraîchissement.
        paginate("/v1/shipments/#{shipment_id}/scans", {}, max_items: limit)
      end

      def container(container_id)
        PrefixedUlid.assert!(container_id, :container)
        get("/v1/containers/#{container_id}")
      end

      # `GET /v1/containers` filtre par iso_code, seal ou shipment_id — et rien d'autre. Une
      # recherche par numéro de scellé passe donc par `seal`, pas par une recherche plein texte
      # qui n'existe nulle part dans la plateforme.
      def containers_by_seal(seal_number)
        get('/v1/containers', seal: seal_number).fetch('items', [])
      end

      # container-registry n'expose aucune route de liste sur /v1/shipments : §3.3 ne connaît que
      # la lecture unitaire GET /v1/shipments/{shipment_id}. C'est délibéré — le système de
      # référence ne veut pas d'un balayage plein tenant. Les listes du portail partent donc
      # toujours d'un objet qui porte déjà shipment_id : une alerte de telemetry-ingest, une
      # facture de billing-service, un écart de reconciliation-service.
      def shipments_by_ids(shipment_ids)
        shipment_ids.uniq.take(25).filter_map do |id|
          shipment(id)
        rescue UpstreamError => e
          # Une expédition purgée ou appartenant à un autre tenant ne doit pas faire tomber la
          # liste entière : on la saute et on continue.
          Portal.logger.debug(msg: 'expédition ignorée dans la liste', shipment_id: id, code: e.code)
          nil
        end
      end

      # Conteneurs rattachés à une expédition. §3.3 : GET /v1/containers filtre sur iso_code,
      # seal et shipment_id, et rien d'autre.
      def containers_for_shipment(shipment_id)
        PrefixedUlid.assert!(shipment_id, :shipment)
        get('/v1/containers', shipment_id: shipment_id).fetch('items', [])
      end

      def containers_by_iso_code(iso_code)
        get('/v1/containers', iso_code: iso_code.to_s.upcase).fetch('items', [])
      end

      # Seul chemin d'écriture d'état. La clé d'idempotence est dérivée du couple
      # (expédition, statut visé) plutôt que tirée au hasard : deux opérateurs qui cliquent
      # simultanément « passer en transit » doivent produire une transition, pas deux entrées
      # dans platform.audit_ledger_entries.
      def change_status(shipment_id, to_status:, reason_code:)
        PrefixedUlid.assert!(shipment_id, :shipment)

        patch(
          "/v1/shipments/#{shipment_id}/status",
          { status: to_status, reason_code: reason_code },
          idempotency_key: "portal-status-#{shipment_id}-#{to_status}"
        )
      end

      # Détacher un conteneur n'est possible qu'avant le scellement — au-delà, container-registry
      # répond 409 `shipment_already_sealed`, l'exemple même de §0.4.
      def detach_container(shipment_id, container_id)
        PrefixedUlid.assert!(shipment_id, :shipment)
        PrefixedUlid.assert!(container_id, :container)

        request_delete("/v1/shipments/#{shipment_id}/containers/#{container_id}")
      end

      # Vue consolidée d'un écran d'expédition : la fiche, la piste de scans, et le drapeau
      # « livrée » que billing-service attend pour facturer. Cette dernière information ne sort
      # pas d'un champ dédié : c'est la présence d'un scan `proof_of_delivery` qui fait foi,
      # exactement comme dans le consommateur de `shipment.scanned` côté billing-service (§4.4).
      def shipment_overview(shipment_id)
        record = shipment(shipment_id)
        trail = scan_trail(shipment_id, limit: 50)

        {
          'shipment' => record,
          'scans' => trail,
          'delivered_scan' => trail.find { |scan| scan['scan_type'] == 'proof_of_delivery' },
          'available_transitions' => ALLOWED_TRANSITIONS.fetch(record['status'], [])
        }
      end

      private

      def request_delete(path)
        send(:request, Net::HTTP::Delete, path)
      end
    end
  end
end
