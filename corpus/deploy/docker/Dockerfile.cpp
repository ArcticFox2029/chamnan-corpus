# =============================================================================
# Obraz geo-service (C++20, gRPC).
#
# Nejdelší build v repozitáři — proto je rozdělený tak, aby se cache trefila
# co nejčastěji: nejdřív systémové závislosti, pak vcpkg manifest, teprve pak
# zdrojáky. Změna jednoho .cpp souboru nesmí znamenat překlad Protobufu a
# GEOS znovu.
#
# Silniční graf (OF_GEO_ROAD_GRAPH_PATH) se do obrazu nekopíruje. Má desítky
# gigabajtů, staví ho offline dávka a v clusteru se připojuje jako PVC v
# režimu ReadOnlyMany. Obraz s ním by se nedal ani rozumně stáhnout.
# =============================================================================

FROM debian:bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git pkg-config curl zip unzip tar \
        libssl-dev libgeos-dev libproj-dev protobuf-compiler-grpc \
        libgrpc++-dev libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY services/geo/CMakeLists.txt services/geo/vcpkg.json ./
COPY services/geo/cmake ./cmake

COPY libs/ /src/libs/
COPY services/geo/src ./src
COPY services/geo/include ./include

# -O2 místo -O3 vědomě: rozdíl ve výkonu point-in-polygon byl v měření pod
# jedno procento, ale -O3 přidalo minuty k buildu a znesnadnilo čtení
# stacktrace z produkčního jádra.
RUN cmake -B /build -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_CXX_FLAGS="-O2 -fno-omit-frame-pointer" \
        -DOF_BUILD_TESTS=OFF \
    && cmake --build /build --parallel

FROM debian:bookworm-slim AS runtime

ARG VERSION=4.2.0
ARG BUILD_SHA=unknown
LABEL org.opencontainers.image.title="geo-service" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_SHA}" \
      org.opencontainers.image.vendor="ORBITALFREIGHT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libssl3 libgeos-c1v5 libproj25 libgrpc++1.51 libprotobuf32 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1400 orbitalfreight \
    && useradd -u 1400 -g 1400 -s /usr/sbin/nologin -M orbitalfreight

COPY --from=build /build/geo-service /usr/local/bin/geo-service

# Přípojný bod pro graf. Prázdný adresář v obrazu je záměr — kdyby chyběl,
# kubelet ho vytvoří jako root a služba pod UID 1400 na něj nedosáhne.
RUN mkdir -p /var/lib/orbitalfreight/geo && chown 1400:1400 /var/lib/orbitalfreight/geo

USER 1400:1400
EXPOSE 8086 9086

ENTRYPOINT ["/usr/local/bin/geo-service"]
