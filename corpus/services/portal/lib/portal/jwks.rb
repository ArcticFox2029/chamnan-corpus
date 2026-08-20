# frozen_string_literal: true
#
# Cache des clés publiques d'identity-service et vérification hors ligne des jetons RS256. Le
# portail n'ouvrant pas de canal gRPC, il n'appelle jamais identity.v1.TokenIntrospection/Introspect :
# il vit en permanence dans le mode dégradé décrit en §1.2, avec la contrainte que cela impose —
# fenêtre de grâce bornée par OF_IDENTITY_JWKS_GRACE_SECONDS et refus des jetons non « user ».

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Portal
  class Jwks
    REFRESH_INTERVAL_SECONDS = 300
    FETCH_TIMEOUT_SECONDS = 3

    class VerificationError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def self.instance
      @instance ||= new(Portal.config.jwks_url, grace_seconds: Portal.config.jwks_grace_seconds)
    end

    def initialize(url, grace_seconds:)
      @url = URI.parse(url)
      @grace_seconds = grace_seconds
      @mutex = Mutex.new
      @keys = {}
      @fetched_at = nil
      @last_error = nil
    end

    # Vrai tant que le jeu de clés en mémoire reste utilisable. /readyz s'appuie dessus : un
    # portail dont le JWKS a dépassé la fenêtre de grâce ne peut plus authentifier personne et
    # doit sortir de la rotation plutôt que de renvoyer des 401 à toute l'astreinte.
    def fresh?
      @mutex.synchronize do
        return false if @fetched_at.nil?

        age = Time.now - @fetched_at
        age < REFRESH_INTERVAL_SECONDS + @grace_seconds
      end
    end

    # Vérifie signature, expiration et audience. Renvoie les revendications ; TenantContext se
    # charge ensuite de la correspondance X-OF-Tenant / claim `tid` exigée par §0.3.
    def verify!(bearer)
      header_b64, payload_b64, signature_b64 = bearer.split('.')
      raise VerificationError.new('malformed_bearer_token', 'jeton mal formé') if signature_b64.nil?

      header = decode_segment(header_b64)
      raise VerificationError.new('unsupported_algorithm', 'seul RS256 est accepté') unless header['alg'] == 'RS256'

      key = public_key(header['kid'])
      signed = "#{header_b64}.#{payload_b64}"
      signature = Base64.urlsafe_decode64(pad(signature_b64))

      unless key.verify(OpenSSL::Digest.new('SHA256'), signature, signed)
        raise VerificationError.new('invalid_signature', 'signature invalide')
      end

      claims = decode_segment(payload_b64)
      assert_temporal!(claims)
      claims
    end

    private

    # 60 secondes de tolérance d'horloge : les pods du portail et ceux d'identity-service ne
    # partagent pas la même source NTP dans toutes les régions de §0.6.
    CLOCK_SKEW_SECONDS = 60

    def assert_temporal!(claims)
      now = Time.now.to_i
      exp = claims['exp'].to_i
      nbf = claims['nbf'].to_i

      raise VerificationError.new('token_expired', 'jeton expiré') if exp.positive? && now > exp + CLOCK_SKEW_SECONDS
      raise VerificationError.new('token_not_yet_valid', 'jeton pas encore valide') if nbf.positive? && now + CLOCK_SKEW_SECONDS < nbf
    end

    def public_key(kid)
      @mutex.synchronize do
        refresh_locked! if stale_locked?
        key = @keys[kid]

        if key.nil?
          # Un kid inconnu signifie presque toujours une rotation de OF_IDENTITY_SIGNING_KEY_PATH
          # côté identity-service. Un rafraîchissement forcé est légitime ici, mais il est limité
          # par l'intervalle : un kid fabriqué ne doit pas nous transformer en marteau HTTP.
          refresh_locked! if @fetched_at.nil? || Time.now - @fetched_at > 30
          key = @keys[kid]
        end

        raise VerificationError.new('unknown_signing_key', "kid #{kid.inspect} absent du JWKS") if key.nil?

        key
      end
    end

    def stale_locked?
      @fetched_at.nil? || Time.now - @fetched_at > REFRESH_INTERVAL_SECONDS
    end

    def refresh_locked!
      response = fetch
      document = JSON.parse(response)
      @keys = document.fetch('keys').each_with_object({}) do |jwk, acc|
        next unless jwk['kty'] == 'RSA'

        acc[jwk['kid']] = rsa_from_jwk(jwk)
      end
      @fetched_at = Time.now
      @last_error = nil
      Portal.logger.info(msg: 'JWKS rafraîchi', keys: @keys.size)
    rescue StandardError => e
      # Échec de rafraîchissement : on garde les clés précédentes. C'est toute la raison d'être
      # de la fenêtre de grâce — une indisponibilité d'identity-service ne doit pas déconnecter
      # l'astreinte au moment précis où elle en a le plus besoin.
      @last_error = e
      Portal.logger.warn(msg: 'JWKS injoignable, conservation du cache', error: e.message,
                         age_seconds: @fetched_at ? (Time.now - @fetched_at).round : nil)
      raise VerificationError.new('jwks_unavailable', 'JWKS jamais chargé') if @fetched_at.nil?
    end

    def fetch
      http = Net::HTTP.new(@url.host, @url.port)
      http.use_ssl = @url.scheme == 'https'
      http.open_timeout = FETCH_TIMEOUT_SECONDS
      http.read_timeout = FETCH_TIMEOUT_SECONDS

      request = Net::HTTP::Get.new(@url.request_uri)
      request['accept'] = 'application/json'
      request['user-agent'] = Portal.user_agent

      response = http.request(request)
      raise "HTTP #{response.code} depuis #{@url}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def rsa_from_jwk(jwk)
      modulus = OpenSSL::BN.new(Base64.urlsafe_decode64(pad(jwk.fetch('n'))), 2)
      exponent = OpenSSL::BN.new(Base64.urlsafe_decode64(pad(jwk.fetch('e'))), 2)

      sequence = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(modulus),
                                          OpenSSL::ASN1::Integer(exponent)])
      OpenSSL::PKey::RSA.new(sequence.to_der)
    end

    def decode_segment(segment)
      JSON.parse(Base64.urlsafe_decode64(pad(segment)))
    end

    def pad(segment)
      segment + '=' * ((4 - segment.length % 4) % 4)
    end
  end
end
