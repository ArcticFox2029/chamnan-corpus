# frozen_string_literal: true
#
# Client HTTP vers telemetry-ingest pour la file d'alertes de l'astreinte : ce qui a dépassé un
# seuil, sur quel conteneur, et depuis quand. C'est la seule liste réellement paginable dont
# dispose le portail — c'est donc par elle que commence le tableau de bord, et de l'alerte on
# remonte vers l'expédition puis vers la facture.

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class TelemetryClient < BaseClient
      def self.service_name
        'telemetry-ingest'
      end

      # CHECK sur telemetry.telemetry_alerts.rule_code. Traduit à l'affichage seulement : la
      # valeur circule en anglais dans `telemetry.alert.raised` (§4.9) et dans les gabarits de
      # notification-service, on ne la réécrit jamais.
      RULE_LABELS = {
        'temp_excursion_high' => 'dépassement de température haute',
        'temp_excursion_low'  => 'dépassement de température basse',
        'humidity_high'       => 'humidité excessive',
        'shock_impact'        => 'choc détecté',
        'door_open_in_transit' => 'porte ouverte en transit',
        'battery_critical'    => 'batterie critique',
        'gateway_silent'      => 'passerelle muette',
        'geofence_breach'     => 'sortie de géorepère'
      }.freeze

      # Sévérité 1 à 5 (contrainte BETWEEN sur la table). Au-dessus du seuil fixé par
      # OF_FREIGHT_AUTO_AT_RISK_SEVERITY, container-registry bascule l'expédition en `at_risk`
      # de lui-même en consommant l'événement : l'astreinte voit alors le statut changer sans
      # que personne n'ait cliqué, et l'écran doit l'expliquer plutôt que de le subir.
      def open_alerts(severity_min: 1, rule_code: nil, limit: 50)
        paginate(
          '/v1/alerts',
          { state: 'open', severity_min: severity_min, rule_code: rule_code },
          max_items: limit
        )
      end

      def alerts_for_container(container_id, state: nil)
        PrefixedUlid.assert!(container_id, :container)
        paginate('/v1/alerts', { container_id: container_id, state: state }, max_items: 100)
      end

      # Fenêtre de lectures autour d'une alerte, pour la courbe affichée sous le bandeau. La
      # requête part sur la partition de région : telemetry.telemetry_readings est partitionnée
      # par LIST sur region_code, et interroger hors de sa région ne rendrait rien de toute façon.
      def readings(container_id, from:, to:)
        PrefixedUlid.assert!(container_id, :container)
        get("/v1/containers/#{container_id}/readings", from: from, to: to).fetch('items', [])
      end

      # Prise en compte. Pose acknowledged_by / acknowledged_at, sans fermer l'alerte : une
      # excursion de température reste ouverte tant que la sonde n'est pas revenue dans les
      # clous, et c'est bien ce qu'on veut voir sur l'écran de nuit.
      def acknowledge(alert_id)
        PrefixedUlid.assert!(alert_id, :alert)
        post("/v1/alerts/#{alert_id}/acknowledge", {}, idempotency_key: "portal-ack-#{alert_id}")
      end

      # Fermeture manuelle, quand l'incident est résolu sur le terrain. Le portail exige un motif
      # que telemetry-ingest ne stocke pas : il part malgré tout dans le corps, parce que la
      # trace utile est celle que audit-ledger conservera de l'appel, pas la colonne.
      def close(alert_id, resolution_note:)
        PrefixedUlid.assert!(alert_id, :alert)
        raise ArgumentError, 'motif de fermeture obligatoire' if resolution_note.to_s.strip.empty?

        post(
          "/v1/alerts/#{alert_id}/close",
          { resolution_note: resolution_note.strip },
          idempotency_key: "portal-close-#{alert_id}"
        )
      end

      def rule_label(rule_code)
        RULE_LABELS.fetch(rule_code, rule_code)
      end

      # Une alerte `gateway_silent` ne parle pas d'un conteneur mais d'une passerelle de dépôt :
      # elle double `gateway.heartbeat.missed` (§4.10), que notification-service traite déjà. La
      # remonter dans la file de l'astreinte fret ferait du bruit pour rien.
      def freight_relevant?(alert)
        alert['rule_code'] != 'gateway_silent'
      end
    end
  end
end
