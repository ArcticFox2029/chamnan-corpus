# frozen_string_literal: true
#
# Point d'entrée Rack du portail d'administration interne. Assemble la pile de middlewares
# autour de Portal::App — contexte tenant, garde d'idempotence — et laisse le serveur
# applicatif écouter sur OF_HTTP_PORT. Aucune logique métier ne vit dans ce fichier.
#
# À ne pas confondre avec les deux autres surfaces web de la plateforme : `web/` est la console
# opérateur destinée aux clients, et partner-portal-api sert les courtiers externes sous
# /partner/v1. Le portail, lui, n'est joignable que depuis le VPN d'exploitation.

require 'rack'
require 'rack/deflater'

require_relative 'app/boot'
require_relative 'app/middleware/tenant_context'
require_relative 'app/middleware/idempotency_guard'
require_relative 'app/portal_app'

Portal.boot!

# L'ordre compte. TenantContext doit s'exécuter en premier : il fabrique le X-OF-Trace-Id
# quand l'ingress ne l'a pas fourni, et tout ce qui suit (journalisation, idempotence,
# clients HTTP) le suppose déjà présent dans l'environnement Rack.
use Rack::Deflater
use Portal::Middleware::TenantContext
use Portal::Middleware::IdempotencyGuard

# Les sondes de §3.15 sont montées hors de la pile d'authentification : kubelet ne présente
# évidemment aucun jeton émis par identity-service.
map '/healthz' do
  run ->(_env) { [200, { 'content-type' => 'text/plain' }, ["ok\n"]] }
end

map '/' do
  run Portal::App
end
