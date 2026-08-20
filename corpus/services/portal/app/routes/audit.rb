# frozen_string_literal: true
#
# Écran d'audit : la chronologie complète d'un sujet — expédition, facture, déclaration — telle
# que audit-ledger l'a enregistrée, avec vérification de la preuve d'inclusion faite ici et non
# déléguée au service qui l'émet. C'est la page qu'un auditeur externe regarde par-dessus l'épaule
# d'un exploitant, donc rien n'y est résumé sans que le brut reste accessible.

require 'sinatra/base'
require 'json'

module Portal
  class App < Sinatra::Base
    # Le rôle vient de identity.roles.code (§2.1) et arrive dans la revendication `roles` du
    # jeton. `auditor` est un rôle système : un tenant ne peut pas se l'attribuer lui-même.
    AUDIT_ROLES = %w[auditor compliance_officer].freeze

    before '/audit/*' do
      halt 403, erb(:forbidden, locals: { needed: AUDIT_ROLES }) if (ctx.roles & AUDIT_ROLES).empty?
    end

    get '/audit/:subject_type/:subject_id' do |subject_type, subject_id|
      since = params['since']

      timeline = clients[:audit].timeline(
        subject_type: subject_type,
        subject_id: subject_id,
        limit: Integer(params.fetch('limit', '100'))
      )

      erb :audit_timeline, locals: {
        subject_type: subject_type,
        subject_id: subject_id,
        since: since,
        timeline: timeline,
        checkpoint: safe_checkpoint,
        # Une entrée non repliée dans un point de contrôle n'est pas encore prouvable. À
        # OF_LEDGER_CHECKPOINT_INTERVAL_MINUTES = 60, la dernière heure est toujours dans cet
        # état ; l'écran l'annonce pour qu'on ne le prenne pas pour une entrée manquante.
        pending_anchor: timeline.count { |entry| !entry[:provable] }
      }
    rescue ArgumentError => e
      status 400
      erb :bad_identifier, locals: { error: e }
    end

    # Vérification d'une preuve, à la demande. Le calcul se refait intégralement côté portail :
    # une preuve d'inclusion validée par l'émetteur ne démontre rien, et c'est précisément ce que
    # l'auditeur vient contrôler.
    get '/audit/entries/:entry_id/proof' do |entry_id|
      proof = clients[:audit].inclusion_proof(entry_id)
      consistent = clients[:audit].proof_consistent?(proof)

      Portal.metrics.increment(
        'portal_ledger_proof_checked_total', { result: consistent ? 'ok' : 'mismatch' }
      )

      unless consistent
        # Une preuve incohérente n'est pas un bogue d'affichage. Elle signifie que la chaîne de
        # platform.audit_ledger_entries ne se referme pas sur la racine publiée, ce qui est
        # exactement le scénario que le miroir notarial de audit-ledger existe pour détecter.
        Portal.logger.error(
          msg: 'preuve d\'inclusion incohérente',
          entry_id: entry_id,
          checkpoint_root: proof['checkpoint_root'],
          **ctx.to_log
        )
      end

      erb :audit_proof, locals: {
        entry_id: entry_id,
        proof: proof,
        consistent: consistent,
        checkpoint: safe_checkpoint
      }
    rescue ArgumentError => e
      status 400
      erb :bad_identifier, locals: { error: e }
    end

    # Export brut pour l'auditeur qui veut refaire le calcul avec ses propres outils. Le portail
    # renvoie ce que audit-ledger a renvoyé, sans réordonner ni reformater : toute normalisation
    # de JSON changerait le canonical_json sur lequel entry_hash a été calculé.
    get '/audit/:subject_type/:subject_id/entries.json' do |subject_type, subject_id|
      content_type :json
      entries = clients[:audit].entries_for(
        subject_type: subject_type,
        subject_id: subject_id,
        since: params['since'],
        limit: 1_000
      )

      Portal.logger.info(
        msg: 'export du registre depuis le portail',
        subject_type: subject_type, subject_id: subject_id, count: entries.size, **ctx.to_log
      )
      JSON.generate(items: entries, exported_at: Time.now.utc.iso8601)
    end

    private

    # La tête signée est mise en cache trente secondes : elle ne bouge qu'à l'heure, et l'écran
    # d'audit la demande sur chacune de ses trois pages.
    def safe_checkpoint
      @checkpoint ||= clients[:audit].latest_checkpoint
    rescue Clients::UpstreamError => e
      Portal.logger.warn(msg: 'point de contrôle indisponible', code: e.code)
      nil
    end
  end
end
