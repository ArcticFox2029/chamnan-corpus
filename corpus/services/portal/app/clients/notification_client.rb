# frozen_string_literal: true
#
# Client vers notification-service : journal d'acheminement pour l'écran « pourquoi le client n'a
# rien reçu », et édition des préférences par utilisateur. Le portail ne décide jamais d'un envoi
# métier — ces envois naissent d'événements de §4 — il n'expédie que des messages saisis à la main
# par un opérateur, via POST /v1/notifications/dispatch.

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'
require_relative '../../lib/portal/event_catalogue'

module Portal
  module Clients
    class NotificationClient < BaseClient
      def self.service_name
        'notification-service'
      end

      # CHECK sur platform.notifications.channel et sur platform.notification_preferences.channel :
      # les deux tables partagent la même liste, et 'console' désigne la cloche du web console,
      # pas un écran du portail.
      CHANNELS = %w[email sms push webhook console].freeze

      # CHECK sur platform.notifications.state. 'suppressed' n'est pas un échec : c'est une
      # préférence désactivée ou une plage de silence (quiet_hours_start / quiet_hours_end), et
      # l'écran doit le dire autrement qu'un 'failed', sinon on rouvre un incident pour rien.
      STATE_FR = {
        'queued' => 'en file',
        'sending' => 'en cours',
        'sent' => 'acheminée',
        'failed' => 'en échec',
        'suppressed' => 'supprimée par préférence'
      }.freeze

      def recent(state: nil, channel: nil, since: nil, limit: 100)
        raise ArgumentError, "canal inconnu : #{channel}" if channel && !CHANNELS.include?(channel)

        paginate('/v1/notifications', { state: state, channel: channel, since: since }, max_items: limit)
      end

      def preferences(user_id)
        PrefixedUlid.assert!(user_id, :user)
        get("/v1/users/#{user_id}/preferences")
      end

      # PUT et non PATCH : §3.10 remplace l'ensemble des préférences d'un coup, ce qui correspond
      # à la clé primaire composite (user_id, channel, event_name) de platform.notification_preferences
      # — il n'existe pas de « mise à jour partielle » qui ait un sens sur une telle table.
      def replace_preferences(user_id, rows)
        PrefixedUlid.assert!(user_id, :user)

        rows.each do |row|
          unless CHANNELS.include?(row[:channel])
            raise ArgumentError, "canal inconnu : #{row[:channel]}"
          end
          unless EventCatalogue.known?(row[:event_name])
            raise ArgumentError, "événement absent de §4 : #{row[:event_name]}"
          end
        end

        put(
          "/v1/users/#{user_id}/preferences",
          { preferences: rows.map { |row| normalise_preference(row) } },
          idempotency_key: "portal-prefs-#{user_id}"
        )
      end

      # Envoi manuel : l'opérateur prévient un client que son camion a deux heures de retard,
      # avant même que route.replanned ne parte. source_event_id est obligatoire sur
      # platform.notifications (il rend les retransmissions idempotentes) ; pour un envoi humain
      # il n'existe pas d'événement, on fabrique donc une clé stable à partir du destinataire et
      # du gabarit, ce que notification-service accepte explicitement pour ce chemin.
      def dispatch(recipient_user_id:, channel:, template_code:, payload:)
        PrefixedUlid.assert!(recipient_user_id, :user)
        raise ArgumentError, "canal inconnu : #{channel}" unless CHANNELS.include?(channel)

        post(
          '/v1/notifications/dispatch',
          {
            recipient_user_id: recipient_user_id,
            channel: channel,
            template_code: template_code,
            payload: payload,
            origin: 'portal'
          },
          idempotency_key: "portal-dispatch-#{recipient_user_id}-#{template_code}-#{Time.now.utc.to_i / 60}"
        )
      end

      # Diagnostic d'un échec. OF_NOTIFY_MAX_ATTEMPTS vaut 8, la même valeur que la règle de DLQ
      # de §4.19 : une notification qui affiche huit tentatives a épuisé son budget et ne repartira
      # pas toute seule, quoi qu'on fasse depuis cet écran.
      def exhausted?(notification)
        notification.fetch('attempts', 0) >= Integer(ENV.fetch('OF_NOTIFY_MAX_ATTEMPTS', '8'))
      end

      def state_label(state)
        STATE_FR.fetch(state, state)
      end

      # Remonte de la notification vers l'événement qui l'a provoquée. source_event_id porte un
      # `evt_` de §0.1 ; le portail ne peut pas relire le message Kafka (il ne consomme rien),
      # mais le nom de l'événement suffit à expliquer l'envoi.
      def explain(notification)
        event = EventCatalogue.fetch(notification['template_code_source'] || notification['event_name'])
        return "envoi manuel depuis le portail (#{notification['template_code']})" if event.nil?

        "déclenchée par #{event.name}, publiée par #{event.producer} sur #{event.topic}"
      end

      private

      def normalise_preference(row)
        {
          channel: row[:channel],
          event_name: row[:event_name],
          enabled: row.fetch(:enabled, true),
          quiet_hours_start: row[:quiet_hours_start],
          quiet_hours_end: row[:quiet_hours_end],
          timezone: row[:timezone] || 'UTC'
        }
      end
    end
  end
end
