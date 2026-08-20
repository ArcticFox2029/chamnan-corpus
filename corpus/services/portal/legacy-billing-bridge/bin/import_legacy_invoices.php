#!/usr/bin/env php
<?php

/**
 * Lot d'import nocturne des extraits de facturation déposés par le mainframe sur le volume
 * partagé. Il fait le même travail que la route POST /facturation/depot de LegacyRouter, mais
 * pour les fichiers que le mainframe pousse par SFTP au lieu de les envoyer en HTTP — c'est-à-dire
 * la quasi-totalité du volume, la route HTTP ne servant qu'aux corrections de la journée.
 *
 * Lancé par un CronJob à 02:10, soit avant le rapprochement à trois voies de reconciliation-service :
 * une facture importée après le passage du rapprochement produirait un `missing_invoice` qui se
 * refermerait tout seul le lendemain, et l'astreinte finance a demandé qu'on lui épargne ce bruit.
 *
 * Usage : import_legacy_invoices.php <répertoire> [--dry-run] [--max=N]
 *
 * @package OrbitalFreight\LegacyBillingBridge
 */

declare(strict_types=1);

use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Billing\LegacyInvoiceMapper;
use OrbitalFreight\LegacyBillingBridge\Billing\MalformedExtract;
use OrbitalFreight\LegacyBillingBridge\Billing\UpstreamFailure;

require __DIR__ . '/../vendor/autoload.php';

if (!of_region_is_valid(of_env('OF_REGION_CODE'))) {
    fwrite(STDERR, "OF_REGION_CODE hors de la liste fermée de §0.6\n");
    exit(2);
}

$options = getopt('', ['dry-run', 'max::']) ?: [];
$directory = $argv[1] ?? '';
$dryRun = array_key_exists('dry-run', $options);
$max = isset($options['max']) ? (int) $options['max'] : PHP_INT_MAX;

if ($directory === '' || !is_dir($directory)) {
    fwrite(STDERR, "usage : import_legacy_invoices.php <répertoire> [--dry-run] [--max=N]\n");
    exit(2);
}

$billing = new BillingServiceClient(
    baseUrl: rtrim(of_env('OF_BILLING_BASE_URL'), '/'),
    identityBaseUrl: of_identity_base_url(),
);
$mapper = new LegacyInvoiceMapper();

// Un trace-id unique pour tout le lot. Ce n'est pas conforme à l'esprit de §0.3, qui veut une
// trace par requête, mais c'est exactement ce que l'astreinte veut : retrouver d'un coup les
// quatre cents factures d'une nuit dans le collecteur, plutôt que quatre cents traces isolées.
$batchTraceId = bin2hex(random_bytes(16));

$processed = 0;
$failed = 0;
$rejected = 0;

// Ordre lexicographique : le mainframe nomme ses fichiers FACT_AAAAMMJJ_NNNN.txt, ce qui donne
// l'ordre chronologique de production. Le respecter évite qu'un avoir soit importé avant la
// facture qu'il annule.
$files = glob(rtrim($directory, '/') . '/FACT_*.txt') ?: [];
sort($files, SORT_STRING);

foreach ($files as $file) {
    if ($processed + $failed >= $max) {
        break;
    }

    $raw = file_get_contents($file);
    if ($raw === false) {
        of_log('error', 'extrait illisible', ['file' => $file]);
        $failed++;
        continue;
    }

    try {
        $draft = $mapper->parseExtract(mb_convert_encoding($raw, 'UTF-8', 'ISO-8859-1'));
    } catch (MalformedExtract $e) {
        // Extrait invalide : il part en quarantaine et n'est jamais réessayé. Le service
        // comptable le reprend depuis son côté ; le pont n'a pas à corriger une donnée
        // qu'il n'a pas produite.
        of_log('warn', 'extrait rejeté', [
            'file'   => basename($file),
            'error'  => $e->getMessage(),
            'fields' => $e->fields(),
        ]);
        quarantine($file);
        $rejected++;
        continue;
    }

    if ($dryRun) {
        printf(
            "%-28s %s %s %d ligne(s) %d %s\n",
            basename($file),
            $draft->legacyReference,
            $draft->shipmentId,
            count($draft->lines),
            $draft->subtotalMinor(),
            $draft->currency,
        );
        $processed++;
        continue;
    }

    try {
        $invoice = $billing->createInvoice($draft, $batchTraceId);
    } catch (UpstreamFailure $e) {
        if ($e->isPermanent()) {
            of_log('warn', 'facture refusée par billing-service', [
                'file'  => basename($file),
                'code'  => $e->code(),
                'error' => $e->getMessage(),
            ]);
            quarantine($file);
            $rejected++;
            continue;
        }

        // Erreur transitoire : le fichier reste en place et repassera au prochain déclenchement.
        // Rien ne se perd, la clé d'idempotence dérivée de la référence héritée garantit qu'un
        // second essai ne crée pas de doublon dans billing.invoices.
        of_log('error', 'échec transitoire, fichier conservé', [
            'file'  => basename($file),
            'code'  => $e->code(),
        ]);
        $failed++;
        continue;
    }

    of_log('info', 'facture créée depuis un extrait hérité', [
        'file'        => basename($file),
        'invoice_id'  => $invoice['invoice_id'],
        'shipment_id' => $draft->shipmentId,
        'status'      => $invoice['status'],
        'trace_id'    => $batchTraceId,
    ]);

    // Elle reste en `draft` : l'émission, qui publie `billing.invoice.issued`, est faite depuis
    // le portail par un opérateur du rôle finance. Le lot ne s'octroie pas ce geste.
    archive($file);
    $processed++;
}

of_log('info', 'lot d\'import terminé', [
    'processed' => $processed,
    'rejected'  => $rejected,
    'failed'    => $failed,
    'dry_run'   => $dryRun,
    'trace_id'  => $batchTraceId,
]);

// Un échec transitoire fait sortir en 1 pour que le CronJob soit marqué en erreur et réveille
// l'alerting ; un rejet, non — c'est un problème de données, pas de plateforme.
exit($failed > 0 ? 1 : 0);

/**
 * Déplace un extrait traité vers le sous-répertoire d'archive du jour. Le mainframe le relit
 * parfois pour justifier un écart soulevé par reconciliation-service, d'où la conservation.
 */
function archive(string $file): void
{
    $target = dirname($file) . '/traites/' . gmdate('Y-m-d');
    if (!is_dir($target)) {
        mkdir($target, 0o750, true);
    }

    rename($file, $target . '/' . basename($file));
}

/**
 * Met un extrait de côté sans le détruire. La comptabilité vide ce répertoire elle-même après
 * correction ; le pont n'y touche plus jamais.
 */
function quarantine(string $file): void
{
    $target = dirname($file) . '/rejets';
    if (!is_dir($target)) {
        mkdir($target, 0o750, true);
    }

    rename($file, $target . '/' . basename($file));
}
