# frozen_string_literal: true
#
# Catalogue local des dix-huit événements de §4 : nom, topic, producteur, et la phrase française
# que l'astreinte lit à l'écran. Le portail ne consomme aucun topic — il n'a ni groupe de
# consommateurs ni table de déduplication sur event_id — mais il doit nommer ces événements
# correctement dans l'éditeur de préférences de notification et dans les explications d'écran.

module Portal
  module EventCatalogue
    # Les six topics de §4 avec leur rétention. Elle est affichée telle quelle dans l'écran
    # d'explication : « cette alerte a sept jours, l'événement qui l'a produite n'existe plus ».
    TOPICS = {
      'of.identity.v1'  => { partitions: 12, retention_days: 30 },
      'of.freight.v1'   => { partitions: 48, retention_days: 14 },
      'of.telemetry.v1' => { partitions: 96, retention_days: 7 },
      'of.customs.v1'   => { partitions: 12, retention_days: 90 },
      'of.billing.v1'   => { partitions: 12, retention_days: 90 },
      'of.platform.v1'  => { partitions: 24, retention_days: 30 }
    }.freeze

    Event = Struct.new(:name, :topic, :producer, :subject_kind, :label, keyword_init: true)

    # Ordre du catalogue calqué sur §4.1 à §4.18, pour qu'une relecture croisée avec SPEC.md se
    # fasse ligne à ligne. `subject_kind` sert à proposer le bon lien depuis la préférence :
    # une préférence sur `billing.invoice.issued` renvoie vers un écran de facture.
    ALL = [
      Event.new(name: 'identity.session.opened', topic: 'of.identity.v1', producer: 'identity-service',
                subject_kind: :user, label: 'ouverture de session'),
      Event.new(name: 'identity.credential.revoked', topic: 'of.identity.v1', producer: 'identity-service',
                subject_kind: :credential, label: "révocation d'une clé d'API"),
      Event.new(name: 'shipment.created', topic: 'of.freight.v1', producer: 'container-registry',
                subject_kind: :shipment, label: "création d'expédition"),
      Event.new(name: 'shipment.scanned', topic: 'of.freight.v1', producer: 'container-registry',
                subject_kind: :shipment, label: 'scan enregistré'),
      Event.new(name: 'shipment.status.changed', topic: 'of.freight.v1', producer: 'container-registry',
                subject_kind: :shipment, label: "changement d'état d'expédition"),
      Event.new(name: 'fleet.assignment.created', topic: 'of.freight.v1', producer: 'fleet-service',
                subject_kind: :assignment, label: 'affectation véhicule et chauffeur'),
      Event.new(name: 'fleet.assignment.released', topic: 'of.freight.v1', producer: 'fleet-service',
                subject_kind: :assignment, label: "fin d'affectation"),
      Event.new(name: 'telemetry.reading.recorded', topic: 'of.telemetry.v1', producer: 'telemetry-ingest',
                subject_kind: :container, label: 'relevé capteur'),
      Event.new(name: 'telemetry.alert.raised', topic: 'of.telemetry.v1', producer: 'telemetry-ingest',
                subject_kind: :alert, label: "levée d'alerte"),
      Event.new(name: 'gateway.heartbeat.missed', topic: 'of.telemetry.v1', producer: 'telemetry-ingest',
                subject_kind: :gateway, label: 'passerelle silencieuse'),
      Event.new(name: 'route.replanned', topic: 'of.platform.v1', producer: 'routing-service',
                subject_kind: :route, label: 'replanification'),
      Event.new(name: 'customs.declaration.filed', topic: 'of.customs.v1', producer: 'customs-service',
                subject_kind: :declaration, label: 'déclaration déposée'),
      Event.new(name: 'customs.declaration.cleared', topic: 'of.customs.v1', producer: 'customs-service',
                subject_kind: :declaration, label: 'mainlevée douanière'),
      Event.new(name: 'billing.invoice.issued', topic: 'of.billing.v1', producer: 'billing-service',
                subject_kind: :invoice, label: 'facture émise'),
      Event.new(name: 'billing.invoice.settled', topic: 'of.billing.v1', producer: 'billing-service',
                subject_kind: :invoice, label: 'facture soldée'),
      Event.new(name: 'document.uploaded', topic: 'of.platform.v1', producer: 'document-service',
                subject_kind: :document, label: 'pièce déposée'),
      Event.new(name: 'reconciliation.discrepancy.opened', topic: 'of.platform.v1',
                producer: 'reconciliation-service', subject_kind: :discrepancy,
                label: 'écart de rapprochement'),
      Event.new(name: 'notification.delivery.failed', topic: 'of.platform.v1',
                producer: 'notification-service', subject_kind: :notification,
                label: "échec d'acheminement d'une notification")
    ].freeze

    BY_NAME = ALL.each_with_object({}) { |event, acc| acc[event.name] = event }.freeze

    # Sous-ensemble proposé dans l'éditeur de préférences. platform.notification_preferences
    # accepte n'importe quel nom de §4 ou l'étoile, mais s'abonner à `telemetry.reading.recorded`
    # reviendrait à recevoir un courriel toutes les vingt lectures et par conteneur.
    SUBSCRIBABLE = %w[
      shipment.status.changed
      telemetry.alert.raised
      gateway.heartbeat.missed
      route.replanned
      customs.declaration.filed
      customs.declaration.cleared
      billing.invoice.issued
      billing.invoice.settled
      reconciliation.discrepancy.opened
    ].freeze

    module_function

    def fetch(name)
      BY_NAME[name]
    end

    def label(name)
      return 'tous les événements' if name == '*'

      BY_NAME.key?(name) ? BY_NAME[name].label : name
    end

    def known?(name)
      name == '*' || BY_NAME.key?(name)
    end

    def retention_days(name)
      event = BY_NAME[name] or return nil

      TOPICS.fetch(event.topic).fetch(:retention_days)
    end

    # Phrase affichée sous un état surprenant. Trois cas reviennent assez souvent pour mériter
    # une explication écrite plutôt qu'un appel à l'équipe plateforme, et tous les trois sont des
    # arêtes cassées par la file de §1.2 : personne n'a « oublié » d'appeler, c'est le contrat.
    ASYNCHRONOUS_EXPLANATIONS = {
      'at_risk' =>
        'container-registry a basculé cette expédition en consommant telemetry.alert.raised ; ' \
        "telemetry-ingest ne l'appelle jamais directement.",
      'duty_paid' =>
        'customs-service apprend le paiement des droits par billing.invoice.settled, et par ' \
        'aucun autre chemin — il ne rappelle jamais billing-service.',
      'on_hold' =>
        'billing-service a posé ce blocage en consommant reconciliation.discrepancy.opened ; ' \
        'hold_reason reprend le champ kind de cet événement.'
    }.freeze

    def explain(state)
      ASYNCHRONOUS_EXPLANATIONS[state]
    end
  end
end
