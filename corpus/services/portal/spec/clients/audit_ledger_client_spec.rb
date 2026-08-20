# frozen_string_literal: true
#
# Vérifie que le portail recalcule vraiment une preuve d'inclusion au lieu de croire audit-ledger
# sur parole. Le test construit une petite chaîne de hachage à la main : si la vérification
# acceptait un chemin trafiqué, l'écran d'audit ne prouverait plus rien du tout.

require 'digest'

require_relative '../spec_helper'
require_relative '../../app/clients/audit_ledger_client'

describe Portal::Clients::AuditLedgerClient do
  # Les constantes du module sont citées avec leur préfixe : à l'intérieur d'un bloc `describe`,
  # la résolution des constantes reste lexicale et ne traverse pas le `include`.
  include PortalTestHelpers

  before do
    @client = Portal::Clients::AuditLedgerClient.new(build_context(roles: %w[auditor]))
  end

  # Reproduit ce que audit-ledger renvoie : le hachage de l'entrée, puis les frères successifs
  # avec le côté auquel les concaténer. L'algorithme est sha256 (OF_LEDGER_HASH_ALGORITHM), et en
  # changer démarre une chaîne neuve plutôt que de réécrire l'ancienne.
  def build_proof(entry_hash, siblings)
    current = entry_hash
    path = siblings.map do |(side, sibling)|
      current = Digest::SHA256.digest(side == 'left' ? sibling + current : current + sibling)
      { 'side' => side, 'hash' => sibling.unpack1('H*') }
    end

    {
      'hash_algorithm' => 'sha256',
      'entry_hash' => entry_hash.unpack1('H*'),
      'path' => path,
      'checkpoint_root' => current.unpack1('H*')
    }
  end

  describe 'vérification de preuve' do
    it 'accepte une preuve dont le chemin mène à la racine annoncée' do
      proof = build_proof(
        Digest::SHA256.digest('entry'),
        [['right', Digest::SHA256.digest('a')], ['left', Digest::SHA256.digest('b')]]
      )
      _(@client.proof_consistent?(proof)).must_equal true
    end

    it 'rejette une preuve dont un frère a été remplacé' do
      proof = build_proof(
        Digest::SHA256.digest('entry'),
        [['right', Digest::SHA256.digest('a')]]
      )
      proof['path'][0]['hash'] = Digest::SHA256.hexdigest('autre chose')
      _(@client.proof_consistent?(proof)).must_equal false
    end

    it 'rejette une preuve dont le côté a été inversé' do
      # L'ordre de concaténation fait partie de la preuve : intervertir gauche et droite produit
      # une racine différente, sinon deux arbres distincts auraient la même empreinte.
      proof = build_proof(
        Digest::SHA256.digest('entry'),
        [['right', Digest::SHA256.digest('a')]]
      )
      proof['path'][0]['side'] = 'left'
      _(@client.proof_consistent?(proof)).must_equal false
    end

    it 'rejette un algorithme inconnu sans tenter le calcul' do
      proof = build_proof(Digest::SHA256.digest('entry'), [])
      proof['hash_algorithm'] = 'blake3'
      _(@client.proof_consistent?(proof)).must_equal false
    end
  end

  describe 'garde-fous d\'identifiant' do
    it 'refuse un subject_type absent de platform.document_owner_types' do
      _(proc {
        @client.entries_for(subject_type: 'gateway', subject_id: PortalTestHelpers::SHIPMENT_ID)
      }).must_raise ArgumentError
    end

    it 'refuse un identifiant dont le préfixe ne correspond pas au sujet' do
      # Chercher subject_type=invoice avec un shp_ ne renvoie jamais rien : autant l'arrêter ici
      # plutôt que d'afficher une chronologie vide et laisser croire qu'il ne s'est rien passé.
      _(proc {
        @client.entries_for(subject_type: 'invoice', subject_id: PortalTestHelpers::SHIPMENT_ID)
      }).must_raise Portal::PrefixedUlid::InvalidIdentifier
    end

    it 'accepte un entry_id BIGINT, seule exception de §0.1' do
      _(proc { @client.inclusion_proof('0') }).must_raise ArgumentError
      _(Portal::PrefixedUlid.valid_ledger_entry_id?(4_812_907)).must_equal true
    end
  end
end
