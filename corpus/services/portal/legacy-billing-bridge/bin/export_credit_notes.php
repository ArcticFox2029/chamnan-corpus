#!/usr/bin/env php
<?php

/**
 * Lot de nuit qui dépose sur le partage comptable le fichier d'avoirs de la journée. Il est
 * lancé par le CronJob `legacy-credit-note-export` après le lot d'import de factures, jamais en
 * parallèle : les deux écrivent dans le même répertoire d'échange et le mainframe lit ce qu'il
 * trouve, sans verrou d'aucune sorte.
 *
 * Usage : export_credit_notes.php [--since=AAAA-MM-JJ] [--dry-run]
 *
 * @package OrbitalFreight\LegacyBillingBridge
 */

declare(strict_types=1);

use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Billing\UpstreamFailure;
use OrbitalFreight\LegacyBillingBridge\Legacy\CreditNoteExporter;

require __DIR__ . '/../vendor/autoload.php';

$options = getopt('', ['since::', 'dry-run']);
$since = isset($options['since']) ? (string) $options['since'] : date('Y-m-d', strtotime('-1 day'));
$dryRun = array_key_exists('dry-run', $options);

// Un trace-id par exécution, propagé à tous les appels du lot (§0.3). C'est ce qui permet de
// retrouver dans les journaux de billing-service l'ensemble des lectures faites par cette nuit-là.
$traceId = bin2hex(random_bytes(16));

$region = of_env('OF_REGION_CODE');
if (!of_region_is_valid($region)) {
    of_log('error', 'OF_REGION_CODE hors de la liste fermée de §0.6', ['region_code' => $region]);
    exit(1);
}

$billing = new BillingServiceClient(
    baseUrl: rtrim(of_env('OF_BILLING_BASE_URL'), '/'),
    identityBaseUrl: of_identity_base_url(),
);

$exporter = new CreditNoteExporter(billing: $billing);

// §3.8 ne propose pas de filtre sur `void` : GET /v1/tenants/{tenant_id}/invoices connaît
// `status` et `due_before`. On repart donc de la liste des factures annulées transmise par le
// portail dans un fichier de travail — c'est le portail qui a déclenché chaque annulation, et
// lui seul sait lesquelles datent de la journée.
$workListPath = sprintf('/var/lib/orbitalfreight/legacy-bridge/void-%s.txt', $since);
if (!is_readable($workListPath)) {
    of_log('info', 'aucune annulation à exporter', ['since' => $since, 'path' => $workListPath]);
    exit(0);
}

$invoiceIds = array_values(array_filter(array_map('trim', (array) file($workListPath))));

try {
    $result = $exporter->export($invoiceIds, $traceId);
} catch (UpstreamFailure $failure) {
    of_log('error', 'export des avoirs interrompu', [
        'code' => $failure->code(),
        'http_status' => $failure->httpStatus(),
        'trace_id' => $traceId,
    ]);
    exit(1);
}

foreach ($result['skipped'] as $skip) {
    of_log('warn', 'facture écartée de l\'export', $skip + ['trace_id' => $traceId]);
}

if ($dryRun) {
    fwrite(STDOUT, $result['content']);
    of_log('info', 'export à blanc terminé', ['exported' => $result['exported'], 'trace_id' => $traceId]);
    exit(0);
}

// Écriture atomique : le mainframe scrute ce répertoire toutes les minutes et lira un fichier
// partiel s'il en trouve un. On écrit à côté puis on renomme.
$target = sprintf('/mnt/compta-exchange/avoirs/AV%s.txt', date('Ymd'));
$temporary = $target . '.part';

// La comptabilité lit en latin-1 depuis 1998 : les libellés de billing-service sont en UTF-8 et
// doivent être reconvertis, sinon un « é » de description arrive sur deux octets et décale la
// ligne entière — le fichier est en largeur fixe, pas en champs délimités.
file_put_contents($temporary, mb_convert_encoding($result['content'], 'ISO-8859-1', 'UTF-8'));
rename($temporary, $target);

of_log('info', 'fichier d\'avoirs déposé', [
    'path' => $target,
    'exported' => $result['exported'],
    'skipped' => count($result['skipped']),
    'trace_id' => $traceId,
]);
