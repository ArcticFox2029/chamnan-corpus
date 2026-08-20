# frozen_string_literal: true
#
# Deux écrans autour de notification-service : le journal d'acheminement, ouvert chaque fois qu'un
# client affirme n'avoir rien reçu, et l'éditeur de préférences par utilisateur. Le portail ne
# consomme aucun topic ; il ne peut donc rien dire de ce qui n'a jamais produit de ligne dans
# platform.notifications, et l'écran le formule explicitement plutôt que d'afficher une page vide.

require 'sinatra/base'
require 'json'
require 'time'

require_relative '../../lib/portal/event_catalogue'

module Portal
  class App < Sinatra::Base
    get '/notifications' do
      since = params['since'] || (Time.now.utc - 86_400).iso8601

      rows = clients[:notify].recent(
        state: presence(params['state']),
        channel: presence(params['channel']),
        since: since,
        limit: 200
      )

      erb :notification_log, locals: {
        rows: rows,
        since: since,
        state: params['state'],
        channel: params['channel'],
        # Un 'suppressed' n'est pas une panne : la préférence était coupée, ou l'envoi tombait
        # dans une plage de silence de platform.notification_preferences. Les compter à part
        # évite d'ouvrir un incident pour un comportement demandé par l'utilisateur lui-même.
        counters: rows.group_by { |row| row['state'] }.transform_values(&:size),
        exhausted: rows.count { |row| clients[:notify].exhausted?(row) }
      }
    end

    # Fiche d'un envoi précis. C'est ici qu'on répond à « pourquoi » : source_event_id porte le
    # `evt_` de l'enveloppe (§0.7), et le nom de l'événement dit quel service a déclenché quoi.
    get '/notifications/:notification_id' do |notification_id|
      PrefixedUlid.assert!(notification_id, :notification)

      row = clients[:notify].recent(limit: 500).find { |item| item['notification_id'] == notification_id }
      halt 404, erb(:not_found) if row.nil?

      erb :notification_detail, locals: {
        row: row,
        state_label: clients[:notify].state_label(row['state']),
        explanation: clients[:notify].explain(row),
        exhausted: clients[:notify].exhausted?(row),
        # `notification.delivery.failed` (§4.18) part vers analytics-pipeline et audit-ledger à
        # chaque échec définitif. L'écran le rappelle : l'incident est déjà tracé ailleurs, il
        # n'y a rien à ressaisir à la main.
        traced_downstream: row['state'] == 'failed'
      }
    end

    get '/users/:user_id/notification-preferences' do |user_id|
      preferences = clients[:notify].preferences(user_id)

      erb :notification_preferences, locals: {
        user_id: user_id,
        # La table est indexée par (canal, événement) : c'est la clé primaire de
        # platform.notification_preferences, et l'écran la reproduit telle quelle pour que la
        # correspondance entre ce qu'on coche et ce qui est stocké reste évidente.
        matrix: build_matrix(preferences.fetch('preferences', [])),
        channels: Clients::NotificationClient::CHANNELS,
        events: EventCatalogue::SUBSCRIBABLE.map { |name| [name, EventCatalogue.label(name)] }
      }
    end

    # Remplacement complet, jamais partiel : §3.10 ne connaît que PUT sur cette ressource, ce qui
    # correspond au fait qu'une préférence absente de la table vaut « valeur par défaut » et non
    # « désactivée ». Envoyer une différence produirait deux lectures divergentes de l'absence.
    post '/users/:user_id/notification-preferences' do |user_id|
      rows = parse_preference_form(params)

      clients[:notify].replace_preferences(user_id, rows)
      Portal.logger.info(
        msg: 'préférences de notification remplacées', target_user_id: user_id,
        rows: rows.size, **ctx.to_log
      )
      redirect "/users/#{user_id}/notification-preferences"
    rescue ArgumentError => e
      status 422
      erb :invalid_preferences, locals: { message: e.message }
    end

    private

    def presence(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s
    end

    def build_matrix(rows)
      rows.each_with_object({}) do |row, acc|
        acc[[row['channel'], row['event_name']]] = row
      end
    end

    # Le formulaire poste une case par couple (canal, événement) plus, une seule fois, la plage de
    # silence et le fuseau. Ce dernier est stocké par ligne dans la table mais l'écran ne propose
    # pas de le faire varier par canal : personne n'a jamais demandé à dormir en UTC pour les SMS
    # et en Europe/Hamburg pour les courriels.
    def parse_preference_form(params)
      timezone = params['timezone'].to_s.empty? ? 'UTC' : params['timezone'].to_s
      quiet_start = presence(params['quiet_hours_start'])
      quiet_end = presence(params['quiet_hours_end'])

      if (quiet_start.nil?) ^ (quiet_end.nil?)
        raise ArgumentError, 'plage de silence incomplète : début et fin sont indissociables'
      end

      Clients::NotificationClient::CHANNELS.flat_map do |channel|
        EventCatalogue::SUBSCRIBABLE.map do |event_name|
          {
            channel: channel,
            event_name: event_name,
            enabled: params["enabled[#{channel}][#{event_name}]"] == 'on',
            quiet_hours_start: quiet_start,
            quiet_hours_end: quiet_end,
            timezone: timezone
          }
        end
      end
    end
  end
end
