# frozen_string_literal: true
#
# Garde de résidence des données (§7 règle 7) appliquée à l'affichage. Un pod du portail déployé
# en eu-west n'a pas le droit de montrer, de mettre en cache ni de journaliser une ligne étiquetée
# latam-br : ce fichier est le point unique où cette règle est vérifiée, juste avant que la donnée
# n'atteigne un gabarit ERB.

module Portal
  module Residency
    # Une violation n'est jamais un incident réseau : elle signifie qu'un service amont a répondu
    # pour une région qu'il n'aurait pas dû servir, ou que l'ingress a routé la requête au
    # mauvais cluster. Dans les deux cas la page s'arrête ici.
    class Violation < StandardError
      attr_reader :expected_region, :observed_region, :subject_id

      def initialize(expected_region:, observed_region:, subject_id: nil)
        @expected_region = expected_region
        @observed_region = observed_region
        @subject_id = subject_id
        super(
          "donnée de région #{observed_region} rencontrée dans un pod #{expected_region}" \
          "#{subject_id ? " (#{subject_id})" : ''}"
        )
      end
    end

    # Libellés d'affichage. Les codes eux-mêmes viennent de Portal::REGION_CODES, qui reproduit la
    # liste fermée de §0.6 ; cette table ne fait que les habiller et doit rester exactement aussi
    # longue, sans quoi une région existante s'affiche comme un code brut.
    LABELS = {
      'eu-west' => 'Europe de l\'Ouest',
      'eu-central' => 'Europe centrale',
      'na-east' => 'Amérique du Nord — Est',
      'na-west' => 'Amérique du Nord — Ouest',
      'apac-sg' => 'Asie-Pacifique — Singapour',
      'apac-jp' => 'Asie-Pacifique — Japon',
      'latam-br' => 'Amérique latine — Brésil',
      'mea-ae' => 'Moyen-Orient — Émirats'
    }.freeze

    module_function

    def label(region_code)
      LABELS.fetch(region_code, region_code)
    end

    def local_region
      Portal.config.region_code
    end

    # Toute ligne portant `region_code` passe par ici. Les tables concernées sont nommément
    # freight.shipments, freight.facilities, platform.documents et telemetry.telemetry_readings —
    # cette dernière étant partitionnée par LIST(region_code) précisément pour que la résidence
    # soit une propriété du stockage et pas seulement une convention applicative.
    #
    # @raise [Violation] si la ligne appartient à une autre région
    def assert_local!(row, subject_key = nil)
      return row if row.nil?

      observed = row['region_code'] || row[:region_code]
      return row if observed.nil? || observed == local_region

      raise Violation.new(
        expected_region: local_region,
        observed_region: observed,
        subject_id: subject_key && (row[subject_key] || row[subject_key.to_s])
      )
    end

    # Variante tolérante pour les listes : on écarte silencieusement les lignes étrangères plutôt
    # que de vider tout l'écran. Le compteur nourrit une métrique parce qu'une occurrence est
    # anodine (réplication en cours) et qu'une série continue ne l'est pas du tout.
    def filter_local(rows)
      kept, dropped = Array(rows).partition do |row|
        observed = row['region_code'] || row[:region_code]
        observed.nil? || observed == local_region
      end

      unless dropped.empty?
        Portal.metrics.increment(
          'portal_residency_rows_dropped_total', { region: local_region }, by: dropped.size
        )
        Portal.logger.warn(
          msg: 'lignes hors région écartées avant affichage',
          expected_region: local_region,
          dropped: dropped.size,
          observed_regions: dropped.map { |row| row['region_code'] }.uniq
        )
      end

      kept
    end

    # Un lien vers l'écran équivalent dans le cluster propriétaire de la donnée. C'est la seule
    # réponse acceptable à une violation : le portail ne va pas chercher la donnée par-dessus la
    # frontière, il envoie l'opérateur là où elle a le droit d'être lue.
    def cross_region_url(region_code, path)
      raise ArgumentError, "région inconnue : #{region_code}" unless Portal::REGION_CODES.include?(region_code)

      "https://portal.#{region_code}.orbitalfreight.internal#{path}"
    end
  end
end
