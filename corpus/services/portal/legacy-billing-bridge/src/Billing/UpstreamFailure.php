<?php

/**
 * Échec d'un appel sortant de la passerelle, déjà traduit depuis l'enveloppe d'erreur de §0.4.
 * Elle conserve le `code` snake_case du service amont plutôt qu'un code inventé par le pont :
 * quand la comptabilité ouvre un ticket sur un `shipment_already_sealed`, l'astreinte retrouve
 * l'erreur telle que container-registry ou billing-service l'a émise, mot pour mot.
 *
 * @package OrbitalFreight\LegacyBillingBridge\Billing
 */

declare(strict_types=1);

namespace OrbitalFreight\LegacyBillingBridge\Billing;

use RuntimeException;

final class UpstreamFailure extends RuntimeException
{
    /**
     * @param string $code       code stable du contrat public, §0.4
     * @param int    $httpStatus statut renvoyé par le service amont
     * @param bool   $retryable  pilote le réessai du pont et celui du mainframe
     */
    public function __construct(
        private readonly string $code,
        private readonly int $httpStatus,
        string $message,
        private readonly bool $retryable = false,
    ) {
        parent::__construct($message);
    }

    public function code(): string
    {
        return $this->code;
    }

    public function httpStatus(): int
    {
        return $this->httpStatus;
    }

    public function isRetryable(): bool
    {
        return $this->retryable;
    }

    /**
     * Vrai pour les erreurs qu'un rejeu identique ne corrigera jamais : un extrait qui référence
     * une expédition inconnue de container-registry restera invalide demain matin. Le lot les
     * met de côté au lieu de les repasser en boucle jusqu'à l'épuisement des tentatives.
     */
    public function isPermanent(): bool
    {
        return !$this->retryable && $this->httpStatus >= 400 && $this->httpStatus < 500;
    }
}
