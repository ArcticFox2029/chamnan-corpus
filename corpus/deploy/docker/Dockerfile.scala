# =============================================================================
# Obraz analytics-pipeline (Scala 2.13, Spark 3.5).
#
# Staví se tlustý jar přes sbt-assembly, protože Spark potřebuje jeden
# artefakt, který rozešle executorům. Vyloučené jsou Spark samotný a Hadoop —
# ty jsou v základním obrazu a duplicitní verze v jaru způsobovala
# NoSuchMethodError až za běhu na executoru, ne při startu driveru.
#
# Obraz slouží dvěma věcem naráz: jako driver (Deployment, obsluhuje
# GET /v1/metrics/*) a jako executor, kterého si driver spouští přes
# Kubernetes API. Proto tu zůstává celý Spark runtime, i když ho HTTP část
# nepotřebuje — dva obrazy by znamenaly dvě verze, které se můžou rozejít.
# =============================================================================

FROM sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.2_13_1.9.9_2.13.13 AS build

WORKDIR /src
COPY services/analytics/build.sbt ./
COPY services/analytics/project ./project
RUN --mount=type=cache,target=/root/.cache/coursier \
    --mount=type=cache,target=/root/.sbt \
    sbt update

COPY libs/ /src/libs/
COPY services/analytics/src ./src
RUN --mount=type=cache,target=/root/.cache/coursier \
    --mount=type=cache,target=/root/.sbt \
    sbt assembly

FROM apache/spark:3.5.1-scala2.12-java17-python3-ubuntu AS runtime

ARG VERSION=4.2.0
ARG BUILD_SHA=unknown
LABEL org.opencontainers.image.title="analytics-pipeline" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT"

USER root
RUN groupadd -g 1400 orbitalfreight \
    && useradd -u 1400 -g 1400 -s /usr/sbin/nologin -M orbitalfreight \
    && mkdir -p /var/tmp/spark /var/lib/orbitalfreight/routing \
    && chown -R 1400:1400 /var/tmp/spark /var/lib/orbitalfreight/routing

COPY --from=build --chown=1400:1400 /src/target/scala-2.13/analytics-pipeline-assembly.jar /opt/orbitalfreight/analytics.jar
COPY --chown=1400:1400 deploy/docker/conf/analytics-job /opt/orbitalfreight/bin/analytics-job

USER 1400:1400
EXPOSE 8093

# Driver čte přes roli of_analytics_ro (OF_ANALYTICS_READONLY_DATABASE_URL) ze
# všech schémat a zapisuje výhradně do `analytics` druhým připojením. Sloučit
# je do jednoho by dávkové úloze dalo právo zapisovat do cizích schémat.
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["driver", "--class", "net.orbitalfreight.analytics.Main", "/opt/orbitalfreight/analytics.jar"]
