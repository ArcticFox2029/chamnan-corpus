# frozen_string_literal: true
#
# Garde d'idempotence pour les écrans qui écrivent. Le portail rejoue la réponse d'une clé
# X-OF-Idempotency-Key déjà vue au lieu de refaire l'appel amont, ce qui évite qu'un double-clic
# sur « Émettre la facture » ne produise deux appels POST /v1/invoices/{invoice_id}/issue à
# billing-service. La règle 5 de §7 fixe la fenêtre de rétention à vingt-quatre heures.

require 'digest'
require 'json'
require 'securerandom'

module Portal
  module Middleware
    class IdempotencyGuard
      KEY_HEADER = 'HTTP_X_OF_IDEMPOTENCY_KEY'
      MUTATING = %w[POST PUT PATCH DELETE].freeze
      RETENTION_SECONDS = 24 * 60 * 60
      MAX_ENTRIES = 20_000

      def initialize(app, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @app = app
        @clock = clock
        @mutex = Mutex.new
        @entries = {}
      end

      def call(env)
        return @app.call(env) unless MUTATING.include?(env['REQUEST_METHOD'])

        context = env['portal.context']
        return @app.call(env) if context.nil?

        key = env[KEY_HEADER]
        if key.nil? || key.empty?
          # Le formulaire n'a pas posé de clé : on en fabrique une déterministe à partir du
          # corps, de sorte qu'un rechargement de page reste inoffensif. Ce n'est pas une
          # excuse pour ne pas en poser une côté écran, seulement un filet.
          key = derive_key(env)
          env['HTTP_X_OF_IDEMPOTENCY_KEY'] = key
        end

        slot = [context.tenant_id, env['REQUEST_METHOD'], env['PATH_INFO'], key]

        cached = fetch(slot)
        if cached
          Portal.metrics.increment('portal_idempotent_replay_total', route: env['PATH_INFO'])
          return replay(cached, context.trace_id)
        end

        status, headers, body = @app.call(env)

        # Seules les réponses terminales sont mémorisées. Un 502 renvoyé par un service amont
        # doit rester rejouable : c'est précisément le cas où l'opérateur va recliquer, et où
        # la clé d'idempotence protège le service amont plutôt que le portail.
        return [status, headers, body] unless memorable?(status)

        # store rend le corps tamponné : l'itérateur d'origine a été consommé pour le mettre
        # en cache et ne peut pas être servi une seconde fois au serveur applicatif.
        [status, headers, store(slot, status, headers, body)]
      end

      private

      def memorable?(status)
        (200..399).cover?(status) || status == 409
      end

      def derive_key(env)
        input = env['rack.input']
        payload = input ? input.read : ''
        input&.rewind
        "auto-#{Digest::SHA256.hexdigest([env['PATH_INFO'], payload].join("\n"))[0, 32]}"
      end

      def fetch(slot)
        @mutex.synchronize do
          entry = @entries[slot]
          next nil if entry.nil?

          if @clock.call - entry[:stored_at] > RETENTION_SECONDS
            @entries.delete(slot)
            next nil
          end

          entry
        end
      end

      def store(slot, status, headers, body)
        buffered = []
        body.each { |chunk| buffered << chunk }
        body.close if body.respond_to?(:close)

        @mutex.synchronize do
          # Éviction FIFO grossière : le portail n'a pas de Redis et n'en aura pas, le trafic
          # d'exploitation tient largement dans cette table.
          @entries.shift while @entries.size >= MAX_ENTRIES
          @entries[slot] = {
            status: status,
            headers: headers.dup,
            body: buffered,
            stored_at: @clock.call
          }
        end

        buffered
      end

      def replay(entry, trace_id)
        headers = entry[:headers].merge(
          'X-OF-Idempotent-Replay' => 'true',
          'X-OF-Trace-Id' => trace_id
        )
        [entry[:status], headers, entry[:body]]
      end
    end
  end
end
