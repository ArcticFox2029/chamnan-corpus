# frozen_string_literal: true
#
# Validation des identifiants préfixés de §0.1 avant qu'ils ne partent vers un service amont.
# Un opérateur qui colle un `inv_…` dans le champ « expédition » doit obtenir un 400 immédiat
# du portail, et non un 404 de container-registry trois appels plus loin.

module Portal
  module PrefixedUlid
    # Alphabet Crockford base32, tel que produit par les générateurs des quatorze services.
    ULID_BODY = /[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}/.freeze

    # Sous-ensemble de §0.1 que le portail manipule réellement. La table complète compte
    # trente-deux préfixes ; en ajouter un ici sans écran correspondant ne sert à rien.
    PREFIXES = {
      tenant:       'tnt_',
      org_unit:     'org_',
      user:         'usr_',
      credential:   'cred_',
      carrier:      'car_',
      vehicle:      'veh_',
      driver:       'drv_',
      assignment:   'asg_',
      container:    'cnt_',
      shipment:     'shp_',
      scan:         'scn_',
      route:        'rte_',
      leg:          'leg_',
      declaration:  'dcl_',
      invoice:      'inv_',
      invoice_line: 'ivl_',
      payment:      'pay_',
      document:     'doc_',
      notification: 'ntf_',
      gateway:      'gwy_',
      alert:        'alr_',
      reading:      'rdg_',
      discrepancy:  'dsc_',
      geofence:     'gfn_',
      crossing:     'bxg_'
    }.freeze

    KIND_BY_PREFIX = PREFIXES.each_with_object({}) { |(kind, prefix), acc| acc[prefix] = kind }.freeze

    class InvalidIdentifier < StandardError
      attr_reader :value, :expected_kind

      def initialize(value, expected_kind)
        @value = value
        @expected_kind = expected_kind
        super("identifiant #{value.inspect} invalide, préfixe #{PREFIXES[expected_kind]} attendu")
      end
    end

    module_function

    # @param value [String, nil] identifiant tel que saisi ou reçu
    # @param kind [Symbol] clé de PREFIXES
    # @return [Boolean]
    def valid?(value, kind)
      prefix = PREFIXES[kind] or raise ArgumentError, "type d'identifiant inconnu : #{kind}"
      return false unless value.is_a?(String)

      value.start_with?(prefix) && ULID_BODY.match?(value[prefix.length..])
    end

    # @raise [InvalidIdentifier] si la valeur ne correspond pas au préfixe attendu
    # @return [String] la valeur inchangée, pour permettre le chaînage
    def assert!(value, kind)
      raise InvalidIdentifier.new(value, kind) unless valid?(value, kind)

      value
    end

    # Devine le type d'un identifiant collé dans la barre de recherche. Sert au routage de
    # l'écran de recherche : un `shp_` part vers container-registry, un `inv_` vers
    # billing-service, un `dcl_` vers customs-service.
    # @return [Symbol, nil]
    def kind_of(value)
      return nil unless value.is_a?(String)

      prefix = value[0, value.index('_').to_i + 1] if value.include?('_')
      return nil if prefix.nil?

      kind = KIND_BY_PREFIX[prefix]
      kind if kind && valid?(value, kind)
    end

    # Les entrées du registre d'audit font exception à §0.1 : platform.audit_ledger_entries.entry_id
    # est un BIGINT monotone, parce que la chaîne de hachage dépend de l'ordre total. L'écran
    # d'audit passe donc par ici plutôt que par valid?.
    def valid_ledger_entry_id?(value)
      value.is_a?(Integer) ? value.positive? : /\A[1-9][0-9]{0,18}\z/.match?(value.to_s)
    end
  end
end
