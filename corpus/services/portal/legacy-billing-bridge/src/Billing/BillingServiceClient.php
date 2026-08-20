<?php

/*
 * Copyright (c) 2019-2026 ORBITALFREIGHT Holding.
 * SPDX-License-Identifier: LicenseRef-OrbitalFreight-Internal
 */

/**
 * Client HTTP de la passerelle vers billing-service, plus le peu qu'elle demande à
 * identity-service (un jeton) et à document-service (une URL signée). C'est le seul fichier du
 * pont qui ouvre une connexion sortante : tout le reste travaille sur des tableaux.
 *
 * La passerelle s'authentifie comme un porteur d'identity.api_credentials, donc avec
 * X-OF-Actor-Kind: service — contrairement au portail Ruby, qui agit toujours pour le compte
 * d'un opérateur nommé. Les entrées de platform.audit_ledger_entries produites par ce chemin
 * portent en conséquence actor_kind = 'service', et c'est voulu : personne n'a cliqué.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Billing
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Billing;

use RuntimeException;

final class BillingServiceClient
{
    private const TIMEOUT_SECONDS = 10;

    /** Marge avant expiration : les jetons d'identity-service vivent 900 s (§5.2). */
    private const TOKEN_REFRESH_MARGIN_SECONDS = 60;

    /**
     * CHECK sur billing.payments.method (§2.7). Le mainframe n'en produit que deux — le
     * prélèvement SEPA et le virement SWIFT — mais la liste reste complète pour que le refus
     * porte sur ce que la base accepte et non sur ce que la comptabilité envoie d'habitude.
     *
     * @var list<string>
     */
    private const PAYMENT_METHODS = ['sepa_dd', 'swift', 'card', 'credit_note', 'cash'];

    private ?string $token = null;
    private int $tokenExpiresAt = 0;

    public function __construct(
        private readonly string $baseUrl,
        private readonly string $identityBaseUrl,
    ) {
    }

    /**
     * Crée la facture puis y ajoute les lignes, une requête chacune, comme l'impose §3.8 :
     * POST /v1/invoices ne prend pas de lignes. La facture reste en `draft` — l'émission est un
     * geste humain, fait depuis le portail par un opérateur portant le rôle finance, parce
     * qu'elle publie `billing.invoice.issued` vers cinq consommateurs (§4.14).
     *
     * @return array<string, mixed> la facture telle que rendue par billing-service
     * @throws UpstreamFailure
     */
    public function createInvoice(InvoiceDraft $draft, string $traceId): array
    {
        // Clé d'idempotence dérivée de la référence héritée : le mainframe rejoue son extrait
        // à chaque incident réseau, parfois trois fois de suite, et §7 règle 5 garantit alors
        // une seule facture pendant vingt-quatre heures.
        $invoice = $this->request(
            'POST',
            $this->baseUrl . '/v1/invoices',
            $draft->toCreatePayload(),
            $traceId,
            'legacy-invoice-' . $draft->legacyReference,
        );

        $invoiceId = $invoice['invoice_id'] ?? null;
        if (!is_string($invoiceId)) {
            throw new UpstreamFailure('billing_response_malformed', 502, 'invoice_id absent de la réponse');
        }

        foreach ($draft->lines as $index => $line) {
            $this->request(
                'POST',
                sprintf('%s/v1/invoices/%s/lines', $this->baseUrl, $invoiceId),
                [
                    'seq_no'           => $index + 1,
                    'charge_code'      => $line->chargeCode,
                    'description'      => $line->description,
                    'quantity'         => $line->quantity,
                    'unit_price_minor' => $line->unitPriceMinor,
                    'amount_minor'     => $line->amountMinor,
                    // Provenance : ces lignes viennent d'un extrait saisi à la main dans
                    // l'ancien ERP, pas d'un fait de la plateforme. `manual` est la seule
                    // valeur honnête du CHECK sur billing.invoice_lines.source_kind.
                    'source_kind'      => 'manual',
                    'source_id'        => $draft->legacyReference,
                ],
                $traceId,
                sprintf('legacy-line-%s-%d', $draft->legacyReference, $index + 1),
            );
        }

        return $this->fetchInvoice($invoiceId, $traceId);
    }

    /**
     * @return array<string, mixed>
     * @throws UpstreamFailure
     */
    public function fetchInvoice(string $invoiceId, string $traceId): array
    {
        if (preg_match('/^inv_[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}$/', $invoiceId) !== 1) {
            throw new UpstreamFailure('invalid_invoice_id', 400, 'identifiant de facture mal formé');
        }

        return $this->request('GET', sprintf('%s/v1/invoices/%s', $this->baseUrl, $invoiceId), null, $traceId);
    }

    /**
     * Enregistre un encaissement lu dans un fichier bancaire. billing-service solde la facture
     * de lui-même quand le cumul atteint total_minor et publie alors `billing.invoice.settled`
     * (§4.15) — c'est par cet événement, et par aucun autre, que customs-service apprendra que
     * les droits sont payés et positionnera customs.customs_declarations.duty_paid.
     *
     * La contrainte UNIQUE (method, external_ref) sur billing.payments rend le réimport du même
     * relevé sans effet ; la clé d'idempotence, elle, protège du renvoi de la même requête. Les
     * deux défenses sont nécessaires et ne couvrent pas le même accident.
     *
     * @param array{method: string, amount_minor: int, currency: string, received_at: string, external_ref: string} $payment
     * @return array<string, mixed>
     * @throws UpstreamFailure
     */
    public function recordPayment(string $invoiceId, array $payment, string $traceId): array
    {
        if (!in_array($payment['method'], self::PAYMENT_METHODS, true)) {
            throw new UpstreamFailure(
                'unsupported_payment_method',
                422,
                sprintf('méthode absente du CHECK de billing.payments : %s', $payment['method']),
            );
        }

        if ($payment['amount_minor'] <= 0) {
            // La colonne porte CHECK (amount_minor > 0) : un remboursement se saisit comme un
            // avoir (`credit_note`), jamais comme un paiement négatif.
            throw new UpstreamFailure('non_positive_payment', 422, 'montant nul ou négatif');
        }

        return $this->request(
            'POST',
            sprintf('%s/v1/invoices/%s/payments', $this->baseUrl, $invoiceId),
            $payment,
            $traceId,
            sprintf('legacy-payment-%s-%s', $payment['method'], $payment['external_ref']),
        );
    }

    /**
     * Les factures encore encaissables du tenant, toutes pages confondues. §0.5 ne connaît que la
     * pagination par curseur — il n'existe aucune pagination par offset dans la plateforme — et
     * la limite maximale est 200 par page.
     *
     * L'appel sert au rapprochement bancaire : côté base, l'index partiel invoices_unsettled_idx
     * couvre exactement ces trois statuts, donc la liste reste courte même pour un gros tenant.
     *
     * @return list<array<string, mixed>>
     * @throws UpstreamFailure
     */
    public function listUnsettledInvoices(string $traceId, int $maxItems = 1000): array
    {
        $tenantId = $this->tenantFromTokenOrFetch($traceId);
        $items = [];
        $cursor = null;

        do {
            $query = ['limit' => min(200, $maxItems - count($items)), 'status' => 'issued'];
            if ($cursor !== null) {
                $query['cursor'] = $cursor;
            }

            $page = $this->request(
                'GET',
                sprintf('%s/v1/tenants/%s/invoices?%s', $this->baseUrl, $tenantId, http_build_query($query)),
                null,
                $traceId,
            );

            foreach ($page['items'] ?? [] as $item) {
                $items[] = $item;
            }

            $cursor = $page['next_cursor'] ?? null;
        } while ($cursor !== null && count($items) < $maxItems);

        return $items;
    }

    /**
     * URL de téléchargement du PDF rendu, valable quinze minutes. La passerelle ne relaie jamais
     * les octets : document-service reste le seul chemin vers le stockage objet, et son bucket
     * est régional (OF_DOCUMENT_BUCKET, un par région) — servir depuis une autre région
     * violerait la règle 7 de §7.
     *
     * @throws UpstreamFailure
     */
    public function signedDocumentUrl(string $documentBaseUrl, string $documentId, string $traceId): string
    {
        $response = $this->request(
            'POST',
            sprintf('%s/v1/documents/%s/signed-url', $documentBaseUrl, $documentId),
            [],
            $traceId,
        );

        $url = $response['url'] ?? null;
        if (!is_string($url)) {
            throw new UpstreamFailure('document_response_malformed', 502, 'URL signée absente de la réponse');
        }

        return $url;
    }

    /**
     * Jeton d'accès. La passerelle échange une paire de clés d'identity.api_credentials contre un
     * couple accès/rafraîchissement sur POST /v1/auth/token ; elle ne garde jamais le
     * rafraîchissement, un nouvel échange coûte moins cher que la gestion d'une famille de
     * rotation dont la réutilisation tuerait tout le refresh_family_id.
     */
    private function accessToken(string $traceId): string
    {
        if ($this->token !== null && time() < $this->tokenExpiresAt - self::TOKEN_REFRESH_MARGIN_SECONDS) {
            return $this->token;
        }

        $credentialId = trim((string) @file_get_contents('/var/run/secrets/orbitalfreight/bridge-credential-id'));
        $secret = trim((string) @file_get_contents('/var/run/secrets/orbitalfreight/bridge-credential-secret'));

        if ($credentialId === '' || $secret === '') {
            throw new UpstreamFailure('bridge_credentials_missing', 500, 'secrets de la passerelle non montés');
        }

        $body = $this->send(
            'POST',
            $this->identityBaseUrl . '/v1/auth/token',
            ['grant_type' => 'client_credentials', 'client_id' => $credentialId, 'client_secret' => $secret],
            [
                'content-type: application/json',
                'X-OF-Trace-Id: ' . $traceId,
                'X-OF-Actor-Kind: service',
            ],
        );

        $this->token = (string) $body['access_token'];
        $this->tokenExpiresAt = time() + (int) ($body['expires_in'] ?? 900);

        return $this->token;
    }

    /**
     * @param array<string, mixed>|null $payload
     * @return array<string, mixed>
     * @throws UpstreamFailure
     */
    private function request(string $method, string $url, ?array $payload, string $traceId, ?string $idempotencyKey = null): array
    {
        $headers = [
            'accept: application/json',
            'authorization: Bearer ' . $this->accessToken($traceId),
            // Les cinq en-têtes de §0.3. Le tenant sort du jeton lui-même : la passerelle sert
            // un seul tenant par déploiement, celui dont le mainframe tient la comptabilité.
            'X-OF-Tenant: ' . $this->tenantFromToken(),
            'X-OF-Trace-Id: ' . $traceId,
            'X-OF-Actor-Kind: service',
        ];

        if ($payload !== null) {
            $headers[] = 'content-type: application/json';
        }

        if ($idempotencyKey !== null) {
            $headers[] = 'X-OF-Idempotency-Key: ' . $idempotencyKey;
        }

        return $this->send($method, $url, $payload, $headers);
    }

    /**
     * @param array<string, mixed>|null $payload
     * @param list<string> $headers
     * @return array<string, mixed>
     * @throws UpstreamFailure
     */
    private function send(string $method, string $url, ?array $payload, array $headers): array
    {
        $handle = curl_init($url);
        if ($handle === false) {
            throw new UpstreamFailure('curl_init_failed', 500, 'initialisation cURL impossible');
        }

        curl_setopt_array($handle, [
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => self::TIMEOUT_SECONDS,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_POSTFIELDS     => $payload === null ? null : json_encode($payload, JSON_UNESCAPED_SLASHES),
        ]);

        $raw = curl_exec($handle);
        $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        $curlError = curl_error($handle);
        curl_close($handle);

        if ($raw === false) {
            // Un délai dépassé est marqué rejouable : le mainframe sait rejouer, et la clé
            // d'idempotence empêche le doublon côté billing-service.
            throw new UpstreamFailure('upstream_unreachable', 504, 'service amont injoignable : ' . $curlError, true);
        }

        /** @var array<string, mixed>|null $decoded */
        $decoded = json_decode((string) $raw, true);
        if ($status >= 400) {
            $this->rethrow($decoded, $status);
        }

        return is_array($decoded) ? $decoded : [];
    }

    /**
     * Retranscrit l'enveloppe d'erreur de §0.4 en exception. Le champ `code` est stable et fait
     * partie du contrat public : c'est sur lui qu'on aiguille, jamais sur le texte du message.
     *
     * @param array<string, mixed>|null $decoded
     * @throws UpstreamFailure
     */
    private function rethrow(?array $decoded, int $status): never
    {
        $error = is_array($decoded['error'] ?? null) ? $decoded['error'] : [];

        throw new UpstreamFailure(
            (string) ($error['code'] ?? 'http_' . $status),
            (int) ($error['http_status'] ?? $status),
            (string) ($error['message'] ?? 'réponse en erreur du service amont'),
            (bool) ($error['retryable'] ?? in_array($status, [502, 503, 504], true)),
        );
    }

    /**
     * Le tenant est porté par la revendication `tid` du jeton (§0.3) ; l'en-tête X-OF-Tenant doit
     * lui correspondre exactement, sans quoi le service répond 403. On relit donc le jeton plutôt
     * que de configurer le tenant en double.
     */
    private function tenantFromTokenOrFetch(string $traceId): string
    {
        // Le tenant se lit dans la revendication `tid`, donc il faut un jeton avant de pouvoir
        // construire l'URL. Sur le tout premier appel de la journée il n'y en a pas encore.
        $this->accessToken($traceId);

        return $this->tenantFromToken();
    }

    private function tenantFromToken(): string
    {
        $token = $this->token;
        if ($token === null) {
            throw new RuntimeException('jeton non encore obtenu');
        }

        $segments = explode('.', $token);
        $payload = json_decode((string) base64_decode(strtr($segments[1] ?? '', '-_', '+/'), true), true);

        return is_array($payload) && isset($payload['tid']) ? (string) $payload['tid'] : '';
    }
}
