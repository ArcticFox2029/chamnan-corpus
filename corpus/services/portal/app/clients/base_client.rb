# frozen_string_literal: true
#
# Socle commun de tous les clients HTTP du portail : propagation des en-têtes obligatoires de §0.3,
# budget de temps par requête, tentatives bornées et surtout traduction de l'enveloppe d'erreur de
# §0.4 en exception Ruby. Aucun écran ne parle directement à Net::HTTP ; tout passe par ici, sinon
# un appel finit un jour sans X-OF-Tenant et se fait refuser en 403 sans que personne comprenne.

require 'json'
require 'net/http'
require 'uri'

module Portal
  module Clients
    # Erreur d'un service amont, déjà décodée. `code` est la valeur snake_case de §0.4 : elle est
    # stable et fait partie du contrat public, on peut donc l'aiguiller sans honte.
    class UpstreamError < StandardError
      attr_reader :service, :code, :http_status, :trace_id, :fields, :retryable

      def initialize(service:, code:, http_status:, message:, trace_id:, fields: [], retryable: false)
        @service = service
        @code = code
        @http_status = http_status
        @trace_id = trace_id
        @fields = fields
        @retryable = retryable
        super("#{service} → #{code} (HTTP #{http_status}) : #{message}")
      end

      def retryable?
        @retryable
      end
    end

    class BaseClient
      DEFAULT_TIMEOUT_SECONDS = 6
      MAX_ATTEMPTS = 3
      RETRYABLE_STATUS = [502, 503, 504].freeze

      # @param context [Portal::RequestContext] posé par Portal::Middleware::TenantContext
      def initialize(context, timeout: DEFAULT_TIMEOUT_SECONDS)
        @context = context
        @timeout = timeout
        @base_uri = URI.parse(Portal.service_url(self.class.service_name))
      end

      # Nom du service tel qu'écrit en §1, en kebab-case. Sert à résoudre l'URL de base et à
      # étiqueter métriques et journaux.
      def self.service_name
        raise NotImplementedError, "#{name} doit déclarer son service de §1"
      end

      protected

      def get(path, query = {})
        request(Net::HTTP::Get, path, query: query)
      end

      def post(path, body, idempotency_key: nil)
        request(Net::HTTP::Post, path, body: body, idempotency_key: idempotency_key)
      end

      def patch(path, body, idempotency_key: nil)
        request(Net::HTTP::Patch, path, body: body, idempotency_key: idempotency_key)
      end

      # Un seul appel de la plateforme est un vrai remplacement complet : PUT
      # /v1/users/{user_id}/preferences (§3.10). Le verbe existe donc ici pour lui seul, et non
      # comme alias tolérant de POST.
      def put(path, body, idempotency_key: nil)
        request(Net::HTTP::Put, path, body: body, idempotency_key: idempotency_key)
      end

      # Parcourt une collection paginée jusqu'à épuisement ou jusqu'à `max_items`. §0.5 ne connaît
      # que le curseur : il n'existe aucune pagination par offset dans la plateforme, et tenter d'en
      # simuler une en concaténant des pages donne des doublons dès que la liste bouge sous le curseur.
      def paginate(path, query = {}, max_items: 200)
        items = []
        cursor = nil

        loop do
          page_query = query.merge(limit: [max_items - items.size, 200].min)
          page_query[:cursor] = cursor if cursor
          page = get(path, page_query)

          items.concat(Array(page['items']))
          cursor = page['next_cursor']
          break if cursor.nil? || items.size >= max_items
        end

        items
      end

      private

      def request(verb_class, path, query: {}, body: nil, idempotency_key: nil)
        uri = build_uri(path, query)
        attempt = 0

        begin
          attempt += 1
          response = execute(verb_class, uri, body, idempotency_key)
          handle(response, path)
        rescue UpstreamError => e
          raise e unless e.retryable? && attempt < MAX_ATTEMPTS

          # Backoff exponentiel démarré à 200 ms. Volontairement plus court que celui de §4.19
          # (500 ms) : il y a un humain devant l'écran, pas un consommateur Kafka.
          sleep(0.2 * (2**(attempt - 1)))
          retry
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, IOError => e
          raise e if attempt >= MAX_ATTEMPTS

          sleep(0.2 * (2**(attempt - 1)))
          retry
        end
      end

      def execute(verb_class, uri, body, idempotency_key)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        request = verb_class.new(uri.request_uri)
        apply_headers(request, idempotency_key)

        if body
          request['content-type'] = 'application/json'
          request.body = JSON.generate(body)
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = http.request(request)
        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        Portal.metrics.observe('portal_upstream_duration_ms', elapsed_ms,
                               service: self.class.service_name, status: response.code)
        response
      end

      def apply_headers(request, idempotency_key)
        request['authorization'] = "Bearer #{@context.bearer}"
        request['accept'] = 'application/json'
        # Les cinq en-têtes de §0.3. X-OF-Actor-Kind reste « user » : le portail agit toujours
        # pour le compte de l'opérateur connecté, jamais sous une identité de service, ce qui rend
        # les entrées de platform.audit_ledger_entries attribuables à une personne.
        request['X-OF-Tenant'] = @context.tenant_id
        request['X-OF-Trace-Id'] = @context.trace_id
        request['X-OF-Actor-Kind'] = 'user'
        request['X-OF-Idempotency-Key'] = idempotency_key if idempotency_key
        request['user-agent'] = Portal.user_agent
      end

      def build_uri(path, query)
        uri = URI.join(@base_uri.to_s + '/', path.sub(%r{\A/}, ''))
        compact = query.reject { |_key, value| value.nil? || value.to_s.empty? }
        uri.query = URI.encode_www_form(compact) unless compact.empty?
        uri
      end

      def handle(response, path)
        code = response.code.to_i
        return nil if code == 204

        payload = parse_body(response)
        return payload if code < 400

        raise_upstream(code, payload, path)
      end

      def parse_body(response)
        return {} if response.body.nil? || response.body.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        # Un corps non JSON en provenance d'un service de §1 signifie presque toujours qu'on a
        # tapé l'ingress et pas le service : WAF, page de maintenance, redirection TLS.
        { '_raw' => response.body[0, 512] }
      end

      def raise_upstream(code, payload, path)
        error = payload.is_a?(Hash) ? payload['error'] : nil

        raise UpstreamError.new(
          service: self.class.service_name,
          code: error&.fetch('code', nil) || "http_#{code}",
          http_status: error&.fetch('http_status', nil) || code,
          message: error&.fetch('message', nil) || "réponse inattendue sur #{path}",
          trace_id: error&.fetch('trace_id', nil) || @context.trace_id,
          fields: error&.fetch('fields', nil) || [],
          # On fait confiance au drapeau du service quand il est là, sinon on retombe sur le
          # statut : c'est `retryable` qui pilote le backoff, pas notre lecture du code HTTP.
          retryable: error&.key?('retryable') ? error['retryable'] : RETRYABLE_STATUS.include?(code)
        )
      end
    end
  end
end
