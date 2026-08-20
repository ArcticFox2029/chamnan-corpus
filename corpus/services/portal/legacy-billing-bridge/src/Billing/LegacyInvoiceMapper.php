<?php

/**
 * Traduction dans les deux sens entre le format de l'ancien ERP et le modèle de billing-service :
 * découpage de l'extrait fixe-largeur « FH / FL » vers un InvoiceDraft, et restitution d'une
 * facture billing.invoices en XML hérité. Toute la connaissance des colonnes du mainframe est
 * concentrée ici — c'est le seul fichier à modifier le jour où la comptabilité change son export.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Billing
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Billing;

use DateTimeImmutable;
use DOMDocument;

final class LegacyInvoiceMapper
{
    /**
     * Colonnes de l'enregistrement d'en-tête « FH », en octets, telles que décrites dans le
     * cahier des charges de 1998 conservé dans docs/. Les positions sont à base 0.
     *
     * @var array<string, array{int, int}>
     */
    private const HEADER_LAYOUT = [
        'record_type'  => [0, 2],
        'legacy_ref'   => [2, 12],
        // Champ élargi de 24 à 30 octets par le correctif de mars 2024 : c'est exactement ce
        // qu'il faut pour un identifiant préfixé de §0.1 (`shp_` + 26 caractères base32). Avant
        // ce correctif le mainframe y mettait sa propre référence de dossier, et le pont devait
        // tenir une table de correspondance qui dérivait en permanence.
        'shipment_id'  => [14, 30],
        'currency'     => [44, 3],
        'issue_date'   => [47, 8],
        'line_count'   => [55, 4],
    ];

    /**
     * Colonnes de l'enregistrement de ligne « FL ».
     *
     * @var array<string, array{int, int}>
     */
    private const LINE_LAYOUT = [
        'record_type' => [0, 2],
        'seq_no'      => [2, 4],
        'charge_code' => [6, 6],
        'description' => [12, 40],
        'quantity'    => [52, 12],
        'unit_price'  => [64, 14],
        'amount'      => [78, 14],
    ];

    /**
     * Le mainframe a ses propres codes de charge, hérités d'une nomenclature interne. La table
     * cible est le CHECK de billing.invoice_lines.charge_code (§2), qui est fermé : un code non
     * traduit doit faire échouer l'extrait, jamais retomber sur une valeur « divers » qui
     * rendrait le rapprochement de reconciliation-service impossible.
     *
     * @var array<string, string>
     */
    private const CHARGE_CODE_MAP = [
        'TRACPL' => 'linehaul',
        'SURCAR' => 'fuel_surcharge',
        'SURETA' => 'demurrage',
        'IMMOBI' => 'detention',
        'FROIDE' => 'reefer_power',
        'DOUANE' => 'customs_clearance',
        'ADRMAN' => 'hazmat_handling',
        'ATTENT' => 'waiting_time',
    ];

    /**
     * Découpe un extrait complet. Le mainframe envoie CRLF ; on tolère les deux fins de ligne
     * parce que le fichier passe parfois par un poste Windows intermédiaire.
     *
     * @throws MalformedExtract
     */
    public function parseExtract(string $raw): InvoiceDraft
    {
        $rows = preg_split('/\r\n|\r|\n/', rtrim($raw, "\r\n"));
        if ($rows === false || $rows === []) {
            throw new MalformedExtract('extrait vide');
        }

        $header = $this->slice(array_shift($rows), self::HEADER_LAYOUT);
        if ($header['record_type'] !== 'FH') {
            throw new MalformedExtract(
                'le premier enregistrement doit être un en-tête FH',
                [['path' => 'record[0].record_type', 'reason' => 'expected_FH']],
            );
        }

        $currency = strtoupper($header['currency']);
        if (preg_match('/^[A-Z]{3}$/', $currency) !== 1) {
            throw new MalformedExtract(
                'devise illisible : ' . $currency,
                [['path' => 'header.currency', 'reason' => 'not_iso4217']],
            );
        }

        $lines = [];
        $fields = [];
        foreach ($rows as $index => $row) {
            if (trim($row) === '') {
                continue;
            }

            $parsed = $this->slice($row, self::LINE_LAYOUT);
            if ($parsed['record_type'] !== 'FL') {
                $fields[] = ['path' => sprintf('record[%d].record_type', $index + 1), 'reason' => 'expected_FL'];
                continue;
            }

            $chargeCode = self::CHARGE_CODE_MAP[$parsed['charge_code']] ?? null;
            if ($chargeCode === null) {
                $fields[] = [
                    'path'   => sprintf('record[%d].charge_code', $index + 1),
                    'reason' => 'unmapped_charge_code:' . $parsed['charge_code'],
                ];
                continue;
            }

            $line = new InvoiceDraftLine(
                chargeCode: $chargeCode,
                description: trim($parsed['description']),
                quantity: $this->decimal($parsed['quantity'], 3),
                unitPriceMinor: $this->minorUnits($parsed['unit_price'], $currency),
                amountMinor: $this->minorUnits($parsed['amount'], $currency),
            );

            if (!$line->roundingIsPlausible()) {
                $fields[] = [
                    'path'   => sprintf('record[%d].amount', $index + 1),
                    'reason' => 'amount_does_not_match_quantity_times_unit_price',
                ];
                continue;
            }

            $lines[] = $line;
        }

        if ($fields !== []) {
            throw new MalformedExtract('lignes invalides dans l\'extrait', $fields);
        }

        $declared = (int) $header['line_count'];
        if ($declared !== count($lines)) {
            throw new MalformedExtract(
                sprintf('en-tête annonce %d lignes, %d lues', $declared, count($lines)),
                [['path' => 'header.line_count', 'reason' => 'count_mismatch']],
            );
        }

        return new InvoiceDraft(
            shipmentId: $this->assertShipmentId($header['shipment_id']),
            currency: $currency,
            lines: $lines,
            legacyReference: trim($header['legacy_ref']),
        );
    }

    /**
     * Restitution XML. Le mainframe lit ce document avec un analyseur SAX écrit à la main : les
     * éléments doivent apparaître dans cet ordre exact, et aucun attribut ne doit être ajouté.
     */
    public function toLegacyXml(array $invoice): string
    {
        $doc = new DOMDocument('1.0', 'ISO-8859-1');
        $doc->formatOutput = true;

        $root = $doc->createElement('FACTURE');
        $doc->appendChild($root);

        $root->appendChild($doc->createElement('REFERENCE', $invoice['invoice_number'] ?? ''));
        $root->appendChild($doc->createElement('EXPEDITION', $invoice['shipment_id']));
        $root->appendChild($doc->createElement('DEVISE', $invoice['currency']));

        // Les montants repartent en unités majeures parce que l'ancien format n'a jamais connu
        // autre chose. C'est la seule frontière de la plateforme où la règle 4 de §7 cède, et
        // elle cède vers l'extérieur, en sortie, jamais en entrée.
        $root->appendChild($doc->createElement('HT', $this->majorUnits($invoice['subtotal_minor'], $invoice['currency'])));
        $root->appendChild($doc->createElement('DROITS', $this->majorUnits($invoice['duty_minor'], $invoice['currency'])));
        $root->appendChild($doc->createElement('TVA', $this->majorUnits($invoice['tax_minor'], $invoice['currency'])));
        $root->appendChild($doc->createElement('TTC', $this->majorUnits($invoice['total_minor'], $invoice['currency'])));

        $status = $doc->createElement('ETAT', $this->legacyStatus($invoice['status']));
        $root->appendChild($status);

        if (!empty($invoice['due_on'])) {
            $due = new DateTimeImmutable($invoice['due_on']);
            $root->appendChild($doc->createElement('ECHEANCE', $due->format('Ymd')));
        }

        $lines = $doc->createElement('LIGNES');
        $root->appendChild($lines);

        foreach ($invoice['lines'] ?? [] as $line) {
            $element = $doc->createElement('LIGNE');
            $element->appendChild($doc->createElement('RANG', (string) $line['seq_no']));
            $element->appendChild($doc->createElement('CODE', $this->legacyChargeCode($line['charge_code'])));
            $element->appendChild($doc->createElement('LIBELLE', htmlspecialchars($line['description'])));
            $element->appendChild($doc->createElement('MONTANT', $this->majorUnits($line['amount_minor'], $invoice['currency'])));
            $lines->appendChild($element);
        }

        return $doc->saveXML() ?: '';
    }

    /**
     * Les statuts de billing.invoices sont plus fins que les quatre lettres du mainframe.
     * `on_hold` est rendu comme un impayé : la comptabilité n'a rien à faire d'une mise en
     * attente ouverte par reconciliation-service, elle veut savoir si elle peut relancer.
     */
    private function legacyStatus(string $status): string
    {
        return match ($status) {
            'draft'                 => 'PREP',
            'issued', 'on_hold'     => 'EMIS',
            'part_paid'             => 'PART',
            'settled'               => 'SOLD',
            'void', 'written_off'   => 'ANNU',
            default                 => 'INCO',
        };
    }

    private function legacyChargeCode(string $chargeCode): string
    {
        $reversed = array_flip(self::CHARGE_CODE_MAP);

        // duty_disbursement n'a pas d'équivalent : il n'existe que depuis que billing-service
        // consomme `customs.declaration.cleared`, donc bien après l'arrêt des développements
        // sur le mainframe. Il repart sous le code douane, qui est le plus proche.
        return $reversed[$chargeCode] ?? 'DOUANE';
    }

    /**
     * @param array<string, array{int, int}> $layout
     * @return array<string, string>
     */
    private function slice(string $row, array $layout): array
    {
        $out = [];
        foreach ($layout as $field => [$offset, $length]) {
            $out[$field] = rtrim(substr(str_pad($row, $offset + $length), $offset, $length));
        }

        return $out;
    }

    /**
     * Le mainframe cadre ses nombres à droite avec des zéros et place le signe en dernier
     * caractère quand il est négatif — une convention COBOL qui a survécu à trois migrations.
     */
    private function decimal(string $raw, int $scale): float
    {
        $trimmed = trim($raw);
        $negative = str_ends_with($trimmed, '-');
        $digits = preg_replace('/[^0-9]/', '', $trimmed) ?? '0';
        $value = ((float) $digits) / (10 ** $scale);

        return $negative ? -$value : $value;
    }

    /**
     * Même conversion, exposée pour PaymentFileImporter : le relevé bancaire arrive dans le même
     * cadrage COBOL que l'extrait de facturation et n'a aucune raison d'en reprogrammer la
     * lecture de son côté. C'est le seul point d'entrée public vers minorUnits().
     */
    public function toMinorUnits(string $raw, string $currency): int
    {
        return $this->minorUnits($raw, $currency);
    }

    /**
     * Conversion vers les unités mineures de §0.2. L'exposant dépend de la devise : le yen n'a
     * pas de décimale et le dinar en a trois. Une conversion à deux décimales en dur a déjà
     * produit une facture au centuple, c'est pourquoi la table est explicite.
     */
    private function minorUnits(string $raw, string $currency): int
    {
        $exponent = $this->currencyExponent($currency);
        $value = $this->decimal($raw, 2);

        return (int) round($value * (10 ** $exponent));
    }

    private function majorUnits(int $minor, string $currency): string
    {
        $exponent = $this->currencyExponent($currency);

        return number_format($minor / (10 ** $exponent), $exponent, '.', '');
    }

    private function currencyExponent(string $currency): int
    {
        return match (strtoupper($currency)) {
            'JPY', 'KRW', 'VND', 'CLP' => 0,
            'BHD', 'KWD', 'TND', 'OMR' => 3,
            default                    => 2,
        };
    }

    /**
     * L'identifiant d'expédition doit arriver déjà préfixé. Il n'existe nulle part dans la
     * plateforme de route qui résoudrait une référence client vers un shp_ : container-registry
     * n'expose que la lecture unitaire GET /v1/shipments/{shipment_id} (§3.3), et lire
     * freight.shipments en SQL serait une violation directe de la règle 2 de §7. Un extrait
     * antérieur au correctif de 2024 est donc rejeté, pas deviné.
     *
     * @throws MalformedExtract
     */
    private function assertShipmentId(string $raw): string
    {
        $value = trim($raw);
        if (preg_match('/^shp_[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}$/', $value) !== 1) {
            throw new MalformedExtract(
                sprintf('identifiant d\'expédition invalide : %s', $value === '' ? '(vide)' : $value),
                [['path' => 'header.shipment_id', 'reason' => 'expected_prefixed_ulid_shp']],
            );
        }

        return $value;
    }
}
