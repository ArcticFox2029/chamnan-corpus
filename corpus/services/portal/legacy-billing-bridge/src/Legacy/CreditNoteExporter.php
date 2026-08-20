<?php

/**
 * Restitution des avoirs vers le mainframe comptable : pour chaque facture passée en `void`, on
 * fabrique l'enregistrement fixe-largeur « AV » que l'ancien ERP sait relire, en y joignant la
 * référence de la pièce déposée chez document-service. Sans ce chemin, une annulation faite dans
 * billing-service resterait invisible de la comptabilité, qui continuerait à relancer le client.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Legacy
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Legacy;

use DateTimeImmutable;
use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Billing\UpstreamFailure;

final class CreditNoteExporter
{
    /**
     * Largeur de l'enregistrement « AV » attendu par le lot de nuit du mainframe. Le compte est
     * vérifié à l'écriture : une ligne d'un octet de trop décale toute la suite du fichier, et le
     * mainframe n'émet aucune erreur — il range simplement des montants dans les mauvaises colonnes.
     */
    private const RECORD_WIDTH = 200;

    /**
     * Les deux seuls états d'une facture qui produisent un avoir. `written_off` n'en produit
     * pas : une créance abandonnée reste due au sens comptable, elle sort du recouvrement mais
     * pas du grand livre, et l'ancien ERP a sa propre écriture pour cela.
     *
     * @var list<string>
     */
    private const EXPORTABLE_STATUSES = ['void'];

    /**
     * Le pont ne reçoit pas d'URL de document-service ici, et c'est délibéré : une URL signée vit
     * quinze minutes (OF_DOCUMENT_SIGNED_URL_TTL_SECONDS) et le fichier déposé cette nuit sera lu
     * demain matin. Le fichier ne porte donc que l'identifiant `doc_` de l'avoir ; quand le
     * mainframe veut les octets, il repasse par la route /facturation/{id}/pdf de LegacyRouter,
     * qui redemande une URL fraîche à ce moment-là.
     */
    public function __construct(private readonly BillingServiceClient $billing)
    {
    }

    /**
     * Construit le fichier complet pour une liste d'identifiants de factures. Les factures
     * illisibles sont écartées avec une trace : un export partiel vaut mieux qu'un fichier
     * absent, parce que le lot de nuit du mainframe ne repasse qu'une fois par vingt-quatre heures.
     *
     * @param list<string> $invoiceIds
     * @return array{content: string, exported: int, skipped: list<array{invoice_id: string, reason: string}>}
     */
    public function export(array $invoiceIds, string $traceId): array
    {
        $records = [];
        $skipped = [];

        foreach ($invoiceIds as $invoiceId) {
            try {
                $invoice = $this->billing->fetchInvoice($invoiceId, $traceId);
            } catch (UpstreamFailure $failure) {
                $skipped[] = ['invoice_id' => $invoiceId, 'reason' => $failure->code()];
                continue;
            }

            $status = (string) ($invoice['status'] ?? '');
            if (!in_array($status, self::EXPORTABLE_STATUSES, true)) {
                $skipped[] = ['invoice_id' => $invoiceId, 'reason' => 'status_' . $status];
                continue;
            }

            $documentId = $this->creditNoteDocumentId($invoice);
            if ($documentId === null) {
                // billing-service refuse une annulation sans avoir déposé : trouver une facture
                // `void` sans document signifie une reprise de données manuelle, jamais le
                // fonctionnement normal de POST /v1/invoices/{invoice_id}/void.
                $skipped[] = ['invoice_id' => $invoiceId, 'reason' => 'credit_note_document_missing'];
                continue;
            }

            $records[] = $this->buildRecord($invoice, $documentId);
        }

        return [
            'content' => implode("\r\n", $records) . "\r\n",
            'exported' => count($records),
            'skipped' => $skipped,
        ];
    }

    /**
     * L'avoir est une pièce de platform.documents rattachée à la facture : owner_type `invoice`,
     * kind `credit_note`. La liste arrive inlinée dans la réponse de billing-service, qui
     * l'obtient lui-même de document-service — la passerelle ne fait pas ce second appel.
     *
     * @param array<string, mixed> $invoice
     */
    private function creditNoteDocumentId(array $invoice): ?string
    {
        foreach ($invoice['documents'] ?? [] as $document) {
            if (($document['kind'] ?? null) === 'credit_note') {
                return (string) $document['document_id'];
            }
        }

        return null;
    }

    /**
     * Un enregistrement « AV ». Les montants repartent en unités majeures avec deux décimales
     * implicites, parce que c'est ce que le mainframe sait lire — la conversion depuis les unités
     * mineures de §0.2 est faite ici et nulle part ailleurs dans ce fichier.
     *
     * @param array<string, mixed> $invoice
     */
    private function buildRecord(array $invoice, string $documentId): string
    {
        $issuedAt = new DateTimeImmutable((string) ($invoice['issued_at'] ?? 'now'));

        $record = 'AV'
            . str_pad((string) ($invoice['invoice_number'] ?? ''), 24)
            . str_pad((string) $invoice['invoice_id'], 30)
            . str_pad((string) $invoice['shipment_id'], 30)
            . str_pad((string) $invoice['currency'], 3)
            . str_pad($this->amountField((int) $invoice['total_minor']), 15, '0', STR_PAD_LEFT)
            . $issuedAt->format('Ymd')
            . str_pad($documentId, 30);

        $record = str_pad($record, self::RECORD_WIDTH);

        if (strlen($record) !== self::RECORD_WIDTH) {
            // Un identifiant plus long que sa colonne : c'est arrivé quand le champ expédition
            // faisait encore 24 octets, avant l'élargissement de mars 2024. On échoue bruyamment
            // plutôt que de tronquer un identifiant préfixé de §0.1 en silence.
            throw new UpstreamFailure(
                'legacy_record_overflow',
                500,
                sprintf('enregistrement AV de %d octets au lieu de %d', strlen($record), self::RECORD_WIDTH),
            );
        }

        return $record;
    }

    /**
     * Le mainframe attend un montant sans séparateur décimal, signe en dernière position quand il
     * est négatif. Un avoir est toujours porté positif dans ce fichier : c'est le type
     * d'enregistrement « AV » qui en fait un crédit, pas le signe.
     */
    private function amountField(int $totalMinor): string
    {
        return (string) abs($totalMinor);
    }
}
