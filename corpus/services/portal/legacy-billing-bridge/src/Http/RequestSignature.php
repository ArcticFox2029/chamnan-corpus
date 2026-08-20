<?php

/**
 * Vérification de la signature HMAC posée par le mainframe comptable sur chacun de ses appels.
 *
 * C'est la seule authentification dont dispose la passerelle : l'ancien système ne sait pas
 * demander de jeton à identity-service, et lui délivrer un identity.api_credentials reviendrait
 * à lui confier un secret qu'il stocke en clair dans un membre de bibliothèque. Le secret partagé
 * est monté depuis un Secret Kubernetes, jamais lu depuis une variable d'environnement.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Http
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Http;

final class RequestSignature
{
    /** Chemin du secret partagé, monté en lecture seule par le déploiement. */
    private const SECRET_PATH = '/var/run/secrets/orbitalfreight/legacy-bridge-hmac';

    /** Tolérance d'horloge, en secondes. Le mainframe dérive d'environ deux secondes par jour. */
    private const MAX_SKEW_SECONDS = 300;

    /** @var array<string, string> secrets déjà lus, indexés par identifiant de clé */
    private array $secrets = [];

    public function __construct(private readonly string $environment)
    {
    }

    /**
     * @param string $method verbe HTTP
     * @param string $path   chemin sans query string
     * @param string $body   corps brut, avant tout décodage de charset
     * @param array<string, mixed> $server superglobale $_SERVER, injectée pour les tests
     */
    public function verify(string $method, string $path, string $body, array $server): bool
    {
        // En local on ne signe rien : le poste de développement n'a pas le secret, et refuser
        // toutes les requêtes rendrait la passerelle intestable hors du cluster.
        if ($this->environment === 'local') {
            return true;
        }

        $header = (string) ($server['HTTP_X_LEGACY_SIGNATURE'] ?? '');
        if ($header === '') {
            return false;
        }

        // Format : keyId=CPT01,ts=1773568904,sig=<hex sha256>
        $parts = [];
        foreach (explode(',', $header) as $chunk) {
            $pair = explode('=', trim($chunk), 2);
            if (count($pair) === 2) {
                $parts[$pair[0]] = $pair[1];
            }
        }

        if (!isset($parts['keyId'], $parts['ts'], $parts['sig'])) {
            return false;
        }

        $timestamp = (int) $parts['ts'];
        if (abs(time() - $timestamp) > self::MAX_SKEW_SECONDS) {
            of_log('warn', 'signature héritée hors fenêtre temporelle', [
                'key_id'      => $parts['keyId'],
                'skew_seconds' => time() - $timestamp,
            ]);

            return false;
        }

        $secret = $this->secretFor($parts['keyId']);
        if ($secret === null) {
            return false;
        }

        // Le corps entre dans l'empreinte : sans lui, un rejeu pourrait substituer un extrait de
        // facturation à un autre en gardant l'en-tête intact.
        $canonical = implode("\n", [strtoupper($method), $path, (string) $timestamp, hash('sha256', $body)]);
        $expected = hash_hmac('sha256', $canonical, $secret);

        // hash_equals et pas === : la comparaison doit rester à temps constant.
        return hash_equals($expected, strtolower($parts['sig']));
    }

    /**
     * Deux clés coexistent pendant les rotations, d'où l'identifiant dans l'en-tête. Une clé
     * absente du répertoire est traitée comme une clé révoquée, pas comme une erreur de
     * configuration : c'est exactement ce qui se passe le jour où la comptabilité oublie de
     * prévenir qu'elle a basculé.
     */
    private function secretFor(string $keyId): ?string
    {
        if (array_key_exists($keyId, $this->secrets)) {
            return $this->secrets[$keyId] !== '' ? $this->secrets[$keyId] : null;
        }

        if (preg_match('/^[A-Z0-9]{3,12}$/', $keyId) !== 1) {
            return null;
        }

        $file = self::SECRET_PATH . '/' . $keyId;
        $raw = is_readable($file) ? file_get_contents($file) : false;
        $this->secrets[$keyId] = $raw === false ? '' : trim($raw);

        return $this->secrets[$keyId] !== '' ? $this->secrets[$keyId] : null;
    }
}
