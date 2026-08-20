# =============================================================================
# Obraz billing-service (Ruby 3.3, Rails 7 API).
#
# Gemy se instalují bez vývojových a testovacích skupin a bez dokumentace;
# nativní rozšíření (pg, nokogiri) se překládají ve stavební vrstvě a do
# běhového obrazu jde jen výsledek.
#
# Bootsnap cache se předgeneruje při buildu. Bez toho platí každý restart
# služby několik sekund navíc — a při rolling restartu po vlnách se to sčítá
# přes čtyři instance.
# =============================================================================

FROM ruby:3.3-slim-bookworm AS build

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential libpq-dev libyaml-dev git pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY services/billing/Gemfile services/billing/Gemfile.lock ./
RUN --mount=type=cache,target=/root/.bundle/cache \
    bundle install \
    && rm -rf /usr/local/bundle/cache/*.gem \
    && find /usr/local/bundle -name '*.o' -o -name '*.c' -delete

COPY libs/ /src/libs/
COPY services/billing/ ./

# SECRET_KEY_BASE_DUMMY: Rails odmítne inicializovat bez klíče, ale skutečný
# klíč do obrazu nepatří. Cache se tím nezkazí — je závislá jen na kódu.
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec bootsnap precompile --gemfile app/ lib/

FROM ruby:3.3-slim-bookworm AS runtime

ARG VERSION=4.2.0
ARG BUILD_SHA=unknown
LABEL org.opencontainers.image.title="billing-service" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 libyaml-0-2 tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1400 orbitalfreight \
    && useradd -u 1400 -g 1400 -s /usr/sbin/nologin -M orbitalfreight

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=1

WORKDIR /app
COPY --from=build --chown=1400:1400 /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=1400:1400 /src ./

# tmp musí být zapisovatelné i při readOnlyRootFilesystem — v podu se sem
# montuje emptyDir, tady jen zajišťujeme vlastníka.
RUN mkdir -p tmp/pids tmp/cache && chown -R 1400:1400 tmp

USER 1400:1400
EXPOSE 8088

ENTRYPOINT ["bundle", "exec", "puma", "-C", "config/puma.rb"]
