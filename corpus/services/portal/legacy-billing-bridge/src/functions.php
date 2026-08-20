<?php

/**
 * Fonctions d'amorçage partagées par le contrôleur frontal et par le lot d'import : lecture des
 * variables d'environnement, journalisation au format attendu par le collecteur, et résolution de
 * l'URL HTTP d'identity-service. Elles sont globales, sans espace de noms, parce qu'elles sont
 * appelées depuis des scripts qui n'instancient rien — chargées par la section « files » de
 * l'autoload Composer.
 *
 * @package OrbitalFreight\LegacyBillingBridge
 */

declare(strict_types=1);

use OrbitalFreight\LegacyBillingBridge\Billing\UpstreamFailure;

/**
 * La passerelle ne figure pas parmi les quatorze services de §1, donc ops/validate-env.py ne la
 * contrôle pas. On s'interdit malgré tout d'inventer des noms : tout ce qui est lu ici existe
 * déjà en §5, et la règle 1 de §7 s'applique au pont comme au reste.
 *
 * @throws RuntimeException si la variable est absente et sans valeur de repli
 */
function of_env(string $name, ?string $default = null): string
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        if ($default === null) {
            throw new RuntimeException(sprintf('variable d\'environnement obligatoire absente : %s', $name));
        }

        return $default;
    }

    return $value;
}

/**
 * Journalisation au format imposé par OF_LOG_FORMAT : JSON sur stderr en production, collecté par
 * le même pipeline que les quatorze services, texte lisible en local.
 *
 * @param string $level trace|debug|info|warn|error, valeurs de OF_LOG_LEVEL
 * @param array<string, mixed> $fields
 */
function of_log(string $level, string $message, array $fields = []): void
{
    static $format = null;
    static $threshold = null;

    $format ??= of_env('OF_LOG_FORMAT', 'text');
    $threshold ??= of_env('OF_LOG_LEVEL', 'info');

    $order = ['trace' => 0, 'debug' => 1, 'info' => 2, 'warn' => 3, 'error' => 4];
    if (($order[$level] ?? 2) < ($order[$threshold] ?? 2)) {
        return;
    }

    $record = [
        'level'   => $level,
        'ts'      => gmdate('Y-m-d\TH:i:s\Z'),
        'service' => 'legacy-billing-bridge',
        'msg'     => $message,
    ] + $fields;

    if ($format === 'json') {
        fwrite(STDERR, json_encode($record, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n");

        return;
    }

    fwrite(STDERR, sprintf(
        "%s %-5s %s %s\n",
        $record['ts'],
        strtoupper($level),
        $message,
        $fields === [] ? '' : json_encode($fields, JSON_UNESCAPED_UNICODE),
    ));
}

/**
 * URL HTTP d'identity-service. §5 ne la déclare nulle part : seules OF_IDENTITY_GRPC_ADDR et
 * OF_IDENTITY_JWKS_URL existent, parce que les vrais services parlent à identity-service en gRPC
 * (identity.v1.TokenIntrospection/Introspect) et que la passerelle, elle, n'a besoin que de
 * POST /v1/auth/token. Le portail Ruby résout le même problème par la convention de nommage
 * in-cluster de §1 ; ici on part du JWKS, qui pointe forcément sur le même hôte et le port 8081.
 */
function of_identity_base_url(): string
{
    $jwks = of_env('OF_IDENTITY_JWKS_URL');
    $parts = parse_url($jwks);

    if ($parts === false || !isset($parts['scheme'], $parts['host'])) {
        throw new UpstreamFailure('identity_jwks_url_malformed', 500, 'OF_IDENTITY_JWKS_URL illisible : ' . $jwks);
    }

    return sprintf('%s://%s:%d', $parts['scheme'], $parts['host'], $parts['port'] ?? 8081);
}

/**
 * Liste fermée de §0.6. Une région hors liste est une faute de frappe dans le manifeste, jamais
 * une nouvelle région : une région se déclare d'abord dans infra/, jamais dans un composant.
 */
function of_region_is_valid(string $region): bool
{
    return in_array($region, [
        'eu-west', 'eu-central', 'na-east', 'na-west', 'apac-sg', 'apac-jp', 'latam-br', 'mea-ae',
    ], true);
}
