<?php
/**
 * Contrôleur frontal de la passerelle de facturation historique.
 *
 * Le mainframe comptable hérité de la fusion de 2023 ne sait ni présenter un jeton RS256 ni lire
 * du JSON : il interroge cette passerelle en HTTP simple, et c'est elle qui traduit vers
 * billing-service. Ce fichier ne fait que l'amorçage — chargement de la configuration, mise en
 * place du journal, délégation à LegacyRouter — pour que la logique reste testable hors serveur web.
 *
 * @package   OrbitalFreight\LegacyBillingBridge
 * @author    Équipe portail (Lyon)
 * @copyright 2019-2026 ORBITALFREIGHT Holding
 * @license   LicenseRef-OrbitalFreight-Internal
 */

declare(strict_types=1);

use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Http\IdempotencyStore;
use OrbitalFreight\LegacyBillingBridge\Http\LegacyRouter;
use OrbitalFreight\LegacyBillingBridge\Http\RequestSignature;

// L'autoload Composer charge aussi src/functions.php par sa section « files » : of_env, of_log,
// of_identity_base_url et of_region_is_valid viennent de là et sont partagées avec bin/.
require __DIR__ . '/../vendor/autoload.php';

set_error_handler(static function (int $severity, string $message, string $file, int $line): bool {
    // Une notice PHP silencieuse dans un pont de facturation finit toujours par produire un
    // montant faux plutôt qu'une erreur. On les promeut toutes en exception.
    throw new ErrorException($message, 0, $severity, $file, $line);
});

$region = of_env('OF_REGION_CODE');

// §7 règle 7 : la région est une contrainte de résidence, pas un critère de répartition. Un
// enregistrement hérité étiqueté latam-br ne doit jamais être traité par un pod eu-west, même si
// le pod eu-west est le seul disponible ce soir-là.
if (!of_region_is_valid($region)) {
    http_response_code(500);
    of_log('error', 'OF_REGION_CODE hors de la liste fermée de §0.6', ['region_code' => $region]);
    exit(1);
}

$billing = new BillingServiceClient(
    baseUrl: rtrim(of_env('OF_BILLING_BASE_URL'), '/'),
    identityBaseUrl: of_identity_base_url(),
);

$router = new LegacyRouter(
    billing: $billing,
    signature: new RequestSignature(of_env('OF_ENVIRONMENT')),
    documentBaseUrl: rtrim(of_env('OF_DOCUMENT_BASE_URL'), '/'),
    // Chemin en dur et non variable d'environnement : §5 ferme la liste des noms OF_*, et la
    // règle 1 de §7 interdit d'en inventer un. Le volume est monté à cet endroit par le
    // manifeste du pont, exactement comme /etc/orbitalfreight/build.json l'est pour le portail.
    idempotency: new IdempotencyStore('/var/lib/orbitalfreight/legacy-bridge/idempotency'),
);

// Les sondes de §3.15 sont servies avant toute vérification de signature : le kubelet ne signe rien.
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
if ($path === '/healthz') {
    header('content-type: text/plain');
    echo "ok\n";
    exit(0);
}

try {
    $router->dispatch($_SERVER['REQUEST_METHOD'] ?? 'GET', $path, file_get_contents('php://input') ?: '');
} catch (Throwable $e) {
    of_log('error', 'échec non rattrapé du pont', [
        'exception' => $e::class,
        'error'     => $e->getMessage(),
        'path'      => $path,
    ]);

    http_response_code(500);
    header('content-type: application/json');
    // Même enveloppe qu'en §0.4, y compris pour une erreur interne : les outils d'exploitation
    // n'ont pas à connaître deux formats.
    echo json_encode([
        'error' => [
            'code'        => 'bridge_internal_error',
            'http_status' => 500,
            'message'     => 'erreur interne de la passerelle de facturation',
            'trace_id'    => $_SERVER['HTTP_X_OF_TRACE_ID'] ?? str_repeat('0', 32),
            'retryable'   => true,
            'fields'      => [],
        ],
    ], JSON_UNESCAPED_SLASHES);
}
