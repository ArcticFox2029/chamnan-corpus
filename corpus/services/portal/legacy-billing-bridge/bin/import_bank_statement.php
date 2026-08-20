#!/usr/bin/env php
<?php

/*
 * Copyright (c) 2019-2026 ORBITALFREIGHT Holding.
 * SPDX-License-Identifier: LicenseRef-OrbitalFreight-Internal
 */

/**
 * Lot du matin : lit le relevé bancaire déposé pendant la nuit sur le partage comptable et
 * enregistre chaque encaissement dans billing-service. C'est ce lot qui, indirectement, débloque
 * la douane — une facture soldée publie `billing.invoice.settled`, seul événement qui positionne
 * customs.customs_declarations.duty_paid.
 *
 * Usage : import_bank_statement.php <fichier> [--dry-run]
 *
 * @package OrbitalFreight\LegacyBillingBridge
 */

declare(strict_types=1);

use OrbitalFreight\LegacyBillingBridge\Billing\BillingServiceClient;
use OrbitalFreight\LegacyBillingBridge\Billing\LegacyInvoiceMapper;
use OrbitalFreight\LegacyBillingBridge\Billing\PaymentFileImporter;

require __DIR__ . '/../vendor/autoload.php';

$arguments = array_slice($argv, 1);
$dryRun = in_array('--dry-run', $arguments, true);
$path = $arguments[0] ?? null;

if ($path === null || !is_readable($path)) {
    fwrite(STDERR, "usage : import_bank_statement.php <fichier> [--dry-run]\n");
    exit(2);
}

$region = of_env('OF_REGION_CODE');
if (!of_region_is_valid($region)) {
    of_log('error', 'OF_REGION_CODE hors de la liste fermée de §0.6', ['region_code' => $region]);
    exit(1);
}

// Un seul trace-id pour tout le lot : il retrouve d'un coup, chez billing-service, l'ensemble des
// encaissements passés ce matin-là. Les relevés arrivent en un fichier par jour, donc la
// granularité par exécution est la bonne.
$traceId = bin2hex(random_bytes(16));

// Le relevé est en latin-1 comme tout ce qui vient de la banque via le mainframe. La conversion
// se fait ici, une fois, avant que PaymentFileImporter ne découpe quoi que ce soit : découper
// des octets latin-1 avec des fonctions multi-octets décalerait les colonnes de largeur fixe.
$raw = mb_convert_encoding((string) file_get_contents($path), 'UTF-8', 'ISO-8859-1');
$lines = preg_split('/\r\n|\r|\n/', rtrim($raw, "\r\n")) ?: [];

$importer = new PaymentFileImporter(
    billing: new BillingServiceClient(
        baseUrl: rtrim(of_env('OF_BILLING_BASE_URL'), '/'),
        identityBaseUrl: of_identity_base_url(),
    ),
    mapper: new LegacyInvoiceMapper(),
);

if ($dryRun) {
    // À blanc, on ne veut surtout pas des appels sortants : on se contente de compter les
    // écritures reconnaissables, ce qui suffit à valider un changement de format côté banque.
    $recognised = count(array_filter($lines, static fn (string $line): bool => str_starts_with($line, 'MV')));
    fwrite(STDOUT, sprintf("%d écritures reconnues sur %d lignes\n", $recognised, count($lines)));
    exit(0);
}

$result = $importer->import($lines, $traceId);

foreach ($result['failures'] as $failure) {
    of_log('error', 'écriture non importée', $failure + ['trace_id' => $traceId]);
}

of_log('info', 'relevé bancaire importé', [
    'path'     => $path,
    'imported' => $result['imported'],
    'skipped'  => $result['skipped'],
    'failed'   => count($result['failures']),
    'trace_id' => $traceId,
]);

// Code de sortie non nul dès qu'une écriture est restée sur le carreau : le lot est surveillé par
// le même contrôle que les autres CronJobs, et un import silencieusement partiel se découvre
// sinon trois jours plus tard, quand un client rappelle pour une relance injustifiée.
exit($result['failures'] === [] ? 0 : 1);
