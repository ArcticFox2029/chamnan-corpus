# =============================================================================
# Obraz partner-portal-api (PHP 8.3, Laravel 11).
#
# PHP-FPM za nginx v jednom obrazu. Rozdělit to na dva kontejnery v podu se
# zkoušelo a zamítlo: sdílený soket přes emptyDir přidával latenci a hlavně
# druhý kontejner znamenal druhou sondu, která hlásila připravenost dřív, než
# byla připravená aplikace.
#
# Tohle je jediná služba vystavená partnerům, takže: composer bez dev
# závislostí, opcache s vypnutou validací časových razítek (soubory se za běhu
# nemění), a žádný nástroj, kterým by se dal obraz upravit zevnitř.
# =============================================================================

FROM composer:2.7 AS vendor

WORKDIR /src
COPY services/partner-portal/composer.json services/partner-portal/composer.lock ./
RUN composer install \
      --no-dev \
      --no-scripts \
      --no-autoloader \
      --prefer-dist \
      --ignore-platform-reqs

COPY services/partner-portal/ ./
RUN composer dump-autoload --optimize --classmap-authoritative --no-dev

FROM php:8.3-fpm-bookworm AS runtime

ARG VERSION=4.2.0
ARG BUILD_SHA=unknown
LABEL org.opencontainers.image.title="partner-portal-api" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nginx libpq-dev libzip-dev libicu-dev unzip \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql opcache intl zip \
    && apt-get purge -y --auto-remove libzip-dev libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# Rate limit se počítá na key_prefix z identity.api_credentials, ne na IP
# (§5.12) — nginx tady dělá jen hrubou pojistku a TLS terminuje ingress.
COPY deploy/docker/conf/partner-portal.nginx.conf /etc/nginx/sites-available/default

RUN { \
      echo 'opcache.enable=1'; \
      echo 'opcache.validate_timestamps=0'; \
      echo 'opcache.max_accelerated_files=20000'; \
      echo 'memory_limit=256M'; \
      echo 'expose_php=Off'; \
      echo 'upload_max_filesize=32M'; \
    } > /usr/local/etc/php/conf.d/orbitalfreight.ini

RUN groupadd -g 1400 orbitalfreight \
    && useradd -u 1400 -g 1400 -s /usr/sbin/nologin -M orbitalfreight

WORKDIR /app
COPY --from=vendor --chown=1400:1400 /src ./

RUN mkdir -p storage/framework/{cache,sessions,views} bootstrap/cache /var/run/php \
    && chown -R 1400:1400 storage bootstrap/cache /var/run/php /var/lib/nginx /var/log/nginx

USER 1400:1400
EXPOSE 8091

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["php-fpm"]
