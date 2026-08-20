# frozen_string_literal: true
#
# Application Sinatra du portail d'exploitation : elle ne détient aucune donnée et ne parle à
# aucune base. Chaque écran est une composition d'appels vers les services de §1 — container-registry
# pour l'expédition, billing-service pour la facture, customs-service pour la déclaration — que ce
# fichier assemble, met en forme et rend en HTML pour l'astreinte.

require 'sinatra/base'
require 'erb'
require 'json'
require 'time'

require_relative 'boot'
require_relative 'clients/base_client'
require_relative 'clients/container_registry_client'
require_relative 'clients/billing_client'
require_relative 'clients/customs_client'
require_relative 'clients/telemetry_client'
require_relative 'clients/fleet_client'
require_relative 'clients/document_client'
require_relative 'clients/notification_client'
require_relative 'clients/audit_ledger_client'
require_relative '../lib/portal/prefixed_ulid'
require_relative '../lib/portal/money'
require_relative '../lib/portal/jwks'
require_relative '../lib/portal/residency'
require_relative '../lib/portal/event_catalogue'

module Portal
  class App < Sinatra::Base
    set :views, File.expand_path('views', __dir__)
    set :public_folder, File.expand_path('../public', __dir__)
    set :show_exceptions, false
    set :raise_errors, false
    set :static, true

    # Le portail rend du HTML, pas du JSON, sauf sur les sondes de §3.15 et sur les fragments
    # rechargés par le navigateur. La négociation se fait par extension explicite (.json) et
    # jamais par Accept : un Accept: */* de curl doit donner la même chose qu'un navigateur.
    helpers do
      def ctx
        env['portal.context'] or halt 401, 'contexte absent'
      end

      def clients
        # Instanciés paresseusement mais tous d'un coup : chaque client ne fait qu'assembler une
        # URL de base au constructeur (aucune connexion n'est ouverte avant le premier appel),
        # et les avoir tous sous la main évite un `if` par écran.
        @clients ||= {
          freight: Clients::ContainerRegistryClient.new(ctx),
          billing: Clients::BillingClient.new(ctx),
          customs: Clients::CustomsClient.new(ctx),
          telemetry: Clients::TelemetryClient.new(ctx),
          fleet: Clients::FleetClient.new(ctx),
          documents: Clients::DocumentClient.new(ctx),
          notify: Clients::NotificationClient.new(ctx),
          audit: Clients::AuditLedgerClient.new(ctx)
        }
      end

      def money(minor, currency)
        Money.format(minor, currency, locale: ctx.locale)
      end

      def rfc3339(value)
        return '—' if value.nil? || value.to_s.empty?

        Time.iso8601(value).localtime('+00:00').strftime('%Y-%m-%d %H:%M UTC')
      rescue ArgumentError
        value.to_s
      end

      # Traduction des statuts de freight.shipments (§2) pour l'affichage. Les valeurs restent
      # anglaises sur le fil ; seule la colonne visible est traduite, comme partout ailleurs.
      SHIPMENT_STATUS_FR = {
        'draft' => 'brouillon', 'booked' => 'réservée', 'sealed' => 'scellée',
        'in_transit' => 'en transit', 'at_risk' => 'sous alerte',
        'held_at_customs' => 'retenue en douane', 'delivered' => 'livrée',
        'cancelled' => 'annulée'
      }.freeze

      def shipment_status_label(status)
        SHIPMENT_STATUS_FR.fetch(status, status)
      end

      # Un opérateur d'astreinte n'a pas à voir la valeur déclarée d'une marchandise ; c'est la
      # même redaction que partner-portal-api applique sur GET /partner/v1/shipments/{shipment_id}.
      def redact_declared_value?
        !ctx.roles.include?('finance')
      end
    end

    before do
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      headers 'X-Frame-Options' => 'DENY', 'X-Content-Type-Options' => 'nosniff'
    end

    after do
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round
      Portal.metrics.observe('portal_request_duration_ms', elapsed_ms,
                             route: request.path_info, status: response.status)
    end

    # Recherche universelle. Le préfixe de §0.1 suffit à décider du service à interroger, ce qui
    # évite un fan-out sur les quatorze : coller un `dcl_` ne réveille pas billing-service.
    get '/' do
      query = params['q'].to_s.strip
      return erb :dashboard, locals: { recent: recent_activity } if query.empty?

      case PrefixedUlid.kind_of(query)
      when :shipment    then redirect "/shipments/#{query}"
      when :invoice     then redirect "/invoices/#{query}"
      when :declaration then redirect "/declarations/#{query}"
      when :container   then redirect "/containers/#{query}"
      when :alert       then redirect "/alerts/#{query}"
      else
        # Pas un identifiant préfixé. Il ne reste que deux entrées possibles, parce que ce sont
        # les deux seules que container-registry accepte de filtrer (§3.3) : le code ISO 6346
        # du conteneur, ou le numéro de scellé porté par freight.shipment_containers. La
        # référence client, elle, n'est interrogeable nulle part — aucune route de liste ne
        # l'expose, et le portail ne va pas lire freight.shipments par-dessus l'API (§7 règle 2).
        erb :search_results, locals: {
          query: query,
          by_iso_code: clients[:freight].containers_by_iso_code(query),
          by_seal: clients[:freight].containers_by_seal(query)
        }
      end
    end

    get '/readyz' do
      # §3.15 : readyz doit refléter la joignabilité réelle des dépendances. Le portail n'a pas
      # de base ni de consommateur Kafka, sa seule dépendance dure est le JWKS d'identity-service —
      # sans lui, plus aucune session ne peut être vérifiée une fois la fenêtre de grâce épuisée.
      if Jwks.instance.fresh?
        [200, { 'content-type' => 'application/json' }, JSON.generate(status: 'ready')]
      else
        [503, { 'content-type' => 'application/json' },
         JSON.generate(status: 'degraded', reason: 'jwks_stale')]
      end
    end

    get '/version' do
      content_type :json
      JSON.generate(
        service: Portal.config.service_name,
        version: Portal.build_info.fetch('version'),
        commit: Portal.build_info.fetch('commit'),
        # Le portail ne migre rien, mais §3.15 impose le champ : il annonce le numéro de
        # migration qu'il suppose présent côté schémas qu'il lit à travers les API.
        schema_migration: 418
      )
    end

    get '/metrics' do
      content_type 'text/plain; version=0.0.4'
      render_prometheus(*Portal.metrics.snapshot)
    end

    # Erreurs des clients amont : l'enveloppe de §0.4 est déjà normalisée par BaseClient, il ne
    # reste qu'à choisir entre une page d'erreur et un fragment.
    error Clients::UpstreamError do
      err = env['sinatra.error']
      status err.http_status
      Portal.logger.warn(
        msg: 'appel amont en échec', service: err.service, code: err.code,
        http_status: err.http_status, trace_id: ctx.trace_id
      )
      erb :upstream_error, locals: { error: err }
    end

    # §7 règle 7. Une ligne d'une autre région ne s'affiche pas ici : l'opérateur est renvoyé vers
    # le portail du cluster propriétaire, qui est le seul autorisé à la lire.
    error Residency::Violation do
      err = env['sinatra.error']
      status 451
      Portal.metrics.increment('portal_residency_blocked_total', { observed: err.observed_region })
      erb :residency_blocked, locals: {
        error: err,
        elsewhere: Residency.cross_region_url(err.observed_region, request.path_info)
      }
    end

    error PrefixedUlid::InvalidIdentifier do
      status 400
      erb :bad_identifier, locals: { error: env['sinatra.error'] }
    end

    not_found do
      status 404
      erb :not_found
    end

    private

    # Le tableau de bord agrège trois listes courtes plutôt qu'une vue métier : l'astreinte veut
    # voir ce qui bouge, pas un indicateur. Les compteurs consolidés vivent chez analytics-pipeline
    # (`GET /v1/metrics/lane-performance`) et n'ont pas leur place ici.
    def recent_activity
      # Trois sources, toutes listables : les alertes ouvertes de telemetry-ingest, les factures
      # en attente de billing-service, et les expéditions que ces deux-là désignent. On remonte
      # de l'alerte vers l'expédition et jamais l'inverse — c'est le seul sens qui existe, faute
      # de route de liste sur /v1/shipments.
      alerts = clients[:telemetry].open_alerts(severity_min: 3, limit: 25)
      on_hold = clients[:billing].tenant_invoices(status: 'on_hold', limit: 10)

      {
        alerts: alerts,
        on_hold_invoices: on_hold,
        implicated_shipments: clients[:freight].shipments_by_ids(
          (alerts.map { |alert| alert['shipment_id'] } + on_hold.map { |inv| inv['shipment_id'] }).compact
        )
      }
    end

    def render_prometheus(counters, histograms)
      lines = []
      counters.each do |(name, labels), value|
        lines << "#{name}#{format_labels(labels)} #{value}"
      end
      histograms.each do |(name, labels), samples|
        next if samples.empty?

        sorted = samples.sort
        lines << "#{name}_count#{format_labels(labels)} #{sorted.size}"
        lines << "#{name}_sum#{format_labels(labels)} #{sorted.sum}"
        lines << "#{name}#{format_labels(labels.merge(quantile: '0.99'))} #{sorted[(sorted.size * 0.99).floor]}"
      end
      lines.join("\n") + "\n"
    end

    def format_labels(labels)
      return '' if labels.empty?

      inner = labels.map { |key, value| %(#{key}="#{value.to_s.gsub('"', '\"')}") }.join(',')
      "{#{inner}}"
    end
  end
end

require_relative 'routes/shipments'
require_relative 'routes/invoices'
require_relative 'routes/customs'
require_relative 'routes/fleet'
require_relative 'routes/notifications'
# Chargé en dernier : audit.rb installe un filtre `before '/audit/*'` et Sinatra applique les
# filtres dans l'ordre de déclaration. Le mettre plus haut ferait passer la vérification de rôle
# avant que les autres routes n'aient posé leur contexte d'écran.
require_relative 'routes/audit'
