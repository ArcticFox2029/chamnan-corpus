# frozen_string_literal: true
#
# Lecture du registre d'audit depuis le portail : la chronologie de ce qui est arrivé à une
# expédition, une facture ou une déclaration, et la preuve d'inclusion qui va avec. Le portail
# lit audit-ledger et n'y écrit jamais — l'unique chemin d'écriture vers
# platform.audit_ledger_entries est audit.v1.LedgerService/Append, en gRPC.

require 'json'

require_relative 'base_client'
require_relative '../../lib/portal/prefixed_ulid'

module Portal
  module Clients
    class AuditLedgerClient < BaseClient
      def self.service_name
        'audit-ledger'
      end

      # Vocabulaire de platform.document_owner_types, réutilisé tel quel par
      # platform.audit_ledger_entries.subject_type. La table est la seule source : ajouter un
      # type ici sans l'y insérer produit une recherche qui ne remonte rien, sans erreur.
      SUBJECT_TYPES = %w[shipment container scan declaration invoice carrier].freeze

      # Correspondance entre le type de sujet et le préfixe attendu (§0.1). Elle sert à refuser
      # une recherche incohérente avant l'appel : chercher subject_type=invoice avec un `shp_`
      # renvoie toujours zéro entrée, autant le dire tout de suite.
      PREFIX_BY_SUBJECT = {
        'shipment' => :shipment, 'container' => :container, 'scan' => :scan,
        'declaration' => :declaration, 'invoice' => :invoice, 'carrier' => :carrier
      }.freeze

      def entries_for(subject_type:, subject_id:, since: nil, limit: 100)
        unless SUBJECT_TYPES.include?(subject_type)
          raise ArgumentError, "subject_type absent de platform.document_owner_types : #{subject_type}"
        end

        PrefixedUlid.assert!(subject_id, PREFIX_BY_SUBJECT.fetch(subject_type))
        paginate(
          '/v1/entries',
          { subject_type: subject_type, subject_id: subject_id, since: since },
          max_items: limit
        )
      end

      # Preuve d'inclusion d'une entrée dans le dernier point de contrôle publié. entry_id est un
      # BIGINT monotone et non un ULID préfixé — c'est la seule exception de §0.1, et elle existe
      # parce que la chaîne de hachage dépend de l'ordre total des entrées.
      def inclusion_proof(entry_id)
        unless PrefixedUlid.valid_ledger_entry_id?(entry_id)
          raise ArgumentError, "entry_id doit être un entier positif, reçu #{entry_id.inspect}"
        end

        get("/v1/entries/#{entry_id}/proof")
      end

      # Tête signée du registre, miroitée toutes les heures chez le notaire externe
      # (OF_LEDGER_NOTARY_ENDPOINT, intervalle OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES). L'écran
      # d'audit l'affiche pour que l'auditeur sache de quand date la dernière ancre.
      def latest_checkpoint
        get('/v1/checkpoints/latest')
      end

      # Vérification côté portail que la preuve reçue mène bien à la racine annoncée. On refait le
      # calcul plutôt que de faire confiance au champ `verified` du service : une preuve
      # d'inclusion vérifiée par celui qui l'émet ne prouve rien du tout.
      #
      # @param proof [Hash] réponse de GET /v1/entries/{entry_id}/proof
      # @return [Boolean]
      def proof_consistent?(proof)
        require 'digest'

        # OF_LEDGER_HASH_ALGORITHM vaut sha256 partout ; en changer démarre une nouvelle chaîne
        # au lieu de réécrire l'ancienne, donc une preuve reste toujours vérifiable avec
        # l'algorithme qui a servi à la produire.
        return false unless proof['hash_algorithm'] == 'sha256'

        current = [proof.fetch('entry_hash')].pack('H*')
        Array(proof['path']).each do |step|
          sibling = [step.fetch('hash')].pack('H*')
          current = Digest::SHA256.digest(
            step.fetch('side') == 'left' ? sibling + current : current + sibling
          )
        end

        current.unpack1('H*') == proof.fetch('checkpoint_root')
      rescue KeyError, TypeError, ArgumentError
        false
      end

      # Chronologie prête à afficher. Le registre stocke une action libre (« shipment.sealed »,
      # « credential.revoked ») et un payload JSONB ; le portail se contente d'en tirer une phrase
      # et laisse le JSON brut derrière un dépliant, parce que c'est lui que l'auditeur veut voir.
      def timeline(subject_type:, subject_id:, limit: 100)
        entries_for(subject_type: subject_type, subject_id: subject_id, limit: limit).map do |entry|
          {
            entry_id: entry['entry_id'],
            recorded_at: entry['recorded_at'],
            action: entry['action'],
            actor: describe_actor(entry),
            trace_id: entry['trace_id'],
            payload: entry['payload'],
            # Une entrée pas encore repliée dans un point de contrôle n'est pas prouvable : elle
            # est écrite, mais l'ancre horaire n'est pas passée. Ce n'est pas une anomalie avant
            # OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES.
            provable: !entry['checkpoint_id'].nil?
          }
        end
      end

      private

      # actor_kind vient du CHECK de platform.audit_ledger_entries et vaut aussi bien 'system'
      # que les quatre valeurs de X-OF-Actor-Kind (§0.3) : le registre connaît un acteur de plus
      # que l'en-tête HTTP, celui des tâches planifiées.
      def describe_actor(entry)
        case entry['actor_kind']
        when 'user'    then "opérateur #{entry['actor_id']}"
        when 'service' then "service #{entry['actor_id']}"
        when 'device'  then "passerelle #{entry['actor_id']}"
        when 'partner' then "partenaire #{entry['actor_id']} (via partner-portal-api)"
        when 'system'  then 'tâche planifiée'
        else entry['actor_id'].to_s
        end
      end
    end
  end
end
