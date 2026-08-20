# =============================================================================
# Obraz pro obě služby psané v Go 1.22: identity-service a audit-ledger.
#
# Jeden soubor pro obě schválně — liší se jen adresářem a portem, a dvě kopie
# téhož by znamenaly dvě místa, kde se zapomene na opravu. Která služba se
# staví, říká ARG SERVICE; hodnota musí být jméno ze §1 SPEC.md, protože se
# z ní odvozuje i cesta do services/.
#
# Výsledný obraz je distroless a běží pod UID 1400 — stejným, jaké má
# securityContext v deploy/kubernetes/. Kdyby se rozešly, pody by padaly na
# právech k připojeným secretům, ne na aplikační chybě.
#
#   docker build -f deploy/docker/Dockerfile.go --build-arg SERVICE=identity-service .
# =============================================================================

FROM golang:1.22-bookworm AS build

ARG SERVICE
ARG VERSION=4.2.0
ARG BUILD_SHA=unknown

WORKDIR /src

# Závislosti odděleně od zdrojáků: mění se řádově méně často a vrstva se tak
# recykluje mezi buildy všech Go služeb.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY libs/ ./libs/
COPY services/${SERVICE}/ ./services/${SERVICE}/

# CGO vypnuté kvůli distroless static; -trimpath a prázdné ldflags kvůli
# reprodukovatelnosti — dva buildy téhož commitu musí dát stejný digest.
# Verze a SHA se vpisují do binárky a vrací je GET /version (§3.15).
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.buildSHA=${BUILD_SHA}" \
      -o /out/service \
      ./services/${SERVICE}/cmd/server

FROM gcr.io/distroless/static-debian12:nonroot AS runtime

ARG SERVICE
ARG VERSION=4.2.0
ARG BUILD_SHA=unknown

LABEL org.opencontainers.image.title="${SERVICE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT" \
      org.opencontainers.image.source="https://git.orbitalfreight.net/platform/orbitalfreight"

COPY --from=build /out/service /usr/local/bin/service

# 1400 = uživatel orbitalfreight, stejný jako v rolích Ansiblu i v podech.
USER 1400:1400

# identity-service 8081/9081, audit-ledger 8092/9092. EXPOSE je dokumentace,
# skutečný port říká OF_HTTP_PORT.
EXPOSE 8081 9081 8092 9092

ENTRYPOINT ["/usr/local/bin/service"]
