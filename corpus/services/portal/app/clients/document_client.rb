# frozen_string_literal: true
#
# Accès aux pièces jointes d'un dossier : connaissement, facture commerciale, preuve de livraison,
# photo d'avarie. Le portail n'affiche jamais les octets lui-même — il demande à document-service
# une URL signée de quinze minutes et laisse le navigateur aller la chercher, ce qui garde le
# portail hors du chemin des gros fichiers.

require 'date'

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class DocumentClient < BaseClient
      def self.service_name
        'document-service'
      end

      # Valeurs du CHECK sur platform.documents.kind (§2.8). Le portail les affiche toutes mais
      # n'en dépose aucune : le dépôt vient de inspector-android, de customs-service ou du pont
      # PHP, jamais d'un écran d'exploitation.
      KIND_FR = {
        'bill_of_lading' => 'connaissement',
        'commercial_invoice' => 'facture commerciale',
        'packing_list' => 'liste de colisage',
        'certificate_of_origin' => "certificat d'origine",
        'proof_of_delivery' => 'preuve de livraison',
        'damage_photo' => "photo d'avarie",
        'insurance_certificate' => "attestation d'assurance",
        'customs_decision' => 'décision douanière',
        'rendered_invoice' => 'facture émise (PDF)',
        'credit_note' => 'avoir'
      }.freeze

      # Les six valeurs insérées dans platform.document_owner_types. La colonne owner_type porte
      # une clé étrangère vers cette table de vocabulaire, donc toute autre valeur est refusée
      # par document-service à l'écriture — et ne remonte donc jamais rien en lecture.
      OWNER_TYPES = %w[shipment container scan declaration invoice carrier].freeze

      def for_owner(owner_type:, owner_id:, kind: nil, limit: 50)
        raise ArgumentError, "owner_type inconnu : #{owner_type}" unless OWNER_TYPES.include?(owner_type)

        paginate(
          '/v1/documents',
          { owner_type: owner_type, owner_id: owner_id, kind: kind },
          max_items: limit
        )
      end

      def metadata(document_id)
        PrefixedUlid.assert!(document_id, :document)
        get("/v1/documents/#{document_id}")
      end

      # URL de téléchargement à durée de vie courte (OF_DOCUMENT_SIGNED_URL_TTL_SECONDS, 900 s).
      # Elle n'est jamais mise en cache par le portail ni journalisée : une URL signée dans un
      # journal est un document lisible par quiconque lit les journaux.
      def signed_url(document_id, disposition: 'inline')
        PrefixedUlid.assert!(document_id, :document)
        response = post("/v1/documents/#{document_id}/signed-url", { disposition: disposition })
        response.fetch('url')
      end

      # Regroupe les doublons de contenu. La contrainte UNIQUE (tenant_id, sha256, owner_type,
      # owner_id) n'empêche pas la même facture commerciale d'exister deux fois si elle est
      # rattachée une fois à la déclaration et une fois à la facture : c'est exactement le losange
      # B de §1.2, où customs-service et billing-service déposent le même PDF chacun de son côté.
      # L'écran le montre comme une seule pièce avec deux rattachements.
      def group_by_content(documents)
        documents.group_by { |doc| doc['sha256'] }.map do |sha256, group|
          {
            sha256: sha256,
            kind: group.first['kind'],
            byte_size: group.first['byte_size'],
            mime_type: group.first['mime_type'],
            attachments: group.map { |doc| { document_id: doc['document_id'],
                                             owner_type: doc['owner_type'],
                                             owner_id: doc['owner_id'] } },
            uploaded_at: group.map { |doc| doc['uploaded_at'] }.min
          }
        end
      end

      # Une pièce douanière est conservée dix ans (OF_CUSTOMS_RETENTION_YEARS remplit
      # platform.documents.retained_until). document-service refuse la suppression tant que la
      # date n'est pas passée ; le portail grise le bouton plutôt que de récolter le 409.
      def deletable?(document)
        return true if document['retained_until'].nil?

        Date.parse(document['retained_until']) < Date.today
      rescue ArgumentError
        false
      end

      def kind_label(kind)
        KIND_FR.fetch(kind, kind)
      end
    end
  end
end
