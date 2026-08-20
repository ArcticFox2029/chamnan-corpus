<?php

/**
 * Vérifie le découpage de l'extrait fixe-largeur du mainframe et la conversion des montants.
 * Ce sont les deux endroits où une erreur ne se voit pas : un décalage d'une colonne produit un
 * identifiant tronqué que billing-service refusera bruyamment, mais une conversion d'unité
 * fausse produit une facture parfaitement valide et cent fois trop grande.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Tests
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Tests;

use OrbitalFreight\LegacyBillingBridge\Billing\LegacyInvoiceMapper;
use OrbitalFreight\LegacyBillingBridge\Billing\MalformedExtract;
use PHPUnit\Framework\TestCase;

final class LegacyInvoiceMapperTest extends TestCase
{
    private LegacyInvoiceMapper $mapper;

    protected function setUp(): void
    {
        $this->mapper = new LegacyInvoiceMapper();
    }

    /**
     * Enregistrement d'en-tête conforme au correctif de mars 2024 : le champ expédition fait
     * trente octets, ce qui loge exactement un identifiant préfixé de §0.1.
     */
    private function header(string $shipmentId = 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PC', int $lineCount = 2): string
    {
        // Douze octets pour la référence héritée, trente pour l'expédition : c'est le cadrage
        // exact de HEADER_LAYOUT, et un octet d'écart décale tout ce qui suit sans erreur visible.
        return 'FH'
            . str_pad('REF-2026-041', 12)
            . str_pad($shipmentId, 30)
            . 'EUR'
            . '20260314'
            // Le nombre de lignes annoncé est vérifié contre le nombre lu : un extrait tronqué
            // en cours de transfert échoue ici plutôt que de produire une facture incomplète.
            . str_pad((string) $lineCount, 4, '0', STR_PAD_LEFT);
    }

    /**
     * Enregistrement de ligne « FL » au cadrage de LINE_LAYOUT : rang sur 4, code de charge du
     * mainframe sur 6, libellé sur 40, quantité sur 12 (trois décimales implicites), prix
     * unitaire et montant sur 14 chacun (deux décimales implicites).
     */
    private function line(string $legacyChargeCode, string $amount, int $seqNo = 1): string
    {
        return 'FL'
            . str_pad((string) $seqNo, 4, '0', STR_PAD_LEFT)
            . str_pad($legacyChargeCode, 6)
            . str_pad('Transport principal Hambourg - Rotterdam', 40)
            // Quantité 1,000 : le contrôle roundingIsPlausible() de InvoiceDraftLine exige que
            // quantité × prix unitaire retombe sur le montant à une unité mineure près.
            . str_pad('1000', 12, '0', STR_PAD_LEFT)
            . str_pad($amount, 14, '0', STR_PAD_LEFT)
            . str_pad($amount, 14, '0', STR_PAD_LEFT);
    }

    public function testParsesHeaderAndLines(): void
    {
        $raw = implode("\r\n", [
            $this->header(),
            $this->line('TRACPL', '128450', 1),
            $this->line('SURCAR', '012000', 2),
        ]);

        $draft = $this->mapper->parseExtract($raw);

        self::assertSame('shp_01J8ZK4T9QW3RM7XN2VB6HD5PC', $draft->shipmentId);
        self::assertSame('EUR', $draft->currency);
        self::assertCount(2, $draft->lines);
        self::assertSame('REF-2026-041', $draft->legacyReference);
    }

    /**
     * Les codes du mainframe ne sont pas ceux du CHECK sur billing.invoice_lines.charge_code ;
     * la correspondance est la raison d'être de ce mapper, et une valeur inconnue doit être
     * refusée plutôt que transmise telle quelle à billing-service.
     */
    public function testMapsLegacyChargeCodesToTheBillingVocabulary(): void
    {
        $draft = $this->mapper->parseExtract(
            implode("\r\n", [$this->header(lineCount: 1), $this->line('TRACPL', '128450')])
        );

        self::assertSame('linehaul', $draft->lines[0]->chargeCode);
        self::assertSame(128450, $draft->lines[0]->amountMinor);
    }

    public function testRejectsAnUnprefixedShipmentReference(): void
    {
        // Extrait antérieur au correctif : le mainframe y mettait sa propre référence de dossier.
        // Il n'existe aucune route qui résoudrait une référence client vers un shp_ — container-registry
        // n'expose que la lecture unitaire — donc l'extrait est rejeté, jamais deviné.
        $this->expectException(MalformedExtract::class);
        $this->mapper->parseExtract($this->header('DOSSIER-88213', 0));
    }

    /**
     * §0.2 : les montants voyagent en unités mineures entières. Le yen n'a pas de décimale, et
     * une conversion « ×100 » systématique a déjà produit une ligne au centuple.
     *
     * @dataProvider currencyExponentCases
     */
    public function testConvertsToMinorUnitsUsingTheCurrencyExponent(string $raw, string $currency, int $expected): void
    {
        self::assertSame($expected, $this->mapper->toMinorUnits($raw, $currency));
    }

    /**
     * @return array<string, array{string, string, int}>
     */
    public static function currencyExponentCases(): array
    {
        return [
            'euro, deux décimales'   => ['000000000128450', 'EUR', 128450],
            'yen, aucune décimale'   => ['000000000128400', 'JPY', 1284],
            'dinar, trois décimales' => ['000000000128450', 'KWD', 1284500],
        ];
    }

    /**
     * Le XML de restitution est relu par un programme COBOL qui compte les balises : l'ordre et
     * la présence de HT, DROITS, TVA et TTC sont contractuels, et l'égalité entre eux reproduit
     * la contrainte invoice_total_is_consistent de billing.invoices.
     */
    public function testRendersLegacyXmlWithConsistentTotals(): void
    {
        $xml = $this->mapper->toLegacyXml([
            'invoice_id'     => 'inv_01J8ZK4T9QW3RM7XN2VB6HD5PD',
            'invoice_number' => 'OF-HAMB-2026-000412',
            'shipment_id'    => 'shp_01J8ZK4T9QW3RM7XN2VB6HD5PC',
            'currency'       => 'EUR',
            'subtotal_minor' => 100000,
            'duty_minor'     => 12500,
            'tax_minor'      => 22500,
            'total_minor'    => 135000,
            'status'         => 'issued',
            'issued_at'      => '2026-03-14T09:21:44.118Z',
            'lines'          => [],
        ]);

        self::assertStringContainsString('<HT>1000.00</HT>', $xml);
        self::assertStringContainsString('<DROITS>125.00</DROITS>', $xml);
        self::assertStringContainsString('<TVA>225.00</TVA>', $xml);
        self::assertStringContainsString('<TTC>1350.00</TTC>', $xml);
    }
}
