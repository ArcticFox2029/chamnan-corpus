# =============================================================================
# Obraz fleet-service (Java 21, Spring Boot 3).
#
# Dvě věci, které se tu dělají jinak, než jak vypadá běžný Spring Boot obraz:
#
#   1. Fat jar se rozbaluje na vrstvy (`layertools extract`). Knihovny se mění
#      jednou za čtvrtletí, aplikační třídy při každém commitu — bez rozdělení
#      by se při každém buildu přenášelo 180 MB závislostí.
#   2. Žádný `java -jar`. Spouští se rozbalená aplikace, aby JVM nemusela při
#      startu rozbalovat archiv; u služby, která se restartuje po vlnách,
#      to je rozdíl několika sekund na instanci.
#
# JAVA_TOOL_OPTIONS se v podu přebíjí; hodnota tady je pro lokální běh.
# =============================================================================

FROM eclipse-temurin:21-jdk-jammy AS build

WORKDIR /src
COPY services/fleet/mvnw services/fleet/pom.xml ./
COPY services/fleet/.mvn ./.mvn
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -q dependency:go-offline

COPY libs/ /src/libs/
COPY services/fleet/src ./src
RUN --mount=type=cache,target=/root/.m2 \
    ./mvnw -B -q -DskipTests package

RUN mkdir -p /out && cd /out && java -Djarmode=layertools -jar /src/target/fleet-service.jar extract

FROM eclipse-temurin:21-jre-jammy AS runtime

ARG VERSION=4.2.0
ARG BUILD_SHA=unknown
LABEL org.opencontainers.image.title="fleet-service" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT"

RUN groupadd -g 1400 orbitalfreight \
    && useradd -u 1400 -g 1400 -s /usr/sbin/nologin -M orbitalfreight

WORKDIR /app
# Pořadí vrstev od nejstabilnější po nejméně stabilní.
COPY --from=build --chown=1400:1400 /out/dependencies/ ./
COPY --from=build --chown=1400:1400 /out/spring-boot-loader/ ./
COPY --from=build --chown=1400:1400 /out/snapshot-dependencies/ ./
COPY --from=build --chown=1400:1400 /out/application/ ./

USER 1400:1400
EXPOSE 8082 9082

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError"

# ExitOnOutOfMemoryError je záměr: pod, kterému došla paměť, má zemřít a nechat
# se nahradit. JVM, která po OOM dál běží a odpovídá na /healthz, je horší stav
# — vypadá živě a přitom neobslouží fleet.v1.FleetService/Assign.
ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
