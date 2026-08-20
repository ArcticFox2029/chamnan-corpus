# frozen_string_literal: true
#
# Middleware qui transforme la requête navigateur d'un opérateur en contexte propagé vers les
# services amont : jeton porteur, tenant, identifiant de trace et nature d'acteur (§0.3). Le
# portail joue ici le rôle de bordure : c'est lui qui fabrique le X-OF-Trace-Id quand l'ingress
# ne l'a pas déjà posé, et sans ce contexte aucun client HTTP du portail n'accepte de partir.

require 'base64'
require 'json'
require 'securerandom'

module Portal
  # Objet transporté dans env['portal.context'] et exigé par Portal::Clients::BaseClient.
  RequestContext = Struct.new(
    :tenant_id, :trace_id, :bearer, :actor_kind, :user_id, :roles, :locale,
    keyword_init: true
  ) do
    def dispatcher?
      roles.include?('dispatcher')
    end

    def auditor?
      roles.include?('auditor')
    end

    def to_log
      { tenant_id: tenant_id, user_id: user_id, trace_id: trace_id }
    end
  end

  module Middleware
    class TenantContext
      TENANT_HEADER = 'HTTP_X_OF_TENANT'
      TRACE_HEADER  = 'HTTP_X_OF_TRACE_ID'
      TRACE_FORMAT  = /\A[0-9a-f]{32}\z/.freeze

      # Chemins servis avant toute authentification : les sondes de §3.15 et les fichiers
      # statiques de l'écran de connexion.
      PUBLIC_PREFIXES = ['/healthz', '/readyz', '/metrics', '/version', '/assets/'].freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        path = env['PATH_INFO'].to_s
        return @app.call(env) if PUBLIC_PREFIXES.any? { |prefix| path.start_with?(prefix) }

        trace_id = normalise_trace(env[TRACE_HEADER])
        env['portal.trace_id'] = trace_id

        bearer = extract_bearer(env)
        return unauthorised(trace_id, 'missing_bearer_token') if bearer.nil?

        claims = decode_claims(bearer)
        return unauthorised(trace_id, 'malformed_bearer_token') if claims.nil?

        # Le portail n'embarque pas de pile gRPC et n'appelle donc jamais
        # identity.v1.TokenIntrospection/Introspect : il vérifie la signature RS256 hors ligne
        # contre le JWKS mis en cache depuis OF_IDENTITY_JWKS_URL. C'est exactement le mode
        # dégradé décrit en §1.2, et il impose sa contrepartie — les jetons non « user » sont
        # refusés ici, sans exception, y compris pour un compte de service d'exploitation.
        actor_kind = claims['akt'] || 'user'
        return forbidden(trace_id, 'actor_kind_not_permitted') unless actor_kind == 'user'

        tenant_id = env[TENANT_HEADER] || claims['tid']
        return forbidden(trace_id, 'tenant_mismatch') if tenant_id != claims['tid']

        env['portal.context'] = RequestContext.new(
          tenant_id: tenant_id,
          trace_id: trace_id,
          bearer: bearer,
          actor_kind: actor_kind,
          user_id: claims['sub'],
          roles: Array(claims['roles']),
          locale: claims['locale'] || 'fr-FR'
        )

        status, headers, body = @app.call(env)
        headers['X-OF-Trace-Id'] = trace_id
        [status, headers, body]
      end

      private

      def normalise_trace(raw)
        value = raw.to_s.downcase
        return value if TRACE_FORMAT.match?(value)

        # Un trace-id fabriqué ici plutôt que propagé casse la corrélation avec l'ingress,
        # d'où la trace de niveau debug : en production ce cas ne devrait pas se produire.
        Portal.logger.debug(msg: 'trace-id absent ou malformé, régénéré au portail')
        SecureRandom.hex(16)
      end

      def extract_bearer(env)
        header = env['HTTP_AUTHORIZATION'].to_s
        return nil unless header.start_with?('Bearer ')

        token = header[7..].strip
        token.empty? ? nil : token
      end

      # Lecture seule de la charge utile. La vérification cryptographique est faite par
      # Portal::Jwks avant d'arriver ici ; ce décodage ne sert qu'à extraire tid/sub/roles.
      def decode_claims(bearer)
        payload = bearer.split('.')[1]
        return nil if payload.nil?

        JSON.parse(Base64.urlsafe_decode64(payload + '=' * ((4 - payload.length % 4) % 4)))
      rescue ArgumentError, JSON::ParserError
        nil
      end

      def unauthorised(trace_id, code)
        envelope(401, code, 'authentification requise', trace_id)
      end

      def forbidden(trace_id, code)
        envelope(403, code, 'jeton refusé pour cette surface', trace_id)
      end

      # Même enveloppe d'erreur que les quatorze services (§0.4) : les outils d'exploitation
      # parsent indifféremment une erreur du portail et une erreur de billing-service.
      def envelope(status, code, message, trace_id)
        body = JSON.generate(
          error: {
            code: code,
            http_status: status,
            message: message,
            trace_id: trace_id,
            retryable: false,
            fields: []
          }
        )
        [status, { 'content-type' => 'application/json', 'X-OF-Trace-Id' => trace_id }, [body]]
      end
    end
  end
end
