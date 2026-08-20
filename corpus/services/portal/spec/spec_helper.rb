# frozen_string_literal: true
#
# Amorçage des tests du portail : environnement OF_* minimal, neutralisation du réseau, et un
# contexte de requête tout fait. Aucun test de ce dossier ne doit joindre un service de §1 —
# webmock coupe la sortie, et un test qui échoue faute de réseau est un test mal écrit.

require 'minitest/autorun'
require 'webmock/minitest'

# Les variables lues par Portal.boot!. Elles sont posées avant le require de l'application :
# build_config lève au chargement si l'une d'elles manque, ce qui est exactement le comportement
# voulu en production et qu'on ne veut donc pas contourner ici.
ENV['OF_ENVIRONMENT'] ||= 'ci'
ENV['OF_REGION_CODE'] ||= 'eu-west'
ENV['OF_SERVICE_NAME'] ||= 'portal'
ENV['OF_LOG_LEVEL'] ||= 'error'
ENV['OF_LOG_FORMAT'] ||= 'text'
ENV['OF_HTTP_PORT'] ||= '8080'
ENV['OF_IDENTITY_JWKS_URL'] ||= 'http://identity-service:8081/.well-known/jwks.json'
ENV['OF_BILLING_BASE_URL'] ||= 'http://billing-service:8088'
ENV['OF_CUSTOMS_BASE_URL'] ||= 'http://customs-service:8087'
ENV['OF_DOCUMENT_BASE_URL'] ||= 'http://document-service:8089'
ENV['OF_FLEET_BASE_URL'] ||= 'http://fleet-service:8082'

require_relative '../app/boot'
require_relative '../app/middleware/tenant_context'
require_relative '../lib/portal/money'
require_relative '../lib/portal/residency'
require_relative '../lib/portal/prefixed_ulid'
require_relative '../lib/portal/event_catalogue'

Portal.boot!

module PortalTestHelpers
  # Identifiants d'exemple. Ils respectent §0.1 (préfixe + 26 caractères base32 Crockford) parce
  # que PrefixedUlid.assert! est appelé sur presque tous les chemins : un identifiant bricolé
  # ferait échouer les tests pour une raison qui n'a rien à voir avec ce qu'ils vérifient.
  SHIPMENT_ID    = 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PC'
  INVOICE_ID     = 'inv_01J8ZK4T9QW3RM7XN2VB6HD5PD'
  DECLARATION_ID = 'dcl_01J8ZK4T9QW3RM7XN2VB6HD5PE'
  CONTAINER_ID   = 'cnt_01J8ZK4T9QW3RM7XN2VB6HD5PF'
  DRIVER_ID      = 'drv_01J8ZK4T9QW3RM7XN2VB6HD5PG'
  VEHICLE_ID     = 'veh_01J8ZK4T9QW3RM7XN2VB6HD5PH'

  def build_context(roles: %w[dispatcher], tenant_id: 'tnt_01J7A0000000000000000000AA')
    Portal::RequestContext.new(
      tenant_id: tenant_id,
      trace_id: '4bf92f3577b34da6a3ce929d0e0e4736',
      bearer: 'jeton-de-test',
      actor_kind: 'user',
      user_id: 'usr_01J8ZK4T9QW3RM7XN2VB6HD5PA',
      roles: roles,
      locale: 'fr-FR'
    )
  end

  # Enveloppe d'erreur de §0.4, telle que la renvoie n'importe lequel des quatorze services.
  def error_envelope(code:, http_status:, message: 'refus de test', retryable: false)
    JSON.generate(
      error: {
        code: code, http_status: http_status, message: message,
        trace_id: '4bf92f3577b34da6a3ce929d0e0e4736', retryable: retryable, fields: []
      }
    )
  end
end
