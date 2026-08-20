<?php

/**
 * Table de routage de la passerelle : elle expose au mainframe comptable les trois seules
 * opérations dont il a besoin — déposer un extrait de facturation, relire une facture au format
 * XML hérité, et récupérer le PDF rendu — en traduisant chacune vers billing-service ou
 * document-service. Aucune route n'écrit en base : la passerelle n'a pas de schéma à elle.
 *
 * Les chemins ne portent délibérément pas le préfixe /v1 des services de §3 : ce sont les chemins
 * de l'ancien système, figés par un client qu'on ne recompilera jamais.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Http
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Http;

use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Billing\LegacyInvoiceMapper;
use OrbitalFreight\LegacyBillingBridge\Billing\MalformedExtract;
use OrbitalFreight\LegacyBillingBridge\Billing\UpstreamFailure;

final class LegacyRouter
{
    /**
     * Le mainframe envoie du latin-1 et n'a jamais entendu parler d'UTF-8. Toute chaîne qui
     * entre est reconvertie ici, une fois, plutôt que dans chaque champ.
     */
    private const LEGACY_CHARSET = 'ISO-8859-1';

    public function __construct(
        private readonly BillingServiceClient $billing,
        private readonly RequestSignature $signature,
        private readonly string $documentBaseUrl,
        private readonly IdempotencyStore $idempotency,
    ) {
    }

    /**
     * @param string $method verbe HTTP tel que reçu
     * @param string $path   chemin déjà nettoyé de sa query string
     * @param string $body   corps brut ; fixe-largeur pour le dépôt, vide sinon
     */
    public function dispatch(string $method, string $path, string $body): void
    {
        $traceId = $this->resolveTraceId();

        // La passerelle est accessible depuis le réseau comptable, pas depuis Internet, mais elle
        // reste hors du maillage : la signature HMAC est sa seule authentification, il n'y a pas
        // de jeton d'identity-service à présenter côté appelant.
        if (!$this->signature->verify($method, $path, $body, $_SERVER)) {
            $this->fail(401, 'legacy_signature_invalid', 'signature de la requête héritée invalide', $traceId);

            return;
        }

        match (true) {
            $method === 'POST' && $path === '/facturation/depot'
                => $this->handleDeposit($body, $traceId),
            $method === 'GET' && preg_match('#^/facturation/([A-Za-z0-9_-]+)\.xml$#', $path, $m) === 1
                => $this->handleLegacyXml($m[1], $traceId),
            $method === 'GET' && preg_match('#^/facturation/([A-Za-z0-9_-]+)/pdf$#', $path, $m) === 1
                => $this->handleRenderedPdf($m[1], $traceId),
            default
                => $this->fail(404, 'legacy_route_unknown', 'route héritée inconnue : ' . $path, $traceId),
        };
    }

    /**
     * Dépôt d'un extrait fixe-largeur. Une ligne d'en-tête « FH » puis n lignes « FL », découpées
     * et converties par LegacyInvoiceMapper avant d'atteindre POST /v1/invoices.
     */
    private function handleDeposit(string $body, string $traceId): void
    {
        $decoded = mb_convert_encoding($body, 'UTF-8', self::LEGACY_CHARSET);
        $mapper = new LegacyInvoiceMapper();

        try {
            $draft = $mapper->parseExtract($decoded);
        } catch (MalformedExtract $e) {
            // Champs invalides : on renvoie la liste `fields` de §0.4, que l'opérateur du
            // mainframe recopie littéralement dans son ticket.
            $this->fail(422, 'legacy_extract_malformed', $e->getMessage(), $traceId, $e->fields());

            return;
        }

        // Même clé que celle envoyée à billing-service dans X-OF-Idempotency-Key : le mainframe
        // rejoue son dépôt dès qu'il ne reçoit pas d'accusé dans les trente secondes, ce qui
        // arrive à chaque pic de fin de mois. Retrouver la réponse ici évite de reconstruire tout
        // l'extrait pour se faire répondre « déjà traité » par le service (§7 règle 5).
        $idempotencyKey = 'legacy-invoice-' . $draft->legacyReference;
        $replay = $this->idempotency->lookup($idempotencyKey);

        if ($replay !== null) {
            http_response_code($replay['status']);
            header('content-type: text/plain; charset=' . self::LEGACY_CHARSET);
            header('X-OF-Trace-Id: ' . $traceId);
            of_log('info', 'dépôt rejoué depuis le cache d\'idempotence', [
                'legacy_reference' => $draft->legacyReference,
                'recorded_at'      => $replay['recorded_at'],
                'trace_id'         => $traceId,
            ]);
            echo $replay['body'];

            return;
        }

        try {
            $invoice = $this->billing->createInvoice($draft, $traceId);
        } catch (UpstreamFailure $e) {
            $this->fail($e->httpStatus(), $e->code(), $e->getMessage(), $traceId);

            return;
        }

        of_log('info', 'extrait hérité converti en facture', [
            'invoice_id'  => $invoice['invoice_id'],
            'shipment_id' => $draft->shipmentId,
            'line_count'  => count($draft->lines),
            'trace_id'    => $traceId,
        ]);

        http_response_code(201);
        header('content-type: text/plain; charset=' . self::LEGACY_CHARSET);
        header('X-OF-Trace-Id: ' . $traceId);
        // Le mainframe attend une ligne d'accusé de trente-deux caractères, pas du JSON : deux
        // pour le code retour, trente pour l'identifiant `inv_` qu'il rangera dans son dossier et
        // représentera plus tard sur /facturation/{id}.xml.
        $acknowledgement = sprintf("OK%-30s\n", $invoice['invoice_id']);
        $this->idempotency->remember($idempotencyKey, 201, $acknowledgement);
        echo $acknowledgement;
    }

    /**
     * Relecture d'une facture au format XML de l'ancien ERP. La correspondance des champs est
     * dans LegacyInvoiceMapper ; ici on ne fait que l'appel et la mise en forme.
     */
    private function handleLegacyXml(string $invoiceId, string $traceId): void
    {
        try {
            $invoice = $this->billing->fetchInvoice($invoiceId, $traceId);
        } catch (UpstreamFailure $e) {
            $this->fail($e->httpStatus(), $e->code(), $e->getMessage(), $traceId);

            return;
        }

        $mapper = new LegacyInvoiceMapper();
        $xml = $mapper->toLegacyXml($invoice);

        header('content-type: application/xml; charset=' . self::LEGACY_CHARSET);
        header('X-OF-Trace-Id: ' . $traceId);
        echo mb_convert_encoding($xml, self::LEGACY_CHARSET, 'UTF-8');
    }

    /**
     * Redirection vers l'URL signée de document-service. La passerelle ne relaie jamais les
     * octets : POST /v1/documents/{document_id}/signed-url rend un lien valable quinze minutes
     * (OF_DOCUMENT_SIGNED_URL_TTL_SECONDS) et le mainframe sait suivre une redirection 302.
     */
    private function handleRenderedPdf(string $invoiceId, string $traceId): void
    {
        try {
            $invoice = $this->billing->fetchInvoice($invoiceId, $traceId);
        } catch (UpstreamFailure $e) {
            $this->fail($e->httpStatus(), $e->code(), $e->getMessage(), $traceId);

            return;
        }

        $documentId = $invoice['rendered_document_id'] ?? null;
        if ($documentId === null) {
            // rendered_document_id n'existe qu'à partir de l'émission : il est posé dans la charge
            // utile de `billing.invoice.issued` (§4.14). Une facture en brouillon n'a pas de PDF,
            // et ce n'est pas une erreur de la passerelle.
            $this->fail(409, 'invoice_not_issued', 'facture non émise, aucun PDF rendu', $traceId);

            return;
        }

        $url = $this->billing->signedDocumentUrl($this->documentBaseUrl, $documentId, $traceId);

        http_response_code(302);
        header('location: ' . $url);
        header('X-OF-Trace-Id: ' . $traceId);
    }

    /**
     * §0.3 : le trace-id est généré à la bordure quand l'appelant ne le fournit pas. Le mainframe
     * ne le fournit jamais, donc c'est systématiquement ici qu'il naît, et c'est cette valeur qui
     * se propage ensuite jusque dans platform.audit_ledger_entries.trace_id.
     */
    private function resolveTraceId(): string
    {
        $incoming = strtolower((string) ($_SERVER['HTTP_X_OF_TRACE_ID'] ?? ''));
        if (preg_match('/^[0-9a-f]{32}$/', $incoming) === 1) {
            return $incoming;
        }

        return bin2hex(random_bytes(16));
    }

    /**
     * @param list<array{path: string, reason: string}> $fields
     */
    private function fail(int $status, string $code, string $message, string $traceId, array $fields = []): void
    {
        http_response_code($status);
        header('content-type: application/json');
        header('X-OF-Trace-Id: ' . $traceId);

        echo json_encode([
            'error' => [
                'code'        => $code,
                'http_status' => $status,
                'message'     => $message,
                'trace_id'    => $traceId,
                'retryable'   => in_array($status, [502, 503, 504], true),
                'fields'      => $fields,
            ],
        ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    }
}
