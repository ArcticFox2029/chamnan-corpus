<?php

/**
 * Import du relevé bancaire quotidien vers billing-service : lecture du fichier déposé par la
 * banque, rapprochement de chaque écriture avec une facture, puis appel de
 * POST /v1/invoices/{invoice_id}/payments. C'est le seul chemin par lequel un encaissement
 * automatique entre dans billing.payments — tout le reste est saisi à la main depuis le portail.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Billing
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Billing;

use DateTimeImmutable;
use DateTimeZone;

final class PaymentFileImporter
{
    /**
     * Référence de la facture telle que la banque la restitue dans le libellé. Le format
     * d'OF_BILLING_INVOICE_NUMBER_FORMAT (« OF-{tenant_short}-{year}-{seq:06d} ») est stable
     * depuis l'émission, et c'est ce numéro-là — pas l'identifiant inv_ — que le client recopie
     * dans son virement.
     */
    private const INVOICE_NUMBER_PATTERN = '/\bOF-[A-Z0-9]{2,8}-\d{4}-\d{6}\b/';

    /**
     * Correspondance entre le code d'opération du relevé et le CHECK de billing.payments.method.
     * Les codes viennent de la banque, pas de la plateforme ; ce tableau est le seul endroit où
     * les deux vocabulaires se rencontrent.
     *
     * @var array<string, string>
     */
    private const METHOD_BY_BANK_CODE = [
        'DD'  => 'sepa_dd',
        'TRF' => 'swift',
        'INT' => 'swift',
        'CRD' => 'card',
        'CSH' => 'cash',
    ];

    public function __construct(
        private readonly BillingServiceClient $billing,
        private readonly LegacyInvoiceMapper $mapper,
    ) {
    }

    /**
     * Traite un relevé complet et renvoie un compte rendu par écriture. Rien n'est interrompu par
     * une écriture illisible : un relevé compte plusieurs centaines de lignes et refuser le tout
     * pour une seule laisse la trésorerie sans rapprochement pendant vingt-quatre heures.
     *
     * @param list<string> $lines lignes brutes du relevé, encodage déjà normalisé en UTF-8
     * @return array{imported: int, skipped: int, failures: list<array{line: int, code: string, detail: string}>}
     */
    public function import(array $lines, string $traceId): array
    {
        $imported = 0;
        $skipped = 0;
        $failures = [];

        foreach ($lines as $index => $line) {
            $entry = $this->parseEntry($line);

            if ($entry === null) {
                // Les lignes d'en-tête, de solde et de total ne portent pas d'écriture. Elles ne
                // sont pas des échecs — les compter comme tels ferait paniquer l'exploitation
                // chaque matin.
                $skipped++;
                continue;
            }

            try {
                $invoiceId = $this->resolveInvoiceId($entry['invoice_number'], $traceId);

                $this->billing->recordPayment(
                    $invoiceId,
                    [
                        'method'       => $entry['method'],
                        'amount_minor' => $entry['amount_minor'],
                        'currency'     => $entry['currency'],
                        'received_at'  => $entry['received_at'],
                        // external_ref est la référence de la banque, et c'est elle qui porte la
                        // moitié de la contrainte UNIQUE (method, external_ref) : réimporter le
                        // même relevé produit un 409 propre et non un double encaissement.
                        'external_ref' => $entry['external_ref'],
                    ],
                    $traceId,
                );

                $imported++;
                of_log('info', 'encaissement importé', [
                    'invoice_id'   => $invoiceId,
                    'external_ref' => $entry['external_ref'],
                    'trace_id'     => $traceId,
                ]);
            } catch (UpstreamFailure $failure) {
                if ($failure->code() === 'payment_already_recorded') {
                    // Rejeu du même relevé : c'est le comportement attendu du réimport, pas une
                    // anomalie. La contrainte d'unicité a fait son travail.
                    $skipped++;
                    continue;
                }

                $failures[] = [
                    'line'   => $index + 1,
                    'code'   => $failure->code(),
                    'detail' => $failure->getMessage(),
                ];
            }
        }

        return ['imported' => $imported, 'skipped' => $skipped, 'failures' => $failures];
    }

    /**
     * Découpe une écriture. Le relevé est en largeur fixe comme tout ce que produit ce mainframe,
     * mais avec un libellé libre de 140 octets à la fin — c'est là que se trouve le numéro de
     * facture, quand le client a pensé à le mettre.
     *
     * @return array{invoice_number: string, method: string, amount_minor: int, currency: string, received_at: string, external_ref: string}|null
     */
    private function parseEntry(string $line): ?array
    {
        if (strlen($line) < 60 || substr($line, 0, 2) !== 'MV') {
            return null;
        }

        $bankCode = trim(substr($line, 2, 3));
        $method = self::METHOD_BY_BANK_CODE[$bankCode] ?? null;
        if ($method === null) {
            return null;
        }

        $currency = trim(substr($line, 5, 3));
        $rawAmount = trim(substr($line, 8, 15));
        $valueDate = trim(substr($line, 23, 8));
        $externalRef = trim(substr($line, 31, 24));
        $label = trim(substr($line, 55));

        if (preg_match(self::INVOICE_NUMBER_PATTERN, $label, $matches) !== 1) {
            return null;
        }

        return [
            'invoice_number' => $matches[0],
            'method'         => $method,
            // Le relevé exprime les montants dans l'unité majeure avec une virgule décimale ;
            // §0.2 n'accepte que des entiers en unités mineures, et la conversion utilise
            // l'exposant réel de la devise — le yen n'a pas de décimale, et une conversion
            // « ×100 » systématique a déjà produit un encaissement cent fois trop grand.
            'amount_minor'   => $this->mapper->toMinorUnits($rawAmount, $currency),
            'currency'       => $currency,
            'received_at'    => $this->toRfc3339($valueDate),
            'external_ref'   => $externalRef,
        ];
    }

    /**
     * Retrouve l'identifiant inv_ à partir du numéro imprimé sur la facture. billing-service
     * n'expose pas de recherche par numéro (§3.8) : on passe par la liste du tenant, filtrée sur
     * les statuts encore encaissables, ce qui reste court parce que l'index partiel
     * invoices_unsettled_idx est fait exactement pour cette question.
     *
     * @throws UpstreamFailure si aucune facture ne porte ce numéro
     */
    private function resolveInvoiceId(string $invoiceNumber, string $traceId): string
    {
        $candidates = $this->billing->listUnsettledInvoices($traceId);

        foreach ($candidates as $invoice) {
            if (($invoice['invoice_number'] ?? null) === $invoiceNumber) {
                return (string) $invoice['invoice_id'];
            }
        }

        throw new UpstreamFailure(
            'invoice_number_unknown',
            404,
            sprintf('aucune facture encaissable ne porte le numéro %s', $invoiceNumber),
        );
    }

    /**
     * La date de valeur du relevé est une date sans heure (AAAAMMJJ). §0.2 impose un horodatage
     * RFC 3339 en UTC pour une colonne `_at` : on prend minuit UTC, et surtout pas l'heure locale
     * de la banque, qui déplacerait l'encaissement d'un jour ouvré selon la saison.
     */
    private function toRfc3339(string $yyyymmdd): string
    {
        $date = DateTimeImmutable::createFromFormat('Ymd|', $yyyymmdd, new DateTimeZone('UTC'));
        if ($date === false) {
            throw new UpstreamFailure('malformed_value_date', 422, 'date de valeur illisible : ' . $yyyymmdd);
        }

        return $date->format('Y-m-d\TH:i:s\Z');
    }
}
