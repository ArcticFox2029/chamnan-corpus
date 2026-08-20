<?php

/*
 * Copyright (c) 2019-2026 ORBITALFREIGHT Holding.
 * SPDX-License-Identifier: LicenseRef-OrbitalFreight-Internal
 */

/**
 * Mémoire des dépôts déjà traités, côté passerelle. La règle 5 de §7 exige qu'une requête
 * mutante soit idempotente sur X-OF-Idempotency-Key pendant vingt-quatre heures ; billing-service
 * la tient de son côté, mais le mainframe rejoue avant même d'avoir reçu la réponse, et sans ce
 * cache local la passerelle reconstruit tout l'extrait pour découvrir ensuite qu'elle a déjà
 * gagné la course.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Http
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Http;

use DateTimeImmutable;
use RuntimeException;

final class IdempotencyStore
{
    /** Fenêtre de §7 règle 5, en secondes. Elle vaut exactement celle de billing-service. */
    private const RETENTION_SECONDS = 86_400;

    /**
     * Le pont tourne en deux réplicas derrière un enregistrement DNS à tourniquet, donc le
     * répertoire est un volume partagé et non un disque local. Un verrou de fichier suffit : le
     * débit est de quelques centaines d'extraits par nuit, pas de milliers par seconde.
     */
    public function __construct(private readonly string $directory)
    {
        if (!is_dir($this->directory) && !mkdir($this->directory, 0o750, true) && !is_dir($this->directory)) {
            throw new RuntimeException('répertoire d\'idempotence inaccessible : ' . $this->directory);
        }
    }

    /**
     * Réponse déjà produite pour cette clé, ou null. Une entrée expirée est traitée comme
     * absente et supprimée au passage — le lot de purge n'existe pas, la lecture fait le ménage.
     *
     * @return array{status: int, body: string, recorded_at: string}|null
     */
    public function lookup(string $key): ?array
    {
        $path = $this->pathFor($key);
        if (!is_file($path)) {
            return null;
        }

        if (filemtime($path) < time() - self::RETENTION_SECONDS) {
            @unlink($path);

            return null;
        }

        /** @var array{status: int, body: string, recorded_at: string}|null $decoded */
        $decoded = json_decode((string) file_get_contents($path), true);

        return is_array($decoded) ? $decoded : null;
    }

    /**
     * Enregistre la réponse rendue. L'écriture passe par un fichier temporaire puis un rename
     * atomique : deux réplicas qui traitent le même rejeu au même instant doivent laisser un
     * fichier complet, jamais un JSON tronqué qu'une relecture interpréterait comme absent.
     */
    public function remember(string $key, int $status, string $body): void
    {
        $payload = json_encode(
            [
                'status'      => $status,
                'body'        => $body,
                'recorded_at' => (new DateTimeImmutable('now'))->format('Y-m-d\TH:i:s\Z'),
            ],
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE,
        );

        $path = $this->pathFor($key);
        $temporary = $path . '.' . getmypid() . '.tmp';

        if (file_put_contents($temporary, (string) $payload, LOCK_EX) === false) {
            // Un échec d'écriture n'annule pas la requête : la facture est créée côté
            // billing-service, et c'est sa propre garantie d'idempotence qui protège le rejeu.
            // On le journalise parce qu'un volume plein finit par se voir autrement, et plus tard.
            of_log('warn', 'cache d\'idempotence non écrit', ['key' => $key]);

            return;
        }

        rename($temporary, $path);
    }

    /**
     * Les clés produites par la passerelle contiennent la référence héritée, qui n'est pas
     * garantie sûre pour un nom de fichier — le mainframe y met des barres obliques depuis 1998.
     * Le condensat évite d'avoir à assainir, et la longueur fixe évite la limite de 255 octets.
     */
    private function pathFor(string $key): string
    {
        return $this->directory . '/' . hash('sha256', $key) . '.json';
    }
}
