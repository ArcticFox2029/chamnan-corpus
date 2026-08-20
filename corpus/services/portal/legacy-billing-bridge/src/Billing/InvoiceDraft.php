<?php

/**
 * Représentation intermédiaire d'une facture entre l'extrait fixe-largeur du mainframe et le corps
 * JSON attendu par POST /v1/invoices de billing-service. Elle existe pour que la validation des
 * montants et des devises se fasse une seule fois, avant tout appel réseau : un extrait refusé ne
 * doit jamais laisser derrière lui une facture en brouillon orpheline dans billing.invoices.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Billing
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Billing;

use RuntimeException;

final class InvoiceDraft
{
    /**
     * @param string $shipmentId identifiant shp_ de freight.shipments
     * @param string $currency   code ISO 4217 majuscule, commun à toutes les lignes
     * @param list<InvoiceDraftLine> $lines
     * @param string $legacyReference référence de l'ancien ERP, conservée pour le rapprochement
     */
    public function __construct(
        public readonly string $shipmentId,
        public readonly string $currency,
        public readonly array $lines,
        public readonly string $legacyReference,
    ) {
    }

    /**
     * Sous-total en unités mineures. Les droits de douane n'en font pas partie : billing-service
     * les porte dans duty_minor, alimenté par `customs.declaration.cleared` (§4.13), et un extrait
     * hérité qui en contiendrait les dupliquerait.
     */
    public function subtotalMinor(): int
    {
        $total = 0;
        foreach ($this->lines as $line) {
            $total += $line->amountMinor;
        }

        return $total;
    }

    /**
     * Corps de POST /v1/invoices, puis une requête par ligne sur
     * POST /v1/invoices/{invoice_id}/lines. billing-service refuse un corps qui porterait déjà
     * total_minor : la contrainte invoice_total_is_consistent est vérifiée côté base, pas ici.
     *
     * @return array{shipment_id: string, currency: string, external_reference: string}
     */
    public function toCreatePayload(): array
    {
        return [
            'shipment_id'        => $this->shipmentId,
            'currency'           => $this->currency,
            'external_reference' => $this->legacyReference,
        ];
    }
}

final class InvoiceDraftLine
{
    /**
     * @param string $chargeCode valeur du CHECK sur billing.invoice_lines.charge_code
     * @param string $description libellé repris tel quel sur la facture rendue
     * @param float  $quantity   NUMERIC(12,3) côté base
     * @param int    $unitPriceMinor prix unitaire en unités mineures (§0.2)
     * @param int    $amountMinor    quantité × prix unitaire, arrondi par le mainframe
     */
    public function __construct(
        public readonly string $chargeCode,
        public readonly string $description,
        public readonly float $quantity,
        public readonly int $unitPriceMinor,
        public readonly int $amountMinor,
    ) {
    }

    /**
     * Contrôle de cohérence de l'arrondi. Le mainframe arrondit au demi supérieur, PHP au pair
     * le plus proche : sur une quantité de 2,5 unités à 1 centime, les deux ne tombent pas
     * d'accord. On tolère un écart d'une unité mineure, au-delà c'est une ligne à rejeter.
     */
    public function roundingIsPlausible(): bool
    {
        $computed = (int) round($this->quantity * $this->unitPriceMinor);

        return abs($computed - $this->amountMinor) <= 1;
    }
}

/**
 * Extrait illisible ou incohérent. Porte la liste `fields` de l'enveloppe d'erreur de §0.4, que
 * LegacyRouter recopie telle quelle dans sa réponse : le service comptable travaille sur ces
 * chemins pour corriger son export.
 */
final class MalformedExtract extends RuntimeException
{
    /** @param list<array{path: string, reason: string}> $fields */
    public function __construct(string $message, private readonly array $fields = [])
    {
        parent::__construct($message);
    }

    /** @return list<array{path: string, reason: string}> */
    public function fields(): array
    {
        return $this->fields;
    }
}
